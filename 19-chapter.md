# 第 19 章 · 温度记录仪 BLE 版（SPL版）

> **本章产出**：把第 18 章的温度记录仪从“连接路由器后上报”改为“由手机近距离读取”；理解 BLE 的广播、连接、特征值和通知在 AT 模块项目中的位置。
>
> **前置知识**：第 17 章无线与 AT 模块、第 18 章温度记录仪。
>
> **用在哪**：手机调试、低功耗传感器、近距离配置与控制。

---

## 19.1 BLE 不是把 WiFi 命令换个名字

第 18 章的 WiFi 路径是：

~~~text
STM32 → AT 模块 → 路由器 → TCP 网关
~~~

BLE 的典型路径是：

~~~text
STM32 → AT 模块 → 手机
~~~

WiFi 更像设备主动连接服务器；BLE 常常先广播，让手机发现后再连接。因此，连接状态、数据方向和功耗策略都不同。

## 19.2 认识 BLE 的四个对象

| 名词 | 先这样理解 |
|---|---|
| 广播 Advertising | 设备周期性喊“我在这里” |
| 连接 Connection | 手机选择一个设备后建立会话 |
| Service | 一组相关功能，例如环境监测 |
| Characteristic | 可读、可写、可通知的数据项 |

例如可设计：

~~~text
Environmental Service
  ├─ Temperature Characteristic：Notify
  ├─ Humidity Characteristic：Notify
  └─ Command Characteristic：Write
~~~

若使用 AT 模块，Service 与 Characteristic 可能由模块固件预定义，也可能通过 AT 命令配置。必须以模块手册为准，不能把一个模块的命令照搬到另一个模块。

## 19.3 数据仍然需要协议

BLE Notify 也不是“天然完整的一条业务消息”。为温度记录仪定义最小帧：

~~~text
SOF | type | seq | payload_len | payload | CRC
~~~

其中：

- seq 用于识别重复通知；
- payload 可以是定点温度、湿度和电池电压；
- CRC 能帮助区分链路问题与解析错误。

不要直接把 printf 文本当作长期协议；调试文本可变，二进制帧才适合程序稳定解析。

## 19.4 一个清晰的 BLE 状态机

~~~text
INIT → ADVERTISING → CONNECTED → NOTIFYING
             ↑             |          |
             └── disconnect/error ────┘
~~~

每个状态都应通过模块的明确响应切换。手机断开后，模块应回到广播；STM32 不应该因为手机离开而停止采样或记录数据。

## 19.5 任务划分

~~~text
Task_Sensor
  → Queue_LatestSample
  → Task_BLETx

Task_BLE_Rx
  → 解析写入命令
  → Queue_Command

Task_BLETx
  → 仅在 CONNECTED 时发送 Notify
~~~

BLETxTask 应有发送频率限制。例如温度每秒更新一次已经足够；高频发送只会增加功耗、增加手机处理压力，也更难排查丢包。

## 19.6 用手机验证，而不是猜

推荐的验证顺序：

1. 手机能发现设备广播名称；
2. 连接成功后能看到 Service 与 Characteristic；
3. 订阅 Notify 后每秒收到一条温度数据；
4. 写入一条测试命令，STM32 在串口打印并返回状态；
5. 关闭手机蓝牙，设备重新进入广播而不死机。

记录手机应用、模块固件版本、广播间隔和连接参数；BLE 问题高度依赖这些条件。

## 19.7 安全和功耗边界

教学项目中可以用简单测试命令理解流程，但不要把它变成真实门锁或生产控制协议：

- 不能因为收到字符串 OPEN 就执行危险动作；
- 控制命令应有身份、序号、确认和超时；
- 广播间隔越短，越容易被发现，但越耗电；
- 真正的配对、绑定和加密能力由模块与手机系统共同决定。

第 26 章会把这些原则放进一个门锁状态机中。

## 19.8 从 UART 字节到可验证的 BLE 业务帧

不同 BLE AT 模块把“广播、连接、Notify、写特征值”的命令暴露得并不一样，因此教材不把某家命令表硬编码为通用协议。对 STM32 侧，稳定的部分是：**无论模块怎样封装 GATT，业务数据仍应有自己的帧边界。**

~~~c
typedef enum {
    BLE_MSG_SAMPLE = 0x01,
    BLE_MSG_COMMAND = 0x02,
    BLE_MSG_ACK = 0x03
} BleMessageType;

typedef struct {
    uint8_t magic;         // 固定值，例如 0xA5
    uint8_t type;
    uint16_t seq;
    uint8_t length;        // payload 长度
    /* payload[length] */
    /* crc16 */
} BleFrameHeader;
~~~

接收侧不要因为 UART 收到一段文本就立即执行动作。推荐状态机：

~~~text
WAIT_MAGIC → READ_HEADER → READ_PAYLOAD → READ_CRC → VALID / DROP
                     ↑                         │
                     └──── 长度非法或 CRC 错 ────┘
~~~

每次失败都丢弃当前半帧、增加错误计数，再回到 `WAIT_MAGIC`。这与第 24 章网关的字节流处理完全同构。

### BLE 连接状态和业务状态分开

| 连接状态 | 业务动作 |
|---|---|
| 未广播 | 只允许启动/配置模块，不发送样本 |
| 广播中 | 本地采样继续，等待手机连接 |
| 已连接 | 允许 Notify/读取；仍需要业务帧校验 |
| 已断开 | 停止 Notify，保留本地缓存并重新广播 |
| 模块异常 | 重新探测 AT，不把“未知状态”当作已连接 |

### 手机验收流程

1. 只验证广播：用通用 BLE 扫描工具看到预期设备名/服务；
2. 再连接：确认模块向 STM32 报告连接事件；
3. 只读取一个固定值：例如 `seq=1` 的温度样本；
4. 开启 Notify：每秒收到一帧递增序号的数据；
5. 从手机写入一个无害命令：例如 `GET_STATUS`；确认 STM32 先返回 ACK，再执行读取；
6. 强制断开手机：确认采样和 UART 心跳继续。

| 现象 | 优先检查 |
|---|---|
| 手机扫描不到 | 模块供电、广播状态、天线环境、模块手册配置 |
| 能连但没有数据 | 连接事件是否被解析、Notify 是否启用、业务帧长度/CRC |
| 手机发命令后设备异常 | 没有长度/类型/序号校验，或在 UART ISR 中做了业务处理 |
| 断开后不再广播 | 状态机没有处理 DISCONNECTED 或模块需要重新配置 |

练习：先用 LED 作为 `GET_STATUS` 的唯一副作用，只有收到“长度、CRC、序号都正确”的命令时才允许改变它。

## 19.9 本章要点

- BLE 面向近距离手机连接，WiFi 面向路由器和互联网；
- 广播、连接、Service、Characteristic 是 BLE 的基本组织方式；
- Notify 传递的仍是字节流，业务协议需要长度、序号与校验；
- 手机断开不应影响传感器采样和本地记录；
- BLE 控制命令需要状态机和安全边界。

---

[上一章：第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)

[下一章：第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

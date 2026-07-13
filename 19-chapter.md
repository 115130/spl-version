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

## 19.8 本章要点

- BLE 面向近距离手机连接，WiFi 面向路由器和互联网；
- 广播、连接、Service、Characteristic 是 BLE 的基本组织方式；
- Notify 传递的仍是字节流，业务协议需要长度、序号与校验；
- 手机断开不应影响传感器采样和本地记录；
- BLE 控制命令需要状态机和安全边界。

---

[上一章：第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)

[下一章：第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

# 第 19 章 · 温度记录仪 BLE 版（SPL 版）

这一章复用第 18 章的传感器、`TempSample` 和状态字段，只替换通信层：数据不再经过路由器和 TCP 网关，而是通过 BLE 模块发给附近的手机。重点放在广播、连接、Characteristic、Notify、控制命令和重连边界。

具体 AT 命令、UUID 配置方式和最大载荷取决于模块固件。本章先固定 MCU 侧业务协议和任务职责，再把它映射到手头模块支持的 GATT 接口。

## 19.1 先确定模块能提供什么

BLE AT 模块大致有两种常见形态。第一种是 UART 透传模块，Service 和 Characteristic 已经由固件固定，STM32 只负责收发字节。第二种允许通过 AT 命令配置 UUID、Notify、读写属性和连接参数。

选模块时先查手册并记录：

- 是否能配置 Service / Characteristic UUID；
- 哪个 Characteristic 支持 Notify；
- 手机写入数据时模块怎样通过 UART 上报；
- 连接、断开和订阅 Notify 是否有独立事件；
- 模块是否报告 MTU 或单次可发送载荷上限；
- 模块复位后哪些配置需要重新设置。

这些能力确认以后，MCU 侧代码才知道自己是在控制 GATT，还是只在一条固定的 BLE 串口通道里收发业务帧。

## 19.2 GATT 契约先写清楚

如果模块支持自定义 GATT，可以把温度记录仪设计成三个逻辑接口：

```text
Environmental Service
  ├─ Telemetry Characteristic : Notify
  ├─ Control Characteristic   : Write / Write With Response
  └─ Status Characteristic    : Read + Notify
```

Telemetry 只发送传感器样本；Control 接收手机命令；Status 返回协议版本、错误计数或设备状态。若模块只有固定透传 Service，也继续保留这三个业务概念，只是在同一 UART/BLE 通道上用消息 `type` 区分。

Notify 必须在手机订阅后才发送。断开连接后，订阅状态失效；设备重新连接时不能假定客户端仍然开启 Notify。

## 19.3 复用第 18 章的样本，不重复定义传感器协议

第 18 章已经有：

```c
typedef struct {
    uint32_t seq;
    uint8_t status;
    int16_t ntc_centi;
    int16_t ds_centi;
    int16_t dht_centi;
    uint16_t humidity_permille;
} TempSample;
```

BLE 层只负责把这个样本包装成业务消息。不要为了 BLE 再定义一套不同的温度单位或错误表示，否则 WiFi 版和 BLE 版会逐渐变成两个不兼容项目。

业务消息可以统一成：

```text
magic | version | type | seq | payload_len | payload | crc16
```

其中 `type` 区分样本、命令、ACK 和状态。`payload_len` 明确指出后续长度；`seq` 用于发现重复和关联 ACK；CRC 负责检测应用层帧损坏。多字节字段仍按固定端序逐字段编码，不直接发送 C struct。

## 19.4 连接状态和业务状态分开

BLE 连接状态可以写成：

```c
typedef enum {
    BLE_OFFLINE,
    BLE_ADVERTISING,
    BLE_CONNECTED,
    BLE_READY,
    BLE_RECOVERING
} BleLinkState;
```

`BLE_CONNECTED` 只表示手机和模块建立了连接；只有模块确认相关 Characteristic 可用、手机已经订阅 Notify 后，才进入 `BLE_READY`。这样可以避免“一连上就发 Notify”，但客户端实际上还没完成订阅。

手机断开时，采样任务继续运行。是否缓存历史数据由产品需求决定：实时监视可以只保留最新值；需要查看断线期间历史则应接第 13 章的持久化日志，不能无限把样本堆在 RAM 里。

模块重启或 UART 出现 `ready` 一类启动事件时，状态回到探测/恢复流程。不能只保留一个 `connected = true` 的布尔变量然后继续发送。

## 19.5 BLETxTask 只在链路可用时发送

如果手机只关心最新温湿度，可以使用长度 1 的覆盖 Queue：

```c
static QueueHandle_t latest_sample_queue;

static void SensorTask(void *argument)
{
    TempSample sample;

    (void)argument;

    for (;;) {
        Sensor_ReadAll(&sample);
        xQueueOverwrite(latest_sample_queue, &sample);
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
```

BLE 发送任务等待最新值，并检查当前链路状态：

```c
static void BleTxTask(void *argument)
{
    TempSample sample;
    uint8_t frame[64];

    (void)argument;

    for (;;) {
        if (xQueueReceive(latest_sample_queue, &sample,
                          portMAX_DELAY) != pdPASS)
            continue;

        if (Ble_GetLinkState() != BLE_READY)
            continue;

        size_t len = BleFrame_EncodeSample(frame, sizeof frame, &sample);
        if (len == 0U)
            continue;

        if (!Ble_SendNotification(frame, len))
            Ble_ReportSendError();
    }
}
```

这里没有承诺每个采样点都会到手机。长度 1 Queue 的含义就是“保留最新值”。如果项目需要完整历史，通信队列和离线存储要换成另一种策略。

## 19.6 Notify 的载荷受模块和 MTU 限制

一次 Notify 能发送多少业务字节，取决于 ATT MTU、模块固件和模块自己的 UART/GATT 封装。不能因为某台手机能一次显示 100 字节，就把 100 当成协议固定上限。

应用层定义一个经过实测的 `BLE_PAYLOAD_MAX`，它应不超过模块文档和实际协商结果允许的范围。消息小于这个上限时直接发送；更长的数据再做分片。

分片头可以包含：

```c
typedef struct {
    uint16_t seq;
    uint8_t type;
    uint8_t part_index;
    uint8_t part_count;
    uint8_t payload_len;
} BleFragmentHeader;
```

接收端按 `seq + part_index` 重组。缺片、重复片和超时都要丢弃整条未完成消息，不能把半条控制命令交给业务层。

温度样本本身很小，一般没有必要为了演示而强行分片。本节主要给后面较长配置、日志或固件信息建立边界。

## 19.7 控制命令必须能重复处理

手机写入 Control Characteristic 后，模块通常会把字节通过 UART 上报给 STM32。UART 接收层继续沿用第 17 章的字节流解析，先收满完整业务帧、检查长度和 CRC，再交给命令状态机。

例如：

```c
typedef enum {
    CMD_GET_STATUS = 0x01,
    CMD_SET_PERIOD = 0x02
} BleCommandType;

typedef struct {
    uint16_t seq;
    BleCommandType type;
    uint32_t value;
} BleCommand;
```

执行改变状态的命令前，先检查参数范围和 `seq`。如果手机因为超时重发同一个 `seq`，设备应返回同样的结果，不重复执行会产生副作用的操作。这就是幂等边界。

ACK 可以包含：

```text
command_seq | result_code | current_state
```

这样手机能区分“命令没到”“命令被拒绝”“命令已经执行但 ACK 丢了”。对于门锁、继电器等安全相关动作，还需要认证、授权和超时策略，本章不把简单 BLE 写命令当作安全控制方案。

## 19.8 手机端怎样验收

先用通用 BLE 工具验证链路，不急着写 App。测试顺序如下：

1. 扫描到设备广播，并记录实际设备名和 Service UUID。
2. 连接后确认模块向 STM32 报告连接事件。
3. 找到 Telemetry Characteristic，并手动开启 Notify。
4. 每秒收到一条递增 `seq` 的样本，状态位和数值都能正确解析。
5. 向 Control Characteristic 写 `GET_STATUS`，收到带相同 `seq` 的 ACK。
6. 重复发送同一条命令，确认不会重复产生副作用。
7. 关闭手机蓝牙或强制断开，确认 STM32 采样继续，模块回到广播或恢复状态。

测试记录里保存手机型号、系统版本、BLE 工具版本、模块固件、UUID、协商 MTU（如果可见）和发送频率。不同手机和模块组合出现差异时，这些信息能直接帮助定位。

## 19.9 解析器和状态机分别统计什么

BLE 运行时至少保留这些计数：

```c
typedef struct {
    uint32_t connect_count;
    uint32_t disconnect_count;
    uint32_t notify_error;
    uint32_t rx_bad_length;
    uint32_t rx_bad_crc;
    uint32_t duplicate_command;
    uint32_t fragment_timeout;
    uint32_t module_reset;
} BleStats;
```

`rx_bad_crc` 增长说明业务帧解析失败；`module_reset` 增长说明无线模块本身重新启动；`notify_error` 增长则说明发送阶段失败。这些状态不能合并成一个“BLE error”。

手机长时间不连接时，设备不应持续累积无上限的通知消息。实时遥测通常合并到最新值；历史记录另存本地。控制命令则只在当前连接会话内有效，断线后丢弃未完成命令。

## 19.10 分阶段接入

按下面顺序集成：

1. **广播**：只验证手机能扫描到模块。
2. **连接事件**：STM32 能收到连接和断开状态。
3. **固定 Notify**：每秒发送固定 4 字节序列，手机端能稳定接收。
4. **业务帧**：发送 `TempSample`，检查 version、seq 和 CRC。
5. **Control 写入**：手机发送 `GET_STATUS`，STM32 解析后返回 ACK。
6. **重连**：手机断开再连接，必须重新订阅 Notify，设备状态恢复正确。
7. **故障测试**：模块复位、UART 溢出、错误长度、错误 CRC、重复命令都能留下计数。

每一步只新增一个变量。这样手机收不到数据时，可以判断是广播、连接、订阅、模块 UART 还是业务帧的问题。

## 19.11 练习

1. 让 Telemetry 只发送最新样本，手机断开 30 秒后重连，确认第一条收到的是当前值而不是积压的 30 条旧数据。
2. 给 `CMD_SET_PERIOD` 增加范围检查，只接受 200 ms 到 60 s，并让 ACK 返回最终采用的周期。
3. 构造一个超过 `BLE_PAYLOAD_MAX` 的状态消息，完成两片分片和超时丢弃测试。
4. 让手机重复发送同一 `seq` 的控制命令，确认设备只执行一次，并返回相同结果。
5. 在模块复位后检查：广播配置、连接状态、Notify 订阅和统计项分别怎样恢复。

完成这一章后，WiFi 版和 BLE 版应共用同一份传感器数据模型。差别只留在通信任务和链路状态机里；采样、状态码和业务字段不重复实现。

> **上一章**：[第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)
>
> **下一章**：[第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

# 第 19 章 · 温度记录仪 BLE 版（SPL 版）

这一章复用第 18 章的传感器和 `TempSample`，只替换通信层：数据通过 BLE 模块发给附近的手机。MCU 侧需要处理广播/连接事件、Notify、手机写入命令和模块重启；具体 AT 命令、UUID 配置和载荷上限以模块固件手册为准。

## 19.1 先确认模块暴露的 BLE 能力

BLE AT 模块常见两类。固定透传模块已经在固件里定义 Service 和 Characteristic，STM32 只看到 UART 字节流；另一类允许通过 AT 命令配置 UUID、Characteristic 属性和连接参数。

接入前至少确认：

- Service / Characteristic UUID 是否可配置；
- 哪个 Characteristic 支持 Notify；
- 手机写入数据时，模块如何通过 UART 上报；
- 连接、断开、订阅 Notify 是否有独立事件；
- 模块能否报告 MTU 或实际单次发送上限；
- 模块复位后哪些配置需要重新下发。

这些信息决定 STM32 是直接管理 GATT 配置，还是只在固定透传通道上运行自己的业务协议。

## 19.2 GATT 和业务协议分两层

模块支持自定义 GATT 时，可以设计三个逻辑接口：

```text
Environmental Service
  ├─ Telemetry Characteristic : Notify
  ├─ Control Characteristic   : Write
  └─ Status Characteristic    : Read + Notify
```

Telemetry 发送传感器样本，Control 接收手机命令，Status 返回协议版本和设备状态。固定透传模块也可以保留这三个业务类型，只是在同一个 BLE 数据通道里用消息 `type` 区分。

连接建立不代表 Notify 已经可用。客户端还需要对相应 Characteristic 启用通知；断开连接后，这个订阅状态不能继续沿用到下一次连接。

## 19.3 继续使用同一份样本结构

第 18 章的采样层保持不变：

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

BLE 层只负责把它编码成业务帧。WiFi 版和 BLE 版使用相同的温度单位、状态位和序号，通信任务之外的代码不需要分叉。

一个简单的业务帧可以包含：

```text
magic | version | type | seq | payload_len | payload | crc16
```

`payload_len` 给出后续数据长度，`type` 区分样本、命令、ACK 和状态，`seq` 用于发现重复或关联请求与响应。多字节字段按协议规定的端序逐字段编码，不直接发送 C `struct`。

## 19.4 连接状态要包含 Notify 是否就绪

```c
typedef enum {
    BLE_OFFLINE,
    BLE_ADVERTISING,
    BLE_CONNECTED,
    BLE_READY,
    BLE_RECOVERING
} BleLinkState;
```

`BLE_CONNECTED` 表示链路已经建立。确认客户端订阅 Telemetry Notify 后再进入 `BLE_READY`，发送任务只在这个状态提交通知。

手机断开时，SensorTask 继续采样。实时监视可以只保留最新样本；需要保存断线期间的历史时，使用第 13 章的 NOR/SD 日志。RAM Queue 的容量必须有限。

模块通过 UART 上报启动事件或发生复位时，清除当前连接和订阅状态，重新执行模块探测与配置流程。

## 19.5 实时遥测只保留最新值

手机只需要当前温湿度时，可以创建长度 1 的 Queue：

```c
static QueueHandle_t latest_sample_queue;

static void SensorTask(void *argument)
{
    TickType_t last_wake = xTaskGetTickCount();
    TempSample sample;

    (void)argument;

    for (;;) {
        Sensor_ReadAll(&sample);
        xQueueOverwrite(latest_sample_queue, &sample);
        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(1000));
    }
}
```

`xQueueOverwrite()` 适合长度 1 的 Queue：旧值还没被消费时，新值直接替换它。这个设计明确放弃逐条历史，只保留当前状态。

BLE 发送任务可以写成：

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

断线期间收到的样本不会在连接恢复后逐条补发。重新连接并订阅后，发送的是随后产生的最新样本。如果产品要求“订阅完成后立即看到当前值”，可以在进入 `BLE_READY` 时主动读取一份 latest-value cache 并触发一次发送。

## 19.6 Notify 长度按实际链路确定

应用层一次能交给 Notify 的数据长度受 ATT MTU、模块固件和模块 UART/GATT 封装共同限制。协议中定义的 `BLE_PAYLOAD_MAX` 必须来自模块文档和实际连接测试，不能根据某一台手机的一次成功发送反推固定上限。

温度样本很小，优先让一条业务帧落在一次 Notify 能承载的范围内。状态转储或较长日志确实需要超过这个范围时，再增加分片层，例如：

```text
message_seq | type | part_index | part_count | payload_len | payload
```

接收端按 `message_seq` 重组，检查 `part_index` 和总片数。缺片、重复片、长度错误或重组超时都丢弃当前未完成消息，并增加对应计数。二进制 Payload 仍按长度处理，不能用换行或 `strlen()` 判断结束位置。

## 19.7 手机写命令时处理重复请求

Control Characteristic 收到的数据经模块 UART 送到 STM32 后，先完成业务帧长度、版本和 CRC 检查，再进入命令处理。

```c
typedef enum {
    CMD_GET_STATUS = 0x01,
    CMD_SET_PERIOD = 0x02
} BleCommandType;

typedef struct {
    uint32_t seq;
    BleCommandType type;
    uint32_t value;
} BleCommand;
```

`CMD_SET_PERIOD` 这类会改变设备状态的命令要先检查参数范围。设备还应保存最近处理过的命令 `seq` 和结果；客户端因为 ACK 超时而重发同一个请求时，返回上一次结果，不再次修改状态。

ACK 至少包含：

```text
command_seq | result_code | current_value
```

这样客户端可以把请求和响应对应起来。这个简单的序号机制只解决会话内的重复执行；模块或 MCU 重启后若还要求跨重启去重，就需要把请求标识和执行结果持久化。

涉及门锁、继电器等安全相关动作时，还需要认证、授权和重放防护。本章的普通 BLE 写入接口不提供这些安全属性。

## 19.8 UART 接收仍沿用第 17 章的分层

BLE 模块的 UART 同样是字节流。AT 响应、连接事件和手机写入的数据不能全部塞进一个 `strstr()` 解析器。

接收路径保持：

```text
USART RX
   ↓
环形缓冲 / DMA
   ↓
模块协议解析
   ├─ AT response
   ├─ connect/disconnect/subscribe event
   └─ received payload
                         ↓
                  BleFrame parser
                         ↓
                  Control command
```

模块层只负责确认“收到多少业务字节”，业务层再检查自己的 `magic/version/type/length/CRC`。这样更换 BLE 模块时，温度帧和控制命令格式不需要跟着改。

## 19.9 运行时统计

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

这些计数分别对应链路、发送、业务帧和模块复位。调试“手机没数据显示”时，可以先看连接次数和订阅状态，再看 Notify 错误；控制命令异常则检查长度、CRC 和重复请求计数。

统计值由多个任务或 ISR 更新时，还要按第 6、15 章的并发规则处理。`volatile` 只能约束编译器访问，不能替代临界区、原子操作或单一所有者设计。

## 19.10 手机端验收

先使用通用 BLE 调试工具，不急着开发 App：

1. 扫描设备，记录实际设备名和 Service UUID。
2. 连接，确认 STM32 收到连接事件。
3. 找到 Telemetry Characteristic，手动启用 Notify。
4. 检查样本 `seq` 递增，状态位和数值能正确解码。
5. 写入 `GET_STATUS`，确认 ACK 带回相同的命令 `seq`。
6. 重发同一条改变状态的命令，确认副作用只发生一次。
7. 关闭手机蓝牙或主动断开，确认 SensorTask 继续运行，模块恢复广播。
8. 重新连接并订阅，确认不会沿用上一次会话的 Notify 状态。

测试记录保留手机型号、系统版本、BLE 工具版本、模块固件版本、UUID，以及模块能够提供的 MTU/载荷信息。遇到兼容性差异时，这些信息比一句“某手机连不上”更有用。

## 19.11 分阶段接入

先验证广播，再增加连接事件。连接稳定后发送固定的短 Notify；随后换成 `TempSample` 业务帧，再增加 Control 写入和 ACK。最后测试手机断开、模块复位、UART 溢出、错误长度、错误 CRC 和重复命令。

每次只增加一层后保存测试日志。手机收不到数据时，就能判断问题停在广播、连接、订阅、模块 UART 还是业务帧解析。

## 19.12 练习

1. 手机断开 30 秒后重新连接并订阅，确认收到的是当前样本，不补发 30 条旧数据。
2. 给 `CMD_SET_PERIOD` 增加范围检查，例如实验中允许 200 ms 到 60 s，并让 ACK 返回最终采用的周期。
3. 构造一条超过 `BLE_PAYLOAD_MAX` 的状态消息，完成两片分片、缺片和重组超时测试。
4. 连续发送两次相同 `seq` 的 `CMD_SET_PERIOD`，确认设备只执行一次，并返回相同结果。
5. 让 BLE 模块复位，检查 GATT 配置、连接状态、Notify 订阅和统计项分别如何恢复。

完成本章后，WiFi 版和 BLE 版应继续共用同一份传感器数据模型。第 20 章回到 TCP/IP，把第 18 章使用的 TCP 链路逐层拆开。

> **上一章**：[第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)
>
> **下一章**：[第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

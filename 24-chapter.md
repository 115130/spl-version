# 第 24 章 · 网关架构与 UART 接收通路（SPL 版）

这一章把“UART 收到字节”整理成一条可维护的数据通路：ISR 只搬运字节，ParserTask 负责解帧，协议适配器生成统一事件，后面的规则、显示、存储和网络任务只处理事件。

前面已经分别做过 AT、HTTP、MQTT 和自定义二进制帧。本章不再讲新的协议，重点是这些协议同时存在时，怎样避免它们把串口、缓冲区和任务关系搅在一起。

## 24.1 网关内部先统一数据模型

不同设备在线路上使用不同协议，但应用层没必要保留这些差异。例如 Modbus 温度、BLE 遥测和本地传感器最终都可以转成统一事件：

```c
#define GATEWAY_PAYLOAD_MAX 32U

typedef struct {
    uint32_t seq;
    uint32_t tick;
    uint16_t source;
    uint16_t type;
    uint16_t length;
    uint16_t error_flags;
    uint8_t payload[GATEWAY_PAYLOAD_MAX];
} GatewayEvent;
```

`source` 标识数据来自哪台设备或哪个适配器，`type` 表示温度、状态、命令等事件类型，`error_flags` 保存协议层已经确认的错误状态。业务任务只处理 `GatewayEvent`，不直接读取 UART RingBuffer，也不自己解析 Modbus 或 AT 文本。

如果某类数据有固定字段，也可以在适配器里转换成更具体的 `SensorEvent`。关键是协议字节只存在于适配器边界内，不让应用层到处依赖原始帧格式。

## 24.2 UART 接收路径

一条典型的数据流是：

```text
USART RXNE / DMA
      ↓
RingBuffer（字节）
      ↓
ParserTask（帧）
      ↓
协议适配器（事件）
      ↓
GatewayQueue
      ↓
RuleTask / NetworkTask / LogTask / DisplayTask
```

这四层处理的数据单位分别是字节、帧、事件和业务动作。问题也可以按层定位：RingBuffer overflow 是接收通路来不及消费；CRC error 是帧或物理链路问题；GatewayQueue full 是事件消费速度不足；MQTT publish failure 则属于网络层。

不要用一个“大接收数组”同时承担这几层职责。数组看起来省代码，但一旦出现半帧、多个来源和网络阻塞，就很难判断哪些字节属于谁。

## 24.3 ISR 只搬运数据

USART2 接收中断可以保持很短：

```c
void USART2_IRQ_Init(void)
{
    NVIC_InitTypeDef nvic;

    USART_ITConfig(USART2, USART_IT_RXNE, ENABLE);

    nvic.NVIC_IRQChannel = USART2_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 2U;
    nvic.NVIC_IRQChannelSubPriority = 0U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}

void USART2_IRQHandler(void)
{
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t byte = (uint8_t)USART_ReceiveData(USART2);

        if (!RingBuffer_PutFromISR(&wifi_rx_ring, byte))
            ++wifi_rx_overflow;
    }
}
```

`RingBuffer_PutFromISR()` 不能等待空间。缓冲区满时记录丢弃并返回；JSON、CRC、AT 响应匹配和 Queue 操作都留给任务上下文。

USART 错误位也需要按第 8 章的规则处理。生产代码应记录 ORE、FE、NE、PE 等接收错误，避免只统计“收到多少字节”，却不知道线路已经发生过硬件级错误。

如果后面把 RX 改成 DMA，ISR 的形式会变化，但分层不变：DMA 只负责把字节搬进内存，ParserTask 仍然承担协议边界和校验。

## 24.4 RingBuffer 先明确所有权

最简单可靠的模型是单生产者/单消费者：USART ISR 只推进 `head`，ParserTask 只推进 `tail`。这种情况下，代码可以很小，且每个索引只有一个写入者。

```text
USART2 ISR  ──唯一生产者──> RingBuffer ──唯一消费者──> ParserTask
```

这个约束一旦改变，设计就要一起改变。如果第二个 ISR、DMA 回调或其他任务也写同一个 RingBuffer，就需要临界区、同步原语或重新拆缓冲区；`volatile` 不能把多生产者结构变成线程安全。

RingBuffer 满时的策略也要固定。本章对 UART 原始字节选择“丢新字节并计数”，因为覆盖旧字节会破坏当前正在解析的帧，而且上层必须知道字节流已经不完整。ParserTask 看到 overflow 计数变化后，可以放弃当前候选帧并重新同步。

## 24.5 容量先按速率估算

UART 115200、8N1 每个字节在线路上需要 10 bit，因此连续满速接收的理论上限约为：

```text
115200 / 10 = 11520 byte/s
```

如果 ParserTask 最坏有 50 ms 没有运行，仅这段时间就可能积压：

```text
11520 × 0.050 ≈ 576 byte
```

这还没有包含模块突发、调度抖动和处理余量。此时 64 或 128 字节 RingBuffer 显然不足；可以增大缓冲、减少任务阻塞、使用 DMA/流控，或者降低输入速率。

这个估算只针对连续满速 UART。真实 AT 模块往往是突发输出，因此还要实际测量最大 burst。最终容量应由“最坏积压 + 允许余量”决定，再检查 SRAM 是否接受。

## 24.6 ParserTask 按字节流维护状态

ParserTask 从 RingBuffer 取字节，并把解析状态保存在对象里。AT 模块可以解析成文本行、长度型 Payload 和异步事件；自定义二进制协议则按帧头、长度和 CRC 前进。

协议状态不能依赖“一次任务循环正好拿到一整帧”。同一帧可能被拆成几十次输入，多帧也可能已经连续排在 RingBuffer 中。

本章用一个教学二进制帧说明：

```text
A5 | 5A | type | length | payload[length] | crc8
              length = 0...32
```

解析器状态：

```c
typedef enum {
    FIND_A5,
    FIND_5A,
    READ_TYPE,
    READ_LENGTH,
    READ_PAYLOAD,
    READ_CRC
} FrameState;

typedef struct {
    FrameState state;
    uint8_t type;
    uint8_t length;
    uint8_t used;
    uint8_t payload[32];
    uint32_t last_byte_tick;

    uint32_t bad_length;
    uint32_t bad_crc;
    uint32_t timeout;
} FrameParser;
```

处理规则固定下来：

- `length > sizeof(payload)`：增加 `bad_length`，放弃当前候选帧；
- Payload 收满后读取 CRC，校验成功才交付一次事件；
- CRC 错时增加 `bad_crc`，重新寻找帧头；
- 半帧超过规定超时，增加 `timeout` 并复位状态；
- 交付时复制到 `GatewayEvent`，不把 `parser->payload` 指针直接交给 Queue。

最后一点关系到生命周期。ParserTask 收下一帧时会立刻改写内部数组，Queue 如果只保存这个数组地址，消费者读到的内容可能已经属于另一帧。

## 24.7 重同步要写进协议实现

解析器出错后不能假设下一个字节一定是新帧开头。以 `A5 5A` 为 magic 的协议，可以逐字节重新寻找候选帧头。

还要处理一个细节：在等待第二个 magic 字节时，如果又收到 `A5`，它可能已经是下一个帧头的第一个字节。状态机可以继续保持在 `FIND_5A`，而不是无条件退回 `FIND_A5`，这样能减少丢失合法起点的机会。

RingBuffer 发生 overflow 后，当前帧的完整性已经无法保证。ParserTask 应把它当成输入流损坏事件，增加统计并复位解析状态，而不是继续使用剩余的半帧。

## 24.8 从帧转换成统一事件

协议解析成功后，再做语义转换。例如某个温度帧：

```c
static bool Adapter_ToSensorEvent(const FrameParser *frame,
                                  GatewayEvent *event)
{
    if (frame->type != 0x01U || frame->length != 4U)
        return false;

    event->source = SOURCE_RS485_SENSOR_1;
    event->type = EVENT_TEMPERATURE;
    event->length = 4U;
    event->error_flags = 0U;
    memcpy(event->payload, frame->payload, 4U);
    return true;
}
```

更完整的适配器还会检查设备地址、量程、状态位和单位，并把线路协议里的单位转换成项目统一单位。完成转换后，后面的 MQTT、显示和日志任务就不需要知道原始帧长什么样。

如果协议包含设备自己的 sequence，可以保留到 `GatewayEvent.seq`；没有 sequence 时，也可以由网关为已验证事件生成本地递增序号，方便日志定位，但不要把它解释成远端设备的原始序号。

## 24.9 GatewayQueue 需要背压策略

Queue 满说明事件生产速度暂时超过了消费速度。每条 Queue 都要明确“满了怎么办”。

实时显示通常只需要最新值，可以使用长度 1 的 overwrite Queue。历史日志需要保持顺序，可以选择丢新或丢旧并明确计数。控制命令如果不能接受静默丢弃，应在入口处拒绝并返回 busy/error，而不是塞进已经满的 Queue。

例如普通遥测队列选择丢新事件：

```c
if (xQueueSend(gateway_queue, &event, 0U) != pdPASS)
    ++gateway_queue_drop_new;
```

网络异常期间消费者可能长时间停止。如果项目要求保留数小时历史，RAM Queue 不适合承担这个任务，应把第 13 章的 SD/NOR 持久化日志接到数据流中。

## 24.10 多种协议不能争用同一物理接口

同一个 UART 只能有一个明确所有者。某些 WiFi/BLE 组合模块可以在固件内部复用功能，但 MCU 侧仍要按模块协议区分 AT 响应、异步事件和业务 Payload。

如果 WiFi 和 BLE 是两个独立模块，优先给它们独立 UART。如果硬件资源不够，需要外部复用器或模式切换，就把“当前谁拥有 UART”写成状态机，并在切换前清理未完成事务。

不要让两个 Task 同时直接操作同一个 USART 的 DR、RingBuffer 或 AT 状态机。第 17 章已经把 AT 模块收进单一通信任务，本章继续使用同样的所有权规则。

## 24.11 可观测性按层记录

每层至少保留与自己职责相关的计数：

```c
typedef struct {
    uint32_t rx_bytes;
    uint32_t uart_error;
    uint32_t ring_overflow;
    uint32_t valid_frames;
    uint32_t bad_length;
    uint32_t bad_crc;
    uint32_t frame_timeout;
    uint32_t event_drop;
} GatewayStats;
```

网络任务另外记录 reconnect、publish failure、认证错误等指标，不要把它们混进 UART parser 统计。

压力测试时可以输出：

```text
source=wifi rx=12450 uart_err=0 ring_drop=0 frame_ok=381 crc_err=0
source=rs485 rx=8200 uart_err=0 ring_drop=14 frame_ok=196 crc_err=3
queue=gateway full=7 drop_new=7
network reconnect=2 publish_fail=5
```

这些数字能直接说明问题发生在哪一层。如果 `ring_drop` 已经增加，后面的 CRC 错很可能只是上游丢字节的结果；不要只盯着 CRC 算法。

## 24.12 字节流测试脱离硬件运行

每个 Parser 都应该有可重复的输入测试。同一个合法帧至少用几种切分方式喂入：

```c
FeedBytes(parser, frame, frame_len);          /* 一次全部 */

for (size_t i = 0; i < frame_len; ++i)
    FeedBytes(parser, frame + i, 1U);         /* 每次 1 字节 */

FeedBytes(parser, frame, 3U);                 /* 任意切分 */
FeedBytes(parser, frame + 3U, frame_len - 3U);
```

再加入噪声、错误 CRC、非法长度、半帧超时、两个连续帧和 `A5 A5 5A...` 这类重同步边界。不同切分方式最终产生的合法事件序列应该一致。

还要单独测试 Queue 满。解析器是否正确与 Queue 是否能接收是两个问题；合法帧仍应计入 `valid_frames`，随后事件交付失败再增加 `event_drop`。

## 24.13 联调顺序

硬件联调按数据层次往上走：

1. 只统计 USART 收到的字节和硬件错误，确认波特率、接线和电气层。
2. 从 RingBuffer 输出有限的十六进制样本，确认没有丢字节和乱序。
3. 打开 Parser，只看 valid / bad CRC / timeout 计数。
4. 转成 `GatewayEvent`，打印 `seq/source/type/length`。
5. 最后再连接 MQTT、HTTP、规则和存储任务。

如果一种设备异常导致整个网关停住，优先检查协议适配器里是否存在无超时等待、共享锁是否持有过久，以及某个 Queue 是否使用了无限阻塞发送。

## 24.14 本章完成标准

完成下面这些测试后，UART 接收通路才算真正建立：

- ISR 中没有协议解析和阻塞等待；
- RingBuffer 有明确的单生产者/单消费者所有权；
- 在目标波特率和最大 burst 下，缓冲容量经过计算和实测；
- Parser 能处理任意字节切分、连续帧、错误帧和半帧超时；
- RingBuffer overflow 后会放弃损坏的候选帧并重新同步；
- Queue 满有固定策略和计数；
- 一种协议或网络任务失败时，其他来源还能继续产生事件；
- UART、Parser、Queue、网络四层统计可以分别查看。

这条数据通路在后面的综合项目中继续复用。新接一种设备时，只增加对应的驱动和协议适配器，不重新发明 UART 接收框架。

> **上一章**：[第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
>
> **下一章**：[第 25 章 · 综合项目一：智能环境监测节点](./25-chapter.md)

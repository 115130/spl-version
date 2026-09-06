# 第 24 章 · 网关架构与 UART 接收通路（SPL 版）

这一章把 UART 接收整理成一条固定通路：ISR 或 DMA 搬字节，Parser 识别帧，协议适配器生成事件，业务任务只处理事件。前面做过的 AT、自定义二进制协议和其他串口设备都可以套进这套结构。

## 24.1 先划清四层数据边界

一条接收路径可以写成：

```text
USART RXNE / DMA
      ↓
RingBuffer：字节
      ↓
ParserTask：协议帧
      ↓
Adapter：统一事件
      ↓
RuleTask / NetworkTask / LogTask / DisplayTask
```

每层只处理自己的数据单位。RingBuffer overflow 表示原始字节来不及消费；CRC error 属于帧或链路；事件 Queue 满表示业务消费速度不足；MQTT publish failure 属于网络输出。统计也按这些边界分别记录。

应用层不直接读取 UART RingBuffer，也不解析 AT、Modbus 或私有帧。这样增加新设备时，改动集中在驱动、Parser 和 Adapter。

## 24.2 统一事件只保存业务需要的数据

协议帧通过校验后再转换成事件。例如：

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

`source` 标识来源，`type` 表示温度、状态、命令等业务类型。固定格式的数据也可以直接定义 `SensorEvent` 等结构体，不必所有事件都塞进通用 payload。

如果远端协议有 sequence，可以保存在 `seq`。没有时可以生成本地递增序号用于日志定位，但日志和接口要明确它是网关序号，不能把它当成远端设备原始序号。

## 24.3 USART ISR 只完成接收

USART2 使用 RXNE 中断时，处理函数保持短小：

```c
void USART2_IRQHandler(void)
{
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t byte = (uint8_t)USART_ReceiveData(USART2);

        if (!RingBuffer_PutFromISR(&wifi_rx_ring, byte))
            ++wifi_rx_overflow;
    }
}
```

`RingBuffer_PutFromISR()` 不等待空位。缓冲区满时按既定策略丢弃并计数。JSON、CRC、AT 响应匹配和业务处理都放到任务上下文。

USART 的 ORE、FE、NE、PE 等错误也要按第 8 章的驱动策略处理并计数。只统计 RX 字节数会掩盖线路或调度已经导致的接收错误。

改成 DMA 后，ISR/回调负责通知“哪一段内存有新数据”，Parser 的职责不变。DMA 不会自动提供协议帧边界。

## 24.4 RingBuffer 使用单生产者、单消费者

本章采用 SPSC 模型：USART ISR 只推进 `head`，ParserTask 只推进 `tail`。

```text
USART ISR ──生产──> RingBuffer ──消费──> ParserTask
```

每个索引只有一个写入者，可以减少同步范围。若第二个 ISR、DMA 回调或任务也写同一个 RingBuffer，就已经不是这个模型，需要重新设计同步或拆成独立缓冲区。`volatile` 只影响编译器访问方式，不提供多生产者互斥。

本章 RingBuffer 满时选择丢新字节并增加 `ring_overflow`。覆盖旧数据会破坏 Parser 当前看到的字节顺序。ParserTask 发现 overflow 计数发生变化后，应放弃正在解析的候选帧并重新同步，因为输入流已经缺字节。

## 24.5 缓冲容量按最坏积压估算

115200 baud、8N1 时，一个 UART 字节在线路上占 10 bit。连续满速输入的理论字节率约为：

```text
115200 / 10 = 11520 byte/s
```

如果 ParserTask 最坏有 50 ms 没运行，期间可能积压约：

```text
11520 × 0.050 ≈ 576 byte
```

这个计算说明 64 或 128 字节缓冲无法覆盖这种假设。可以减少 ParserTask 的最长停顿、增大缓冲、启用 DMA/硬件流控，或者限制输入速率。

50 ms 只是估算条件，不是推荐任务周期。AT 模块还可能突发输出，因此最终要测目标固件在实际业务下的最大 burst 和 ParserTask 最长服务间隔，再结合 SRAM 余量确定容量。

## 24.6 Parser 按任意字节切分工作

用一个简单二进制帧说明状态机：

```text
A5 | 5A | type | length | payload[length] | crc8
              length = 0...32
```

Parser 保存跨调用状态：

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

处理规则包括：长度超过 payload 容量就拒绝；Payload 收满后再校验 CRC；半帧超时后复位；校验成功才产生事件。超时值由协议允许的帧间时序、波特率和调度延迟确定，不写成任意固定常数。

同一帧可以一次全部输入，也可以每次只输入一个字节。两个连续帧也可以在一次 ParserTask 运行中被连续解析。Parser 不依赖任务调度或 DMA 分块碰巧落在帧边界上。

## 24.7 错误后重新寻找帧头

CRC、长度或超时错误发生后，Parser 回到寻找 magic 的状态。等待 `0x5A` 时如果再次收到 `0xA5`，这个字节可能已经是下一候选帧的起点，可以继续保持 `FIND_5A`。

这种重同步只能在协议允许的规则内实现。如果 payload 本身可以任意包含 magic，解析器仍应以已经确认的 length 为主，不能在合法 Payload 中看到 `A5 5A` 就提前切帧。

RingBuffer overflow 的情况更直接：至少一个字节已经丢失，当前候选帧不能继续信任。复位 Parser，再从后续输入寻找新的合法帧头。

## 24.8 Adapter 负责协议语义转换

帧校验通过后，Adapter 再检查设备地址、类型、状态位和单位，并填充业务事件：

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

Queue 中保存事件副本，不保存 `frame->payload` 的地址。Parser 收下一帧时会覆盖内部数组，把指针异步交给消费者会产生生命周期错误。

如果线路协议使用另一套单位，也在 Adapter 转换成项目统一单位。MQTT、显示和日志任务随后只认识统一事件。

## 24.9 Queue 满时必须有固定策略

不同数据的丢弃语义不同。实时显示通常只关心最新状态，可以使用长度 1 的 Queue 配合 `xQueueOverwrite()`；历史日志要求保持顺序，需要选择丢新、丢旧或写入持久存储；控制命令无法接受静默丢失时，应返回 busy/error。

普通遥测若采用丢新策略：

```c
if (xQueueSend(gateway_queue, &event, 0U) != pdPASS)
    ++gateway_queue_drop_new;
```

网络离线几小时不能靠 RAM Queue 保存全部历史。需要这种能力时，把第 13 章的 NOR/SD 日志放到数据路径中，并定义重新上传后的去重规则。

## 24.10 一个物理 UART 只有一个软件所有者

两个任务不能同时操作同一个 USART、RingBuffer 或 AT 状态机。WiFi 和 BLE 若是独立模块，硬件允许时使用独立 UART；如果通过外部复用器或模式切换共用接口，要把当前模式和切换条件写进驱动状态机。

对于 AT 模块，接收端还可能同时出现命令响应、异步事件和业务 Payload。这些都应由同一个模块 Parser 先分类，再把事件交给上层，不能让不同任务各自在同一字节流里寻找自己的关键字。

这一所有权规则与第 17、18、23 章保持一致：业务任务提交请求，通信层独占实际 UART/AT 事务。

## 24.11 按层记录统计

可以为接收通路保留：

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

网络层另外记录 reconnect、publish failure、认证错误等指标。压力测试时，如果 `ring_overflow` 已经增加，随后出现的 CRC error 很可能只是上游丢字节的结果；先修接收积压，再判断 CRC 实现。

统计值最好是单调累计计数，并配合时间戳或采样周期查看增量。只打印“当前错误=3”而不知道它在一分钟内增加了多少，定位价值有限。

## 24.12 Parser 用回放输入测试

同一合法帧至少使用这些输入方式：

```c
FeedBytes(parser, frame, frame_len);

for (size_t i = 0; i < frame_len; ++i)
    FeedBytes(parser, frame + i, 1U);

FeedBytes(parser, frame, 3U);
FeedBytes(parser, frame + 3U, frame_len - 3U);
```

再测试噪声、错误 CRC、非法长度、半帧超时、连续两帧、`A5 A5 5A...` 和 overflow 后重同步。只要输入字节序列相同，不同切分方式最终产生的合法事件序列就应一致。

Queue 满单独测试。一个合法帧可以已经计入 `valid_frames`，随后因为 Queue 满增加 `event_drop`；这两个计数描述不同阶段，不要合成一个“收包失败”。

## 24.13 联调从 UART 往上开功能

硬件联调按下面顺序进行：

1. 先看 UART 字节数和 ORE/FE/NE/PE，确认波特率、接线和电气层；
2. 检查有限的十六进制输入样本和 RingBuffer overflow；
3. 开 Parser，只看 valid、bad CRC、bad length、timeout；
4. 开 Adapter，检查 `seq/source/type/length`；
5. 最后接 MQTT、HTTP、规则、显示和存储。

如果一种设备异常后整个网关都停住，检查 Parser 是否存在无界循环、驱动是否有无超时等待、共享锁是否持有过久，以及 Queue 是否使用无限阻塞发送。

## 24.14 本章完成标准

完成这些测试后，接收通路具备后续综合项目需要的边界：

- ISR 中没有协议解析或阻塞等待；
- RingBuffer 保持明确的单生产者/单消费者所有权；
- 容量根据目标波特率、最大 burst 和最长消费间隔估算并实测；
- Parser 能处理任意切分、连续帧、错误帧和半帧超时；
- overflow 后放弃损坏候选帧并重新同步；
- Queue 满有固定策略和独立计数；
- 单个协议或网络任务失败时，其他来源仍能继续产生事件；
- UART、Parser、Queue 和网络统计可以分别查看。

下一章开始做综合项目。这套 UART → Parser → Adapter → Event 通路继续复用，新设备只增加自己的协议实现和适配器。

> **上一章**：[第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
>
> **下一章**：[第 25 章 · 综合项目一：智能环境监测节点](./25-chapter.md)

# 第 18 章 · 温度记录仪 WiFi 版

这一章把传感器、FreeRTOS、AT 模块和 PC 网关接成一个完整数据链路。设备按固定周期采样，把结果放进 RAM Queue；网络任务独立维护 WiFi 和 TCP 连接，PC 收到数据后校验并写入 JSON Lines 日志。

先只接一种已经单独验证过的传感器跑通整条链路，再增加其他传感器。具体引脚、上拉、电源和 WiFi 模块命令都以开发板原理图和模块手册为准。

## 18.1 数据流先分清责任

```text
传感器
   ↓
SensorTask
   ↓ TempSample
 tx_queue
   ↓
WiFiTxTask
   ↓ UART / AT
WiFi 模块
   ↓ TCP
PC gateway
   ↓
temps.jsonl
```

`SensorTask` 只负责采样和入队，不等待网络。WiFi 断开时，由 `WiFiTxTask` 负责重新探测模块、加入 AP 和建立 TCP。Queue 满时执行预先定义的丢弃策略，并增加计数。

这样一条样本没到 PC 时，可以继续判断它是采集失败、Queue 满、AT 命令失败、TCP 断开，还是 PC 解析失败。第 16 章已经建立了 FreeRTOS Queue 的生产者/消费者边界，这里继续使用，不再额外实现一套应用层环形队列。

## 18.2 硬件先分别验证

下面只是常见连接示例，只有原理图确认后才能作为当前开发板配置：

- NTC 模拟输出 → PA1 / ADC1_IN1；
- DS18B20 数据 → PB0；
- DHT11 数据 → PB1；
- WiFi 模块 UART → USART2，默认 PA2/PA3。

STM32、传感器、WiFi 模块和调试 USB-TTL 要共地。WiFi 模块的工作电压、UART 电平和峰值供电能力查对应模块手册，不能从 STM32 GPIO 给无线模块供电。

DS18B20 和 DHT11 的数据线是否已经有上拉，取决于模块和开发板。接线后先分别运行单传感器实验，确认 timeout、CRC/校验错误和断线都有明确返回值，再放进 RTOS 项目。

## 18.3 TCP 上发送固定格式的数据包

不要直接发送 C `struct`。编译器 padding、字段对齐和主机字节序都可能改变线路格式。本章定义一个固定 18 字节的 v1 数据包：

```text
offset  size  field
0       2     magic: A5 5A
2       1     version: 1
3       1     status bits
4       4     sequence, little-endian
8       2     NTC, 0.01 C, little-endian signed
10      2     DS18B20, 0.01 C, little-endian signed
12      2     DHT11 temperature, 0.01 C, little-endian signed
14      2     DHT11 humidity, 0.1 %, little-endian unsigned
16      1     reserved: 0
17      1     CRC-8/MAXIM over bytes 0..16
```

`status` 中的位表示本次对应传感器数据是否有效。某个传感器读取失败时，数值字段可以保留 0，但 PC 只能在对应状态位有效时解释该数值。

```c
#include <stddef.h>
#include <stdint.h>

#define TEMP_PACKET_SIZE       18U
#define TEMP_PACKET_VERSION     1U

#define SAMPLE_NTC_OK  (1U << 0)
#define SAMPLE_DS_OK   (1U << 1)
#define SAMPLE_DHT_OK  (1U << 2)

static void put_u16_le(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void put_u32_le(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

typedef struct {
    uint32_t seq;
    uint8_t status;
    int16_t ntc_centi;
    int16_t ds_centi;
    int16_t dht_centi;
    uint16_t humidity_permille;
} TempSample;

uint8_t crc8_maxim(const uint8_t *data, size_t len);

void TempPacket_Encode(uint8_t out[TEMP_PACKET_SIZE],
                       const TempSample *sample)
{
    out[0] = 0xA5;
    out[1] = 0x5A;
    out[2] = TEMP_PACKET_VERSION;
    out[3] = sample->status;
    put_u32_le(out + 4, sample->seq);
    put_u16_le(out + 8, (uint16_t)sample->ntc_centi);
    put_u16_le(out + 10, (uint16_t)sample->ds_centi);
    put_u16_le(out + 12, (uint16_t)sample->dht_centi);
    put_u16_le(out + 14, sample->humidity_permille);
    out[16] = 0U;
    out[17] = crc8_maxim(out, 17U);
}
```

CRC-8/MAXIM 的 MCU 和 PC 实现必须先用同一组固定测试向量验证。教程里的多项式写法、初值和位序要保持一致，不能只看函数名字相同。

## 18.4 传感器接口返回状态

三个传感器统一返回错误状态：

```c
typedef enum {
    SENSOR_READ_OK,
    SENSOR_READ_TIMEOUT,
    SENSOR_READ_CRC_ERROR,
    SENSOR_READ_RANGE_ERROR
} SensorReadResult;

SensorReadResult NTC_ReadCenti(int16_t *value);
SensorReadResult DS18B20_ReadCenti(int16_t *value);
SensorReadResult DHT11_Read(int16_t *temperature,
                            uint16_t *humidity_permille);
```

NTC 不能拿一组没有来源的 ADC 阈值直接对应温度。需要知道分压固定电阻、NTC 标称阻值、B 值以及 ADC 参考电压，再计算阻值和温度。需要更高精度时还要做实测标定。

DS18B20 需要检查 presence、转换完成和 scratchpad CRC。转换时间取决于分辨率设置，等待逻辑按器件配置设置超时。DHT11 的每个电平等待阶段也要设置超时，并在读取 5 字节后检查校验和。

这些驱动继续使用前面章节已经验证过的硬件微秒时基，不重新用空循环估算微秒。

## 18.5 SensorTask 保持独立采样周期

```c
#include "FreeRTOS.h"
#include "queue.h"
#include "task.h"

#define SAMPLE_PERIOD_MS 1000U

static QueueHandle_t tx_queue;
static volatile uint32_t tx_queue_drops;

static void SensorTask(void *argument)
{
    TickType_t last_wake = xTaskGetTickCount();
    uint32_t seq = 0U;

    (void)argument;

    for (;;) {
        TempSample sample = {0};

        sample.seq = seq++;

        if (NTC_ReadCenti(&sample.ntc_centi) == SENSOR_READ_OK)
            sample.status |= SAMPLE_NTC_OK;

        if (DS18B20_ReadCenti(&sample.ds_centi) == SENSOR_READ_OK)
            sample.status |= SAMPLE_DS_OK;

        if (DHT11_Read(&sample.dht_centi,
                       &sample.humidity_permille) == SENSOR_READ_OK)
            sample.status |= SAMPLE_DHT_OK;

        if (xQueueSend(tx_queue, &sample, 0U) != pdPASS)
            ++tx_queue_drops;

        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(SAMPLE_PERIOD_MS));
    }
}
```

这里选择 Queue 满时丢弃新样本，保留已经排队的历史顺序。实时监控设备也可以选择丢最旧数据、保留最新值，但要把策略和统计一起改掉。

如果三路传感器顺序读取的最坏执行时间已经接近 1 秒，这个周期就没有余量。需要实际测量任务最长执行时间；DS18B20 这类转换时间较长的设备可以把“启动转换”和“读取结果”拆成两个阶段，避免整个任务一直等待。

## 18.6 WiFiTxTask 维护连接和待发送样本

第 17 章已经把 UART 字节解析成 AT 行、Payload 和异步事件。本章继续复用那套解析器，网络任务只调用业务层接口：

```c
typedef enum {
    RADIO_OK,
    RADIO_TIMEOUT,
    RADIO_COMMAND_ERROR,
    RADIO_DISCONNECTED
} RadioResult;

RadioResult Radio_Probe(void);
RadioResult Radio_JoinAp(void);
RadioResult Radio_OpenTcp(void);
RadioResult Radio_Send(const uint8_t *data, uint16_t len);
void Radio_ResetSession(void);
```

SSID、密码、服务器地址和端口放在独立配置中。公开仓库不要提交真实 WiFi 密码。

```c
typedef enum {
    NET_PROBE,
    NET_JOIN,
    NET_OPEN,
    NET_CONNECTED,
    NET_BACKOFF
} NetState;

#define NET_RETRY_MS 5000U

static volatile uint32_t radio_errors;
static volatile uint32_t send_errors;

static void WiFiTxTask(void *argument)
{
    NetState state = NET_PROBE;
    TempSample pending;
    bool have_pending = false;

    (void)argument;

    for (;;) {
        switch (state) {
        case NET_PROBE:
            if (Radio_Probe() == RADIO_OK)
                state = NET_JOIN;
            else
                state = NET_BACKOFF;
            break;

        case NET_JOIN:
            if (Radio_JoinAp() == RADIO_OK)
                state = NET_OPEN;
            else
                state = NET_BACKOFF;
            break;

        case NET_OPEN:
            if (Radio_OpenTcp() == RADIO_OK)
                state = NET_CONNECTED;
            else
                state = NET_BACKOFF;
            break;

        case NET_CONNECTED: {
            uint8_t packet[TEMP_PACKET_SIZE];

            if (!have_pending) {
                if (xQueueReceive(tx_queue, &pending,
                                  pdMS_TO_TICKS(500)) != pdPASS)
                    break;
                have_pending = true;
            }

            TempPacket_Encode(packet, &pending);

            if (Radio_Send(packet, sizeof packet) == RADIO_OK) {
                have_pending = false;
            } else {
                ++send_errors;
                Radio_ResetSession();
                state = NET_BACKOFF;
            }
            break;
        }

        case NET_BACKOFF:
            ++radio_errors;
            vTaskDelay(pdMS_TO_TICKS(NET_RETRY_MS));
            state = NET_PROBE;
            break;
        }
    }
}
```

5 秒只是本章的重试间隔。实际设备可以使用逐步增加的退避时间，并设置上限，避免 AP 长时间不可用时持续高频尝试。

网络任务只保留一份 `pending`。发送失败后，这份样本不会立刻丢掉，而是在重新连接后再次尝试。这样 PC 可能收到重复 `seq`，必须能够识别重复包。

`Radio_Send()` 返回成功只能说明模块接受了发送流程，具体能证明到哪一层取决于模块 AT 协议。即使 TCP 已经成功传输，也不能据此断言 PC 已经把该记录持久化。业务要求应用层确认时，需要服务器返回 ACK，并由设备在收到 ACK 后再释放 `pending`。

## 18.7 RAM Queue 只能处理短时断网

缓存时长取决于三个量：Queue 长度、采样周期和每次产生的样本数。若每个采样周期只入队一条：

```text
可缓存时长 ≈ queue_length × sample_period
```

例如 Queue 长度为 32、采样周期为 1 秒，在消费者完全停止时最多容纳约 32 秒的新样本；实际可用时间还受网络任务手里的 `pending` 和生产/消费时序影响。

RAM 占用也不能只算 `queue_length * sizeof(TempSample)`，FreeRTOS Queue 控制结构本身还需要额外内存。最终以链接 map、heap 使用量和运行时统计为准。

RAM Queue 不适合长时间离线保存。断网可能持续数小时，设备也可能掉电。需要保留历史时，把第 13 章的 NOR/SD 日志接成持久化离线队列；RAM Queue 只负责短时解耦。

## 18.8 PC 网关按 TCP 字节流解析

TCP 没有应用层消息边界。一次 `read()` 可能得到半包、一个完整包或多个包。网关应维护接收缓冲：先寻找 `A5 5A`，再等待完整 18 字节，验证 version 和 CRC；失败后继续寻找下一组 magic。

```c
static uint16_t get_u16_le(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_u32_le(const uint8_t *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

static int packet_valid(const uint8_t packet[TEMP_PACKET_SIZE])
{
    if (packet[0] != 0xA5 || packet[1] != 0x5A)
        return 0;

    if (packet[2] != TEMP_PACKET_VERSION)
        return 0;

    return crc8_maxim(packet, TEMP_PACKET_SIZE - 1U)
        == packet[TEMP_PACKET_SIZE - 1U];
}
```

`status` 某一位为 0 时，JSON 对应字段写 `null` 或单独记录错误状态，不能把该数值字段解释成真实测量值。

网关还要统计 CRC 错误、未知版本、序号缺口和重复序号。`socket()`、`bind()`、`listen()`、`accept()`、`read()` 和文件写入都检查返回值。入门实验可以先处理一个连接；需要同时支持多台设备时再增加 `poll`、`epoll` 或其他并发模型。

## 18.9 解析器先在 PC 本地测试

联网前准备固定测试向量：

- 正常数据包；
- CRC 错误包；
- 未知版本包；
- 两个连续合法包；
- 从任意位置切开的半包；
- 合法包前插入随机噪声。

把同一字节序列按单字节、随机块和整块三种方式喂给解析器，得到的有效包序列应一致。

例如：

```text
00 FF A5 5A ...bad crc...
13 37 A5 5A ...valid packet...
```

解析器应增加一次 bad-frame 计数，然后继续找到后面的合法包。这个测试不需要 STM32 和 WiFi 模块，可以先在 PC 上完成。

## 18.10 分阶段集成

按下面顺序接入：

1. 一种传感器 + USART1，每秒打印数值和状态。
2. 协议编码 + PC 测试，固定 18 字节样本在 MCU 和 PC 得到相同字段与 CRC。
3. FreeRTOS Queue，暂停消费者后验证满队列计数和 `seq` 缺口。
4. AT 模块，只完成探测、入网、TCP 建连和断线重试。
5. 端到端发送，PC 能记录 `seq`、status 和 CRC 结果。
6. 逐个增加其他传感器，单路故障不影响其他字段继续上报。
7. 断 AP、关闭 PC 网关、重启无线模块、制造传感器超时，检查错误计数和恢复过程。

每一步保存对应固件 commit、接线和一段可复现日志。出现问题时回到最后一个已经验证通过的阶段。

## 18.11 运行时统计

设备端至少记录：

```c
typedef struct {
    uint32_t sensor_timeout;
    uint32_t sensor_crc_error;
    uint32_t tx_queue_drops;
    uint32_t radio_command_error;
    uint32_t radio_timeout;
    uint32_t tcp_reconnect;
    uint32_t send_error;
} LoggerStats;
```

PC 端另外记录 `bad_crc`、`bad_version`、`seq_gap` 和 `duplicate_seq`。这些计数能把“数据没到”拆到采集、缓存、无线和服务器几层。

FreeRTOS 还要继续观察任务栈高水位和剩余 heap。WiFiTxTask 如果在栈上放较大的 AT 或发送缓冲，要把这部分纳入栈预算。

## 18.12 练习

1. 只接 DS18B20，分别制造 presence timeout 和 scratchpad CRC error，让 PC JSON 记录不同状态。
2. 把 `tx_queue` 长度改成 4，关闭 PC 网关 10 秒，观察 `tx_queue_drops` 和恢复后的序号。
3. 在线路协议中增加 32 位采样 tick，升级成 version 2，让旧网关明确拒绝未知版本。
4. 增加应用层 ACK。服务器写入成功后返回确认，设备收到对应 `seq` 的 ACK 才释放 `pending`。
5. 把 RAM Queue 前面接入第 13 章的持久化日志，使设备重启后仍能继续发送未确认样本。

完成这一章后，日志应该能说明某个样本是否采集成功、是否进入发送队列、网络失败在哪一步，以及 PC 是否看到重复或缺失序号。下一章把通信方式换成 BLE，采样结构和大部分错误处理继续复用。

> **上一章**：[第 17 章 · 无线通信基础与 AT 模块](./17-chapter.md)
>
> **下一章**：[第 19 章 · 温度记录仪 BLE 版](./19-chapter.md)

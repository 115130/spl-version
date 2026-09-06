# 第 18 章 · 温度记录仪 WiFi 版

这一章把前面的传感器、FreeRTOS、AT 模块和 PC 网络程序接成一个项目。系统每秒产生一份温湿度样本，先放进 RAM 队列；网络任务建立 TCP 连接后把样本发给电脑，电脑校验并写入 JSON Lines 日志。

项目先使用一种已经单独验证过的传感器跑通全链路，再增加其他传感器。具体引脚、上拉和 WiFi 模块供电以开发板原理图和模块手册为准。

## 18.1 数据流和故障边界

本章的数据流是：

```text
NTC / DS18B20 / DHT11
          ↓
      SensorTask
          ↓ TempPacket
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

`SensorTask` 不等待网络。WiFi 断开时，网络任务负责重连；队列装满后按照明确策略丢数据并增加计数。这样可以区分“传感器读取失败”“本地积压”“AT 失败”和“TCP 连接失败”。

第 16 章已经使用 FreeRTOS Queue 建立生产者/消费者边界，这里继续沿用。无需再实现一套带 `volatile head/tail` 的环形缓冲区。

## 18.2 硬件先分别验证

示例可以使用下面的连接，但只有原理图确认后才能把它当成当前板卡配置：

- NTC 模拟输出 → PA1 / ADC1_IN1；
- DS18B20 数据 → PB0；
- DHT11 数据 → PB1；
- WiFi 模块 UART → USART2，默认 PA2/PA3。

传感器、STM32、WiFi 模块和调试 USB-TTL 必须有共同的逻辑参考地。WiFi 模块的工作电压、UART 电平和峰值供电能力查模块手册；不要从 STM32 GPIO 给无线模块供电。

DS18B20 和 DHT11 的数据线是否已经带上拉取决于模块和开发板。接线后先分别运行单传感器实验，确认超时、CRC/校验错误和断线都能返回错误状态，再放进 RTOS 项目。

## 18.3 线路协议不要直接发送 C struct

TCP 传输使用固定 18 字节的 v1 数据包：

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

`status` 的每一位表示对应传感器本次数据是否有效。这样传感器超时时不需要伪造 `25 C`、`0 C` 或其他看起来正常的数值。

协议序列化应逐字段写字节：

```c
#include <stddef.h>
#include <stdint.h>

#define TEMP_PACKET_SIZE 18U
#define TEMP_PACKET_VERSION 1U

#define SAMPLE_NTC_OK   (1U << 0)
#define SAMPLE_DS_OK    (1U << 1)
#define SAMPLE_DHT_OK   (1U << 2)

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

这里没有 `#pragma pack`，也没有把 struct 地址直接交给 UART。协议的字节序和长度由代码明确生成，换编译器后不会因为 padding 改变线路格式。

CRC-8/MAXIM 的反射多项式可以写成 `0x8C`，初值为 0。MCU 和 PC 应用同一组测试字节计算 CRC，结果一致后再开始联网。

## 18.4 传感器接口要返回状态

三个传感器统一使用“状态 + 输出参数”的形式：

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

NTC 的 ADC 码值不能使用一组没有来源的阈值直接换算温度。先确认分压电路中的固定电阻、NTC 标称阻值和 B 值，再根据实际 VDDA/参考电压计算电阻和温度；精度要求较高时还要做实测标定。

DS18B20 读取时应检查 presence、转换完成和 scratchpad CRC。转换时间与分辨率有关，等待策略按器件配置设置超时。第 7 章已经提供硬件微秒时基，不要重新用 `for (...) __NOP()` 猜微秒延时。

DHT11 同样使用硬件微秒时基，并给每个等待电平的阶段设置超时。读取 5 字节后检查校验和；任何阶段失败都返回状态，不沿用上一次读数冒充本次成功。

## 18.5 SensorTask：每秒产生一份完整样本

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

如果三路传感器顺序读取的最坏执行时间接近或超过 1 秒，任务就无法维持这个周期。应实际测量一次循环的最长执行时间；需要更严格的采样时间时，可以拆任务或把 DS18B20 的“启动转换”和“读取结果”做成非阻塞状态机。

## 18.6 网络任务维护连接状态

第 17 章已经把 UART 字节解析成 AT 行、Payload 和异步事件。本章的 WiFi 层继续使用那套解析器，不再清空全局 RX 字符串后用 `strstr()` 等响应。

模块命令取决于实际 AT 固件。下面只定义业务层需要的接口：

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

SSID、密码、服务器地址和端口放进单独配置，不写死在任务函数里。仓库公开时也不要提交真实 WiFi 密码。

网络任务可以使用简单状态机：

```c
typedef enum {
    NET_PROBE,
    NET_JOIN,
    NET_OPEN,
    NET_CONNECTED,
    NET_BACKOFF
} NetState;

static volatile uint32_t radio_errors;
static volatile uint32_t send_errors;

static void WiFiTxTask(void *argument)
{
    NetState state = NET_PROBE;
    TempSample pending;
    bool have_pending = false;
    TickType_t retry_at = 0U;

    (void)argument;

    for (;;) {
        switch (state) {
        case NET_PROBE:
            state = (Radio_Probe() == RADIO_OK) ? NET_JOIN : NET_BACKOFF;
            break;

        case NET_JOIN:
            state = (Radio_JoinAp() == RADIO_OK) ? NET_OPEN : NET_BACKOFF;
            break;

        case NET_OPEN:
            state = (Radio_OpenTcp() == RADIO_OK) ? NET_CONNECTED : NET_BACKOFF;
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
            retry_at = xTaskGetTickCount() + pdMS_TO_TICKS(5000);
            state = NET_PROBE;
            vTaskDelayUntil(&retry_at, 1U);
            break;
        }
    }
}
```

上面的 5 秒退避是实验策略，可以根据网络环境调整。实际代码更适合把退避截止时间作为状态数据，而不是在复杂网络状态机中加入更多阻塞延时。

这里保留一份 `pending`，只有 `Radio_Send()` 成功后才从网络任务视角确认该样本完成。如果连接在发送期间断开，这一份样本可以在重连后再次发送，因此 PC 端必须用 `seq` 识别重复包。TCP 本身不能告诉应用层“服务器已经持久化了这一条记录”；如果业务要求 exactly-once，需要额外设计 ACK 和持久化协议，本章不做这个保证。

## 18.7 RAM 能缓存多久要算出来

假设 `tx_queue` 长度为 256，每秒产生 1 份 `TempSample`，网络最多可以积压约 256 秒。Queue 本身还会有 FreeRTOS 管理开销，实际 RAM 占用也不只等于 `256 * sizeof(TempSample)`。

256 秒不是可靠的离线存储。断网时间可能更长，MCU 也可能掉电。需要保存较长历史时，把第 13 章的 NOR/SD 日志作为离线队列；RAM Queue 只负责短时解耦。

队列满时必须确定策略。本章选择丢弃新样本并增加 `tx_queue_drops`，这样已经排队的历史顺序不变。实时监控项目也可以选择丢最旧数据、优先保留最新值，但协议和统计要跟着修改。

## 18.8 PC 网关按 TCP 字节流解析

TCP 的一次 `read()` 可能返回半包、一个包或多个包。网关需要维护解析状态，先找 `A5 5A`，再收满 18 字节并验证 version 和 CRC；失败后继续寻找下一组 magic。

多字节字段逐字节解码：

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
```

网关收到一帧后先验证：

```c
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

`status` 某一位为 0 时，JSON 中对应传感器应记录为 `null` 或单独输出状态，不能把未初始化的数值写成真实温度。网关还应统计 CRC 错误、版本错误、序号跳变和重复序号。

服务器代码的 `socket()`、`setsockopt()`、`bind()`、`listen()`、`accept()`、`read()` 和日志文件写入都要检查返回值。教程里可以先做单连接阻塞服务器；需要同时接多台设备时，再引入 `poll`/`epoll` 或多线程模型。

## 18.9 先在本机测试网关解析器

联网前先保存几组固定测试向量：正常包、CRC 错包、未知版本包、两个连续包，以及从任意位置切开的半包。把同一串字节按 1 字节、随机块和整块三种方式喂给解析器，得到的有效包序列应该一致。

还要加入噪声和重同步测试：

```text
00 FF A5 5A ...bad crc...
13 37 A5 5A ...valid packet...
```

解析器应增加一次 bad-frame 计数，并继续找到后面的合法包。这个测试不需要 STM32 和 WiFi 模块，可以先在 PC 上完成。

## 18.10 分阶段把硬件接进来

项目按下面顺序集成：

1. **一种传感器 + USART1**：每秒输出一次值和错误状态。
2. **协议编码 + PC 单元测试**：MCU 与 PC 对固定 18 字节样本得到相同 CRC 和字段值。
3. **FreeRTOS Queue**：故意暂停消费者，确认队列满计数和序号缺口符合设计。
4. **AT 模块**：只做探测、入网、TCP 连接和重连，不接传感器数据。
5. **端到端发送**：每次只发送一份 `TempSample`，PC 能记录序号和状态。
6. **增加其余传感器**：逐个接入，某一路断开时其他数据继续上报。
7. **长时间和故障测试**：断 AP、关闭 PC 网关、重启无线模块、制造传感器超时，观察错误计数和恢复过程。

每一步保存固件 commit、接线和一段可复现日志。出现问题时先回到最后一个通过的阶段。

## 18.11 运行时至少记录这些计数

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

PC 端另外记录 `bad_crc`、`bad_version`、`seq_gap` 和 `duplicate_seq`。这些计数能把“数据没到”拆成采集、缓存、无线和服务器几个位置。

FreeRTOS 部分继续检查任务栈高水位和剩余 heap。WiFiTxTask 里如果保留较大的 AT/发送缓冲，栈和静态 RAM 都要计入预算，不能只看 `TempSample` 队列本身。

## 18.12 练习

1. 只接 DS18B20，构造 presence timeout 和 scratchpad CRC error，在 PC JSON 中分别记录状态。
2. 把 `tx_queue` 长度改成 4，关闭 PC 网关 10 秒，确认 `tx_queue_drops` 增长，并说明恢复后最早能看到哪个序号。
3. 给线路协议增加 32 位采样 tick，升级为 version 2；让旧网关明确拒绝未知版本。
4. 给网络协议增加应用层 ACK。只有收到服务器对 `seq` 的确认后才释放 `pending`，然后测试“服务器收到数据后立即断线”的重复发送情况。
5. 把 RAM Queue 前面接入第 13 章的持久化日志，使设备重启后仍能继续发送未确认样本。

完成这一章后，项目应该能在日志里回答：某个样本是否采集成功、是否进入发送队列、网络在哪一步失败，以及 PC 是否收到重复或缺失序号。下一章把通信层换成 BLE，传感器和样本结构继续复用。

> **上一章**：[第 17 章 · 无线通信基础与 AT 模块](./17-chapter.md)
>
> **下一章**：[第 19 章 · 温度记录仪 BLE 版](./19-chapter.md)

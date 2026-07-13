# 第 18 章 · 温度记录仪 WiFi 版

> **前置知识**：第 8 章 UART、第 9 章 ADC、第 14–17 章 FreeRTOS 与 AT 模块；建议先单独完成每个传感器的最小实验。
>
> **硬件边界**：传感器、WiFi 模块、USB-TTL 与 ZET6 必须共地；WiFi 模块电源的峰值能力单独确认。先用 UART 日志验证每一层，再接入下一层。
>
> **通过标准**：不是“所有功能都亮”，而是每个里程碑都有一份可复现接线、日志和错误计数。

> **本章产出**：一个分层的多传感器温度记录仪教材项目——NTC + DS18B20 + DHT11 三路采集，SRAM 缓存，满 256 包通过 WiFi 发到电脑上的 C 网关程序
>
> **用到前面的知识**：ADC（Ch9）、UART（Ch8）、FreeRTOS 多任务（Ch14-16）、AT 指令（Ch17）

---

## 18.1 项目架构

```
┌─────────────── STM32 ─────────────────────┐
│                                            │
│  NTC (PA1·ADC1)         每 1 秒采样        │
│  DS18B20 (PB0·OneWire)  ──→ RingBuffer     │
│  DHT11 (PB1·单总线)     (256 个包缓存)      │
│                               ↓ 满 256 包   │
│                             WiFi TCP 发送   │
│                           DX-WF24 (USART2)  │
└──────────────────────┬─────────────────────┘
                       │ TCP :8888
┌──────────────────────▼─────────────────────┐
│  PC 网关 (gateway.c)                       │
│  ./gateway [port] [log.jsonl]              │
│  → 终端显示 [彩色]                          │
│  → 追加 JSON Lines 日志                     │
└────────────────────────────────────────────┘
```

**三个 FreeRTOS 任务**：

| 任务 | 优先级 | 做的事 |
|------|--------|--------|
| `SensorTask` | 3 | 每秒读三路传感器 → 打包 → 入 RingBuffer |
| `WiFiTxTask` | 2 | 监视 RingBuffer，满 256 包 → TCP 发送 |

生产者-消费者模式：SensorTask（高优先级）只管采，WiFiTxTask 管发。即使 WiFi 卡住，采样不丢。

## 18.2 硬件接线

| 传感器 | 信号 | STM32 引脚 | 协议 |
|--------|------|-----------|------|
| NTC（板载 ADC 模块） | 模拟电压 | **PA1** (ADC1_IN1) | ADC 单通道 |
| DS18B20（裸露 TO‑92，插板载座） | 数据 | **PB0** | OneWire |
| DHT11（带小 PCB 板，接座子） | 数据 | **PB1** | 单总线 |
| DX-WF24 | UART TX/RX | **PA2/PA3** (USART2) | 115200, 8N1 |

DS18B20 与 DHT11 模块的插座排列、上拉电阻和供电方式取决于你手上的开发板或扩展板。先看丝印、原理图或用万用表确认；若数据线没有被模块/板卡可靠上拉，需按器件手册加入合适的上拉电阻。不要把某块板的“自带 4.7kΩ”当作 ZET6 的通用事实。

## 18.3 二进制有线协议

每包固定 15 字节，省流量、易解析：

```
偏移  大小  字段          说明
0     2    Magic (0xA5A5)   包识别头
2     4    Sequence (LE)    序号（发现丢包）
6     2    NTC 温度         毫摄氏度，2530 = 25.30°C
8     2    DS18B20 温度
10    2    DHT11 温度
12    2    DHT11 湿度       千分比，523 = 52.3%
14    1    CRC8             校验（Dallas 1-Wire 算法）
```

CRC8 校验确保每个包的数据完整性。

`protocol.h`：

```c
#ifndef __PROTOCOL_H
#define __PROTOCOL_H

#include <stdint.h>

#define PKG_MAGIC_HI     0xA5
#define PKG_MAGIC_LO     0xA5
#define PKG_SIZE         15

#pragma pack(push, 1)
typedef struct {
    uint8_t  magic[2];      /* 0xA5A5 */
    uint32_t seq;
    int16_t  ntc_mdeg;
    int16_t  ds18b20_mdeg;
    int16_t  dht11_mdeg;
    uint16_t dht11_hum;
    uint8_t  crc8;
} TempPacket;               /* 总共 15 字节 */
#pragma pack(pop)

uint8_t crc8_compute(const uint8_t *data, int len);
void packet_fill(TempPacket *pkt, uint32_t seq,
                 int16_t ntc_mdeg, int16_t ds18b20_mdeg,
                 int16_t dht11_mdeg, uint16_t dht11_hum);
int packet_verify(const TempPacket *pkt);

#endif
```

`protocol.c`（CRC8 + 打包）：

```c
#include "protocol.h"

/* Dallas/Maxim CRC-8：正常多项式 0x31，按最低位优先时使用 0x8C。
   这里故意采用位运算而非不完整的查表，便于读者逐步验证。 */
uint8_t crc8_compute(const uint8_t *data, int len)
{
    uint8_t crc = 0;

    for (int i = 0; i < len; ++i) {
        crc ^= data[i];
        for (uint8_t bit = 0; bit < 8; ++bit) {
            if (crc & 0x01)
                crc = (uint8_t)((crc >> 1) ^ 0x8C);
            else
                crc >>= 1;
        }
    }
    return crc;
}

void packet_fill(TempPacket *pkt, uint32_t seq,
                 int16_t ntc_mdeg, int16_t ds18b20_mdeg,
                 int16_t dht11_mdeg, uint16_t dht11_hum)
{
    pkt->magic[0]    = PKG_MAGIC_HI;
    pkt->magic[1]    = PKG_MAGIC_LO;
    pkt->seq         = seq;
    pkt->ntc_mdeg    = ntc_mdeg;
    pkt->ds18b20_mdeg = ds18b20_mdeg;
    pkt->dht11_mdeg  = dht11_mdeg;
    pkt->dht11_hum   = dht11_hum;
    pkt->crc8        = crc8_compute((uint8_t *)pkt, PKG_SIZE - 1);
}
```

---

## 18.4 PC 端网关（gateway.c）

电脑上跑一个 C 写的 TCP 服务器，接收并解码温度包。

```c
/*
 * gateway.c — 温度记录仪 PC 网关
 * 编译: gcc gateway.c -o gateway
 * 运行: ./gateway [端口] [日志文件]
 *       默认 8888, temps.jsonl
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>

#define PKG_SIZE      15
#define DEFAULT_PORT  8888

/* ===== CRC-8/MAXIM (Dallas 1-Wire) =====
 * 与 MCU 的 crc8_compute 使用相同的反射算法：normal poly 0x31，
 * reflected poly 0x8C，init=0。PC/MCU 必须对同一输入得到同一结果。 */
static uint8_t crc8_table[256];

static void crc8_init(void) {
    for (int i = 0; i < 256; ++i) {
        uint8_t crc = (uint8_t)i;
        for (int bit = 0; bit < 8; ++bit) {
            if (crc & 0x01)
                crc = (uint8_t)((crc >> 1) ^ 0x8C);
            else
                crc >>= 1;
        }
        crc8_table[i] = crc;
    }
}

static uint8_t crc8_calc(const uint8_t *d, int len) {
    uint8_t crc = 0;
    for (int i = 0; i < len; ++i)
        crc = crc8_table[crc ^ d[i]];
    return crc;
}

/* ===== 解码 ===== */
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8)
         | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}
static uint16_t rd16(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1]<<8);
}
static float mdeg_to_c(int16_t md) { return (float)md / 100.0f; }
static float permille_to_pct(uint16_t p) { return (float)p / 10.0f; }

/* ===== 日志 ===== */
static FILE *log_fp = NULL;
static volatile int running = 1;

static void sigint_handler(int sig) { (void)sig; running = 0; }

static void log_packet(uint32_t seq, int16_t ntc, int16_t ds,
                       int16_t dht_t, uint16_t dht_h)
{
    time_t now = time(NULL);
    struct tm *lt = localtime(&now);
    char tb[64];
    strftime(tb, sizeof(tb), "%H:%M:%S", lt);

    /* 终端彩色显示 */
    printf("\033[36m[#%04u]\033[0m \033[33m%s\033[0m  "
           "NTC=\033[92m%5.1f°C\033[0m  "
           "DS18B20=\033[92m%5.1f°C\033[0m  "
           "DHT11=\033[92m%5.1f°C\033[0m  H=\033[94m%4.1f%%\033[0m\n",
           (unsigned)seq, tb,
           mdeg_to_c(ntc), mdeg_to_c(ds),
           mdeg_to_c(dht_t), permille_to_pct(dht_h));

    if (!log_fp) return;
    /* JSON Lines */
    fprintf(log_fp,
        "{\"ts\":%ld,\"time\":\"%s\",\"seq\":%u,"
        "\"ntc\":%.1f,\"ds18b20\":%.1f,"
        "\"dht11_temp\":%.1f,\"dht11_hum\":%.1f}\n",
        (long)now, tb, (unsigned)seq,
        mdeg_to_c(ntc), mdeg_to_c(ds),
        mdeg_to_c(dht_t), permille_to_pct(dht_h));
    fflush(log_fp);
}

/* ===== 处理一个包 ===== */
static int handle_packet(const uint8_t *pkg) {
    if (pkg[0] != 0xA5 || pkg[1] != 0xA5) return -2;
    uint8_t calc = crc8_calc(pkg, PKG_SIZE-1);
    if (calc != pkg[PKG_SIZE-1]) {
        fprintf(stderr, "CRC 错误\n"); return -3;
    }
    log_packet(rd32(pkg+2), (int16_t)rd16(pkg+6),
               (int16_t)rd16(pkg+8), (int16_t)rd16(pkg+10), rd16(pkg+12));
    return 0;
}

/* ===== TCP 服务器 ===== */
int main(int argc, char **argv) {
    int port = DEFAULT_PORT;
    const char *log_path = "temps.jsonl";
    if (argc >= 2) port = atoi(argv[1]);
    if (argc >= 3) log_path = argv[2];

    crc8_init();
    signal(SIGINT, sigint_handler);
    log_fp = fopen(log_path, "a");
    if (!log_fp) { perror("fopen"); return 1; }

    printf("温度记录仪网关 v1.0\n 端口 %d  日志 %s\n等待设备连接...\n", port, log_path);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr = { .sin_family = AF_INET,
        .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY };
    bind(srv, (struct sockaddr*)&addr, sizeof(addr));
    listen(srv, 5);

    while (running) {
        struct sockaddr_in cli;
        socklen_t clen = sizeof(cli);
        int fd = accept(srv, (struct sockaddr*)&cli, &clen);
        if (fd < 0) break;

        char ip[64];
        inet_ntop(AF_INET, &cli.sin_addr, ip, sizeof(ip));
        printf("\n\033[1m[连接] %s:%d\033[0m\n", ip, ntohs(cli.sin_port));

        /* TCP 是字节流：一次 read 可能得到半帧、多帧或噪声后的字节。
           此处按 magic + 固定长度 + CRC 重同步，而不是每 15 字节硬切。 */
        typedef struct {
            uint8_t frame[PKG_SIZE];
            size_t used;
            uint32_t bad_frame;
        } PacketParser;

        PacketParser parser = {0};
        uint8_t buf[128];

        while (running) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n <= 0) break;

            for (ssize_t k = 0; k < n; ++k) {
                uint8_t ch = buf[k];

                if (parser.used == 0) {
                    if (ch == 0xA5) parser.frame[parser.used++] = ch;
                    continue;
                }
                if (parser.used == 1) {
                    if (ch == 0xA5) parser.frame[parser.used++] = ch;
                    else parser.used = 0;
                    continue;
                }

                parser.frame[parser.used++] = ch;
                if (parser.used != PKG_SIZE) continue;

                if (handle_packet(parser.frame) == 0) {
                    parser.used = 0;
                    continue;
                }

                /* CRC 错后，在已收字节中寻找最后一个 A5 A5；
                   保留其后的候选数据，下一字节继续重同步。 */
                parser.bad_frame++;
                size_t restart = PKG_SIZE;
                for (size_t i = 1; i + 1 < PKG_SIZE; ++i) {
                    if (parser.frame[i] == 0xA5 &&
                        parser.frame[i + 1] == 0xA5) {
                        restart = i;
                    }
                }
                if (restart < PKG_SIZE) {
                    memmove(parser.frame, parser.frame + restart,
                            PKG_SIZE - restart);
                    parser.used = PKG_SIZE - restart;
                } else if (parser.frame[PKG_SIZE - 1] == 0xA5) {
                    parser.frame[0] = 0xA5;
                    parser.used = 1;
                } else {
                    parser.used = 0;
                }
            }
        }

        if (parser.bad_frame)
            fprintf(stderr, "本连接丢弃 %u 个错误帧\n",
                    (unsigned)parser.bad_frame);
        printf("\033[31m[断开] %s:%d\033[0m\n", ip, ntohs(cli.sin_port));
        close(fd);
    }
    close(srv); fclose(log_fp);
    return 0;
}
```

```bash
# 编译 & 运行
gcc gateway.c -o gateway -Wall
./gateway              # 端口 8888，日志 temps.jsonl
./gateway 9999 data.jsonl  # 自定义端口和路径
```

### 效果

终端显示：
```
[#0042] 14:32:05  NTC=25.3°C  DS18B20=26.1°C  DHT11=24.8°C  H=52.3%
```

日志文件 `temps.jsonl`：
```json
{"ts":1720160000,"time":"14:32:05","seq":42,"ntc":25.3,"ds18b20":26.1,"dht11_temp":24.8,"dht11_hum":52.3}
```

用 Python 做后续分析：
```python
import json
with open("temps.jsonl") as f:
    for line in f:
        p = json.loads(line)
        print(p["seq"], p["ntc"], p["ds18b20"])
```

---

## 18.5 传感器驱动

### NTC（PA1·ADC1）

NTC 热敏电阻通过板载 ADC 模块接到 PA1，用 ADC1 通道 1 读电压值，查预计算的阈值表得温度。

`sensors/ntc.h`：

```c
#ifndef __NTC_H
#define __NTC_H
#include <stdint.h>
void NTC_Init(void);
int16_t NTC_Read_mdeg(void);   /* 毫摄氏度 */
#endif
```

`sensors/ntc.c`：

```c
#include "ntc.h"
#include "stm32f10x.h"

/* 阈值表：ADC 值 ≥ 阈值 → 返回对应温度（毫摄氏度）*/
static const uint16_t thr[] = { 3500,3000,2500,2300,2100,1900,1700,1500,1200,1000,0 };
static const int16_t  tmp[] = { -100, 50,  150, 200, 250, 300, 350, 400, 500, 600, 250 };

void NTC_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA|RCC_APB2Periph_ADC1, ENABLE);
    GPIO_InitTypeDef g = { GPIO_Pin_1, GPIO_Speed_50MHz, GPIO_Mode_AIN };
    GPIO_Init(GPIOA, &g);
    ADC_InitTypeDef a;
    ADC_StructInit(&a);
    a.ADC_Mode = ADC_Mode_Independent; a.ADC_ScanConvMode = DISABLE;
    a.ADC_ContinuousConvMode = DISABLE; a.ADC_ExternalTrigConv = ADC_ExternalTrigConv_None;
    a.ADC_DataAlign = ADC_DataAlign_Right; a.ADC_NbrOfChannel = 1;
    ADC_Init(ADC1, &a);
    ADC_RegularChannelConfig(ADC1, ADC_Channel_1, 1, ADC_SampleTime_239Cycles5);
    ADC_Cmd(ADC1, ENABLE);
    ADC_ResetCalibration(ADC1); while (ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1); while (ADC_GetCalibrationStatus(ADC1));
}

int16_t NTC_Read_mdeg(void) {
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);
    while (!ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC));
    uint16_t adc = ADC_GetConversionValue(ADC1);
    for (int i = 0; i < (int)(sizeof(thr)/sizeof(thr[0])); i++)
        if (adc >= thr[i]) return tmp[i];
    return 250;
}
```

### DS18B20（PB0·OneWire）

OneWire 协议由 MCU 精确控制时序。

`sensors/ds18b20.h`：

```c
#ifndef __DS18B20_H
#define __DS18B20_H
#include <stdint.h>
void DS18B20_Init(void);
int16_t DS18B20_Read_mdeg(void);
#endif
```

`sensors/ds18b20.c`：

```c
#include "ds18b20.h"
#include "stm32f10x.h"

#define PIN  GPIO_Pin_0
#define PORT GPIOB

static void delay_us(uint32_t us) {
    for (uint32_t i = 0; i < us * 9; i++) __NOP();
}
static void out(void) {
    GPIO_InitTypeDef g = { PIN, GPIO_Speed_50MHz, GPIO_Mode_Out_OD };
    GPIO_Init(PORT, &g);
}
static void in(void) {
    GPIO_InitTypeDef g = { PIN, GPIO_Speed_50MHz, GPIO_Mode_IN_FLOATING };
    GPIO_Init(PORT, &g);
}
static void wr_bit(int b) {
    out(); GPIO_WriteBit(PORT, PIN, Bit_RESET);
    delay_us(b ? 5 : 80);
    GPIO_WriteBit(PORT, PIN, Bit_SET);
    delay_us(b ? 65 : 10);
    in();
}
static int rd_bit(void) {
    out(); GPIO_WriteBit(PORT, PIN, Bit_RESET); delay_us(2);
    in(); delay_us(5);
    int b = GPIO_ReadInputDataBit(PORT, PIN) != Bit_RESET;
    delay_us(55);
    return b;
}
static void wr_byte(uint8_t d) {
    for (int i = 0; i < 8; i++) { wr_bit(d & 1); d >>= 1; }
}
static uint8_t rd_byte(void) {
    uint8_t d = 0;
    for (int i = 0; i < 8; i++) { d >>= 1; if (rd_bit()) d |= 0x80; }
    return d;
}
static int reset(void) {
    out(); GPIO_WriteBit(PORT, PIN, Bit_RESET); delay_us(500);
    in(); delay_us(70);
    int p = GPIO_ReadInputDataBit(PORT, PIN) == Bit_RESET;
    delay_us(430);
    return p;
}

void DS18B20_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
    out(); GPIO_WriteBit(PORT, PIN, Bit_SET);
}

int16_t DS18B20_Read_mdeg(void) {
    if (!reset()) return 2500;
    wr_byte(0xCC); wr_byte(0x44);        /* Start conversion */
    for (int i = 0; i < 100; i++) { delay_us(10000); if (rd_bit()) break; }
    if (!reset()) return 2500;
    wr_byte(0xCC); wr_byte(0xBE);        /* Read scratchpad */
    int16_t raw = (int16_t)((rd_byte() | (rd_byte() << 8)));
    return (int16_t)((int32_t)raw * 625 / 100);  /* 转毫摄氏度 */
}
```

### DHT11（PB1·单总线）

`sensors/dht11.h`：

```c
#ifndef __DHT11_H
#define __DHT11_H
#include <stdint.h>
void DHT11_Init(void);
int DHT11_Read(int16_t *temp_mdeg, uint16_t *hum_permille);
/* 返回 0=成功，-1=超时，-2=校验和错 */
#endif
```

`sensors/dht11.c`：

```c
#include "dht11.h"
#include "stm32f10x.h"

#define PIN  GPIO_Pin_1
#define PORT GPIOB

static void delay_us(uint32_t us) {
    for (uint32_t i = 0; i < us * 9; i++) __NOP();
}
static void out(void) {
    GPIO_InitTypeDef g = { PIN, GPIO_Speed_50MHz, GPIO_Mode_Out_OD };
    GPIO_Init(PORT, &g);
}
static void in(void) {
    GPIO_InitTypeDef g = { PIN, GPIO_Speed_50MHz, GPIO_Mode_IN_FLOATING };
    GPIO_Init(PORT, &g);
}
static int wait(int level, uint32_t timeout) {
    while (timeout--) {
        if ((GPIO_ReadInputDataBit(PORT, PIN) != Bit_RESET) == level)
            return 1;
        delay_us(1);
    }
    return 0;
}
static uint8_t rd_byte(void) {
    uint8_t d = 0;
    for (int i = 0; i < 8; i++) {
        wait(0, 100); delay_us(35);
        d = (d << 1) | (GPIO_ReadInputDataBit(PORT, PIN) != Bit_RESET);
        wait(1, 100);
    }
    return d;
}

void DHT11_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
    out(); GPIO_WriteBit(PORT, PIN, Bit_SET);
}

int DHT11_Read(int16_t *t, uint16_t *h) {
    out(); GPIO_WriteBit(PORT, PIN, Bit_RESET); delay_us(20000);
    GPIO_WriteBit(PORT, PIN, Bit_SET); delay_us(30);
    in();
    if (!wait(0, 200) || !wait(1, 200)) return -1;
    uint8_t b[5];
    for (int i = 0; i < 5; i++) b[i] = rd_byte();
    if ((uint8_t)(b[0]+b[1]+b[2]+b[3]) != b[4]) return -2;
    *h = (uint16_t)b[0] * 10;   /* 千分比 */
    int16_t tmp = (int16_t)b[2] * 1000;
    if (b[2] & 0x80) tmp = -(int16_t)(b[2] & 0x7F) * 1000;
    *t = tmp;
    return 0;
}
```

---

## 18.6 环形缓冲区

```c
/* ringbuf.h */
#ifndef __RINGBUF_H
#define __RINGBUF_H
#include "protocol.h"

#define RINGBUF_CAPACITY  256

typedef struct {
    TempPacket  pkgs[RINGBUF_CAPACITY];
    volatile uint16_t head, tail;
} RingBuffer;

void     RingBuf_Init(RingBuffer *rb);
int      RingBuf_Push(RingBuffer *rb, const TempPacket *pkt);
int      RingBuf_Pop(RingBuffer *rb, TempPacket *pkt);
uint16_t RingBuf_Count(const RingBuffer *rb);

#endif
```

```c
/* ringbuf.c */
#include "ringbuf.h"

void RingBuf_Init(RingBuffer *rb) { rb->head = rb->tail = 0; }

int RingBuf_Push(RingBuffer *rb, const TempPacket *pkt) {
    uint16_t n = (rb->head + 1) % RINGBUF_CAPACITY;
    if (n == rb->tail) return -1;
    rb->pkgs[rb->head] = *pkt;
    rb->head = n;
    return 0;
}

int RingBuf_Pop(RingBuffer *rb, TempPacket *pkt) {
    if (rb->tail == rb->head) return -1;
    *pkt = rb->pkgs[rb->tail];
    rb->tail = (rb->tail + 1) % RINGBUF_CAPACITY;
    return 0;
}

uint16_t RingBuf_Count(const RingBuffer *rb) {
    return (rb->head - rb->tail) % RINGBUF_CAPACITY;
}
```

256 × 15 字节 = 不到 4KB SRAM。ZET6 有 64KB，绰绰有余。

---

## 18.7 WiFi AT 封装

AT 指令的底层 UART 收发（`UART2_Init`、`AT_SendCmd`、`AT_WaitResponse`）在第 18.8 节的 `main.c` 教学骨架中展示；这里仅讨论上层封装。实际工程仍须按所选模块与构建环境验证。

`sensors/wifi.h`：

```c
#ifndef __WIFI_H
#define __WIFI_H
#include <stdint.h>

void WiFi_Init(void);
int  WiFi_Connect(const char *ssid, const char *password);
int  WiFi_TCPConnect(const char *ip, uint16_t port);
int  WiFi_SendBinary(const uint8_t *data, uint16_t len);

/* AT 函数由 main.c 提供 */
extern void AT_SendCmd(const char *cmd);
extern void AT_ClearRxBuf(void);
extern int  AT_WaitResponse(const char *expect, uint32_t timeout_ms);

#endif
```

`sensors/wifi.c`：

```c
#include "wifi.h"
#include <stdio.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"

#define RETRY 3

void WiFi_Init(void) {
    vTaskDelay(pdMS_TO_TICKS(2000));
    for (int i = 0; i < RETRY; i++) {
        AT_ClearRxBuf(); AT_SendCmd("AT");
        if (AT_WaitResponse("OK", 3000)) return;
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

int WiFi_Connect(const char *ssid, const char *password) {
    char cmd[128];
    AT_ClearRxBuf(); AT_SendCmd("AT+CWMODE=1");
    AT_WaitResponse("OK", 2000);
    snprintf(cmd, sizeof(cmd), "AT+CWJAP=\"%s\",\"%s\"", ssid, password);
    for (int i = 0; i < RETRY; i++) {
        AT_ClearRxBuf(); AT_SendCmd(cmd);
        if (AT_WaitResponse("WIFI GOT IP", 15000)) return 0;
    }
    return -1;
}

int WiFi_TCPConnect(const char *ip, uint16_t port) {
    char cmd[64];
    snprintf(cmd, sizeof(cmd), "AT+CIPSTART=\"TCP\",\"%s\",%d", ip, port);
    for (int i = 0; i < RETRY; i++) {
        AT_ClearRxBuf(); AT_SendCmd(cmd);
        if (AT_WaitResponse("CONNECT", 10000)) return 0;
    }
    return -1;
}

int WiFi_SendBinary(const uint8_t *data, uint16_t len) {
    char cmd[32];
    snprintf(cmd, sizeof(cmd), "AT+CIPSEND=%d", len);
    AT_ClearRxBuf(); AT_SendCmd(cmd);
    if (!AT_WaitResponse(">", 5000)) return -1;
    for (uint16_t i = 0; i < len; i++) {
        while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET);
        USART_SendData(USART2, data[i]);
    }
    return AT_WaitResponse("SEND OK", 10000) ? 0 : -1;
}
```

---

## 18.8 FreeRTOS 主程序（main.c）

```c
/*
 * 温度记录仪 main.c
 * FreeRTOS 任务: SensorTask(pri=3) + WiFiTxTask(pri=2)
 */

#include "stm32f10x.h"
#include <stdio.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"
#include "protocol.h"
#include "ringbuf.h"
#include "sensors/ntc.h"
#include "sensors/ds18b20.h"
#include "sensors/dht11.h"
#include "sensors/wifi.h"

#define SAMPLE_MS  1000
#define TX_THRESH  256

static RingBuffer tx_ring;
static uint32_t   pkt_seq = 0;

/* ====== UART2 (DX-WF24) AT 指令收发 ====== */
#define AT_BUF 512
static char at_buf[AT_BUF];
static volatile uint16_t at_idx = 0;

void USART2_IRQHandler(void) {
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t ch = USART_ReceiveData(USART2);
        if (at_idx < AT_BUF - 1) { at_buf[at_idx++] = ch; at_buf[at_idx] = '\0'; }
        USART_ClearITPendingBit(USART2, USART_IT_RXNE);
    }
}

void UART2_Init(uint32_t baud) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_USART2, ENABLE);
    GPIO_InitTypeDef g = { GPIO_Pin_2, GPIO_Speed_50MHz, GPIO_Mode_AF_PP };
    GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_3; g.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &g);
    USART_InitTypeDef u;
    USART_StructInit(&u);
    u.USART_BaudRate = baud; u.USART_Mode = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART2, &u);
    USART_ITConfig(USART2, USART_IT_RXNE, ENABLE);
    NVIC_EnableIRQ(USART2_IRQn);
    USART_Cmd(USART2, ENABLE);
}
void AT_SendString(const char *s) {
    while (*s) { while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET); USART_SendData(USART2, *s++); }
}
void AT_SendCmd(const char *c) { AT_SendString(c); AT_SendString("\r\n"); }
void AT_ClearRxBuf(void) { taskENTER_CRITICAL(); at_idx = 0; memset(at_buf,0,AT_BUF); taskEXIT_CRITICAL(); }
int AT_WaitResponse(const char *exp, uint32_t ms) {
    uint32_t start = xTaskGetTickCount();
    while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(ms)) {
        vTaskDelay(pdMS_TO_TICKS(50));
        taskENTER_CRITICAL();
        int ok = !!strstr(at_buf, exp);
        int er = !!strstr(at_buf, "ERROR");
        taskEXIT_CRITICAL();
        if (ok) return 1; if (er) return 0;
    }
    return 0;
}

/* ====== USART1 调试串口 ====== */
void USART1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1|RCC_APB2Periph_GPIOA, ENABLE);
    GPIO_InitTypeDef g = { GPIO_Pin_9, GPIO_Speed_50MHz, GPIO_Mode_AF_PP };
    GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_10; g.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &g);
    USART_InitTypeDef u;
    USART_StructInit(&u); u.USART_BaudRate = 115200; u.USART_Mode = USART_Mode_Rx|USART_Mode_Tx;
    USART_Init(USART1, &u); USART_Cmd(USART1, ENABLE);
}
int fputc(int ch, FILE *f) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, (uint8_t)ch); return ch;
}

/* ====== SensorTask ====== */
void SensorTask(void *pv) {
    NTC_Init(); DS18B20_Init(); DHT11_Init();
    TickType_t last = xTaskGetTickCount();
    while (1) {
        vTaskDelayUntil(&last, pdMS_TO_TICKS(SAMPLE_MS));
        int16_t ntc = NTC_Read_mdeg();
        int16_t ds  = DS18B20_Read_mdeg();
        int16_t dt; uint16_t dh;
        DHT11_Read(&dt, &dh);
        TempPacket pkt;
        packet_fill(&pkt, ++pkt_seq, ntc, ds, dt, dh);
        if (RingBuf_Push(&tx_ring, &pkt) == 0)
            printf("S#%04u  NTC=%d  DS=%d  DHT=%d  H=%d%%\r\n",
                   (unsigned)pkt_seq, ntc/100, ds/100, dt/100, dh/10);
        else
            printf("缓冲区满!\r\n");
    }
}

/* ====== WiFiTxTask ====== */
void WiFiTxTask(void *pv) {
    TempPacket batch[TX_THRESH];
    UART2_Init(115200);
    WiFi_Init();
    while (WiFi_Connect("MyWiFi", "password") != 0) { vTaskDelay(pdMS_TO_TICKS(10000)); }
    while (WiFi_TCPConnect("192.168.1.100", 8888) != 0) { vTaskDelay(pdMS_TO_TICKS(10000)); }

    TickType_t last = xTaskGetTickCount();
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        uint16_t cnt = RingBuf_Count(&tx_ring);
        if (cnt == 0) continue;
        int tx = (cnt >= TX_THRESH) || ((xTaskGetTickCount()-last) >= pdMS_TO_TICKS(60000));
        if (!tx) continue;

        uint16_t n = 0;
        while (n < TX_THRESH && RingBuf_Pop(&tx_ring, &batch[n]) == 0) n++;
        printf("TX %d 包...\r\n", n);
        for (uint16_t i = 0; i < n; i++) {
            if (WiFi_SendBinary((uint8_t*)&batch[i], 15) != 0) {
                WiFi_TCPConnect("192.168.1.100", 8888);
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(100));
        }
        last = xTaskGetTickCount();
    }
}

/* ====== main ====== */
int main(void) {
    USART1_Init();
    RingBuf_Init(&tx_ring);
    printf("\r\n===== 温度记录仪 v1.0 =====\r\n");
    xTaskCreate(SensorTask, "Sensor", 256, NULL, 3, NULL);
    xTaskCreate(WiFiTxTask, "WiFiTx", 512, NULL, 2, NULL);
    vTaskStartScheduler();
    while (1);
}
```

---

## 18.9 编译与运行

### 项目文件清单

```
temp-logger/
├── main.c                    ← FreeRTOS 主程序（上面已完成）
├── gateway.c                 ← PC 网关（上面已完成）
├── Makefile                  ← 编译配置
├── link.ld                   ← 链接脚本（512KB Flash / 64KB SRAM）
├── startup_stm32f10x_hd.s    ← 启动文件
├── protocol.h  protocol.c    ← 二进制协议 + CRC8
├── ringbuf.h   ringbuf.c     ← 环形缓冲区
├── wifi.h      wifi.c        ← WiFi AT 封装
└── sensors/
    ├── ntc.h     ntc.c       ← NTC 热敏电阻
    ├── ds18b20.h ds18b20.c   ← DS18B20
    └── dht11.h   dht11.c     ← DHT11
```

### 编译步骤

```bash
# 1. 下载依赖（只在首次做）
# SPL 库: ST 官网 STM32F10x_StdPeriph_Lib_V3.5.0
# FreeRTOS: FreeRTOS.org 下载 Source/ 目录

# 2. 编辑 Makefile 开头的路径
#    FREERTOS_DIR = ../FreeRTOS
#    SPL_DIR      = ../STM32F10x_StdPeriph_Lib

# 3. 编译
make           # → temp-logger.bin

# 4. 烧录
make flash     # OpenOCD + ST-Link

# 5. 在另一个终端启动网关
gcc gateway.c -o gateway
./gateway

# 6. 看调试输出
picocom -b 115200 /dev/ttyACM0
```

### PC 端收数据

```bash
# 编译网关
gcc gateway.c -o gateway

# 运行（默认端口 8888）
./gateway

# 效果：
[#0042] 14:32:05  NTC=25.3°C  DS18B20=26.1°C  DHT11=24.8°C  H=52.3%
```

用 `curl` 或 Python 读日志做分析：

```bash
cat temps.jsonl | python3 -c "
import sys,json
for l in sys.stdin:
    p=json.loads(l)
    print(p['seq'], p['ntc'])
"
```

## 18.10 你学到了什么

| 已学知识 | 在这项目里怎么用的 |
|---------|------------------|
| **ADC**（Ch9） | NTC 温度采集 |
| **UART**（Ch8） | DX-WF24 AT 指令通信 |
| **FreeRTOS**（Ch14-16） | SensorTask + WiFiTxTask |
| **环形缓冲区** | 采样和发送解耦 |
| **二进制协议** | 比 JSON 省 90% 流量 |
| **CRC 校验** | 防止数据损坏 |
| **PC 网关** | 用 C 写 TCP 服务器接收数据 |

## 18.11 用里程碑完成这个项目

本章内容很多，第一次不要同时接入三类传感器、SD 卡、WiFi 和网关。按下面顺序完成：

| 里程碑 | 本次只做什么 | 通过标准 |
|---|---|---|
| M1 | USART1 日志 + 一个传感器 | 串口每秒稳定打印数值 |
| M2 | 加入环形缓冲区与协议 | PC 网关能校验一帧数据 |
| M3 | 加入 WiFi AT 与 TCP | 断线后可重连，不影响采样 |
| M4 | 加入第二个传感器和本地缓存 | 单个传感器异常不会卡住系统 |
| M5 | 加入 FreeRTOS 任务 | 能报告栈、队列和错误计数 |

每通过一个里程碑，都保存一份接线、日志和固件版本。第 25 章会把同样的分阶段方法推广到完整环境监测节点。

### 硬件特别检查

- WiFi 模块的供电和峰值电流独立确认；
- 传感器、ZET6、USB-TTL 和模块必须明确共地；
- 不同传感器的上拉、采样电压和时序分别验证；
- 网络断开必须被当成正常故障路径，而不是系统崩溃。



## 18.12 从单元实验到完整项目的验收

第 18 章的代码很多，正确做法是把每一层单独证明，再把它们组合：

| 阶段 | 只增加的内容 | 证据 | 失败时回退到 |
|---|---|---|---|
| P0 | UART 日志 + 主循环 | 启动文本、时钟信息 | 第 8 章 |
| P1 | 一个 NTC/DS18B20/DHT11 | 连续 60 秒稳定读数 | 第 9 章或对应时序实验 |
| P2 | TempPacket + PC 网关 | PC 校验 magic/长度/CRC | 18.3、20 章 |
| P3 | RingBuffer | 生产快于消费时有溢出统计 | 18.6 |
| P4 | WiFi AT + TCP | 断线、重连、失败计数 | 第 17 章 |
| P5 | FreeRTOS 任务 | 栈、队列、错误指标稳定 | 第 16 章 |

### 每个传感器都必须有“坏数据”路径

不要把读取函数设计成只会返回一个数值：

~~~c
typedef enum {
    SAMPLE_OK,
    SAMPLE_TIMEOUT,
    SAMPLE_CRC_ERROR,
    SAMPLE_RANGE_ERROR
} SampleStatus;

typedef struct {
    uint32_t seq;
    SampleStatus status;
    int16_t value;
} Sample;
~~~

当某一路失败时，网关可以看到状态字段，其他传感器和网络任务继续运行。这比用 `0` 或 `-1` 代表所有错误更容易排错。

### 项目练习

1. 先只保留一种传感器和 P0–P2；把原始 ADC 或总线错误也打印出来；
2. 人为断开 WiFi，验证采样序号持续增加且网络任务不会阻塞它；
3. 让 RingBuffer 容量很小，确认溢出计数可见；
4. 选择一种错误状态，让 PC 网关显示“数据无效”而不是把它当成真实温度。


## 18.13 让“项目代码多”仍然可验证：协议、驱动与网关各留一份证据

本章中的传感器、WiFi 和 PC 网关片段用于讲解结构；它们不代替某块具体 ZET6 板、某个模块固件和某个编译器上的验证。把下面四类证据放进你的实验记录，才可以说某一层已通过。

| 层 | 需要固定的契约 | 最小验证 |
|---|---|---|
| 二进制包 | `TempPacket` 总长、字段字节序、CRC 覆盖范围、版本号 | MCU 与 PC 对同一组字节算出相同 CRC；打印 `sizeof(TempPacket)` |
| 传感器 | 供电、电平、上拉、采样/转换超时、量程 | 与万用表/已知温度趋势对照；断线或 NACK 时返回状态而非假值 |
| RingBuffer | 最大积压、溢出策略、生产者/消费者所有权 | 故意让发送慢于采样，记录溢出数与序号缺口 |
| PC 网关 | `read()` 分段、重连、写文件失败、字节序 | 同一帧按 1 字节、随机块、连续块送入，输出完全一致 |

### 固定长度包也要防编译器与字节序

`#pragma pack` 可以让示例易读，但协议不能只依赖“这台编译器恰好这样布局”。在构建时加入大小检查，并把端序作为协议文字的一部分：

~~~c
/* C11 可用时；旧工具链可用 typedef 数组大小检查替代。 */
_Static_assert(sizeof(TempPacket) == PKG_SIZE,
               "TempPacket layout changed");

/* 本章约定：多字节字段在线路上为 little-endian。
   PC 网关不要直接把网络字节强转为本机 struct 后使用。 */
~~~

对于温度等有符号值，还应记录单位（例如毫摄氏度）、无效状态和量程。这样 PC 端不会把一次超时的 `0` 错当成 0°C。

### 传感器与网关的回归输入

在没有硬件时，先用可保存的输入证明纯逻辑；有硬件时，再记录接线和测量条件：

1. 用一个公开的 `TempPacket` 字节数组同时喂 MCU 验证函数和 PC 网关；
2. 用一组正常值、CRC 错值、长度错值、序号跳变和半包作为回归集；
3. 分别模拟 NTC 开路、DS18B20 超时、DHT11 校验失败，确认产生不同 `SampleStatus`；
4. 让 PC 网关在一个连接中处理多帧，在中途断开后仍能正确关闭/重连，而不是假定一次 `read()` 恰好为 15 字节。

只有把“示例结构”与“已验证的板卡组合”分开记录，读者才不会因代码看起来完整而跳过最重要的硬件验证。
---

> **下一章**：[第 19 章 · 温度记录仪 BLE 版](./19-chapter.md)
>
> 同一套传感器代码，把 WiFi 发送换成 BLE——只改通信层。

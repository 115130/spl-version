# 第 12.5 章 · RS485 与 Modbus RTU ——工业现场的"普通话"

> **本章产出**：用板载 SP3485 + RS485 接口读取 SHT30 温湿度传感器，彻底理解差分信号、半双工收发切换、Modbus RTU 协议
>
> **用到项目的哪里**：第 18 章温度记录仪如果换成 RS485 总线传感器，本章就是它的通信基础

---

## 12.5.1 为什么需要 RS485

你已经学了三样有线通信：

| 协议 | 最远距离 | 适合的场景 |
|------|---------|-----------|
| **I²C** | ~30cm | 板内传感器、OLED、EEPROM |
| **SPI** | ~20cm | Flash、SD 卡、显示屏 |
| **UART**（TTL 电平） | ~1-2m | 调试串口、WiFi 模块排线 |

你的普中玄武板通过 CH340 和电脑通信，用的就是 UART。但把 MCU 的 TX/RX 直接拉出去的话：

```
STM32 TX ─────┬───── 电脑 RX
              │
        信号幅度 3.3V，参考 GND
        线一长（>2m），压降 + 电磁干扰 → 数据全是错的
```

工业现场要把传感器装在 50 米外的管道上，TTL 电平的 UART 根本传不了。

**RS485 就是来解决远距离、抗干扰的。**

---

## 12.5.2 RS485 物理层 —— 差分信号

### TTL 为什么传不远

TTL 电平靠"电压绝对值"表示 0 和 1：

```
TX 输出 1 → 引脚对 GND 是 3.3V
TX 输出 0 → 引脚对 GND 是 0V

线长了之后：
  1. 电阻压降：3.3V 到了远端可能只剩 2.0V
  2. 电磁干扰：外界的噪声叠加在 GND 上
  3. 收发两端 GND 电位不同：你家的 GND 和我家的 GND 差几伏
```

**问题全出在"参考 GND"上**——GND 不是绝对的。

### 差分信号：不靠 GND，靠两根线的电压差

```
RS485 不传"某针对 GND 的电压"，而是传"A 线和 B 线的电压差"：

A 比 B 高  > +200mV → 逻辑 1
A 比 B 低  < -200mV → 逻辑 0
           ↑
      差分的"差"字——看差值，不看绝对值
```

```
发 1：A=3.3V, B=0V    → A-B = +3.3V
发 0：A=0V,   B=3.3V  → A-B = -3.3V

干扰来了：两根线绞在一起，受到同等干扰
  A 被拉到 3.5V, B 被拉到 0.2V → A-B = 3.3V（干扰抵消了！）
```

**这就是 RS485 能传 1200 米的根本原因**——差分 + 双绞线，共模干扰在接收端相减消掉。

### 板子上的 SP3485

你的板子焊了一颗 **SP3485** 芯片。它的作用很单纯：

```
                ┌──────────┐
STM32 TX ─────→│ DI       │
STM32 RX ←─────│ RO       │
                │          │
STM32 GPIO ────→│ DE       │
STM32 GPIO ────→│ /RE      │
                │          │
                │   A ──────→ A 线（螺丝端子）
                │   B ──────→ B 线（螺丝端子）
                └──────────┘
```

SP3485 只是做了电平转换：
- **发**：STM32 的 TX（单端 3.3V）→ SP3485 → A/B（差分）
- **收**：A/B（差分）→ SP3485 → STM32 的 RX（单端 3.3V）

你的板子已经把 SP3485 焊好了，A/B 线接到了螺丝端子——你只需要把传感器拧上去。

### 半双工与方向控制

RS485 是**半双工**的：同一时刻只能发或者只能收，不能同时。

```
DE = 1（使能发送） → SP3485 把 DI 的信号送到 A/B 线
/RE = 0（使能接收） → SP3485 把 A/B 的信号送到 RO

DE 和 /RE 通常接在同一个 GPIO 上，因为：
  DE=1, /RE=1 → 发送模式（/RE 高电平不使能接收也没关系）
  DE=0, /RE=0 → 接收模式

只需要一个 GPIO：
  GPIO_HIGH();  → 切换到发送
  GPIO_LOW();   → 切换到接收
```

---

## 12.5.3 硬件接线

### 板子上的螺丝端子

你的普中玄武板上有两路螺丝端子——一路 RS232、一路 RS485。RS485 那一路有三个端子：

```
┌──────┬──────┬──────┐
│  A   │  B   │ GND  │
└──────┴──────┴──────┘
```

关于 RS485 模块的接线：

| 板子端子 | RS485 SHT30 模块 | 说明 |
|---------|-----------------|------|
| A | A | 差分正 |
| B | B | 差分负 |
| GND | GND | 共地（可选，但建议接） |
| — | VCC | 需要额外供电——见下文 |

### ⚠️ 供电问题

板子的 RS485 螺丝端子**只引出了 A/B/GND**，不提供 VCC。你的 SHT30 模块需要供电。解决办法：

- 从板子的 **3.3V 排针**引一根杜邦线到 SHT30 模块的 **VCC**
- 或者如果模块支持宽电压（多数 RS485 模块支持 5-24V），用外部电源

接线汇总：

```
板子 3.3V 排针 ────→ SHT30 模块 VCC
板子 GND ──────────→ SHT30 模块 GND
板子 RS485 A ──────→ SHT30 模块 A
板子 RS485 B ──────→ SHT30 模块 B
```

### SP3485 接哪个 USART、哪个 GPIO

查你的板子原理图，SP3485 的引脚连接大致如下（以实际原理图为准）：

| SP3485 引脚 | 接 STM32 |
|------------|---------|
| DI | USARTx TX |
| RO | USARTx RX |
| DE + /RE | 同一个 GPIO（例如 PC0） |

> **读者操作**：打开你的原理图 PDF，搜索 `SP3485`，找到 DI/RO/DE/RE 分别接了哪个引脚，写下来。本章代码以 USART2（PA2=TX, PA3=RX）和 PC0（DE/RE）为例。

---

## 12.5.3 Modbus RTU —— 485 上的"普通话"（重点）

### 为什么 RS485 上还得跑协议

RS485 只规定了"怎么把 0 和 1 传到 1200 米外"。但如果总线上挂了三个设备：

```
主机 ── A/B 线 ──┬── 温度传感器 #1
                 ├── 温湿度传感器 #2
                 └── 风速传感器 #3
```

主机发了一串字节 `01 03 00 00 00 02 C4 0B`，三个传感器都收到了——它们怎么知道这串字节是发给谁的？谁该回答？

**没有协议，RS485 就是一群设备对着一条线喊话，谁也听不懂谁。**

Modbus RTU 就是**工业现场最通用的"普通话"**。它规定了：
1. 每一帧（Frame）的格式——"一句话应该怎么说"
2. 地址机制——"叫谁谁回答"
3. 功能码——"问什么、怎么答"

### Modbus RTU 一帧的结构

```
┌──────┬──────┬──────────┬──────────────┐
│ 地址  │ 功能码 │  数据段   │   CRC16 校验  │
│ 1 字节 │ 1 字节 │ N 字节   │   2 字节      │
└──────┴──────┴──────────┴──────────────┘
↑                                    ↑
告诉谁                   验货——数据在传输中坏了没？
```

| 字段 | 长度 | 含义 |
|------|------|------|
| **地址** | 1 字节 | 你要跟谁说话。1-247 是设备地址，0 是广播。你的 SHT30 模块默认一般是 **0x01** |
| **功能码** | 1 字节 | 你要干什么。**0x03** = 读保持寄存器（最常用），0x06 = 写单个寄存器 |
| **数据段** | N 字节 | 功能码的参数。对读寄存器来说：起始地址（2 字节）+ 读取数量（2 字节） |
| **CRC16** | 2 字节 | 校验前面所有字节有没有传错。**低字节在前，高字节在后** |

### 实际例子：读 SHT30 温湿度

你的 SHT30 模块内部暴露了两个 16 位寄存器：

| 寄存器地址 | 内容 | 单位 |
|-----------|------|------|
| 0x0001 | 温度值 | 0.1°C，如 253 = 25.3°C |
| 0x0002 | 湿度值 | 0.1%，如 521 = 52.1% |

要一次读取这两个寄存器，主机发出的查询帧是：

```
01  03  00 01  00 02  ── CRC16 ──
 │   │   ─┬──  ─┬──      │
 │   │    │     └── 读 2 个寄存器（即读 0x0001 和 0x0002）
 │   │    └──────── 起始寄存器地址 = 0x0001
 │   └──────────── 功能码 0x03 = 读保持寄存器
 └──────────────── 设备地址 = 0x01
```

CRC16 计算（后面给代码），算出来 = `95 CA`，低字节在前 = `CA 95`。

所以完整的查询帧是：

```
01 03 00 01 00 02 CA 95
```

### 模块怎么回答

如果 SHT30 当前温度 = 25.3°C（0x00FD = 253），湿度 = 52.1%（0x0209 = 521），它会回答：

```
01  03  04  00 FD  02 09  ── CRC16 ──
 │   │   │  ─┬──  ─┬──      │
 │   │   │   │     └── 湿度值 = 0x0209 = 521 = 52.1%
 │   │   │   └──────── 温度值 = 0x00FD = 253 = 25.3°C
 │   │   └──────────── 字节数 = 4（两个寄存器 × 2 字节）
 │   └──────────────── 功能码 0x03（回声，告诉你这是读寄存器的回复）
 └──────────────────── 地址 0x01
```

### CRC16 计算（完整代码，查表法）

CRC16 保证你收到的数据没有被干扰。Modbus 的 CRC16 和普通 CRC16 算法一样，但**初始值 = 0xFFFF**，多了一步**结果异或 0x0000**（即保持原样），且**低字节先发**。

```c
/*********************************************************************
 * Modbus CRC16 查表法 —— 最快、最省代码
 *
 * 用法：发数据前调用，算出来的 CRC 追加到帧尾（低字节在前）
 *
 * 示例：
 *   uint8_t frame[] = {0x01, 0x03, 0x00, 0x01, 0x00, 0x02};
 *   uint16_t crc = ModbusCRC16(frame, 6);
 *   frame[6] = crc & 0xFF;        // CRC 低字节
 *   frame[7] = (crc >> 8) & 0xFF; // CRC 高字节
 *********************************************************************/
static const uint16_t crc16_table[256] = {
    0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
    0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
    0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40,
    0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
    0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40,
    0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
    0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641,
    0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
    0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240,
    0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
    0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41,
    0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
    0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41,
    0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
    0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640,
    0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
    0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240,
    0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
    0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41,
    0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
    0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41,
    0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
    0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640,
    0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
    0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241,
    0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
    0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40,
    0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
    0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40,
    0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
    0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641,
    0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040,
};

uint16_t ModbusCRC16(uint8_t *data, uint16_t len) {
    uint16_t crc = 0xFFFF;          // Modbus 初始值
    for (uint16_t i = 0; i < len; i++) {
        crc = (crc >> 8) ^ crc16_table[(crc ^ data[i]) & 0xFF];
    }
    return crc;                     // 结果直接追加，低字节在前
}
```

这个算法是 **查表法**——256 个预计算结果，运行时只需按字节查表异或，比逐位计算快几十倍。256 × 2 字节 = 512 字节的表，对 STM32F103 的 64KB Flash 来说微不足道。

### "为什么要有这一层" 总结

| 层 | 解决什么问题 | 类比 |
|----|------------|------|
| **RS485 物理层** | 把 0/1 传到 1200 米外 | 电话线——能传声音，但不知道谁在说 |
| **UART 数据链路** | 把字节按波特率收拢成帧 | 两个人约定用中文说话 |
| **Modbus 应用层** | 谁跟谁说话、说了什么、对没对 | "小明，今天几号？" "25号。" |

没有 Modbus，RS485 线上就是一群会说话的哑巴——能发声，但谁也听不懂谁。

---

## 12.5.4 完整代码：读取 RS485 SHT30 温湿度

### 配置 USART 与 GPIO

```c
// rs485.h
#ifndef __RS485_H
#define __RS485_H

#include "stm32f10x.h"
#include <stdint.h>

// ── 以 USART2 为例（查你的原理图确认） ──
#define RS485_USART         USART2
#define RS485_USART_CLK     RCC_APB1Periph_USART2
#define RS485_GPIO_CLK      RCC_APB2Periph_GPIOA
#define RS485_TX_PIN        GPIO_Pin_2   // PA2 = USART2 TX
#define RS485_RX_PIN        GPIO_Pin_3   // PA3 = USART2 RX
#define RS485_GPIO_PORT     GPIOA

// ── DE/RE 控制引脚（查你的原理图确认） ──
#define RS485_DE_RE_PORT    GPIOC
#define RS485_DE_RE_PIN     GPIO_Pin_0
#define RS485_TX_MODE()     GPIO_SetBits(RS485_DE_RE_PORT, RS485_DE_RE_PIN)   // DE=1, /RE=1 → 发送
#define RS485_RX_MODE()     GPIO_ResetBits(RS485_DE_RE_PORT, RS485_DE_RE_PIN)  // DE=0, /RE=0 → 接收

void RS485_Init(void);
void RS485_SendBytes(uint8_t *buf, uint16_t len);
uint16_t RS485_ReceiveBytes(uint8_t *buf, uint16_t maxLen, uint32_t timeoutMs);
uint16_t ModbusCRC16(uint8_t *data, uint16_t len);

#endif
```

```c
// rs485.c
#include "rs485.h"

void RS485_Init(void) {
    GPIO_InitTypeDef gpio;
    USART_InitTypeDef usart;

    // ── 使能时钟 ──
    RCC_APB2PeriphClockCmd(RS485_GPIO_CLK | RCC_APB2Periph_GPIOC, ENABLE);
    RCC_APB1PeriphClockCmd(RS485_USART_CLK, ENABLE);

    // ── TX (PA2) 推挽复用输出 ──
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = RS485_TX_PIN;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(RS485_GPIO_PORT, &gpio);

    // ── RX (PA3) 浮空输入 ──
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = RS485_RX_PIN;
    gpio.GPIO_Mode  = GPIO_Mode_IN_FLOATING;
    GPIO_Init(RS485_GPIO_PORT, &gpio);

    // ── DE/RE (PC0) 推挽输出，初始为接收模式 ──
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = RS485_DE_RE_PIN;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(RS485_DE_RE_PORT, &gpio);
    RS485_RX_MODE();   // 初始为接收

    // ── USART 配置：9600-8-N-1 ──
    // 9600 是 Modbus 最常用的波特率，RS485 最长距离时也稳定
    USART_StructInit(&usart);
    usart.USART_BaudRate = 9600;
    usart.USART_WordLength = USART_WordLength_8b;
    usart.USART_StopBits = USART_StopBits_1;
    usart.USART_Parity = USART_Parity_No;
    usart.USART_Mode = USART_Mode_Tx | USART_Mode_Rx;
    USART_Init(RS485_USART, &usart);
    USART_Cmd(RS485_USART, ENABLE);
}

void RS485_SendBytes(uint8_t *buf, uint16_t len) {
    RS485_TX_MODE();              // 切为发送
    for (uint16_t i = 0; i < len; i++) {
        while (USART_GetFlagStatus(RS485_USART, USART_FLAG_TXE) == RESET);
        USART_SendData(RS485_USART, buf[i]);
    }
    while (USART_GetFlagStatus(RS485_USART, USART_FLAG_TC) == RESET);  // 等最后一字节发完
    RS485_RX_MODE();              // 切回接收
}

uint16_t RS485_ReceiveBytes(uint8_t *buf, uint16_t maxLen, uint32_t timeoutMs) {
    uint16_t count = 0;
    uint32_t start = uwTick;      // 来自 SysTick 的毫秒计数器

    while (count < maxLen) {
        if (USART_GetFlagStatus(RS485_USART, USART_FLAG_RXNE) != RESET) {
            buf[count++] = USART_ReceiveData(RS485_USART);
            start = uwTick;       // 收到一个字节，刷新超时
        }
        if (uwTick - start > timeoutMs) break;  // 超时退出
    }
    return count;                 // 返回实际收到的字节数
}
```

### 主程序

```c
// main.c
#include "rs485.h"
#include <stdio.h>

// Modbus CRC16 函数（见上一节的完整代码）

int main(void) {
    // ── 系统初始化 ──
    // 假定 SysTick 已配置，每毫秒 uwTick++（参考第 5 章）
    // USART1 已配置，printf 重定向到 CH340（参考第 8 章）

    RS485_Init();

    // 构建查询帧：01 03 00 01 00 02
    uint8_t query[8];
    query[0] = 0x01;                    // 地址 = 1
    query[1] = 0x03;                    // 功能码 = 读寄存器
    query[2] = 0x00;                    // 起始地址高字节
    query[3] = 0x01;                    // 起始地址低字节（0x0001）
    query[4] = 0x00;                    // 读取数量高字节
    query[5] = 0x02;                    // 读取数量低字节（2 个）

    uint16_t crc = ModbusCRC16(query, 6);
    query[6] = crc & 0xFF;              // CRC 低字节
    query[7] = (crc >> 8) & 0xFF;       // CRC 高字节

    uint8_t resp[16];   // 接收缓冲区

    while (1) {
        // ── 发查询帧 ──
        RS485_SendBytes(query, 8);

        // ── 收响应（最多等 100ms） ──
        uint16_t len = RS485_ReceiveBytes(resp, 16, 100);

        if (len >= 7 && resp[0] == 0x01 && resp[1] == 0x03) {
            // 解析温度（resp[3]<<8 | resp[4]），单位 0.1°C
            int16_t temp = (resp[3] << 8) | resp[4];
            // 解析湿度（resp[5]<<8 | resp[6]），单位 0.1%
            int16_t hum  = (resp[5] << 8) | resp[6];

            printf("SHT30: %d.%d°C / %d.%d%% RH\r\n",
                   temp / 10, temp % 10,
                   hum  / 10, hum  % 10);
        } else {
            printf("RS485 无响应或数据错误\r\n");
        }

        Delay_ms(2000);   // 每 2 秒读一次
    }
}
```

### 关于 uwTick

上面用的 `uwTick` 来自第 5 章 SysTick 的 **1ms 中断计数器**：

```c
// SysTick_Handler 中（第 5 章有完整代码）
volatile uint32_t uwTick;
void SysTick_Handler(void) {
    uwTick++;
}
```

如果用第 4 章的 `Delay_ms()` 凑合也可以——把超时改成简单空等。但 `uwTick` 方式不会阻塞 CPU。

---

## 12.5.5 验证与排错

### 正常工作时的输出

```
SHT30: 25.3°C / 52.1% RH
SHT30: 25.3°C / 52.1% RH
SHT30: 25.4°C / 52.3% RH
```

每 2 秒一次，温度湿度在小数后一位波动——这是正常的。

### 翻车排查清单

| 现象 | 最可能的原因 |
|------|------------|
| 完全无输出 | DE/RE 引脚配置错了，SP3485 一直处于接收模式，发不出去 |
| 收到乱码（`ÿÿÿÿ` 等） | 波特率不匹配。模块可能是 9600，但有些模块默认 115200 |
| 收到数据但 CRC 校验失败（可加 CRC 检查） | A/B 线接反了。对调一下试试 |
| 有时收到有时收不到 | 终端电阻未启用。长线（>10m）需要在最后一台设备并 120Ω 电阻 |
| 温度湿度都是 0 | 寄存器地址不对。有些模块温度在 0x0001，有些在 0x0000 |
| 间隔几分钟才出一次数 | `Delay_ms(2000)` 里的 SysTick 没配好，或者 `printf` 阻塞了 |

### 快速验证：USB-RS485 转换器

如果你有 USB-RS485 转换器（¥10-15），插到电脑上用串口助手手动发 `01 03 00 01 00 02 C4 0B`（注意这组 CRC 计算的是 `00 01 00 02` 之前的数据，实际要以你的代码算出来的为准），看模块有没有回复。这能帮你确定：

- 模块的地址是不是 0x01
- 波特率是不是 9600
- 寄存器地址对不对

先把这步过了，再连 STM32。

---

## 12.5.6 协议对比总表

学到这里，你已经接触了全部五种常用有线通信协议：

| | 1-Wire | UART (TTL) | I²C | SPI | **RS485** |
|--|--------|-----------|-----|-----|-----------|
| 线数 | **1**（DQ） | 2（TX+RX） | 2（SCL+SDA） | 3-4（SCK+MOSI+MISO+CS） | **2**（A+B）|
| 传输距离 | <1m | <2m | <0.3m | <0.2m | **1200m** |
| 速度 | 16kbps | 最高 10Mbps | 400kbps | 18Mbps | 最高 10Mbps |
| 多设备 | ✅可级联（ROM 搜索复杂） | ❌一对一 | ✅地址区分（最多 127） | ✅片选区分 | ✅地址区分（最多 247）|
| 抗干扰 | 差 | 差 | 差 | 差 | **强（差分）** |
| 时序要求 | **最严格**（μs 级手工） | 硬件外设自动 | 硬件外设自动 | 硬件外设自动 | 硬件外设自动 |
| 典型用途 | 温度传感器 | 调试串口/WiFi 模块 | 板内传感器/EEPROM | Flash/SD卡/显示屏 | **工业总线/远程传感器** |
| 学会它的意义 | 理解时序的物理感 | 最通用的异步通信 | 接线最少的总线 | 最快的有线传输 | **工业现场的标准答案** |

**1-Wire** 让你亲手触碰到了每一微秒的电压变化——这是其他协议不可能给你的体验。  
**RS485** 则站在另一端：你不需要管时序，但你需要理解差分、方向切换、和应用层协议。

从 1-Wire 到 RS485，你其实走完了嵌入式有线通信的**整个光谱**——从最底层（手撸 GPIO 时序）到最上层（Modbus 应用协议）。后面再遇到任何通信协议，你都能一眼看出它在光谱上的位置。

---

## 12.5.7 本章要点

- RS485 用 **差分信号**（A-B 电压差）代替单端 TTL，传得远、抗干扰
- 半双工需要用 **DE/RE 引脚**切换收发方向
- **Modbus RTU** 是 RS485 上最通用的应用协议：**地址 + 功能码 + 数据 + CRC**
- 0x03 功能码 = 读保持寄存器，是读传感器最常用的命令
- CRC16 查表法比逐位计算快几十倍，嵌入式中永远用查表法
- RS485 不提供供电，传感器 VCC 需要额外接入
- 调试时先拿 USB-RS485 转换器 + 串口助手确认模块正常，再连 MCU

---

> **上一章**：[第 12 章 · DMA 控制器](./12-chapter.md)
>
> **下一章**：[第 13 章 · 存储器与文件系统](./13-chapter.md)

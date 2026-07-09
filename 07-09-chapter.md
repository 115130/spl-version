# 第 7-9 章 · 定时器 / UART / ADC（SPL 版）

> 本章覆盖三个核心外设：定时器（中断 + PWM）、串口通信（轮询/中断/DMA）、ADC（单通道 + DMA 多通道）。
> 每个部分先讲硬件原理，再给 SPL 代码。不需要对照 HAL 版。

---

# 第 7 章 · 定时器

## 7.1 定时器分类

STM32F103ZET6（你的板子）有多达 8 个定时器：

| 定时器 | 类型 | 位数 | 通道 | 用途 |
|--------|------|------|------|------|
| TIM1, TIM8 | 高级控制 | 16 位 | 4 | PWM 互补输出、死区、刹车（电机控制） |
| TIM2-5 | 通用 | 16 位 | 4 | 编码器接口、输入捕获、PWM |
| TIM6, TIM7 | 基本 | 16 位 | — | 只有时基，无通道（DAC 触发） |

另有 SysTick（Cortex-M3 内核内置，24 位）和 IWDG/WWDG 看门狗。

## 7.2 定时器工作原理

核心是三寄存器：

```
PSC (预分频器)
  ↓  CK_CNT = 定时器时钟 / (PSC + 1)
CNT (计数器) —— 每个 CK_CNT 脉冲加 1
  ↓  当 CNT == ARR（自动重装载值）
CNT 归零，触发「更新事件」→ 可产生中断 / DMA
```

**定时周期公式**：

```
定时频率 = 定时器时钟 / ((PSC + 1) × (ARR + 1))
定时周期 = 1 / 定时频率

TIM2 挂在 APB1（36MHz × 2 = 72MHz 定时器时钟）：
  想要 1ms (1000Hz)：PSC=71, ARR=999
  72,000,000 / (72 × 1000) = 1000 Hz ✓
```

> ⚠️ TIM2-7 挂在 APB1。当 APB1 预分频 ≠ /1 时，定时器时钟 = 2 × PCLK1。这是 ST 的特殊设计——让 APB1 上的定时器也能跑 72MHz。

**PWM 输出**：当 CNT < CCR（捕获/比较寄存器），输出高；CNT ≥ CCR，输出低。调整 CCR 改变占空比。

---

## 7.3 SPL 定时器中断：1ms 周期任务

```c
#include "stm32f10x_tim.h"

void TIM2_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);

    TIM_TimeBaseInitTypeDef tim;
    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler         = 71;      // PSC: 72MHz / 72 = 1MHz
    tim.TIM_Period            = 999;     // ARR: 1MHz / 1000 = 1kHz
    tim.TIM_CounterMode       = TIM_CounterMode_Up;
    tim.TIM_ClockDivision     = 0;
    tim.TIM_RepetitionCounter = 0;
    TIM_TimeBaseInit(TIM2, &tim);

    TIM_ITConfig(TIM2, TIM_IT_Update, ENABLE);  // 开通更新中断
    NVIC_EnableIRQ(TIM2_IRQn);                  // NVIC 使能
    TIM_Cmd(TIM2, ENABLE);                      // 启动！
}

// ISR：每 1ms 调一次
void TIM2_IRQHandler(void) {
    if (TIM_GetITStatus(TIM2, TIM_IT_Update) != RESET) {
        TIM_ClearITPendingBit(TIM2, TIM_IT_Update);
        // 你的周期任务放这里
    }
}
```

## 7.4 SPL PWM 呼吸灯

```c
void TIM3_PWM_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM3, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);  // TIM3_CH3 = PB0

    // GPIO: PB0 为复用推挽输出
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin   = GPIO_Pin_0;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOB, &gpio);

    // 时基: 72MHz / 72 / 1000 = 1kHz PWM 频率
    TIM_TimeBaseInitTypeDef tim;
    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler   = 71;
    tim.TIM_Period      = 999;        // ARR=999 → 1kHz
    TIM_TimeBaseInit(TIM3, &tim);

    // PWM 通道 3: 初始占空比 0%
    TIM_OCInitTypeDef oc;
    oc.TIM_OCMode      = TIM_OCMode_PWM1;
    oc.TIM_OutputState = TIM_OutputState_Enable;
    oc.TIM_Pulse       = 0;           // CCR = 0（灭）
    oc.TIM_OCPolarity  = TIM_OCPolarity_High;
    TIM_OC3Init(TIM3, &oc);
    TIM_OC3PreloadConfig(TIM3, TIM_OCPreload_Enable);

    TIM_Cmd(TIM3, ENABLE);
}

// 呼吸灯主循环
int main(void) {
    uint16_t duty = 0;
    int8_t   dir  = 1;

    while (1) {
        TIM_SetCompare3(TIM3, duty);   // 更新占空比
        duty += dir;
        if (duty >= 999) dir = -1;
        if (duty == 0)   dir =  1;
        Delay_ms(2);
    }
}
```

### SPL 定时器函数速查

| 操作 | SPL |
|------|-----|
| 时钟 | `RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE)` |
| 时基 | `TIM_TimeBaseInit(TIM2, &cfg)` |
| 启动 | `TIM_Cmd(TIM2, ENABLE)` |
| 开中断 | `TIM_ITConfig(TIM2, TIM_IT_Update, ENABLE)` |
| 清中断 | `TIM_ClearITPendingBit(TIM2, TIM_IT_Update)` |
| PWM 占空比 | `TIM_SetCompare3(TIM3, duty)` — 直接写 CCR3 |

---

## 7.5 输入捕获：测量脉冲宽度

输入捕获用途：测频率、测占空比、解码红外遥控、超声波测距。

### 原理

```
外部信号 → GPIO → 定时器通道（输入模式）
                    │
                   检测到边沿（上升沿或下降沿）
                    │
                   硬件自动把当前 CNT 值锁存到 CCRx
                    │
                   产生捕获中断
```

两次捕获的差值 = 脉冲宽度（以定时器 tick 为单位）。

### SPL 输入捕获初始化

以 TIM2 CH1（PA0）为例，测量高电平脉宽：

```c
void TIM2_IC_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);

    // PA0 = TIM2_CH1，浮空输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // 时基：72MHz / 72 = 1MHz → 1μs 分辨率
    TIM_TimeBaseInitTypeDef tim;
    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler   = 71;
    tim.TIM_Period      = 0xFFFF;   // 最大计数范围
    TIM_TimeBaseInit(TIM2, &tim);

    // 输入捕获 CH1：上升沿触发
    TIM_ICInitTypeDef ic;
    ic.TIM_Channel     = TIM_Channel_1;
    ic.TIM_ICPolarity  = TIM_ICPolarity_Rising;
    ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
    ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
    ic.TIM_ICFilter    = 0;
    TIM_ICInit(TIM2, &ic);

    TIM_ITConfig(TIM2, TIM_IT_CC1, ENABLE);   // 捕获中断
    NVIC_EnableIRQ(TIM2_IRQn);
    TIM_Cmd(TIM2, ENABLE);
}

// ISR：在中断里切换边沿捕捉
static uint32_t last_cap = 0, pulse_width = 0;

void TIM2_IRQHandler(void) {
    if (TIM_GetITStatus(TIM2, TIM_IT_CC1)) {
        TIM_ClearITPendingBit(TIM2, TIM_IT_CC1);
        uint32_t cap = TIM_GetCapture1(TIM2);

        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0)) {
            // 上升沿：记录初始值
            last_cap = cap;
            TIM_ICInitTypeDef ic;
            TIM_ICStructInit(&ic);
            ic.TIM_Channel    = TIM_Channel_1;
            ic.TIM_ICPolarity = TIM_ICPolarity_Falling;  // 切换为下降沿
            ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
            ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
            TIM_ICInit(TIM2, &ic);
        } else {
            // 下降沿：计算脉宽（单位：μs）
            pulse_width = (cap > last_cap) ? (cap - last_cap) : (0xFFFF - last_cap + cap);
            // 恢复为上升沿
            TIM_ICInitTypeDef ic;
            TIM_ICStructInit(&ic);
            ic.TIM_Channel    = TIM_Channel_1;
            ic.TIM_ICPolarity = TIM_ICPolarity_Rising;
            ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
            ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
            TIM_ICInit(TIM2, &ic);
        }
    }
}
```

### 应用：超声波测距

- Trig 发 10μs 高脉冲
- Echo 返回与距离成正比的高脉冲（~58μs/cm）
- 输入捕获测高电平宽度 → `距离(μs) / 58 = 距离(cm)`

---

# 第 8 章 · 串口通信 UART

## 8.1 串行通信基础

### 并行 vs 串行

| | 并行 | 串行 |
|---|---|---|
| 线数 | 8/16 根数据线 + 时钟 | 1-2 根 |
| 距离 | 短 | 长（几米到上千米 RS485） |
| 嵌入式中 | 极少 | **到处都是** |

UART 是最简单的串行——不需要时钟线（异步），双方约定波特率。

### 异步串行协议

```
空闲：高电平
起始位：1 位低电平（「我要发了」）
数据位：5-9 位（通常 8 位，LSB 先发）
校验位：可选
停止位：1 或 2 位高电平

发 0x41 ('A') = 0b0100_0001（8N1：8 数据位、无校验、1 停止位）

空闲 ─┐  ┌─┐  ┌─┐     ┌─┐  ┌───────
      └──┘S└─┘0└─┘ ... └─┘1└─────
         0   1   2       7   停止
```

- **波特率**：常见 9600, 115200, 921600
- **帧格式**：8N1 最常用
- **波特率误差 > 2% 出错**——所以 HSE（晶振 ±30ppm）比 HSI（±1%）可靠

## 8.2 STM32 USART 外设

ZET6 有 5 个 USART：

| USART | TX | RX | 总线 |
|-------|-----|-----|------|
| USART1 | PA9 | PA10 | APB2 (72MHz) |
| USART2 | PA2 | PA3 | APB1 (36MHz) |
| USART3 | PB10 | PB11 | APB1 |

连接：**TX ↔ RX，RX ↔ TX，GND ↔ GND**。

## 8.3 SPL UART 初始化 + printf 重定向

```c
#include "stm32f10x_usart.h"

void USART1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1 | RCC_APB2Periph_GPIOA, ENABLE);

    // PA9 = TX（复用推挽）
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin   = GPIO_Pin_9;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOA, &gpio);

    // PA10 = RX（浮空输入）
    gpio.GPIO_Pin  = GPIO_Pin_10;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // USART: 115200, 8N1
    USART_InitTypeDef uart;
    uart.USART_BaudRate            = 115200;
    uart.USART_WordLength          = USART_WordLength_8b;
    uart.USART_StopBits            = USART_StopBits_1;
    uart.USART_Parity              = USART_Parity_No;
    uart.USART_HardwareFlowControl = USART_HardwareFlowControl_None;
    uart.USART_Mode                = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART1, &uart);

    USART_Cmd(USART1, ENABLE);
}

// printf 重定向到 USART1
#include <stdio.h>
int fputc(int ch, FILE *f) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, (uint8_t)ch);
    return ch;
}
// 现在 printf("Hello %d\n", 42) 就输出到串口了
```

**验证**：接上 ST-Link 反面的 TXD/RXD → `minicom -D /dev/ttyACM0 -b 115200`，看到 printf 输出。

## 8.4 SPL UART 中断接收

```c
volatile uint8_t rx_byte;
volatile uint8_t rx_ready = 0;

void USART1_IRQHandler(void) {
    if (USART_GetITStatus(USART1, USART_IT_RXNE) != RESET) {
        rx_byte  = USART_ReceiveData(USART1);  // 读 DR 自动清 RXNE
        rx_ready = 1;
    }
}

// 初始化时开启 RXNE 中断：
USART_ITConfig(USART1, USART_IT_RXNE, ENABLE);
NVIC_EnableIRQ(USART1_IRQn);

// 主循环处理：
while (1) {
    if (rx_ready) {
        rx_ready = 0;
        printf("收到: 0x%02X (%c)\n", rx_byte, rx_byte);
    }
}
```

### UART 轮询方式收发

最简单的收发——CPU 忙等：

```c
void UART_PutChar(uint8_t ch) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, ch);
}

uint8_t UART_GetChar(void) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_RXNE) == RESET);
    return USART_ReceiveData(USART1);
}
```

轮询简单但阻塞 CPU。初期调试用轮询，正式代码用中断。

## 8.5 动手：串口指令解析器

串口发命令控制 MCU——实用技能。

```c
#define CMD_BUF_LEN 32
char cmd_buf[CMD_BUF_LEN];
uint8_t cmd_idx = 0;
volatile uint8_t cmd_ready = 0;

// 在 USART1_IRQHandler 中逐字符接收
void USART1_IRQHandler(void) {
    if (USART_GetITStatus(USART1, USART_IT_RXNE) != RESET) {
        char ch = USART_ReceiveData(USART1);

        if (ch == '\r' || ch == '\n') {   // 回车 = 命令结束
            cmd_buf[cmd_idx] = '\0';
            cmd_idx = 0;
            cmd_ready = 1;
        } else if (cmd_idx < CMD_BUF_LEN - 1) {
            cmd_buf[cmd_idx++] = ch;
        }
    }
}

// 主循环中解析
while (1) {
    if (cmd_ready) {
        cmd_ready = 0;
        printf("收到: %s\r\n", cmd_buf);

        if      (strcmp(cmd_buf, "LED ON")  == 0) GPIO_ResetBits(GPIOB, GPIO_Pin_5);
        else if (strcmp(cmd_buf, "LED OFF") == 0) GPIO_SetBits(GPIOB, GPIO_Pin_5);
        else if (strcmp(cmd_buf, "TEMP?")   == 0) printf("温度: 25°C\r\n");
        else printf("未知: %s\r\n", cmd_buf);
    }
}
```

## 9.1 模拟世界 vs 数字世界

物理世界是连续的（模拟），MCU 是离散的（数字）。ADC 就是桥梁：

| 参数 | STM32F103 ADC | 说明 |
|------|---------------|------|
| **分辨率** | 12 位 | 输出 0 ~ 4095（2¹² - 1） |
| **参考电压** | 通常 3.3V | 输入 ≤ Vref |
| **采样率** | 最高 1MHz | 每秒 100 万次 |
| **通道数** | 16 外部 + 2 内部 | 含温度传感器、内部 Vref |

**量化**：12 位 ADC，Vref = 3.3V，每个 LSB = 3.3V / 4096 ≈ 0.806mV。输入 1.65V → ADC 值 ≈ 2048。

逐次逼近型 SAR：和 Vref/2 比 → 大就往 3Vref/4 比，小就往 Vref/4 比...12 次比较出一个 12 位结果。二分法。

### STM32 ADC 结构

- **规则通道组**：最多 16 通道顺序转换，结果只有一个 DR 寄存器——多通道需要 DMA 搬运
- **注入通道组**：最多 4 通道可插队，每通道有独立数据寄存器

## 9.2 SPL ADC 单通道

```c
#include "stm32f10x_adc.h"

void ADC1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_ADC1 | RCC_APB2Periph_GPIOA, ENABLE);

    // PA0 = ADC 通道 0，模拟输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &gpio);

    ADC_InitTypeDef adc;
    ADC_StructInit(&adc);
    adc.ADC_Mode                = ADC_Mode_Independent;
    adc.ADC_ScanConvMode        = DISABLE;       // 单通道
    adc.ADC_ContinuousConvMode  = DISABLE;       // 单次，触发一次转一次
    adc.ADC_ExternalTrigConv    = ADC_ExternalTrigConv_None;
    adc.ADC_DataAlign           = ADC_DataAlign_Right;
    adc.ADC_NbrOfChannel        = 1;
    ADC_Init(ADC1, &adc);

    ADC_RegularChannelConfig(ADC1, ADC_Channel_0, 1, ADC_SampleTime_55Cycles5);
    ADC_Cmd(ADC1, ENABLE);

    ADC_ResetCalibration(ADC1);
    while (ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1);
    while (ADC_GetCalibrationStatus(ADC1));
}

uint16_t ADC1_Read(void) {
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);        // 触发一次转换
    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET);
    return ADC_GetConversionValue(ADC1);
}
```

## 9.3 SPL ADC DMA 多通道

```c
uint16_t adc_buf[3];  // 通道 0,1,2 → 自动填充

void ADC1_DMA_Init(void) {
    // ADC 配置同上，但改为扫描+连续模式
    // ... adc.ADC_ScanConvMode = ENABLE;
    // ... adc.ADC_ContinuousConvMode = ENABLE;
    // ... adc.ADC_NbrOfChannel = 3;
    // ... ADC_RegularChannelConfig × 3

    // DMA1 通道 1
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);
    DMA_DeInit(DMA1_Channel1);
    DMA_InitTypeDef dma;
    dma.DMA_PeripheralBaseAddr = (uint32_t)&ADC1->DR;
    dma.DMA_MemoryBaseAddr     = (uint32_t)adc_buf;
    dma.DMA_DIR                = DMA_DIR_PeripheralSRC;
    dma.DMA_BufferSize         = 3;
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_HalfWord;
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_HalfWord;
    dma.DMA_Mode               = DMA_Mode_Circular;
    dma.DMA_Priority           = DMA_Priority_High;
    dma.DMA_M2M                = DMA_M2M_Disable;
    DMA_Init(DMA1_Channel1, &dma);
    DMA_Cmd(DMA1_Channel1, ENABLE);

    ADC_DMACmd(ADC1, ENABLE);   // ADC → DMA
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);
}
// adc_buf[0] = 通道0, [1] = 通道1, [2] = 通道2，DMA 自动循环更新
```

### 读内部温度传感器

STM32F103 内部有温度传感器连接到 ADC1 的通道 16：

```c
// ADC_Channel_16 — 内部温度传感器
// 需要先开启：ADC_TempSensorVrefintCmd(ENABLE);
// 采样时间要足够长：ADC_SampleTime_239Cycles5

// 温度公式（参考数据手册电气特性）：
// V25 = 1.43V（25°C 时传感器输出电压）
// Avg_Slope = 4.3mV/°C（每度电压变化率）
// 温度(°C) = ((V25 - V_SENSE) / Avg_Slope) + 25

uint16_t adc_val = ADC1_Read(16);  // 读通道 16
float voltage   = adc_val * 3.3f / 4096.0f;
float temp_c    = ((1.43f - voltage) / 0.0043f) + 25.0f;
```

精度不高（±1.5°C），但能感知芯片是否过热。

---

## SPL 外设初始化六步法

所有 SPL 外设初始化遵循同一模式：

```
1. 开时钟    RCC_xxxPeriphClockCmd(...)
2. 配 GPIO   GPIO_Init(...) —— 复用/模拟/推挽等
3. 配外设    xxx_Init(...) —— 外设自己的配置结构体
4. 配中断    NVIC_Init(...) / NVIC_EnableIRQ(...)（可选）
5. 使能外设  xxx_Cmd(xxx, ENABLE)
6. 打开中断  xxx_ITConfig(xxx, ...)（可选）
```

---

> **下一章**：[第 10-13 章 · I2C / SPI / DMA / FatFs（SPL版）](./10-13-chapter.md)
>
> GPIO、定时器、UART、ADC——四个基础外设齐了。接下来进入通信协议和存储：I2C（连 OLED）、SPI（连 Flash）、DMA（不占 CPU 的传输）、文件系统。

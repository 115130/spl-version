# 第 9 章 · ADC、DMA 与 DAC：把码值还原成可验证的模拟量（SPL 版）

> **本章产出**：读取一个外接电位器的 ADC 码值/电压，理解采样时间与 DMA 缓冲边界，并在 PA4/PA5 上输出经过测量的 DAC 电压。
>
> **前置知识**：第 5 章时钟、第 7 章定时器、第 8 章串口。
>
> **安全前提**：模拟输入只能在 VSSA–VDDA 范围内；先确认模块电压、共地和引脚冲突。PA0 同时是默认按键、TIM2_CH1 和 ADC1_IN0，实验不能并接。

---

## 9.1 两种转换器，两个不同问题

ZET6 具有 3 个 ADC 和 2 个 DAC。ADC 把引脚电压量化为码值；DAC 把数字码近似变成电压。它们都以模拟供电/参考为尺度，不是“天然精确的 3.300V 仪器”。

| 外设 | 例子 | 关键限制 |
|---|---|---|
| ADC | 电位器、分压、传感器 | 输入范围、源阻抗、采样时间、ADCCLK、噪声 |
| DAC1 | PA4 | 输出缓冲、负载、量程与实际 VDDA |
| DAC2 | PA5 | 同上；PA5 也常被 SPI1_SCK 占用，不能并用 |

12 位 ADC/DAC 的理想关系是：

```text
code ∈ [0, 4095]
ADC voltage ≈ code × VDDA / 4095
DAC voltage ≈ code × VDDA / 4095
```

这是换算模型，不是校准证明。VDDA、偏移、增益误差、噪声、输入/输出缓冲和负载都会带来偏差；用万用表/示波器验证具体板子的实际值。

## 9.2 ADC 时钟和单通道最小闭环

F103 的 ADCCLK 最大 14MHz。若 PCLK2=72MHz，第 5 章的 `/6` 得到 12MHz。必须在 ADC 初始化前或系统时钟配置中明确设置：

```c
RCC_ADCCLKConfig(RCC_PCLK2_Div6);   /* 72MHz / 6 = 12MHz */
```

以下示例用外接电位器的滑动端接 PA0（ADC1_IN0），两端接 3.3V/GND。不要假定每块板都带电位器。

```c
#include <stdbool.h>
#include "stm32f10x_adc.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

#define ADC_WAIT_LIMIT  1000000U

static bool ADC1_Init_Channel0(void)
{
    GPIO_InitTypeDef gpio;
    ADC_InitTypeDef adc;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA |
                            RCC_APB2Periph_ADC1, ENABLE);
    RCC_ADCCLKConfig(RCC_PCLK2_Div6);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &gpio);

    ADC_DeInit(ADC1);
    ADC_StructInit(&adc);
    adc.ADC_Mode = ADC_Mode_Independent;
    adc.ADC_ScanConvMode = DISABLE;
    adc.ADC_ContinuousConvMode = DISABLE;
    adc.ADC_ExternalTrigConv = ADC_ExternalTrigConv_None;
    adc.ADC_DataAlign = ADC_DataAlign_Right;
    adc.ADC_NbrOfChannel = 1U;
    ADC_Init(ADC1, &adc);

    /* 采样时间不是越短越好；高源阻抗传感器应取更长时间。 */
    ADC_RegularChannelConfig(ADC1, ADC_Channel_0, 1U,
                             ADC_SampleTime_55Cycles5);

    ADC_Cmd(ADC1, ENABLE);
    ADC_ResetCalibration(ADC1);
    for (uint32_t left = ADC_WAIT_LIMIT;
         ADC_GetResetCalibrationStatus(ADC1) != RESET;) {
        if (left-- == 0U) return false;
    }
    ADC_StartCalibration(ADC1);
    for (uint32_t left = ADC_WAIT_LIMIT;
         ADC_GetCalibrationStatus(ADC1) != RESET;) {
        if (left-- == 0U) return false;
    }
    return true;
}

static bool ADC1_ReadOnce(uint16_t *out)
{
    ADC_ClearFlag(ADC1, ADC_FLAG_EOC);
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);
    uint32_t left = ADC_WAIT_LIMIT;
    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET) {
        if (left-- == 0U)
            return false;
    }
    *out = ADC_GetConversionValue(ADC1);
    return true;
}
```

使用时先报告原始码值：

```c
uint16_t raw;
if (ADC1_ReadOnce(&raw)) {
    uint32_t millivolt = (uint32_t)raw * 3300U / 4095U; /* 3300 只是待测假设 */
    /* 输出 raw 和 millivolt；用万用表量 VDDA 后再替换 3300。 */
}
```

## 9.3 采样时间、源阻抗和“稳定数值”的陷阱

ADC 采样时内部采样电容需要经外部信号源充电。源阻抗高、线长、传感器输出弱或采样时间过短时，连续码值可能稳定地偏向前一次电压——这比随机噪声更难发现。

| 现象 | 优先动作 |
|---|---|
| 电位器转到两端，码值不到 0/4095 | 先测实际输入/VDDA，再检查分压/接线 |
| 切换两个通道后第一个值异常 | 丢弃第一次，或增加采样时间/降低源阻抗 |
| NTC/光敏电阻抖动大 | 检查分压拓扑、滤波、采样周期、接地；不要先套软件平均 |
| 值一直接近固定数 | GPIO 是否仍为数字模式、ADC 通道是否正确、传感器是否共地 |

NTC 不是“给一个公式就能测温”：必须明确 NTC 标称阻值/B 值、串联电阻、供电、测量节点和温度范围，才可由分压电压推回电阻再推回温度。先把原始 ADC、电压和电路图记录清楚，再做拟合/校准。

## 9.4 ADC + DMA：CPU 不搬数据，不等于没有并发问题

ADC1 的规则转换 DMA 请求映射到 DMA1 Channel1。连续扫描时 DMA 可把 DR 自动搬到缓冲区：

```c
#define ADC_SAMPLE_COUNT  32U
static volatile uint16_t adc_samples[ADC_SAMPLE_COUNT];

static void ADC1_DMA_Init(void)
{
    DMA_InitTypeDef dma;
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);
    DMA_DeInit(DMA1_Channel1);

    dma.DMA_PeripheralBaseAddr = (uint32_t)&ADC1->DR;
    dma.DMA_MemoryBaseAddr = (uint32_t)adc_samples;
    dma.DMA_DIR = DMA_DIR_PeripheralSRC;
    dma.DMA_BufferSize = ADC_SAMPLE_COUNT;
    dma.DMA_PeripheralInc = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_HalfWord;
    dma.DMA_MemoryDataSize = DMA_MemoryDataSize_HalfWord;
    dma.DMA_Mode = DMA_Mode_Circular;
    dma.DMA_Priority = DMA_Priority_High;
    dma.DMA_M2M = DMA_M2M_Disable;
    DMA_Init(DMA1_Channel1, &dma);
    DMA_Cmd(DMA1_Channel1, ENABLE);
    ADC_DMACmd(ADC1, ENABLE);
}
```

`volatile` 让 CPU 每次从缓冲区重新读取，而不是沿用寄存器里的旧副本；但它不保证你读 32 个样本时 DMA 不在中间改写。要得到一致帧，可在 DMA 半传输/传输完成 ISR 中标记半块、使用双缓冲/序号，或短暂停止 DMA 后复制。不要宣称“DMA 缓冲不需要 volatile”或“加 volatile 就是线程安全”。

启动多通道扫描前还要把 `ADC_ScanConvMode=ENABLE`、`ADC_NbrOfChannel`、每个 rank 的 `ADC_RegularChannelConfig()`、触发源和连续模式一起配置。单通道配置片段不能直接变成多通道系统。

## 9.5 内部温度传感器：趋势参考，不是环境温度计

内部温度传感器接 ADC 通道 16。启用后需要稳定时间，且器件间偏移/斜率差异很大：

```c
ADC_TempSensorVrefintCmd(ENABLE);
/* 等待数据手册规定的稳定时间，再采样 ADC_Channel_16。 */
```

它测的是芯片附近结温相关信号，不等于空气温度。若没有按目标芯片数据手册做校准，适合看自热和相对变化，不适合在教材中承诺“室温 ±某度”。

## 9.6 DAC：ZET6 的 PA4/PA5 是真实模拟输出

不要删除 DAC：STM32F103ZET6 有 DAC1(PA4) 和 DAC2(PA5)。下面以 DAC1 输出静态电压为例：

```c
#include "stm32f10x_dac.h"

static void DAC1_Init(void)
{
    GPIO_InitTypeDef gpio;
    DAC_InitTypeDef dac;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_DAC, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_4;       /* DAC1_OUT */
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &gpio);

    DAC_StructInit(&dac);
    dac.DAC_Trigger = DAC_Trigger_None;
    dac.DAC_WaveGeneration = DAC_WaveGeneration_None;
    dac.DAC_LFSRUnmask_TriangleAmplitude = DAC_LFSRUnmask_Bit0;
    dac.DAC_OutputBuffer = DAC_OutputBuffer_Enable;
    DAC_Init(DAC_Channel_1, &dac);
    DAC_Cmd(DAC_Channel_1, ENABLE);
}

static void DAC1_Write12(uint16_t code)
{
    if (code > 4095U) code = 4095U;
    DAC_SetChannel1Data(DAC_Align_12b_R, code);
}
```

依次写 0、1024、2048、3072、4095，并用高阻万用表测 PA4。实际端点不必恰好是 0/VDDA：输出缓冲、负载、电源和数据手册规格都会影响。若接外部电路，先确认输入阻抗与电流；DAC 不是电源，也不能直接驱动扬声器、继电器或未知低阻负载。

要输出稳定频率的正弦/音频，不能用 `Delay_us()` 在循环中随意写 DAC；应使用定时器触发、DMA、采样率和适当的模拟滤波。第 12 章建立 DMA 边界后再做连续波形。

## 9.7 验收、排错与练习

| 现象 | 优先检查 |
|---|---|
| ADC 读数全 0/4095 | 输入电压、GPIO 模式、通道、供电/共地、超过量程 |
| ADC 偶发错误 | ADCCLK、采样时间、源阻抗、转换完成/校准状态 |
| DMA 缓冲像随机撕裂 | CPU 与 DMA 同时访问同一块；使用半传输/完成边界 |
| 内部温度离室温很远 | 这是预期风险；确认稳定时间和校准用途，不把它当环境计 |
| DAC 输出不等于公式 | VDDA、缓冲/负载、万用表带宽和端点规格 |
| DAC 没波形 | PA4/PA5 是否被其他复用占用；DAC 时钟和使能、代码/对齐是否正确 |

练习：

1. 量出实际 VDDA，比较用 3300mV 假设与实测参考换算的误差；
2. 以 1、8、32 个样本求平均，记录噪声下降和响应变慢的折衷；
3. 把 ADC DMA 缓冲拆成两个半区，在半传输/完成事件中各自处理；
4. 用 DAC 输出五个静态码，作一张“理论/实测/负载”表；
5. 画出自己的 NTC 分压电路，再决定是否有足够信息计算温度。

## 9.8 本章要点

- ADC/DAC 码值的尺度是 VDDA；先保护量程、再讨论精度。
- F103 的 ADCCLK 不超过 14MHz；72MHz PCLK2 常用 `/6` 得到 12MHz。
- 采样时间必须匹配源阻抗；“稳定”不代表“正确”。
- ADC DMA1 Channel1 能减轻 CPU 搬运，但缓冲一致性仍需明确协议；`volatile` 不是锁。
- ZET6 有两路 DAC；PA4/PA5 的输出要用仪器和负载条件验证。

---

> **上一章**：[第 8 章 · UART](./08-chapter.md)
>
> **下一章**：[第 10 章 · I2C](./10-chapter.md)

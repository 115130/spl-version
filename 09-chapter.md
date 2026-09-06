# 第 9 章 · ADC、DMA 与 DAC（SPL 版）

这一章先用 ADC1 读取外接电位器，再把连续采样交给 DMA，最后用 DAC1 在 PA4 输出一个可测的模拟电压。重点放在三个问题上：ADC 的码值怎样换成电压、采样时间为什么会影响结果、DMA 和 CPU 怎样安全共享缓冲区。

STM32F103ZET6 带 3 个 ADC 和 2 个 12 位 DAC。实验前确认模拟供电、共地和引脚冲突；本章用到的 PA0 也可以作为按键、TIM2_CH1 等功能，不能同时占用。

## 9.1 ADC 码值和参考电压

12 位 ADC 的输出范围是 0–4095。理想情况下：

```text
Vin ≈ ADC_code × VREF+ / 4095
```

在本书开发板上，VREF+ 通常和 VDDA 相关，具体接法要看原理图。代码里直接写 `3300 mV` 只是近似假设；想提高电压换算准确度，应先用万用表测实际模拟参考电压，再把实测值代入公式。

例如 ADC 读到 2048，若实测 VREF+ 为 3.28 V：

```text
Vin ≈ 2048 × 3280 / 4095
    ≈ 1640 mV
```

ADC 本身还有偏移、增益、线性和噪声误差，因此公式只能完成码值换算，不能代替校准。

## 9.2 ADC1 单通道采样

本章用 PA0，也就是 ADC1_IN0。外接一个电位器，两端接 3.3 V 和 GND，滑动端接 PA0。

ADC 时钟 ADCCLK 不能超过 STM32F103 数据手册给出的上限。第 5 章配置 PCLK2=72 MHz 时，使用 `/6` 得到 12 MHz：

```c
RCC_ADCCLKConfig(RCC_PCLK2_Div6);
```

初始化代码：

```c
#include <stdbool.h>
#include <stdint.h>
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

    ADC_RegularChannelConfig(
        ADC1,
        ADC_Channel_0,
        1U,
        ADC_SampleTime_55Cycles5
    );

    ADC_Cmd(ADC1, ENABLE);

    ADC_ResetCalibration(ADC1);
    for (uint32_t left = ADC_WAIT_LIMIT;
         ADC_GetResetCalibrationStatus(ADC1) != RESET;) {
        if (left-- == 0U)
            return false;
    }

    ADC_StartCalibration(ADC1);
    for (uint32_t left = ADC_WAIT_LIMIT;
         ADC_GetCalibrationStatus(ADC1) != RESET;) {
        if (left-- == 0U)
            return false;
    }

    return true;
}
```

这里同样要注意：`ADC_WAIT_LIMIT` 是轮询次数，不是固定时间。它只用于避免校准状态异常时无限卡死。

单次转换：

```c
static bool ADC1_ReadOnce(uint16_t *out)
{
    uint32_t left = ADC_WAIT_LIMIT;

    ADC_ClearFlag(ADC1, ADC_FLAG_EOC);
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);

    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET) {
        if (left-- == 0U)
            return false;
    }

    *out = ADC_GetConversionValue(ADC1);
    return true;
}
```

先输出原始码值，再换算电压：

```c
uint16_t raw;
uint32_t vref_mv = 3280U;   /* 用自己的实测值替换 */

if (ADC1_ReadOnce(&raw)) {
    uint32_t mv = (uint32_t)raw * vref_mv / 4095U;
    /* 通过第 8 章 UART 输出 raw 和 mv。 */
}
```

## 9.3 采样时间为什么会影响结果

ADC 输入内部有采样保持电路。采样阶段，外部信号源需要给内部采样电容充电；源阻抗越高，达到目标电压所需时间越长。

这就是 `ADC_SampleTime_55Cycles5` 的意义。采样时间过短时，高阻信号源可能来不及把采样电容充到实际输入电压，转换结果会产生偏差。切换不同 ADC 通道时，这个问题更明显，因为采样电容上可能还保留前一个通道的电压。

调试 ADC 时按下面顺序做：

- 先用万用表量 PA0 实际电压。
- 再检查 ADC 通道和 GPIO 模拟输入模式。
- 检查 ADCCLK 是否在规格范围内。
- 增大采样时间，看码值是否明显变化。
- 高阻传感器仍然不稳定时，再考虑缓冲运放、RC 滤波或调整分压阻值。

不要先靠多次平均掩盖硬件采样问题。平均可以降低随机噪声，但无法修正持续的系统偏差。

## 9.4 多次采样和平均

最简单的平均方式是连续读取若干次：

```c
static bool ADC1_ReadAverage(uint16_t *out, uint16_t count)
{
    if (count == 0U)
        return false;

    uint32_t sum = 0U;

    for (uint16_t i = 0U; i < count; ++i) {
        uint16_t sample;
        if (!ADC1_ReadOnce(&sample))
            return false;
        sum += sample;
    }

    *out = (uint16_t)(sum / count);
    return true;
}
```

平均次数越多，随机噪声通常越平滑，但更新速度也越慢。1、8、32 次平均的效果可以直接通过 UART 输出和电位器快速变化来比较。

## 9.5 ADC + DMA

CPU 逐个读取 ADC 适合低速实验。连续采样时，可以让 DMA 自动把 ADC1->DR 搬进 RAM。STM32F103 上 ADC1 的 DMA 请求使用 DMA1 Channel1。

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

这里只配置了 DMA。要真正连续采样，还需要把 ADC 配成连续转换或外部触发，并根据需求配置单通道或扫描序列。

DMA 在写 `adc_samples` 时，CPU 也可能同时读取同一数组。如果 CPU 从 0 读到 31 的过程中 DMA 已经绕回并覆盖前半区，就会得到来自两个不同采样周期的数据。

解决方法是给缓冲区建立明确边界。常见做法包括：

- 使用 DMA half-transfer 和 transfer-complete 中断，把数组分成两个半区。
- DMA 写前半区时，CPU 只处理后半区；反过来也一样。
- 需要长期保留一组样本时，在确认半区完成后复制到另一个缓冲区。

`volatile` 只能让 CPU 重新读取内存，不能保证 32 个元素属于同一个采样批次。

## 9.6 多通道扫描

多通道 ADC 不能只在单通道代码里多加几个 `ADC_RegularChannelConfig()`。至少要同步修改：

```c
adc.ADC_ScanConvMode = ENABLE;
adc.ADC_NbrOfChannel = 3U;

ADC_RegularChannelConfig(ADC1, ADC_Channel_0, 1U,
                         ADC_SampleTime_55Cycles5);
ADC_RegularChannelConfig(ADC1, ADC_Channel_1, 2U,
                         ADC_SampleTime_55Cycles5);
ADC_RegularChannelConfig(ADC1, ADC_Channel_2, 3U,
                         ADC_SampleTime_55Cycles5);
```

DMA 缓冲区中的顺序与 rank 对应。三个通道时，连续数据会按 `CH0, CH1, CH2, CH0, CH1, CH2...` 写入。处理端必须知道这个顺序，不能只把 DMA 数组当作一串无结构数字。

## 9.7 内部温度传感器

STM32F103 的内部温度传感器连接到 ADC 通道 16。使用前要启用内部温度传感器和 VREFINT 通道：

```c
ADC_TempSensorVrefintCmd(ENABLE);
```

启用后要满足数据手册规定的启动时间，再开始采样。内部温度传感器反映的是芯片结温相关电压，不等于空气温度；器件间还存在偏移和斜率误差。

在没有额外校准的情况下，它更适合观察芯片温度变化趋势，例如 CPU 长时间高负载前后是否升温。不要把一次 ADC 换算结果直接当作精确室温。

## 9.8 DAC1 输出静态电压

STM32F103ZET6 带两路 12 位 DAC，输出引脚分别是 PA4 和 PA5。本章只用 DAC1，也就是 PA4。

初始化：

```c
#include "stm32f10x_dac.h"

static void DAC1_Init(void)
{
    GPIO_InitTypeDef gpio;
    DAC_InitTypeDef dac;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_DAC, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_4;
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &gpio);

    DAC_StructInit(&dac);
    dac.DAC_Trigger = DAC_Trigger_None;
    dac.DAC_WaveGeneration = DAC_WaveGeneration_None;
    dac.DAC_OutputBuffer = DAC_OutputBuffer_Enable;
    DAC_Init(DAC_Channel_1, &dac);

    DAC_Cmd(DAC_Channel_1, ENABLE);
}

static void DAC1_Write12(uint16_t code)
{
    if (code > 4095U)
        code = 4095U;

    DAC_SetChannel1Data(DAC_Align_12b_R, code);
}
```

依次输出：

```c
DAC1_Write12(0U);
DAC1_Write12(1024U);
DAC1_Write12(2048U);
DAC1_Write12(3072U);
DAC1_Write12(4095U);
```

每次写入后用高阻万用表测 PA4。理论换算可以继续使用：

```text
Vout ≈ DAC_code × VREF+ / 4095
```

实测值受 VREF+、DAC 偏移和增益误差、输出缓冲以及负载影响。DAC 输出不能当作电源使用，也不适合直接驱动扬声器、继电器等低阻负载。

## 9.9 连续波形为什么要定时器和 DMA

如果要输出固定采样率的正弦波，可以预先准备查找表：

```c
static const uint16_t sine_lut[] = {
    /* 0..4095 的一周期样本 */
};
```

然后由定时器产生固定更新事件，DMA 每次把下一个样本写入 DAC。输出频率由两个量决定：

```text
wave_freq = sample_rate / samples_per_period
```

例如 32 个采样点、32 kHz 更新率，对应 1 kHz 波形。用主循环 `Delay_us()` 逐点写 DAC 会受到中断、函数执行时间和其他任务影响，采样间隔不稳定。

连续 DAC DMA 会在第 12 章再展开。本章只需要先把静态码值和实际输出电压对应起来。

## 9.10 验证和排错

ADC 最小实验只接电位器和 UART。先测 PA0 实际电压，再记录 ADC 原始码值和换算值。电位器转到两端时如果码值没有接近量程端点，先查实际输入、VREF+、接线和采样配置，不要先改换算公式。

DMA 实验重点看缓冲边界。用半传输和完成事件分别处理两个半区，再通过 UART 输出每半区的最小值、最大值或平均值，确认 CPU 没有处理正在被 DMA 改写的区域。

DAC 实验直接测 PA4。写 0、1024、2048、3072、4095 五个码，记录理论值和实测值；如果输出明显不对，检查 PA4 是否被其他功能占用、DAC 时钟、通道使能、VREF+ 和外部负载。

## 9.11 练习

1. 实测 VREF+ 或 VDDA，并比较使用 3300 mV 和实测值计算 ADC 电压的差异。
2. 分别做 1、8、32 次 ADC 平均，快速转动电位器，观察噪声和响应速度。
3. 把 32 个 DMA 样本分成两个半区，用 half-transfer / transfer-complete 事件分别处理。
4. 用 DAC1 输出五个固定码，记录 PA4 实测电压，并计算和理想值的差异。
5. 配置 ADC1 三通道扫描，验证 DMA 数组中的通道顺序和 rank 一致。

完成这一章后，你应该能把 ADC 原始码值、实际参考电压和外部输入联系起来，也知道 DMA 缓冲区为什么需要明确的生产/消费边界。DAC 部分只做静态输出验证；连续波形留到 DMA 章节处理。

> **上一章**：[第 8 章 · UART](./08-chapter.md)
>
> **下一章**：[第 10 章 · I2C](./10-chapter.md)

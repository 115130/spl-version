# 第 9 章 · ADC 模数转换

> **本章产出**：把 0–3.3V 的模拟电压变成可校验的数字值；能选择单次/连续/DMA 采样，并识别输入超压、噪声和参考电压误差。
>
> **前置知识**：第 3 章 GPIO、第 5 章时钟；建议已完成第 8 章 UART，便于打印原始读数。
>
> **硬件准备**：电位器或安全分压源、万用表；ADC 输入与 MCU 必须共地，任何模拟输入不得超过 3.3V。

> **本章覆盖**：ADC 基本原理、SPL 单通道采集、NTC 测温、DMA 多通道采集、DAC 输出
>
> **用到项目的哪里**：采集电位器电压、NTC 热敏电阻测温、DAC 输出模拟信号

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

## 9.2 动手：单通道读取电位器

### 接线

电位器（或可调电阻）中间脚接 PA0（ADC1 通道 0），两端接 3.3V 和 GND。

```
  3.3V ────┐
           └── 电位器 ──── PA0 (ADC1_IN0)
                    │
  GND ──────────────┘
```

没有电位器？用杜邦线直接碰 3.3V 或 GND 也能看到读数跳变。

### 单通道读取代码

```c
void ADC1_Init(void) {
    // 1. 开时钟
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_ADC1 | RCC_APB2Periph_GPIOA, ENABLE);

    // 2. PA0 配成模拟输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_AIN;         // 模拟输入（GPIO 的缓存不使能，省电）
    GPIO_Init(GPIOA, &gpio);

    // 3. ADC 配置：独立模式、单次、右对齐
    ADC_InitTypeDef adc;
    ADC_StructInit(&adc);
    adc.ADC_Mode               = ADC_Mode_Independent;
    adc.ADC_ScanConvMode       = DISABLE;   // 单通道
    adc.ADC_ContinuousConvMode = DISABLE;   // 单次，触一次转一次
    adc.ADC_ExternalTrigConv   = ADC_ExternalTrigConv_None;  // 软件触发
    adc.ADC_DataAlign          = ADC_DataAlign_Right;
    adc.ADC_NbrOfChannel       = 1;
    ADC_Init(ADC1, &adc);

    // 4. 配置通道 0：采样时间 55.5 周期（够稳了）
    ADC_RegularChannelConfig(ADC1, ADC_Channel_0, 1, ADC_SampleTime_55Cycles5);

    // 5. 使能 ADC
    ADC_Cmd(ADC1, ENABLE);

    // 6. 校准（每次上电做一次，提高精度）
    ADC_ResetCalibration(ADC1);
    while (ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1);
    while (ADC_GetCalibrationStatus(ADC1));
}

uint16_t ADC1_Read(void) {
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);           // 软件触发
    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET);  // 等转换完
    return ADC_GetConversionValue(ADC1);                     // 读结果
}
```

主循环：

```c
int main(void) {
    ADC1_Init();
    USART1_Init();    // printf 串口重定向
    while (1) {
        uint16_t val = ADC1_Read();
        float voltage = val * 3.3f / 4096.0f;
        printf("ADC=%4d, 电压=%.3fV\r\n", val, voltage);
        Delay_ms(500);
    }
}
```

### 预期输出

```
ADC= 512, 电压=0.413V
ADC= 512, 电压=0.413V  ← 旋电位器，值变化
ADC=2048, 电压=1.650V
ADC=3072, 电压=2.475V
ADC=4095, 电压=3.300V  ← 转到 3.3V
```

转到底→4095（3.3V），转到另一边→0（0V），中间平滑变化。

### 为什么需要校准

ADC 硬件有制造误差。校准过程让 ADC 芯片自动测量两个内部基准电压，算出偏移和增益误差，保存在内部寄存器。**每次上电都要做**。

---

## 9.3 DMA 多通道连续采集

### 场景

单通道单次采集是入门。实际项目中 ADC 往往同时采集多个通道（电压、电流、温度、光照）——这就需要**扫描+连续+DMA**。

### 配置差异

相比单通道，多通道的改动：

| 项目 | 单通道（9.2） | 多通道（9.3） |
|------|-------------|--------------|
| `ScanConvMode` | DISABLE | **ENABLE** |
| `ContinuousConvMode` | DISABLE | **ENABLE** |
| `NbrOfChannel` | 1 | **N**（如 3） |
| `RegularChannelConfig` | 配 1 次 | 按顺序配 N 次 |
| 读结果 | CPU 轮询读 DR | **DMA 自动搬**到 `adc_buf[]` |
| 数据更新 | 主循环每次调 `ADC1_Read()` | DMA 后台循环更新，CPU 零开销 |

### 多通道与 DMA 代码

```c
#define ADC_CHANNELS 3
uint16_t adc_buf[ADC_CHANNELS];   // DMA 自动写这里

void ADC1_DMA_Init(void) {
    // ADC 初始化（扫描+连续）
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_ADC1 | RCC_APB2Periph_GPIOA, ENABLE);
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);

    // PA0~PA2 模拟输入
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    gpio.GPIO_Pin  = GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2;
    GPIO_Init(GPIOA, &gpio);

    // ADC 扫描+连续
    ADC_InitTypeDef adc;
    ADC_StructInit(&adc);
    adc.ADC_Mode               = ADC_Mode_Independent;
    adc.ADC_ScanConvMode       = ENABLE;         // 多通道扫描
    adc.ADC_ContinuousConvMode = ENABLE;          // 自动下一轮
    adc.ADC_NbrOfChannel       = ADC_CHANNELS;   // 3 通道
    ADC_Init(ADC1, &adc);

    // 按顺序配通道：通道0 先采样，通道1 次之...
    ADC_RegularChannelConfig(ADC1, ADC_Channel_0, 1, ADC_SampleTime_55Cycles5);
    ADC_RegularChannelConfig(ADC1, ADC_Channel_1, 2, ADC_SampleTime_55Cycles5);
    ADC_RegularChannelConfig(ADC1, ADC_Channel_2, 3, ADC_SampleTime_55Cycles5);

    // DMA1 通道1：外设→内存，循环模式
    DMA_DeInit(DMA1_Channel1);
    DMA_InitTypeDef dma;
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&ADC1->DR;
    dma.DMA_MemoryBaseAddr     = (uint32_t)adc_buf;
    dma.DMA_DIR                = DMA_DIR_PeripheralSRC;
    dma.DMA_BufferSize         = ADC_CHANNELS;
    dma.DMA_Mode               = DMA_Mode_Circular;      // 循环
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;    // 地址递增
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_HalfWord;
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_HalfWord;
    dma.DMA_Priority           = DMA_Priority_High;
    DMA_Init(DMA1_Channel1, &dma);
    DMA_Cmd(DMA1_Channel1, ENABLE);

    ADC_DMACmd(ADC1, ENABLE);                            // ADC → DMA 闸门

    // 校准 + 启动
    ADC_Cmd(ADC1, ENABLE);
    ADC_ResetCalibration(ADC1);
    while (ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1);
    while (ADC_GetCalibrationStatus(ADC1));

    ADC_SoftwareStartConvCmd(ADC1, ENABLE);              // 开转！DMA 自动循环
}
```

使用：**DMA 在后台自动把 3 个通道的转换结果填入 `adc_buf[0..2]`**，CPU 零开销：

```c
int main(void) {
    ADC1_DMA_Init();
    USART1_Init();
    while (1) {
        printf("CH0=%4d CH1=%4d CH2=%4d\r\n",
               adc_buf[0], adc_buf[1], adc_buf[2]);
        Delay_ms(500);
    }
}
```

注意：`adc_buf` 不需要 `volatile`——因为 DMA 写入和 CPU 读取是**不同步的**。极端情况下可能在 DMA 写一半时读，读到「半截数据」。正式代码需要双缓冲，但这里先知道有这个问题。

---

## 9.4 动手：读内部温度传感器

STM32F103 内部有一个温度传感器，连接到 ADC1 的通道 16。**不需要任何外部接线**——只要有芯片就能测。

### 内部温度传感器代码

```c
void TempSensor_Init(void) {
    // 开启 ADC1 时钟 + 开启温度传感器
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_ADC1, ENABLE);
    ADC_TempSensorVrefintCmd(ENABLE);     // 使能内部传感器

    // ADC 初始化（单通道、单次）
    ADC_InitTypeDef adc;
    ADC_StructInit(&adc);
    adc.ADC_NbrOfChannel = 1;
    ADC_Init(ADC1, &adc);

    // 通道 16 采样时间要长（温度传感器输出阻抗高）
    ADC_RegularChannelConfig(ADC1, ADC_Channel_16, 1, ADC_SampleTime_239Cycles5);

    ADC_Cmd(ADC1, ENABLE);
    ADC_ResetCalibration(ADC1);
    while (ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1);
    while (ADC_GetCalibrationStatus(ADC1));
}

float ReadTemp(void) {
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);
    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET);
    uint16_t val = ADC_GetConversionValue(ADC1);

    // 温度公式（参考数据手册电气特性表）
    // V25 = 1.43V（25°C 时输出电压）
    // Avg_Slope = 4.3mV/°C（每度变化量）
    float voltage = val * 3.3f / 4096.0f;
    return ((1.43f - voltage) / 0.0043f) + 25.0f;
}
```

主循环：

```c
printf("芯片温度: %.1f°C\r\n", ReadTemp());
```

### 注意事项

- **精度 ±1.5°C**——内部传感器用于检测芯片是否过热，不是精密温度计
- 采样时间长（`239.5 Cycles`），因为传感器输出阻抗高
- 必须先调 `ADC_TempSensorVrefintCmd(ENABLE)`，否则读通道 16 永远返回 0

---

## 9.5 动手：读取 NTC 热敏电阻温度

你的板子上有 **ADC&NTC&PT100 模块**——NTC（负温度系数热敏电阻）的阻值随温度变化，通过 ADC 测量分压电压即可算出温度。

### 原理

```
      3.3V
        │
        ├── 固定电阻 R₀（通常 10kΩ）
        │
        └──┬─── PA1 (ADC1_IN1) — 你的 STM_ADC 接口
           │
        NTC 热敏电阻（10kΩ @ 25°C）
           │
          GND
```

NTC 阻值与温度的关系（近似公式 —— Steinhart-Hart 方程）：

```
1/T = 1/T₀ + (1/B) × ln(R/R₀)

其中：
  T   = 当前温度（开尔文）
  T₀  = 25°C = 298.15K
  R₀  = 25°C 时的阻值（10kΩ）
  B   = NTC 的 B 值（通常 3435K 或 3950K，看模块标称）
  R   = 当前阻值（由 ADC 分压算出）
```

### ADC 读数 → 温度

```c
#define B_VALUE     3950    // 你的 NTC B 值（看模块标签，常见 3435/3950）
#define R0          10000   // 25°C 时阻值 10kΩ
#define SERIES_R    10000   // 串联固定电阻 10kΩ

float Read_NTC_Temp(uint8_t adc_channel) {
    // 1. 读 ADC
    ADC_RegularChannelConfig(ADC1, adc_channel, 1, ADC_SampleTime_55Cycles5);
    ADC_SoftwareStartConvCmd(ADC1, ENABLE);
    while (ADC_GetFlagStatus(ADC1, ADC_FLAG_EOC) == RESET);
    uint16_t adc_val = ADC_GetConversionValue(ADC1);

    // 2. 分压电压 → NTC 阻值
    float voltage = adc_val * 3.3f / 4096.0f;
    float r_ntc = SERIES_R * voltage / (3.3f - voltage);   // 串联分压反算

    // 3. 阻值 → 温度（Steinhart-Hart）
    float steinhart;
    steinhart = r_ntc / R0;                    // R/R₀
    steinhart = logf(steinhart);                // ln(R/R₀)
    steinhart /= B_VALUE;                       // (1/B) × ln(R/R₀)
    steinhart += 1.0f / 298.15f;                // + 1/T₀
    steinhart = 1.0f / steinhart;               // 取倒数得 T（开尔文）
    steinhart -= 273.15f;                       // 转摄氏

    return steinhart;
}
```

NTC 模块在你的板子上接 **PA1 (ADC1_IN1)**——这就是 STM_ADC 那个接口。

### 验证

```c
int main(void) {
    ADC1_Init();              // 跟 9.2 节同样的 ADC 初始化，只是把通道配为 PA1
    USART1_Init();

    while (1) {
        float temp = Read_NTC_Temp(ADC_Channel_1);   // PA1 = 通道 1
        printf("NTC 温度: %.1f°C\r\n", temp);
        Delay_ms(1000);
    }
}
```

用手捏住 NTC 探头几秒，温度应该上升 2-5°C。

> **NTC 精度**：取决于 B 值标称精度和分压电阻误差，通常 ±1~2°C。NTC 适合测 -40°C ~ +125°C 范围。PT100 更精确（±0.1°C 级别），但需要专用的恒流源或电桥电路——如果你的模块带 PT100 接口，查模块说明书确认接线和 ADC 通道。

> **P_TOUCH（触摸按键）**：同一个模块上可能还有一个标 P_TOUCH 的接口，它连接一个电容式触摸感应传感器（TTP223 或类似芯片）。触摸感应区时，对应 GPIO 输出高/低电平。用法跟第 3 章的机械按键一样——配成 GPIO 输入读取即可，区别是触摸感应没有机械抖动，不需要消抖。具体接哪个 GPIO 脚，查你的模块说明书。

---

## 9.6 动手：DAC 输出模拟电压

ADC 是模拟→数字，**DAC** 是数字→模拟。STM32F103 内置 2 路 12 位 DAC，输出引脚固定：

| DAC 通道 | 引脚 | 说明 |
|---------|------|------|
| DAC1 | PA4 | 输出 0~Vref（通常 0~3.3V）|
| DAC2 | PA5 | 输出 0~Vref |

### DAC 初始化

```c
void DAC1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_DAC, ENABLE);

    // PA4 配成模拟输入（DAC 输出时引脚要配成模拟）
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_4;
    gpio.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &gpio);

    // DAC 通道 1 使能
    DAC_InitTypeDef dac;
    DAC_StructInit(&dac);
    dac.DAC_Trigger = DAC_Trigger_None;       // 软件触发
    dac.DAC_WaveGeneration = DAC_WaveGeneration_None;
    dac.DAC_OutputBuffer = DAC_OutputBuffer_Enable;  // 输出缓冲（可驱动负载）
    DAC_Init(DAC_Channel_1, &dac);
    DAC_Cmd(DAC_Channel_1, ENABLE);
}
```

### 输出指定电压

12 位 DAC：输出值 0~4095 对应 0~Vref（3.3V）。每步 = 3.3V / 4096 ≈ 0.8mV。

```c
// 设 DAC 输出（值 0~4095）
void DAC1_Set(uint16_t val) {
    DAC_SetChannel1Data(DAC_Align_12b_R, val);
}

// 设 DAC 输出电压（0~3.3V）
void DAC1_SetVoltage(float v) {
    if (v < 0)        v = 0;
    if (v > 3.3f)     v = 3.3f;
    uint16_t val = (uint16_t)(v / 3.3f * 4095.0f + 0.5f);
    DAC_SetChannel1Data(DAC_Align_12b_R, val);
}
```

### 验证：输出三角波 / 正弦波

```c
int main(void) {
    DAC1_Init();
    USART1_Init();

    printf("DAC 输出三角波（PA4 接示波器或万用表）\r\n");

    while (1) {
        // 三角波：0→4095→0→4095...
        for (uint16_t i = 0; i < 4095; i++) {
            DAC1_Set(i);
            Delay_us(10);       // 频率约 24Hz（1/(4096×2×10µs)）
        }
        for (uint16_t i = 4095; i > 0; i--) {
            DAC1_Set(i);
            Delay_us(10);
        }
    }
}
```

**效果**：用万用表量 PA4 引脚，电压在 0~3.3V 之间匀速摆动。接 LED 串电阻能看到呼吸灯效果。

> **注意**：DAC 输出缓冲器驱动能力有限（约 5mA），不能直接驱动电机或大负载。接个 LED+电阻或示波器观察没问题。

---

## 9.7 SPL vs HAL ADC 对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 初始化 | `ADC_Init()` + `ADC_Cmd()` | `HAL_ADC_Init()` + `HAL_ADC_Start()` |
| 校准 | `ADC_ResetCalibration()` + `ADC_StartCalibration()` | `HAL_ADCEx_Calibration_Start()` |
| 读单通道 | 软件触发 + 轮询 EOC | `HAL_ADC_Start()` + `HAL_ADC_PollForConversion()` |
| 读温度 | `ADC_Channel_16` + 公式计算 | CubeMX 勾选内部温度传感器 |
| DMA 多通道 | `ADC_DMACmd()` + 手配 DMA | `HAL_ADC_Start_DMA()` + 回调 |
| 通道配置 | `ADC_RegularChannelConfig()` | CubeMX 自动 + `ADC_ChannelConfTypeDef` |

SPL 的 ADC 配置更透明——配通道顺序、采样时间、校准步骤都在代码里。HAL 把这些封装到 `HAL_ADC_ConfigChannel()` 中，更简洁但学到的细节更少。

## 9.8 模拟输入的电气边界

ADC 读数正确的前提不是“代码调用了 ADC1_Read”，而是输入电路满足条件：

- PA0/PA1 等 ADC 引脚电压必须在 GND 到模拟参考电压之间；
- 未使用的 ADC 输入不能悬空，否则读数会随机漂移；
- 高阻传感器或电阻分压需要更长采样时间；
- 用万用表量实际电压，再与 ADC 换算结果对比；
- 任何可能高于 3.3V 的信号都应先分压或用合适的前端电路；
- ADC 可测电压，不等于 GPIO 能承受任意外部模拟源。

第一次实验优先用电位器或 3.3V/GND 分压；不要直接把未知模块输出接到 ADC。

## 9.9 ADC 实测、误差与排错

最低实验要求不是“打印了一个数字”，而是让数字与万用表读数趋势一致：

1. 用万用表测电位器滑动端电压；
2. 打印 `raw`、换算电压和采样次数；
3. 从接近 0V 缓慢转到接近 3.3V，确认数值单调变化；
4. 再打开 DMA 连续采样，比较原始值的抖动范围。

| 现象 | 优先检查 |
|---|---|
| 始终为 0 或满量程 | GPIO 是否为模拟输入、通道号/ADC 时钟、输入是否真的有电压 |
| 数值跳动很大 | 信号源阻抗、采样时间、供电噪声、GND、软件平均 |
| 电压换算整体偏差 | 实际 Vref、分压比、校准假设 |
| 多通道数据错位 | 规则通道顺序、DMA 缓冲区长度和半传输/完成边界 |
| 板子异常或 ADC 损坏风险 | 输入是否超过 3.3V；立即断开未知信号 |

练习：为一个通道记录 100 次采样的最小值、最大值和平均值；解释为什么平均能减小随机噪声，却不能修复错误接线。

## 9.10 本章要点

- ADC = 模拟→数字桥梁，12 位分辨率 → 4096 个台阶，每步 0.8mV（3.3V 参考）
- STM32 ADC 是逐次逼近型（SAR）——二分法比较 12 次得出 12 位结果
- **每条 GPIO 配成模拟输入前必须关数字功能**（`GPIO_Mode_AIN`），否则内部数字缓存干扰模拟信号
- **每次上电必须做 ADC 校准**——否则读数可能整体偏移几十个 LSB
- DMA + ADC = 嵌入式「数据采集」最佳拍档：DMA 负责搬运，CPU 负责计算
- 内部温度传感器很方便但不精确（±1.5°C），用于检测芯片过热而非环境温度

---

> **上一章**：[第 8 章 · 串口通信 UART](./08-chapter.md)
>
> **下一章**：[第 10 章 · I2C 总线](./10-chapter.md)
>
> 你学会了「感知电压」。下一步学「设备之间通信」——I2C 是芯片间最常用的协议，一根数据线一根时钟线，连 OLED、传感器全都靠它。

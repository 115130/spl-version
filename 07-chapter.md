# 第 7 章 · 定时器：从公式到波形（SPL 版）

这一章用 TIM2 和 TIM3 完成三件事：周期中断、PWM 输出和输入捕获。重点不是记配置结构体，而是从当前时钟树算出 TIMCLK、PSC、ARR、CCR，再用实际波形验证结果。

前面已经配置过时钟、中断和 GPIO。本章所有示例都沿用第 5 章的时钟配置；如果系统时钟或 APB 分频发生变化，定时器参数也要重新计算。

## 7.1 先确认定时器资源

STM32F103ZET6 有多类定时器。TIM1、TIM8 属于高级控制定时器；TIM2–TIM5 是通用定时器；TIM6、TIM7 是基本定时器，没有外部输入输出通道。SysTick 属于 Cortex-M3 内核，继续作为本书的 1 ms 系统时基。

本章使用：

- TIM2：周期中断或输入捕获。
- TIM3_CH3：PWM 输出，默认引脚 PB0。
- PA0：TIM2_CH1 输入捕获。

PB0、PA0 在前面章节已经被其他实验使用过，做本章实验时要断开冲突模块。一个定时器实例也不要同时拿来做两套互相冲突的实验配置。

## 7.2 先算 TIMCLK

向上计数时，最基本的公式是：

```text
counter_tick = TIMCLK / (PSC + 1)
update_freq  = TIMCLK / ((PSC + 1) × (ARR + 1))
```

PWM 的周期同样由 PSC 和 ARR 决定。

STM32F1 的 APB 定时器有一条特殊规则：APB 预分频为 `/1` 时，定时器时钟等于 PCLK；APB 预分频大于 1 时，定时器时钟等于 `2 × PCLK`。

可以从当前 RCC 配置计算：

```c
static uint32_t APB1_TimerClockHz(void)
{
    RCC_ClocksTypeDef clocks;
    RCC_GetClocksFreq(&clocks);

    if ((RCC->CFGR & RCC_CFGR_PPRE1) == 0U)
        return clocks.PCLK1_Frequency;

    return clocks.PCLK1_Frequency * 2U;
}

static uint32_t APB2_TimerClockHz(void)
{
    RCC_ClocksTypeDef clocks;
    RCC_GetClocksFreq(&clocks);

    if ((RCC->CFGR & RCC_CFGR_PPRE2) == 0U)
        return clocks.PCLK2_Frequency;

    return clocks.PCLK2_Frequency * 2U;
}
```

第 5 章的 72 MHz 配置中：

```text
HCLK  = 72 MHz
PCLK1 = 36 MHz，APB1=/2
PCLK2 = 72 MHz，APB2=/1

TIM2–TIM7 TIMCLK = 72 MHz
TIM1/TIM8 TIMCLK = 72 MHz
```

这里得到 72 MHz 是当前配置的结果。系统回退到 HSI 或修改 APB 分频后，不能继续照搬 `PSC=71`。

## 7.3 周期中断

假设 TIM2 的 TIMCLK 已确认是 72 MHz，要产生 1 kHz 更新事件，可以先把计数频率降到 1 MHz：

```text
PSC = 71
72 MHz / (71 + 1) = 1 MHz
```

再让计数器数 1000 个 tick：

```text
ARR = 999
1 MHz / (999 + 1) = 1 kHz
```

对应代码：

```c
static void TIM2_Update1kHz_Init(void)
{
    TIM_TimeBaseInitTypeDef tim;
    NVIC_InitTypeDef nvic;

    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);

    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler = 71U;
    tim.TIM_Period = 999U;
    tim.TIM_CounterMode = TIM_CounterMode_Up;
    TIM_TimeBaseInit(TIM2, &tim);

    TIM_ClearITPendingBit(TIM2, TIM_IT_Update);
    TIM_ITConfig(TIM2, TIM_IT_Update, ENABLE);

    nvic.NVIC_IRQChannel = TIM2_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 1U;
    nvic.NVIC_IRQChannelSubPriority = 0U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);

    TIM_Cmd(TIM2, ENABLE);
}

void TIM2_IRQHandler(void)
{
    if (TIM_GetITStatus(TIM2, TIM_IT_Update) != RESET) {
        TIM_ClearITPendingBit(TIM2, TIM_IT_Update);

        /* 置事件、递增轻量计数等。 */
    }
}
```

本书已经用 SysTick 提供公共 1 ms 时间，不需要再让 TIM2 维护另一套全局毫秒计数。TIM2 更适合留给独立周期任务、PWM、输入捕获或后面的微秒时基。

## 7.4 PWM

PWM 模式 1、有效高、向上计数时，通常在 `CNT < CCR` 时输出有效。假设 `ARR=999`，计数器每周期经过 0–999 共 1000 个计数值。

对应占空比约为：

```text
CCR = 0     → 0%
CCR = 250   → 25%
CCR = 500   → 50%
CCR = 750   → 75%
CCR = 1000  → 100%
```

`CCR=999` 时实际是 999/1000，约 99.9%。这一点在做精确 PWM 时要分清。

下面用 PB0 / TIM3_CH3 输出 1 kHz PWM。实验前先确认 PB0 没有连接前面章节的 DS18B20 或其他模块。

```c
static void TIM3_CH3_PWM_Init(void)
{
    GPIO_InitTypeDef gpio;
    TIM_TimeBaseInitTypeDef tim;
    TIM_OCInitTypeDef oc;

    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM3, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    /* 仅适用于 TIMCLK = 72 MHz。 */
    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler = 71U;
    tim.TIM_Period = 999U;
    tim.TIM_CounterMode = TIM_CounterMode_Up;
    TIM_TimeBaseInit(TIM3, &tim);

    TIM_OCStructInit(&oc);
    oc.TIM_OCMode = TIM_OCMode_PWM1;
    oc.TIM_OutputState = TIM_OutputState_Enable;
    oc.TIM_Pulse = 0U;
    oc.TIM_OCPolarity = TIM_OCPolarity_High;
    TIM_OC3Init(TIM3, &oc);

    TIM_OC3PreloadConfig(TIM3, TIM_OCPreload_Enable);
    TIM_ARRPreloadConfig(TIM3, ENABLE);

    TIM_Cmd(TIM3, ENABLE);
}
```

用千分比设置占空比：

```c
static void PWM_SetPermille(uint16_t permille)
{
    if (permille > 1000U)
        permille = 1000U;

    /* ARR=999，因此一周期有 1000 个计数值。 */
    TIM_SetCompare3(TIM3, permille);
}
```

这里 `permille=1000` 时 CCR=1000，大于 ARR，整个周期都满足 `CNT < CCR`，得到持续有效输出。

如果以后 ARR 不再是 999，可以按周期计数数目计算：

```c
uint32_t period_counts = (uint32_t)TIM3->ARR + 1U;
uint32_t ccr = (period_counts * permille) / 1000U;
TIM_SetCompare3(TIM3, ccr);
```

CCR 和 ARR 开启 preload 后，更新通常会在下一个更新事件装入有效寄存器，避免在周期中间直接改变比较值造成不完整周期。

### 呼吸灯步进

PWM 占空比可以在主循环里按固定时间间隔修改，不需要再开一个专门的高频 ISR。

```c
static uint16_t duty;
static int8_t direction = 1;

static void Breath_Step(void)
{
    int32_t next = (int32_t)duty + direction * 5;

    if (next >= 1000) {
        next = 1000;
        direction = -1;
    } else if (next <= 0) {
        next = 0;
        direction = 1;
    }

    duty = (uint16_t)next;
    PWM_SetPermille(duty);
}
```

用第 5 章的毫秒时基每约 10–20 ms 调一次即可。视觉上的“均匀变亮”还会受到 LED 和人眼非线性响应影响，这里先只验证 PWM 占空比本身。

## 7.5 输入捕获

输入捕获会在指定边沿到来时，把当前 CNT 的值锁存进 CCR。这样软件不需要恰好在边沿出现的那个时刻读取计数器。

本章把 PB0 / TIM3_CH3 的 1 kHz PWM 用杜邦线接到 PA0 / TIM2_CH1，再测两个上升沿之间的计数差。PA0 此时不能继续接按键。

TIM2 仍配置成 1 MHz tick：

```c
static volatile uint16_t g_period_ticks;
static volatile uint8_t g_period_ready;

static void TIM2_CH1_Capture_Init(void)
{
    GPIO_InitTypeDef gpio;
    TIM_TimeBaseInitTypeDef tim;
    TIM_ICInitTypeDef ic;
    NVIC_InitTypeDef nvic;

    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler = 71U;
    tim.TIM_Period = 0xFFFFU;
    TIM_TimeBaseInit(TIM2, &tim);

    TIM_ICStructInit(&ic);
    ic.TIM_Channel = TIM_Channel_1;
    ic.TIM_ICPolarity = TIM_ICPolarity_Rising;
    ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
    ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
    ic.TIM_ICFilter = 0U;
    TIM_ICInit(TIM2, &ic);

    TIM_ClearITPendingBit(TIM2, TIM_IT_CC1);
    TIM_ITConfig(TIM2, TIM_IT_CC1, ENABLE);

    nvic.NVIC_IRQChannel = TIM2_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 1U;
    nvic.NVIC_IRQChannelSubPriority = 1U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);

    TIM_Cmd(TIM2, ENABLE);
}
```

ISR 保存相邻两次捕获值：

```c
void TIM2_IRQHandler(void)
{
    static uint16_t previous;
    static uint8_t have_previous;

    if (TIM_GetITStatus(TIM2, TIM_IT_CC1) != RESET) {
        uint16_t captured = TIM_GetCapture1(TIM2);
        TIM_ClearITPendingBit(TIM2, TIM_IT_CC1);

        if (have_previous != 0U) {
            g_period_ticks = (uint16_t)(captured - previous);
            g_period_ready = 1U;
        }

        previous = captured;
        have_previous = 1U;
    }
}
```

1 MHz tick 下，1 kHz 输入的周期应接近 1000 tick：

```text
period_us ≈ g_period_ticks
freq_hz   ≈ 1 000 000 / g_period_ticks
```

`uint16_t` 减法经过强制转换后按 16 位模运算得到差值，因此允许两个边沿之间跨过一次计数器回绕点。前提是实际间隔小于 65536 tick；在 1 MHz 下就是小于约 65.536 ms。

更低频的输入需要降低计数频率、统计更新溢出次数，或者改用更宽的计数方案。不能拿当前配置直接测几秒钟的脉冲。

`TIM_ICFilter=0` 适合本章这种板内回环的干净数字波形。测长线、机械触点或噪声较大的输入时，需要根据输入特性选择滤波和前级电路。

## 7.6 做一个 1 MHz 微秒计时器

第 4 章的 DS18B20、DHT11 需要微秒级时间。与其用空循环估算指令时间，可以把一个空闲通用定时器配置成 1 MHz 自由运行计数器。

例如 TIM4 的 TIMCLK 为 72 MHz 时：

```c
static void TimerUs_Init(void)
{
    TIM_TimeBaseInitTypeDef tim;

    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM4, ENABLE);

    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler = 71U;
    tim.TIM_Period = 0xFFFFU;
    tim.TIM_CounterMode = TIM_CounterMode_Up;
    TIM_TimeBaseInit(TIM4, &tim);

    TIM_Cmd(TIM4, ENABLE);
}

static uint16_t TimerUs_Now16(void)
{
    return TIM_GetCounter(TIM4);
}

static void TimerUs_Delay(uint16_t us)
{
    uint16_t start = TimerUs_Now16();

    while ((uint16_t)(TimerUs_Now16() - start) < us) {
    }
}
```

这个实现适用于小于 65536 us 的单次等待，足够覆盖本书单线协议里的短时隙。它仍是忙等，只是时间来源由硬件定时器提供，精度和编译优化无关得多。

如果系统时钟发生变化，TIM4 的 PSC 也必须按新的 TIMCLK 重算。需要更长的微秒时间戳时，可以结合更新中断扩展成 32 位计数。

## 7.7 输入电压仍然要先确认

定时器输入捕获只是数字输入功能，不会自动处理电压转换。把外部模块信号接到 PA0 前，先查 STM32F103ZET6 数据手册中的该引脚电气规格和模块输出电平。

例如某些超声波模块的 Echo 可能输出接近其供电电压。如果信号超出目标引脚允许范围，应使用合适的分压或电平转换电路，再接入 MCU。

## 7.8 验证和排错

每次配置定时器前，先把计算过程写出来：

```text
PCLK1 = 36 MHz
APB1  = /2
TIMCLK = 72 MHz

PSC = 71
counter_tick = 1 MHz

ARR = 999
period = 1000 us
frequency = 1 kHz
```

然后用逻辑分析仪或示波器测实际输出。PWM 的高电平宽度和周期都应该能直接量出来，输入捕获计算出的频率也应该和输出波形一致。

常见问题：

- PWM 频率正好差约一倍：先查 APB 分频和定时器 ×2 规则。
- PWM 没有波形：查 TIM/GPIO 时钟、通道、引脚复用和资源冲突。
- 占空比方向反了：查 PWM 极性和外部负载接法。
- 更新中断不进：查 TIM 中断使能、pending、NVIC 和 Handler 名称。
- 捕获值跳动：查输入电平、共地、噪声、边沿设置和滤波。
- 低频测量错误：确认计数器是否在两个有效边沿之间回绕超过一个完整周期。

## 7.9 练习

1. 分别在 72 MHz 正常启动和 HSI 回退状态下计算 TIM2 的 PSC，使计数 tick 都保持 1 MHz。
2. 把 PB0 的 1 kHz PWM 回接 PA0，用 TIM2 捕获周期，再和逻辑分析仪实测结果比较。
3. 分别设置 0%、25%、50%、75%、100% 占空比，测量一个完整周期内的高电平时间。
4. 要测最长 2 s 的脉冲，如果使用 10 kHz tick，计算计数分辨率和 16 位定时器一次回绕时间，并判断是否需要溢出计数。

完成这一章后，PSC、ARR 和 CCR 都应该来自实际 TIMCLK 和目标时间，不再靠复制固定数字。下一章 UART 的波特率计算也使用同样的方法：先确认输入时钟，再配置分频。

> **上一章**：[第 6 章 · 中断、事件与并发边界](./06-chapter.md)
>
> **下一章**：[第 8 章 · 串口通信 UART](./08-chapter.md)

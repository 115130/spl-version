# 第 7 章 · 定时器：从公式到波形（SPL 版）

> **本章产出**：能从当前时钟树算出 TIMCLK、配置周期/PWM/输入捕获，并用回环波形而不是肉眼猜测验证结果。
>
> **前置知识**：第 5 章时钟与时基、第 6 章中断、第 3 章 GPIO。
>
> **通过标准**：写出 `TIMCLK`、PSC、ARR、CCR 的计算；实测 PWM 频率与占空比；输入捕获得到与已知回环频率相符的周期。

---

## 7.1 定时器资源先于代码

ZET6 有高级控制、通用和基本定时器。不同实例的通道/引脚、总线和功能不同；一个定时器一次只能承担一个清晰角色（例如 PWM 或 1MHz 输入捕获），不要把教材片段直接拼在同一实例上。

| 类别 | 实例 | 本章用法 |
|---|---|---|
| 高级控制 | TIM1、TIM8 | 互补 PWM、死区、刹车等高级电机用途（本章不展开） |
| 通用 | TIM2–TIM5 | 周期中断、PWM、输入捕获 |
| 基本 | TIM6、TIM7 | 无外部通道的时基/DAC 触发 |
| 内核 | SysTick | 1ms 系统时基，不替代微秒协议计时 |

使用前在资源表登记：定时器实例、通道、GPIO 复用、该 GPIO 是否与按键/ADC/传感器冲突、所处 APB。PB0 的 TIM3_CH3、PA0 的 TIM2_CH1 都是外接实验默认映射，且会与前面章节的默认实验冲突。

## 7.2 第一步永远是求 TIMCLK

向上计数定时器的基本关系是：

```text
counter_tick = TIMCLK / (PSC + 1)
update_freq  = TIMCLK / ((PSC + 1) × (ARR + 1))
PWM_freq     = update_freq
```

TIMCLK 不能硬编码为 72MHz。APB 预分频为 /1 时，TIMCLK=PCLK；为 /2、/4、/8、/16 时，TIMCLK=2×PCLK。可以从 RCC 当前状态推导：

```c
static uint32_t APB1_TimerClockHz(void)
{
    RCC_ClocksTypeDef clocks;
    RCC_GetClocksFreq(&clocks);
    return (RCC->CFGR & RCC_CFGR_PPRE1) == 0U
         ? clocks.PCLK1_Frequency
         : clocks.PCLK1_Frequency * 2U;
}

static uint32_t APB2_TimerClockHz(void)
{
    RCC_ClocksTypeDef clocks;
    RCC_GetClocksFreq(&clocks);
    return (RCC->CFGR & RCC_CFGR_PPRE2) == 0U
         ? clocks.PCLK2_Frequency
         : clocks.PCLK2_Frequency * 2U;
}
```

在第 5 章的典型配置中，PCLK1=36MHz、APB1=/2，因此 TIM2–7 的 TIMCLK=72MHz；这只是**该配置下的推导结果**。若系统回退到 HSI、或你改变 APB 分频，下面的 PSC/ARR 必须重算。

## 7.3 周期中断：短 ISR，明确时基

若 TIM2 的 TIMCLK 已确认为 72MHz，要得到 1kHz 更新事件：`PSC=71` 先得到 1MHz tick，`ARR=999` 再得到 1ms。NVIC 分组在第 6 章启动时已统一配置；这里只分配优先级。

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
        /* 最多置标志/递增轻量计数；不要做 printf、Delay 或轮询。 */
    }
}
```

不要为了“我需要 1ms”同时让 SysTick 和 TIM2 各自跑一套无主的系统时基。第 0 章以 SysTick 为公共毫秒时间；TIM2 只在你确有独立周期任务、PWM 或捕获需求时使用。

## 7.4 PWM：CCR 是占空比，不是“亮度百分比”

PWM 模式 1、有效高时，通常 `CNT < CCR` 输出有效。对 `ARR=999`：

```text
CCR=0    → 0%
CCR=250  → 约 25%
CCR=500  → 约 50%
CCR=999  → 接近 100%
```

极性、外接 LED 的接法和通道模式都会改变“高电平是否等于亮”。先用逻辑分析仪验证波形，再谈视觉亮度；人眼感知也不是线性响应。

下面使用外接 PB0/TIM3_CH3 生成 1kHz PWM。开始前断开 DS18B20，并确认没有把板载 LED 假定在 PB0：

```c
static void TIM3_CH3_PWM_Init(void)
{
    GPIO_InitTypeDef gpio;
    TIM_TimeBaseInitTypeDef tim;
    TIM_OCInitTypeDef oc;

    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM3, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;          /* TIM3_CH3 默认复用 */
    gpio.GPIO_Mode = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;    /* 1kHz 不需要 50MHz 边沿 */
    GPIO_Init(GPIOB, &gpio);

    /* 仅当 APB1_TimerClockHz()==72MHz 时，PSC/ARR 如下。 */
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

static void PWM_SetPermille(uint16_t permille)
{
    if (permille > 1000U)
        permille = 1000U;
    /* ARR=999: 1000‰ 映射到 999，避免写出本例的计数范围。 */
    TIM_SetCompare3(TIM3, (uint32_t)permille * 999U / 1000U);
}
```

`TIM_OCxPreloadConfig` 让 CCR 更新在下一个更新事件生效，减少周期中间改占空比带来的毛刺。PWM 参数变更后应重新实测频率和占空比。

### 不会回绕的呼吸步进

不要让 `uint16_t duty += int8_t dir`：当 `dir=-1` 且 duty=0 时会下溢到 65535。使用有符号临时变量并夹紧：

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

用第 5 章毫秒状态机每 10–20ms 调一次 `Breath_Step()`，不必为呼吸灯再开一个 50Hz ISR。

## 7.5 输入捕获：先测可控波形，再测未知信号

输入捕获把边沿到来时的 CNT 硬件锁存到 CCR。最小可验证实验是把上面的 PB0/TIM3_CH3 用一根杜邦线接到 PA0/TIM2_CH1，测两个上升沿间隔。此时 PA0 不能同时接按键或 ADC。

为避免“1MHz、16 位计数器只能测 65.536ms，却拿去测两秒按键”的矛盾，本实验测 1kHz 回环：周期约 1000 tick，远小于一次回绕。代码用无符号 16 位差值自动处理最多一次回绕：

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
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING; /* 外部 PWM 主动驱动 */
    GPIO_Init(GPIOA, &gpio);

    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler = 71U;     /* TIMCLK=72MHz 时：1MHz tick */
    tim.TIM_Period = 0xFFFFU;
    TIM_TimeBaseInit(TIM2, &tim);

    TIM_ICStructInit(&ic);
    ic.TIM_Channel = TIM_Channel_1;
    ic.TIM_ICPolarity = TIM_ICPolarity_Rising;
    ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
    ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
    ic.TIM_ICFilter = 0U;        /* 仅对已知干净的回环波形使用 0 */
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

主循环先用第 6 章的临界区模式取走 `g_period_ticks`，再计算：`freq_hz = 1000000 / period_ticks`。本例只能可靠测量小于一个 16 位回绕周期的信号；更低频/更长脉冲需要降低 tick 频率、统计更新溢出，或选合适的定时器/输入方案。

机械按键不是干净的输入捕获源。若你必须测按键时长，先做硬件/软件消抖，再按期望最大时长选择 tick 与溢出计数；不要把“ICFilter=0”与两秒长按混在同一示例。

### 输入电压安全

若扩展到 HC-SR04，Echo 常见为 5V。未确认目标 GPIO 的电气容限前，使用分压/电平转换到 3.3V；绝不因为“输入捕获能读边沿”就把未知电压直接接 PA0。

## 7.6 验收、排错与练习

每次实验先写出完整等式和资源占用，例如：

```text
PCLK1 = 36MHz, APB1=/2 → TIMCLK=72MHz
PSC=71 → counter_tick=1MHz
ARR=999 → PWM=1kHz
CCR=250 → 有效高约25%
```

| 现象 | 优先检查 |
|---|---|
| PWM 频率差一倍 | APB 预分频与 TIMCLK ×2 规则；不是先改 ARR |
| PWM 没有引脚波形 | RCC、通道/引脚复用、冲突、是否选择了正确实例/通道 |
| 占空比反向 | 有效极性和 LED 接法，不要只看软件的“高” |
| 更新 ISR 不进 | pending 清除、TIM_ITConfig、NVIC 分组/优先级、Handler 名称 |
| 捕获数值跳动 | 输入电平、接地、边沿、滤波、噪声与计数回绕范围 |
| 长脉冲数值错误 | 16 位范围不够；重新选 tick 或加更新溢出计数 |

练习：

1. 在运行 72MHz 与 HSI 回退两种状态下，重新计算而不是复用 `PSC=71`；
2. 把 PB0 的 1kHz PWM 回接 PA0，用捕获值算出频率并与逻辑分析仪对照；
3. 把 `PWM_SetPermille(0/250/500/750/1000)` 逐项测量高电平宽度；
4. 为一个最长 2 秒的脉冲选择 10kHz tick，算出分辨率、一次回绕范围，以及是否还需要溢出计数。

## 7.7 本章要点

- PSC、ARR、CCR 都要从实际 TIMCLK 推导；TIMCLK 由 PCLK 和 APB 预分频决定。
- PWM 的可见效果不能替代频率/占空比测量；先测波形，再调整极性与负载。
- 同一 GPIO/定时器的不同教材实验互斥，先登记资源再组合。
- 输入捕获适合硬件锁存边沿；测量范围由 tick 频率、ARR 和溢出处理共同决定。
- 机械按键、未知电压、长脉冲都不是“复制一个 ICFilter=0 示例”就能安全处理的信号。

---

> **上一章**：[第 6 章 · 中断、事件与并发边界](./06-chapter.md)
>
> **下一章**：[第 8 章 · 串口通信 UART](./08-chapter.md)

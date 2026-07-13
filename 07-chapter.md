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

## 7.4 PWM：脉冲宽度调制

### 什么是 PWM

PWM（Pulse Width Modulation，脉冲宽度调制）就是用**数字信号模拟模拟输出**。

一根 GPIO 引脚只能输出 0V 或 3.3V——没有中间值。但如果你让这根引脚在 3.3V 和 0V 之间快速切换：

- 3.3V 占 25% 的时间 → LED 看起来像 25% 亮度（实际是快速闪烁）
- 3.3V 占 50% 的时间 → LED 看起来像 50% 亮度
- 3.3V 占 75% 的时间 → LED 看起来像 75% 亮度

```
     ┌──────────── 周期 T ────────────┐
     │                                 │
     │← 高电平宽度 t →│                 │
3.3V ─┐               ┌──               ┌──
      │               │                 │
  0V  ┘               └───────────────  ┘
          ↑
        占空比 = t/T × 100%

     t=0.25T → 占空比 25%  → 灭多亮少
     t=0.50T → 占空比 50%  → 半亮半灭
     t=0.75T → 占空比 75%  → 亮多灭少
```

人眼和许多模拟电路有惯性和低通特性——它们看到的是平均值。这就是 PWM 的核心思想：**快速切换方波，用占空比控制等效模拟量**。

### 用定时器产生 PWM

STM32 的通用定时器（TIM2-5）每个通道都有一个**捕获/比较寄存器 CCR**。定时器 CNT 不停从 0 数到 ARR，每个时刻比较 CNT 和 CCR：

- `CNT < CCR` → 通道输出高电平
- `CNT ≥ CCR` → 通道输出低电平

```
CNT 不断计数:  0 ─ 1 ─ 2 ─ 3 ─ 4 ─ 5 ─ ... ─ 999 ─ 0 ─ 1 ...
                ↑                       ↑
            CCR=250 输出变低        CNT=0 变高

输出:  ┌─────── 高 ───────┐ ┌── 高 ──
       │  (CNT < CCR)    │ │
       └─── 低 ──────────┘ └──────────
                ↑              ↑
            捕获比较            自动重装载
            匹配翻转            从 0 重新开始
```

所以调节占空比只需要改 CCR：`TIM_SetCompare3(TIM3, duty)`。硬件自动做周期和比较，不占用 CPU。

### PWM 频率怎么选

PWM 频率 = 定时器时钟 / (PSC+1) / (ARR+1)：

| 用途 | 推荐频率 | 原因 |
|------|---------|------|
| LED 调光 | 1kHz | 超过人眼闪烁识别阈值即可 |
| 舵机控制 | 50Hz | 标准舵机协议要求 20ms 周期 |
| 电机驱动 | 10-20kHz | 低于此频人耳能听到电机啸叫 |
| 音频输出 | 44kHz+ | 人耳范围之外 |

### SPL PWM 呼吸灯示例

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

输入捕获用途：测频率、测占空比、解码红外遥控。在普中玄武上，我们用板载按键实测——物理世界到定时器的直观体验。

### 输入捕获的原理

定时器 CNT 持续计数，当外部信号在捕获引脚上产生边沿时，硬件自动把当前 CNT 值「咔嚓」一下锁存到 CCRx 寄存器，同时触发中断：

```
外部信号 → GPIO（输入模式）
                │
           TIMx_CHy 捕获输入
                │
       边沿检测器 → 检测到指定边沿
                │
       硬件锁存 CNT → CCRx
                │
         CCx 中断 → CPU 跳 ISR
```

两次捕获的 CNT 差值 = 边沿之间的时间间隔（以定时器 tick 为单位）。知道 tick 频率就能算出真实时间。

### 捕获边沿选择

CNT 从 0 数到 0xFFFF（ARR=最大值）后溢出归零。捕获可以选择在上升沿或下降沿触发：

```
上升沿捕获：        下降沿捕获：
   ────┐              ──┐────
       │                  │
       └──               └──
       ↑ 锁存 CNT         ↑ 锁存 CNT

测量高电平宽度 = 下降沿捕获值 - 上升沿捕获值
测量低电平宽度 = 上升沿捕获值 - 下降沿捕获值
```

### SPL 输入捕获初始化（TIM2 CH1 = PA0）

PA0 同时是 TIM2 的通道 1 输入捕获引脚。我们用它测量板载按键的按下时间：

```c
void TIM2_IC_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);

    // PA0 = TIM2_CH1，浮空输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // 时基：72MHz / 72 = 1MHz → 1μs 分辨率，最大可测 65.5ms
    TIM_TimeBaseInitTypeDef tim;
    TIM_TimeBaseStructInit(&tim);
    tim.TIM_Prescaler   = 71;       // 72MHz / 72 = 1MHz
    tim.TIM_Period      = 0xFFFF;   // ARR = 65535，最大 65535μs
    TIM_TimeBaseInit(TIM2, &tim);

    // 输入捕获 CH1：先从下降沿开始（按键按下 = 高→低）
    TIM_ICInitTypeDef ic;
    ic.TIM_Channel     = TIM_Channel_1;
    ic.TIM_ICPolarity  = TIM_ICPolarity_Falling;   // 下降沿触发
    ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
    ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
    ic.TIM_ICFilter    = 0;        // 不滤波（信号干净）
    TIM_ICInit(TIM2, &ic);

    TIM_ITConfig(TIM2, TIM_IT_CC1, ENABLE);   // 开捕获中断
    NVIC_EnableIRQ(TIM2_IRQn);
    TIM_Cmd(TIM2, ENABLE);
}
```

### 中断服务函数

```c
static uint32_t cap_start = 0;
volatile uint32_t press_time_us = 0;  // 按键持续时长（微秒）

void TIM2_IRQHandler(void) {
    if (TIM_GetITStatus(TIM2, TIM_IT_CC1)) {
        TIM_ClearITPendingBit(TIM2, TIM_IT_CC1);
        uint32_t cap = TIM_GetCapture1(TIM2);

        // 读 PA0 当前电平，判断是哪个边沿触发的捕获
        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
            // PA0 = 低 → 下降沿触发（刚按下）
            cap_start = cap;
            // 切换为上升沿捕获（等释放）
            TIM_ICInitTypeDef ic;
            TIM_ICStructInit(&ic);
            ic.TIM_Channel    = TIM_Channel_1;
            ic.TIM_ICPolarity = TIM_ICPolarity_Rising;
            ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
            ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
            TIM_ICInit(TIM2, &ic);
        } else {
            // PA0 = 高 → 上升沿触发（刚释放）
            if (cap >= cap_start)
                press_time_us = cap - cap_start;
            else   // 处理定时器溢出（实际 ~65ms 内按完不会溢出）
                press_time_us = (0xFFFF - cap_start) + cap;

            // 切换回下降沿捕获（等下次按下）
            TIM_ICInitTypeDef ic;
            TIM_ICStructInit(&ic);
            ic.TIM_Channel    = TIM_Channel_1;
            ic.TIM_ICPolarity = TIM_ICPolarity_Falling;
            ic.TIM_ICSelection = TIM_ICSelection_DirectTI;
            ic.TIM_ICPrescaler = TIM_ICPSC_DIV1;
            TIM_ICInit(TIM2, &ic);
        }
    }
}
```

> **为什么要在 ISR 里读 GPIO 电平？** 因为 STM32 的捕获中断标志不区分上升沿还是下降沿。你需要读引脚当前电平才能知道「发生了什么变化」——低电平 = 刚按下（下降沿），高电平 = 刚释放（上升沿）。

### 主函数：打印按键时长

```c
int main(void) {
    SystemClock_Config();
    SysTick_Init();
    USART1_Init();    // printf → 串口
    TIM2_IC_Init();   // PA0 输入捕获初始化

    while (1) {
        if (press_time_us > 0) {
            printf("按键按下: %d ms\r\n", press_time_us / 1000);
            press_time_us = 0;
        }
    }
}
```

### 效果

按一下板载按键，串口立即打印：
```
按键按下: 156 ms
按键按下: 2038 ms   ← 长按 2 秒
按键按下: 87 ms
```

精度 1μs——这就是输入捕获的威力：**硬件自动计时的，不需要 CPU 参与计时循环，期间 CPU 可以干别的事**。这也是第 6 章中断思想的应用。

### 溢出问题

当前 ARR=0xFFFF，1MHz 计数频率下最多测 65.5ms。按更长时间会触发定时器溢出，测量失败。解决：增大 ARR 或降低时钟频率：

- `tim.TIM_Prescaler = 7199`（72MHz/7200=10kHz）→ 精度 0.1ms，最大可测 6.5 秒
- 或者用 `TIM_TimeBaseInit` 结合溢出中断计算总计数（更复杂）

### 扩展到超声波测距

外部 HC-SR04 模块的原理完全一样：

| | 按键（本实验） | HC-SR04 超声波 |
|--------------|-------------|---------------|
| 待测信号 | PA0 被按键拉低 | Echo 引脚输出高电平 |
| 高电平宽度 | 释放状态 | **距离**，1μs ≈ 0.17mm |
| 数据公式 | `press_time_us` | `距离(cm) = 高电平(μs) / 58` |
| 额外操作 | 无 | 还需要在 Trig 引脚发 10μs 高脉冲触发测距 |

学会了按键的输入捕获——你刚学到了嵌入式测距（超声波）、频率计、PPM 解码的核心原理。

## 7.6 动手：呼吸灯（PWM + 定时器中断）

用 PWM 驱动 LED，配合定时器中断逐渐改变占空比——做出「呼吸」效果。

### 呼吸灯的原理

PWM 占空比从 0→100% 渐变，再 100%→0 渐变，循环。渐变速率用另一个定时器中断控制（比如 50Hz = 20ms 一档，每档增减 5% 占空比）。

### 代码

```c
volatile int duty = 0, dir = 1;  // 当前占空比和方向

void TIM2_IRQHandler(void) {
    if (TIM_GetITStatus(TIM2, TIM_IT_Update) != RESET) {
        TIM_ClearITPendingBit(TIM2, TIM_IT_Update);

        // 每 20ms 更新一次占空比
        duty += dir * 50;          // 每次调 50 点（0~999 范围）
        if (duty >= 950) dir = -1;
        if (duty <= 50)  dir =  1;

        TIM_SetCompare3(TIM3, duty);  // 调 PB0 的 PWM 占空比
    }
}

// 初始化：
// 1. TIM3_CH3 (PB0) 输出 PWM：PSC=71, ARR=999, CCR3=0
// 2. TIM2 做呼吸定时器：PSC=7199, ARR=199 → 72MHz/(7200×200)=50Hz
// 3. 开 TIM2 中断
```

接 LED 到 PB0（STM32 的定时器通道 3 输出），你会看到 LED 缓缓变亮再缓缓变暗——「呼吸」。

---

## 7.7 SPL vs HAL 定时器对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 时基初始化 | `TIM_TimeBaseInit()` + `TIM_Cmd()` | `HAL_TIM_Base_Init()` + `HAL_TIM_Base_Start_IT()` |
| PWM | `TIM_OC1Init()` + `TIM_SetCompare1()` | `HAL_TIM_PWM_Init()` + `__HAL_TIM_SET_COMPARE()` |
| 输入捕获 | `TIM_ICInit()` + `TIM_GetCapture1()` | `HAL_TIM_IC_Init()` + `HAL_TIM_IC_Start_IT()` |
| 中断处理 | 直接写 `TIMx_IRQHandler()` | 回调函数 `HAL_TIM_PeriodElapsedCallback()` |
| 清中断标志 | `TIM_ClearITPendingBit()` | HAL 内部自动清 |

SPL 的定时器操作更接近芯片参考手册的寄存器描述——每个配置项你都能在 RM0008 里找到对应的寄存器位。

## 7.8 本章要点

- 定时器核心：PSC 分频器 → CNT 计数器 → ARR 自动重装载。PSC 决定 tick 频率，ARR 决定周期
- 定时器中断 = 不阻塞的周期性任务，比 `Delay_ms` 准确 100 倍
- PWM = 调节 CCRx 改变占空比，用 `TIM_SetComparex()` 更新
- PWM 频率 = 时钟 / (PSC+1) / (ARR+1)；占空比 = CCR / (ARR+1) × 100%
- 输入捕获 = 边沿触发硬件锁存 CNT，用来测脉冲宽度/频率/超声波距离
- STM32F103 定时器挂在 APB1，但预分频≠1 时自动 ×2 → 照样跑 72MHz
- TIM1 是高级定时器（死区/刹车/互补输出），TIM2-5 通用，TIM6-7 基本（只有时基）

---

> **上一章**：[第 6 章 · 中断系统（SPL版）](./06-chapter.md)
>
> **下一章**：[第 8 章 · 串口通信 UART](./08-chapter.md)
>
> 定时器让你学会了「时间控制」。下一步学「设备间通信」——串口是嵌入式调试的第一工具。

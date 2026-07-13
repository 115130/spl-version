# 第 5 章 · 时钟系统（SPL版）

> **本章产出**：能配置并验证 72MHz 系统时钟，解释 UART 乱码、延时不准和 PWM 频率错误为什么常常是同一个根因。
>
> **前置知识**：完成第 0 章工程，理解外设时钟必须显式开启。
>
> **验证工具**：串口终端；有逻辑分析仪或示波器更好，但没有也可用 GPIO 翻转与串口波特率交叉验证。

> **本章产出**：看懂时钟树、手写 72MHz 时钟配置、用 SysTick 实现精确延时
>
> **用到项目的哪里**：时钟是系统心跳——USB 需要 48MHz、UART 波特率依赖时钟精度、低功耗需要切时钟源、所有外设使用前必须开时钟

---

## 5.1 为什么需要时钟树

你 PC 的 CPU 有一个主频。但 PC 里还有很多其他频率：内存总线、PCIe、USB、SATA——它们都跑不同的频率。

STM32 也一样。不同外设需要不同频率：

| 外设 | 需要的时钟 | 为什么 |
|------|-----------|--------|
| CPU 内核 | 尽量快 | 程序跑得快 |
| USB | 精确 48MHz | USB 协议要求 |
| USART | 精确时钟 | 波特率（115200）需要时钟分频 |
| 定时器 | 灵活 | 有时要快（PWM），有时要慢（秒级） |
| IWDG | 独立于系统时钟 | 系统时钟挂了，看门狗还要能复位 |

所以 STM32 设计了一套**时钟树**——多时钟源 + PLL 倍频 + 多级分频器 = 给每个部件提供恰当的频率。

## 5.2 STM32F103 时钟树全解析

### 时钟源

| 时钟 | 全称 | 频率 | 特点 |
|------|------|------|------|
| **HSI** | 高速内部 RC 振荡器 | 8MHz | 芯片内置，精度差（±1%），上电默认 |
| **HSE** | 高速外部晶振 | 4-16MHz（常用 8MHz） | 板上晶振，精度高（±几十 ppm） |
| **LSI** | 低速内部 RC 振荡器 | ~40kHz | 给独立看门狗和 RTC 用 |
| **LSE** | 低速外部晶振 | 32.768kHz | 给 RTC 提供精确 1 秒时基（2¹⁵ = 32768） |

> **ppm**（百万分之一）：±30ppm 的 8MHz 晶振实际偏差不超过 240Hz，做 UART 通信够用。HSI 的 ±1% = 10,000 ppm，做高波特率通信可能出错。

### 时钟流向

```
HSI (8MHz) ──┐
HSE (8MHz) ──→ /1 ──→ PLL ──×2~16──→ PLLCLK (最高 72MHz)
                                    │
                                    ├──→ SYSCLK ──→ HCLK ──→ CPU / SRAM / DMA
                                    │       │
                                    │       ├──→ PCLK1 (APB1, 最大36MHz)
                                    │       │     → TIM2-7, USART2-5, I2C, SPI2/3
                                    │       │
                                    │       └──→ PCLK2 (APB2, 最大72MHz)
                                    │             → GPIO, TIM1/8, USART1, SPI1, ADC
                                    │
                                    └──→ USB 预分频器 ──→ 48MHz to USB

LSE (32.768kHz) ──→ RTC
LSI (~40kHz)     ──→ 独立看门狗 IWDG
```

**关键约束**：
- PCLK1 (APB1) 最大 36MHz
- USB 必须用 PLL 输出 48MHz
- 所有外设使用前必须先开时钟——GPIO/APB2 上的 `RCC_APB2PeriphClockCmd`，APB1 上的 `RCC_APB1PeriphClockCmd`

### ⚠️ Flash 等待周期（Core Coupling）

系统时钟 > 24MHz 时，必须配置 Flash 等待周期：

| SYSCLK 范围 | Flash Latency |
|-------------|---------------|
| 0 - 24MHz   | 0 WS |
| 24 - 48MHz  | 1 WS |
| 48 - 72MHz  | 2 WS |

**忘了配 → 72MHz 下读 Flash 出错 → 程序随机崩溃！**

---

## 5.3 SPL 手写 72MHz 时钟配置

HAL 版用 CubeMX 自动生成 `SystemClock_Config()`。SPL 版自己写，每一个参数都显式指定：

```c
#include "stm32f10x_rcc.h"
#include "stm32f10x_flash.h"

void SystemClock_Config(void) {
    // ① 开启 HSE（外部 8MHz），等稳定
    RCC_HSEConfig(RCC_HSE_ON);
    while (RCC_GetFlagStatus(RCC_FLAG_HSERDY) == RESET);

    // ② Flash 等待周期——72MHz 必须 2 WS
    FLASH_SetLatency(FLASH_Latency_2);
    FLASH_PrefetchBufferCmd(ENABLE);

    // ③ PLL：HSE 8MHz × 9 = 72MHz
    RCC_PLLConfig(RCC_PLLSource_HSE_Div1, RCC_PLLMul_9);

    // ④ 开启 PLL，等锁定
    RCC_PLLCmd(ENABLE);
    while (RCC_GetFlagStatus(RCC_FLAG_PLLRDY) == RESET);

    // ⑤ AHB/APB1/APB2 分频
    RCC_HCLKConfig(RCC_SYSCLK_Div1);   // HCLK  = 72MHz
    RCC_PCLK1Config(RCC_HCLK_Div2);    // PCLK1 = 36MHz
    RCC_PCLK2Config(RCC_HCLK_Div1);    // PCLK2 = 72MHz

    // ⑥ 切换系统时钟到 PLL
    RCC_SYSCLKConfig(RCC_SYSCLKSource_PLLCLK);
    while (RCC_GetSYSCLKSource() != 0x08);  // 等 SWS = PLL
}
```

在 `main()` 开头调用：

```c
int main(void) {
    SystemClock_Config();  // ← 系统跑在 72MHz
    // ...
}
```

> ⚠️ SPL 自带的 `SystemInit()`（在 `system_stm32f10x.c`）默认保持 HSI 8MHz。你要在 `main()` 手动调上面的 `SystemClock_Config()` 切到 72MHz。

---

## 5.4 SysTick 定时器原理

SysTick 是 **Cortex-M3 内核内置**的 24 位递减定时器，不属于 ST 的外设。所有 Cortex-M 芯片都有，用起来一样：

```
LOAD 寄存器（24 位计数初值）
   ↓
VAL  寄存器（当前值）—— 每个时钟周期减 1
   ↓ 减到 0
   触发 SysTick 中断（如果使能了）
   ↓
VAL 自动重装载为 LOAD 的值，继续递减...
```

时钟源可选：
- **HCLK**（72MHz）：每周期 ~13.9ns
- **HCLK/8**（9MHz）：每周期 ~111ns

## 5.5 SPL 实现 SysTick 精确延时

```c
#include "stm32f10x.h"

static volatile uint32_t sys_tick_ms = 0;

// SysTick 中断服务函数——每个 tick 加 1
void SysTick_Handler(void) {
    sys_tick_ms++;
}

// 初始化——每 1ms 中断一次
void SysTick_Init(void) {
    // SysTick 时钟 = HCLK/8 = 9MHz, 1ms = 9000 个周期
    SysTick_Config(SystemCoreClock / 8 / 1000);
}

// 获取运行毫秒数
uint32_t GetTick(void) {
    return sys_tick_ms;
}

// 毫秒延时（精确，不依赖空循环的 CPU 频率）
void Delay_ms(uint32_t ms) {
    uint32_t start = sys_tick_ms;
    while ((sys_tick_ms - start) < ms);
}
```

在 `main()` 中初始化：

```c
int main(void) {
    SystemClock_Config();
    SysTick_Init();

    while (1) {
        GPIO_ResetBits(GPIOB, GPIO_Pin_5);
        Delay_ms(500);   // 精确 500ms
        GPIO_SetBits(GPIOB, GPIO_Pin_5);
        Delay_ms(500);
    }
}
```

**`Delay_ms` 仍然是阻塞的**——CPU 在 `while` 里空转。后面学中断（第 6 章）和 RTOS（第 14 章）来解决阻塞问题。

### ⚠️ SysTick_Handler 名字不能改

它是启动文件 `startup_stm32f10x_hd.s` 里写死的弱符号——改了就 Hard Fault。

---

## 5.6 SPL vs HAL 时钟对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 时钟配置 | 手写 `SystemClock_Config()` | CubeMX 生成 |
| SysTick 初始化 | `SysTick_Config(9000)` | `HAL_Init()` 内部自动 |
| 延时 | `Delay_ms()`（自己写） | `HAL_Delay()` |
| 获取 tick | `GetTick()`（自己写） | `HAL_GetTick()` |

---

## 5.7 动手：用 Delay 做流水灯

回到第 3 章的流水灯——当时我们用了一个基础的 `Delay_ms`，但那个 `Delay_ms` 只是简单让 CPU 空转。现在你有了 `SysTick_Config` + `uwTick` 的精确定时，可以做出节奏稳定的流水灯。

```c
int main(void) {
    // 时钟 + SysTick + GPIO 初始化
    SystemClock_Config();           // 72MHz
    SysTick_Init();                 // SysTick → 1ms tick
    LED_All_Init();                 // PB0-PB3 推挽输出

    const uint8_t pins[] = {GPIO_Pin_0, GPIO_Pin_1, GPIO_Pin_2, GPIO_Pin_3};

    while (1) {
        for (int i = 0; i < 4; i++) {
            GPIO_ResetBits(GPIOB, pins[i]);     // 亮
            Delay_ms(150);                        // 精确 150ms
            GPIO_SetBits(GPIOB, pins[i]);         // 灭
        }
        // 反向流一次
        for (int i = 3; i >= 0; i--) {
            GPIO_ResetBits(GPIOB, pins[i]);
            Delay_ms(150);
            GPIO_SetBits(GPIOB, pins[i]);
        }
    }
}
```

**相比第 3 章的区别**：

| | 第 3 章的流水灯 | 这里的流水灯 |
|--|---------------|-------------|
| 延时精度 | 取决于 CPU 频率 | **精确 1ms**（基于 SysTick）|
| CPU 占用 | 空转（实际 ≈ 死循环） | 同样空转——但计时**精准** |
| 可预测性 | 换芯片频率不同，节奏飘移 | 72MHz 下准时 150ms |
| 能读到的时间 | 无 | `uwTick` 全局变量，随时可查 |

> 尽管 `Delay_ms` 本质上还是「CPU 原地等」的阻塞方式——但现在的 `Delay_ms` 是基于硬件定时器的，**时间准确且不受编译优化影响**。第 6 章的中断会帮你从「等待」中解放出来。

---

## 5.8 验证时钟是否真的按预期运行

时钟配置不能只看代码。至少做两项交叉验证：

1. 串口以设定波特率输出稳定文本；时钟错时，最常见现象是乱码。
2. 用定时器或 GPIO 翻转输出一个已知频率；可用逻辑分析仪或示波器测量。

还应在启动后打印 SystemCoreClock，并把它与 PLL 配置、USART 波特率和定时器周期对应起来。这样以后遇到“延时不准、UART 乱码、PWM 频率不对”时，能先回到同一个根因：时钟。

## 5.9 常见时钟故障的定位顺序

时钟问题的表现常常出现在别的外设上。请按同一顺序排查：

| 现象 | 最可能的根因 | 首个验证动作 |
|---|---|---|
| UART 全部乱码 | SystemCoreClock/外设时钟与波特率计算不一致 | 先输出已知字符并核对实际波特率 |
| Delay 明显不准 | SysTick 装载值仍按旧时钟算 | 读取时钟配置，计算 1ms 应有的 tick |
| PWM 频率偏一倍 | APB 分频后的定时器时钟规则没考虑 | 重新写出 TIM 时钟、PSC、ARR 三项 |
| 程序卡在启动 | HSE/PLL 未就绪或等待条件无超时 | 回退到已知可用的 HSI 配置定位 |

练习：用一个定时器每秒翻转一次 GPIO；先在 72MHz 下验证，再有意识地改为较低频率，记录 UART、Delay 和 PWM 分别会怎样变化。

## 5.10 本章要点

- 时钟树决定整个系统的速度。HSI（8MHz）+ PLL ×9 = 72MHz（SYSCLK）
- AHB 分频后给 CPU/SRAM/DMA, APB1(/2)=36MHz, APB2(/1)=72MHz
- SysTick = Cortex-M3 自带的 24 位递减定时器，1ms 中断更新 `uwTick`
- SPL 手写时钟配置比 CubeMX 慢 5 分钟，但让你看懂了芯片的每一处配置
- 延时有两种：`Delay_ms`（阻塞，简单精准）和中断延时（非阻塞，后面讲）
- **精确定时**是所有外设时序的基础——UART 波特率、PWM 频率、ADC 采样时间都依赖它

---
> **上一章**：[第 4 章 · C 语言与 Makefile](./04-chapter.md)
> **下一章**：[第 6 章 · 中断系统（SPL版）](./06-chapter.md)
>
> Delay_ms 太蠢了——CPU 卡在那什么都干不了。中断就是来解决这个的：事件发生 → 打断 CPU → 处理完 → 回去。这是嵌入式最核心的机制。

---



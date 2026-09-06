# 第 5 章 · 时钟、时基与可测时间（SPL 版）

这一章把 STM32F103 的时钟配置真正落到代码和测量上。完成后，你应该能配置一套确定的 HCLK、PCLK 和外设时钟，建立 1 ms SysTick 时基，并在外部晶振失败时让程序退出等待而不是永久卡住。

前面的章节已经用过 `SystemCoreClock`、SysTick、UART 和定时器。这里把这些东西连起来：UART 波特率错、PWM 频率错、ADC 时钟超规格，往往都可以从时钟树找到原因。

## 5.1 先确认时钟从哪里来

STM32F103 有 HSI、HSE、PLL 等时钟源。HSI 是片内 RC 振荡器；HSE 由板卡上的外部晶体、振荡器或外部时钟提供。HSE 的实际频率必须看开发板原理图，不能因为常见板使用 8 MHz 就直接写死。

本章的 72 MHz 示例只适用于已经确认 **HSE = 8 MHz** 的板卡：

```text
HSE 8 MHz
   │
   └── PLL ×9 → SYSCLK 72 MHz
                    │
                    ├── AHB /1  → HCLK  72 MHz
                    ├── APB1 /2 → PCLK1 36 MHz
                    └── APB2 /1 → PCLK2 72 MHz
```

STM32F103 的 APB1 最高 36 MHz，APB2 最高 72 MHz。APB 上的定时器还有一条规则：当对应 APB 预分频不是 `/1` 时，定时器输入时钟是 `2 × PCLK`。因此 PCLK1 为 36 MHz 时，TIM2 等 APB1 定时器仍可以得到 72 MHz。

ADC 时钟由 PCLK2 再分频得到，STM32F103 的 ADC 时钟不能超过 14 MHz。PCLK2 为 72 MHz 时，可以选择 `/6` 得到 12 MHz。

## 5.2 提高主频前先处理 Flash

CPU 提高到 72 MHz 后，Flash 不能按零等待周期直接提供每次读取。时钟切换前先配置 Flash latency，并按器件要求打开预取缓冲：

```c
FLASH_SetLatency(FLASH_Latency_2);
FLASH_PrefetchBufferCmd(ENABLE);
```

这里的顺序很重要。先把 Flash 配置到能够承受目标频率，再把 SYSCLK 提高。降回 HSI 后，才可以把等待周期降回较低值。

不同供电电压和频率对应的 Flash latency 应以 STM32F103 数据手册为准。本书的 72 MHz、正常 3.3 V 供电示例使用 `FLASH_Latency_2`。

## 5.3 配置 72 MHz，并给每个等待加退出条件

外部晶振和 PLL 都需要等待就绪标志。硬件异常时，如果代码只写：

```c
while (RCC_GetFlagStatus(RCC_FLAG_HSERDY) == RESET) {
}
```

程序可能永远停在这里。

下面先做一个最简单的有限轮询：

```c
#include <stdbool.h>
#include "stm32f10x.h"
#include "stm32f10x_flash.h"
#include "stm32f10x_rcc.h"

#define CLOCK_WAIT_LIMIT 0x5000U

static bool WaitRccFlag(uint8_t flag)
{
    uint32_t left = CLOCK_WAIT_LIMIT;

    while (RCC_GetFlagStatus(flag) == RESET) {
        if (left-- == 0U)
            return false;
    }

    return true;
}
```

`CLOCK_WAIT_LIMIT` 表示最多轮询多少次，不代表固定的微秒或毫秒。编译优化、当前 CPU 频率和函数调用都会改变一次循环的实际耗时。这里用它解决“不能无限等”的问题；需要确定超时时间时，应使用已经建立好的独立时基。

完整配置：

```c
bool SystemClock_Try72MHz(void)
{
    RCC_DeInit();

    RCC_HSEConfig(RCC_HSE_ON);
    if (!WaitRccFlag(RCC_FLAG_HSERDY))
        goto fallback_hsi;

    FLASH_SetLatency(FLASH_Latency_2);
    FLASH_PrefetchBufferCmd(ENABLE);

    RCC_HCLKConfig(RCC_SYSCLK_Div1);
    RCC_PCLK1Config(RCC_HCLK_Div2);
    RCC_PCLK2Config(RCC_HCLK_Div1);
    RCC_ADCCLKConfig(RCC_PCLK2_Div6);

    RCC_PLLConfig(RCC_PLLSource_HSE_Div1, RCC_PLLMul_9);
    RCC_PLLCmd(ENABLE);

    if (!WaitRccFlag(RCC_FLAG_PLLRDY))
        goto fallback_hsi;

    RCC_SYSCLKConfig(RCC_SYSCLKSource_PLLCLK);

    {
        uint32_t left = CLOCK_WAIT_LIMIT;
        while (RCC_GetSYSCLKSource() != 0x08U) {
            if (left-- == 0U)
                goto fallback_hsi;
        }
    }

    SystemCoreClockUpdate();
    return true;

fallback_hsi:
    RCC_HSICmd(ENABLE);

    if (WaitRccFlag(RCC_FLAG_HSIRDY)) {
        RCC_SYSCLKConfig(RCC_SYSCLKSource_HSI);

        uint32_t left = CLOCK_WAIT_LIMIT;
        while (RCC_GetSYSCLKSource() != 0x00U) {
            if (left-- == 0U)
                break;
        }
    }

    if (RCC_GetSYSCLKSource() == 0x00U) {
        RCC_PLLCmd(DISABLE);
        RCC_HSEConfig(RCC_HSE_OFF);
        FLASH_SetLatency(FLASH_Latency_0);
    }

    SystemCoreClockUpdate();
    return false;
}
```

`RCC_GetSYSCLKSource()` 读取的是 SWS 状态位。`0x00` 表示当前系统时钟来自 HSI，`0x08` 表示来自 PLL。调用 `RCC_SYSCLKConfig()` 只是在请求切换，继续检查 SWS 才能确认硬件已经完成切换。

回退路径里也要先确认 HSI 已经接管 SYSCLK，再关闭 PLL 和 HSE。不能在 CPU 仍由 PLL 供时的时候直接把 PLL 关掉。

这个函数返回 `false` 时，程序仍可能继续在 HSI 上运行，但后面的 UART、定时器和 SysTick 都必须按照实际时钟重新初始化。不能继续拿 72 MHz 的参数使用。

## 5.4 `SystemCoreClock` 只是软件记录

CMSIS 提供：

```c
SystemCoreClockUpdate();
```

它根据 RCC 寄存器重新计算 `SystemCoreClock`。这个变量不会主动配置硬件，也不会自动发现“外部晶振实际不是你以为的频率”。

配置完成后还可以读取 SPL 计算出的总线频率：

```c
RCC_ClocksTypeDef clocks;

SystemCoreClockUpdate();
RCC_GetClocksFreq(&clocks);
```

可以检查：

```c
clocks.SYSCLK_Frequency
clocks.HCLK_Frequency
clocks.PCLK1_Frequency
clocks.PCLK2_Frequency
clocks.ADCCLK_Frequency
```

这些值来自当前 RCC 配置和库中定义的时钟源频率。真正排查频率问题时，最好再用逻辑分析仪、示波器或已验证的串口进行外部测量。

## 5.5 SysTick 做 1 ms 时基

SysTick 是 Cortex-M3 内核里的 24 位递减计数器。CMSIS 的 `SysTick_Config()` 默认把 SysTick 时钟源设为处理器时钟，也就是当前 HCLK。

72 MHz 下，1 ms 需要：

```text
72 000 000 / 1000 = 72 000 tick
```

代码可以直接使用 `SystemCoreClock`：

```c
static volatile uint32_t g_ms;

int Timebase_Init_1ms(void)
{
    SystemCoreClockUpdate();
    return SysTick_Config(SystemCoreClock / 1000U);
}

void SysTick_Handler(void)
{
    ++g_ms;
}

uint32_t Timebase_NowMs(void)
{
    return g_ms;
}
```

`SysTick_Config()` 返回非零时，说明要求的 reload 值超出了 SysTick 的 24 位范围。72 MHz 下配置 1 ms 不会达到这个上限，但初始化代码仍应检查返回值。

有些代码会手动把 SysTick 时钟改成 HCLK/8。那属于另一种配置，reload 也必须跟着重新计算。直接使用 CMSIS `SysTick_Config()` 时，不要再额外除以 8。

## 5.6 用无符号减法处理计数器回绕

`g_ms` 是 `uint32_t`，最终会从 `0xFFFFFFFF` 回到 0。判断已经过去多少时间时，使用无符号减法：

```c
uint32_t start = Timebase_NowMs();

while ((uint32_t)(Timebase_NowMs() - start) < 500U) {
    __WFI();
}
```

只要等待区间小于 `uint32_t` 计数周期，这种写法跨过回绕点仍然成立。

`__WFI()` 会让 CPU 等待中断。SysTick、UART 或其他已经使能的中断都可能唤醒 CPU，因此醒来后仍然要重新检查时间条件。

可以封装成：

```c
void Delay_ms(uint32_t delay)
{
    uint32_t start = Timebase_NowMs();

    while ((uint32_t)(Timebase_NowMs() - start) < delay) {
        __WFI();
    }
}
```

这个延时的时间来源已经可靠，但调用期间当前执行流仍然被阻塞。主循环需要同时处理按键、UART、状态机时，应改成非阻塞判断。

例如 LED 每 500 ms 翻转：

```c
static uint32_t last_toggle;
static uint8_t led_on;

void Blink_Poll(void)
{
    uint32_t now = Timebase_NowMs();

    if ((uint32_t)(now - last_toggle) >= 500U) {
        last_toggle = now;
        led_on ^= 1U;
        BoardLed_Write(led_on);
    }
}
```

主循环可以不断调用 `Blink_Poll()`，中间继续处理其他任务。

## 5.7 外设到底用哪个时钟

配置外设时，不要直接看到 `SystemCoreClock = 72000000` 就把所有公式都代入 72 MHz。

| 外设 | 本章 72 MHz 配置下的输入时钟 | 例子 |
|---|---:|---|
| USART1 | PCLK2 = 72 MHz | BRR 根据 72 MHz 和目标波特率计算 |
| USART2/3 | PCLK1 = 36 MHz | BRR 根据 36 MHz 计算 |
| TIM2–7 | TIMCLK = 72 MHz | APB1=/2，因此定时器时钟为 2 × PCLK1 |
| ADC1/2 | ADCCLK = 12 MHz | PCLK2/6 |
| SysTick | HCLK = 72 MHz | 1 ms 使用 72000 tick |

例如 TIM2 输入 72 MHz，要得到 1 kHz 更新事件，可以先用预分频器得到 1 MHz 计数时钟：

```text
PSC = 71
72 MHz / (71 + 1) = 1 MHz
```

再设置：

```text
ARR = 999
1 MHz / (999 + 1) = 1 kHz
```

STM32 定时器的 PSC 和 ARR 都按“寄存器值 + 1”参与这个基本计算，后面定时器章节会继续展开。

时钟一旦改变，已经初始化的 USART、定时器、ADC 和 SysTick 配置都可能失效。正确顺序是先完成系统时钟切换，再初始化依赖这些时钟的外设。

## 5.8 怎么验证实际频率

先把软件记录打印出来：

```c
RCC_ClocksTypeDef clocks;
RCC_GetClocksFreq(&clocks);
```

然后至少再做一次外部验证。比较直接的方法是让一个定时器输出确定频率，例如 1 kHz PWM，再用逻辑分析仪或示波器测量。如果实际只有 500 Hz，先检查 APB 定时器的 ×2 规则和 PSC/ARR 的 `+1`。

UART 也可以作为辅助证据。USART1 按 PCLK2=72 MHz 配成 115200 后，如果在已确认的 USB-TTL 上持续稳定收发，说明时钟和波特率配置至少相互一致。它不如直接测量定时器波形那样独立，因为 UART 两边也可能同时存在配置问题。

GDB 可以读取 RCC 和 FLASH 寄存器，确认 HSE/PLL ready、SWS、APB 分频和 Flash latency。它能证明寄存器配置是什么，但不能代替对板上实际晶振频率的测量。

## 5.9 常见问题

HSE 一直不 ready：先确认板卡是否真的有 HSE、频率是多少，以及使用的是晶体还是外部有源时钟。再检查原理图、焊接和 RCC 的 HSE 模式配置。

PLL ready 但切换后频率不对：重新检查 PLL 输入源、倍频系数、HSE 实际频率和 SWS。不要只看 `SystemCoreClock` 的数值。

UART 持续乱码：确认具体 USART 位于 APB1 还是 APB2，再检查实际 PCLK 和帧格式。USART1 和 USART2 在这套配置下不能使用同一个外设输入时钟数值。

PWM 频率正好差两倍：优先检查 APB 预分频和定时器时钟 ×2 规则，然后检查 PSC、ARR 是否漏了 `+1`。

SysTick 正好快约 8 倍：检查是不是在 `SysTick_Config(SystemCoreClock / 1000U)` 的基础上又按 HCLK/8 思路改了 reload，或者额外调用了 `SysTick_CLKSourceConfig()`。

ADC 时钟超规格：先读 PCLK2 和 ADC 分频，确认 ADCCLK 不超过器件数据手册给出的上限，再继续查模拟输入和采样时间。

## 5.10 验收和练习

完成本章后确认这些结果：

- HSE、PLL 和 SYSCLK 切换都有有限等待。
- 失败路径能返回状态，不会永久停在等待循环。
- 成功切换后 `SystemCoreClock`、PCLK1、PCLK2 和 ADCCLK 与预期一致。
- SysTick 可以稳定提供 1 ms 计数。
- 至少用逻辑分析仪、示波器或另一种独立方法验证过一个实际频率。

做三个实验：

1. 用 TIM2 输出 1 kHz 信号，写出 TIMCLK、PSC 和 ARR 的计算过程，再用仪器测量。
2. 在副本工程中让 HSE 初始化故意失败，确认程序返回 HSI 路径，并记录此时 `SystemCoreClock`。
3. 在副本工程里故意把 SysTick reload 再除以 8，先计算会发生什么，再观察毫秒计数和真实时间的差异。

到这里，后面的 UART、定时器、PWM、ADC 和单线时序都有了统一的时间基准。下一章进入中断，处理硬件事件如何安全交给主循环。

> **上一章**：[第 4 章 · C 语言的嵌入式边界](./04-chapter.md)
>
> **下一章**：[第 6 章 · 中断、事件与并发边界](./06-chapter.md)

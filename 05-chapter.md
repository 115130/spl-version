# 第 5 章 · 时钟、时基与可测时间（SPL 版）

> **本章产出**：能以有超时、有回退的方式配置 72MHz；能建立正确的 1ms SysTick 时基；能把 UART 乱码、PWM 偏频和单线时序失败统一追溯到时钟证据。
>
> **前置知识**：完成第 0 章模板，理解 HCLK/PCLK 和外设时钟门控。
>
> **通过标准**：`SystemCoreClock`、PCLK1、PCLK2 与代码配置一致；用仪器/串口交叉验证一个频率；HSE 不起振时程序在有限时间内回退而不是无限卡死。

---

## 5.0 前置知识速览：本章涉及的新概念

如果你从第 2 章直接跳到本章，以下几个概念是理解本章代码的前提：

| 概念 | 一句话 | 为什么本章关心 |
|------|--------|---------------|
| **PLL（锁相环）** | "频率放大器"——把 HSE 的 8MHz ×9 得到 72MHz | 接通后需要等待锁定（几 μs～几百 μs），锁定失败通常是 HSE 没起振 |
| **晶振（HSE）** | 板上的 8MHz 石英晶体，一个模拟器件 | 可能因焊接、匹配电容或损坏不起振；代码无法区分"正在起振"和"永不振"，必须设超时 |
| **Flash 等待周期** | Flash 读取速度跟不上 CPU 频率时，需要插入等待周期 | 72MHz 需 2 个等待周期（`FLASH_Latency_2`），不设或少设会导致取指错误、程序跑飞 |
| **ADC 时钟上限** | ADC 是逐次逼近型（SAR），每步转换需要固定时间 | F103 的 ADC 时钟 ≤ 14MHz，72MHz 的 PCLK2 要经 `/6`（12MHz）才能给 ADC |
| **SWS 状态位** | `RCC_CFGR` 中的"当前系统时钟来源"只读位 | `0x00` = HSI、`0x04` = HSE、`0x08` = PLL；代码用 `RCC_GetSYSCLKSource() != 0x08U` 验证时钟切换成功 |

如果以上概念你已经清楚，可以直接跳到 5.1 节；如果某个概念还模糊，记住一个主线就够了：**本章的核心思路是"不稳定时回退到 HSI"**——所有配置和检查都围绕着这个目标展开。

---

## 5.1 时钟不是一个数字，而是一份分发合同

STM32F103 的常见 72MHz 配置是 `HSE 8MHz × PLL 9`，但“系统是 72MHz”还不够。每个消费者拿到的时钟不同：

```text
HSE 8MHz → PLL ×9 → SYSCLK 72MHz
                       │
                       ├─ AHB /1 → HCLK 72MHz → CPU、SRAM、DMA、SysTick(HCLK)
                       ├─ APB1 /2 → PCLK1 36MHz → USART2–5、I2C、SPI2/3、TIM2–7
                       └─ APB2 /1 → PCLK2 72MHz → GPIO、USART1、SPI1、ADC、TIM1/8
```

| 限制/规则 | 为什么后续章节关心 |
|---|---|
| PCLK1 不得高于 36MHz | 超过额定值不能靠“能跑”证明安全 |
| APB 预分频不是 /1 时，该 APB 上的定时器时钟为 `2 × PCLK` | TIM2–7 在 PCLK1=36MHz 时仍可得到 72MHz |
| ADC 时钟不超过 14MHz | 72MHz 的 PCLK2 通常选择 `/6`，即 12MHz |
| Flash 高速运行需要等待周期 | 提高 SYSCLK 前先设 Flash latency，防止取指不可靠 |
| USB 需要精确 48MHz | 未配置 USB 预分频前，不要声明 USB 可用 |

`SystemCoreClock` 只表示内核时钟的**软件记录**，不会魔法般校验硬件。自定义 RCC 后调用 `SystemCoreClockUpdate()`；再用 `RCC_GetClocksFreq()` 读取 HCLK/PCLK1/PCLK2 交叉检查。

## 5.2 72MHz 配置：每个等待都有退出路径

下面的函数适用于已确认板上 HSE 为 8MHz 的 ZET6 开发板。若你的板的晶振不同，PLL 倍频、USB、串口与定时器计算都要重算；先看原理图，不要照抄 `×9`。

```c
#include <stdbool.h>
#include "stm32f10x.h"
#include "stm32f10x_flash.h"
#include "stm32f10x_rcc.h"

#define CLOCK_WAIT_LIMIT  0x5000U

static bool WaitRccFlag(FlagStatus (*get_flag)(uint8_t), uint8_t flag)
{
    uint32_t left = CLOCK_WAIT_LIMIT;
    while (get_flag(flag) == RESET) {
        if (left-- == 0U)
            return false;
    }
    return true;
}

/* 返回 true 表示已切到 PLL 72MHz；false 表示保留/回退在 HSI。 */
bool SystemClock_Try72MHz(void)
{
    RCC_DeInit();                       /* 已知起点：HSI 为系统时钟，PLL/HSE 关闭。 */
    RCC_HSEConfig(RCC_HSE_ON);
    if (!WaitRccFlag(RCC_GetFlagStatus, RCC_FLAG_HSERDY))
        goto fallback_hsi;

    /* 先设置不会超规格的总线和 Flash，再提高 SYSCLK。 */
    FLASH_SetLatency(FLASH_Latency_2);
    FLASH_PrefetchBufferCmd(ENABLE);
    RCC_HCLKConfig(RCC_SYSCLK_Div1);
    RCC_PCLK1Config(RCC_HCLK_Div2);
    RCC_PCLK2Config(RCC_HCLK_Div1);
    RCC_ADCCLKConfig(RCC_PCLK2_Div6);   /* 72MHz / 6 = 12MHz <= 14MHz */

    RCC_PLLConfig(RCC_PLLSource_HSE_Div1, RCC_PLLMul_9);
    RCC_PLLCmd(ENABLE);
    if (!WaitRccFlag(RCC_GetFlagStatus, RCC_FLAG_PLLRDY))
        goto fallback_hsi;

    RCC_SYSCLKConfig(RCC_SYSCLKSource_PLLCLK);
    for (uint32_t left = CLOCK_WAIT_LIMIT;
         RCC_GetSYSCLKSource() != 0x08U; /* SWS: PLL */) {
        if (left-- == 0U)
            goto fallback_hsi;
    }

    SystemCoreClockUpdate();
    return true;

fallback_hsi:
    /* 先确认已真正切回 HSI，才允许关闭当前可能正在供时的 PLL/HSE。 */
    RCC_HSICmd(ENABLE);
    (void)WaitRccFlag(RCC_GetFlagStatus, RCC_FLAG_HSIRDY);
    RCC_SYSCLKConfig(RCC_SYSCLKSource_HSI);
    for (uint32_t left = CLOCK_WAIT_LIMIT;
         RCC_GetSYSCLKSource() != 0x00U; /* SWS: HSI */) {
        if (left-- == 0U)
            break;
    }
    if (RCC_GetSYSCLKSource() == 0x00U) {
        RCC_PLLCmd(DISABLE);
        RCC_HSEConfig(RCC_HSE_OFF);
    }
    FLASH_SetLatency(FLASH_Latency_0);
    SystemCoreClockUpdate();
    return false;
}
```

这里的轮询上限是“防止永久等待”的保护，不是精准的毫秒计时。实际产品还应记录失败原因、在安全状态下提示，并根据板级设计决定是否允许继续在 HSI 上运行。不要在时钟切换失败后仍把串口波特率、PWM 和延时当作 72MHz。

在 `main()` 中保存结果：

```c
bool clock_72m = SystemClock_Try72MHz();
RCC_ClocksTypeDef clocks;
RCC_GetClocksFreq(&clocks);
/* clocks.HCLK_Frequency / PCLK1_Frequency / PCLK2_Frequency 是后续计算依据。 */
```

> SPL 的 `SystemInit()` 由 `system_stm32f10x.c` 的编译选项决定；不要假定任何 SPL 工程“默认必然 8MHz”或“默认必然 72MHz”。本章函数显式配置、显式检查、显式更新软件记录。

## 5.3 SysTick：CMSIS `SysTick_Config()` 用的是 HCLK

SysTick 是 Cortex-M3 的 24 位递减计数器。CMSIS 的 `SysTick_Config(ticks)` 会选择核心时钟（HCLK），所以 72MHz 下 1ms 的正确装载值是 **72000**，不是 `72000 / 8`：

```c
#include "stm32f10x.h"

static volatile uint32_t g_ms;

int Timebase_Init_1ms(void)
{
    SystemCoreClockUpdate();
    return SysTick_Config(SystemCoreClock / 1000U);
}

uint32_t Timebase_NowMs(void)
{
    return g_ms;
}

void SysTick_Handler(void)
{
    g_ms++;
}

void Delay_ms(uint32_t delay)
{
    const uint32_t start = Timebase_NowMs();
    while ((uint32_t)(Timebase_NowMs() - start) < delay) {
        __WFI();
    }
}
```

`SysTick_Config()` 返回非零表示装载值超出 24 位；本书的 72MHz/1ms 不会超出，但仍应检查返回值。`__WFI()` 不是“保证睡满一毫秒”：其他中断也可能唤醒它，循环会重新检查时间，所以功能仍正确。

`SysTick_Handler` 是向量表中的弱符号名。若你写错名字，默认处理函数通常会停在死循环；这不是 GPIO 或时钟的症状。用 GDB 在 `SysTick_Handler` 断点，或用一个独立 GPIO/串口计数验证它确实每毫秒进入一次。

### 阻塞延时和非阻塞调度

`Delay_ms` 的时间来源正确，但它仍让当前主循环等待。对于 LED 闪烁，优先写成状态机：

```c
static uint32_t next_toggle;
static uint8_t led_on;

void Blink_Poll(void)
{
    uint32_t now = Timebase_NowMs();
    if ((int32_t)(now - next_toggle) >= 0) {
        led_on ^= 1U;
        BoardLed_Write(led_on);
        next_toggle = now + 500U;
    }
}
```

这样主循环仍可读取按键、处理 UART、检查超时。`Delay_ms` 只用于短暂、明确的初始化等待；微秒级单线时序不要由 SysTick 1ms 时基承担，见第 7 章的 1MHz 定时器方案。

## 5.4 从时钟到一个外设公式

每次配置外设都先写具体时钟来源，再计算寄存器：

| 外设 | 输入时钟 | 示例 |
|---|---|---|
| USART1 | PCLK2 = 72MHz | 115200 波特率由 72MHz 分频得到 |
| USART2 | PCLK1 = 36MHz | 不能误用 `SystemCoreClock` 直接计算 |
| TIM2 | APB1 定时器时钟 = 72MHz（PCLK1=/2） | `PSC=71, ARR=999` → 1kHz |
| ADC1 | ADCCLK = PCLK2/6 = 12MHz | 低于 14MHz 上限 |
| SysTick | HCLK = 72MHz | `SysTick_Config(72000)` → 1ms |

时钟改变后，所有**已经初始化**的波特率、定时器、ADC 分频和 SysTick 装载值都可能失效。安全流程是：切时钟 → `SystemCoreClockUpdate()` → 重新初始化依赖时钟的外设 → 验证。

## 5.5 验证：至少两种独立证据

不要用“LED 看起来差不多”验证 72MHz。推荐从下列独立证据中至少选两项：

1. 将 TIMx 配为已知频率（例如 1kHz、50% PWM），用逻辑分析仪或示波器测量；
2. 用经过确认的 USB-TTL，在设定波特率下稳定收发文本；
3. GDB 读取 RCC/FLASH 寄存器，核对 HSE/PLL 就绪、SWS、APB 分频与 Flash latency；
4. 用 `RCC_GetClocksFreq()` 输出记录值，并与定时器的实际波形对照。

| 现象 | 首先怀疑 | 下一步 |
|---|---|---|
| HSE/PLL 等待超时 | 晶振/旁路配置、板级硬件或配置不匹配 | 保持 HSI，检查原理图和 RCC 状态 |
| UART 全乱码 | PCLK 与波特率计算不一致 | 核对具体 USART 所在 APB，而非只看 HCLK |
| SysTick 比预期快 8 倍 | 误以为 `SysTick_Config` 使用 HCLK/8 | 改为 `SystemCoreClock / 1000U` |
| PWM 正好差一倍 | 忘记 APB 定时器 ×2 规则 | 重新从 PCLK 与 APB 预分频计算 TIMCLK |
| ADC 数值异常 | ADC 分频超过规格或模拟输入问题 | 先确认 ADCCLK ≤ 14MHz，再检查模拟电路 |

## 5.6 本章验收与练习

- [ ] 时钟函数对 HSE、PLL 和 SWS 都有有限等待；失败时返回可检查状态；
- [ ] `SystemCoreClockUpdate()` 位于成功和回退路径；
- [ ] SysTick 使用 HCLK 装载值，`Timebase_NowMs()` 可被第 3、4 章的非阻塞代码复用；
- [ ] 记录过一次 HCLK/PCLK1/PCLK2 与实测频率/串口结果；
- [ ] 没有把“板上常见 8MHz 晶振”写成未经确认的事实。

练习：

1. 用 TIM2 输出 1kHz PWM，分别在 APB1=/1 和 /2 下计算 TIMCLK；
2. 临时强制 HSE 等待失败，确认函数返回 HSI 而不是卡死（只在副本工程实验）；
3. 把 `SysTick_Config(SystemCoreClock / 8 / 1000U)` 故意用于副本，预测并测量它为何约快 8 倍。

## 5.7 本章要点

- 时钟配置是 SYSCLK、HCLK、PCLK、TIMCLK、ADCCLK 和 Flash latency 的共同合同。
- 72MHz 不等于所有外设都 72MHz；尤其是 APB1=36MHz、定时器可能 ×2、ADC 必须再分频。
- HSE/PLL 轮询必须有退出路径，失败时要有可验证的回退状态。
- CMSIS `SysTick_Config()` 以 HCLK 为时钟源；1ms 用 `SystemCoreClock / 1000U`。
- 正确时基仍不等于非阻塞程序；状态机和第 6 章的中断负责把等待与业务分开。

---

> **上一章**：[第 4 章 · C 语言的嵌入式边界](./04-chapter.md)
>
> **下一章**：[第 6 章 · 中断系统](./06-chapter.md)

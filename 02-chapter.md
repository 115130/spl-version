# 第 2 章 · STM32F103 硬件概览

这一章先建立 STM32F103ZET6 的整体结构：Cortex-M3 内核、Flash、SRAM、总线、外设和时钟分别在哪里，代码里的一个地址最终会落到哪块硬件上。

准备好三份资料：STM32F103xC/D/E 数据手册、RM0008 参考手册，以及你手上开发板的原理图。本章不要求背寄存器地址，重点是知道该去哪里查。

## 2.1 Cortex-M3 和 STM32F103 是什么关系

STM32F103 使用 ARM Cortex-M3 处理器内核。Cortex-M3 定义了 CPU 的指令集、寄存器、异常模型、NVIC、SysTick 和调试接口；ST 在它周围加入 Flash、SRAM、GPIO、USART、SPI、I2C、ADC、定时器、DMA、时钟系统等模块，形成完整的 STM32F103 MCU。

这也是为什么不同厂商的 Cortex-M3 芯片在内核部分很像，但外设寄存器并不通用。你在 STM32 上学到的异常入口、栈、SysTick、NVIC 等 Cortex-M3 概念可以迁移到其他 Cortex-M3 芯片；GPIO、RCC、USART 这些具体寄存器仍要看芯片厂商手册。

Cortex-M3 使用 Thumb-2 指令集，通用寄存器为 R0-R12，R13 是栈指针 SP，R14 是链接寄存器 LR，R15 是程序计数器 PC。还有 xPSR、PRIMASK、BASEPRI、FAULTMASK、CONTROL 等特殊寄存器。现在不用背这些名字，后面调 HardFault 和中断优先级时会再次遇到。

STM32F103 的 Cortex-M3 内核还带 NVIC。F103 实现 4 个有效优先级位，具体怎样分成抢占优先级和子优先级由优先级分组决定，第 6 章会专门处理。

## 2.2 32 位地址空间

Cortex-M3 使用 32 位地址，因此处理器可以表示 `0x00000000` 到 `0xFFFFFFFF` 共 4 GB 的地址空间。STM32F103 把 Flash、SRAM、外设寄存器和内核外设映射到这片空间里的不同区域。

本书最常碰到的区域可以先记这几个起点：

```text
0x0000_0000  启动别名区域，映射内容由启动方式决定
0x0800_0000  主 Flash
0x2000_0000  SRAM
0x4000_0000  外设区域
0x6000_0000  FSMC 外部存储器区域
0xE000_0000  Cortex-M3 系统控制空间
```

STM32F103ZET6 的主 Flash 容量是 512 KB，SRAM 是 64 KB。程序通常烧在 `0x08000000` 开始的 Flash 中，运行期变量主要放在 `0x20000000` 开始的 SRAM 中。

外设寄存器也占地址。CPU 访问 GPIO、USART 或 RCC 时，执行的仍然是普通的 load/store 指令，只是目标地址落在外设区域，芯片内部总线把这次访问送到对应外设。

这就是内存映射外设。C 代码里对这些寄存器的定义使用 `volatile`，防止编译器把硬件需要的读写随意合并、缓存或删除。

## 2.3 从 GPIOB 地址看内存映射

GPIOB 的基地址是：

```text
0x4001_0C00
```

几个常用寄存器位于这个基地址之后：

| 寄存器 | 偏移 | 地址 | 用途 |
|---|---:|---:|---|
| CRL | `0x00` | `0x40010C00` | 配置 PB0-PB7 |
| CRH | `0x04` | `0x40010C04` | 配置 PB8-PB15 |
| IDR | `0x08` | `0x40010C08` | 读取输入电平 |
| ODR | `0x0C` | `0x40010C0C` | 输出数据寄存器 |
| BSRR | `0x10` | `0x40010C10` | 原子置位/复位 |
| BRR | `0x14` | `0x40010C14` | 原子复位 |

SPL 头文件里没有要求你手写这些绝对地址。`stm32f10x.h` 已经定义了外设基地址和结构体：

```c
#define GPIOB_BASE  (APB2PERIPH_BASE + 0x0C00)
#define GPIOB       ((GPIO_TypeDef *) GPIOB_BASE)
```

`GPIO_TypeDef` 的字段顺序对应 CRL、CRH、IDR、ODR、BSRR、BRR 等寄存器。这样写：

```c
GPIOB->ODR
```

编译后就是访问 GPIOB 基地址加 ODR 偏移。

SPL 的 `GPIO_SetBits(GPIOB, GPIO_Pin_5)` 向 BSRR 的低 16 位写入对应 bit；`GPIO_ResetBits(GPIOB, GPIO_Pin_5)` 在 STM32F1 SPL 实现中写 BRR。两种写法都不需要先读取 ODR 再改写，因此适合做单独引脚的原子置位或复位。

## 2.4 总线为什么重要

Cortex-M3 内核通过多条总线访问 Flash、SRAM 和外设。对写程序最直接的影响，是不同外设挂在不同总线上，时钟频率和 RCC 使能位也不同。

STM32F103 常见的几条总线关系可以简化成：

```text
Cortex-M3
   │
   ├── I-Code / D-Code ── Flash
   └── System Bus
          │
          ├── SRAM
          ├── DMA / AHB 外设
          └── AHB-to-APB Bridge
                 ├── APB1
                 └── APB2
```

AHB 连接内核、SRAM、DMA、Flash 接口等高速模块。APB1 和 APB2 主要连接外设。CPU 访问 APB 外设时，请求会经过 AHB 到 APB 的桥。

在 STM32F103 的额定工作范围内，APB1 最高 36 MHz，APB2 最高 72 MHz。USART1、SPI1、GPIO、AFIO 等在 APB2；USART2/3、I2C、SPI2/3、TIM2-TIM7 等主要在 APB1。具体归属查 RM0008 的 memory map 和 RCC 章节。

这会直接影响代码。例如 GPIOB 在 APB2：

```c
RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
```

USART2 在 APB1：

```c
RCC_APB1PeriphClockCmd(RCC_APB1Periph_USART2, ENABLE);
```

写外设驱动前先确认它挂在哪条总线上，可以避免把 RCC 使能函数写错。

还有一个后面经常用到的规则：如果 APB 预分频器配置为 1，定时器时钟等于对应 PCLK；如果 APB 预分频器配置为 2、4、8 或 16，挂在该 APB 上的定时器时钟通常为 PCLK 的 2 倍。第 7 章计算定时器频率时会实际使用这个规则。

## 2.5 时钟树

CPU 和大部分数字外设都需要时钟才能工作。STM32F103 的系统时钟可以来自 HSI、HSE，也可以由 PLL 产生更高频率，再通过 AHB、APB1、APB2 分频器送到各个模块。

常见的 72 MHz 配置是：外部晶振 HSE 经过 PLL 倍频得到 72 MHz，再让 AHB 保持 72 MHz、APB1 分频到 36 MHz、APB2 保持 72 MHz。这里的 HSE 频率必须以实际开发板为准；很多板使用 8 MHz 晶振，但不能只凭芯片型号假定。

以 8 MHz HSE 的常见板卡为例：

```text
HSE 8 MHz
   │
   └── PLL ×9 ── SYSCLK 72 MHz
                    │
                    ├── AHB /1  ── HCLK  72 MHz
                    │                │
                    │                └── CPU、SRAM、DMA...
                    │
                    ├── APB1 /2 ── PCLK1 36 MHz
                    │                └── USART2/3、I2C、TIM2-7...
                    │
                    └── APB2 /1 ── PCLK2 72 MHz
                                     └── GPIO、USART1、SPI1、TIM1...
```

PLL 切换不是一次寄存器写入就结束。程序需要启动时钟源、等待 ready 标志、配置 Flash latency 和总线分频，再启动 PLL、等待 PLL 锁定，最后切换 SYSCLK，并检查实际的 SWS 状态。

等待外部晶振和 PLL 时要设置超时。HSE 没焊、晶体损坏、负载电容不合适或者板卡线路有问题时，ready 标志可能一直不出现。第 5 章会实现带超时和回退路径的时钟初始化。

72 MHz 工作时，Flash 访问需要按照器件手册设置等待周期；ADC 时钟也有上限，不能直接把 72 MHz PCLK2 全速送给 ADC。这些限制都来自数据手册和 RM0008，不应只从示例代码里抄一个数值。

修改系统时钟以后，要重新检查依赖时钟的外设。UART 波特率、定时器周期、SysTick 和 ADC 都会受到影响。

## 2.6 引脚复用

STM32 的一个封装引脚通常可以承担多个功能。以 PA9 为例，它可以作为普通 GPIO，也可以作为 USART1_TX；USART1 还可以通过 AFIO 重映射到其他规定引脚。

使用哪个功能，需要同时看三件事：

1. 数据手册里的引脚功能表，确认这个封装引脚支持哪些外设功能。
2. RM0008 里的 AFIO 和外设章节，确认是否需要重映射以及相应控制位。
3. 开发板原理图，确认这个引脚有没有接到 LED、USB 串口、Flash 或其他板载器件。

STM32F1 的复用配置主要通过 GPIO 的模式配置和 AFIO 重映射完成。比如 USART TX 通常配置为复用推挽输出，RX 按对应输入模式配置；具体模式第 3 章和第 8 章再展开。

PA13 和 PA14 默认用于 SWDIO 和 SWCLK。调试阶段不要随意关闭 SWD 或把这两个引脚改作普通 GPIO，否则 ST-Link 会失去正常的 SWD 连接。确实需要复用调试引脚时，要提前准备恢复手段。

## 2.7 数据手册、参考手册和原理图分别查什么

这三份资料解决的问题不同。

- **数据手册**：查具体型号的容量、封装、引脚复用、电气参数、最大频率、ADC 限制等。
- **RM0008 参考手册**：查寄存器、总线、RCC、外设工作方式、状态位和操作流程。
- **开发板原理图**：查板载 LED、按键、CH340、晶振、SPI Flash、跳帽和电源电路实际接到了哪里。

还有一份经常被忽略的资料：芯片勘误表。遇到某个外设行为和参考手册对不上时，尤其是 I2C、ADC、调试接口等复杂模块，要检查对应 silicon revision 的 errata。

网页文章和示例工程适合快速找到关键词，最终参数最好回到这些一手资料确认。

## 2.8 动手查 USART1

现在用 USART1 做一次完整查找。

先在 RM0008 的 memory map 找 USART1，可以看到它的基地址是：

```text
USART1_BASE = 0x4001_3800
```

然后在数据手册的引脚表里找 USART1_TX。默认映射可以使用 PA9，USART1_RX 默认使用 PA10。再去 RCC 章节确认 USART1 属于 APB2，因此初始化时需要打开 USART1 和相应 GPIO 的 APB2 时钟。

最后看开发板原理图，确认 PA9、PA10 有没有接到板载 USB-UART，或者是否已经被其他电路占用。如果板载 CH340 实际接的是另一组 UART，就不能因为教程写了 USART1 而直接假定 PA9/PA10 已经连到电脑。

做完后，你应该能从资料中得到这样一条完整关系：

```text
USART1
  ├── 寄存器基地址：0x40013800
  ├── 总线：APB2
  ├── 默认 TX/RX：PA9 / PA10
  ├── RCC：USART1 + GPIOA
  └── 板上是否接 USB-UART：查原理图
```

以后接 SPI、I2C、ADC 或定时器，也按这个流程查。

## 2.9 外设初始化前先确认四件事

写驱动前先回答下面四个问题：

1. **外设实例**：使用 USART1 还是 USART2，SPI1 还是 SPI2？
2. **引脚**：默认映射还是重映射？板卡上有没有被其他器件占用？
3. **时钟**：外设挂 APB1、APB2 还是 AHB？当前 PCLK 到底是多少？
4. **验证方法**：准备观察什么结果？GPIO 电平、串口文本、逻辑分析仪波形还是寄存器状态？

比如 USART1 没有输出，先检查 PA9、GPIOA 时钟、USART1 时钟、PCLK2 和板卡接线。直接修改 BRR 或换一段网上代码，通常只会让变量更多。

## 2.10 本章验收

打开自己的数据手册、RM0008 和开发板原理图，再选一个外设完成一次定位。可以继续用 USART1，也可以选 SPI1 或 I2C1。

至少记录：外设基地址、所属总线、默认引脚、是否支持重映射、需要打开哪些 RCC 时钟，以及这些引脚在你的开发板上接了什么。

完成这一步以后，第 3 章开始实际配置 GPIO。到那时看到 `GPIOA->CRL`、`RCC_APB2PeriphClockCmd()` 或 `GPIO_Init()`，你应该能知道它们分别对应地址空间、总线时钟和引脚配置中的哪一部分。

> **上一章**：[第 1 章 · 什么是嵌入式系统](./01-chapter.md)
>
> **下一章**：[第 3 章 · GPIO 与寄存器编程（SPL版）](./03-chapter.md)

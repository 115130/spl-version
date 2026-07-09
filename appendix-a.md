# 附录 A · STM32F103 寄存器速查（SPL版）

> 仅列出最常用的寄存器。完整寄存器描述请查阅 RM0008 参考手册。这些地址和 SPL/HAL 无关——SPL 结构体内部的偏移量就是这些值。

---

## RCC（时钟控制）

基地址：`0x4002_1000`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CR | 0x00 | `RCC_HSEConfig()` / `RCC_PLLCmd()` |
| CFGR | 0x04 | `RCC_SYSCLKConfig()` |
| APB2ENR | 0x18 | `RCC_APB2PeriphClockCmd()` — GPIO/USART1/SPI1/ADC1 |
| APB1ENR | 0x1C | `RCC_APB1PeriphClockCmd()` — TIM2-7/USART2-3/I2C/SPI2 |

---

## GPIO

基地址：GPIOA=`0x4001_0800` GPIOB=`0x4001_0C00` GPIOC=`0x4001_1000`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CRL / CRH | 0x00/0x04 | `GPIO_Init()` — MODE[1:0] + CNF[1:0] |
| IDR | 0x08 | `GPIO_ReadInputDataBit()` |
| ODR | 0x0C | `GPIO_Write()` |
| BSRR | 0x10 | `GPIO_SetBits()` / `GPIO_ResetBits()` — 低 16 位置 1，高 16 位清 0 |

---

## USART

USART1=`0x4001_3800` USART2=`0x4000_4400`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| SR | 0x00 | `USART_GetFlagStatus()` — TXE(7), RXNE(5), IDLE(4) |
| DR | 0x04 | `USART_SendData()` / `USART_ReceiveData()` |
| BRR | 0x08 | `USART_Init()` 计算波特率 |
| CR1 | 0x0C | `USART_Cmd()` — UE(13), TE(3), RE(2) |

---

## TIM

TIM2=`0x4000_0000` TIM3=`0x4000_0400`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CR1 | 0x00 | `TIM_Cmd()` — CEN(0) |
| DIER | 0x0C | `TIM_ITConfig()` — UIE(0) |
| SR | 0x10 | `TIM_GetITStatus()` / `TIM_ClearITPendingBit()` |
| PSC | 0x28 | TIM_TimeBaseInit — 预分频器 |
| ARR | 0x2C | TIM_TimeBaseInit — 自动重装载 |
| CCR1-4 | 0x34-0x40 | `TIM_SetCompare1-4()` — PWM 占空比 |

---

## ADC

ADC1=`0x4001_2400`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| SR | 0x00 | `ADC_GetFlagStatus()` — EOC(1) |
| CR2 | 0x08 | `ADC_Cmd()` — ADON(0), CONT(1), SWSTART(22) |
| DR | 0x4C | `ADC_GetConversionValue()` |

---

## I2C

I2C1=`0x4000_5400`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CR1 | 0x00 | `I2C_Cmd()` — PE(0), START(8), STOP(9), ACK(10) |
| SR1 | 0x04 | `I2C_CheckEvent()` — SB(0), ADDR(1), TXE(7), RXNE(6) |
| DR | 0x10 | `I2C_SendData()` |

---

## SPI

SPI1=`0x4001_3000`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CR1 | 0x00 | `SPI_Cmd()` — SPE(6), MSTR(2), CPOL(1), CPHA(0) |
| SR | 0x04 | `SPI_I2S_GetFlagStatus()` — TXE(1), RXNE(0) |
| DR | 0x08 | `SPI_I2S_SendData()` / `SPI_I2S_ReceiveData()` |

---

## SysTick (Cortex-M3 内核)

基地址：`0xE000_E010`

| 寄存器 | 偏移 | SPL 操作 |
|--------|------|--------|
| CTRL | 0x00 | `SysTick_Config()` 内部配置 — ENABLE(0), TICKINT(1) |
| LOAD | 0x04 | 重装载值（24 位） |
| VAL | 0x08 | 当前值（写任意值清零） |

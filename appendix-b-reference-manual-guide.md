# 附录 B · 怎样读数据手册、参考手册与 SPL 头文件

> 嵌入式开发不是背寄存器地址，而是知道遇到问题时该去哪个文档找答案。

## B.1 三类文档各自解决什么问题

| 文档 | 回答的问题 |
|---|---|
| Datasheet 数据手册 | 芯片有哪些引脚、封装、电压范围、外设数量、电气特性 |
| Reference Manual 参考手册 | 外设寄存器怎么配置、时钟如何连接、中断/DMA 如何工作 |
| SPL 头文件与源码 | 某个 GPIO_Init、USART_Init 实际写了哪些寄存器 |
| 开发板原理图 | 板载 LED、按键、USB、RS485、OLED 接到了哪个引脚 |

例如要让 USART2 工作：

1. 数据手册：确认 PA2/PA3 是否可用；
2. 参考手册：确认 USART2 在 APB1、需要开什么时钟；
3. SPL 头文件：确认 RCC_APB1Periph_USART2 和 USART_InitTypeDef 的字段；
4. 原理图：确认 PA2/PA3 没被板载设备占用。

## B.2 查一个外设的固定顺序

以 I2C 为例：

1. 先看引脚复用表，确认 SCL/SDA；
2. 看时钟树，确认外设时钟来源；
3. 看初始化寄存器与状态标志；
4. 看错误标志与清除顺序；
5. 最后看中断/DMA 章节。

这个顺序比直接搜索某个函数名更容易建立完整模型。

## B.3 常见关键词

| 需求 | 在文档中搜索 |
|---|---|
| 某引脚能否当 UART | alternate function、pin definition |
| 某外设挂在哪条总线 | clock enable、APB1、APB2 |
| DMA 通道 | DMA request mapping |
| 中断名字 | interrupt vector、NVIC |
| 低功耗唤醒 | wakeup source、STOP、STANDBY |
| 最大输入电压 | absolute maximum ratings、operating conditions |

## B.4 从 SPL 函数回到寄存器

当你看到：

~~~c
GPIO_SetBits(GPIOC, GPIO_Pin_13);
~~~

下一步不是死记函数名，而是：

1. 打开 stm32f10x_gpio.c；
2. 看它写的是 BSRR 还是 BRR；
3. 回到参考手册查 BSRR/BRR 的语义；
4. 在 GDB 中观察 GPIOC 的寄存器变化。

这样学完 SPL 后，迁移到 HAL、LL 或裸寄存器仍然能定位问题。

## B.5 每章都该记录什么

建议建立自己的硬件笔记，至少记录：

- 使用的芯片和开发板版本；
- 引脚、供电、电平和接线；
- 外设时钟、波特率、采样率；
- 关键寄存器或 SPL 初始化参数；
- 预期现象；
- 失败现象与最后的解决办法。

[返回 README](./README.md)

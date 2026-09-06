# 第 1 章 · 什么是嵌入式系统

第 0 章已经把程序烧进 STM32，并让 LED 跑了起来。这一章先回答一个更基础的问题：没有操作系统时，C 程序是怎么从上电一路执行到 `main()` 的。

读完后，你应该能在自己的工程里找到向量表、`Reset_Handler`、`SystemInit()` 和 `main()`，并说清 Flash、SRAM、栈和外设寄存器分别做什么。

## 1.1 PC 程序和裸机程序差在哪

写 Java 时，源码不会直接成为 CPU 上电后执行的第一段代码。中间还有 JVM、操作系统、驱动等软件层：

```text
HelloWorld.java
      ↓ javac
HelloWorld.class
      ↓ JVM
操作系统
      ↓
驱动 / 硬件
```

STM32 裸机程序的链路短得多。GCC 把 C 和汇编编译成 Cortex-M3 机器码，链接器按照链接脚本安排地址，最终镜像被写进片上 Flash。芯片复位后，CPU 从向量表取得初始栈地址和复位入口，然后开始执行启动代码。

这里没有 JVM，也没有进程、虚拟内存和文件系统。需要 GPIO 时，程序配置 GPIO 寄存器；需要串口时，程序配置 USART 寄存器。SPL 提供了一层 C 函数封装，但底下仍然是这些外设寄存器。

## 1.2 上电后先执行什么

STM32F103 按启动配置从用户 Flash 启动时，用户 Flash 的物理起始地址是 `0x08000000`。启动别名会让复位时的向量表出现在 CPU 期望的启动地址空间中。

向量表最前面的两个 32 位值最重要：

```asm
.section .isr_vector,"a",%progbits
.word  _estack           @ 初始 MSP
.word  Reset_Handler     @ 复位入口
.word  NMI_Handler
.word  HardFault_Handler
@ ...
```

CPU 复位时先把第一项装入 MSP（Main Stack Pointer），再从第二项取得 `Reset_Handler` 地址。后面的表项对应 NMI、HardFault 和各种外设中断。

本书的启动文件在 [`code/startup_stm32f10x_hd.s`](./code/startup_stm32f10x_hd.s)。`Reset_Handler` 的核心流程可以简化成：

```text
复制 .data 到 SRAM
      ↓
清零 .bss
      ↓
SystemInit()
      ↓
__libc_init_array()
      ↓
main()
```

`.data` 和 `.bss` 的处理发生在 `main()` 之前。比如：

```c
uint32_t a = 123;
uint32_t b;
```

`a` 运行时放在 SRAM，但初始值 `123` 需要保存在 Flash。启动代码会把这个初始值复制到 `.data` 对应的 SRAM 地址。`b` 放在 `.bss`，启动代码在进入 `main()` 前把它清零。

对应的边界符号由链接脚本提供：

```text
_sidata
_sdata
_edata
_sbss
_ebss
```

启动文件和链接脚本必须使用同一套符号名。第 0 章已经用 GDB 验证过 `Reset_Handler → main()`，这里要理解那两个断点之间实际发生了什么。

## 1.3 Flash、SRAM 和栈

STM32F103ZET6 有 512 KB Flash 和 64 KB SRAM。

Flash 主要保存程序代码、只读数据和初始化数据。断电后内容仍然保留，烧录器写入的就是这块存储器。CPU 可以直接从 Flash 取指执行程序，不需要像 PC 那样先由操作系统把整个可执行文件加载进 RAM。

SRAM 保存运行期间会变化的数据，包括全局变量、静态变量、栈，以及程序使用堆时分配出来的动态内存。断电后 SRAM 内容消失。

栈位于 SRAM。函数调用时，局部变量、保存的寄存器和返回地址等内容可能进入栈。向量表第一项 `_estack` 给出了初始栈顶地址；在本书的 ZET6 链接脚本里，它位于 SRAM 顶部附近。

可以在第 0 章生成的 ELF 中查看这些符号：

```bash
arm-none-eabi-nm -n build/blink.elf \
  | rg '(_estack|_sidata|_sdata|_edata|_sbss|_ebss|Reset_Handler|main)'
```

MAP 文件则能看到 `.text`、`.data`、`.bss` 等段到底占了多少空间。

## 1.4 裸机、RTOS 和 Linux

STM32F103 很适合裸机和小型 RTOS。它有 Cortex-M3 内核、64 KB SRAM，没有面向桌面或应用处理器那类系统设计的 MMU，内存和存储资源也远小于常见 Linux 系统。

Linux 历史上存在针对无 MMU 处理器的配置，但 STM32F103 这一级别的芯片并不是本书所说的 Embedded Linux 平台。实际产品里，常见 Linux SoC 会有 Cortex-A 一类应用处理器、更多 RAM、外部存储和更完整的系统外设。

本书前半段使用裸机：

```c
int main(void)
{
    Hardware_Init();

    while (1) {
        App_Poll();
    }
}
```

中断负责处理需要及时响应的硬件事件，主循环处理普通业务。后面加入 FreeRTOS 后，会把部分工作拆成任务，由调度器决定哪个任务运行。

RTOS 仍然运行在 MCU 上，不会自动带来 Linux 的进程、虚拟内存和完整文件系统。它主要提供任务调度、队列、信号量、软件定时器等机制。

## 1.5 外设寄存器也在地址空间里

在 C 代码里看到：

```c
GPIOB->ODR
USART1->SR
RCC->APB2ENR
```

这些看起来像普通结构体成员，但对应的是固定硬件地址。Cortex-M3 通过内存映射 IO 访问外设，读写这些地址会直接访问 RCC、GPIO、USART 等硬件模块。

例如 GPIOB 的寄存器基地址在设备头文件里由宏定义出来，SPL 再把常见操作封装成函数：

```c
RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
GPIO_Init(GPIOB, &gpio);
GPIO_SetBits(GPIOB, GPIO_Pin_5);
```

第一行使能 GPIOB 所在外设时钟。STM32F1 为了控制功耗，很多外设复位后默认没有时钟；在配置这类外设前，应先使能对应 RCC 时钟。没有时钟时，外设不会按正常工作状态响应配置，具体寄存器行为要以参考手册为准。

## 1.6 读一段最小 GPIO 代码

下面用 PB5 上的外接 LED 演示 SPL 调用。PB5 只是实验引脚，板载 LED 继续由 `board.h` 配置。

先包含需要的头文件：

```c
#include "stm32f10x.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_gpio.h"
```

然后打开 GPIOB 时钟：

```c
RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
```

配置 PB5 为推挽输出：

```c
GPIO_InitTypeDef gpio;

GPIO_StructInit(&gpio);
gpio.GPIO_Pin = GPIO_Pin_5;
gpio.GPIO_Mode = GPIO_Mode_Out_PP;
gpio.GPIO_Speed = GPIO_Speed_2MHz;
GPIO_Init(GPIOB, &gpio);
```

`GPIO_StructInit()` 先给结构体填入 SPL 定义的默认值，再覆盖本次需要的字段。这样所有字段都有明确值。

输出高低电平：

```c
GPIO_ResetBits(GPIOB, GPIO_Pin_5);
GPIO_SetBits(GPIOB, GPIO_Pin_5);
```

在 STM32F1 SPL 中，`GPIO_SetBits()` 写 GPIO 的 BSRR 置位部分，`GPIO_ResetBits()` 写 BRR 完成复位。两种操作都通过“写 1 触发对应位”的寄存器完成，不需要先读 ODR、修改某一位再写回，因此适合单独改变指定 GPIO。

如果 LED 是低电平点亮，那么 `GPIO_ResetBits()` 会让它亮，`GPIO_SetBits()` 会让它灭；高有效 LED 的结果相反。有效电平由实际电路决定。

## 1.7 `while (1)` 为什么一直存在

裸机固件通常不会像命令行程序那样执行完后退出。`main()` 完成初始化后，会进入长期运行的主循环：

```c
while (1) {
    ReadInputs();
    UpdateState();
    DriveOutputs();
}
```

程序运行到这里后会一直循环，直到复位或断电。真正需要关心的是循环里每次做多少工作、有没有长时间阻塞，以及中断和主循环之间怎样交换数据。

第 0 章的 blink 工程已经使用 SysTick 计时，没有继续采用这种空循环延时：

```c
for (volatile uint32_t i = 0; i < 500000U; ++i) {
}
```

空循环的实际时间会随主频、编译器和优化等级变化，而且执行期间 CPU 一直被占用。第 5 章会继续把时基、回绕和非阻塞等待讲清楚。

## 1.8 SPL 在这里做了什么

SPL 没有改变硬件工作方式。它主要把寄存器位操作整理成结构体和函数。

例如：

```c
GPIO_Init(GPIOB, &gpio);
```

内部会根据 `GPIO_Pin`、`GPIO_Mode` 和 `GPIO_Speed` 计算 STM32F1 的 CRL/CRH 配置位并写入寄存器。你可以直接打开 `stm32f10x_gpio.c` 看实现。

这也是本书前面使用 SPL 的原因：写代码时不用每次手算寄存器位，同时还能顺着函数看到具体寄存器操作。以后换 HAL 时，可以继续用同样的方法追它的初始化流程。

## 1.9 用 GDB 再走一次启动路径

烧录第 0 章的 blink 工程后启动 OpenOCD，然后连接 GDB：

```gdb
arm-none-eabi-gdb build/blink.elf
(gdb) target remote :3333
(gdb) monitor reset halt
(gdb) break Reset_Handler
(gdb) break main
(gdb) continue
```

命中 `Reset_Handler` 后，可以用：

```gdb
(gdb) info registers sp pc
```

查看当前栈指针和程序计数器。继续运行到 `main`，再比较 PC 的位置。

如果 `Reset_Handler` 断点都不能命中，先检查启动文件、链接地址、烧录结果和 OpenOCD 连接。如果能进入 `main`，启动链路已经成立，GPIO 或 LED 的问题再到外设配置里查。

## 1.10 本章练习

先打开自己的 `startup_stm32f10x_hd.s` 和 `link.ld`，找到：

- 向量表第一项 `_estack`
- 向量表第二项 `Reset_Handler`
- `.data` 的 `_sidata`、`_sdata`、`_edata`
- `.bss` 的 `_sbss`、`_ebss`
- `SystemInit()`
- `main()`

然后在 `main.c` 新增两个变量：

```c
uint32_t initialized_value = 0x12345678U;
uint32_t zero_value;
```

重新构建，用 MAP 文件或 `arm-none-eabi-nm` 找到它们。确认 `initialized_value` 属于 `.data`，`zero_value` 属于 `.bss`。

最后画出这条路径：

```text
复位
 ↓
向量表
 ↓
Reset_Handler
 ↓
.data 复制 / .bss 清零
 ↓
SystemInit
 ↓
main
 ↓
while (1)
```

能根据工程里的实际文件解释这条路径，这一章就完成了。

> **上一章**：[第 0 章 · 开发环境搭建（SPL版）](./00-chapter.md)
>
> **下一章**：[第 2 章 · STM32F103 硬件概览](./02-chapter.md)

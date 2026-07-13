# 第 1 章 · 什么是嵌入式系统

> **本章产出**：能画出程序从复位向量到 `main()` 再到 `while(1)` 的路径，并能把 Flash、SRAM、栈、外设寄存器同你熟悉的 PC 软件层次对应起来。
>
> **前置知识**：完成第 0 章，已有一个能编译、能烧录的 LED 工程。
>
> **本章验收**：不看资料，解释“为什么 MCU 没有 OS 也能运行 C 程序”，并在自己的工程里找到启动文件、`SystemInit()` 与 `main()`。

---

## 1.1 你熟悉的 PC 世界

先回顾一下你写 Java 时发生了什么：

```
你写的 HelloWorld.java
        ↓ javac 编译
    HelloWorld.class (字节码)
        ↓ java 命令启动 JVM
    JVM 加载 .class → 解释/即时编译 → 系统调用
        ↓
    Linux/Windows/macOS 内核 → 驱动 → CPU 执行
```

这个链条上有几层：

| 层 | 干什么 | 在嵌入式世界 |
|----|--------|------------|
| 编程语言运行时（JVM/CLR） | GC、JIT、类加载... | **没有** |
| 操作系统内核 | 进程调度、虚拟内存、文件系统、网络栈... | **可能没有**（裸机），或只有一个轻量 RTOS |
| 驱动层 | 把 OS 的抽象操作翻译成硬件操作 | 你自己写 |
| 硬件 | CPU + 内存 + 外设 | 就是 MCU 本身 |

**嵌入式的本质**：你的 C 代码直接被编译成 ARM 机器码，烧进 Flash，CPU 上电后从第一条指令开始执行。没有 JVM，没有 OS，没有虚拟内存，什么都要自己来。

这可能让你觉得无所适从，但换个角度：**你也因此拥有了对硬件的完全掌控**。

## 1.2 MCU 是怎么「跑」程序的

### 上电瞬间发生了什么

当你给 STM32 供上 3.3V 电，并按启动配置从用户 Flash 启动时：

```
上电 → 内部复位电路等电压稳定
     → 启动存储器在 0x0000_0000 处形成一个别名映射
     → 用户 Flash 的物理起始地址仍是 0x0800_0000
     → 0x0000_0000 存的是 栈顶指针 MSP 的初始值
     → 0x0000_0004 存的是 Reset_Handler 的地址（这就是第一个要执行的函数）
     → Reset_Handler 里：初始化数据段、初始化时钟、调 main()
     → 你的 main() 开始执行
```

用代码说话。打开本书的 [`code/startup_stm32f10x_hd.s`](./code/startup_stm32f10x_hd.s)（启动汇编文件）：

```asm
.section .isr_vector,"a",%progbits
.word  _estack           @ 偏移 0x00：栈顶地址
.word  Reset_Handler     @ 偏移 0x04：复位后第一条指令地址
.word  NMI_Handler       @ 偏移 0x08：不可屏蔽中断
.word  HardFault_Handler @ 偏移 0x0C：硬件错误
@ ... 其他中断向量 ...
```

这个表就叫**中断向量表**（Vector Table）。它告诉 CPU：发生各种事件时，跳到哪里去执行。

`Reset_Handler` 的简化逻辑：

```asm
Reset_Handler:
    @ 把 .data 段从 Flash 复制到 RAM（初始化全局变量）
    ldr   r0, =_sidata
    ldr   r1, =_sdata
    ldr   r2, =_edata
1:  cmp   r1, r2
    bcs   2f
    ldr   r3, [r0], #4
    str   r3, [r1], #4
    b     1b

    @ 清零 .bss 段（未初始化的全局变量）
2:  ldr   r1, =_sbss
    ldr   r2, =_ebss
    movs  r3, #0
3:  cmp   r1, r2
    bcs   4f
    str   r3, [r1], #4
    b     3b

4:  bl    SystemInit          @ 按 system_stm32f10x.c 的配置初始化时钟
    bl    __libc_init_array    @ 运行期初始化钩子（若链接到）
    bl    main                 @ 跳到你的 main() 函数
    b     .                    @ main() 返回后的死循环（理论上不会执行到）
```

注意两点：CPU 在进入 `Reset_Handler` 前已经把向量表第一项装入 MSP，所以启动汇编不必再次设置栈指针；`.data`、`.bss` 的边界符号由链接脚本和启动文件共同约定，二者必须成对修改。本书第 0 章的实际模板已经把这份约定放进 `examples/00-blink-zet6/`，不要混用网上另一份启动文件和链接脚本。

### Flash 和 RAM 的分工

对比你熟悉的 PC：

| | PC（跑 Java） | STM32F103ZET6（跑裸机） |
|---|---|---|
| **程序在哪** | 硬盘 → OS 加载到 RAM | 直接烧在 Flash（512KB），CPU 直接从 Flash 取指执行 |
| **数据在哪** | 堆（new 出来的对象）+ 栈 | SRAM（64KB）= 全局/静态变量 + 堆 + 栈 |
| **「加载」** | OS 的加载器把 ELF/PE 读到 RAM | 不需要加载——Flash 就是 ROM，CPU 直接读 |

这就是「哈佛架构」的体现：**指令总线从 Flash 取指，数据总线从 SRAM 读写，两者可以同时进行**。

## 1.3 裸机 vs RTOS vs Linux

很多初学者会问：「STM32 能跑 Linux 吗？」

**不能。** 因为 STM32F103 没有 MMU（内存管理单元），Linux 内核必须要 MMU 来做虚拟内存。

三种嵌入式软件架构：

| | 裸机（Bare Metal） | RTOS | Embedded Linux |
|---|---|---|---|
| **代表** | 本书 Part 1-3 | 本书 Part 4+ | 树莓派、全志、i.MX |
| **CPU** | Cortex-M0/M3/M4 | Cortex-M3/M4/M7 | Cortex-A 系列 |
| **RAM** | 几 KB ~ 几百 KB | 几十 KB ~ 几 MB | ≥ 64MB |
| **调度** | 一个 `while(1)` 循环 + 中断 | 多任务抢占调度 | 完整的 Linux 进程调度 |
| **网络** | 自己接 WiFi 模块 + 手动发 AT 指令 | lwIP 协议栈 | 完整的 TCP/IP 栈 |
| **学习曲线** | 最陡但最根本 | 中等 | 类 PC 开发，但硬件细节被屏蔽 |

本书的路线：**裸机起步 → RTOS → 加上无线模块 → 上云**。你学的是最底层的、但也最通用的能力。

## 1.4 嵌入式开发的「全栈」

在全栈 Web 开发中，一个开发者要懂：前端（HTML/CSS/JS）→ 后端（Java/Go/Node）→ 数据库 → DevOps。

嵌入式也有自己的「全栈」：

```
    ┌──────────────────────┐
    │   云平台 / 手机 App    │  ← MQTT / HTTP / BLE
    ├──────────────────────┤
    │   无线通信模块         │  ← WiFi (DX-WF24/ESP8266) / 蓝牙 (HC-05)
    ├──────────────────────┤
    │   MCU 固件            │  ← C 语言 + FreeRTOS + SPL
    ├──────────────────────┤
    │   硬件 / 电路          │  ← 原理图、PCB、焊接
    └──────────────────────┘
```

这本书覆盖中间两层（MCU 固件 + 无线模块），基础涉及第四层（会看原理图、会用面包板接线），并延伸到第一层（设备如何跟云端交互）。

## 1.5 动手：逐行读 SPL 版 `main.c`

回到实际模板的 [`examples/00-blink-zet6/main.c`](./examples/00-blink-zet6/main.c)。下面另用 **PB5 上外接的测试 LED** 演示 SPL 的 GPIO 调用；它不是本书默认板载 LED，也不能替代 `board.h` 的板级配置。

### 头文件

```c
#include "stm32f10x.h"          // 芯片寄存器地址定义（GPIOA→0x40010800 这些宏）
#include "stm32f10x_rcc.h"      // 时钟控制 API
#include "stm32f10x_gpio.h"     // GPIO 驱动 API
```

SPL 的头文件体系非常扁平——你要用什么外设，就 include 什么头文件。没有 HAL 的 `main.h` 把所有东西包一层。

### 延时函数

```c
void delay(void) {
    volatile uint32_t i;
    for (i = 0; i < 500000; i++);
}
```

- `volatile` 告诉编译器“每次读写这个对象都必须保留为可观察访问”
- 不带 `volatile`，编译器看到 `for(i=0;i<500000;i++);` 空循环可能会直接删掉，因为它觉得「这循环啥也没干」
- 这个延时非常粗略——不精确，也会占满 CPU。`volatile` 不能让它变成定时器，不能让递增操作原子，也不能替代中断同步；第 5 章会用 SysTick 定时器替代它

### main() 三部曲

```c
int main(void)
{
    // ① 开启 GPIOB 的时钟
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
```

**任何外设使用前必须先开时钟**——这是 STM32 的铁律。不开时钟，属于那个外设的所有寄存器都不可访问，写入无效，读取为 0。STM32F103 的时钟设计像一栋大楼每层有独立电闸——GPIOB 挂在 APB2 总线上，对应 RCC 寄存器的第 3 位。`RCC_APB2PeriphClockCmd` 就是帮你去置那个位的。

```c
    // ② 配置 PB5 为推挽输出（外接测试 LED，不是板载 LED 的固定引脚）
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);               // 填默认值：输入浮空、2MHz、所有引脚
    gpio.GPIO_Pin   = GPIO_Pin_5;         // 选外接测试引脚 PB5
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;   // 推挽输出（Push-Pull）
    gpio.GPIO_Speed = GPIO_Speed_2MHz;    // LED 等低速信号不需要 50MHz 边沿
    GPIO_Init(GPIOB, &gpio);
```

`GPIO_InitTypeDef` 是 SPL 的 GPIO 配置结构体。`GPIO_StructInit` 把字段填成该库定义的默认值，你再覆盖需要的字段，这样不会因为遗漏字段而把栈上的随机值写入寄存器。实际板载 LED 的端口、有效电平不应硬编码在这里，而应放进 `board.h`（见第 0 章模板）。

```c
    // ③ 主循环——嵌入式程序永不退出
    while (1) {
        GPIO_ResetBits(GPIOB, GPIO_Pin_5);   // 输出 0（外接 LED 若低有效则亮）
        delay();
        GPIO_SetBits(GPIOB, GPIO_Pin_5);     // 输出 1（外接 LED 若低有效则灭）
        delay();
    }
}
```

`GPIO_ResetBits` 和 `GPIO_SetBits` 最终操作的是 GPIO 的 **BSRR** 寄存器——一个特殊的硬件设计：写 `1` 到某个位 = 置位/复位对应引脚；写 `0` 无效。这个机制保证了 GPIO 操作的**原子性**——你不需要读-改-写，不会产生竞态条件。

### SPL vs HAL 对照

| 初始化步骤 | HAL（CubeMX 生成） | SPL（你手写） |
|---|---|---|
| 重置外设状态 | `HAL_Init()` | `SystemInit()` 在启动文件中自动调用 |
| 配置系统时钟 | `SystemClock_Config()` | 默认 HSI 8MHz，够用（后面章节再调） |
| 初始化 GPIO | `MX_GPIO_Init()` | `RCC_...ClockCmd()` + `GPIO_Init()` 你亲手写的 |
| 翻转引脚 | `HAL_GPIO_TogglePin()` | `GPIO_SetBits/ResetBits()` 直接映射 BSRR |
| 延时 | `HAL_Delay()` | 手写的 `for` 循环——简陋但透明 |

**关键差异**：HAL 版的 `MX_GPIO_Init()` 是 CubeMX 自动生成的，你不仔细看源文件根本不知道里面做了什么。SPL 版的四行时钟 + GPIO 配置是你亲手写的，**每一行你都知道它在做什么**。这就是 SPL 的核心理念——不隐匿任何硬件细节。

**⚠️ 嵌入式程序没有「结束」的概念。你的代码跑起来，就一直跑下去，直到断电。** `while(1)` 不是 bug，是 feature。

---

## 1.6 最小验收、常见误解与练习

**验收**：打开你自己的 `startup_stm32f10x_hd.s`，找到向量表和 `Reset_Handler`；再在 `main.c` 中标出第一次 GPIO 时钟使能的位置。能把它们连成“上电 → 启动代码 → SystemInit → main → while(1)”就是本章通过。

| 误解 | 正确理解 |
|---|---|
| MCU 也会自动运行 main | 复位后先执行启动文件，启动文件再调用系统初始化和 main |
| Flash 只是硬盘 | Flash 是 CPU 可直接取指的程序存储；SRAM 才承载运行期数据 |
| while(1) 是低级写法 | 裸机程序本来就需要持续运行；关键是循环内是否有阻塞和状态管理 |

练习：画出你第 0 章 blink 工程的文件关系图，并用一句话说明每个文件在上电后的作用。

### 用 GDB 验证启动路径

把“我以为程序跑到了 `main`”变成可检查的事实。烧录后启动 OpenOCD，再在另一个终端执行：

```gdb
arm-none-eabi-gdb build/blink.elf
(gdb) target remote :3333
(gdb) monitor reset halt
(gdb) break Reset_Handler
(gdb) break main
(gdb) continue
```

先命中 `Reset_Handler`、再命中 `main`，才说明向量表、链接脚本和基本启动链路一致。若第一个断点都不命中，先回第 0 章检查 HD 启动文件、`FLASH` 起始地址和 OpenOCD 连接；不要先怀疑 GPIO。

## 1.7 本章要点

- PC 上有 JVM → OS → 驱动 → 硬件；嵌入式只有你的 C 代码 → 寄存器 → 硬件
- MCU 上电 → 取中断向量表第一条（栈顶）→ 取第二条（Reset_Handler）→ `SystemInit()` → `main()` → `while(1)` 永远循环
- STM32F103ZET6 的 Flash（512KB）= 你程序的「永久存储」；SRAM（64KB）= 全局变量 + 堆 + 栈
- SPL 版 `main.c` 的每一行都是你手动写的配置代码，没有 CubeMX 生成的「黑箱」
- 使用任何外设前必须先使能对应时钟——这是 STM32 的铁律，忘记就是硬件不响应
- SPL 的 `GPIO_SetBits/ResetBits` 通过 BSRR 寄存器实现原子操作——写 1 生效，写 0 无效，不用读-改-写

---

> **下一章**：[第 2 章 · STM32F103 硬件概览](./02-chapter.md)
>
> 你知道了 MCU 怎么跑程序。接下来我们打开芯片的「内部地图」——存储器映射、总线矩阵、时钟树。这些概念决定了后面你写的每一行代码。

---

> **上一章**：[第 0 章 · 开发环境搭建（SPL版）](./00-chapter.md)

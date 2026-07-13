# 第 28 章 · 调试与排错：从现象定位到代码（SPL版）

> **本章产出**：能用 OpenOCD 和 GDB 连接开发板、设置断点、查看寄存器，并用 addr2line 定位 HardFault 的程序位置。
>
> **前置知识**：第 0 章工具链，以及至少一个能编译的 SPL 工程。
>
> **用在哪**：后续所有项目。调试不是最后一步，而是开发过程的一部分。

---

## 28.1 先让编译器帮你发现问题

在 Makefile 中启用警告，并把警告当作待处理问题：

~~~makefile
CFLAGS += -Wall -Wextra -Wshadow -Wundef
CFLAGS += -g3 -O0
~~~

学习阶段使用 O0 有利于观察源码与汇编的对应。项目稳定后，再针对关键模块测试 O1/O2；不要在没有测试的情况下只为了“看起来专业”而开启优化。

## 28.2 两个终端：OpenOCD 与 GDB

终端一连接调试器：

~~~bash
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg
~~~

终端二连接 ELF：

~~~bash
arm-none-eabi-gdb build/app.elf
(gdb) target remote :3333
(gdb) monitor reset halt
(gdb) load
(gdb) break main
(gdb) continue
~~~

若目标文件名不同，以 Makefile 实际输出为准。GDB 调试的是 ELF，不是 bin；ELF 保留了符号和调试信息。

## 28.3 最常用的五个命令

| 命令 | 作用 |
|---|---|
| break main | 在 main 设置断点 |
| next | 单步执行，不进入函数 |
| step | 单步执行，进入函数 |
| print variable | 查看变量 |
| info registers | 查看 CPU 寄存器 |
| x/16xw address | 查看一段内存或外设寄存器 |

例如 STM32F1 的 GPIOC 寄存器区域可以这样查看：

~~~text
(gdb) x/4xw 0x40011000
~~~

寄存器地址不要靠记忆猜，优先对照参考手册和 stm32f10x.h。

## 28.4 串口日志不是 printf 越多越好

建议定义级别：

~~~text
ERROR：无法继续，需要人工关注
WARN ：本次失败，但程序会恢复
INFO ：关键状态变化
DEBUG：定位问题时临时开启
~~~

在中断中不要直接 printf；它慢、可能重入、还可能改变你正在观察的时序。ISR 只记录一个标志、计数器或向队列发送轻量事件。

## 28.5 HardFault 的标准排查顺序

1. 暂停程序，记录 PC、LR、SP；
2. 从异常堆栈中找出发生异常时的 PC；
3. 用 addr2line 映射回源文件；
4. 检查数组越界、空指针、栈溢出、错误中断优先级；
5. 修复后设计一个能复现该错误的测试。

~~~bash
arm-none-eabi-addr2line -e build/app.elf -f -C 0x08000234
~~~

如果地址落在库函数或启动代码，不代表库一定有问题；先检查是谁传入了非法参数或破坏了栈。

## 28.6 看三个“健康指标”

| 指标 | 含义 |
|---|---|
| FreeRTOS 栈高水位 | 任务是否接近栈溢出 |
| 环形缓冲区溢出数 | UART 接收是否来不及处理 |
| 断线/重连次数 | 网络是否稳定 |

把这些指标放进一个周期性诊断页面，比只看 LED 更接近工程调试。

## 28.7 常见现象对照

| 现象 | 优先检查 |
|---|---|
| make 失败 | 工具链路径、宏、头文件与源文件是否匹配 |
| 能烧录但不运行 | 时钟、启动文件、链接脚本、复位脚 |
| 串口乱码 | 波特率、时钟、共地、TX/RX 是否交叉 |
| UART 偶发丢包 | NVIC、环形缓冲区、任务优先级、ISR 时间 |
| I2C 卡死 | 上拉电阻、ACK 超时、总线恢复 |
| 进入 HardFault | 栈、指针、数组边界、ISR 优先级 |

## 28.8 先硬件、后软件的五分钟排错树

当板子“完全没反应”时，按这个顺序排查：

~~~text
供电正常？
  → ST-Link 能识别？
    → SWD 能 halt？
      → 程序是否进入 main？
        → 时钟正确？
          → UART 日志正确？
            → 最后才看协议和业务逻辑
~~~

每一步都应有一个可观察证据：万用表读数、OpenOCD 输出、GDB 断点、串口日志或逻辑分析仪波形。这样不会因为猜测而同时改十处代码。

## 28.9 本章练习

1. 在第 25 章项目的传感器任务设置断点，查看一次 EnvSample；
2. 故意将数组下标越界，在 GDB 中练习定位；
3. 让 UART 缓冲区故意变小，观察 overflow 计数；
4. 把一个难复现的问题写成“现象—假设—验证—结论”的调试记录。

## 28.10 一次可重复的 OpenOCD + GDB 调试会话

不要只记住“开两个终端”。把每次调试写成可复制的命令和证据：

~~~bash
# 终端 A：按你的 ST-Link 和板卡连接方式调整配置文件
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg

# 终端 B：必须加载带调试符号的 ELF，而不是 .bin
arm-none-eabi-gdb build/app.elf
~~~

~~~gdb
target extended-remote :3333
monitor reset halt
break main
continue
info threads
backtrace
print SystemCoreClock
x/16wx 0x20000000
~~~

真正的项目应把这些命令写进 `docs/debug.md` 或 Makefile 目标，并记录 OpenOCD、工具链和板卡版本。GDB 无法从裸 `.bin` 恢复函数名，因此调试构建必须保留 `.elf` 和 map 文件。

### HardFault 的第一份证据

HardFault 后不要先重启。暂停在异常处，收集：

1. 当前 PC/LR、`backtrace` 和出错函数；
2. 相关任务的栈高水位与 heap；
3. 最近一条 UART 结构化日志；
4. 是否刚发生 ISR、DMA、队列或指针生命周期切换；
5. 对应地址的 `addr2line -e build/app.elf <address>` 结果。

若栈已经损坏，回溯可能不完整；这正是为什么第 15–16 章要求提前启用栈检查和错误计数。

### 调试练习

1. 在 SensorTask 入口、Queue 发送后、消费者入口各设一个断点，画出真实执行顺序；
2. 故意让一个缓冲区长度过小，在调试副本中练习用 PC/地址定位；
3. 把 UART 日志改为 `[tick][module][level][code]` 格式，避免只输出“error”。

## 28.11 本章要点

- 可调试的工程必须保留 ELF、符号和可读日志；
- OpenOCD 连接硬件，GDB 连接程序，两者缺一不可；
- HardFault 要从 PC 和栈帧回到具体代码；
- ISR 少做事，日志要分级；
- 健康指标能把“偶发故障”变成可量化问题。

---

[上一章：第 27 章 · 多协议智能网关](./27-chapter.md)

[下一章：第 29 章 · 低功耗设计](./29-chapter.md)

# 第 28 章 · 调试与排错：从现象定位到代码（SPL 版）

这一章把调试过程固定成一条可重复的证据链：先复现现象，再确认硬件和软件边界，用 GDB、寄存器、日志或波形缩小范围，最后把复现条件留成回归测试。工具的作用是取得证据，避免一次改很多地方以后不知道哪一处真正解决了问题。

## 28.1 调试构建保留符号和警告

Makefile 可以先启用：

```makefile
CFLAGS += -Wall -Wextra -Wshadow -Wundef
CFLAGS += -g3 -Og
```

`-Og` 适合日常源码级调试，但优化后仍可能出现变量被优化掉、单步顺序与源码行不完全一致。需要观察最直接的源码/汇编对应关系时可以临时使用 `-O0 -g3`；发布配置则按项目性能和测试结果选择优化级别。

每个可追踪构建至少保留 `.elf` 和 map 文件，并能对应到源码 commit 与编译参数。现场只有一个 PC 地址却找不到当时的 ELF，`addr2line` 也无法还原正确源码位置。

## 28.2 OpenOCD 和 GDB 分工

一个常见的 ST-Link + STM32F1 调试会话：

```bash
# 终端 A
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg

# 终端 B
arm-none-eabi-gdb build/app.elf
```

进入 GDB 后：

```gdb
target extended-remote :3333
monitor reset halt
load
break main
continue
```

OpenOCD 配置文件要与实际调试器、SWD 接线和复位电路匹配。连接失败时先检查目标供电、GND、SWDIO、SWCLK、NRST 和接口驱动，再判断是否需要修改 OpenOCD 配置。

GDB 加载 ELF，因为 ELF 保存符号和调试信息；`.bin` 只有待烧录的原始数据，不能单独提供函数名、源码行和变量信息。

## 28.3 常用 GDB 操作

本章主要使用这些命令：

```gdb
break main
next
step
continue
backtrace
print variable
info registers
x/16wx 0x20000000
```

查看外设寄存器时，从参考手册或 `stm32f10x.h` 确认地址。例如 GPIOC 基地址为 `0x40011000` 时，可以读取：

```gdb
x/4wx 0x40011000
```

断点会改变实时系统的执行时序。调 UART、I2C、PWM 或外部设备握手时，如果一停住故障就消失，应改用计数器、GPIO 打点、逻辑分析仪或内存快照观察，而不是继续增加断点。

## 28.4 日志记录状态变化和错误码

日志可以分为 ERROR、WARN、INFO、DEBUG 四级。输出内容至少带时间基准、模块和错误码：

```text
[128340][i2c][WARN][TIMEOUT] bus=1 addr=0x3C
[128351][mqtt][INFO][STATE] old=TCP_CONNECT new=MQTT_CONNECT
```

ISR 中不直接 `printf()`。格式化输出可能耗时、访问非重入库函数或等待串口，都会扩大中断延迟。ISR 只更新计数、保存少量现场或通知任务，由任务完成日志格式化。

多任务共享 `printf()` 还可能产生字符交错和 libc 重入问题。综合项目最好由一个日志任务或明确同步的输出通路独占调试 UART。

## 28.5 先确认故障在哪一层

板子完全没反应时按可观察证据逐层检查：

```text
电源轨和复位脚
    ↓
ST-Link / SWD 能否识别目标
    ↓
GDB 能否 halt，PC 是否合理
    ↓
复位后能否到 main
    ↓
系统时钟和外设时钟
    ↓
UART / I2C / SPI 等驱动
    ↓
Parser / RTOS / 网络 / 业务逻辑
```

电源层用万用表或示波器，SWD 用 OpenOCD/GDB，串行总线用逻辑分析仪，软件状态用断点、寄存器和结构化日志。在哪一层第一次出现与预期不符的证据，就先停在那里继续缩小范围。

例如串口乱码先核对实际 PCLK、USART BRR、波特率、共地和 TX/RX；不要先改上层字符串 Parser。I2C 超时先看 SCL/SDA 电平、ACK 和驱动 timeout，再判断 OLED 业务代码。

## 28.6 断言只检查程序不变量

调试构建可以把“不应发生”的状态停下来：

```c
void App_AssertFailed(const char *expr, const char *file, int line)
{
    Debug_RecordAssert(expr, file, line);
    __BKPT(0);

    for (;;) {
    }
}

#define APP_ASSERT(x) \
    do { \
        if (!(x)) \
            App_AssertFailed(#x, __FILE__, __LINE__); \
    } while (0)
```

适合断言的条件包括 Queue 句柄创建成功、数组索引小于容量、状态机内部枚举有效。I2C 超时、WiFi 断线、SD 卡拔出属于运行期可能发生的故障，应返回错误并由状态机处理。

`__BKPT(0)` 在连接调试器时便于停在现场，但量产固件的断言策略要单独设计。无人调试时如何复位、记录故障或进入安全状态取决于产品要求。

## 28.7 HardFault 先保存异常现场

Cortex-M3 进入异常时，硬件会把 `r0-r3`、`r12`、LR、PC 和 xPSR 压入当前使用的异常栈帧。HardFault handler 可以根据 EXC_RETURN 判断异常前使用 MSP 还是 PSP，并把现场复制到静态对象：

```c
typedef struct {
    uint32_t r0, r1, r2, r3, r12, lr, pc, xpsr;
    uint32_t cfsr, hfsr, mmfar, bfar;
} FaultSnapshot;

static volatile FaultSnapshot g_fault;

void HardFault_C(uint32_t *stack)
{
    g_fault.r0    = stack[0];
    g_fault.r1    = stack[1];
    g_fault.r2    = stack[2];
    g_fault.r3    = stack[3];
    g_fault.r12   = stack[4];
    g_fault.lr    = stack[5];
    g_fault.pc    = stack[6];
    g_fault.xpsr  = stack[7];
    g_fault.cfsr  = SCB->CFSR;
    g_fault.hfsr  = SCB->HFSR;
    g_fault.mmfar = SCB->MMFAR;
    g_fault.bfar  = SCB->BFAR;

    for (;;) {
    }
}

__attribute__((naked)) void HardFault_Handler(void)
{
    __asm volatile(
        "tst lr, #4\n"
        "ite eq\n"
        "mrseq r0, msp\n"
        "mrsne r0, psp\n"
        "b HardFault_C\n");
}
```

这段代码针对 GCC 和 Cortex-M3。工程的启动文件必须只提供一个最终生效的 `HardFault_Handler`；如果启动文件已有弱定义，确认链接结果确实使用这里的实现。

Fault handler 内不依赖 `printf()`、动态内存或 RTOS Queue，因为这些组件可能正是故障来源。连接 GDB 后直接读取 `g_fault`。

## 28.8 PC 地址配合 Fault 状态寄存器定位

先取异常现场：

```gdb
print/x g_fault.pc
print/x g_fault.lr
print/x g_fault.cfsr
print/x g_fault.hfsr
print/x g_fault.mmfar
print/x g_fault.bfar
```

再把异常 PC 映射到源码：

```bash
arm-none-eabi-addr2line -e build/app.elf -f -C 0x08000234
```

`0x08000234` 只是示例，要换成现场保存的 PC。若 PC 落在 `memcpy()`、队列函数或库代码中，继续检查调用者传入的指针、长度和栈是否已经损坏。

CFSR 由 MemManage、BusFault 和 UsageFault 状态位组成。只有相应 valid 位有效时，MMFAR/BFAR 地址才有意义；不要看到一个残留地址就直接判断它是故障访问地址。具体位含义以 Cortex-M3 SCB 文档为准。

## 28.9 FreeRTOS 还要看任务现场

启用项目所需的栈溢出检测和 malloc failed hook，并周期记录任务 high-water mark、heap 余量和 Queue 最大占用。`uxTaskGetStackHighWaterMark()` 返回的是该任务历史最小剩余栈空间，单位与 FreeRTOS 端口的栈元素定义相关，不应直接写成“剩余字节数”。

HardFault 如果发生在任务上下文，还要结合当前任务、最近的 Queue/Mutex 操作和栈水位。栈已经被破坏时，GDB `backtrace` 可能错误或不完整，因此运行期指标比 Fault 后才开始猜栈大小更有价值。

遇到“加 printf 就好了”或“加 delay 就好了”的问题，优先怀疑竞争、未初始化数据、生命周期、栈/内存越界和外设时序。这类改动会改变调度与时序，只能作为线索。

## 28.10 外设问题用波形确认

软件寄存器状态只能说明 MCU 认为自己做了什么。I2C、SPI、UART、PWM 和 RS485 的线路问题要看实际信号。

UART 检查真实 bit 时间、空闲电平和错误计数；I2C 检查 START、地址、ACK/NACK、SCL/SDA 是否被拉低；SPI 检查 CS、时钟极性/相位和数据边沿；PWM 检查周期、占空比以及负载动作时供电是否明显跌落。

逻辑分析仪适合数字时序和协议解码，示波器适合电压幅度、边沿、纹波和电源瞬态。协议解码显示正确也不能证明电源质量正常。

## 28.11 健康指标按层记录

综合项目至少保留这些类型的计数：

- UART：RX 字节、ORE/FE/NE、RingBuffer overflow；
- Parser：合法帧、长度错误、CRC 错误、超时；
- RTOS：Queue drop/最大占用、任务栈 high-water、heap；
- 存储：写失败、重新挂载、同步失败；
- 网络：连接失败、重连、协议错误、publish failure；
- 业务：传感器 timeout、命令 rejected/timeout、执行器 fault。

这些指标不要合并成一个 `error_count`。例如 UART overflow 之后出现 CRC error，先解决接收丢字节；否则会把下游 CRC 失败误判成 CRC 算法错误。

观察累计计数时同时记录时间区间。`reconnect=20` 单独没有足够信息，20 次发生在十分钟还是一个月代表的情况不同。

## 28.12 调试记录要能复现

每次解决实际问题时保存：

```text
现象：
最小复现步骤：
硬件版本：
固件 commit：
工具链/OpenOCD 版本：
构建参数：
观察证据：日志 / 波形 / GDB / 寄存器
根因：
修复：
回归测试：
```

例如第 24 章 Parser 的长度错误和 CRC 错误应该分别构造固定输入。修复以后把输入留进测试集；以后 Parser 改动时重新回放，确认错误分类和重同步行为没有退化。

对于偶发问题，还要记录故障前后的计数增量和最后状态迁移。只留下“重启后正常”无法用于下一次定位。

## 28.13 本章完成标准

完成本章练习时，应能做到：

- 用当前工程的 OpenOCD 配置连接目标并在 `main` 停住；
- 保留与固件版本对应的 ELF 和 map；
- 用 GDB 查看变量、寄存器、内存和调用栈；
- HardFault 后读取异常 PC、LR、CFSR，并用 `addr2line` 回到源码；
- 区分断言和可恢复运行期错误；
- 用逻辑分析仪或示波器确认至少一种外设问题；
- 从 UART、Parser、RTOS、存储和网络的分层计数判断故障先出现在哪里；
- 把一次真实故障留下最小复现和回归测试。

下一章进入低功耗设计，会继续使用这些调试方法检查时钟、唤醒源和睡眠电流。

> **上一章**：[第 27 章 · 多协议智能网关](./27-chapter.md)
>
> **下一章**：[第 29 章 · 低功耗设计](./29-chapter.md)

# 第 14 章 · 为什么需要 RTOS（SPL 版）

前 13 章都可以用裸机主循环组织。本章开始加入 FreeRTOS，先解决一个具体问题：程序里同时存在周期任务、事件处理和可能阻塞的外设操作时，怎样明确每项工作的运行时机和阻塞边界。

本章还会拆开 Cortex-M3 的 SysTick、PendSV、PSP 和上下文切换。迷你调度器只用于理解机制；从第 15 章开始，工程使用 FreeRTOS。

## 14.1 裸机主循环什么时候开始难维护

裸机本身可以处理相当复杂的程序。只要每个模块都采用非阻塞状态机，主循环同样能稳定完成多个周期和事件任务。问题通常出现在某个调用长时间不返回，或者所有模块的时间状态都堆进同一个循环之后。

例如：

```c
for (;;) {
    Console_Poll();
    Sensor_Poll();

    if (Log_IsDue())
        Log_WriteToSd();

    Display_Poll();
}
```

如果 `Log_WriteToSd()` 因 SD 卡访问等待 200 ms，这 200 ms 内 `Console_Poll()` 和 `Display_Poll()` 都不会再次执行。可以继续把 SD 写入改造成状态机，但随着 WiFi、文件系统、传感器和 UI 同时加入，每个模块都要自行维护等待状态、超时和调度条件。

RTOS 提供任务状态和调度器，让等待中的工作离开就绪队列，CPU 去运行其他可执行任务。它不会让一个长时间占用 CPU、从不阻塞的高优先级函数自动变得友好；任务设计仍然要明确阻塞点。

## 14.2 任务和阻塞

FreeRTOS 任务通常是一个长期运行的函数：

```c
static void SensorTask(void *argument)
{
    (void)argument;

    for (;;) {
        Sensor_ReadAndPublish();
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}
```

`vTaskDelay()` 会把当前任务放入 Blocked 状态。延时期间它不占用 CPU；到期后重新进入 Ready 状态，再由调度器根据优先级决定何时运行。

一个简单系统可以拆成：

```text
SensorTask   周期采样并发布数据
DisplayTask  等待新数据后刷新显示
LoggerTask   等待日志消息并写 SD
ConsoleTask  等待串口输入并执行命令
ISR          捕获硬件事件并通知相应任务
```

这些任务并不会在单核 Cortex-M3 上同时执行。任一时刻只有一个任务占用 CPU；调度器在任务阻塞、时间片到期、高优先级任务变为 Ready 等时机选择下一项工作。

抢占也不能消除驱动内部的全局影响。例如某个任务长时间关中断，其他任务和 ISR 都会受到影响；两个任务同时访问同一个 I2C 外设，也仍需要互斥或统一的设备服务。

## 14.3 Cortex-M3 怎样切换任务

Cortex-M3 为 RTOS 提供了适合上下文切换的异常机制。典型 FreeRTOS Cortex-M3 port 会用 SysTick 提供 tick，用 PendSV 执行上下文切换，用 SVC 启动第一个任务。

任务在线程模式运行时通常使用 PSP。异常进入时，处理器硬件自动保存：

```text
r0-r3, r12, LR, PC, xPSR
```

`r4-r11` 属于被调用者保存寄存器，需要上下文切换代码另外保存。一次简化的切换过程可以表示为：

```text
SysTick 到期或其他事件要求重新调度
        ↓
PendSV 置为 pending
        ↓
进入 PendSV
        ↓
保存当前任务 r4-r11 和 PSP
        ↓
调度器选择下一个 Ready 任务
        ↓
装载该任务 PSP，恢复 r4-r11
        ↓
异常返回，硬件恢复其余寄存器
```

PendSV 通常配置为很低的异常优先级，使真正的外设 ISR 先完成，再进行任务上下文切换。具体优先级和向量映射由 FreeRTOS port 与 `FreeRTOSConfig.h` 配置，不应在应用代码里另写一套。

## 14.4 一个只用于理解的切换片段

下面只展示 PendSV 中最关键的保存/恢复动作，不构成可运行调度器：

```asm
MRS     r0, PSP
STMDB   r0!, {r4-r11}

; 把 r0 保存到当前任务的 TCB
; 调度器选择下一个任务
; 从新任务 TCB 取出 PSP 到 r0

LDMIA   r0!, {r4-r11}
MSR     PSP, r0
BX      LR
```

TCB 至少要保存任务当前栈指针。任务第一次运行之前，还要在它自己的栈上准备与 Cortex-M3 异常返回格式匹配的初始栈帧。这里涉及 EXC_RETURN、8 字节栈对齐、编译器 ABI、临界区和首次任务启动等细节。

这也是本章不提供“50 行可运行 RTOS”的原因。一个看似能切换两个测试函数的汇编片段，不等于能安全处理嵌套中断、优化编译、任务退出、栈溢出和不同工具链。第 15 章直接使用 FreeRTOS 官方 Cortex-M3 port。

## 14.5 `Delay_ms()` 和 `vTaskDelay()` 的差别

裸机忙等延时可能写成：

```c
void Delay_ms(uint32_t ms)
{
    uint32_t start = Timebase_NowMs();

    while ((uint32_t)(Timebase_NowMs() - start) < ms) {
    }
}
```

放进 FreeRTOS 任务后，SysTick 和抢占调度通常仍然可以发生；忙等并不会天然禁止任务切换。它的问题是当前任务始终保持 Ready，并持续消耗自己获得的 CPU 时间。如果它又是最高优先级的 Ready 任务，低优先级任务可能长期得不到运行机会。

`vTaskDelay()` 会让任务进入 Blocked：

```c
for (;;) {
    BoardLed_Toggle();
    vTaskDelay(pdMS_TO_TICKS(500));
}
```

这 500 ms 内调度器可以运行其他 Ready 任务。周期任务如果希望减少自身执行时间造成的周期漂移，还可以使用 `vTaskDelayUntil()`，让下一次唤醒时间基于固定周期推进。

FreeRTOS 接管 SysTick 后，前面章节自建的 SysTick 时间基准不能继续以冲突的中断实现同时存在。需要毫秒时间时，可以使用 RTOS tick，或者使用独立硬件定时器提供不与内核 SysTick 冲突的时间源。

## 14.6 优先级解决的是调度顺序

FreeRTOS 总是优先运行最高优先级的 Ready 任务。高优先级任务如果从不阻塞，低优先级任务可能被饿死：

```c
static void BadHighPriorityTask(void *argument)
{
    (void)argument;

    for (;;) {
        ComputeForever();
    }
}
```

周期采样、控制回路、网络处理和日志写入不应仅凭“感觉重要”分配优先级。先确定响应时间和阻塞条件，再决定谁需要抢占谁。日志写 SD 往往可以等几毫秒，硬件控制事件可能有更短的响应边界。

任务优先级也不能替代 ISR 优先级。调用 FreeRTOS `...FromISR()` API 的中断必须满足该 port 对 NVIC 优先级的限制；第 15 章配置 `configMAX_SYSCALL_INTERRUPT_PRIORITY` 时会具体处理。

## 14.7 任务之间怎样交数据

进入 RTOS 后，不要因为有多个任务就把更多状态放进全局变量。先确定数据所有权和交接方式。

例如传感器产生一份完整样本：

```c
typedef struct {
    uint32_t seq;
    int16_t temperature_centi;
    uint16_t voltage_mv;
} EnvSample;

static QueueHandle_t sample_queue;
```

`SensorTask` 可以把 `EnvSample` 的副本发送到 Queue；消费者收到的是一份完整消息，不依赖生产者的局部变量生命周期。对于“只需要唤醒某个任务”的 ISR，Task Notification 通常比创建一个消息结构更直接。共享 I2C/SPI 设备则可以使用 Mutex，或者把所有访问集中到一个设备任务。

选择同步原语时先看数据关系：

- 需要传递一条条数据：Queue。
- 只需要计数或唤醒任务：Task Notification / Semaphore。
- 多个任务共享同一资源：Mutex。
- ISR 向任务交事件：使用对应的 `...FromISR()` API，并根据返回值决定是否请求切换到刚唤醒的高优先级任务。

这些机制的具体 API 放到第 15、16 章。本章只先建立“谁产生、谁消费、能否丢、能阻塞多久”这几个边界。

## 14.8 从裸机模块拆任务

以一个同时采样、显示、记录和响应按键的节点为例，可以先写出运行条件：

| 工作 | 触发条件 | 允许阻塞 | 数据交接 |
|---|---|---|---|
| 传感器采样 | 每 100 ms | 短时间等待外设 | Queue 发布完整样本 |
| OLED 刷新 | 收到新样本或每 250 ms | I2C 事务有超时 | 消费样本副本 |
| SD 日志 | 收到日志消息 | SD 操作可能较慢 | 独占文件系统/块设备 |
| UART RX | 字节/IDLE 中断 | ISR 不阻塞 | DMA/环形缓冲后通知任务 |
| 按键 | EXTI 边沿 | ISR 不阻塞 | 通知 ButtonTask |

这张表先回答运行时问题，再决定要创建几个任务。两个工作如果访问同一个设备、周期相近且没有独立响应要求，也可以放在同一任务中；RTOS 不要求每个模块都创建一个 Task。

还要给每个任务分配栈。栈大小不能按固定的“每个任务几百字节”猜测，应根据调用深度、局部数组、库函数和实际高水位测量调整。`printf`、文件系统和较大的局部缓冲通常会明显增加栈需求。

## 14.9 最小 FreeRTOS 验收

第 15 章完成移植后，先用两个简单任务验收调度器：

```c
static void LedTask(void *argument)
{
    (void)argument;

    for (;;) {
        BoardLed_Toggle();
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

static void LogTask(void *argument)
{
    (void)argument;

    for (;;) {
        Console_PrintTick();
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
```

连续运行一段时间后检查两项任务都在执行，再读取各任务的栈高水位。随后故意让一个高优先级任务不再阻塞，观察低优先级任务停止运行；恢复阻塞点后再次验证。

如果启动调度器后没有日志，先检查 Cortex-M3 port、SysTick/PendSV/SVC 向量和系统时钟。任务运行一次就消失时，检查任务函数是否错误 `return`、参数生命周期和栈。出现 HardFault 时，优先检查栈溢出、越界访问、ISR API 与 NVIC 优先级配置。

## 14.10 本章边界

本章只解释为什么项目开始使用 RTOS，以及 Cortex-M3 怎样完成任务切换。以下内容留给后续章节：

- FreeRTOS 源码、port 和 `FreeRTOSConfig.h` 的实际接入；
- Heap 实现与动态/静态任务创建；
- Queue、Semaphore、Mutex、Task Notification；
- ISR 可调用 API 与 NVIC 优先级限制；
- 栈溢出、断言和运行时统计。

进入第 15 章前，先确认工程里不会同时存在两套 SysTick、PendSV 或 SVC 实现。前面章节的裸机时基如果占用了 SysTick，也要先决定迁移到 RTOS tick 还是独立定时器。

> **上一章**：[第 13 章 · 存储语义：NOR 与 FatFs](./13-chapter.md)
>
> **下一章**：[第 15 章 · FreeRTOS 核心 API 与手动移植](./15-chapter.md)

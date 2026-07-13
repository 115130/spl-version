# 第 14 章 · 为什么需要 RTOS（SPL版）

> **本章产出**：能从一个阻塞的裸机循环拆出任务、事件和时间边界；理解调度器到底替你保存了什么、没有替你解决什么。
>
> **前置知识**：第 5 章 SysTick、第 6 章中断，以及至少一个能通过 UART 输出日志的 SPL 工程。
>
> **本章边界**：迷你调度器只用于理解 Cortex-M3 上下文切换；后续项目使用经过长期维护的 FreeRTOS。

## 14.1 裸机 while(1) 的局限

前 13 章你写的程序都是这种结构：

```c
int main(void) {
    // 初始化全部外设
    LED_Init();
    USART1_Init();
    ADC1_Init();

    while (1) {
        LED_Toggle();              // 每 500ms 闪灯
        uint16_t adc = ADC1_Read(); // 读 ADC
        printf("ADC=%d\r\n", adc);
        Delay_ms(100);
    }
}
```

这个 `while(1)` 大循环在项目简单时够用。但随着你加入越来越多的功能，问题开始暴露：

### 场景 1：一件事阻塞了所有事

假设你加了一个「每 30 秒写一次 SD 卡日志」的功能：

```c
while (1) {
    LED_Toggle();          // ① 闪灯
    ProcessUART();         // ② 处理串口命令
    if (uwTick % 30000 == 0) {
        WriteSD_Log();     // ③ 写 SD 卡——耗时 200ms！
    }
}
```

**问题**：`WriteSD_Log()` 执行的那 200ms 里，LED 不闪了（卡在灭或亮的状态），串口来了命令也不处理了。因为裸机是**顺序执行**——一个函数不返回，后面的代码永远轮不到。

### 场景 2：定时任务不准

用 `uwTick % 500 == 0` 来做 LED 定时翻转——但如果某次循环因为等 ADC、等 UART 耗时超过了 500ms，LED 的翻转时机就会乱掉。所有「定时」在裸机里都是**近似值**，取决于大循环里最慢的那个函数。

### 场景 3：代码越改越乱

当你有「收到串口 AT 命令 → 读温度 → 显示到 OLED → 同时 LED 呼吸指示模式」，你会写成：

```c
while (1) {
    if (UART_DataReady()) {
        ParseCMD();         // 解析命令
        switch (mode) {
            case SHOW_TEMP: ReadTemp(); break;
            case SHOW_OLED: OLED_Update(); break;
        }
    }
    LED_Breath();            // 呼吸灯
    OLED_Update();           // 刷新显示
    CheckKey();              // 检测按键
    // 这里顺序和优先级不可控……
}
```

所有逻辑混在一起。想加一个新功能就要改这个大循环，怕改崩旧功能。**项目的复杂度从「能不能跑」变成「能不能维护」了。**

### 你前 13 章做过的项目，哪些会碰到这些问题？

| 项目 | 裸机能搞定吗 | 为什么 |
|------|------------|--------|
| 第 3 章：按键点灯 | ✅ 简单 | 就一件事 |
| 第 8 章：UART 指令控制台 | ⚠️ 勉强 | 加个定时器读传感器就开始乱了 |
| 第 8 章实验②：WiFi 发数据 | ❌ 痛苦 | 配网 10 秒 → 发数据 500ms，期间按键、LED 全挂 |
| 第 10 章：I2C 读 MPU6050 + OLED 显示 | ❌ 混乱 | 要同时读传感器、刷新显示、处理命令 |
| 物联网网关（后面 21-24 章）| ❌ 不可能 | 同时跑 WiFi、MQTT、传感器、OLED、按键 |

## 14.2 RTOS 的解法：从一个大循环拆成多个小循环

RTOS（Real-Time Operating System，实时操作系统）做的事很简单：**让你把程序拆成多个独立的死循环（称为 Task/任务），每个任务只关心自己那一件事。内核帮你决定哪个任务占用 CPU、什么时候切换。**

裸机的思维：

```c
while (1) {
    做A();
    做B();
    做C();
}
```

RTOS 的思维：

```c
void TaskA(void *pv) { while (1) { 做A(); } }   // 独立
void TaskB(void *pv) { while (1) { 做B(); } }   // 独立
void TaskC(void *pv) { while (1) { 做C(); } }   // 独立
```

### 具体对比：第 8 章 WiFi 实验的裸机 vs RTOS

**裸机版**（你第 8 章写的）：

```c
int main(void) {
    USART1_Init(); USART2_Init();
    WiFi_AT_Setup();                     // 配网——耗时长
    while (1) {
        temp = ReadTemp();
        WiFi_SendData(temp);              // 发数据——阻塞
        Delay_ms(5000);
        // 这时候按键不响应、LED 不闪
    }
}
```

**RTOS 版**：

```c
void TaskWiFi(void *pv) {                // 任务 A：只管 WiFi
    WiFi_AT_Setup();
    while (1) {
        WiFi_SendData(ReadTemp());
        vTaskDelay(5000);
    }
}

void TaskLED(void *pv) {                 // 任务 B：只管闪灯
    while (1) {
        LED_Toggle();
        vTaskDelay(500);
    }
}

void TaskKey(void *pv) {                 // 任务 C：只管按键
    while (1) {
        if (Key_Pressed()) mode++;
        vTaskDelay(20);
    }
}

int main(void) {
    xTaskCreate(TaskWiFi, "WiFi", ...);
    xTaskCreate(TaskLED,  "LED",  ...);
    xTaskCreate(TaskKey,  "Key",  ...);
    vTaskStartScheduler();               // 启动！三个任务「同时」跑
    while (1);                           // 永不执行到这里
}
```

三个任务各跑各的。当 TaskWiFi 在 `vTaskDelay(5000)` 睡眠时，CPU 自动去跑 TaskLED 和 TaskKey。当 TaskWiFi 的 `WiFi_SendData()` 在执行时，它也在跑——但 500ms 后 TaskLED 的时间到了，**内核会强行打断** WiFi 任务，让 LED 先翻转，再回来继续发 WiFi。这就是**抢占式调度**。

### RTOS 解决的核心问题总结

| 裸机问题 | RTOS 的解法 |
|---------|------------|
| 一个函数阻塞，全系统卡住 | **多任务**：一个任务阻塞，其他任务继续运行 |
| 定时不精确 | **调度器**：内核强制切换，高优先级任务准时执行 |
| 代码难以维护 | **职责分离**：每个 task 只干一件事，改一个不影响其他 |
| 新功能难加 | **即插即用**：新建一个 task 文件，跟已有 task 零耦合 |

### 什么时候用 RTOS，什么时候不用

| 适合裸机 | 适合 RTOS |
|---------|----------|
| 只有一个独立功能 | 多个任务需要「同时」运行 |
| 逻辑简单（读按键→亮灯）| 涉及无线通信（WiFi/BLE 有长延迟）|
| 实时性要求不高 | 有严格的时序要求 |
| 代码 < 1000 行 | 代码 > 5000 行，多人协作 |

对于后面第 17-30 章（WiFi、MQTT、网关、三个综合项目），**没有 RTOS 几乎不可能组织代码**。这就是现在学 FreeRTOS 的原因。

---

## 14.3 自己动手：一个最简抢占式调度器（50 行）

FreeRTOS 几千行。但抢占式多任务的核心，只靠 **SysTick + PendSV + 任务控制块** 三个机制就能实现。Cortex-M3 为此提供了完美的硬件支持。

### 核心数据结构

每个任务只需要保存自己的栈指针：

```c
#define MAX_TASKS  4
struct TCB {
    uint32_t *sp;                  // 栈指针——任务切换时只需换这个
    uint32_t  stack[128];          // 每个任务 512 字节栈
};
struct TCB tasks[MAX_TASKS];
volatile int current_task = 0;
```

### SysTick——触发调度

```c
void SysTick_Handler(void) {
    // 设 PendSV 位——等当前 ISR 处理完再切换
    SCB->ICSR |= SCB_ICSR_PENDSVSET_Msk;
}
```

SysTick 只设一个标志位。PendSV 是 Cortex-M3 优先级最低的异常，它会等所有更高级的中断处理完才执行——**绝不会在另一个 ISR 中间切任务**。

### PendSV——真正的上下文切换

汇编写，约 20 行：

```asm
PendSV_Handler:
    MRS r0, PSP              ; 读当前任务的栈指针
    STMDB r0!, {r4-r11}      ; 保存 r4~r11 到栈上
                             ; r0~r3, r12, LR, PC, xPSR 已被硬件自动压栈
    ; 保存当前任务的 sp 到 TCB
    LDR r1, =current_task
    LDR r2, [r1]             ; current_task id
    LDR r3, =tasks
    MOV r4, #16              ; sizeof(struct TCB) = 16
    MLA r2, r2, r4, r3
    STR r0, [r2]             ; tasks[id].sp = current SP

    ; 选下一个任务（轮转）
    LDR r2, [r1]             ; 重新加载 current_task
    ADD r2, r2, #1
    CMP r2, #MAX_TASKS-1
    ITT GT
    MOVGT r2, #0
    STR r2, [r1]             ; current_task = (current_task+1) % MAX_TASKS

    ; 恢复新任务的寄存器
    MOV r4, #16
    MLA r2, r2, r4, r3
    LDR r0, [r2]             ; 新任务的 sp
    LDMIA r0!, {r4-r11}      ; 弹出 r4~r11
    MSR PSP, r0              ; 设 PSP 为新任务的栈
    BX LR                    ; 返回→硬件自动弹出 r0~r3, PC, xPSR→新任务跑起来了
```

**硬件帮了大忙**：进入 PendSV 时，CPU 自动把 r0-r3、r12、LR、PC、xPSR 压栈了；`BX LR` 返回时硬件自动弹出。你只需要手动保存/恢复 r4-r11。

### 创建任务

创建任务本质是**伪造一个栈帧**——看起来刚刚被中断过：

```c
void TaskCreate(void (*func)(void), int id) {
    uint32_t *sp = &tasks[id].stack[128];
    *--sp = 0x01000000;              // xPSR（Thumb 位 = 1，必须）
    *--sp = (uint32_t)func;           // PC = 任务入口地址
    *--sp = 0xFFFFFFFD;               // LR = 异常返回 magic 值（回到线程模式+PSP）
    *--sp = 0x0C; *--sp = 0x03;      // r12, r3, r2, r1, r0
    *--sp = 0x02; *--sp = 0x01;
    *--sp = 0x00;
    for (int i = 0; i < 8; i++) *--sp = 0;   // r4~r11
    tasks[id].sp = sp;
}
```

### 启动调度器

```c
void StartScheduler(void) {
    __set_PSP((uint32_t)tasks[0].sp);        // 设 PSP 指向任务 0 的栈
    SysTick_Config(SystemCoreClock / 1000);  // 1ms tick
    SCB->ICSR |= SCB_ICSR_PENDSVSET_Msk;     // 触发一次切换→跑任务 0
    __set_CONTROL(0x03);                     // 切换到线程模式+PSP
    __ISB();
    asm("SVC 0");                            // 触发 SVC→跳 PendSV→第一个任务开始
}
```

### 两个任务跑起来

```c
void Task1(void) {
    while (1) { GPIOC->ODR ^= GPIO_Pin_13;  /* LED toggle */  }
}
void Task2(void) {
    while (1) { /* 另一个任务 */ }
}

int main(void) {
    TaskCreate(Task1, 0);
    TaskCreate(Task2, 1);
    StartScheduler();
    while (1);   // 永不执行到这里
}
```

### 这个迷你 RTOS vs FreeRTOS

| 功能 | 迷你 RTOS | FreeRTOS |
|------|----------|----------|
| 抢占式调度 | ✅ 轮转 | ✅ 可配优先级 8~32 级 |
| vTaskDelay | ❌ 自己加链表 | ✅ |
| 信号量/队列 | ❌ | ✅ |
| 代码量 | **~50 行** | ~8000 行 |
| 工业级可靠性 | ❌ | ✅ 数亿设备验证 |

这证明了抢占式调度的本质就那么几行——SysTick 里设 PendSV 位，PendSV 里保存寄存器+换 SP。FreeRTOS 在这之上加了优先级、阻塞、同步、十年来的 bug 修复和几十种芯片的移植层。

---

## 14.4 FreeRTOS 内部：SysTick → PendSV 切换流程

上面的迷你 RTOS 帮你理解了核心机制。FreeRTOS 的上下文切换也是完全相同的原理：

```
SysTick_Handler（每 1ms）
    │
    └── 设置 PendSV 位（SCB->ICSR |= PENDSVSET）
        │
        └── 系统 PendSV 优先级最低，等所有中断处理完
            │
            └── PendSV_Handler 执行：
                1. 保存 r4~r11 到当前任务栈
                2. 调用 vTaskSwitchContext() 选下一个任务
                3. 恢复下一个任务的 r4~r11
                4. BX LR → 硬件弹出剩下的寄存器→新任务跑
```

唯一区别是第 2 步——FreeRTOS 用优先级就绪位图而不是简单的 `(current+1)%N` 来选下一个任务，O(1) 时间找到最高优先级的就绪任务。

### 为什么裸机的 Delay_ms 不能和 FreeRTOS 共存

你的 `Delay_ms` 是这样做的：

```c
void Delay_ms(uint32_t ms) {
    uint32_t start = uwTick;       // 读 SysTick 计数值
    while (uwTick - start < ms);   // 忙等
}
```

问题在执行 `while` 忙等时，**任务切换不会发生**——因为 PendSV 也是在 SysTick 中断里触发的，但 `Delay_ms` 的 while 循环不在中断里，SysTick 照常触发，PendSV 也照常执行。

真正的问题是：**`Delay_ms` 阻塞了当前任务的全部执行时间**。如果 Task1 调了 `Delay_ms(1000)`，这一秒里 Task1 占用 CPU——FreeRTOS 的调度器只在每个 SysTick 中断里切换，如果 Task1 不主动让出（`vTaskDelay` 或阻塞），且优先级最高，它就一直跑。

**`vTaskDelay` 和 `Delay_ms` 的区别**：

| | `Delay_ms(1000)` | `vTaskDelay(1000)` |
|--|-----------------|-------------------|
| 行为 | CPU 忙等 1 秒 | 任务进入 Blocked 状态，不占 CPU |
| 其他任务 | 不能运行 | ❓ 可以运行 |
| 调度器效果 | 无 | 任务被移出就绪队列，调度器选其他任务 |

RTOS 里的延时**不是忙等**——是把任务从就绪队列移到延时队列，然后调度其他任务。延时到后自动回到就绪队列。

### FreeRTOS 占用资源

| 资源 | 用量 |
|------|------|
| ROM（Flash） | ~5KB（内核源码）|
| RAM | 每个任务 ~200-500 字节栈 + 内核堆 ~1-10KB |
| CPU | 每 1ms 进入 SysTick ~1µs，约 0.1% 开销 |

STM32F103 ZET6（512KB Flash / 64KB RAM）跑 FreeRTOS 绰绰有余。

---

## 14.5 SPL 版和 HAL 版的不同

HAL 版用 CubeMX 勾选「FreeRTOS」即可自动生成配置代码。SPL 版需要你**手动完成** CubeMX 自动做的事：

| | HAL 版 | SPL 版 |
|---|---|---|
| FreeRTOS 添加 | CubeMX 勾选 | 手动下载源码、写 `FreeRTOSConfig.h`、改 Makefile |
| 外设初始化 | `MX_GPIO_Init()` 自动生成 | 自己 `GPIO_Init()` |
| ISR 写法 | `HAL_GPIO_EXTI_Callback` 回调 | 直接写 `EXTIx_IRQHandler` |
| 延时 | `HAL_Delay` 或 `vTaskDelay` | 只有 `vTaskDelay`（SysTick 被 FreeRTOS 接管） |
| 编译 | CubeIDE | `make` |

**FreeRTOS 的 API 本身在两个版本中一模一样**——`xTaskCreate`、`xQueueSend`、`vTaskDelay` 是 FreeRTOS 的函数，不是 HAL 或 SPL 的。

## 14.6 迷你调度器的边界

本章的几十行调度器用于帮助你看懂 SysTick、PendSV、PSP 和上下文切换的关系。它不是可直接放入项目的 RTOS：

- 没有完整的临界区与中断优先级管理；
- 没有可靠的任务创建、栈检查、延时队列和同步原语；
- 没有经过不同优化等级、不同异常路径和长期运行的验证；
- 很容易因为汇编、ABI、栈对齐或启动顺序细节而出现 HardFault。

阅读它的正确目标是“知道 FreeRTOS 为什么需要 port.c”，而不是“为了省代码自己实现一个生产调度器”。从下一章开始，项目统一使用 FreeRTOS。


## 14.7 从裸机循环拆成任务：一个可执行的设计练习

不要从“我要几个 Task”开始，而是先列出每件事的时间和阻塞边界。以温度节点为例：

| 工作 | 频率/触发条件 | 可能阻塞什么 | 合适归属 |
|---|---|---|---|
| 读取 ADC | 每 100ms | 采样时间很短 | SensorTask |
| OLED 刷新 | 每 250ms | I2C 可能等待 ACK | DisplayTask |
| WiFi AT | 事件驱动、可超时 | 网络可能几十秒无响应 | RadioTask |
| 串口收字节 | 中断到来 | 不能等待 | USART ISR + 缓冲区 |
| 告警按键 | 边沿到来 | 不能解析完整命令 | EXTI ISR + ButtonTask |

然后给每一项写出接口，而不是让任务直接互相读全局变量：

~~~c
typedef struct {
    uint32_t seq;
    int16_t temperature_centi;
    uint16_t voltage_mv;
} EnvSample;

/* 生产者只发送完整副本；消费者不依赖生产者的局部变量。 */
QueueHandle_t sample_q;
~~~

这个表解决三件事：

1. 需要多快响应；  
2. 哪些工作绝不能在 ISR 中做；  
3. 哪些数据必须通过 Queue、通知或受保护的接口交接。  

如果一项工作没有周期、超时、输入和输出，就先不要急着给它创建任务。

## 14.8 最小验收、故障演练与排错

先用两个任务验证调度，再接传感器。最小验收可以是：

1. Task_A 每 500ms 翻转 LED；
2. Task_B 每秒通过 UART 打印自身 tick；
3. 两者同时持续运行 10 分钟；
4. 给一个任务加入 `vTaskDelay`，确认另一个任务仍然运行；
5. 记录每个任务的栈高水位，而不是只看“暂时没死机”。

| 现象 | 优先检查 |
|---|---|
| 启动调度器后没有任何日志 | SysTick/PendSV/SVC 向量、FreeRTOS port、时钟配置 |
| 一个任务跑一次就消失 | 任务函数意外 return；任务栈或参数生命周期错误 |
| 系统偶发 HardFault | 栈太小、非法 ISR API、优先级配置、共享数据越界 |
| 低优先级任务永远不运行 | 高优先级任务没有阻塞/让出 CPU |
| 把 delay 放进任务后系统“卡” | 仍在使用裸机 busy-wait，而不是 `vTaskDelay` |

故障演练：故意把一个任务优先级提高且去掉阻塞，观察其他任务被饿死；恢复 `vTaskDelay` 后解释为什么系统重新平衡。这个实验比背“抢占”定义更重要。

## 14.9 迷你调度器只能用来读，不能混入工程

> ⚠️ **机制演示边界**：14.3 节的迷你调度器用于理解“SysTick 计时、PendSV 换上下文”这条链路。它不是一个可移植的 RTOS 内核，也不能和 FreeRTOS 共用向量表、SysTick 或 PendSV。不要把其中的汇编、任务栈布局或启动函数复制进第 15 章以后的工程。

用下面的时间线检查自己是否真的理解了它：

~~~text
SysTick 到期
  → 只记录“需要调度”
  → 触发 PendSV
  → 当前任务保存寄存器
  → 调度器选择下一个就绪任务
  → PendSV 恢复下一个任务寄存器
  → 回到任务代码
~~~

这里有两个容易被忽略的前提：

- `SysTick` 和 `PendSV` 必须处在合适且一致的异常优先级；它们不是普通外设中断。
- 上下文切换代码依赖编译器 ABI、启动文件、栈对齐和异常入口格式；换一个工具链或优化选项都可能让“看起来只有几十行”的代码失效。

因此从本章过渡到第 15 章时，只保留你学到的**设计语言**：任务有输入、输出、阻塞点、优先级和栈预算。调度、临界区和中断 API 统一交给一个已选定版本的 FreeRTOS port。最小交接检查如下：

- [ ] 工程中只存在一套 `SysTick_Handler`、`PendSV_Handler`、`SVC_Handler` 映射；
- [ ] 没有同时编译迷你调度器和 FreeRTOS 的上下文切换代码；
- [ ] 高优先级任务有明确阻塞点，不能靠忙等“让出 CPU”；
- [ ] 对所有 ISR 都注明：是否会调用 `...FromISR()` API、其 NVIC 优先级是否允许这样做。

练习：不修改汇编，先用伪代码画出两个任务、一个 Queue 和一个 ISR 通知的时间线；能说明“ISR 为什么只通知、任务为什么可以阻塞”后，再开始第 15 章的移植。

## 14.10 本章要点

- RTOS 的价值是把时间、阻塞和责任边界显式化，不是让代码自动并行；
- ISR 负责尽快留下事件，任务负责等待、解析、重试和恢复；
- 每个任务都应有输入、输出、周期/超时、优先级和栈预算；
- 迷你调度器帮助理解机制，项目必须使用经验证的 FreeRTOS；
- 下一章开始先搭出一个可观察、可失败、可定位的 FreeRTOS 最小工程。

---

[下一章：第 15 章 · FreeRTOS 核心 API 与手动移植](./15-chapter.md)

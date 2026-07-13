# 第 15 章 · FreeRTOS 核心 API 与手动移植（SPL版）

> **本章产出**：把 FreeRTOS 正确放入 ZET6 SPL 工程，建立 Task、Queue、Semaphore、Mutex 与 ISR 的最小可验证闭环。
>
> **前置知识**：第 14 章的调度概念；第 5、6、8 章的 SysTick、中断和 UART。
>
> **通过标准**：两个任务、一个 Queue 和一个 ISR 通知能稳定运行，并能报告堆、栈和错误原因。

> FreeRTOS 的 Task、Queue、Semaphore、Mutex 是纯软件概念，API 和 SPL/HAL 无关。本章包含 API 参考 + 手动移植步骤。

---

## 15.1 手动添加 FreeRTOS 到 SPL 工程

### Step 1：下载 FreeRTOS

```bash
git clone https://github.com/FreeRTOS/FreeRTOS-Kernel.git
cd FreeRTOS-Kernel
git checkout V10.5.1  # 稳定版本
```

只需要这几个文件：

```
FreeRTOS-Kernel/
├── tasks.c              # 任务创建/调度
├── queue.c              # 队列+信号量+互斥锁（底层共用）
├── list.c               # 内核链表
├── timers.c             # 软件定时器
├── include/             # 头文件
│   ├── FreeRTOS.h
│   ├── task.h
│   ├── queue.h
│   └── semphr.h
└── portable/
    ├── GCC/ARM_CM3/     # ← Cortex-M3 的 GCC 移植层
    │   ├── port.c
    │   └── portmacro.h
    └── MemMang/
        └── heap_4.c     # ← 五选一的堆实现之一
```

### Step 2：拷贝到工程

```bash
mkdir -p ~/stm32/your-project/freertos/include
cp FreeRTOS-Kernel/{tasks.c,queue.c,list.c,timers.c} \
   ~/stm32/your-project/freertos/
cp -r FreeRTOS-Kernel/include/* \
   ~/stm32/your-project/freertos/include/
cp FreeRTOS-Kernel/portable/GCC/ARM_CM3/{port.c,portmacro.h} \
   ~/stm32/your-project/freertos/
cp FreeRTOS-Kernel/portable/MemMang/heap_4.c \
   ~/stm32/your-project/freertos/
```

### Step 3：写 `FreeRTOSConfig.h`

告诉 FreeRTOS 你的 MCU 参数——这是移植中最关键的一步：

```c
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configCPU_CLOCK_HZ              (72000000UL)  // 系统时钟 72MHz
#define configTICK_RATE_HZ              (1000)         // 心跳 1ms
#define configMAX_PRIORITIES            (8)
#define configMINIMAL_STACK_SIZE        ((unsigned short)128)
#define configTOTAL_HEAP_SIZE           ((size_t)(10 * 1024))  // 10KB 堆
#define configUSE_PREEMPTION            1
#define configUSE_TIME_SLICING          1
#define configUSE_MUTEXES               1
#define configUSE_COUNTING_SEMAPHORES   1
#define configCHECK_FOR_STACK_OVERFLOW  2
#define configUSE_TIMERS                1

/* Cortex-M3 的实现位数来自 CMSIS；不要把 4、15、5 的“左移结果”
   直接抄进别的芯片。ZET6 的常见配置为 4 个实现优先级位，但仍以
   工程实际的 __NVIC_PRIO_BITS 为准。 */
#define configPRIO_BITS                              __NVIC_PRIO_BITS
#define configLIBRARY_LOWEST_INTERRUPT_PRIORITY     15
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY 5

#define configKERNEL_INTERRUPT_PRIORITY \
    (configLIBRARY_LOWEST_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))
#define configMAX_SYSCALL_INTERRUPT_PRIORITY \
    (configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))

#if (configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY == 0)
# error "FromISR API 的优先级边界不能是 0"
#endif
#endif
```

### Step 4：修改 SysTick 中断

FreeRTOS 会接管 SysTick 做心跳：

```c
void SysTick_Handler(void) {
    if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) {
        xPortSysTickHandler();
    }
}
```

⚠️ 删掉你之前写的 `GetTick()` 和 `Delay_ms()`——FreeRTOS 用 `xTaskGetTickCount()` 和 `vTaskDelay()` 替代。

### Step 5：修改 Makefile

```makefile
FREERTOS_DIR = freertos
C_SRCS += $(FREERTOS_DIR)/tasks.c
C_SRCS += $(FREERTOS_DIR)/queue.c
C_SRCS += $(FREERTOS_DIR)/list.c
C_SRCS += $(FREERTOS_DIR)/timers.c
C_SRCS += $(FREERTOS_DIR)/port.c
C_SRCS += $(FREERTOS_DIR)/heap_4.c          # 内存管理
CFLAGS += -I$(FREERTOS_DIR)/include
CFLAGS += -I$(FREERTOS_DIR)
```

---

## 15.2 Task 创建

```c
#include "FreeRTOS.h"
#include "task.h"

// SPL 风格的外设初始化
void LED_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC, ENABLE);
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = GPIO_Pin_13;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    GPIO_Init(GPIOC, &gpio);
}

// Task 函数模板
void Task_Sensor(void *arg) {
    for (;;) {
        // 采集传感器
        vTaskDelay(pdMS_TO_TICKS(5000));  // 5 秒
    }
}

int main(void) {
    SystemClock_Config();
    LED_Init();

    xTaskCreate(Task_Sensor, "Sensor", 256, NULL, 2, NULL);
    vTaskStartScheduler();
    while (1);
}
```

## 15.3 Queue 通信

```c
QueueHandle_t sensor_queue;

void Task_Sensor(void *arg) {
    float temp = 25.3f;
    for (;;) {
        temp += 0.1f;
        xQueueSend(sensor_queue, &temp, portMAX_DELAY);
        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}

void Task_Display(void *arg) {
    float temp;
    for (;;) {
        if (xQueueReceive(sensor_queue, &temp, pdMS_TO_TICKS(2000)) == pdPASS) {
            // 收到数据——更新显示（SPL 操作 I2C OLED 等）
        } else {
            // 超时——传感器可能挂了
        }
    }
}
```

## 15.4 Semaphore + ISR

```c
SemaphoreHandle_t button_sem;

void EXTI0_IRQHandler(void) {
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        BaseType_t wake = pdFALSE;
        xSemaphoreGiveFromISR(button_sem, &wake);
        portYIELD_FROM_ISR(wake);
    }
}

void Task_Button(void *arg) {
    for (;;) {
        // 阻塞等信号量——不占 CPU
        if (xSemaphoreTake(button_sem, portMAX_DELAY) == pdTRUE) {
            vTaskDelay(pdMS_TO_TICKS(30));
            if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
                GPIOC->ODR ^= GPIO_Pin_13;  // SPL 翻转 LED
            }
        }
    }
}
```

## 15.5 Mutex 保护共享资源

```c
SemaphoreHandle_t i2c_mutex;

void Task_A(void *arg) {
    for (;;) {
        xSemaphoreTake(i2c_mutex, portMAX_DELAY);
        // SPL I2C 操作...
        xSemaphoreGive(i2c_mutex);
        vTaskDelay(100);
    }
}

// Task_B 同样先 Take 后 Give——防止两者同时操作 I2C
```

---

## 15.6 SPL vs HAL 代码对照

| 操作 | HAL | SPL |
|------|-----|-----|
| LED 翻转 | `HAL_GPIO_TogglePin(GPIOC, PIN_13)` | `GPIOC->ODR ^= GPIO_Pin_13` |
| 读按键 | `HAL_GPIO_ReadPin(GPIOA, PIN_0)` | `GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0)` |
| I2C 写 | `HAL_I2C_Mem_Write()` | 手动 START→ADDR→DATA→STOP |
| UART 发 | `HAL_UART_Transmit()` | `USART_SendData() + 轮询 TXE` |
| ISR | `HAL_GPIO_EXTI_Callback` 回调 | 直接写 `EXTIx_IRQHandler` |
| 延时 | `HAL_Delay` / `vTaskDelay` | 只有 `vTaskDelay` |
| FreeRTOS 添加 | CubeMX 勾选 | 手动下载+配置+Makefile |
| FreeRTOS API | 相同 | 相同 |

---

## 15.7 ISR、优先级与 FromISR API

FreeRTOS 中最容易出现“偶尔死机”的地方是中断和任务之间的边界。

规则如下：

1. ISR 中只做最短工作：读硬件、放字节、发送轻量通知；
2. ISR 里要使用 xQueueSendFromISR、xSemaphoreGiveFromISR 等 FromISR API；
3. 如果 FromISR API 唤醒了更高优先级任务，按端口要求执行任务切换；
4. 能调用 FreeRTOS API 的中断优先级必须满足 FreeRTOSConfig.h 的限制；
5. 不要在 ISR 中 printf、等待互斥锁、操作文件系统或执行网络请求。

把“中断优先级”和“任务优先级”看成两套不同体系：前者决定谁能打断 CPU，后者决定调度器选择哪个任务。

## 15.8 实验验收

- [ ] 一个按键 ISR 通过二值信号量唤醒任务；
- [ ] ISR 不直接做耗时业务逻辑；
- [ ] 人为提高中断频率后，系统仍不丢失关键通知；
- [ ] 打开栈溢出和断言钩子，观察错误是否可定位；
- [ ] 在 README 中写出使用的 FreeRTOS 堆和时钟配置。

## 15.9 附录：精简版 RTOS 核心（~50 行）

第 14 章详细讲解了抢占式调度的原理。下面是精简版 RTOS 的全部代码——去掉了注释，只保留核心骨架。理解了这个，你就知道 FreeRTOS 的 `vTaskStartScheduler()` 内部在干什么。

```c
/* ========== 数据结构 ========== */
#define MAX_TASKS  4
struct TCB { uint32_t *sp; uint32_t stack[128]; };
struct TCB tasks[MAX_TASKS];
volatile int current_task = 0;

/* ========== 创建任务（伪造栈帧）========== */
void TaskCreate(void (*func)(void), int id) {
    uint32_t *sp = &tasks[id].stack[128];
    *--sp = 0x01000000;                     // xPSR (Thumb=1)
    *--sp = (uint32_t)func;                  // PC
    *--sp = 0xFFFFFFFD;                      // LR
    *--sp = 0x0C; *--sp = 0x03; *--sp = 0x02; *--sp = 0x01; *--sp = 0x00;
    for (int i = 0; i < 8; i++) *--sp = 0;  // r4~r11
    tasks[id].sp = sp;
}

/* ========== SysTick：触发调度 ========== */
void SysTick_Handler(void) {
    SCB->ICSR |= SCB_ICSR_PENDSVSET_Msk;
}

/* ========== PendSV：上下文切换 ========== */
__asm void PendSV_Handler(void) {
    MRS r0, PSP
    STMDB r0!, {r4-r11}
    LDR r1, =current_task
    LDR r2, [r1]
    LDR r3, =tasks
    MOV r4, #16
    MLA r2, r2, r4, r3
    STR r0, [r2]
    LDR r2, [r1]
    ADD r2, r2, #1
    CMP r2, #MAX_TASKS-1
    ITT GT
    MOVGT r2, #0
    STR r2, [r1]
    MOV r4, #16
    MLA r2, r2, r4, r3
    LDR r0, [r2]
    LDMIA r0!, {r4-r11}
    MSR PSP, r0
    BX LR
}

/* ========== 启动调度器 ========== */
void StartScheduler(void) {
    __set_PSP((uint32_t)tasks[0].sp);
    SysTick_Config(SystemCoreClock / 1000);
    SCB->ICSR |= SCB_ICSR_PENDSVSET_Msk;
    __set_CONTROL(0x03);
    __ISB();
    asm("SVC 0");
}

/* ========== 两个任务 ========== */
void Task1(void) { while (1) { GPIOC->ODR ^= GPIO_Pin_13; } }
void Task2(void) { while (1) { /* 做别的事 */ } }

int main(void) {
    TaskCreate(Task1, 0); TaskCreate(Task2, 1);
    StartScheduler();
    while (1);
}
```

> **为什么能工作**：Cortex-M3 进入 PendSV 时硬件自动压栈 r0~r3/r12/LR/PC/xPSR，`BX LR` 返回时自动弹出。你只需要保存/恢复 r4~r11（编译器约定「被调用者保存」的寄存器）。FreeRTOS 的 `port.c` 做的也是这件事，只是多了优先级查找、临界区保护、中断屏蔽。

## 15.10 从“能编译”到“移植正确”的检查表

手工移植最容易出现“工程能链接、上电就没有输出”。请按层检查，而不是同时修改所有宏：

| 层 | 必须确认的事实 | 可观察证据 |
|---|---|---|
| 内核文件 | kernel、heap 实现和 Cortex-M3 GCC port 都被编译 | Makefile 编译日志含对应 `.c` |
| 配置 | CPU 时钟、tick、堆、优先级和断言策略一致 | UART 启动日志打印关键宏 |
| 启动向量 | SVC、PendSV、SysTick 已指向 FreeRTOS port | 启动调度器后两个任务都运行 |
| 中断边界 | 只有合法优先级的 ISR 调用 `...FromISR` API | 连续外部中断不导致 HardFault |
| 内存 | 每个任务有栈预算，内核堆有余量 | 高水位与剩余堆可输出 |

调试构建建议启用两个 hook，而不是把内存失败静默吞掉：

~~~c
void vApplicationMallocFailedHook(void)
{
    taskDISABLE_INTERRUPTS();
    /* 可在这里点亮错误 LED；调试时停住以便 GDB 查看。 */
    for (;;);
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task; (void)name;
    taskDISABLE_INTERRUPTS();
    for (;;);
}
~~~

这段代码的目标是**暴露问题**，不是线上恢复策略。正式项目应记录错误并进入明确的安全状态。

## 15.11 Queue、Semaphore、Mutex：按“所有权”选择

| 需要交接的东西 | 首选 | 典型误用 |
|---|---|---|
| 一份完整传感器数据 | Queue | 传递指向即将失效的局部变量指针 |
| “有新字节/按键来了”事件 | 二值信号量或任务通知 | 在 ISR 中解析整帧 |
| 计数资源或多个事件 | 计数信号量 | 用全局计数器无保护自增 |
| 一条共享 I2C/SPI 总线 | Mutex | 用 Mutex 保护本该排队的数据 |
| 最新状态而非历史队列 | 长度 1 的覆盖队列或原子快照 | 无限堆积过期 UI 数据 |

每一次发送都要回答：谁创建数据、谁拥有它、谁释放它、满了怎么办、超时后怎么办。这个问题比 API 名字更关键。

## 15.12 分阶段实验、排错与练习

按以下顺序构建，不要一次加所有 API：

1. 创建两个只会打印日志并 `vTaskDelay` 的任务；
2. 加入一个整数 Queue，生产者每秒发送，消费者打印；
3. 加入按键 ISR，只使用 `xSemaphoreGiveFromISR` 或任务通知；
4. 加入一个共享 I2C/SPI 接口，明确 Mutex 的持有时间；
5. 打印 `xPortGetFreeHeapSize()` 与每个任务的 `uxTaskGetStackHighWaterMark()`。

| 现象 | 优先检查 |
|---|---|
| `xTaskCreate` 失败 | 总堆太小、任务栈请求过大、heap 实现/链接遗漏 |
| Queue 永远收不到 | 句柄生命周期、发送者是否真的运行、等待时间单位 |
| ISR 一触发就 HardFault | 调用了非 FromISR API、优先级不符合配置、yield 逻辑不完整 |
| 栈余量越来越小 | 大数组/printf/递归放在任务栈，或存在越界写 |
| Mutex 让系统看似死锁 | 持锁后做网络/延时，或锁顺序不一致 |

练习：把第 8 章 UART 接收 ISR 改为“ISR 只通知 + 任务解析”；用 UART 证明快速连续输入时既不丢失统计，也不会在 ISR 中执行耗时逻辑。

## 15.13 ZET6 移植的最小清单：先证明“只有一套内核”

“能编译”并不足以说明 FreeRTOS 已正确接管 Cortex-M3。开始编译前，把下面这份清单写进项目 README；每一项都能在文件树、启动文件或日志中检查。

| 类别 | 必须明确的选择 | 常见事故 |
|---|---|---|
| 内核源码 | `tasks.c`、`queue.c`、`list.c`，按需加入 `timers.c` | 漏编译 `list.c`，或把内核源码复制了两份 |
| 移植层 | 只使用 `portable/GCC/ARM_CM3` 的 `port.c/portmacro.h` | 误用 M4F/MPU port，或自己再编译一套 PendSV 汇编 |
| 堆实现 | 只编译一个 `heap_1.c`…`heap_5.c`；入门示例选 `heap_4.c` 并写明原因 | 同时链接两个 heap，或声明 `configTOTAL_HEAP_SIZE` 却没编译 heap |
| 向量表 | SVC、PendSV、SysTick 分别映射到选定 port 的 handler | 旧裸机 SysTick 和 port handler 同名/重复 |
| 中断优先级 | `__NVIC_PRIO_BITS`、库优先级和移位后的 FreeRTOS 优先级同时可读 | 把“数值越小优先级越高”看反 |
| 可观测性 | `configASSERT`、malloc failed hook、stack overflow hook、栈高水位 | 只在 HardFault 后猜测原因 |

### 一份不含魔数的优先级约定

上面配置把 **库级优先级** 与 **写入 NVIC 寄存器的值** 分开。以 `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY = 5` 为例：

- 逻辑优先级 `0–4` 更高；这些 ISR **不得**调用任何 FreeRTOS API（包括 `...FromISR()`）。
- 逻辑优先级 `5–15` 可以调用 `...FromISR()` API，但 ISR 仍应只搬运事件、给通知或入队。
- 内核 SysTick/PendSV 通常处在最低逻辑优先级；实际值由选用的 port 和 `FreeRTOSConfig.h` 共同决定。

不要只修改 `NVIC_InitTypeDef` 的数字就认为已经安全。给每个 ISR 写一行注释：它是否调用 RTOS API、对应的库级优先级、为什么这个优先级合适。

### Handler 映射只选一种方式

不同启动文件和 FreeRTOS 版本的符号命名可能不同。项目可以在启动文件中把 `SVC_Handler`、`PendSV_Handler`、`SysTick_Handler` 映射到 port 提供的 `vPortSVCHandler`、`xPortPendSVHandler`、`xPortSysTickHandler`，也可以由 C 文件提供同名包装函数；**两种方式二选一**。提交前用 map 文件确认三个 handler 最终各只解析到一个地址。

最小验收顺序：

1. 只创建两个会 `vTaskDelay()` 的任务，连续运行 10 分钟；
2. 打印 `xPortGetFreeHeapSize()` 和每个任务的高水位；
3. 再让一个允许的 ISR 用 `xSemaphoreGiveFromISR()` 通知任务；
4. 人为把该 ISR 调到不允许的优先级，确认 `configASSERT` 或审查规则能阻止错误进入产品代码。

## 15.14 本章要点

- FreeRTOS 移植首先是向量、中断优先级、时钟和内存的系统工程；
- Task/Queue/Semaphore/Mutex 的区别来自数据与所有权，不来自名字；
- 先建立两个任务和一条日志，再逐步接入队列、中断和总线；
- 堆、栈高水位和错误 hook 是最早应加入的可观测性；
- 任何 ISR 到任务的通路都必须使用 FromISR API 并遵守优先级边界。

---

> **下一章**：[第 16 章 · FreeRTOS 实战（SPL版）](./16-chapter.md)

# 第 15 章 · FreeRTOS 核心 API 与手动移植（SPL 版）

这一章把 FreeRTOS 接进 STM32F103ZET6 的 SPL 工程。先让两个任务稳定运行，再加入 Queue、ISR 通知和 Mutex。调试时要能看到剩余堆、任务栈高水位和断言位置。

FreeRTOS API 和 SPL/HAL 没有绑定关系。SPL 负责外设，FreeRTOS 负责任务调度和任务间同步。

## 15.1 先固定 FreeRTOS 版本

不要直接跟随仓库最新提交。项目应固定一个已经验证过的 FreeRTOS Kernel tag 或 commit，并把版本写进 README 或构建配置。后续升级时单独做一次移植验证。

工程至少需要：

```text
FreeRTOS-Kernel/
├── tasks.c
├── queue.c
├── list.c
├── timers.c             # 使用软件定时器时加入
├── include/
├── portable/GCC/ARM_CM3/
│   ├── port.c
│   └── portmacro.h
└── portable/MemMang/
    └── heap_4.c         # 本书示例使用一个 heap 实现
```

`tasks.c`、`queue.c`、`list.c` 是基础内核文件。Semaphore 和 Mutex 也建立在 Queue 实现上，不需要再找单独的 `semaphore.c`。`portable/GCC/ARM_CM3` 对应 Cortex-M3 + GCC；不要混入 ARM_CM4F、MPU 或其他编译器的 port。

内存管理文件只能选一个。这里使用 `heap_4.c`，因为它支持分配和释放，并能合并相邻空闲块。选择其他 heap 也可以，但必须明确其行为和限制。

## 15.2 Makefile 只编译一套内核

假设 FreeRTOS 放在 `freertos/`：

```makefile
FREERTOS_DIR := freertos

C_SRCS += $(FREERTOS_DIR)/tasks.c
C_SRCS += $(FREERTOS_DIR)/queue.c
C_SRCS += $(FREERTOS_DIR)/list.c
C_SRCS += $(FREERTOS_DIR)/timers.c
C_SRCS += $(FREERTOS_DIR)/portable/GCC/ARM_CM3/port.c
C_SRCS += $(FREERTOS_DIR)/portable/MemMang/heap_4.c

CFLAGS += -I$(FREERTOS_DIR)/include
CFLAGS += -I$(FREERTOS_DIR)/portable/GCC/ARM_CM3
CFLAGS += -I.
```

如果没有启用软件定时器，可以先不编译 `timers.c`，同时把对应配置关闭。不要同时复制一份 `port.c` 到项目根目录又从 `portable/GCC/ARM_CM3` 编译一次；同样不要同时链接两个 `heap_x.c`。

编译日志和 MAP 文件应该能确认这些源码只出现一次。

## 15.3 `FreeRTOSConfig.h` 先配置最小集合

下面给出 ZET6 工程的起点。具体堆大小、任务优先级数量和 tick 频率要根据项目实际资源调整。

```c
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include "stm32f10x.h"

#define configUSE_PREEMPTION                     1
#define configUSE_TIME_SLICING                   1
#define configCPU_CLOCK_HZ                       (SystemCoreClock)
#define configTICK_RATE_HZ                       ((TickType_t)1000)
#define configMAX_PRIORITIES                     8
#define configMINIMAL_STACK_SIZE                 ((uint16_t)128)
#define configTOTAL_HEAP_SIZE                    ((size_t)(10U * 1024U))

#define configUSE_MUTEXES                        1
#define configUSE_COUNTING_SEMAPHORES            1
#define configUSE_TIMERS                         1
#define configTIMER_TASK_PRIORITY                2
#define configTIMER_QUEUE_LENGTH                 8
#define configTIMER_TASK_STACK_DEPTH             256

#define configCHECK_FOR_STACK_OVERFLOW           2
#define configUSE_MALLOC_FAILED_HOOK             1
#define configASSERT(x)                          do { if ((x) == 0) { taskDISABLE_INTERRUPTS(); for (;;) {} } } while (0)

#define configPRIO_BITS                          __NVIC_PRIO_BITS
#define configLIBRARY_LOWEST_INTERRUPT_PRIORITY  15
#define configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY 5

#define configKERNEL_INTERRUPT_PRIORITY \
    (configLIBRARY_LOWEST_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))

#define configMAX_SYSCALL_INTERRUPT_PRIORITY \
    (configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY << (8 - configPRIO_BITS))

#endif
```

`configCPU_CLOCK_HZ` 使用 `SystemCoreClock` 时，要保证进入调度器之前已经完成时钟配置并调用过 `SystemCoreClockUpdate()`。如果 HSE 启动失败后系统会回退到 HSI，这样 FreeRTOS tick 仍能按实际时钟计算。

STM32F103 实现 4 个 NVIC 优先级位，CMSIS 通过 `__NVIC_PRIO_BITS` 提供这个值。上面的库级优先级 5 表示：逻辑优先级 0–4 的 ISR 不允许调用 FreeRTOS API；5–15 可以调用允许的 `...FromISR()` API。NVIC 数字越小，硬件优先级越高。

这些数字要作为整个工程的中断策略统一维护，不能每个驱动自己随便选。

## 15.4 SVC、PendSV、SysTick 只能有一套

Cortex-M3 port 需要三个异常入口：SVC、PendSV 和 SysTick。项目可以在 `FreeRTOSConfig.h` 中把标准异常名映射到 port handler，例如：

```c
#define vPortSVCHandler    SVC_Handler
#define xPortPendSVHandler PendSV_Handler
#define xPortSysTickHandler SysTick_Handler
```

也可以根据所用启动文件和 FreeRTOS 版本采用其他明确的映射方式。关键是最终链接结果中每个异常只有一个实现。

不要一边让 `port.c` 提供 SysTick handler，一边又保留前面章节的：

```c
void SysTick_Handler(void)
{
    ++g_ms;
}
```

这种重复会导致链接冲突，或者更隐蔽地让 FreeRTOS 没有收到 tick。

前面章节如果还需要独立毫秒时基，可以把它迁到普通硬件定时器，或者在任务环境直接使用 `xTaskGetTickCount()`。不要维护两套互相竞争的 SysTick。

提交前可以从 MAP 文件或 `arm-none-eabi-nm` 检查：

```bash
arm-none-eabi-nm -n build/app.elf \
  | grep -E 'SVC_Handler|PendSV_Handler|SysTick_Handler'
```

每个 handler 应只解析到一个最终地址。

## 15.5 先跑两个最小任务

外设初始化完成后创建两个任务：

```c
#include "FreeRTOS.h"
#include "task.h"

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
        Console_Write("alive\r\n");
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

int main(void)
{
    Board_Init();
    Console_Init();

    if (xTaskCreate(LedTask, "led", 128, NULL, 1, NULL) != pdPASS)
        Error_Stop();

    if (xTaskCreate(LogTask, "log", 256, NULL, 1, NULL) != pdPASS)
        Error_Stop();

    vTaskStartScheduler();

    Error_Stop();
}
```

`xTaskCreate()` 的 stack depth 单位是 `StackType_t` 元素，不是字节。Cortex-M3 port 的 `StackType_t` 通常是 32 位，因此 `128` 通常对应 512 字节栈；仍应以当前 port 类型定义为准。

`vTaskStartScheduler()` 正常启动后不会返回。若返回，常见原因是创建 Idle Task 所需内存分配失败。这里直接进入错误处理，不继续运行裸机主循环。

两个任务先持续运行一段时间，再加 Queue 和 ISR。移植阶段一次只增加一个变量，故障更容易定位。

## 15.6 Queue 传递完整数据

Queue 会把发送的数据复制进队列存储区。传传感器样本时，可以直接发送结构体副本：

```c
typedef struct {
    uint32_t seq;
    int16_t temperature_centi;
    uint16_t voltage_mv;
} EnvSample;

static QueueHandle_t sample_queue;

static void SensorTask(void *argument)
{
    EnvSample sample = {0};
    (void)argument;

    for (;;) {
        sample.seq++;
        sample.temperature_centi = Sensor_ReadTemperature();
        sample.voltage_mv = Sensor_ReadVoltage();

        if (xQueueSend(sample_queue, &sample, pdMS_TO_TICKS(50)) != pdPASS)
            Diagnostics_CountSampleDrop();

        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

static void DisplayTask(void *argument)
{
    EnvSample sample;
    (void)argument;

    for (;;) {
        if (xQueueReceive(sample_queue, &sample, portMAX_DELAY) == pdPASS)
            Display_Update(&sample);
    }
}
```

创建队列：

```c
sample_queue = xQueueCreate(8, sizeof(EnvSample));
if (sample_queue == NULL)
    Error_Stop();
```

队列满时怎么办属于应用策略。传感器历史不能丢，就需要更大的缓冲或后压机制；UI 只关心最新状态时，长度为 1 的 Queue 配合 `xQueueOverwrite()` 可能更合适。

## 15.7 ISR 使用 `...FromISR()` API

按键 EXTI ISR 可以只通知任务：

```c
static TaskHandle_t button_task;

void EXTI0_IRQHandler(void)
{
    BaseType_t higher_priority_woken = pdFALSE;

    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);

        vTaskNotifyGiveFromISR(button_task, &higher_priority_woken);
        portYIELD_FROM_ISR(higher_priority_woken);
    }
}
```

任务中阻塞等待：

```c
static void ButtonTask(void *argument)
{
    (void)argument;

    for (;;) {
        (void)ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

        vTaskDelay(pdMS_TO_TICKS(30));
        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET)
            App_OnButtonPressed();
    }
}
```

这种“一对一唤醒”不需要额外创建 Semaphore，Task Notification 更轻。需要多个消费者、计数资源或其他语义时再使用 Binary/Counting Semaphore。

调用任何 `...FromISR()` API 前，都要确认该中断的 NVIC 优先级符合 `configMAX_SYSCALL_INTERRUPT_PRIORITY` 的规则。高于这个边界的硬实时 ISR 仍然可以存在，但它们不能调用 FreeRTOS API。

ISR 中不要等待 Mutex、调用文件系统、做网络请求或大量输出日志。

## 15.8 Mutex 保护共享外设

两个任务直接操作同一 I2C 控制器时，START 到 STOP 之间必须保持完整事务。可以用 Mutex 保护总线：

```c
static SemaphoreHandle_t i2c_mutex;

bool I2C_DeviceRead(...)
{
    if (xSemaphoreTake(i2c_mutex, pdMS_TO_TICKS(20)) != pdTRUE)
        return false;

    bool ok = I2C_Transaction(...);

    xSemaphoreGive(i2c_mutex);
    return ok;
}
```

持有 Mutex 的时间只覆盖必须独占的事务。不要拿到锁以后 `vTaskDelay()`、等待网络或做与 I2C 无关的计算。

如果多个任务都频繁访问同一复杂外设，也可以建立一个 I2C/Storage 服务任务，其他任务通过 Queue 提交请求。这样总线所有权天然集中在一个上下文中。

Mutex 带优先级继承，适合任务之间保护共享资源。ISR 不能获取 Mutex。

## 15.9 内存和栈必须可观察

启用 malloc failure 和 stack overflow hook：

```c
void vApplicationMallocFailedHook(void)
{
    taskDISABLE_INTERRUPTS();
    Error_SetCode(ERROR_FREERTOS_MALLOC);
    for (;;) {
    }
}

void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task;
    (void)name;

    taskDISABLE_INTERRUPTS();
    Error_SetCode(ERROR_FREERTOS_STACK);
    for (;;) {
    }
}
```

调试时定期读取：

```c
size_t free_heap = xPortGetFreeHeapSize();
UBaseType_t led_watermark = uxTaskGetStackHighWaterMark(led_task_handle);
```

栈高水位表示任务历史上最少剩余过多少个 `StackType_t` 元素。它不是字节数，解释时要乘当前 `sizeof(StackType_t)`。

给任务分配栈时，不要统一写一个经验值。`printf`、FatFs、较大的局部数组和深层函数调用都会增加栈需求。先给出保守空间，做压力测试后根据高水位再调整。

`xPortGetFreeHeapSize()` 只能说明当前剩余堆，不等于最大连续可分配块，也不能替代对长期分配/释放行为的检查。

## 15.10 一个最小的中断优先级约定

本章只保留一张表，用来固定哪些 ISR 可以调用 FreeRTOS API。假设 `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY = 5`：

| NVIC 逻辑优先级 | 可否调用 `...FromISR()` | 典型用途 |
|---:|---|---|
| 0–4 | 不可以 | 极高优先级、完全独立于 RTOS 的短 ISR |
| 5–15 | 可以 | UART、DMA、EXTI 等需要通知任务的 ISR |

这里的数字越小优先级越高。任务优先级是另一套编号体系，不能拿 task priority 与 NVIC priority 直接比较。

每个 ISR 都建议在驱动旁写明：NVIC 逻辑优先级、是否调用 RTOS API、通知哪个任务。这样以后修改 `configLIBRARY_MAX_SYSCALL_INTERRUPT_PRIORITY` 时能一起审查。

## 15.11 最小验收顺序

按下面顺序加功能：

1. 两个任务只做 LED 和 UART 日志，都使用 `vTaskDelay()`。
2. 创建一个 `Queue<EnvSample>`，生产者发送，消费者接收。
3. EXTI ISR 用 Task Notification 唤醒 ButtonTask。
4. 两个任务通过 Mutex 共享 I2C，并故意制造并发访问验证互斥。
5. 输出剩余堆和每个任务的栈高水位。
6. 打开 `configASSERT`，故意把一个调用 `...FromISR()` 的中断设到不允许的高优先级，在调试构建中确认错误能被发现。

常见故障可以这样缩小范围：

- `xTaskCreate()` 返回失败：检查 heap 实现、`configTOTAL_HEAP_SIZE` 和申请的 stack depth。
- `vTaskStartScheduler()` 返回：优先检查 Idle Task 内存是否分配失败。
- 启动后没有 tick：检查 SysTick/PendSV/SVC handler 映射和系统时钟。
- ISR 一触发就断言或 HardFault：检查是否调用了普通 API、NVIC 优先级是否越过 syscall 边界。
- 低优先级任务长期不运行：检查更高优先级任务是否从不阻塞。
- Mutex 看起来死锁：检查锁顺序，以及持锁期间是否执行了长时间等待。

## 15.12 本章练习

1. 把第 8 章 UART RX 改成 DMA/ISR 只负责收数据和通知，ConsoleTask 在任务上下文解析命令。
2. 建立长度为 1 的最新传感器状态 Queue，用 `xQueueOverwrite()` 更新，再与普通长度 8 Queue 的行为比较。
3. 在 I2C Mutex 保护区中故意加入 100 ms 延时，观察其他等待 I2C 的任务，再删掉延时并比较。
4. 给所有任务打印 `uxTaskGetStackHighWaterMark()`，逐个减少栈，找到开始触发 stack overflow 检测附近的边界，然后恢复安全余量。

完成这一章后，工程应该只有一套 FreeRTOS Cortex-M3 port、一套 heap、一个明确的 NVIC syscall 优先级边界。第 16 章再继续讨论任务同步、事件和更完整的系统组织。

> **上一章**：[第 14 章 · 为什么需要 RTOS](./14-chapter.md)
>
> **下一章**：[第 16 章 · FreeRTOS 任务同步与系统组织](./16-chapter.md)

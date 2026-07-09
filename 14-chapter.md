# 第 14 章 · 为什么需要 RTOS（SPL版）

> 裸机只有一个 while(1)——复杂项目里多任务协调困难。RTOS 用抢占式调度解决这个问题。FreeRTOS 和 SPL/HAL 无关——它的 API 在两个库里调用方式完全一样。

---

## SPL 版和 HAL 版的不同

HAL 版第 14 章提到「CubeMX 一键配置 FreeRTOS」。SPL 版没有 CubeMX——你需要**手动把 FreeRTOS 源码加入工程**。

这听起来更麻烦，但手动移植 FreeRTOS 有一个巨大的好处：**你彻底理解了 RTOS 是怎么跑在 MCU 上的**。你会知道：
- `FreeRTOSConfig.h` 里每一项配置的含义
- SysTick 是怎么被 FreeRTOS 劫持的
- 为什么 `vTaskDelay` 能工作而你的 `Delay_ms` 不能共存了

---

## 手动添加 FreeRTOS 到 SPL 工程

### Step 1：下载 FreeRTOS

```bash
git clone https://github.com/FreeRTOS/FreeRTOS-Kernel.git
cd FreeRTOS-Kernel
git checkout V10.5.1  # 稳定版本
```

只需要这几个文件：

```
FreeRTOS-Kernel/
├── croutine.c
├── event_groups.c
├── list.c
├── queue.c
├── stream_buffer.c
├── tasks.c
├── timers.c
├── include/
│   ├── FreeRTOS.h
│   ├── task.h
│   ├── queue.h
│   ├── semphr.h
│   └── ...
└── portable/
    └── GCC/ARM_CM3/          ← 你要这个！
        ├── port.c
        ├── portmacro.h
        └── portasm.c  (或 .s)
```

### Step 2：拷贝到 SPL 工程

```bash
mkdir ~/stm32/your-project/freertos
cp -r FreeRTOS-Kernel/*.c ~/stm32/your-project/freertos/
cp -r FreeRTOS-Kernel/include ~/stm32/your-project/freertos/
cp -r FreeRTOS-Kernel/portable/GCC/ARM_CM3/* ~/stm32/your-project/freertos/
```

### Step 3：写 `FreeRTOSConfig.h`

这是最关键的一步——告诉 FreeRTOS 你的 MCU 参数：

```c
#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configUSE_PREEMPTION            1
#define configUSE_TIME_SLICING          1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0
#define configUSE_TICKLESS_IDLE         0
#define configCPU_CLOCK_HZ              (72000000UL)  // ← 你的系统时钟
#define configTICK_RATE_HZ              (1000)         // 1ms tick
#define configMAX_PRIORITIES            (8)
#define configMINIMAL_STACK_SIZE        ((unsigned short)128)
#define configTOTAL_HEAP_SIZE           ((size_t)(10 * 1024))  // 10KB 堆
#define configMAX_TASK_NAME_LEN         (16)
#define configUSE_16_BIT_TICKS          0
#define configIDLE_SHOULD_YIELD         1
#define configUSE_MUTEXES               1
#define configUSE_COUNTING_SEMAPHORES   1
#define configQUEUE_REGISTRY_SIZE       8

// 钩子函数
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0
#define configCHECK_FOR_STACK_OVERFLOW  2  // 检测栈溢出

// 软件定时器
#define configUSE_TIMERS               1
#define configTIMER_TASK_PRIORITY      (2)
#define configTIMER_QUEUE_LENGTH       10
#define configTIMER_TASK_STACK_DEPTH   (256)

// 内存管理方案——用 heap_4.c（合并相邻空闲块）
#define configSUPPORT_DYNAMIC_ALLOCATION 1

// 中断优先级（Cortex-M3 特定）
#define configKERNEL_INTERRUPT_PRIORITY   (15 << 4)
#define configMAX_SYSCALL_INTERRUPT_PRIORITY (5 << 4)

// 钩子声明
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName);
void vAssertCalled(const char *file, int line);

#define configASSERT(x) if((x)==0) vAssertCalled(__FILE__, __LINE__)

#endif
```

### Step 4：修改 SysTick 中断

FreeRTOS 会接管 SysTick 做系统心跳。你的 `SysTick_Handler` 需要改成：

```c
// 在 main.c 中（替换你第 5 章写的 SysTick_Handler）
void SysTick_Handler(void) {
    // 告诉 FreeRTOS tick 到了
    if (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED) {
        xPortSysTickHandler();
    }
}
```

**同时删掉你自己写的 `GetTick()` 和 `Delay_ms()`**——FreeRTOS 提供了 `xTaskGetTickCount()` 和 `vTaskDelay()` 来替代它们。

### Step 5：修改 Makefile

```makefile
# FreeRTOS 源文件加入编译
FREERTOS_DIR = freertos
C_SRCS += $(FREERTOS_DIR)/tasks.c
C_SRCS += $(FREERTOS_DIR)/queue.c
C_SRCS += $(FREERTOS_DIR)/list.c
C_SRCS += $(FREERTOS_DIR)/timers.c
C_SRCS += $(FREERTOS_DIR)/port.c
C_SRCS += $(FREERTOS_DIR)/heap_4.c

# FreeRTOS 头文件路径
CFLAGS += -I$(FREERTOS_DIR)/include
CFLAGS += -I$(FREERTOS_DIR)
```

---

## SPL + FreeRTOS 的 Task 代码

和 HAL 版第 15-16 章对比一下——核心逻辑**完全一样**，只是底层外设操作走 SPL：

```c
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"

#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

// ===== LED 初始化（SPL 风格）=====
void LED_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC, ENABLE);
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = GPIO_Pin_13;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    GPIO_Init(GPIOC, &gpio);
}

// ===== LED 闪烁任务 =====
void Task_LED(void *arg) {
    for (;;) {
        GPIOC->ODR ^= GPIO_Pin_13;                     // SPL 风格翻转
        vTaskDelay(pdMS_TO_TICKS(500));                 // FreeRTOS 延时
    }
}

// ===== 按键检测任务（中断 → 信号量 → 任务）=====
SemaphoreHandle_t button_sem;

// EXTI 中断 ISR
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
        if (xSemaphoreTake(button_sem, portMAX_DELAY) == pdTRUE) {
            vTaskDelay(pdMS_TO_TICKS(30));  // 消抖
            if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
                // 按键处理...
            }
        }
    }
}

int main(void) {
    SystemClock_Config();
    LED_Init();
    Button_EXTI_Init();

    // 创建信号量
    button_sem = xSemaphoreCreateBinary();

    // 创建任务
    xTaskCreate(Task_LED,   "LED",   128, NULL, 2, NULL);
    xTaskCreate(Task_Button,"Button",256, NULL, 3, NULL);

    // 启动调度器——此函数永不返回
    vTaskStartScheduler();

    while (1);  // 永远不会执行到这里
}
```

---

## 关键区别总结

| | HAL 版 Part 4 | SPL 版 Part 4 |
|---|---|---|
| FreeRTOS 添加方式 | CubeMX 勾选 | 手动拷贝源码 + 写 `FreeRTOSConfig.h` |
| 外设初始化 | `MX_GPIO_Init()` | `GPIO_Init()` |
| ISR | `HAL_GPIO_EXTI_Callback` | 直接写 `EXTIx_IRQHandler` |
| 延时 | `HAL_Delay` / `vTaskDelay` | 只有 `vTaskDelay`（SysTick 被 FreeRTOS 接管了） |
| 编译 | CubeIDE Build 按钮 | `make` |

**FreeRTOS 本身没变**——`xTaskCreate`、`xQueueSend`、`vTaskDelay` 这些 API 在两个版本里完全一样。SPL 版只是让你手动完成了 HAL 版 CubeMX 自动做的那部分工作。

---

> **下一章**：[第 15 章 · FreeRTOS 核心概念](./15-chapter.md)
>
> FreeRTOS 的 Task、Queue、Semaphore、Mutex API 在 SPL 和 HAL 中调用方式完全一样——因为这些不是 HAL/SPL 的函数，是 FreeRTOS 自己的。下面的骨架代码可以直接编译运行。

# 第 15 章 · FreeRTOS 核心 API 与手动移植（SPL版）

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
    └── GCC/ARM_CM3/     # ← Cortex-M3 移植层！
        ├── port.c
        ├── portmacro.h
        └── portasm.c
```

### Step 2：拷贝到工程

```bash
mkdir ~/stm32/your-project/freertos
cp -r FreeRTOS-Kernel/*.c ~/stm32/your-project/freertos/
cp -r FreeRTOS-Kernel/include ~/stm32/your-project/freertos/
cp -r FreeRTOS-Kernel/portable/GCC/ARM_CM3/* ~/stm32/your-project/freertos/
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

// Cortex-M3 中断优先级（高 4 位有效）
#define configKERNEL_INTERRUPT_PRIORITY   (15 << 4)
#define configMAX_SYSCALL_INTERRUPT_PRIORITY (5 << 4)
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

---

> **下一章**：[第 16 章 · FreeRTOS 实战（SPL版）](./16-chapter.md)

# 第 15 章 · FreeRTOS 核心概念（SPL版）

> FreeRTOS 的 Task、Queue、Semaphore、Mutex 是纯软件概念，API 和 SPL/HAL 无关——两个库里使用方法一模一样。本章给 SPL 版完整可编译代码。

---

## Task 创建（SPL 外设初始化）

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

## Queue 通信（SPL 风格）

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

## Semaphore + ISR

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

## Mutex 保护共享资源

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

## SPL vs HAL 代码对照（FreeRTOS 无关部分）

| 操作 | HAL（上层目录） | SPL（本章） |
|------|---------------|-----------|
| LED 翻转 | `HAL_GPIO_TogglePin(GPIOC, PIN_13)` | `GPIOC->ODR ^= GPIO_Pin_13` |
| 读按键 | `HAL_GPIO_ReadPin(GPIOA, PIN_0)` | `GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0)` |
| ISR 清标志 | HAL 自动 | `EXTI_ClearITPendingBit(EXTI_Line0)` |
| FreeRTOS API | 相同 | 相同 |

---

> **下一章**：[第 16 章 · FreeRTOS 实战（SPL版）](./16-chapter.md)

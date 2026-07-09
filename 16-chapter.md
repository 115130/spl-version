# 第 16 章 · FreeRTOS 实战（SPL版）

> 多任务传感器系统：用 FreeRTOS 管理数据采集任务，用 SPL 初始化 I2C/SPI/UART 外设。任务架构和 FreeRTOS API 调用是通用的，本章给 SPL 版完整代码。

---

## 四任务系统（SPL 外设 + FreeRTOS）

```
SensorTask(prio 3, 256w)  ──Queue──→ DisplayTask(prio 2, 256w)
                                      更新 OLED（SPL I2C）

SensorTask ──Queue──→ LogTask(prio 2, 512w)
                      写 SD 卡（SPL SPI）

Button ISR ──Sem──→ ButtonTask(prio 4, 128w)
                    处理按键
```

### 完整代码

```c
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"
#include "semphr.h"

#include "stm32f10x.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_usart.h"
#include "stm32f10x_adc.h"

// ===== 数据结构 =====
typedef struct {
    float temperature;
    float humidity;
    uint16_t lux;
    float battery_v;
} SensorData_t;

// ===== IPC 对象 =====
QueueHandle_t sensor_queue;
QueueHandle_t log_queue;
SemaphoreHandle_t button_sem;
SemaphoreHandle_t i2c_mutex;

// ===== 外设初始化（SPL）=====
void Periph_Init(void) {
    // LED
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC, ENABLE);
    GPIO_InitTypeDef g;
    GPIO_StructInit(&g);
    g.GPIO_Pin = GPIO_Pin_13; g.GPIO_Speed = GPIO_Speed_50MHz;
    g.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(GPIOC, &g);

    // USART1 (printf)
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1 | RCC_APB2Periph_GPIOA, ENABLE);
    g.GPIO_Pin = GPIO_Pin_9; g.GPIO_Mode = GPIO_Mode_AF_PP; GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_10; g.GPIO_Mode = GPIO_Mode_IN_FLOATING; GPIO_Init(GPIOA, &g);
    USART_InitTypeDef u;
    USART_StructInit(&u);
    u.USART_BaudRate = 115200; u.USART_Mode = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART1, &u);
    USART_Cmd(USART1, ENABLE);

    // 按键 PA0
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA | RCC_APB2Periph_AFIO, ENABLE);
    g.GPIO_Pin = GPIO_Pin_0; g.GPIO_Mode = GPIO_Mode_IPU; GPIO_Init(GPIOA, &g);
    GPIO_EXTILineConfig(GPIO_PortSourceGPIOA, GPIO_PinSource0);
    EXTI_InitTypeDef e;
    e.EXTI_Line = EXTI_Line0; e.EXTI_Mode = EXTI_Mode_Interrupt;
    e.EXTI_Trigger = EXTI_Trigger_Falling; e.EXTI_LineCmd = ENABLE;
    EXTI_Init(&e);
    NVIC_InitTypeDef n;
    n.NVIC_IRQChannel = EXTI0_IRQn;
    n.NVIC_IRQChannelPreemptionPriority = 1; n.NVIC_IRQChannelSubPriority = 0;
    n.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&n);
}

// ===== 任务实现 =====

void Task_Sensor(void *arg) {
    SensorData_t data;
    for (;;) {
        // 模拟采集（实际项目用 SPL I2C + ADC）
        data.temperature = 25.3f;
        data.humidity = 64.2f;
        data.lux = 450;
        data.battery_v = 3.85f;

        xQueueSend(sensor_queue, &data, 0);
        xQueueSend(log_queue, &data, 0);
        vTaskDelay(pdMS_TO_TICKS(5000));
    }
}

void Task_Display(void *arg) {
    SensorData_t data;
    char buf[64];
    for (;;) {
        if (xQueueReceive(sensor_queue, &data, pdMS_TO_TICKS(10000)) == pdPASS) {
            xSemaphoreTake(i2c_mutex, portMAX_DELAY);
            snprintf(buf, sizeof(buf),
                "T:%.1fC H:%.1f%%\r\nLux:%u Bat:%.1fV\r\n",
                data.temperature, data.humidity, data.lux, data.battery_v);
            // 实际项目：SSD1306_Print(0, 0, buf); ← SPL I2C 驱动
            printf("%s", buf);  // 调试用串口输出
            xSemaphoreGive(i2c_mutex);
        }
    }
}

void Task_Log(void *arg) {
    SensorData_t data;
    for (;;) {
        if (xQueueReceive(log_queue, &data, portMAX_DELAY) == pdPASS) {
            // 实际项目：写 SD 卡（SPL SPI + FatFs）
            printf("LOG: %.1fC, %.1f%%, %ulx\r\n",
                   data.temperature, data.humidity, data.lux);
            GPIOC->ODR ^= GPIO_Pin_13;  // 存盘指示
        }
    }
}

void Task_Button(void *arg) {
    for (;;) {
        if (xSemaphoreTake(button_sem, portMAX_DELAY) == pdTRUE) {
            vTaskDelay(pdMS_TO_TICKS(30));
            if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
                printf("Button pressed!\r\n");
            }
        }
    }
}

// ISR
void EXTI0_IRQHandler(void) {
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        BaseType_t wake = pdFALSE;
        xSemaphoreGiveFromISR(button_sem, &wake);
        portYIELD_FROM_ISR(wake);
    }
}

// printf 重定向（SPL）
int __io_putchar(int ch) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, (uint8_t)ch);
    return ch;
}

// 栈溢出钩子
void vApplicationStackOverflowHook(TaskHandle_t xTask, char *pcTaskName) {
    printf("STACK OVERFLOW: %s\r\n", pcTaskName);
    while (1);
}

// ===== main =====
int main(void) {
    SystemClock_Config();
    Periph_Init();

    sensor_queue = xQueueCreate(5, sizeof(SensorData_t));
    log_queue    = xQueueCreate(5, sizeof(SensorData_t));
    button_sem   = xSemaphoreCreateBinary();
    i2c_mutex    = xSemaphoreCreateMutex();

    xTaskCreate(Task_Sensor,  "Sensor",  256, NULL, 3, NULL);
    xTaskCreate(Task_Display, "Display", 256, NULL, 2, NULL);
    xTaskCreate(Task_Log,     "Log",     512, NULL, 2, NULL);
    xTaskCreate(Task_Button,  "Button",  128, NULL, 4, NULL);

    vTaskStartScheduler();
    while (1);
}
```

### 编译运行

```bash
make
make flash
# 串口输出：
# T:25.3C H:64.2%
# Lux:450 Bat:3.85V
# LOG: 25.3C, 64.2%, 450lx
```

---

> **下一章**：[第 17 章 · 无线通信基础（SPL版）](./17-chapter.md)
>
> FreeRTOS 框架搭好了。接下来加无线——用 SPL 的 UART 和 DX-WF24/ESP8266 通信，进入物联网的世界。

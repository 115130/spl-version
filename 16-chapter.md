# 第 16 章 · FreeRTOS 实战（SPL版）

> **本章产出**：把上一章的 API 拼成一个可观察的四任务系统，并能在传感器、队列、按键和日志任一环节失败时定位责任边界。
>
> **前置知识**：第 15 章的最小 FreeRTOS 工程；第 8 章 UART 作为日志通道。
>
> **硬件建议**：先只用 LED + UART 跑通任务，再逐个接入传感器、OLED、SD 卡或无线模块。

> 用 FreeRTOS 搭建一个四任务传感器采集系统：SensorTask → Queue → DisplayTask + LogTask，外加按键 ISR → 信号量 → ButtonTask。本章给出教学级的四任务骨架，用来说明任务契约、数据流和失败边界。仓库尚未附带第三方 SPL/FreeRTOS 源码、板卡专属驱动与完整构建文件；不要把本章片段当成“复制后即可编译”的成品工程。

---

## 16.1 四任务架构

## 16.2 教学级实现骨架

```
SensorTask(prio 3, 256w)  ──Queue──→ DisplayTask(prio 2, 256w)
                                      更新 OLED（SPL I2C）

SensorTask ──Queue──→ LogTask(prio 2, 512w)
                      写 SD 卡（SPL SPI）

Button ISR ──Sem──→ ButtonTask(prio 4, 128w)
                    处理按键
```

### 任务与接口骨架

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

## 16.3 编译运行

```bash
make
make flash
# 串口输出：
# T:25.3C H:64.2%
# Lux:450 Bat:3.85V
# LOG: 25.3C, 64.2%, 450lx
```## 16.4 把“能跑”变成“可验证”

四任务架构完成后，至少增加三类健康指标：

| 指标 | 为什么需要 |
|---|---|
| 每个任务的栈高水位 | 发现栈太小，避免随机 HardFault |
| 每个 Queue 的满/丢弃计数 | 判断生产速度是否超过消费速度 |
| 每个外设的错误/重连计数 | 区分硬件故障、协议错误和网络故障 |

建议用一次故障演练验证架构：拔掉传感器、让 WiFi 断线、塞满队列、延长某任务的运行时间。系统不必“毫无错误”，但错误必须被记录、超时并恢复。

## 16.4 从启动到稳定运行的验证

完整代码不能直接等同于完整实验。请拆成以下五个可独立证明的阶段：

| 阶段 | 只验证什么 | 通过证据 |
|---|---|---|
| A | 调度器与两个空任务 | 两个不同周期的 UART 心跳 |
| B | SensorTask → Queue | 消费者看到单调递增的 seq |
| C | Display/Log 消费者 | 同一份样本被正确显示或记录 |
| D | 按键 ISR → 通知 | 快速按键不阻塞采样 |
| E | 故障路径 | 拔掉一个模块/断开网络后其他任务仍运行 |

每增加一层，保留上一层的 UART 日志和计数器。这样出现问题时可以立即知道是“调度器没跑”“消息没到”“设备没响应”还是“业务处理错误”。

推荐给每个模块定义最小状态，而不是用无意义的布尔变量：

~~~c
typedef enum {
    SENSOR_OK,
    SENSOR_TIMEOUT,
    SENSOR_BAD_DATA
} SensorStatus;

typedef struct {
    uint32_t seq;
    SensorStatus status;
    int16_t value;
} SensorEvent;
~~~

消费者看到 `SENSOR_TIMEOUT` 时应记录并继续运行，而不是永久等待一个永远不会到的数据。

## 16.5 故障演练与资源预算

在真实传感器稳定前，先做“主动破坏”：

1. 把 Queue 长度改成 1，故意让消费者慢于生产者，观察满计数；
2. 把某个任务栈调小，在调试构建中确认 overflow hook 能停住；
3. 暂时让 I2C 设备 NACK 或断开 WiFi，确认超时后能恢复；
4. 连续快速触发按键，确认 ISR 不做耗时工作；
5. 运行 30 分钟，记录堆余量、栈高水位、队列深度和错误计数。

| 指标 | 合理的阅读方式 |
|---|---|
| 栈高水位 | 不是“越大越好”；要留下安全余量并说明最坏路径 |
| 剩余 heap | 持续下降通常意味着泄漏或反复分配；不要只看启动瞬间 |
| Queue 满计数 | 说明生产/消费速度或容量设计不匹配 |
| 超时/重连计数 | 区分正常环境波动和持续故障 |
| CPU 忙等比例 | 高优先级任务忙等会掩盖所有其他问题 |

## 16.6 完成检查

- [ ] 每个任务有明确职责和周期；
- [ ] 共享数据通过 Queue、Semaphore 或受保护的接口交接；
- [ ] 任务、队列和缓冲区都有容量说明；
- [ ] 串口能显示栈高水位和关键错误计数；
- [ ] 单个模块失败不会让全部任务永久阻塞。

## 16.7 把教学骨架落成可构建工程：先缩小，再扩展

本节代码刻意把 OLED、SD、I2C、按键等接口留成教学占位。真正工程应先实现一个**只有 LED + UART 的四任务最小版本**，再按文件和里程碑增加外设。推荐的目录不是一份巨大的 `main.c`：

~~~text
16-rtos-pipeline-zet6/
├── README.md                 # 板型、接线、状态：仅骨架/已编译/已烧录
├── Makefile + link.ld
├── platform/                 # 启动文件、SystemClock、SPL 与 FreeRTOS port
├── app/
│   ├── app_types.h           # EnvSample、状态码、容量常量
│   ├── task_sensor.c         # 第一阶段可用模拟值
│   ├── task_log.c            # UART 日志；后续才接 SD
│   ├── task_display.c        # 第一阶段 LED/串口；后续才接 OLED
│   └── task_health.c         # 堆、栈、队列与错误计数
└── drivers/                  # 每个真实外设独立在前置章节验收
~~~

每一阶段的“可运行”含义也应不同：

| 阶段 | 允许依赖 | 最小证据 | 不能声称什么 |
|---|---|---|---|
| A | FreeRTOS + LED + UART | 四任务心跳、Queue 收发、栈高水位 | 传感器/OLED/SD 已经可用 |
| B | 加一种已单独验证的传感器 | 60 秒稳定样本与超时计数 | 多外设长期稳定 |
| C | 加显示或存储其一 | 断开该设备后其他任务继续 | 全系统硬件已验证 |
| D | 加网络 | 断线退避且采样序号不断 | 已适合真实部署 |

### 任务契约必须能落到容量预算

在 ZET6 的 64KB SRAM 内，先写预算再调大常量。下表是记录模板，不是默认数值：

| 对象 | 数量/长度 | 单项字节数 | 预计 RAM | 满/错时行为 |
|---|---:|---:|---:|---|
| Task 栈 | … | … words | … | 高水位低于阈值即报警 |
| `sensor_queue` | … | `sizeof(EnvSample)` | … | 丢新/覆盖/阻塞必须明确 |
| `log_queue` | … | `sizeof(EnvSample)` | … | 记录丢失，不拖住采样 |
| UART/RingBuffer | … | 1 | … | 统计溢出并重同步 |
| FreeRTOS heap | 1 | `configTOTAL_HEAP_SIZE` | … | 分配失败 hook |

完成 A 阶段后，才有资格把 README 标为“已编译”；完成与本书 ZET6 接线一致的板卡实验后，才标为“已烧录”。这两个状态都不应由本章文字替读者宣称。

## 16.8 本章练习与要点

练习：

1. 为 `EnvSample` 增加 `seq` 和状态字段，验证消费者能发现漏包；
2. 将日志任务替换为“只保留最新值”的长度 1 队列，比较它和历史日志队列的取舍；
3. 拔掉一个传感器或让读取函数超时，确保系统仍能输出其他任务的心跳；
4. 写下四个任务各自的输入、输出、最大阻塞时间、优先级和栈预算。

本章要点：

- 完整系统要按任务间的契约验收，不按“有没有一份大代码”验收；
- 数据消息应携带序号、状态与必要的时间信息；
- 队列满、模块超时和断线是设计输入，不是意外；
- 先跑 LED/UART，再逐个接入真实外设，是最有效的集成顺序。



---

> **下一章**：[第 17 章 · 无线通信基础（SPL版）](./17-chapter.md)
>
> FreeRTOS 框架搭好了。接下来加无线——用 SPL 的 UART 和 DX-WF24/ESP8266 通信，进入物联网的世界。

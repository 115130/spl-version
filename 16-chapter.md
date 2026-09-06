# 第 16 章 · FreeRTOS 实战：任务间的数据流（SPL 版）

上一章已经把 FreeRTOS 移植进工程。本章用一个传感器节点练习任务之间的边界：采样任务产生数据，显示和日志任务消费数据，按键 ISR 唤醒按键任务，同时记录队列满、设备超时和栈余量。

先用 LED、UART 和模拟传感器值跑通整个数据流，再逐个接入 OLED、SD 卡和真实传感器。这样某个外设失败时，可以确认调度器和任务通信本身仍然正常。

## 16.1 先定义消息，再拆任务

传感器数据需要带序号和状态。消费者拿到一条消息后，可以判断这是有效样本、超时还是坏数据，也能通过 `seq` 发现中间是否漏过消息。

```c
#include <stdint.h>

typedef enum {
    SENSOR_OK,
    SENSOR_TIMEOUT,
    SENSOR_BAD_DATA
} SensorStatus;

typedef struct {
    uint32_t seq;
    uint32_t tick;
    SensorStatus status;
    int16_t temperature_centi;
    uint16_t humidity_permille;
    uint16_t voltage_mv;
} EnvSample;
```

这里用定点整数保存温度、湿度和电压，日志或显示时再格式化。这样消息结构的大小和数值精度都比较明确，也避免为了几个传感器值把浮点格式化带进每个任务。

本章使用四个任务：

```text
SensorTask
    ├── display_queue ──→ DisplayTask
    └── log_queue ──────→ LogTask

EXTI0 ISR ──notification──→ ButtonTask
```

显示和日志需要独立 Queue。FreeRTOS Queue 的一条消息只能被一次 `xQueueReceive()` 取走；两个消费者如果共用同一个 Queue，会竞争消息，无法保证两边都得到每份样本。

## 16.2 创建 RTOS 对象时检查失败

Queue 和 Task 都可能因为 heap 不足而创建失败。启动阶段应检查返回值，不要带着 NULL 句柄进入调度器。

```c
#include "FreeRTOS.h"
#include "task.h"
#include "queue.h"

#define SAMPLE_QUEUE_LEN  4U

static QueueHandle_t display_queue;
static QueueHandle_t log_queue;
static TaskHandle_t button_task;

static volatile uint32_t display_drop_count;
static volatile uint32_t log_drop_count;

static void App_Fatal(void)
{
    taskDISABLE_INTERRUPTS();
    for (;;) {
        /* 调试构建可在这里停住，由 GDB 查看失败位置。 */
    }
}

static void App_CreateObjects(void)
{
    display_queue = xQueueCreate(SAMPLE_QUEUE_LEN, sizeof(EnvSample));
    log_queue = xQueueCreate(SAMPLE_QUEUE_LEN, sizeof(EnvSample));

    if (display_queue == NULL || log_queue == NULL)
        App_Fatal();
}
```

`SAMPLE_QUEUE_LEN = 4` 是本章实验值。它是否够用取决于采样周期、消费者最长阻塞时间和允许丢多少历史数据。后面会主动让消费者变慢，观察这个容量什么时候被耗尽。

## 16.3 SensorTask：生产数据时不要被慢消费者拖住

采样任务每 1 秒产生一份消息。这里先使用模拟值，真实驱动接入时仍保持同一个 `EnvSample` 接口。

```c
static EnvSample Sensor_Read(uint32_t seq)
{
    EnvSample sample;

    sample.seq = seq;
    sample.tick = xTaskGetTickCount();
    sample.status = SENSOR_OK;
    sample.temperature_centi = 2530;
    sample.humidity_permille = 642;
    sample.voltage_mv = 3300;
    return sample;
}

static void SensorTask(void *argument)
{
    TickType_t last_wake = xTaskGetTickCount();
    uint32_t seq = 0U;

    (void)argument;

    for (;;) {
        EnvSample sample = Sensor_Read(seq++);

        if (xQueueSend(display_queue, &sample, 0U) != pdPASS)
            ++display_drop_count;

        if (xQueueSend(log_queue, &sample, 0U) != pdPASS)
            ++log_drop_count;

        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(1000));
    }
}
```

这里发送 Queue 时不等待。设计目标是显示或日志暂时变慢时，采样任务仍按周期继续运行，并用 drop counter 留下证据。另一个合理设计是允许生产者等待一段时间；选择哪一种要根据业务能否接受漏样本决定。

`vTaskDelayUntil()` 以固定的上次唤醒时间推进周期，比“执行完工作再延时 1 秒”更适合周期采样。如果一次采样本身已经超过周期，还需要额外记录 deadline miss，不能靠 `vTaskDelayUntil()` 消除超时。

## 16.4 DisplayTask 和 LogTask：慢操作留在消费者

显示任务阻塞等待新样本。OLED 驱动应保留第 10 章的 I2C 超时，设备 NACK 时返回错误，不能让任务永久卡在底层 `while`。

```c
static void DisplayTask(void *argument)
{
    EnvSample sample;

    (void)argument;

    for (;;) {
        if (xQueueReceive(display_queue, &sample, portMAX_DELAY) == pdPASS) {
            if (sample.status == SENSOR_OK) {
                Display_ShowSample(&sample);
            } else {
                Display_ShowSensorError(sample.status);
            }
        }
    }
}
```

日志任务同样独立消费自己的 Queue：

```c
static volatile uint32_t log_error_count;

static void LogTask(void *argument)
{
    EnvSample sample;

    (void)argument;

    for (;;) {
        if (xQueueReceive(log_queue, &sample, portMAX_DELAY) == pdPASS) {
            if (!Log_AppendSample(&sample))
                ++log_error_count;
        }
    }
}
```

`Log_AppendSample()` 可以先只写 UART。接入 SD/FatFs 后，再替换成第 13 章已经验证过的日志接口。文件系统和块设备访问集中在 `LogTask`，可以避免多个任务同时操作同一个 `FIL` 或 SDIO/SPI 数据通道。

如果显示只关心最新状态，不需要每一份历史样本，可以把显示通道改成长度 1 的 Queue，并使用 `xQueueOverwrite()`。日志通常需要保留历史记录，因此它的满队列策略应单独设计。

## 16.5 按键：ISR 只通知任务

PA0 的 EXTI 配置沿用第 6 章，但中断优先级必须符合第 15 章的 FreeRTOS syscall priority 规则。这里假设启动代码已经完成正确的 NVIC 配置。

一对一的按键事件可以直接使用 Task Notification：

```c
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

任务收到通知后再做消抖和业务处理：

```c
static void ButtonTask(void *argument)
{
    (void)argument;

    for (;;) {
        (void)ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        vTaskDelay(pdMS_TO_TICKS(30));

        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET)
            App_HandleButtonPress();
    }
}
```

30 ms 是实验消抖窗口，不是所有按键的固定参数。可以用示波器或逻辑分析仪观察实际抖动，再调整时间或改成状态机消抖。

Notification 的计数可以记录任务处理前累计到来的多次通知，但这里延时后只检查一次 GPIO，因此它仍是“确认当前按下状态”的按键逻辑，不等于精确统计每个机械边沿。

## 16.6 共享外设要有唯一访问规则

如果只有 `DisplayTask` 使用 I2C，就不需要再加 Mutex。多任务共享同一个 I2C 控制器时，可以使用 Mutex 把一整个 I2C 事务保护起来：

```c
static SemaphoreHandle_t i2c_mutex;

bool SharedI2C_Write(const uint8_t *data, size_t len)
{
    bool ok;

    if (xSemaphoreTake(i2c_mutex, pdMS_TO_TICKS(50)) != pdTRUE)
        return false;

    ok = I2C_DeviceWrite(data, len);
    xSemaphoreGive(i2c_mutex);
    return ok;
}
```

锁的范围覆盖一次完整事务，不能只保护单个寄存器写。底层 I2C 函数本身仍要有超时，否则持锁任务卡死后，所有等待这个 Mutex 的任务都会一起停住。

另一个方案是创建专门的 I2C 服务任务，其他任务通过 Queue 提交请求。设备多、事务复杂时，这种方式能把总线所有权集中到一个地方；代价是请求结构和响应机制会更复杂。

## 16.7 创建任务并启动

先初始化时钟、UART、LED 和按键，再创建 RTOS 对象与任务。OLED、SD 和真实传感器暂时不接入。

```c
int main(void)
{
    BaseType_t ok;

    SystemClock_Config();
    Board_Init();
    Console_Init();
    ButtonExti_Init();

    App_CreateObjects();

    ok = xTaskCreate(SensorTask, "sensor", 256U, NULL, 3U, NULL);
    if (ok != pdPASS)
        App_Fatal();

    ok = xTaskCreate(DisplayTask, "display", 256U, NULL, 2U, NULL);
    if (ok != pdPASS)
        App_Fatal();

    ok = xTaskCreate(LogTask, "log", 384U, NULL, 2U, NULL);
    if (ok != pdPASS)
        App_Fatal();

    ok = xTaskCreate(ButtonTask, "button", 192U, NULL, 4U, &button_task);
    if (ok != pdPASS)
        App_Fatal();

    vTaskStartScheduler();
    App_Fatal();
}
```

这里的 `256U`、`384U`、`192U` 都是 stack depth，单位为 `StackType_t` 元素，不是字节。这些数值只是起始实验配置；接入 `printf`、FatFs 或较大的局部缓冲后，要重新测量高水位。

`vTaskStartScheduler()` 正常启动后不会返回。如果返回，常见原因是内核启动所需内存分配失败；调试时应结合 malloc failed hook、剩余 heap 和链接 map 定位。

## 16.8 日志本身也有并发边界

原型阶段常让多个任务直接 `printf()`。这样很快会遇到两个问题：C 库格式化是否可重入，以及多个任务的字符输出是否会交错。

本章建议让普通任务把日志消息交给单独的日志通道，最终由一个任务写 USART。最简单的教学版本也至少要保证一次完整日志记录不会被另一个任务插入一半。

ISR 中不要调用 `printf()`。栈溢出和 malloc failed hook 也不应依赖可能持锁、分配内存或阻塞的日志路径。调试 hook 可以关中断后点亮固定错误 LED，并由 GDB 查看现场。

## 16.9 给系统留下可观察状态

运行时至少记录：

```c
typedef struct {
    uint32_t display_drops;
    uint32_t log_drops;
    uint32_t log_errors;
    uint32_t sensor_timeouts;
} AppHealth;
```

任务栈使用 `uxTaskGetStackHighWaterMark()` 观察；heap 可以用 `xPortGetFreeHeapSize()`，如果所选 heap 实现支持，还可以记录历史最小剩余量。Queue 当前深度可用 `uxQueueMessagesWaiting()` 作为调试信息。

这些指标要结合故障演练看。Queue drop 一直增加说明生产速度、消费速度或容量不匹配；传感器 timeout 增长说明设备或驱动路径有问题；栈高水位过低则需要检查局部数组、格式化函数和最深调用路径。

## 16.10 分阶段接入真实外设

不要一次把四个任务和所有驱动一起打开。按下面顺序验证：

1. **调度器**：两个不同周期的 LED/UART 心跳持续运行。
2. **Queue**：SensorTask 产生递增 `seq`，消费者确认没有异常跳号。
3. **四任务骨架**：显示和日志仍使用 UART/LED 占位，按键 ISR 能唤醒 ButtonTask。
4. **真实传感器**：拔掉传感器后返回 `SENSOR_TIMEOUT`，其他任务继续运行。
5. **OLED**：断开 I2C 设备后 DisplayTask 超时返回，SensorTask 和 LogTask 不停。
6. **SD/FatFs**：让写入失败或拔卡，LogTask 记录错误，采样仍继续。

每加一个设备，只替换一个已经有明确输入输出的接口。这样故障范围不会从一个驱动突然扩大到整个系统。

## 16.11 压力测试

把 `SAMPLE_QUEUE_LEN` 暂时改成 1，并在 `LogTask` 中加入明显长于采样周期的测试延时。`log_drop_count` 应开始增加，而 SensorTask 的 `seq` 仍继续递增。这能直接验证“日志变慢不会拖住采样”这个设计。

随后恢复正常配置，连续运行一段时间，记录：

- 每个任务的栈高水位；
- 当前和历史最小剩余 heap；
- 两个 Queue 的深度和 drop counter；
- 传感器、I2C、SD 的 timeout/error counter；
- SensorTask 的周期和最大执行时间。

运行时长应根据系统用途决定。本章不把“运行 10 分钟”或“30 分钟没死机”当成稳定性的固定证明；压力测试需要覆盖预期的最坏负载和故障路径。

## 16.12 练习

1. 给 `EnvSample` 增加 ADC 原始值，在 DisplayTask 中显示换算后的电压，同时让 LogTask 保存原始值和换算值。
2. 把 `display_queue` 改成长度 1，并使用 `xQueueOverwrite()`；让 DisplayTask 故意变慢，验证它最终显示最新样本。
3. 给 SensorTask 增加执行时间统计，构造一次超过 1 秒周期的读取，记录 deadline miss。
4. 给 UART 日志增加单独的 LogConsoleTask，其他任务只提交完整日志消息，验证多任务日志不会交错。
5. 写出四个任务的输入、输出、最大允许阻塞时间、优先级依据和栈高水位，并放进项目 README。

完成本章后，四任务系统应能回答几个具体问题：哪条 Queue 满了、哪个设备超时、哪个任务栈接近上限，以及一个慢消费者是否影响采样周期。第 17 章加入无线模块时，网络断线和 AT 命令超时也沿用同样的任务边界处理。

> **上一章**：[第 15 章 · FreeRTOS 核心 API 与手动移植](./15-chapter.md)
>
> **下一章**：[第 17 章 · 无线通信基础](./17-chapter.md)

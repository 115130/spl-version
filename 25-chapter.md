# 第 25 章 · 综合项目一：智能环境监测节点（SPL版）

> **本章产出**：把前面学过的 ADC、I2C、SPI、UART、FreeRTOS 和 MQTT 组织成一个可分阶段完成的环境监测节点。
>
> **前置知识**：第 9–16 章外设与 FreeRTOS，以及第 21 章 MQTT。
>
> **项目目标**：采集环境数据、在 OLED 显示、记录到 SD 卡，并定时上报云端。

---

## 25.1 不要一上来就做“全功能设备”

综合项目最常见的失败方式是：第一天同时接传感器、OLED、SD 卡、WiFi 和云平台，最后不知道是哪一层坏了。

本项目按四个可验证里程碑推进：

| 里程碑 | 完成标准 |
|---|---|
| M1：本地采样 | 串口每秒打印温湿度和电池电压 |
| M2：本地显示 | OLED 每秒更新一次，按键可切换页面 |
| M3：本地存储 | SD 卡生成按行记录的数据文件 |
| M4：云端上报 | MQTT 每分钟发布一次完整数据 |

只有当前一项稳定后，再进入下一项。

## 25.2 硬件清单与接口规划

| 功能 | 建议器件 | 接口 | 备注 |
|---|---|---|---|
| 温湿度 | DHT11 / DHT22 或 NTC | 单线 / ADC | 先选择一种 |
| 光照 | BH1750 | I2C1 | 可与 OLED 共线 |
| 显示 | SSD1306 OLED | I2C1 | 需要上拉电阻 |
| 存储 | MicroSD | SPI1 | 初始化阶段低速 |
| 网络 | ESP8266 AT 或兼容模块 | USART2 | 需独立供电与共地 |
| 调试 | USB-TTL | USART1 | 不要与网络串口混用 |
| 电池检测 | 分压电路 | ADC1 | 注意电压范围 |

本书固定使用 STM32F103ZET6：Flash 512KB、SRAM 64KB、High Density 启动文件和 STM32F10X_HD 宏。项目中的链接脚本、引脚表和构建参数都以这套配置为准。

## 25.3 任务架构

~~~text
Task_Sensor (prio 3)
  └─ 采样 → Queue_Sample

Task_Display (prio 2)
  └─ 读取最新样本 → OLED

Task_SDLog (prio 2)
  └─ Queue_Sample → CSV / JSONL 文件

Task_MQTT (prio 3)
  └─ Queue_Sample → WiFi → Broker

Button ISR
  └─ 二值信号量 → Task_UI
~~~

先让采样任务产生统一的数据结构，其余任务只消费它：

~~~c
typedef struct {
    uint32_t seq;
    int16_t  temperature_centi;
    uint16_t humidity_centi;
    uint16_t light_lux;
    uint16_t battery_mv;
} EnvSample;
~~~

使用整数保存 24.63°C 为 2463，可以避免在没有硬件 FPU 的 Cortex-M3 上到处使用浮点格式化。

## 25.4 初始化顺序

推荐的启动顺序：

1. 时钟、GPIO、USART1 调试输出；
2. 创建日志接口，确认每一步失败都可见；
3. ADC、I2C、SPI 等本地外设；
4. UART2 与接收中断；
5. 创建 Queue、Semaphore、FreeRTOS 任务；
6. 启动调度器；
7. 在网络任务中异步配网和连接 MQTT。

UART 接收中断不仅要调用 USART_ITConfig，还必须初始化 NVIC：

~~~c
static void USART2_IRQ_Init(void)
{
    NVIC_InitTypeDef nvic;

    USART_ITConfig(USART2, USART_IT_RXNE, ENABLE);

    nvic.NVIC_IRQChannel = USART2_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 2;
    nvic.NVIC_IRQChannelSubPriority = 0;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}
~~~

把“网络没有连接”当作正常状态，而不是系统启动失败。这样传感器、显示与本地存储仍可以继续工作。

## 25.5 采样任务

采样任务不应直接调用 MQTT 或 FatFs。它只做“得到一份可信样本，然后送到队列”。

~~~c
static void Task_Sensor(void *arg)
{
    EnvSample sample = {0};

    for (;;) {
        sample.seq++;
        sample.temperature_centi = NTC_ReadCentiC();
        sample.humidity_centi = DHT_ReadHumidityCenti();
        sample.light_lux = BH1750_ReadLux();
        sample.battery_mv = Battery_ReadMilliVolt();

        xQueueOverwrite(q_latest_sample, &sample);
        xQueueSend(q_log_sample, &sample, 0);
        xQueueSend(q_cloud_sample, &sample, 0);

        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
~~~

这里使用三个队列只是为了说明“最新显示、完整日志、云端发送”的需求不同。实际项目可根据 RAM 选择更小的队列或共享最新样本。

## 25.6 验证计划

| 测试 | 预期结果 |
|---|---|
| 拔掉 WiFi 模块 | 显示和 SD 卡仍正常 |
| 拔掉 SD 卡 | 传感器和云端上报仍正常，日志任务报错后重试 |
| 模拟 I2C 设备未响应 | 任务超时返回，不永久卡住 |
| 断开 Broker | 网络任务退避重连，不阻塞采样 |
| 连续运行 8 小时 | seq 持续递增，无队列溢出和栈水位异常 |

先做故障测试，才能确认各个任务真的解耦。

## 25.7 本章练习

1. 只实现 M1，并把数据格式固定下来；
2. 为每个任务打印一次启动日志和高水位栈余量；
3. 让 MQTT 断线时把数据暂存到 SD 卡；
4. 写一个 Python 小脚本读取日志文件并画温度曲线。

## 25.8 参考任务契约：先固定数据，再写驱动

综合项目最有价值的产物不是某一个传感器函数，而是一份在各任务之间稳定流动的数据契约：

~~~c
typedef enum {
    ENV_OK            = 0,
    ENV_SENSOR_ERROR  = 1u << 0,
    ENV_STORAGE_ERROR = 1u << 1,
    ENV_NETWORK_ERROR = 1u << 2
} EnvFlags;

typedef struct {
    uint32_t seq;
    uint32_t tick;
    int16_t temperature_centi;
    uint16_t humidity_centi;
    uint16_t light_lux;
    uint16_t flags;
} EnvSample;
~~~

| 任务 | 输入 | 输出 | 最大阻塞时间 | 满/错时策略 |
|---|---|---|---|---|
| SensorTask | 定时 tick、设备驱动 | `EnvSample` | 单次采样超时 | 带状态发布，不永久等待 |
| DisplayTask | 最新 sample | OLED | 一次 I2C 超时 | 保留旧值并显示错误标识 |
| LogTask | 顺序 sample | SD/Flash | 单次写入超时 | 批量、CRC、失败计数 |
| NetworkTask | sample/缓存 | MQTT/HTTP | 网络超时 | 退避、重连、不阻塞采样 |
| HealthTask | 各计数器 | UART/OLED | 很短 | 只观察不控制业务 |

显示只需要最新数据时，使用长度为 1 的覆盖队列；日志需要顺序时，使用有容量的队列并记录溢出。这两个需求不能用同一条“万能队列”含糊处理。

## 25.9 分层联调与故障注入

| 测试 | 操作 | 预期结果 |
|---|---|---|
| 采样连续性 | WiFi 断开 5 分钟 | `seq` 继续增长，网络错误计数增加 |
| 存储边界 | 塞满日志队列或模拟写失败 | 采样任务仍按周期运行 |
| I2C 错误 | 拔掉 OLED 或传感器 | 其他任务心跳和错误状态仍可见 |
| 网络恢复 | 恢复 Broker/路由器 | 有限退避后恢复，不产生重连风暴 |
| 内存稳定 | 连续运行 30 分钟 | heap、栈高水位无持续恶化 |
| 冷启动 | 断电重启 | 配置、日志扫描和传感器初始化可重复 |

建议每次只引入一个外设：LED/UART → 一个传感器 → OLED → 存储 → 网络。每一阶段提交一次可运行版本，并保存接线图和串口日志。

练习：实现一个 HealthTask，每 10 秒打印任务栈余量、采样序号、队列满计数、存储错误和网络重连次数。它是你后面排查“项目偶尔死掉”时最有价值的证据。

## 25.10 启动顺序与最小主程序骨架

综合工程要把“板级初始化成功”与“某项业务成功”分开。推荐启动顺序：

~~~c
int main(void)
{
    SystemClock_Config();     /* 已在第 5 章独立验证 */
    Board_SafeOutputs();      /* 默认让执行器/CS 处于安全状态 */
    UART_DebugInit();         /* 先建立观察口 */
    HealthCounters_Init();

    SensorBus_Init();         /* 每个驱动返回明确成功/失败 */
    Storage_Init();
    Radio_Init();

    sample_q = xQueueCreate(8, sizeof(EnvSample));
    latest_q = xQueueCreate(1, sizeof(EnvSample));
    if (sample_q == NULL || latest_q == NULL)
        App_Fatal("queue-init");

    xTaskCreate(SensorTask,  "sensor",  STACK_SENSOR,  NULL, PRIO_SENSOR,  NULL);
    xTaskCreate(DisplayTask, "display", STACK_DISPLAY, NULL, PRIO_DISPLAY, NULL);
    xTaskCreate(LogTask,     "log",     STACK_LOG,     NULL, PRIO_LOG,     NULL);
    xTaskCreate(NetworkTask, "net",     STACK_NETWORK, NULL, PRIO_NETWORK, NULL);
    xTaskCreate(HealthTask,  "health",  STACK_HEALTH,  NULL, PRIO_HEALTH,  NULL);

    vTaskStartScheduler();
    for (;;); /* 只有调度器无法启动时才会走到这里 */
}
~~~

骨架中的函数名不是现成库。它们的意义是让每一步都有名字、返回值和日志。不要在 `main()` 中默默初始化 20 个设备，然后在第一个错误上继续运行。

### 硬件联调表

| 接口 | 最小验证 | 不通过时先回退 |
|---|---|---|
| ADC 传感器 | UART 打印原始值 + 万用表趋势 | 第 9 章 |
| I2C OLED/传感器 | 单设备 ACK、固定显示 | 第 10 章 |
| SPI 存储 | 写入/读回固定记录 | 第 11/13 章 |
| USART WiFi | `AT` → `OK`、错误计数 | 第 17 章 |
| MQTT/HTTP | PC 教学 Broker/服务回包 | 第 21/23 章 |
| FreeRTOS | 栈高水位、Queue 满计数 | 第 15/16 章 |

练习：为每个 `*_Init()` 规定一个错误码和一条脱敏 UART 日志。冷启动失败时，你应该能从第一条错误直接知道回退到哪一章。

## 25.11 把“接口规划”变成 ZET6 资源表、数据格式和验收映射

前面的接口表只说明“想接什么”；真正接线前还要把每个资源唯一地分配到 ZET6，并用开发板原理图确认没有被板载外设占用。以下是本书的**默认教学映射**，不是对所有 ZET6 开发板的承诺：

| 功能 | 默认引脚/资源 | 同类冲突 | 接线前必须确认 |
|---|---|---|---|
| 调试 UART | USART1：PA9/PA10 | 不能与 WiFi 共用一根 UART | USB-TTL 是 3.3V、TX/RX 交叉、已共地 |
| WiFi AT | USART2：PA2/PA3 | 接收缓冲/DMA/中断优先级 | 模块供电峰值、固件 AT 能力 |
| I2C 传感器 + OLED | I2C1：PB6/PB7 | 同一总线地址/上拉/总线占用 | 每个地址唯一、上拉存在、拔设备可恢复 |
| SD 卡 | SPI1：PA4/PA5/PA6/PA7 | OLED 若也走 SPI 必须独立 CS | CS 默认高、初始化低速、卡供电稳定 |
| 电池/模拟采样 | ADC1：例如 PA1 | 模拟源阻抗与量程 | 分压不超过参考电压、采样时间足够 |
| 板载提示 | 常见 PC13 | 板卡 LED 可能低电平点亮 | 实际丝印/原理图 |

### 离线日志必须有格式与上限

WiFi 断开时不能无限往 RAM 或 SD 卡堆数据。先定义一条日志记录的版本、长度、状态和 CRC，再决定保留策略：

~~~c
typedef struct {
    uint16_t magic;
    uint8_t  version;
    uint8_t  length;
    uint32_t seq;
    uint32_t tick;
    uint16_t flags;
    /* EnvSample payload + crc */
} EnvLogHeader;
~~~

写入失败、SD 卡缺失、文件满和重启扫描都应该产生 `ENV_STORAGE_ERROR`，但不得让 `SensorTask` 停止采样。项目 README 要说明：离线最多保存多少条、满时丢旧还是丢新、恢复联网后如何限速回传。

### 用 M1–M4 逐项验收，不跳关

| 里程碑 | 只新增的能力 | 通过证据 | 故障注入 |
|---|---|---|---|
| M1 | 一种传感器 + UART | 60 秒连续样本、单位/状态正确 | 断开传感器，采样仍有心跳 |
| M2 | I2C OLED | 固定页面与错误标记 | 拔 OLED，采样不停止 |
| M3 | SPI/SD 日志 | 写入、读回、重启后扫描 | 拔卡/写失败，错误可见 |
| M4 | WiFi + MQTT | seq、重连、上报限制可见 | 断网 5 分钟，缓存与采样策略符合文档 |

每完成一关，就保存一次接线图、固件 SHA、串口日志和资源使用记录。它们是下一章排查“综合项目偶发失败”时最有用的回归证据。

## 25.12 本章要点

- 综合项目靠里程碑推进，而不是一次性拼接所有模块；
- 采样数据要有统一结构，任务之间使用 Queue 交接；
- 网络和存储都可能失败，不能拖垮本地采样；
- ISR、驱动、协议和应用逻辑需要分层；
- 可验证的故障测试与功能测试同样重要。

---

[上一章：第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

[下一章：第 26 章 · 综合项目二：BLE 智能门锁](./26-chapter.md)

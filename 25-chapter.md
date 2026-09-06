# 第 25 章 · 综合项目一：智能环境监测节点（SPL 版）

这一章把已经验证过的传感器、OLED、SD/FatFs、FreeRTOS 和 MQTT 接成一个环境监测节点。集成时重点检查任务边界：WiFi 断开、SD 卡故障或单个传感器超时，都不能让周期采样一起停掉。

项目按四个里程碑推进：M1 采样、M2 显示、M3 存储、M4 网络。每一步通过故障测试以后再加入下一层。

## 25.1 先确认硬件资源

本书 MCU 是 STM32F103ZET6。下面的引脚只作为教学映射，接线前仍要核对开发板原理图和已有外设占用。

| 功能 | 教学资源 | 接线前检查 |
|---|---|---|
| 调试串口 | USART1：PA9/PA10 | USB-TTL 电平、TX/RX 交叉、共地 |
| WiFi AT | USART2：PA2/PA3 | 供电、UART 电平、AT 固件能力 |
| OLED + BH1750 | I2C1：PB6/PB7 | 地址、上拉、总线占用 |
| SD 卡 | SPI1：PA4/PA5/PA6/PA7 | CS、初始化时钟、供电、板载占用 |
| 电池采样 | ADC1，例如 PA1 | 分压范围、源阻抗、采样时间 |
| 温湿度 | 已验证的传感器接口 | 复用前面通过测试的驱动 |

综合项目先复用已经单独通过测试的器件。若某块开发板的板载 Flash、LED 或其他功能占用了表中引脚，就按原理图重新分配，并同步修改资源文档。

## 25.2 所有消费者使用同一份样本

定义稳定的值类型：

```c
typedef enum {
    ENV_STATUS_TEMP_ERROR  = 1U << 0,
    ENV_STATUS_HUM_ERROR   = 1U << 1,
    ENV_STATUS_LIGHT_ERROR = 1U << 2,
    ENV_STATUS_BATT_ERROR  = 1U << 3
} EnvStatus;

typedef struct {
    uint32_t seq;
    uint32_t tick;
    int16_t  temperature_centi;
    uint16_t humidity_permille;
    uint16_t light_lux;
    uint16_t battery_mv;
    uint16_t status;
} EnvSample;
```

`temperature_centi = 2463` 表示 24.63 °C，`humidity_permille = 583` 表示 58.3% RH。读取失败时设置对应状态位；消费者先看状态，再决定是否使用该字段。

`seq` 每生成一份样本递增一次。日志和云端都保留它，后续可以用跳号发现 Queue 丢弃或其他数据缺口。

## 25.3 一份样本分别送给三个消费者

FreeRTOS Queue 的消息被一个消费者取走后就从该 Queue 删除，因此显示、日志和网络不能竞争同一条 Queue。本项目使用三条通路：

```text
                    ┌→ latest_display_q ─→ DisplayTask
SensorTask ─ sample ├→ log_q ────────────→ LogTask
                    └→ cloud_q ──────────→ NetworkTask
```

`latest_display_q` 长度为 1，用 `xQueueOverwrite()` 保存最新样本。`log_q` 和 `cloud_q` 保持顺序；本章第一版在满时丢新并分别增加 `log_drop`、`cloud_drop`，SensorTask 不等待消费者腾空间。

若需求改成“断网期间每条样本最终上传”，`cloud_q` 只能承担短期缓冲。长时间离线要把持久日志纳入补传流程，并定义服务端确认、重复数据和本地删除条件。

## 25.4 五个任务各管一件事

```text
SensorTask   周期产生 EnvSample
DisplayTask  显示最新样本
LogTask      顺序写 SD/FatFs
NetworkTask  独占 WiFi AT，维护 TCP/MQTT
HealthTask   汇总队列、驱动、网络和资源计数
```

按键如果只切换页面，可以由 EXTI ISR 通过 Task Notification 通知显示逻辑。ISR 不刷 OLED，也不访问 FatFs 或 WiFi。

任务优先级根据周期、最坏执行时间和阻塞关系确定。先保证驱动都有有限超时，再通过压力测试检查某个任务是否长期拿不到 CPU；不靠固定的“传感器必须高两级”规则。

## 25.5 SensorTask 保持固定的数据生产节奏

```c
static void SensorTask(void *arg)
{
    TickType_t wake = xTaskGetTickCount();
    EnvSample sample = {0};

    for (;;) {
        sample.seq++;
        sample.tick = xTaskGetTickCount();
        sample.status = 0U;

        if (!Temp_ReadCenti(&sample.temperature_centi))
            sample.status |= ENV_STATUS_TEMP_ERROR;

        if (!Humidity_ReadPermille(&sample.humidity_permille))
            sample.status |= ENV_STATUS_HUM_ERROR;

        if (!BH1750_ReadLux(&sample.light_lux))
            sample.status |= ENV_STATUS_LIGHT_ERROR;

        if (!Battery_ReadMilliVolt(&sample.battery_mv))
            sample.status |= ENV_STATUS_BATT_ERROR;

        xQueueOverwrite(latest_display_q, &sample);

        if (xQueueSend(log_q, &sample, 0U) != pdPASS)
            health.log_drop++;

        if (xQueueSend(cloud_q, &sample, 0U) != pdPASS)
            health.cloud_drop++;

        vTaskDelayUntil(&wake, pdMS_TO_TICKS(1000U));
    }
}
```

1 s 是本项目的初始采样周期。要实测一次完整采样的最坏执行时间；如果它接近或超过周期，`vTaskDelayUntil()` 不会替任务补出空闲时间，任务会持续落后。DS18B20 这类有明显转换等待的器件可以拆成“启动转换”和“稍后读取”两个阶段。

SensorTask 不调用 MQTT 或 FatFs。单个传感器失败时仍产生一份带状态位的样本，让显示、日志和健康统计看到故障。

## 25.6 LogTask 定义何时算写入完成

日志至少保存格式版本、`seq`、时间基准、状态和传感器字段。CSV/JSONL 便于人工查看，二进制格式节省空间；选定以后要固定记录格式、文件轮换和损坏恢复规则。

FatFs 的 `f_write()` 成功不等于数据已经安全落到物理介质。`f_sync()` 可以推进文件系统和底层介质的同步，但具体掉电保证还取决于 SD 卡控制器、缓存和供电。本项目通过断电测试决定可接受的同步间隔。

SD 卡拔出、文件系统错误或写超时只改变 LogTask 的存储状态和计数。SensorTask 不等待 SD 卡恢复。

如果日志还承担离线补传，需要另外保存上传状态。MQTT 发送接口成功、模块 `SEND OK` 或 QoS 1 PUBACK 各自有不同语义；只有项目定义的确认条件满足后，才能把对应本地记录标记为可删除。

## 25.7 NetworkTask 独占 WiFi AT

网络状态沿用前面的结构：

```text
RADIO_INIT
    ↓
WIFI_JOIN
    ↓
TCP_CONNECT
    ↓
MQTT_CONNECT
    ↓
ONLINE ── cloud_q → PUBLISH
    │
    └─ 断线 / 超时 → BACKOFF → 重连
```

断网时 SensorTask 和 LogTask 继续运行。`cloud_q` 满以后执行本章规定的丢新策略；如果启用持久补传，则把离线数据的唯一来源和所有权写清楚，避免 RAM Queue 与 SD 日志各自重复上传同一条记录却没有去重依据。

恢复连接后可以限制补传速率，避免历史数据长时间占满链路，使实时遥测和 MQTT Keep Alive 得不到处理。若要求端到端确认，使用业务 `seq` 和服务端 ACK 定义完成条件。

## 25.8 启动时区分致命错误和设备故障

时钟、RTOS 对象或关键内存创建失败通常无法继续运行；WiFi、SD 卡、OLED 或单个传感器离线则可以让对应任务进入故障状态，调度器仍然启动。

```c
int main(void)
{
    SystemClock_Config();
    Board_SafeOutputs();
    UART_DebugInit();
    HealthCounters_Init();

    Board_PeripheralsInit();

    latest_display_q = xQueueCreate(1U, sizeof(EnvSample));
    log_q = xQueueCreate(LOG_QUEUE_LEN, sizeof(EnvSample));
    cloud_q = xQueueCreate(CLOUD_QUEUE_LEN, sizeof(EnvSample));

    if (latest_display_q == NULL || log_q == NULL || cloud_q == NULL)
        App_Fatal("queue-init");

    if (xTaskCreate(SensorTask, "sensor", STACK_SENSOR,
                    NULL, PRIO_SENSOR, NULL) != pdPASS)
        App_Fatal("sensor-task");

    if (xTaskCreate(DisplayTask, "display", STACK_DISPLAY,
                    NULL, PRIO_DISPLAY, NULL) != pdPASS)
        App_Fatal("display-task");

    if (xTaskCreate(LogTask, "log", STACK_LOG,
                    NULL, PRIO_LOG, NULL) != pdPASS)
        App_Fatal("log-task");

    if (xTaskCreate(NetworkTask, "net", STACK_NETWORK,
                    NULL, PRIO_NETWORK, NULL) != pdPASS)
        App_Fatal("net-task");

    if (xTaskCreate(HealthTask, "health", STACK_HEALTH,
                    NULL, PRIO_HEALTH, NULL) != pdPASS)
        App_Fatal("health-task");

    vTaskStartScheduler();
    App_Fatal("scheduler-returned");
}
```

`STACK_*` 的单位是 `StackType_t` 元素。初始值根据调用链和局部变量估算，再用 high-water mark 和故障压力测试调整。

## 25.9 HealthTask 记录能定位故障的指标

至少保留：

```text
sample_seq=...
sensor_timeout=...
i2c_error=...
log_drop=...
storage_error=...
cloud_drop=...
radio_rx_overflow=...
mqtt_reconnect=...
mqtt_publish_fail=...
heap_free=...
stack_sensor_min=...
stack_log_min=...
stack_net_min=...
```

Queue 除当前占用外，再记录运行期间的最大占用。这样可以发现已经过去的突发积压。

多个任务更新统计时按实际并发模型处理。可以让各任务维护自己的计数器，由 HealthTask 读取；需要一致快照的多字段数据再使用短临界区或其他同步方式。给整个结构加 `volatile` 不会产生一致快照。

## 25.10 按 M1 到 M4 集成

**M1：采样。** 只启用 SensorTask 和调试输出。检查 `seq`、单位、状态位和实际周期；断开传感器，任务仍持续生成错误状态样本。

**M2：显示。** 加 OLED 和 `latest_display_q`。制造 I2C 超时，确认 `sample.seq` 继续增长；显示恢复后直接显示最新样本。

**M3：存储。** 加 LogTask 和 SD 卡。测试正常写、拔卡、重新挂载、写失败和断电重启。Queue 满时要有明确计数，SensorTask 周期不被拖慢。

**M4：网络。** 最后加入 WiFi/MQTT。停止 Broker、断开 AP、复位无线模块，检查 NetworkTask 的统一重连路径。实现补传后，再测试大量历史数据存在时实时样本和 Keep Alive 仍能处理。

每完成一个里程碑，保存当前固件 commit SHA、资源映射和关键测试日志。发生回归时可以直接比较相邻里程碑。

## 25.11 故障测试覆盖具体机制

至少测试这些路径：

- WiFi 断开时 `sample_seq` 继续递增，`cloud_drop` 或离线缓存按策略变化；
- SD 卡拔出时显示和网络继续运行，`storage_error` 增加；
- I2C 设备无响应时驱动在规定超时内返回；
- 人为缩短 `log_q`、`cloud_q` 后能稳定触发满队列计数；
- Broker 恢复后只有 NetworkTask 操作 AT 并执行重连；
- 连续注入网络、JSON 和存储错误后，heap 与任务栈水位没有持续恶化；
- 断电重启后，日志和配置回到文档定义的状态。

运行时长要覆盖日志轮换、最大网络退避、缓存回放等长周期行为。很难等待的故障可以通过缩短测试参数或故障注入单独验证，不用只靠长时间空跑判断稳定性。

## 25.12 本章完成标准

项目 README 至少写清这些边界：

- 硬件资源、驱动和任务的所有者；
- `EnvSample` 字段单位与错误状态；
- 三条 Queue 的容量和满队列策略；
- WiFi、SD、OLED、传感器故障时哪些功能继续运行；
- 离线数据容量、满后的处理方式和补传策略；
- 一条本地记录满足什么条件后可以删除；
- 任务栈水位、Queue 丢弃和关键驱动错误从哪里查看。

这些路径都能通过故障测试复现后，第一个综合项目就完成了。下一章加入执行器和 BLE 命令，重点会转到命令权限、重复请求和安全输出状态。

> **上一章**：[第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)
>
> **下一章**：[第 26 章 · 综合项目二：BLE 智能门锁](./26-chapter.md)

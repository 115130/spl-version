# 第 25 章 · 综合项目一：智能环境监测节点（SPL 版）

这一章把前面已经验证过的传感器、OLED、SD 卡、FreeRTOS 和 MQTT 接成一个完整节点。重点是任务边界和故障隔离：网络断开、SD 卡拔出或某个传感器超时，都不能让采样任务一起停掉。

项目分四步完成：

1. **M1 本地采样**：串口持续输出带状态的环境样本；
2. **M2 本地显示**：OLED 显示最新样本，显示故障不影响采样；
3. **M3 本地存储**：SD 卡按顺序记录样本，拔卡后系统继续运行；
4. **M4 网络上报**：MQTT 发布遥测，断网后按既定缓存策略处理。

每一步都先留下可重复的测试结果，再接下一块硬件。

## 25.1 先固定硬件资源

本书 MCU 是 STM32F103ZET6。下面是一套教学映射，实际接线仍以手里的开发板原理图为准，尤其要确认板载 Flash、LED、按键或其他外设有没有占用相同引脚。

| 功能 | 默认资源 | 接线前检查 |
|---|---|---|
| 调试串口 | USART1：PA9/PA10 | USB-TTL 电平、TX/RX 交叉、共地 |
| WiFi AT | USART2：PA2/PA3 | 模块供电、UART 电平、AT 固件能力 |
| OLED + BH1750 | I2C1：PB6/PB7 | 地址、上拉、电气连接、总线恢复 |
| SD 卡 | SPI1：PA4/PA5/PA6/PA7 | CS 默认高、初始化时钟、供电 |
| 电池采样 | ADC1，例如 PA1 | 分压范围、源阻抗、采样时间 |
| 温湿度 | 选定一种已验证传感器 | 复用前面章节已经通过测试的驱动 |

不要为了综合项目同时换一批新器件。M1 先选一个已经单独验证过的温湿度方案；BH1750、电池 ADC 等数据源再逐个加入。

## 25.2 数据结构先稳定下来

所有消费者都使用同一份值类型样本：

```c
typedef enum {
    ENV_STATUS_TEMP_ERROR = 1U << 0,
    ENV_STATUS_HUM_ERROR  = 1U << 1,
    ENV_STATUS_LIGHT_ERROR = 1U << 2,
    ENV_STATUS_BATT_ERROR = 1U << 3
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

这里继续沿用前文的定点单位：`temperature_centi = 2463` 表示 24.63 °C，`humidity_permille = 583` 表示 58.3 %RH。传感器读取失败时设置对应状态位，不用一个看起来正常的数值代替错误。

`seq` 每产生一份样本递增一次。日志和云端都保留它，后面看到跳号时可以判断中间发生过丢弃。

## 25.3 一份样本要扇出到不同消费者

显示、日志和网络对数据的要求不同，不能让三个任务竞争同一个 Queue：FreeRTOS Queue 中的一条消息被一个消费者取走后就没有了。

本项目使用三条通路：

```text
                    ┌→ latest_display_q ─→ DisplayTask
SensorTask ─ sample ├→ log_q ────────────→ LogTask
                    └→ cloud_q ──────────→ NetworkTask
```

`latest_display_q` 长度为 1，使用 `xQueueOverwrite()`，因为屏幕只关心最新状态。`log_q` 和 `cloud_q` 是有容量的顺序队列，满时分别增加 `log_drop` 和 `cloud_drop`；第一版不允许 SensorTask 等待它们腾出空间。

如果项目要求断网期间每一条样本都最终上传，RAM Queue 不够，需要把持久日志作为离线缓存，并设计确认、回放和删除规则。本章 M4 先把这一策略写清楚，再决定是否实现补传。

## 25.4 任务边界

项目使用五个任务：

```text
SensorTask
  └─ 周期采样并扇出 EnvSample

DisplayTask
  └─ 显示 latest_display_q 中的最新样本

LogTask
  └─ 顺序写入 SD/FatFs

NetworkTask
  └─ 独占 WiFi AT 模块，维护 TCP/MQTT 和重连

HealthTask
  └─ 汇总队列、栈、驱动和网络计数器
```

按键如果只切换页面，可以由 EXTI ISR 使用 Task Notification 唤醒 UI/Display 逻辑。ISR 不直接刷 OLED，也不访问 FatFs 或 WiFi。

任务优先级不在这一章硬编码成“传感器一定比显示高几级”。先保证所有驱动都有有限超时，再用实际周期、阻塞时间和压力测试调整优先级。

## 25.5 SensorTask 只负责产生样本

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

1 s 是本项目的初始采样周期。它成立的前提是一次完整采样的最坏执行时间小于周期，并且每个设备驱动都有超时。若 DS18B20 等器件的转换时间占据周期的大部分，应使用“启动转换—稍后读取”的状态机，或调整采样周期。

SensorTask 不调用 MQTT、FatFs，也不等待网络恢复。某个传感器失败时，这一周期仍然产生带错误位的样本，让显示、日志和 HealthTask 能看到故障。

## 25.6 LogTask 明确持久化边界

日志至少保存版本、`seq`、时间基准、状态和传感器字段。CSV/JSONL 便于人工查看；二进制记录更节省空间。无论选哪一种，都要规定最大文件尺寸、轮换方式和写失败策略。

第一版可以按批次 `f_write()`，在明确的同步点执行 `f_sync()`。每条记录都 `f_sync()` 会增加写放大和延迟；长期不同步则扩大掉电时可能丢失的数据范围。同步周期属于项目策略，需要通过断电测试决定。

SD 卡拔出、文件系统错误或写超时只改变存储状态和计数器。LogTask 不能持有样本队列的生产端，也不能让 SensorTask 阻塞等待卡恢复。

如果日志承担断网补传，还要额外记录“哪些记录已被云端确认”。仅凭 MQTT 发送函数返回成功就删除离线记录，会把传输层成功误当成业务持久化成功。

## 25.7 NetworkTask 独占无线模块

NetworkTask 沿用第 17–21 章的通信边界：只有它操作 WiFi UART、AT 状态机、TCP 和 MQTT。

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
    └─ 断线/超时 → BACKOFF → WIFI/TCP/MQTT 恢复
```

断网时 SensorTask 继续运行。`cloud_q` 满以后按项目规定丢弃并计数，或者把样本交给持久离线日志；不能靠无限增加 RAM Queue 解决长时间断网。

恢复联网后也要限制补传速率，给实时数据和 MQTT Keep Alive 留出处理时间。若项目要求“每条样本最终到云端”，还需要业务 ACK 或服务端可查询的 `seq` 机制来定义何时可以删除本地副本。

## 25.8 启动顺序

先建立调试通道，再创建 RTOS 对象。外设初始化失败要留下明确状态，但 WiFi、SD 卡或某个传感器不可用不必直接阻止调度器启动。

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

`STACK_*` 的单位是 `StackType_t` 元素，不能把数值直接当字节。初值根据各任务实际调用链给出，再用 stack high-water mark 和压力测试调整。

## 25.9 HealthTask 留下能定位问题的数字

HealthTask 不控制业务，只汇总状态。每隔一段时间输出一次即可，避免调试串口本身成为系统负载。

建议至少保留：

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

队列还应记录历史最大占用量。只看“当前剩几个位置”可能错过之前发生过的突发积压。

这些计数器的更新方式要符合并发模型。多个任务同时修改同一个复合结构时，不要因为成员加了 `volatile` 就认为读写已经同步；可以让每个任务维护自己的计数器，再由 HealthTask 读取快照，或用短临界区保护需要一致性的字段。

## 25.10 按 M1–M4 联调

**M1：采样。** 先只启动 SensorTask 和调试输出。连续检查 `seq`、单位、状态位和周期；断开传感器后，任务仍应继续产生带错误状态的样本。

**M2：显示。** 加入 OLED 和 `latest_display_q`。拔掉 OLED 或让 I2C 超时，SensorTask 的 `seq` 仍继续增长。显示恢复后直接显示最新样本，不补画旧页面。

**M3：存储。** 加入 LogTask 和 SD 卡。测试正常写入、拔卡、重新插卡、写失败和重启扫描。确认日志 Queue 满时有明确计数，SensorTask 周期不被拖慢。

**M4：网络。** 最后加入 WiFi/MQTT。测试 Broker 停止、路由器断开和模块复位。恢复后应经过统一状态机重新连接；如果实现离线补传，再验证补传期间实时样本仍能处理。

每完成一个里程碑，保存接线图、固件 commit SHA、关键串口日志和当前资源映射。后续出现回归时，可以确定是哪一次集成开始出问题。

## 25.11 故障测试按机制验收

综合项目不使用“连续运行 8 小时就算稳定”这种单一标准。运行时间只能覆盖时间维度，不能替代具体故障路径。

至少测试这些情况：

- WiFi 断开期间，`sample_seq` 继续递增，`cloud_drop` 或离线缓存按设计变化；
- SD 卡拔出期间，显示和网络继续工作，`storage_error` 增加；
- I2C 设备无响应时，驱动在规定超时内返回，其他任务仍有心跳；
- `log_q` / `cloud_q` 人为缩短后，满队列计数能稳定复现；
- Broker 恢复后只有 NetworkTask 执行重连，没有多个任务同时刷 AT 命令；
- 连续注入错误 JSON、MQTT 断线和存储失败后，heap 与各任务栈水位没有持续恶化；
- 断电重启后，日志扫描和配置加载能回到文档规定的状态。

测试时间要覆盖项目预期的最长周期事件，例如日志轮换、网络退避上限和缓存回放。若这些事件需要更长时间，就针对它们单独做加速或故障注入测试。

## 25.12 本章完成标准

项目完成时，代码和 README 至少能回答下面这些问题：

- 每个硬件资源由哪个驱动和任务拥有；
- `EnvSample` 每个字段的单位和错误状态是什么；
- 显示、日志、网络各自的 Queue 满策略是什么；
- WiFi 或 SD 卡故障时哪些功能继续运行；
- 离线数据最多保存多少，满后怎么处理；
- MQTT 恢复后是否补传，何时认为一条记录可以删除；
- 每个任务的栈水位、队列满次数和关键驱动错误从哪里查看。

这些边界都能通过故障测试复现后，第一个综合项目才算完成。下一章会把同样的任务和协议边界用到带执行器的 BLE 门锁上，那里还要增加权限、重复命令和安全输出状态的处理。

> **上一章**：[第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)
>
> **下一章**：[第 26 章 · 综合项目二：BLE 智能门锁](./26-chapter.md)

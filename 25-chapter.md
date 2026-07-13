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

接线前先确认开发板型号。C8T6 与 VET6/ZET6 的 Flash、RAM、启动文件和链接脚本不同；本项目不要混用两套配置。

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

## 25.8 本章要点

- 综合项目靠里程碑推进，而不是一次性拼接所有模块；
- 采样数据要有统一结构，任务之间使用 Queue 交接；
- 网络和存储都可能失败，不能拖垮本地采样；
- ISR、驱动、协议和应用逻辑需要分层；
- 可验证的故障测试与功能测试同样重要。

---

[上一章：第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

[下一章：第 26 章 · 综合项目二：BLE 智能门锁](./26-chapter.md)

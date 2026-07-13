# 第 24 章 · 网关架构与 UART 接收通路（SPL版）

> **本章产出**：把“串口收到字节”变成可维护的网关数据通路；能区分 ISR、驱动层、协议层和应用层各自该做什么。
>
> **前置知识**：第 8 章 UART、中断与环形缓冲区，以及第 21–23 章的网络协议。
>
> **用在哪**：WiFi AT 模块、BLE 模块、RS485 设备和最终多协议网关。

---

## 24.1 网关不是“把数据原样转发”

一个网关至少做四件事：

1. 接收不同接口的数据；
2. 检查协议是否合法；
3. 转换为统一的内部数据模型；
4. 决定上报、缓存、告警或下发控制。

例如，Modbus 温度寄存器、BLE 广播包和 WiFi JSON 不应在整个程序里到处出现。它们应该在各自的适配器中被转换成统一的 SensorEvent。

~~~c
typedef struct {
    uint32_t seq;
    int16_t  temperature_centi;
    uint16_t humidity_centi;
    uint8_t  source;
} SensorEvent;
~~~

业务任务只处理 SensorEvent，不需要知道数据来自 UART、I2C 还是 BLE。

## 24.2 四层结构

~~~text
硬件层        GPIO / USART / DMA / 中断
驱动层        uart_at.c / rs485.c / ble_uart.c
协议适配层    mqtt_adapter.c / modbus_adapter.c / json_adapter.c
应用层        规则、告警、显示、上报、存储
~~~

层与层之间通过明确的函数接口或 FreeRTOS Queue 交互。这样替换 WiFi 模块时，不会牵连温度计算和 OLED 页面。

## 24.3 中断只搬运字节，不解析协议

UART 接收中断的职责应尽量小：读出硬件寄存器，把字节放进缓冲区，然后立刻返回。不要在 ISR 中做 JSON 解析、等待 AT 响应或访问网络。

~~~c
void USART2_IRQ_Init(void)
{
    NVIC_InitTypeDef nvic;

    USART_ITConfig(USART2, USART_IT_RXNE, ENABLE);

    nvic.NVIC_IRQChannel = USART2_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 2;
    nvic.NVIC_IRQChannelSubPriority = 0;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}

void USART2_IRQHandler(void)
{
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t ch = (uint8_t)USART_ReceiveData(USART2);
        RingBuffer_PutFromISR(&wifi_rx_ring, ch);
    }
}
~~~

RingBuffer_PutFromISR 必须是无阻塞的：缓冲区满了时只记录溢出计数，不能在 ISR 里等待空间。

## 24.4 从字节流到一条消息

驱动任务从环形缓冲区取字节，交给状态机。以 AT 响应为例：

~~~text
字节流 → 行缓冲区 → 识别 OK / ERROR / > / +IPD → 发送事件
~~~

对于自定义二进制协议，则可能是：

~~~text
寻找帧头 → 读取长度 → 累积 Payload → 校验 CRC → 产生 SensorEvent
~~~

关键原则：协议状态必须保存在任务或解析器对象中，不能依赖“这次 read 一定恰好读到一整帧”。

## 24.5 Queue 是网关的边界

一个典型的数据流：

~~~text
UART ISR
  → RingBuffer
  → Task_ProtocolParser
  → Queue_SensorEvent
  → Task_RuleEngine
  → Queue_CloudPublish / Task_Display / Task_SDLog
~~~

这样可以分别观察“串口丢字节”“CRC 错误”“云端发送失败”属于哪一层，而不是只看到一个模糊的“设备没反应”。

## 24.6 同一串口不要同时承担互斥角色

有些 WiFi/BLE 二合一模块通过同一 UART 工作，但并不意味着程序可以同时把它当作两个独立设备。请先确认模块固件是否支持并发模式。

如果不支持，选择其中一种设计：

- 为 WiFi 和 BLE 各分配一个 UART；
- 使用模块明确提供的多路复用协议；
- 用状态机切换模式，并明确切换期间哪些服务不可用。

把 AT 响应和 BLE 业务数据混在没有边界的同一缓冲区中，是后期最难排查的问题之一。

## 24.7 可观测性

每个适配器至少统计：

| 指标 | 用来发现什么 |
|---|---|
| rx_bytes | 线路是否真的有数据 |
| rx_overflow | 环形缓冲区是否太小 |
| frame_crc_error | 接线、波特率或协议问题 |
| reconnect_count | 网络稳定性 |
| publish_fail_count | Broker 或认证问题 |

定期通过调试串口输出这些统计，比只打印“连接失败”有用得多。

## 24.8 本章练习

1. 用 USART2 接收一行 AT 响应，并在任务中识别 OK；
2. 故意降低任务优先级，观察环形缓冲区溢出计数；
3. 把一个 Modbus 温度值转换成 SensorEvent；
4. 给每个层级添加一条可开关的调试日志。

## 24.9 本章要点

- 网关的价值是协议适配和统一数据模型，而不是简单转发；
- ISR 只搬运字节，解析必须放在任务上下文；
- UART 中断还需要配置 NVIC，只有 USART_ITConfig 不够；
- RingBuffer、状态机、Queue 共同解决“字节流没有消息边界”的问题；
- 可观测性是网关长期稳定运行的一部分。

---

[上一章：第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)

[下一章：第 25 章 · 综合项目一：智能环境监测节点](./25-chapter.md)

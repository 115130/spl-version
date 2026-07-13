# 第 27 章 · 综合项目三：多协议智能网关（SPL版）

> **本章产出**：把 WiFi、BLE、RS485/Modbus 等不同接口转换为统一事件，并实现最小的本地规则引擎。
>
> **前置知识**：第 12.5 章 RS485/Modbus、第 21–24 章网络与网关架构，以及第 25–26 章项目组织方法。
>
> **项目目标**：接收多类设备数据、本地判断规则、上报云端，并能下发可追踪的控制命令。

---

## 27.1 先定义“网关内的共同语言”

不要把 Modbus 寄存器地址、BLE 字节偏移和 MQTT Topic 直接传到应用层。先定义一个通用事件：

~~~c
typedef enum {
    SRC_MODBUS,
    SRC_BLE,
    SRC_WIFI
} EventSource;

typedef enum {
    EVT_TEMPERATURE,
    EVT_HUMIDITY,
    EVT_DOOR_STATE,
    EVT_COMMAND
} EventType;

typedef struct {
    EventSource source;
    EventType   type;
    uint32_t    device_id;
    int32_t     value;
    uint32_t    seq;
} GatewayEvent;
~~~

现在，Modbus 适配器和 BLE 适配器都只需要生成 GatewayEvent，规则引擎不再关心原始协议。

## 27.2 适配器模式

| 适配器 | 输入 | 输出 |
|---|---|---|
| modbus_adapter | RS485 帧、CRC | GatewayEvent |
| ble_adapter | BLE UART 帧 | GatewayEvent |
| mqtt_adapter | Topic + Payload | GatewayEvent |
| cloud_adapter | GatewayEvent | MQTT/HTTP 上报 |

每个适配器只负责一个方向的转换。不要让 modbus_adapter 直接调用 WiFi 函数；它应该把事件送到 Queue_GatewayEvent。

## 27.3 任务划分

~~~text
Task_RS485_Poll      → Queue_GatewayEvent
Task_BLE_Rx          → Queue_GatewayEvent
Task_WiFi_Rx         → Queue_GatewayEvent
Task_RuleEngine      ← Queue_GatewayEvent
Task_CloudPublish    ← Queue_CloudEvent
Task_LocalActuator   ← Queue_Command
~~~

轮询 Modbus 时要考虑总线时序；BLE/WiFi 接收依赖 UART 中断与环形缓冲区。所有任务都应该有超时与错误计数。

## 27.4 本地规则引擎

本地规则的价值是：即使云端断网，关键动作仍能执行。

~~~text
如果 room-01.temperature > 3000（30.00°C）
那么：
  1. 打开本地风扇
  2. 记录告警
  3. 网络可用时上报告警
~~~

初学阶段不需要实现脚本语言。用一个清晰的 C 表即可：

~~~c
typedef struct {
    EventType type;
    int32_t   greater_than;
    uint8_t   action;
} Rule;
~~~

规则任务收到事件后遍历表，命中后把动作发送到 Queue_Command。动作执行结果也要形成事件，避免“已经执行”只存在于某一行日志里。

## 27.5 不要假定一根 UART 能同时承载一切

WiFi/BLE 二合一模块是否支持并发，取决于模块固件。若模块不明确支持多角色、多连接或复用边界，不要把 AT 响应和 BLE 业务帧当作两条独立通道。

优先级从高到低：

1. WiFi、BLE、RS485 使用独立 UART 或独立模块；
2. 使用模块官方支持的多路复用协议；
3. 明确切换模式，并向上层报告当前不可用的服务。

“能收到一些字节”不等于架构正确。

## 27.6 设备注册与可追踪性

每个来源设备至少需要：

| 字段 | 作用 |
|---|---|
| device_id | 唯一身份 |
| source | 来自哪个适配器 |
| last_seen | 判断设备是否离线 |
| last_seq | 检测重复或丢帧 |
| error_count | 决定是否告警 |

调试时，把 device_id、source、seq 一起打印；只有温度值而没有来源，后期很难排查。

## 27.7 项目验收

| 验收项 | 方法 |
|---|---|
| 协议转换 | 同一温度分别从 Modbus 和 BLE 上报，云端格式一致 |
| 本地规则 | 断网后仍触发风扇或告警 LED |
| 去重 | 重放同一 seq 的帧，不执行第二次动作 |
| 故障隔离 | 一个设备持续发错误帧，不阻塞其他适配器 |
| 资源稳定性 | 连续运行 24 小时，记录堆、栈、溢出计数 |

## 27.8 本章练习

1. 为两种来源生成相同的 GatewayEvent；
2. 实现“温度过高开风扇”的本地规则；
3. 为每个设备实现 last_seen 超时离线检测；
4. 把错误计数和队列剩余空间显示到 OLED 调试页。

## 27.9 本章要点

- 多协议网关的核心是统一事件模型；
- 适配器之间通过 Queue 交接，而不是相互直接调用；
- 本地规则让系统在断网时仍能工作；
- 协议并发能力必须由模块文档证明；
- 可追踪的 device_id、seq 与错误计数是长期维护基础。

---

[上一章：第 26 章 · BLE 智能门锁](./26-chapter.md)

[下一章：第 28 章 · 调试与排错](./28-chapter.md)

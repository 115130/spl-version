# 第 27 章 · 综合项目三：多协议智能网关（SPL版）

> **本章产出**：把 WiFi、BLE、RS485/Modbus 等不同接口转换为统一事件，并实现最小的本地规则引擎。
>
> **前置知识**：第 12B 章 RS485/Modbus、第 21–24 章网络与网关架构，以及第 25–26 章项目组织方法。
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
    uint16_t    schema_version; /* 统一事件格式的版本 */
    EventSource source;
    EventType   type;
    uint32_t    device_id;
    uint32_t    seq;
    uint32_t    mono_tick;      /* 排序/超时用单调时间，不冒充真实 UTC */
    int32_t     value;          /* 必须在 type 文档中规定单位，例如 centi-°C */
    uint16_t    flags;          /* 有效、估算、CRC 错、离线等状态 */
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

## 27.9 适配器接口与可重复集成

把每一种协议都限制在自己的适配器里。应用层只看 `GatewayEvent`，不应知道 Modbus 寄存器、BLE 特征值或 AT 提示符：

~~~c
typedef struct {
    bool (*init)(void);
    void (*poll)(void);                  /* 从 RingBuffer/驱动取字节 */
    bool (*next_event)(GatewayEvent *);  /* 只产出已验证事件 */
    const char *name;
} GatewayAdapter;
~~~

每个适配器都必须维护自己的超时、解析状态、错误计数和最后在线时间。适配器之间不直接调用，统一把事件交给 Queue。

### 三层集成顺序

| 阶段 | 使用的输入 | 通过标准 |
|---|---|---|
| A | UART 回放的固定字节数组 | 每种协议都能独立产生同一类事件 |
| B | 单个真实来源 | 断线/坏帧只影响该适配器 |
| C | 两个来源并发 | Queue、seq 和 source 可追踪，无互相阻塞 |
| D | 云端/本地规则 | 规则只消费 GatewayEvent，不反向耦合驱动 |
| E | 长稳测试 | 24 小时的错误、队列和内存指标可解释 |

### 背压设计题

网关输入可以突发，云端输出可以很慢。每种事件应明确处理策略：

- 遥测最新值：可覆盖旧值；
- 审计日志：保留顺序，满时记录丢失；
- 控制命令：不能静默丢弃，必须 ACK、拒绝或进入超时；
- 错误告警：限速聚合，避免日志风暴。

练习：用 UART 同时模拟一个“每秒温度”的来源和一个“突发 100 帧”的来源；证明它们的错误计数、来源 ID 和 Queue 策略都可见。

## 27.10 命令关联、设备注册与规则隔离

网关既要处理遥测，也要处理“下发控制后到底发生了什么”。为命令建立关联 ID，而不是只打印一条字符串：

~~~c
typedef struct {
    uint32_t correlation_id;   /* 云端/本地发起一次命令的编号 */
    uint16_t target_source;
    uint16_t command;
    uint32_t deadline_tick;
} GatewayCommand;

typedef enum {
    CMD_ACCEPTED,
    CMD_REJECTED,
    CMD_TIMEOUT,
    CMD_COMPLETED
} CommandResult;
~~~

当一个控制命令到达时：

1. 检查来源、设备状态和参数范围；
2. 创建 `GatewayCommand` 并放入该适配器的受限队列；
3. 适配器产生 `CMD_ACCEPTED/REJECTED/COMPLETED` 事件；
4. 网络层根据 `correlation_id` 上报结果；
5. 超时后明确报 `CMD_TIMEOUT`，而不是无声消失。

### 规则引擎只消费事件

本地规则应是纯函数式判断，不直接操作 UART 或继电器：

~~~c
typedef struct {
    bool fan_should_run;
    bool alarm_should_raise;
} RuleDecision;

RuleDecision Rules_Evaluate(const GatewayEvent *e)
{
    RuleDecision d = {0};
    if (e->type == EVT_TEMPERATURE && e->value > 3000)
        d.fan_should_run = true;  /* 教学示例：真实值需按格式解析 */
    return d;
}
~~~

执行层接到 `RuleDecision` 后仍需使用安全状态机、权限与超时。这样可以单独用录制的 GatewayEvent 测试规则，而不接任何真实设备。

### 长稳验收

- 同时注入有效帧、CRC 错帧、离线和突发数据；
- 每个适配器都仍能报告 `last_seen`、错误数、溢出数；
- 命令都有 correlation ID 和终态；
- 网络断开时本地规则仍有明确行为；
- 重启后设备注册、配置和默认安全状态可重复。

练习：录制 20 条 GatewayEvent，在 PC/固件测试函数中回放；同一份事件序列应得到同一组 RuleDecision 和统计。

## 27.11 统一事件要有版本、单位、容量和回放边界

`GatewayEvent` 不是“随便塞几个 payload 字节”的容器。每个 `type` 都应在一张表里规定 value 的单位、有效范围和 flags 的含义；否则一台适配器传“30”，另一台传“3000”时，规则引擎会在看似正常的条件下做错事。

| type | `value` 的约定示例 | 必须保留的 flags |
|---|---|---|
| `EVT_TEMPERATURE` | 摄氏度 × 100，3000 = 30.00°C | 有效/传感器错/数据过期 |
| `EVT_HUMIDITY` | %RH × 100 | 有效/范围错 |
| `EVT_DOOR_STATE` | 枚举值，不把字符串塞入数值 | 物理反馈可信度 |
| `EVT_COMMAND` | 不用 `value` 表示全部命令；使用关联 ID + 参数结构 | 接受/拒绝/超时/完成 |

### 注册表与配置恢复

设备注册不只存 `device_id`。一个可恢复的登记项至少包括：适配器类型、地址/服务标识、配置版本、最后成功版本、默认安全策略和 CRC。Flash 中的配置必须有版本、长度和校验；无法识别时进入“未注册/只观察”的安全状态，而不是把旧字节强转成新结构体。

### 先算 RAM，再决定支持多少设备

假设网关最多同时跟踪 `N` 台设备、每台保留一个状态项 `S` 字节、事件队列深度 `Q`、事件大小 `E`，最小 RAM 预算至少包含：

~~~text
device_registry = N × S
event_queue     = Q × E
rx_buffers      = 每个适配器的 RingBuffer 之和
task_stacks + FreeRTOS heap + 日志格式化缓冲
~~~

写出最大 N、Q、E 后，再选择“遥测覆盖、审计限速、控制不静默丢失”的策略。最后将录制的正常帧、CRC 错帧、断线、突发和重复 seq 保存成回放集；PC 测试与固件测试应对同一输入给出相同的事件计数和规则结果。

## 27.12 本章要点

- 多协议网关的核心是统一事件模型；
- 适配器之间通过 Queue 交接，而不是相互直接调用；
- 本地规则让系统在断网时仍能工作；
- 协议并发能力必须由模块文档证明；
- 可追踪的 device_id、seq 与错误计数是长期维护基础。

---

[上一章：第 26 章 · BLE 智能门锁](./26-chapter.md)

[下一章：第 28 章 · 调试与排错](./28-chapter.md)

# 第 27 章 · 综合项目三：多协议智能网关（SPL 版）

这一章把第 24 章的 UART → Parser → Adapter → Event 通路扩展到多个协议来源。RS485/Modbus、BLE 和 WiFi 各自保留驱动与协议状态，进入应用层以后统一成 `GatewayEvent`；规则、日志和云端不再解析原始协议。

综合项目重点检查三件事：统一事件的字段语义、不同来源之间的故障隔离，以及控制命令从发起到完成的可追踪性。

## 27.1 先固定网关内部事件格式

```c
typedef enum {
    SRC_MODBUS,
    SRC_BLE,
    SRC_WIFI
} EventSource;

typedef enum {
    EVT_TEMPERATURE,
    EVT_HUMIDITY,
    EVT_DOOR_STATE,
    EVT_COMMAND_RESULT
} EventType;

typedef struct {
    uint16_t    schema_version;
    EventSource source;
    EventType   type;
    uint32_t    device_id;
    uint32_t    seq;
    uint32_t    mono_tick;
    int32_t     value;
    uint16_t    flags;
} GatewayEvent;
```

`mono_tick` 用于本机超时和事件间隔，不当作 UTC 时间。`value` 的解释由 `type` 决定，例如温度统一为摄氏度 × 100；门状态使用文档规定的枚举值。复杂命令结果不够一个 `value` 表达时，应定义专门结构体或受版本控制的 payload，避免不断给这个结构硬塞字段。

`seq` 也要注明来源。它可以是远端设备序号，也可以由 Adapter 生成本地序号；两者在去重能力上不同，不能只看字段名字就假定含义相同。

## 27.2 Adapter 隔离协议细节

每个 Adapter 只处理自己的协议和设备映射。例如 Modbus Adapter 把寄存器值、从站地址和 CRC 校验结果转换成 `GatewayEvent`；BLE Adapter 处理特征值或透明串口协议；WiFi Adapter 处理其定义好的业务消息。

可以使用统一接口：

```c
typedef struct {
    bool (*init)(void);
    void (*poll)(void);
    bool (*next_event)(GatewayEvent *out);
    const char *name;
} GatewayAdapter;
```

`next_event()` 只返回已经通过协议校验并完成单位转换的事件。Adapter 维护自己的 Parser 状态、超时和错误计数，不直接调用 MQTT、OLED 或其他 Adapter。

如果协议本身需要主动轮询，例如 Modbus RTU Master，轮询调度和响应超时也属于该 Adapter/驱动路径。上层只看到最终事件和设备状态。

## 27.3 多来源通过 Queue 汇合

任务结构可以是：

```text
RS485Task ─┐
BLETask ───┼─→ gateway_event_q ─→ RuleTask
WiFiTask ──┘                         ├→ local_command_q
                                    └→ cloud_event_q

CloudTask ← cloud_event_q
ActuatorTask ← local_command_q
```

多个任务向同一个 FreeRTOS Queue 发送值类型消息是受支持的，但 Queue 容量仍然有限。发送端要使用明确的等待策略；本项目不允许某个突发来源无限阻塞整个采集路径。

如果事件速率差距很大，可以为来源设置独立输入 Queue，再由聚合任务按策略合并。这样一个高流量来源不会轻易占满所有来源共用的入口。是否需要这层结构由压力测试决定。

## 27.4 每个 EventType 都要规定单位和 flags

本项目至少固定这些语义：

- `EVT_TEMPERATURE`：`value` 为 °C × 100，例如 `3000` 表示 30.00 °C；
- `EVT_HUMIDITY`：`value` 为 %RH × 100，例如 `5830` 表示 58.30% RH；
- `EVT_DOOR_STATE`：`value` 使用项目定义的门状态枚举；
- `EVT_COMMAND_RESULT`：使用关联 ID 和专门结果字段，不能靠一个数值猜命令上下文。

`flags` 也要集中定义，例如 VALID、STALE、SENSOR_ERROR。CRC 错误通常在 Adapter 输入阶段就被拒绝并计入协议统计，不应生成一条带 `CRC_ERROR` 的正常温度事件让规则继续计算。

若事件格式写入 Flash、SD 或发往云端，`schema_version` 用于识别字段语义。读取未知版本时拒绝解析或走显式迁移路径，不能把旧字节直接强转成当前结构体。

## 27.5 本地规则只产生决策

断网时，本地规则仍可以根据已经收到的事件运行。第一版不需要脚本语言，用可测试的 C 逻辑即可：

```c
typedef struct {
    bool fan_should_run;
    bool alarm_should_raise;
} RuleDecision;

RuleDecision Rules_Evaluate(const GatewayEvent *e)
{
    RuleDecision d = {0};

    if (e->type == EVT_TEMPERATURE &&
        (e->flags & EVENT_FLAG_VALID) != 0U &&
        e->value > 3000) {
        d.fan_should_run = true;
    }

    return d;
}
```

规则函数不访问 UART、继电器或 MQTT。RuleTask 把决策转换成 `GatewayCommand`，再交给执行层。这样同一组录制事件可以在 PC 测试和固件测试中回放，不需要连接真实设备。

温度阈值 30.00 °C 只是教学规则。真实项目把阈值、迟滞和故障时默认行为写进配置；如果只有一个 `> 3000` 条件而没有迟滞，温度在阈值附近波动时可能频繁开关执行器。

## 27.6 控制命令使用 correlation ID

定义命令事务：

```c
typedef struct {
    uint32_t correlation_id;
    uint32_t target_device_id;
    uint16_t command;
    uint32_t deadline_tick;
} GatewayCommand;

typedef enum {
    CMD_ACCEPTED,
    CMD_REJECTED,
    CMD_TIMEOUT,
    CMD_COMPLETED
} CommandResult;
```

收到云端或本地规则命令后，先验证目标设备、参数和当前状态，再放入目标 Adapter/执行器的受限 Queue。`CMD_ACCEPTED` 只表示命令已经被当前层接受处理，不能当成设备动作完成；只有取得协议或物理层定义的完成证据后才产生 `CMD_COMPLETED`。

超时产生 `CMD_TIMEOUT`，拒绝产生 `CMD_REJECTED`。结果事件保留同一个 `correlation_id`，云端日志才能把请求和最终结果对应起来。

重试还要考虑命令是否幂等。开灯到指定状态通常可以设计成幂等命令；“脉冲一次”“加 1”这类动作重试可能产生第二次副作用，需要设备侧 request ID 或其他去重机制。

## 27.7 设备注册保存协议身份和运行状态

一个注册项至少需要设备 ID、Adapter 类型、协议地址/服务标识、配置版本和安全默认策略。`last_seen`、`last_seq`、错误数属于运行状态，可以和持久配置分开保存。

`last_seen` 的更新条件要明确。收到任意噪声字节不能算设备在线；通常在得到一条通过协议校验的响应或事件后更新。设备离线判断使用单调时间，并用无符号 tick 差值处理计数器回绕。

`last_seq` 只有在对应协议确实提供有意义的序号时才用于丢帧或重复检测。Modbus RTU 本身没有通用消息 sequence 字段，不能为了统一结构就假定所有来源都有远端 seq。

持久注册配置写入 Flash 时保存版本、长度和校验。无法识别或校验失败的条目进入未注册/受限状态，由明确流程重新配置。

## 27.8 UART 和模块并发能力按硬件实际设计

WiFi、BLE 和 RS485 使用独立 UART 时最容易保持所有权。若开发板 UART 数量、引脚复用或模块设计不允许，就要根据实际硬件选择外部 UART、总线复用器或模块官方支持的多路复用机制。

WiFi/BLE 二合一模块能否同时运行多个角色和连接取决于具体模块及固件。AT 响应、异步事件和业务 Payload 如果共用一条串口，必须先由同一个模块 Parser 分类，不能让两个任务各自在同一字节流中找关键字。

模式切换型设计还要向上层暴露当前不可用的服务。例如切到 BLE 配网期间 WiFi 暂停，就让 CloudTask 得到明确离线状态，不要让它继续等待永远不会到来的 AT 响应。

## 27.9 背压按事件类型处理

输入可能突发，云端也可能长时间不可用。不同数据使用不同策略：

- 最新遥测可以覆盖旧值，但要保留丢弃/覆盖计数；
- 审计日志保持顺序，容量不足时记录明确的数据缺口；
- 控制命令不能静默丢弃，Queue 满时返回 busy/rejected 或在 deadline 内等待；
- 重复错误和告警可以限速聚合，避免故障设备把日志和网络通道占满。

如果所有事件共用一个 Queue，高流量遥测可能排在控制结果前面。项目有不同延迟要求时，可以拆 Queue 或在聚合层做有限调度；不要只靠提高某个任务优先级解决已经进入 Queue 的排队问题。

网络断开几小时仍需要保留的审计或遥测数据应进入持久存储。RAM Queue 只覆盖按容量计算出的短期积压。

## 27.10 先算 SRAM 预算

STM32F103ZET6 有 64 KB SRAM，事件注册表、Queue、RingBuffer、任务栈和协议缓冲都从这里分配。至少列出：

```text
device_registry = N × sizeof(DeviceState)
event_queue     = Q × sizeof(GatewayEvent)
command_queue   = C × sizeof(GatewayCommand)
rx_buffers      = 各 Adapter RingBuffer 之和
task_stacks     = 各任务 StackType_t 深度 × sizeof(StackType_t)
other           = FreeRTOS 对象、协议缓冲、日志格式化缓冲、全局/静态数据
```

Queue 还会有 FreeRTOS 控制结构开销，因此 `Q × E` 只是消息存储部分。最终以链接 map、heap 统计和任务 high-water mark 检查实际占用。

最大设备数 `N`、事件深度 `Q` 和命令深度 `C` 都要写成项目约束。不要先宣称“支持几十台设备”，再让动态分配失败决定实际容量。

## 27.11 用回放和并发故障做验收

先给每个 Adapter 单独准备固定输入：合法帧、CRC 错误、非法长度、超时和重复数据。相同输入在不同字节切分下应产生相同的合法事件序列。

随后同时运行至少两个来源，注入一个高流量来源和一个正常来源，检查 `gateway_event_q` 的最大占用、各 Adapter overflow、事件 drop 和规则处理延迟。让其中一个来源持续产生错误帧，其他来源仍应继续产生事件。

命令路径单独检查 `correlation_id`：正常完成、拒绝、设备离线、Queue 满和超时都要得到终态。网络断开时本地规则继续运行，CloudTask 只进入离线/积压策略。

最后检查重启恢复：注册配置能通过版本和校验加载；无法识别的配置不会被当成有效设备；执行器回到项目定义的安全启动状态。长时间测试用于覆盖日志轮换、最大退避、tick 回绕测试方案等长周期机制，不能代替这些故障注入。

## 27.12 本章完成标准

项目完成时应能回答：

- 每种协议在哪个 Adapter 内结束，应用层从哪里开始；
- 每个 EventType 的单位、范围和 flags 如何定义；
- 哪些来源有远端 seq，哪些只有网关本地序号；
- 一个高流量或故障设备如何避免拖住其他来源；
- 控制命令怎样从 `correlation_id` 追踪到最终结果；
- Queue 满、网络离线和持久存储满时分别执行什么策略；
- 最大设备数和 Queue 深度对应多少 SRAM；
- 重启后设备注册和执行器默认状态如何恢复。

这些边界通过回放、并发压力和故障注入验证后，多协议网关的基本架构就完成了。下一章集中处理调试与排错方法。

> **上一章**：[第 26 章 · BLE 智能门锁](./26-chapter.md)
>
> **下一章**：[第 28 章 · 调试与排错](./28-chapter.md)

# 第 26 章 · 综合项目二：BLE 智能门锁（SPL 版）

这一章在第 19 章 BLE 通信的基础上加入执行器。教学目标是把 BLE 输入、认证结果、锁状态和执行器反馈分开处理，并在桌面夹具上验证重复命令、超时、复位和故障恢复。

这里实现的是门锁控制架构的教学原型，不是可直接部署的安全门锁。真实产品还需要经过审查的认证协议、密钥管理、物理安全、故障分析和合规设计。

## 26.1 上电先确认物理状态

设备复位时，RAM 里的状态已经丢失，锁体却可能停在上一次动作的位置。程序不能一启动就把状态变量写成 `LOCKED` 并当作锁已经到位。

本章使用这些状态：

```c
typedef enum {
    DOOR_BOOT_CHECK,
    DOOR_SAFE_LOCKED,
    DOOR_AUTH_PENDING,
    DOOR_UNLOCKING,
    DOOR_UNLOCKED,
    DOOR_LOCKING,
    DOOR_FAULT
} DoorState;
```

启动进入 `DOOR_BOOT_CHECK`，读取限位开关、门磁或项目实际使用的位置反馈。确认锁定位置后进入 `DOOR_SAFE_LOCKED`；反馈缺失、矛盾或超时则进入 `DOOR_FAULT`。

如果原型只有普通舵机而没有位置反馈，就无法确认机械锁舌是否真的到位。此时只能验证软件动作时序，不能把 PWM 已经输出解释成“门已锁好”。

## 26.2 硬件先在桌面夹具上验证

本章需要 BLE 模块、测试执行器、位置/门磁输入和本地恢复按键。舵机或电机的供电路径根据执行器规格设计，不能直接假定开发板 3.3 V 电源能提供所需峰值电流。MCU 与驱动电路是否共地、是否需要隔离和保护，也由实际电路决定。

第一次联调先用 LED 表示锁定/解锁输出，再换低风险桌面执行器。动作超时、复位和传感器故障都验证完以后，才有理由连接机械结构。

本地恢复按键只生成恢复请求，不能简单把状态变量改成 `LOCKED`。FAULT 清除后仍回到 `DOOR_BOOT_CHECK`，重新取得物理反馈。

## 26.3 BLE 帧只产生请求

传输层先验证长度、类型和完整性，再产生结构化请求。例如教学帧可以包含：

```text
SOF | type | seq | payload_len | payload | CRC
```

对应的业务请求：

```c
typedef enum {
    CMD_STATUS,
    CMD_UNLOCK_REQUEST,
    CMD_LOCK_REQUEST
} DoorCommand;

typedef struct {
    uint32_t request_id;
    DoorCommand command;
} DoorRequest;
```

CRC 用于发现传输错误，不提供身份认证。`request_id` 用于业务去重，也不能证明请求来自授权用户。真正的认证由独立认证层完成，具体算法沿用目标 BLE 方案的安全设计。

BLE 连接建立也不代表对端已经获得开锁权限。配对、加密、应用身份和命令授权是不同边界，不能用“已连接”代替认证结果。

## 26.4 重复请求不能重复驱动执行器

无线链路和应用都可能重发请求。控制层要定义请求 ID 的生命周期，并缓存近期已处理请求的结果。

例如设备已经完成 `request_id=105` 的开锁事务，再收到同一个请求时可以返回之前的结果，但不能再次启动执行器。只保存“最后一个 seq”通常只适合非常受限的单客户端、严格递增协议；有多个客户端、重连或计数器回绕时，需要更完整的会话和去重规则。

设备还要规定重启后的语义。若去重状态只在 RAM 中，复位以后旧请求可能再次被视为新请求。对真实安全系统，这一边界必须和认证协议、防重放机制一起设计。

## 26.5 执行器驱动只接受受限动作

PWM 或电机驱动层提供明确接口：

```c
typedef enum {
    MOTOR_IDLE,
    MOTOR_MOVING,
    MOTOR_TARGET_REACHED,
    MOTOR_TIMEOUT,
    MOTOR_ERROR
} MotorStatus;

bool LockMotor_StartLock(void);
bool LockMotor_StartUnlock(void);
void LockMotor_Stop(void);
MotorStatus LockMotor_GetStatus(void);
```

控制器启动动作以后等待反馈事件或超时，不在协议 Parser 里直接写 TIM 寄存器。超时后先停止驱动，再进入故障状态，避免软件无限维持动作输出。

若执行器只有开环舵机，`MOTOR_TARGET_REACHED` 只能表示控制脉冲已经按计划完成，不能证明机械位置。需要确认锁舌位置时必须增加合适的物理反馈。

## 26.6 任务和事件通路

可以拆成：

```text
BLE ISR / UART DMA
        ↓
BLE Parser / ProtocolTask
        ↓ DoorRequest
Authentication
        ↓ DoorEvent
LockControllerTask
        ↓ MotorCommand
Actuator driver/task
        ↓ feedback / timeout
LockControllerTask
        ↓
UI / audit log / BLE status
```

BLE 接收路径不等待执行器动作完成。LockControllerTask 是状态迁移的唯一所有者，其他任务通过 Queue 或 Task Notification 交付事件，不能直接修改 `DoorState`。

UI 只显示已经确认的状态和故障码。蜂鸣器、LED 或 BLE 返回信息也不要暴露不必要的认证细节，例如具体是哪一段凭据校验失败。

## 26.7 状态迁移集中在一个函数

定义事件：

```c
typedef enum {
    EVT_UNLOCK_REQUEST,
    EVT_LOCK_REQUEST,
    EVT_AUTH_OK,
    EVT_AUTH_FAIL,
    EVT_UNLOCK_CONFIRMED,
    EVT_LOCK_CONFIRMED,
    EVT_AUTOLOCK_TIMEOUT,
    EVT_ACTION_TIMEOUT,
    EVT_LOCAL_RECOVER
} DoorEvent;
```

状态迁移可以先写成无硬件副作用的函数：

```c
DoorState Door_Next(DoorState s, DoorEvent e)
{
    switch (s) {
    case DOOR_BOOT_CHECK:
        if (e == EVT_LOCK_CONFIRMED) return DOOR_SAFE_LOCKED;
        if (e == EVT_ACTION_TIMEOUT) return DOOR_FAULT;
        return s;

    case DOOR_SAFE_LOCKED:
        if (e == EVT_UNLOCK_REQUEST) return DOOR_AUTH_PENDING;
        return s;

    case DOOR_AUTH_PENDING:
        if (e == EVT_AUTH_OK)   return DOOR_UNLOCKING;
        if (e == EVT_AUTH_FAIL || e == EVT_ACTION_TIMEOUT)
            return DOOR_SAFE_LOCKED;
        return s;

    case DOOR_UNLOCKING:
        if (e == EVT_UNLOCK_CONFIRMED) return DOOR_UNLOCKED;
        if (e == EVT_ACTION_TIMEOUT)    return DOOR_FAULT;
        return s;

    case DOOR_UNLOCKED:
        if (e == EVT_LOCK_REQUEST || e == EVT_AUTOLOCK_TIMEOUT)
            return DOOR_LOCKING;
        return s;

    case DOOR_LOCKING:
        if (e == EVT_LOCK_CONFIRMED) return DOOR_SAFE_LOCKED;
        if (e == EVT_ACTION_TIMEOUT)  return DOOR_FAULT;
        return s;

    case DOOR_FAULT:
        if (e == EVT_LOCAL_RECOVER) return DOOR_BOOT_CHECK;
        return s;
    }

    return DOOR_FAULT;
}
```

动作由状态进入逻辑触发。例如进入 `DOOR_UNLOCKING` 时启动一次解锁动作，进入 `DOOR_FAULT` 时停止执行器。这样重复调用状态判断不会反复输出新的 PWM 动作。

还要给认证等待、解锁、上锁分别设置 deadline。具体毫秒值根据认证协议和执行器实测时间确定，再留出明确余量；不要把教学中的 2 秒或 30 秒直接当成通用安全参数。

## 26.8 自动上锁依赖明确的产品条件

自动上锁计时可以在进入 `DOOR_UNLOCKED` 时启动，但什么时候允许真正驱动锁舌，要看机械结构和传感器。若锁舌在门打开时伸出可能造成碰撞，控制逻辑就需要门磁等反馈，在门关闭后再执行锁定。

因此 `EVT_AUTOLOCK_TIMEOUT` 可以表示“自动上锁条件到期”，随后还要检查门状态和故障状态。门磁异常、位置反馈矛盾或执行器不可用时进入定义好的等待或 FAULT 路径。

BLE 断开不应取消已经建立的本地安全计时器。网络连接状态和锁体状态分别维护，避免手机离开以后自动上锁逻辑也一起消失。

## 26.9 认证失败要有可测的限制策略

连续失败可以触发退避、速率限制或本地恢复要求，但阈值和等待时间属于产品策略。教学测试可以使用较短参数快速验证状态机，生产值需要结合威胁模型和可用性要求决定。

计数范围也要定义。按 BLE 连接、用户身份、设备全局或时间窗口统计，会得到不同的安全和拒绝服务特性。简单的“失败 10 次锁 30 秒”只能作为实验策略，不能直接当作完整防暴力破解方案。

认证失败日志记录时间、会话/请求标识和错误类别，不记录 PIN、Secret、挑战响应原文等敏感材料。

## 26.10 状态日志保存迁移证据

每次迁移记录旧状态、事件、请求 ID、新状态、tick 和结果码。例如：

```text
old=SAFE_LOCKED event=UNLOCK_REQ req=105 new=AUTH_PENDING result=accepted
old=AUTH_PENDING event=AUTH_OK req=105 new=UNLOCKING result=ok
old=UNLOCKING event=ACTION_TIMEOUT req=105 new=FAULT result=motor_timeout
```

日志要能区分协议错误、认证失败、重复请求、动作超时和物理反馈异常。BLE Parser 的 CRC error 不应被记成“认证失败”，否则排错和安全统计都会混在一起。

如果日志用于审计，还要另外解决持久化、时间来源、完整性和访问控制。本章串口日志只用于开发验证。

## 26.11 桌面故障测试

先用 LED 和手工输入的 `DoorEvent` 测纯状态机，再接 BLE 和执行器。至少覆盖：

- 正常认证：`BOOT_CHECK → SAFE_LOCKED → AUTH_PENDING → UNLOCKING → UNLOCKED`；
- 重复同一 request ID：返回已有结果，不重复启动执行器；
- CRC 错：Parser 拒绝，DoorState 不变化；
- BLE 断开：自动上锁 deadline 继续运行；
- 解锁或上锁无反馈：停止执行器并进入 FAULT；
- 动作中 MCU 复位：重新进入 BOOT_CHECK，不继承旧 RAM 状态；
- FAULT 下收到无线开锁请求：保持 FAULT；
- 本地恢复：回到 BOOT_CHECK，取得物理锁定反馈后才进入 SAFE_LOCKED；
- 连续认证失败：按当前实验策略限速，并能从日志看到计数变化。

还要测试非法事件。例如在 `DOOR_SAFE_LOCKED` 直接输入 `EVT_AUTH_OK`、在 `DOOR_FAULT` 输入 `EVT_UNLOCK_REQUEST`，状态都不应越过规定边界。

## 26.12 本章完成标准

完成本章时，代码和测试记录至少能回答：

- 上电怎样确认锁体实际状态；
- 哪个任务是 `DoorState` 的唯一写入者；
- BLE 请求在哪一层完成帧校验、去重和认证；
- 同一个请求重发时为什么不会重复驱动执行器；
- 执行器卡住或反馈缺失后何时停止输出；
- BLE 断开后自动上锁逻辑是否继续；
- FAULT 能通过哪些本地条件恢复；
- 哪些日志用于协议排错，哪些属于认证或动作故障。

这些路径在桌面夹具上都能重复验证后，再进入下一章的多协议网关综合项目。

> **上一章**：[第 25 章 · 智能环境监测节点](./25-chapter.md)
>
> **下一章**：[第 27 章 · 综合项目三：多协议智能网关](./27-chapter.md)

# 第 26 章 · 综合项目二：BLE 智能门锁（SPL版）

> **本章产出**：用状态机组织“待机、认证、开锁、自动上锁、故障”流程；理解安全设备不能只靠一次串口命令。
>
> **前置知识**：第 7 章 PWM、第 8 章 UART、第 16 章 FreeRTOS，以及第 19 章 BLE 通信。
>
> **项目目标**：手机通过 BLE 发起开锁请求，设备验证后驱动舵机，并在超时后回到安全状态。

---

## 26.1 这不是“收到 OPEN 就转舵机”

门锁类项目的第一条原则是：默认状态必须安全。无线通信可能丢包、重复包或被伪造，舵机也可能卡住。

因此，先定义状态，而不是先写一串 if：

~~~text
LOCKED
  ├─ 收到认证请求 → AUTHENTICATING
  └─ 管理员复位 → LOCKED

AUTHENTICATING
  ├─ 验证通过 → UNLOCKING
  └─ 超时/失败 → LOCKED

UNLOCKING → UNLOCKED
UNLOCKED
  ├─ 超时 → LOCKING → LOCKED
  └─ 门磁异常 → FAULT
~~~

## 26.2 硬件与安全边界

| 模块 | 作用 | 注意事项 |
|---|---|---|
| BLE 模块 | 接收手机请求 | 串口只是传输层，不自动等于安全 |
| 舵机/电机 | 执行开锁 | 单独供电，共地，防止压降复位 MCU |
| 门磁开关 | 检查门状态 | 可用于防夹和异常检测 |
| 按键 | 本地管理员操作 | 应能在无线失效时恢复控制 |
| 蜂鸣器/LED | 状态提示 | 不要泄露过多认证细节 |

课程原型可以使用固定 PIN 或挑战码理解流程；真实门锁必须使用经过审计的加密、密钥轮换、防重放和物理安全设计。

## 26.3 BLE 消息格式

不要直接把人类可读字符串当作最终协议。先给消息定义类型、序号和校验：

~~~text
SOF | type | seq | payload_len | payload | CRC
~~~

建议至少有：

| type | 含义 |
|---|---|
| AUTH_REQ | 手机请求认证 |
| AUTH_RESP | 设备返回挑战或结果 |
| UNLOCK_REQ | 已认证后的开锁请求 |
| STATUS | 锁状态与错误码 |

seq 用于识别重发；同一个开锁请求不能因为重传执行两次。

## 26.4 舵机控制只是一层驱动

TIM PWM 驱动应该只暴露明确接口：

~~~c
void LockMotor_SetLocked(void);
void LockMotor_SetUnlocked(void);
bool LockMotor_IsAtTarget(void);
~~~

状态机调用接口，而不是在协议解析器中直接改定时器寄存器。这样未来把舵机改成直流电机加限位开关时，上层逻辑不需要重写。

## 26.5 认证任务与执行任务分开

~~~text
Task_BLE_Rx
  → 解析帧 → Queue_Command

Task_LockController
  → 状态机、认证结果、超时
  → 调用 LockMotor 驱动

Task_UI
  → LED、蜂鸣器、显示错误状态
~~~

Task_BLE_Rx 不应等待舵机转完；Task_LockController 也不应在 ISR 中运行。任何耗时动作都应有超时，例如舵机 2 秒内未到位则进入 FAULT。

## 26.6 最小状态机骨架

~~~c
typedef enum {
    LOCKED,
    AUTHENTICATING,
    UNLOCKING,
    UNLOCKED,
    LOCKING,
    FAULT
} LockState;

static LockState state = LOCKED;

static void LockController_Handle(const Command *cmd)
{
    switch (state) {
    case LOCKED:
        if (cmd->type == AUTH_REQ) {
            StartAuthentication(cmd);
            state = AUTHENTICATING;
        }
        break;

    case AUTHENTICATING:
        if (AuthenticationPassed()) {
            LockMotor_SetUnlocked();
            state = UNLOCKING;
        } else if (AuthenticationTimedOut()) {
            state = LOCKED;
        }
        break;

    case UNLOCKING:
        if (LockMotor_IsAtTarget()) {
            StartAutoLockTimer();
            state = UNLOCKED;
        }
        break;

    default:
        break;
    }
}
~~~

这不是完整安全实现，但它展示了一个重要思想：输入事件改变状态，状态决定允许什么动作。

## 26.7 测试矩阵

| 场景 | 预期结果 |
|---|---|
| 正常认证与开锁 | 状态按顺序流转 |
| 重复 UNLOCK_REQ | 只执行一次 |
| 蓝牙断开 | 已有计时器仍能自动上锁 |
| 舵机卡住 | 超时进入 FAULT，不无限供电 |
| 认证失败 10 次 | 触发退避或人工恢复策略 |
| MCU 复位 | 恢复到 LOCKED 或明确的安全恢复流程 |

不要在真实门上第一次测试。先用 LED、逻辑分析仪和桌面夹具模拟状态。

## 26.8 本章练习

1. 用 LED 代替舵机，跑通完整状态机；
2. 给每条 BLE 消息加入 seq 和 CRC；
3. 实现一次认证失败后的 30 秒退避；
4. 为 FAULT 状态设计本地恢复按键流程。

## 26.9 桌面模拟器、命令契约与故障测试

本章的正确第一硬件不是门锁，而是 LED、按键和桌面夹具。不要把第一次固件测试接到真实门、强力执行器或无人看管的设备上。

### 命令先变成数据，再变成动作

~~~c
typedef enum {
    CMD_STATUS,
    CMD_UNLOCK_REQUEST,
    CMD_LOCK_REQUEST
} DoorCommand;

typedef struct {
    uint16_t seq;
    DoorCommand command;
    uint16_t crc;
} DoorRequest;

/* 传输层验证长度、类型、CRC 和序号后才生成 DoorRequest。
   执行任务还要检查当前状态、认证结果、超时与物理反馈。 */
~~~

| 层 | 可以做什么 | 绝不能做什么 |
|---|---|---|
| UART/BLE ISR | 搬字节、记录溢出 | 直接驱动舵机/电机 |
| BLE/协议任务 | 校验帧、生成请求、回 ACK | 绕过认证改变锁状态 |
| 状态机 | 判断是否允许一次动作 | 假定执行器一定成功 |
| 执行器任务 | 输出受限 PWM、等待反馈/超时 | 持续堵转或无限等待 |
| 监控任务 | 记录错误、显示状态 | 自动忽略反复失败 |

### 桌面测试矩阵

| 场景 | 操作 | 安全预期 |
|---|---|---|
| 正常请求 | 合法 `UNLOCK_REQUEST` | LED/小功率测试负载进入短暂“开”状态并返回 ACK |
| 重放 | 重复同一 seq | 拒绝或幂等，不重复执行 |
| CRC 错误 | 修改一字节 | 只记录错误，状态不变 |
| 认证失败 | 发送无权限请求 | 进入退避/报警状态，状态不变 |
| 执行器无反馈 | 模拟开关未到位 | 在超时后进入 FAULT，不持续输出 |
| 断电重启 | 在动作中复位 | 启动时回到明确的安全状态 |

### 供电边界

舵机、电机和锁体通常需要独立供电路径；它们的峰值电流不能由 ZET6 的 3.3V 小接口承担。控制信号和电源地是否共地、是否需要隔离、如何限流，都应由真实执行器规格与电路设计决定。

练习：先把 `UNLOCK_REQUEST` 映射为 LED 闪烁，完成上表所有测试后，才考虑在受控桌面环境替换为低风险执行器。

## 26.10 安全状态迁移必须可以逐步审查

把状态机写成显式的“事件 + 当前状态 → 下一个状态”，不要把动作散落在 BLE 回调里：

~~~c
typedef enum {
    DOOR_SAFE_LOCKED,
    DOOR_AUTH_PENDING,
    DOOR_ACTUATING,
    DOOR_VERIFYING,
    DOOR_FAULT
} DoorState;

typedef enum {
    EVT_UNLOCK_REQUEST,
    EVT_AUTH_OK,
    EVT_AUTH_FAIL,
    EVT_ACTUATOR_DONE,
    EVT_TIMEOUT,
    EVT_RESET
} DoorEvent;

/* 教学伪代码：动作由单独的执行器任务完成；
   状态机只决定“是否允许请求”和“何时超时”。 */
DoorState Door_Next(DoorState s, DoorEvent e)
{
    switch (s) {
    case DOOR_SAFE_LOCKED:
        return e == EVT_UNLOCK_REQUEST ? DOOR_AUTH_PENDING : s;
    case DOOR_AUTH_PENDING:
        if (e == EVT_AUTH_OK)   return DOOR_ACTUATING;
        if (e == EVT_AUTH_FAIL || e == EVT_TIMEOUT) return DOOR_SAFE_LOCKED;
        return s;
    case DOOR_ACTUATING:
        if (e == EVT_ACTUATOR_DONE) return DOOR_VERIFYING;
        if (e == EVT_TIMEOUT)       return DOOR_FAULT;
        return s;
    case DOOR_VERIFYING:
        return e == EVT_RESET ? DOOR_SAFE_LOCKED : s;
    case DOOR_FAULT:
        return e == EVT_RESET ? DOOR_SAFE_LOCKED : s;
    }
    return DOOR_FAULT;
}
~~~

真实产品还需要物理反馈、权限模型、审计、异常断电策略和合规审查；本章不把这个骨架宣传为安全门锁实现。

### 事件追踪与超时

每次状态迁移都记录：旧状态、事件、请求 seq、新状态、tick、失败码。这样才能复盘“为什么没开”“为什么重复动作”“为什么进入 FAULT”。

| 迁移 | 需要的证据 |
|---|---|
| 请求 → 认证 | 帧长度/CRC/seq 合法，且来源连接状态有效 |
| 认证 → 动作 | 认证结果未过期，动作任务可用 |
| 动作 → 验证 | 执行器反馈或受控时间窗口，不是简单 delay |
| 任意 → FAULT | 具体超时/反馈/供电错误码 |
| FAULT → 安全锁定 | 明确的本地恢复/受控复位，不是无线字符串 |

练习：用一张状态迁移日志驱动 LED 模拟器：不发送任何 BLE 字节，只手工喂 `DoorEvent`，验证所有非法事件都不会离开安全锁定状态。

## 26.11 本章要点

- 锁的核心是状态机和安全边界，不是 PWM；
- 传输层收到的数据绝不能直接变成执行动作；
- 所有执行器都需要超时、反馈和故障状态；
- 认证、控制与 UI 应由不同任务负责；
- 教学原型不能被误认为量产安全方案。

---

[上一章：第 25 章 · 智能环境监测节点](./25-chapter.md)

[下一章：第 27 章 · 综合项目三：多协议智能网关](./27-chapter.md)

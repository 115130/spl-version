# 第 21 章 · MQTT：让设备持续发布数据（SPL版）

> **本章产出**：理解 Broker、Client、Topic、QoS 的职责；能在已有的 WiFi AT + TCP 通道上完成一次 MQTT CONNECT 和 PUBLISH。
>
> **前置知识**：第 18 章的 WiFi AT 封装，以及第 20 章的 TCP 连接。
>
> **用在哪**：环境监测节点、云端数据上报、多协议网关。
>
> **实验环境**：已验证的 WiFi AT + TCP 通道和一个你可控制的教学 Broker；第一轮使用局域网/测试账号，不把真实云端密钥写进固件。
>
> **通过标准**：先收到正确的 CONNACK，再看到本地订阅端收到带递增序号的 PUBLISH；断开 Broker 后能退避重连。

---

## 21.1 为什么不继续直接发 TCP 包

第 20 章中，温度记录仪已经能通过 TCP 把 TempPacket 发给自己的 PC 网关。这种方式很适合学习协议和局域网调试，但它有一个限制：每个设备都必须知道服务器地址、端口和自定义包格式。

MQTT 把这件事拆开：

| 角色 | 做什么 | 你可以把它想成 |
|---|---|---|
| Client | 发布或订阅消息的设备、程序 | 温度记录仪、手机、PC 程序 |
| Broker | 接收消息并转发给订阅者 | 邮局 |
| Topic | 消息的主题路径 | 邮件地址 |
| Payload | 真正传递的数据 | 信件内容 |

设备只需要说“把这条消息发布到 sensors/room1/temperature”，Broker 决定把它转给哪些订阅者。这样，设备不必知道手机或网页在哪里。

## 21.2 第一套 Topic 设计

Topic 一旦被很多设备使用，就很难随意改名。先把结构设计清楚：

~~~text
school-lab/
  room-01/
    temperature
    humidity
    status
    command
~~~

建议把“遥测数据”和“控制命令”分开：

| Topic | 方向 | 例子 |
|---|---|---|
| school-lab/room-01/temperature | 设备 → 云 | 24.6 |
| school-lab/room-01/status | 设备 → 云 | online |
| school-lab/room-01/command | 云 → 设备 | led=on |

不要把 WiFi 密码、设备密钥或调试日志直接放在 Topic 或 Payload 中。

## 21.3 复用第 18 章的 AT + TCP 通道

MQTT 不是新的无线协议。对 STM32 来说，它只是“通过已建立的 TCP 连接发送另一种格式的字节流”。

先确认下面三件事已经能工作：

1. WiFi 模块能连上路由器；
2. AT+CIPSTART 已经建立到 Broker 的 TCP 连接；
3. 你能发送原始字节，并等待模块返回 SEND OK。

下面的函数只展示发送层的职责。AT_SendCmd、AT_WaitResponse 和 UART 原始发送函数应来自第 18 章的 WiFi 驱动。

~~~c
static int TCP_SendRaw(const uint8_t *data, uint16_t len)
{
    char cmd[32];

    snprintf(cmd, sizeof(cmd), "AT+CIPSEND=%u", (unsigned)len);
    AT_SendCmd(cmd);
    if (!AT_WaitResponse(">", 5000)) {
        return -1;
    }

    for (uint16_t i = 0; i < len; ++i) {
        while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET) {
        }
        USART_SendData(USART2, data[i]);
    }

    return AT_WaitResponse("SEND OK", 10000) ? 0 : -1;
}
~~~

这段代码的重点是：原始 MQTT 字节不能被 AT_SendCmd 自动追加回车换行。AT 命令和 MQTT 报文是两段不同的数据。

## 21.4 CONNECT：向 Broker 说“我来了”

一个 MQTT CONNECT 报文包含四类信息：

| 字段 | 用途 |
|---|---|
| 固定头 | 表示这是 CONNECT 报文 |
| 协议名和版本 | 常见的是 MQTT 3.1.1 |
| 连接标志 | 是否保留会话、是否有用户名密码等 |
| Client ID | 此次连接的设备身份 |

学习阶段先使用短 Client ID 和短报文。MQTT 的 Remaining Length 使用可变长度编码；当报文小于 128 字节时，课堂示例只需一个字节，但正式驱动必须实现完整编码。

连接流程如下：

~~~text
STM32                  Broker
  |---- CONNECT ------->|
  |<--- CONNACK --------|
  |---- PUBLISH ------->|
~~~

收到 CONNACK 前，不要开始发布业务数据。若 Broker 拒绝连接，应把返回码打印到调试串口，而不是盲目重试。

## 21.5 PUBLISH：把温度变成一条消息

发布一条 QoS 0 温度消息至少需要：

1. 固定头：PUBLISH + QoS 0；
2. Topic 长度和 Topic 字节；
3. Payload，例如 24.6 或一个 JSON 对象。

课堂上的第一个目标可以非常小：

~~~text
Topic:   school-lab/room-01/temperature
Payload: 24.6
QoS:     0
~~~

QoS 0 的含义是“尽力而为”。它适合频繁的温度采样，但不适合开锁、继电器断电等不能丢的控制命令。控制类消息至少要设计确认、超时和幂等性，不能只依赖一次 PUBLISH。

## 21.6 断线与重连

物联网设备一定会遇到断线：路由器重启、信号弱、Broker 升级、服务器证书过期都可能发生。把重连放进一个独立任务，而不是散落在每个传感器任务里。

~~~text
未连接 → 建立 TCP → CONNECT → 已连接
   ↑                         |
   └──── 超时/发送失败 ───────┘
~~~

建议的最小策略：

- 连续失败时逐步拉长重试间隔，避免每毫秒刷 AT 命令；
- 重新连接成功后先发布 status=online；
- 每次发送失败都保留一条可读日志；
- 业务数据是否缓存到 SD 卡，由项目需求决定。

## 21.7 本章练习

1. 用 PC 上的 MQTT 客户端订阅 school-lab/room-01/#；
2. 让 STM32 每 10 秒发布一次温度；
3. 断开路由器 30 秒，再恢复网络，观察设备是否能重连；
4. 给每条上报数据加入 seq 字段，检查是否有重复或缺失。

## 21.8 QoS、会话与遗嘱消息

最小 PUBLISH 只是 MQTT 的起点。项目设计时还应知道：

| 功能 | 作用 | 入门项目建议 |
|---|---|---|
| QoS 0 | 尽力发送，不确认 | 高频温度遥测可使用 |
| QoS 1 | 至少送达一次，可能重复 | 重要告警需处理重复 |
| retain | Broker 保留最后一条消息 | 可用于最后状态 |
| Keep Alive | 定期证明连接仍活着 | 设定超时和重连 |
| LWT 遗嘱 | 异常断线时由 Broker 发布离线状态 | 用于 status Topic |
| 持久会话 | 重连后恢复订阅 | 根据 RAM/模块能力选择 |

所有这些能力都依赖具体 Broker 和 AT 模块的 TCP 稳定性。先完成 QoS 0 + 明确重连，再逐步增加复杂性。

## 21.9 最小 MQTT 3.1.1 报文：先能看懂，再交给 AT 发送

MQTT 的 TCP 连接成功不等于 MQTT 连接成功。第一包必须是 CONNECT，Broker 返回成功 CONNACK 后才能 PUBLISH。下面是一个**只用于首个实验**的 CONNECT 组包器：它使用 Clean Session、无用户名密码，且缓冲区大小受限；生产环境还要按平台要求加入认证、TLS 与完整错误处理。

~~~c
static bool put_u8(uint8_t *b, size_t cap, size_t *p, uint8_t v)
{
    if (*p >= cap) return false;
    b[(*p)++] = v;
    return true;
}

static bool put_u16(uint8_t *b, size_t cap, size_t *p, uint16_t v)
{
    return put_u8(b, cap, p, (uint8_t)(v >> 8)) &&
           put_u8(b, cap, p, (uint8_t)v);
}

static bool put_utf8(uint8_t *b, size_t cap, size_t *p, const char *s)
{
    size_t n = strlen(s);
    if (n > 0xffff) return false;
    if (!put_u16(b, cap, p, (uint16_t)n)) return false;
    while (*s) if (!put_u8(b, cap, p, (uint8_t)*s++)) return false;
    return true;
}

/* MQTT Remaining Length 是变长编码，不能只写一个字节。 */
static bool put_remaining_length(uint8_t *b, size_t cap, size_t *p, size_t n)
{
    do {
        uint8_t byte = n % 128;
        n /= 128;
        if (n) byte |= 0x80;
        if (!put_u8(b, cap, p, byte)) return false;
    } while (n);
    return true;
}

bool Mqtt_BuildConnect(uint8_t *out, size_t cap,
                       const char *client_id, uint16_t keep_alive,
                       size_t *out_len)
{
    size_t id_len = strlen(client_id);
    size_t remaining = 10 + 2 + id_len;  /* variable header + payload */
    size_t p = 0;

    if (!put_u8(out, cap, &p, 0x10)) return false;  /* CONNECT */
    if (!put_remaining_length(out, cap, &p, remaining)) return false;
    if (!put_u16(out, cap, &p, 4)) return false;
    if (!put_u8(out, cap, &p, 'M') || !put_u8(out, cap, &p, 'Q') ||
        !put_u8(out, cap, &p, 'T') || !put_u8(out, cap, &p, 'T')) return false;
    if (!put_u8(out, cap, &p, 4)) return false;     /* MQTT 3.1.1 */
    if (!put_u8(out, cap, &p, 0x02)) return false;  /* Clean Session */
    if (!put_u16(out, cap, &p, keep_alive)) return false;
    if (!put_utf8(out, cap, &p, client_id)) return false;
    *out_len = p;
    return true;
}
~~~

CONNACK 的最小成功帧是 `20 02 00 00`：固定头 `0x20`、剩余长度 2、会话标志 0、返回码 0。收到其他返回码时，记录它并停止业务发送；不要把“TCP 已连接”当作“Broker 已接受”。

### 第一条 PUBLISH 和 Keep Alive

QoS 0 的 PUBLISH 固定头为 `0x30`。Remaining Length 后先写 Topic 的 UTF-8 长度和内容，再写 payload。第一轮实验可以发送短文本：

~~~text
topic:   lab/zet6-01/telemetry
payload: {"seq":17,"t":2534}
~~~

每条 payload 加 `seq`，这样订阅端能分辨重连、重复和丢失。Keep Alive 到期前发送 PINGREQ（`C0 00`），等待 PINGRESP（`D0 00`）；超时则回到第 17 章的 BACKOFF 状态。

### Broker 实验与排错

在你控制的 PC 上启动一个教学 Broker，并用独立终端订阅 `lab/#`。不要以公开 Broker 或真实产品账号作为第一站。

| 现象 | 优先检查 |
|---|---|
| TCP 建好但没有 CONNACK | CONNECT Remaining Length、协议名/级别、Client ID、认证要求 |
| CONNACK 返回拒绝码 | Broker 权限、Client ID 冲突、用户名/密码或平台规则 |
| 订阅端没有 PUBLISH | Topic 拼写、PUBLISH 长度、AT 发送的字节数、是否等待 ONLINE |
| 很快断线 | Keep Alive、无线稳定性、模块 TCP 状态、重连风暴 |
| 数据重复 | QoS 1 或重连重发；用 seq 在应用层幂等处理 |

练习：先实现 QoS 0 的一发一收；随后让 Broker 重启，记录第一次失败、退避、重新 CONNACK 和恢复发布的时间线。

## 21.10 QoS 0 PUBLISH 组包与 broker 回放测试

首个实验的发布可以保持 QoS 0、无 retain，但 Topic 和 payload 都必须计入 Remaining Length：

~~~c
bool Mqtt_BuildPublish(uint8_t *out, size_t cap,
                       const char *topic,
                       const uint8_t *payload, size_t payload_len,
                       size_t *out_len)
{
    size_t topic_len = strlen(topic);
    size_t remaining = 2 + topic_len + payload_len;
    size_t p = 0;

    if (topic_len > 0xffff) return false;
    if (!put_u8(out, cap, &p, 0x30)) return false;  /* PUBLISH, QoS 0 */
    if (!put_remaining_length(out, cap, &p, remaining)) return false;
    if (!put_utf8(out, cap, &p, topic)) return false;
    if (p + payload_len > cap) return false;
    memcpy(out + p, payload, payload_len);
    p += payload_len;
    *out_len = p;
    return true;
}
~~~

这个函数不包含 QoS 1 的 packet identifier、retain 或认证。先把它测对，再逐项增加：

| 版本 | 新增内容 | 新的验证点 |
|---|---|---|
| V0 | CONNECT + QoS 0 PUBLISH | CONNACK、订阅端 payload |
| V1 | PINGREQ/PINGRESP | 空闲连接不会超时 |
| V2 | QoS 1 | PUBACK、重复消息的 seq 处理 |
| V3 | retain/LWT | 新订阅者与异常断线状态 |
| V4 | 平台认证/TLS | 以官方文档和模块能力为准 |

### 字节级回放测试

保存一次已知正确的 CONNECT、CONNACK、PUBLISH 和 PINGRESP 十六进制序列。无需连接网络也能用它们测试：

- Remaining Length 变长编码；
- CONNACK 返回码；
- PINGRESP 超时；
- 多个 MQTT 包粘在同一 TCP 片段；
- 一个 MQTT 包被拆进多个 TCP 片段。

这是把“协议偶尔能连上”升级为“解析器可重复验证”的关键步骤。

## 21.11 为 MQTT 明确“已实现的子集”与接收状态机

本章的入门发送器只适合一个很小的 MQTT 3.1.1 子集：短 Client ID、Clean Session、QoS 0 遥测、显式等待 CONNACK。把这条边界写出来，比给读者一个看似万能的组包函数更重要。

| 功能 | 本章最小实现 | 后续实现前必须补的状态 |
|---|---|---|
| CONNECT | 无用户名/密码、无遗嘱、Clean Session | 平台认证字段、遗嘱、会话恢复 |
| PUBLISH | QoS 0、长度受限 | QoS 1 的 packet id、PUBACK、重传与 DUP 标志 |
| 收包 | CONNACK / PINGRESP 等少量控制包 | 完整固定头、Remaining Length、多帧连续输入 |
| Keep Alive | 空闲时发送 PINGREQ，等待 PINGRESP | `last_tx/last_rx`、超时关闭与重连 |
| TLS | 不在这个裸 TCP 入门例程中保证 | 模块 TLS、SNI、证书、时间和内存评估 |

### Remaining Length 必须按字节流解析

MQTT 的固定头后是可变长 Remaining Length。接收端不能假定一个 UART 回调里有完整报文，也不能只支持一个字节后就悄悄解析错误。一个受限解析器至少维护：

~~~text
FIXED_HEADER
  → REMAINING_LENGTH（最多 4 字节；乘数 1、128、16384、2097152）
  → BODY（累计到声明长度）
  → 产生一条 MQTT 事件，再回到 FIXED_HEADER
~~~

每一步都检查：Remaining Length 是否超过你的接收上限、编码是否超过 4 字节、Body 是否超时、同一缓冲区里是否紧跟下一帧。这个解析器应通过“1 字节一喂、两帧粘连、超长长度、半包超时”的回放测试。

### QoS 1 不是给 QoS 0 加一个数字

控制命令若需要 QoS 1，最小状态机是：

~~~text
IDLE → 分配 packet_id → 发送 PUBLISH(QoS1) → WAIT_PUBACK
  ├─ 收到匹配 packet_id 的 PUBACK → DONE
  └─ 超时/断线 → 按策略重连并决定是否带 DUP 重发
~~~

`packet_id`、业务 `seq` 和执行结果是三件事。即使 Broker 已回 PUBACK，设备也不能因此假定“远端执行器已经完成动作”；控制协议仍需自己的 ACK、超时和幂等设计。

## 21.12 本章要点

- MQTT 运行在 TCP 之上，SPL 的工作重点仍是 UART 和 AT 发送；
- Broker 负责转发，Topic 负责组织数据，Payload 才是实际内容；
- CONNECT 成功并收到 CONNACK 后，才能开始业务通信；
- 发布遥测数据与执行控制命令，可靠性要求不同；
- 重连逻辑必须独立、可观察、可限速。

---

[上一章：第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

[下一章：第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)

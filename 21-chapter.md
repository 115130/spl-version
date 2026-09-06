# 第 21 章 · MQTT：让设备持续发布数据（SPL 版）

第 20 章已经把温度记录仪接到 TCP 服务端。本章在同一条 WiFi AT + TCP 通道上加入 MQTT 3.1.1，先完成 CONNECT、CONNACK、QoS 0 PUBLISH 和 Keep Alive，再讨论 QoS 1、retain 和遗嘱消息。

第一轮实验使用自己能控制的教学 Broker 和测试账号。真实平台的认证、TLS、证书和时间同步留到后续章节处理。

## 21.1 MQTT 在现有链路里增加了什么

直接使用 TCP 时，设备和 PC 网关共同约定第 18 章的二进制帧。MQTT 在 TCP 字节流上增加 Broker、Topic 和控制报文，让发布者与订阅者不需要直接建立彼此的连接。

本章只需要记住四个对象：

- **Client**：连接 Broker 的设备或程序；STM32 和 PC 订阅工具都属于 Client。
- **Broker**：接受 Client 连接，并按 Topic 转发消息。
- **Topic**：消息的主题名，例如 `lab/zet6-01/telemetry`。
- **Payload**：Topic 下实际携带的字节，可以是文本、JSON 或二进制。

Broker 解决的是消息路由。设备仍然要处理 WiFi、TCP、MQTT 会话、缓存和重连；Broker 也不会自动保证一条业务命令只执行一次。

## 21.2 先固定 Topic

本章使用下面几个 Topic：

```text
lab/zet6-01/telemetry
lab/zet6-01/status
lab/zet6-01/command
```

`telemetry` 发布温湿度和 `seq`，`status` 发布在线状态和错误信息，`command` 留给后续控制实验。设备密钥、WiFi 密码等凭据不要放进 Topic 或普通遥测 Payload。

多个设备接入时，把设备标识放在 Topic 的固定层级，例如 `lab/<device-id>/telemetry`。Topic 是应用协议的一部分，手机、网关和云端都可能依赖它，改名时需要一起升级这些组件。

## 21.3 MQTT 字节通过第 20 章的 TCP 通道发送

对 STM32 来说，MQTT 报文就是一段二进制数据。AT 命令和 MQTT 数据必须分开：先用 `AT+CIPSEND=<len>` 进入发送阶段，再原样发送 MQTT 字节，不能让命令发送函数自动追加 `\r\n`。

```c
static int TCP_SendRaw(const uint8_t *data, uint16_t len)
{
    char cmd[32];

    snprintf(cmd, sizeof cmd, "AT+CIPSEND=%u", (unsigned)len);
    AT_SendCmd(cmd);

    if (!AT_WaitResponse(">", 5000U))
        return -1;

    for (uint16_t i = 0; i < len; ++i) {
        while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET) {
        }
        USART_SendData(USART2, data[i]);
    }

    return AT_WaitResponse("SEND OK", 10000U) ? 0 : -1;
}
```

这里的 5 s 和 10 s 都是实验超时策略，要按模块手册和实际网络环境调整。`SEND OK` 只表示模块接受并完成了它定义的发送流程，不能把它当成 Broker 已处理 MQTT 报文的证明。MQTT 层仍要等待 CONNACK、PUBACK 等对应协议事件。

实际工程还应避免让多个任务同时调用这类 AT 发送函数。第 17、18 章已经把无线模块所有权集中到通信任务，本章继续沿用这个边界。

## 21.4 CONNECT 和 CONNACK

TCP 连接建立后，MQTT Client 首先发送 CONNECT。MQTT 3.1.1 的 CONNECT 包含协议名、协议级别、连接标志、Keep Alive，以及 Client ID 等 Payload 字段。

本章第一版使用：

```text
Protocol:      MQTT 3.1.1
Clean Session: 1
Username:      无
Password:      无
Will:          无
Client ID:     zet6-01
```

下面的辅助函数按 MQTT 的网络字节序写 16 位长度，并实现 Remaining Length 的可变长度编码：

```c
static bool put_u8(uint8_t *buf, size_t cap, size_t *pos, uint8_t value)
{
    if (*pos >= cap)
        return false;

    buf[(*pos)++] = value;
    return true;
}

static bool put_u16_be(uint8_t *buf, size_t cap, size_t *pos, uint16_t value)
{
    return put_u8(buf, cap, pos, (uint8_t)(value >> 8)) &&
           put_u8(buf, cap, pos, (uint8_t)value);
}

static bool put_utf8(uint8_t *buf, size_t cap, size_t *pos, const char *text)
{
    size_t len = strlen(text);

    if (len > UINT16_MAX)
        return false;
    if (!put_u16_be(buf, cap, pos, (uint16_t)len))
        return false;
    if (*pos + len > cap)
        return false;

    memcpy(buf + *pos, text, len);
    *pos += len;
    return true;
}

static bool put_remaining_length(uint8_t *buf, size_t cap,
                                 size_t *pos, size_t value)
{
    if (value > 268435455U)
        return false;

    do {
        uint8_t encoded = (uint8_t)(value % 128U);
        value /= 128U;

        if (value != 0U)
            encoded |= 0x80U;
        if (!put_u8(buf, cap, pos, encoded))
            return false;
    } while (value != 0U);

    return true;
}
```

CONNECT 组包器可以写成：

```c
bool Mqtt_BuildConnect(uint8_t *out, size_t cap,
                       const char *client_id,
                       uint16_t keep_alive,
                       size_t *out_len)
{
    size_t id_len = strlen(client_id);
    size_t remaining;
    size_t pos = 0U;

    if (id_len > UINT16_MAX)
        return false;

    /* variable header 10 字节；payload 是 2 字节长度 + Client ID。 */
    remaining = 10U + 2U + id_len;

    if (!put_u8(out, cap, &pos, 0x10U)) return false;
    if (!put_remaining_length(out, cap, &pos, remaining)) return false;
    if (!put_u16_be(out, cap, &pos, 4U)) return false;

    if (!put_u8(out, cap, &pos, 'M') ||
        !put_u8(out, cap, &pos, 'Q') ||
        !put_u8(out, cap, &pos, 'T') ||
        !put_u8(out, cap, &pos, 'T'))
        return false;

    if (!put_u8(out, cap, &pos, 4U)) return false;     /* protocol level */
    if (!put_u8(out, cap, &pos, 0x02U)) return false;  /* Clean Session */
    if (!put_u16_be(out, cap, &pos, keep_alive)) return false;
    if (!put_utf8(out, cap, &pos, client_id)) return false;

    *out_len = pos;
    return true;
}
```

对于这组参数，成功的 MQTT 3.1.1 CONNACK 是 `20 02 00 00`。第三个字节是 Session Present，第四个字节是返回码。只有返回码为 0 才进入 MQTT 在线状态；其他返回码应记录下来，再按错误类型处理认证、Client ID 或 Broker 配置。

不要只用 `memcmp(buf, "\x20\x02\x00\x00", 4)` 处理所有接收情况。TCP 和 AT 外层都可能拆包或粘包，MQTT 接收器仍需要按字节流解析。

## 21.5 QoS 0 PUBLISH

第一条遥测消息使用 QoS 0：

```text
Topic:   lab/zet6-01/telemetry
Payload: {"seq":17,"t":2534}
```

`2534` 表示 25.34 °C，与前面章节使用的摄氏度百分之一单位保持一致。Payload 中继续保留业务 `seq`，订阅端可以据此发现缺失、重复或重连后的跳变。

QoS 0 PUBLISH 的固定头是 `0x30`。Topic 长度、Topic 和 Payload 都计入 Remaining Length：

```c
bool Mqtt_BuildPublishQos0(uint8_t *out, size_t cap,
                           const char *topic,
                           const uint8_t *payload, size_t payload_len,
                           size_t *out_len)
{
    size_t topic_len = strlen(topic);
    size_t remaining;
    size_t pos = 0U;

    if (topic_len > UINT16_MAX)
        return false;
    if (payload_len > 268435455U - 2U - topic_len)
        return false;

    remaining = 2U + topic_len + payload_len;

    if (!put_u8(out, cap, &pos, 0x30U)) return false;
    if (!put_remaining_length(out, cap, &pos, remaining)) return false;
    if (!put_utf8(out, cap, &pos, topic)) return false;
    if (pos + payload_len > cap) return false;

    memcpy(out + pos, payload, payload_len);
    pos += payload_len;

    *out_len = pos;
    return true;
}
```

QoS 0 没有 PUBACK。`TCP_SendRaw()` 返回成功以后，本地没有 MQTT 级确认能证明 Broker 已接收这条 PUBLISH。对于周期遥测，可以接受这种语义，并通过后续样本继续更新状态。

## 21.6 Keep Alive 需要状态，不是定时无条件发 PINGREQ

CONNECT 中的 Keep Alive 是客户端与 Broker 的 MQTT 会话参数。客户端必须保证相邻 MQTT Control Packet 的发送间隔不超过 Keep Alive；Broker 在约 1.5 倍 Keep Alive 时间内没有收到客户端控制报文时，可以断开连接。

因此 PUBLISH 本身也会刷新发送活动时间。只有连接空闲、接近 Keep Alive 边界时才需要发送 PINGREQ：

```text
MQTT_ONLINE
  ├─ 正常发送 PUBLISH ─────────────→ 更新 last_tx
  ├─ 空闲接近 Keep Alive ──────────→ PINGREQ → WAIT_PINGRESP
  ├─ 收到 PINGRESP ────────────────→ MQTT_ONLINE
  └─ TCP/MQTT 超时或协议错误 ─────→ BACKOFF
```

PINGREQ 是 `C0 00`，PINGRESP 是 `D0 00`。PINGRESP 超时意味着当前会话不能继续信任，应关闭旧连接并进入统一的重连流程。

Keep Alive 为 0 时，协议不要求这种保活检查。本章实验建议使用非零值，并记录 `last_tx`、最后一次 PINGREQ 时间和 PINGRESP 超时次数。

## 21.7 MQTT 接收器按字节流工作

MQTT 固定头的第一个字节之后是 Remaining Length。这个字段最多占 4 字节，最大合法值为 268435455。接收器不能假定一次 UART/AT 回调就包含一条完整 MQTT 报文。

一个受限解析器至少维护这些状态：

```text
FIXED_HEADER
    ↓
REMAINING_LENGTH
    ↓
BODY
    ↓
DISPATCH
    └── 回到 FIXED_HEADER
```

解析 Remaining Length 时，每个字节低 7 位参与数值，高位表示后面还有字节。遇到超过 4 字节的编码、声明长度超过本地接收上限或 Body 超时，都应丢弃当前连接并记录协议错误；不要根据网络输入申请无上限内存。

同一个输入片段里可能连续出现 CONNACK 和其他控制报文，一条 MQTT 报文也可能跨多个 TCP/AT Payload。解析器每产生一个完整事件后继续处理剩余字节，不能提前返回并丢掉后面的数据。

## 21.8 网络状态机只保留一个重连入口

MQTT 加入后，通信任务至少区分 TCP 和 MQTT 两层状态：

```text
WIFI_OFFLINE
    ↓
TCP_CONNECTING
    ↓
MQTT_CONNECTING
    ↓ CONNACK success
MQTT_ONLINE
    │
    └─ TCP close / timeout / protocol error
                ↓
             BACKOFF
                ↓
          TCP_CONNECTING
```

SensorTask 不直接连接 Broker，也不在发送失败后自己调用 `AT+CIPSTART`。所有 WiFi、TCP 和 MQTT 重连都由同一个通信任务处理，避免多个任务同时操作 AT 模块。

连续失败时逐步增加退避时间并设置上限。具体初值和上限属于项目策略，本章不写成协议规定。每次失败记录当前状态、错误原因和累计次数，恢复后再继续发布新样本或按项目策略处理缓存。

## 21.9 QoS 0、QoS 1、retain 和 LWT

这些功能解决的问题不同：

| 功能 | 协议语义 | 本章使用方式 |
|---|---|---|
| QoS 0 | PUBLISH 后没有 MQTT 确认 | 周期遥测 |
| QoS 1 | Broker/接收方按协议确认 PUBLISH，消息可能重复 | 后续重要消息实验 |
| retain | Broker 保存该 Topic 的最后一条 retained 消息 | 可用于当前状态 |
| LWT | Client 异常断开后，由 Broker 按 CONNECT 中的 Will 配置发布 | 可用于离线状态 |
| Keep Alive | 限制客户端控制报文的最大空闲发送间隔 | 检测失效会话 |

QoS 1 提供的是“至少一次”交付语义，因此重复 PUBLISH 是正常情况。应用层仍应保留业务 `seq` 或命令 ID，避免重复执行有副作用的操作。

QoS 1 还需要 Packet Identifier 和 PUBACK 状态。MQTT 的 Packet Identifier 用于协议事务，业务 `seq` 用于业务数据，两者不要混用：

```text
IDLE
  ↓ 分配 packet_id
SEND_QOS1
  ↓
WAIT_PUBACK
  ├─ 收到匹配 packet_id → 完成本次 MQTT 事务
  └─ 断线/超时 → 按 MQTT 会话与重发策略处理
```

即使收到 PUBACK，也只能说明 QoS 1 的 MQTT 交付阶段完成。远端执行器是否已经完成“开继电器”等业务动作，需要另外定义业务 ACK。

## 21.10 会话语义要和协议版本对应

本章固定 MQTT 3.1.1，因此 CONNECT 标志叫 **Clean Session**。Clean Session 为 1 时，客户端断开后 Broker 不保留该客户端的持久会话状态；重新连接后需要重新建立订阅等状态。

如果以后切换到 MQTT 5.0，相关字段和会话规则会变成 Clean Start、Session Expiry Interval 等概念。不要把 MQTT 5.0 的字段名直接套进本章 3.1.1 报文。

本章的设备只做发布，因此暂时没有 SUBSCRIBE。后续加入 `command` 订阅时，重连成功并收到 CONNACK 后还要恢复订阅；是否能依赖持久会话，要根据 Clean Session 设置和 Broker 返回的 Session Present 判断。

## 21.11 回放测试

保存一组已验证的 MQTT 十六进制数据，可以在没有 WiFi 的情况下测试解析器。至少覆盖：

1. 一个字节一个字节喂入成功 CONNACK；
2. 两个 MQTT Control Packet 粘在同一个输入缓冲区；
3. Remaining Length 使用 2 个字节的报文；
4. Remaining Length 超过 4 字节；
5. 声明 Body 长度超过本地缓冲区；
6. PINGRESP 被拆成两次输入；
7. CONNACK 返回非零错误码。

网络联调时再做三组测试：正常发布、Broker 重启、WiFi 断开恢复。每次记录从第一次错误到重新收到成功 CONNACK 的状态变化，不要只看最终是否又开始出数据。

## 21.12 本章完成标准

先在 PC 上启动一个可控 Broker，并用另一个客户端订阅 `lab/zet6-01/#`。设备完成下面几项后，本章即可收尾：

- TCP 建立后发送 CONNECT，并解析成功 CONNACK；
- 每个遥测 Payload 带递增 `seq`，订阅端能看到数据；
- 空闲时能完成 PINGREQ/PINGRESP；
- Broker 停止后设备进入退避，不持续刷连接请求；
- Broker 恢复后重新 CONNECT，再恢复发布；
- 调试输出能区分 TCP 失败、CONNACK 拒绝、PINGRESP 超时和 PUBLISH 发送失败。

完成这些测试后，再加入用户名密码、QoS 1、retain 或 LWT。一次只增加一个协议状态，出现问题时才能确定是哪一层出了错。

> **上一章**：[第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)
>
> **下一章**：[第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)

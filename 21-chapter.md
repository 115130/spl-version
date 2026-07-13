# 第 21 章 · MQTT：让设备持续发布数据（SPL版）

> **本章产出**：理解 Broker、Client、Topic、QoS 的职责；能在已有的 WiFi AT + TCP 通道上完成一次 MQTT CONNECT 和 PUBLISH。
>
> **前置知识**：第 18 章的 WiFi AT 封装，以及第 20 章的 TCP 连接。
>
> **用在哪**：环境监测节点、云端数据上报、多协议网关。

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

## 21.9 本章要点

- MQTT 运行在 TCP 之上，SPL 的工作重点仍是 UART 和 AT 发送；
- Broker 负责转发，Topic 负责组织数据，Payload 才是实际内容；
- CONNECT 成功并收到 CONNACK 后，才能开始业务通信；
- 发布遥测数据与执行控制命令，可靠性要求不同；
- 重连逻辑必须独立、可观察、可限速。

---

[上一章：第 20 章 · TCP/IP 协议栈与温度记录仪](./20-chapter.md)

[下一章：第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)

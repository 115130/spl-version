# 第 20 章 · TCP/IP 协议栈与温度记录仪

第 18 章已经把 18 字节温度帧通过 WiFi 模块发送到 PC。本章继续沿这条链路往下看：STM32 交给 AT 模块的是什么，TCP/IP 各层分别负责什么，PC 上的 `socket`、`accept` 和 `read` 又对应链路里的哪一步。

实验先放在同一局域网中，使用明文 TCP 教学服务。公网、TLS 和证书验证留到后面的协议章节；本章只把 TCP 字节流、连接状态和应用帧边界讲清楚。

## 20.1 一份温度样本经过了哪些层

第 18 章的链路可以拆成：

```text
TempSample
   ↓
TempPacket_Encode()：18 字节业务帧
   ↓
WiFiTxTask / Radio_Send()
   ↓ UART
AT 模块
   ↓
TCP
   ↓
IP
   ↓
WiFi MAC / 射频
   ↓
路由器
   ↓
PC TCP socket
   ↓
TempReassembler
   ↓
JSON Lines / 显示
```

STM32 直接负责的是应用协议、UART 和 AT 控制。TCP、IP、WiFi MAC 和射频通常由无线模块固件处理；PC 端的操作系统负责另一端 TCP/IP 协议栈，网关程序只通过 socket API 收发字节。

这几个层次不要混在一起。业务 CRC 错误属于端到端数据检查；TCP 重传属于传输层；WiFi 重新关联 AP 属于更下面的无线链路。日志里把它们分别计数，才能知道问题发生在哪里。

## 20.2 `connect()` 背后发生了什么

设备发出类似下面的 AT 命令时：

```text
AT+CIPSTART="TCP","192.168.1.100",8888
```

模块会尝试向目标 IP 和端口建立 TCP 连接。典型 TCP 三次握手是：

```text
模块                         PC
  ───────── SYN ───────────→
  ←────── SYN + ACK ────────
  ───────── ACK ───────────→
```

应用代码通常看不到这三个报文，只会得到“连接成功”或错误/超时。Linux、Java、Python 的 `connect()` 也是类似边界：内核完成 TCP 握手，应用等待结果。

连接成功只说明传输通道建立。服务器是否会接受你的业务协议、数据是否最终写进文件，是后续应用层的事情。

## 20.3 TCP 提供的是有序字节流

TCP 在一个正常连接中负责排序、确认和必要的重传。应用写入：

```text
18 字节帧 A
18 字节帧 B
```

PC 端的 `read()` 可能得到：

```text
5 字节
13 字节
36 字节
```

也可能先得到 20 字节，再得到 16 字节。TCP 不保留应用每次 `write()` 或 AT 发送操作的边界。

这意味着业务协议必须自己定义帧边界。第 18 章使用 magic、固定版本、固定 18 字节长度和 CRC；变长协议还需要可信的长度字段和上限检查。

TCP 也不能保证“每个温度样本最终一定进入 PC 日志”。连接可能在应用确认前断开，设备 Queue 可能已满，AT UART 可能丢字节，PC 也可能在收到数据后写文件失败。第 18 章保留 `seq`、重复检测和错误计数，就是为了观察这些端到端问题。

## 20.4 `SEND OK` 到底说明什么

不同 AT 固件对 `SEND OK` 的具体语义可能不同，必须查模块手册。通常它说明模块接受并完成了一次发送流程，但不能把它解释成“PC 应用已经持久化这条记录”。

业务层若需要确认 PC 已经处理某个 `seq`，需要额外定义 ACK：

```text
device → TempPacket(seq=42)
pc     → ACK(seq=42)
```

只有收到应用 ACK 后，设备才能确认“对端应用已经接受了 42”。如果 ACK 丢失，设备可能重发 42，PC 端就需要按 `seq` 幂等处理。

对于普通实时遥测，也可以接受少量丢失，不增加 ACK。这里的选择属于产品语义，不由 TCP 自动决定。

## 20.5 PC 网关的 socket 生命周期

一个最小 Linux TCP 服务端通常按下面顺序工作：

```c
int srv = socket(AF_INET, SOCK_STREAM, 0);

/* 检查 srv < 0 */

if (bind(srv, (struct sockaddr *)&addr, sizeof addr) < 0) {
    /* 记录 errno，关闭 srv */
}

if (listen(srv, 5) < 0) {
    /* 记录 errno，关闭 srv */
}

for (;;) {
    int cli = accept(srv, NULL, NULL);
    if (cli < 0) {
        /* 记录 errno；根据错误决定继续还是退出 */
        continue;
    }

    HandleClient(cli);
    close(cli);
}
```

`socket()` 创建一个内核 socket，并返回文件描述符。`bind()` 把它绑定到本地地址和端口，`listen()` 进入监听状态，`accept()` 返回一个新的已连接 socket；监听 socket `srv` 继续保留，用来接受后续连接。

`listen(srv, 5)` 中的 `5` 是 backlog 提示值，不应简单解释为“最多同时 5 个客户端”。它主要影响待完成/待接受连接的排队，具体行为还受操作系统实现和内核参数影响。

端口 8888 只是本章选的教学端口，没有特殊协议含义。开发 PC 的局域网 IP 也可能由 DHCP 改变，实验时应先用 `ip addr` 等工具确认当前地址，再写进设备配置。

## 20.6 网络字节序和业务字节序是两件事

`sin_port` 使用网络字节序，因此常见写法是：

```c
addr.sin_port = htons(8888);
```

这是 socket API 对端口字段的要求。第 18 章业务帧内部则明确使用 little-endian，例如 `seq` 由 `put_u32_le()` 编码。

业务协议可以选择大端或小端，只要编码和解码双方一致。不要因为 IP/TCP 头使用网络字节序，就自动把应用协议里的所有整数都改成大端。

## 20.7 正确处理 `read()`

连接处理函数不能假设一次 `read()` 返回一帧：

```c
static void HandleClient(int cli)
{
    uint8_t buf[256];
    TempReassembler parser = {0};

    for (;;) {
        ssize_t n = read(cli, buf, sizeof buf);

        if (n > 0) {
            TempReassembler_Feed(&parser, buf, (size_t)n);
            continue;
        }

        if (n == 0) {
            /* 对端正常关闭连接 */
            break;
        }

        if (errno == EINTR)
            continue;

        /* 其他错误：记录 errno */
        break;
    }
}
```

阻塞 socket 上的 `read()` 可能被信号中断，因此常见代码会特别处理 `EINTR`。生产服务还要考虑连接超时、并发客户端和资源上限，本章先做单连接教学服务器。

## 20.8 固定长度协议也要能重新同步

如果连接从 magic 开始，并且中间从不丢失或插入字节，那么每 18 字节切一帧可以工作。但第 18 章保留 magic 和 CRC 的意义之一，就是在 UART/AT 外层或应用缓存出现异常后能够重新找到帧边界。

重组器更适合显式寻找 magic：

```c
#define TEMP_PACKET_SIZE 18U

typedef enum {
    RX_FIND_MAGIC0,
    RX_FIND_MAGIC1,
    RX_COLLECT
} TempRxState;

typedef struct {
    TempRxState state;
    uint8_t buf[TEMP_PACKET_SIZE];
    size_t used;
    uint32_t bad_crc;
    uint32_t bad_version;
    uint32_t resync_count;
} TempReassembler;

static void TempReassembler_Reset(TempReassembler *r)
{
    r->state = RX_FIND_MAGIC0;
    r->used = 0U;
}

void TempReassembler_PushByte(TempReassembler *r, uint8_t ch)
{
    switch (r->state) {
    case RX_FIND_MAGIC0:
        if (ch == 0xA5U) {
            r->buf[0] = ch;
            r->state = RX_FIND_MAGIC1;
        }
        break;

    case RX_FIND_MAGIC1:
        if (ch == 0x5AU) {
            r->buf[1] = ch;
            r->used = 2U;
            r->state = RX_COLLECT;
        } else if (ch == 0xA5U) {
            r->buf[0] = ch;
        } else {
            r->state = RX_FIND_MAGIC0;
        }
        break;

    case RX_COLLECT:
        r->buf[r->used++] = ch;

        if (r->used == TEMP_PACKET_SIZE) {
            if (TempPacket_ValidateAndDeliver(r->buf)) {
                TempReassembler_Reset(r);
            } else {
                ++r->resync_count;
                TempReassembler_Reset(r);

                /* 简化实现从下一个输入字节重新找 magic。
                   更严格的实现可检查失败帧内部是否含候选 magic。 */
            }
        }
        break;
    }
}
```

这里省略了 `TempPacket_ValidateAndDeliver()` 的 version/CRC 统计细节。重点是 CRC 失败后回到“找 magic”，不能简单假定下一个 18 字节边界仍然正确。

测试时把同一组帧按 1 字节、随机大小和整块输入，结果必须一致；再在中间插入一个噪声字节，确认后续合法帧仍能恢复。

## 20.9 设备端连接状态机

AT 模块隐藏了 TCP 报文细节，但设备仍需要管理连接状态：

```text
PROBE
  ↓
JOIN_AP
  ↓
OPEN_TCP
  ↓
ONLINE
  ↓ error / disconnect / timeout
BACKOFF
  └────────────→ PROBE
```

每个状态都有独立超时和错误码。进入 `BACKOFF` 时清理当前 AT 事务和连接状态，记录失败原因，再等待一段时间后重新探测模块。

退避可以从较短间隔开始，连续失败后逐步增加，并设置上限。这样 AP 长时间关闭时不会每几毫秒重连一次。具体初值和上限属于系统策略，应根据网络环境和功耗要求确定。

SensorTask 不参与这些状态转换。它继续产生样本，并按照第 18 章定义的 Queue/持久化策略处理网络积压。

## 20.10 发送缓冲区的所有权

网络任务异步发送数据时，缓冲区必须在发送完成前保持有效。下面这种做法有生命周期问题：

```c
void Produce(void)
{
    uint8_t packet[TEMP_PACKET_SIZE];
    TempPacket_Encode(packet, &sample);
    NetworkQueue_SendPointer(packet);  /* 错误示例 */
}
```

函数返回后 `packet` 的生命周期结束。安全的简单做法是让 Queue 复制完整的小消息：

```c
xQueueSend(network_queue, &packet_struct, 0U);
```

较大的消息可以使用固定缓冲池，但要定义申请者、网络任务和释放者之间的所有权状态。无论哪种实现，都不能在上一笔发送尚未完成时直接覆盖同一 TX buffer。

## 20.11 TCP 和 UDP 怎么选

TCP 提供连接、有序字节流、拥塞控制和重传；UDP 是无连接的数据报服务，应用可以保留一报一报的边界，但需要自己决定丢包、乱序、重试和拥塞策略。

温度记录仪使用 TCP 的实际理由是实现简单：AT 模块和操作系统已经提供了连接与有序传输，PC 网关只需要在字节流上恢复业务帧。它并不意味着每一个温度点都必须可靠保存。

某些遥测场景允许丢少量数据，希望更低延迟或更简单的单报发送，也可以用 UDP；重要命令或日志则通常需要更明确的确认和重试语义。协议选择要根据业务损失模型决定。

## 20.12 协议开销不要用一个固定数字概括

IPv4 和 TCP 在都没有可选项时，头部最小分别是 20 字节和 20 字节。但实际链路还可能有 TCP options、WiFi MAC/LLC、安全封装、聚合、重传和 PHY 前导等开销。

因此不能用 `18 + 20 + 20 + 24` 就得到“空中实际传输了多少字节”，更不能直接拿某个标称 PHY 速率换算一次业务消息的真实 airtime。要研究带宽和功耗时，应抓包或使用模块/无线侧测量工具获得实际数据。

对本书这个每秒一帧、18 字节左右的教学遥测，带宽显然不是主要瓶颈。更值得关注的是连接恢复、供电和缓冲策略。

## 20.13 验证

先在 PC 上完成不依赖硬件的重组测试：半帧、两帧合并、随机分段、CRC 错误、未知版本、插入噪声后重新同步。随后再启动 TCP server，让设备每秒发送一帧。

故障测试至少覆盖：

- PC server 停止后，设备进入退避，采样继续；
- server 恢复后，设备重新连接；
- server 在半帧处主动关闭连接，PC 不交付残缺业务帧；
- 网络任务故意变慢，Queue 满策略和 `seq` 缺口符合第 18 章定义；
- PC 写日志失败时单独记录文件错误，不误报成 TCP 错误。

PC 端至少统计 `accepted_connections`、`read_errors`、`bad_crc`、`bad_version`、`resync_count`、`seq_gap` 和 `duplicate_seq`。设备端继续保留 radio timeout、reconnect、send error 和 Queue drop 计数。

## 20.14 练习

1. 修改 PC 测试程序，把一帧拆成 18 次单字节 `write()`，再一次发送两帧，验证解析结果相同。
2. 在两个合法帧中间插入一个字节，确认重组器能在后续 magic 处恢复，并增加 `resync_count`。
3. 给应用协议增加 ACK：PC 只有在日志写入成功后才回复 `ACK(seq)`，设备据此决定是否释放 pending。
4. 把设备网络退避改成逐步增长并设上限，关闭 AP 一段时间，记录每次重试的时间点。
5. 用 Wireshark 抓取局域网 TCP 会话，找到 SYN、SYN/ACK、ACK 和包含业务数据的 TCP segment，并和设备日志时间对应。

完成本章后，网络路径应该能明确区分三件事：TCP 连接是否存在、字节流是否完整恢复成业务帧、业务样本是否最终被应用接受。第 21 章开始在 TCP 之上加入 MQTT。

> **上一章**：[第 19 章 · 温度记录仪 BLE 版](./19-chapter.md)
>
> **下一章**：[第 21 章 · MQTT：让设备持续发布数据](./21-chapter.md)

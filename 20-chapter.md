# 第 20 章 · TCP/IP 协议栈与温度记录仪

> **前置知识**：第 8 章 UART、第 17 章 AT 模块、第 18 章的二进制温度包。
>
> **实验环境**：ZET6 + 可工作的 WiFi AT 模块 + 同一网络中的 PC；先用局域网地址和明文教学 TCP 服务，不把公网 HTTPS 问题混进本章。
>
> **通过标准**：设备能断线后退避重连，PC 网关能从任意分段的 `read()` 结果恢复完整业务帧。

> **本章产出**：从温度记录仪项目出发，理解 TCP/IP 各层在代码中的对应关系、AT 模块内部发生了什么、网关 socket 编程的原理
>
> **用在哪**：项目⑤⑥⑦——MQTT、HTTP、网关的通信基础

---

## 20.1 温度记录仪的 TCP 链路，逐层拆解

你在第 18 章做成的温度记录仪，数据链路是这样的（从传感器到电脑屏幕）：

```
温度值 (int16)
    ↓
二进制协议打包 (TempPacket, 15 字节)
    ↓
发送函数 WiFi_SendBinary()
    ↓
AT 指令 "AT+CIPSEND=15\r\n"
    ↓
UART TX (PA2) ──→ DX-WF24 RXD
                    ↓
                模块内部：
                解析 AT → 取 15 字节数据
                → 加上 TCP 头部
                → 加上 IP 头部
                → 加上 WiFi 帧头
                    ↓
                WiFi 射频发送
                    ↓
                路由器 → 互联网
                    ↓
PC 网关 (gateway.c)
    收 TCP 数据 → 校验 Magic+CRC
    → 拆解 TempPacket → 显示 + 写 JSON
```

这条链路上的每一步，对应 TCP/IP 协议栈的一层：

| 层 | 温度记录仪中的对应 | 代码 |
|----|-----------------|------|
| **应用层** | 温度数据打包为 TempPacket | `protocol.c` |
| **传输层** | TCP 连接 + 可靠传输 | AT 模块内部处理 |
| **网络层** | IP 寻址（你的电脑 IP） | `AT+CIPSTART="TCP","192.168.1.100",8888` |
| **链路层** | WiFi 帧、MAC 地址 | 模块固件自动处理 |
| **物理层** | 2.4GHz 射频 | 模块硬件 |

## 20.2 TCP 连接的三次握手

当 STM32 执行 `WiFi_TCPConnect("192.168.1.100", 8888)` 时，AT 命令只是 `AT+CIPSTART="TCP","192.168.1.100",8888`。但模块内部为你做了：

```
STM32                          DX-WF24                     PC Gateway (8888)
  │                              │                              │
  │─ AT+CIPSTART ──────────────→│                              │
  │                              │── SYN ─────────────────────→│
  │                              │←─ SYN+ACK ──────────────────│
  │                              │── ACK ─────────────────────→│
  │←─ CONNECT ──────────────────│                              │
  │                              │                              │
  │←─── 现在 TCP 连接已建立 ────→│←─── 可以收发数据 ──────────→│
```

三次握手发生在模块和网关之间，STM32 只需要等 AT 返回 `CONNECT`。**如果你从 Java/Python 写 socket 编程**，三次握手是 `socket.connect()` 内部发生的——和你现在用 AT 指令一样，都是等结果。

> 计网课上学过的 SYN、SYN+ACK、ACK——现在你亲眼看到了它被触发（`AT+CIPSTART`）和完成（`CONNECT`）。

### 温故知新：Java Socket 代码

```java
Socket socket = new Socket("192.168.1.100", 8888);
//  ↑ 这个构造函数内部完成了三次握手
//  等价于 STM32 的 AT+CIPSTART
OutputStream out = socket.getOutputStream();
out.write(packet);   // 等价于 AT+CIPSEND
```

### STM32 版

```c
WiFi_TCPConnect("192.168.1.100", 8888);  // Java: new Socket()
WiFi_SendBinary(data, 15);               // Java: out.write()
```

两种写法下，网络上传送的 TCP 包**一模一样**。区别只在于 Java 里三次握手是 JDK 帮你做的，STM32 里是模块固件帮你做的——你的代码都在等待结果。

## 20.3 TCP 的可靠性机制（在项目中的应用）

### 重传

`WiFi_SendBinary` 发送后等 `AT_WaitResponse("SEND OK", 10000)`——如果 10 秒没收到 SEND OK，说明模块没确认 TCP 发送成功，代码返回 -1：

```c
int WiFi_SendBinary(const uint8_t *data, uint16_t len) {
    AT_SendCmd("AT+CIPSEND=%d", len);
    if (!AT_WaitResponse(">", 5000)) return -1;
    // 发 15 字节原始数据...
    return AT_WaitResponse("SEND OK", 10000) ? 0 : -1;
}
```

在 WiFiTxTask 中，发送失败后会重新连接 TCP：

```c
if (WiFi_SendBinary(...) != 0) {
    WiFi_TCPConnect("192.168.1.100", 8888);  // 重连
    break;
}
```

### 序列号

每个温度包有个 4 字节 `seq` 字段。PC 网关收到后可以检查序列号是否连续。如果网关发现 `seq` 从 42 跳到了 45，就知道序号 43 和 44 的包丢了——虽然温度记录仪不处理丢包（丢了就丢了），但至少能发现。

```bash
# 从 JSON Lines 日志检查丢包
cat temps.jsonl | python3 -c "
import sys,json
seqs = [json.loads(l)['seq'] for l in sys.stdin]
for i in range(len(seqs)-1):
    if seqs[i+1] - seqs[i] != 1:
        print(f'可能丢包: {seqs[i]} → {seqs[i+1]}')
"
```

## 20.4 网关的 socket 编程解释

`gateway.c` 的核心是这三行：

```c
int srv = socket(AF_INET, SOCK_STREAM, 0);    // 创建 TCP socket
bind(srv, ..., 8888);                           // 绑定端口 8888
listen(srv, 5);                                 // 开始监听
```

### socket

```c
int srv = socket(AF_INET, SOCK_STREAM, 0);
// AF_INET     = IPv4
// SOCK_STREAM = TCP（不是 UDP）
// 0           = 默认协议（TCP）
```

操作系统返回一个**文件描述符**——在 Linux 中，socket 就是一个文件。你可以 `read()` 它收数据，`write()` 它发数据。

### bind

```c
struct sockaddr_in addr = {
    .sin_family = AF_INET,
    .sin_port   = htons(8888),     // 端口号（网络字节序）
    .sin_addr   = INADDR_ANY       // 接受来自任何 IP 的连接
};
bind(srv, (struct sockaddr*)&addr, sizeof(addr));
```

把 socket 和本地地址绑定。`htons` = Host TO Network Short——因为网络字节序是大端（Big Endian），而大部分电脑是小端。

### listen 和 accept

```c
listen(srv, 5);   // 开始监听，最多 5 个待处理连接

while (1) {
    int cli = accept(srv, NULL, NULL);
    // 阻塞——直到有 STM32 连上来
    read(cli, buf, 15);  // 读 15 字节
    close(cli);
}
```

`listen` 让操作系统知道这个 socket 愿意接受外来连接。`accept` 取出一个已完成三次握手的连接——如果当前没有，就阻塞等。

### 和 temperature logger 的对应

| 操作系统原理 | gateway.c | 温度记录仪 |
|------------|-----------|----------|
| socket 创建 | `socket(AF_INET, SOCK_STREAM, 0)` | 模块固件内部有 socket |
| bind | `bind(srv, ..., 8888)` | 网关定好端口等连接 |
| listen | `listen(srv, 5)` | - |
| accept | `accept(srv, ...)` 阻塞等待 | 模块等 `AT+CIPSTART` |
| connect | - | `AT+CIPSTART="TCP",ip,port` |
| 三次握手 | 操作系统自动完成 | 模块固件自动完成 |
| read/write | `read(cli, buf, 15)` | `AT+CIPSEND=15` + 发数据 |

## 20.5 TCP vs UDP：为什么用 TCP

你可能想问：为什么不用 UDP？

| | TCP | UDP |
|---|---|---|
| **可靠性** | 有确认+重传，保证顺序 | 发出去不管，可能丢包 |
| **速度** | 稍慢（有确认延迟） | 快（无确认） |
| **代码复杂度** | 简单（AT 模块封装了） | 简单（AT 也支持） |
| **适合** | 文件、数据库、控制指令 | 视频、音频、实时游戏 |

**温度记录仪用 TCP 的原因**：数据不能丢。一个温度点是 2 字节，但丢失意味着那 5 分钟没有记录。TCP 保证每个包都到达（或者你明确知道失败才能重试）。

> 第 21-24 章的 MQTT 也跑在 TCP 之上。MQTT 本身是一个「在 TCP 之上的应用层协议」，所以你学会了 TCP 通信，MQTT 就是在此基础上定义报文格式。

## 20.6 IP 地址与端口

在温度记录仪中，你硬编码了：

```c
WiFi_TCPConnect("192.168.1.100", 8888);
```

- **IP 地址 `192.168.1.100`**：你电脑在局域网中的门牌号。路由器通过 DHCP 分配给你的电脑。如果你的电脑 IP 变了，STM32 就连不上了。
- **端口 `8888`**：你电脑上的门。操作系统通过端口区分不同的网络服务——8888 是温度记录仪网关，22 是 SSH，80 是 HTTP 服务器。

一个 IP 地址有 65536 个端口。`bind` 就是在其中一个端口上「挂一个监听器」——操作系统收到 TCP 包后，看目标端口是 8888，就把数据交给 `gateway.c`。

## 20.7 从温度记录仪看 TCP/IP 五层模型

```
应用层                    温度数据 (TempPacket, 15 字节)
                           ↓
传输层                    TCP 头部 (20 字节) + 温度数据
                           ↓
网络层                    IP 头部 (20 字节) + TCP 段
                           ↓
链路层                    WiFi 帧头 (MAC 地址等)
                           ↓
物理层                    2.4GHz 射频信号
```

每个头部长度：

| 头部 | 大约字节 | 包含什么 |
|------|---------|---------|
| TCP | 20 | 源端口、目标端口、序列号、确认号、窗口 |
| IP | 20 | 源 IP、目标 IP、TTL、校验和 |
| WiFi MAC | 24 | 源 MAC、目标 MAC、帧类型 |

所以发一个 15 字节的温度包，实际空中传输约 **15 + 20 + 20 + 24 ≈ 79 字节**——5 倍多的开销。但这对 2.4GHz WiFi 来说可以忽略（54Mbps 速率下 79 字节 ≈ 12 微秒）。

## 20.8 TCP 是字节流，不是业务消息队列

TCP 保证字节按顺序到达，但不会替你保留 TempPacket、JSON 或 HTTP 的边界。一次 read 可能得到半包、一整包，或者多包连在一起。

因此接收端必须自己定义边界，例如：

- 固定长度帧：先收满 15 字节，再校验 Magic 和 CRC；
- 长度字段帧：先收头部，再按 length 累积；
- 文本协议：用换行或空行作为边界；
- HTTP：按头部、Content-Length 或连接关闭判断 Body 是否完整。

把 read 返回值当成“收到了一条消息”，是网络编程中最常见的初学错误。

## 20.9 用重组器处理 TCP 字节流

假设第 18 章的 `TempPacket` 是固定长度帧。PC 的 `read()` 可能一次返回 1 字节、15 字节或 30 字节，因此接收端必须把“读到的字节”与“完整数据包”分开：

~~~c
typedef struct {
    uint8_t buf[TEMP_PACKET_SIZE];
    size_t used;
    uint32_t bad_frame_count;
} TempReassembler;

typedef void (*TempPacketSink)(const TempPacket *packet, void *ctx);

/* 每来一小段字节就调用一次。一次 data 里可能有 0、1 或多帧；
   因此通过回调逐帧交付，绝不能在第一帧时提前 return 丢掉剩余字节。 */
void TempReassembler_Feed(TempReassembler *r,
                          const uint8_t *data, size_t n,
                          TempPacketSink sink, void *ctx)
{
    while (n--) {
        TempPacket packet;

        r->buf[r->used++] = *data++;
        if (r->used != TEMP_PACKET_SIZE) continue;

        memcpy(&packet, r->buf, sizeof(packet));
        r->used = 0;

        if (TempPacket_IsValid(&packet))
            sink(&packet, ctx);
        else
            r->bad_frame_count++;
    }
}
~~~

这段代码的重点不是固定长度本身，而是接口：**任何网络层回调只喂字节；只有验证通过后才向业务层交付 Packet。**

### 连接状态机和退避

AT 模块会把 TCP 细节藏在固件里，但应用仍要管理自己的连接状态：

~~~text
INIT → WIFI_JOIN → TCP_OPEN → ONLINE
               ↑                 │
               └── BACKOFF ← ERROR/TIMEOUT
~~~

- 每个状态有超时；
- 每次失败记录原因和次数；
- 退避时间逐步增加并设置上限；
- ONLINE 只在连接已确认、发送路径可用时成立；
- 采样任务不等待连接；它只把数据交给缓冲区或 Queue。

### 局域网实验与排错

1. 在 PC 启动一个只收固定长度 TempPacket 的教学服务器；
2. 让设备每秒发一帧，PC 故意把读取缓冲区改小；
3. 断开 WiFi 或停止服务器，观察设备进入退避而不是忙等；
4. 重启服务器，确认设备能恢复并报告重连次数。

| 现象 | 优先检查 |
|---|---|
| TCP “已连接”但 PC 没有完整包 | UART/AT 外层接收、`+IPD` 解析、业务帧边界 |
| PC 偶发 CRC 错 | 把多次 read 当成一帧、发送缓冲区复用、字节序 |
| 重连风暴 | 无退避、多个任务同时重连、旧连接未清理 |
| 断网拖慢采样 | 采样路径直接等待 AT/TCP，而不是异步交给网络任务 |

## 20.10 发送所有权、半包和 TCP 关闭

接收端要重组，发送端同样需要边界。任何交给网络任务的 buffer 都必须在发送完成前保持有效：

| 做法 | 为什么危险/安全 |
|---|---|
| 把局部数组地址放进 Queue | 函数返回后地址仍在，但内容已不可靠 |
| 复用同一全局 TX buffer | 上一条 AT/TCP 发送未完成时会被下一条覆盖 |
| Queue 传递完整小结构体 | 简单、安全，但占更多 RAM |
| 固定缓冲池 + 所有权状态 | 适合较大消息，但必须有申请/释放/超时规则 |

TCP 连接关闭也不是“下一次写失败再说”。设备应区分：

~~~text
ONLINE → SEND_PENDING → ONLINE
ONLINE → PEER_CLOSED / AT_ERROR → BACKOFF
ONLINE → KEEPALIVE_TIMEOUT → BACKOFF
~~~

每次进入 BACKOFF 都清理未完成事务、记录失败原因和最后一个 seq；重连后按照业务语义决定哪些消息需要重发。遥测可以丢旧保新，命令确认必须幂等。

### 练习

1. 修改 PC 网关，使一次 `read()` 合并两帧，再把一帧拆成三个 `write()`；重组结果应完全相同；
2. 让设备每秒入队一帧、网络任务每三秒取一帧，说明队列满时保留哪个数据；
3. 服务器主动关闭连接，记录设备从检测到错误到下一次成功发送的状态时间线。

## 20.11 本章要点

- AT 模块帮你实现了 TCP/IP 协议栈——三次握手、重传、打包全在固件里
- TCP 保证可靠传输，适合温度记录数据
- socket 编程三要素：`socket` → `bind` → `listen/accept`（网关）或 `connect`（设备）
- IP 地址找机器，端口找程序
- 一个温度包的 TCP/IP 头部开销约 64 字节，数据 15 字节——可以接受
- 本章的 TCP 知识是第 21-24 章 MQTT/HTTP 通信的基础

---

> **下一章**：[第 21 章 · MQTT：让设备持续发布数据（SPL版）](./21-chapter.md)
>
> 从已经建立的 TCP 通道出发，先学习 MQTT 的 Broker、Topic 和发布流程。

# 第 23 章 · HTTP、响应解析与 cJSON（SPL版）

> **本章产出**：能用 WiFi AT 模块发送一条正确的 HTTP 请求；知道如何安全地从响应中分离 Body 并解析 JSON。
>
> **前置知识**：第 20 章 TCP，以及第 22 章的配置管理。
>
> **用在哪**：REST API、天气查询、设备配置拉取、调试云端接口。
>
> **实验环境**：先用同一局域网内的教学 HTTP 服务；公网接口、DNS、HTTPS、证书和 Chunked 编码属于下一层复杂度，不能被“浏览器能打开”掩盖。

---

## 23.1 MQTT 和 HTTP，什么时候选哪个

| 需求 | 更适合 MQTT | 更适合 HTTP |
|---|---|---|
| 设备持续上报 | 是 | 不一定 |
| 云端主动下发 | 是 | 需要轮询 |
| 调试一个 Web API | 不方便 | 是 |
| 请求一次天气或配置 | 可以 | 是 |
| 浏览器直接访问 | 需要额外桥接 | 是 |

两者都可以通过 TCP 运行。学习 HTTP 的价值是：它把一个网络请求的每一个文本字段都摆在你眼前，特别适合理解协议。

## 23.2 一条最小 GET 请求

HTTP 请求由“请求行、若干头部、空行、可选 Body”组成：

~~~text
GET /api/v1/weather HTTP/1.1
Host: api.example.com
Connection: close

~~~

最后的空行很重要：它表示头部结束。

## 23.3 先组装请求，再计算长度

不要把 AT+CIPSEND=<len> 原样写进程序。正确顺序是：

1. 先用 snprintf 生成完整 HTTP 文本；
2. 得到真实字节数；
3. 再发送 AT+CIPSEND=真实长度；
4. 等待模块提示符 >；
5. 原样发送 HTTP 字节，不额外补回车换行。

~~~c
char request[256];
char cmd[32];

int len = snprintf(request, sizeof(request),
    "GET /api/v1/weather HTTP/1.1\r\n"
    "Host: api.example.com\r\n"
    "Connection: close\r\n"
    "\r\n");

if (len < 0 || len >= (int)sizeof(request)) {
    return -1;                 /* 请求被截断，不能发送 */
}

snprintf(cmd, sizeof(cmd), "AT+CIPSEND=%d", len);
AT_SendCmd(cmd);
if (!AT_WaitResponse(">", 5000)) {
    return -1;
}
if (TCP_SendRaw((const uint8_t *)request, (uint16_t)len) != 0) {
    return -1;
}
~~~

这里的 TCP_SendRaw 指的是第 21 章中的“原始字节发送”能力；实际工程中只应保留一个发送入口，避免重复等待提示符。

## 23.4 不要假设一次就能收到完整响应

UART 中断收到的数据可能被分成多段，TCP 也没有“消息边界”。因此，下面这种写法只适合作为概念演示：

~~~c
char *body = strstr(at_rx_buf, "\r\n\r\n");
~~~

真正的程序至少要做到：

- 为接收缓冲区记录当前长度；
- 确保缓冲区始终以零结尾；
- 找到头部结束标志后，再检查 Content-Length 或连接关闭事件；
- 限制最大响应尺寸，避免缓冲区溢出；
- 超时后丢弃不完整响应，并回到可恢复状态。

## 23.5 从 HTTP 状态码开始判断

先判断状态行，再解析 JSON。200 只表示服务器成功处理了请求，不代表 Body 就一定符合你的格式。

~~~text
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 31

{"temperature_c":24.6}
~~~

处理顺序：

1. 解析状态行，确认是 200、201 等预期状态；
2. 查找头部结束的空行；
3. 检查 Content-Type 是否是 JSON；
4. 在完整 Body 到齐后调用 cJSON_Parse；
5. 逐个验证字段类型和范围。

## 23.6 cJSON 解析时要检查每一步

~~~c
cJSON *root = cJSON_Parse(body);
if (root == NULL) {
    return -1;
}

cJSON *temp = cJSON_GetObjectItemCaseSensitive(root, "temperature_c");
if (!cJSON_IsNumber(temp)) {
    cJSON_Delete(root);
    return -1;
}

float temperature_c = (float)temp->valuedouble;
cJSON_Delete(root);
~~~

任何来自网络的数据都不可信。字段缺失、字段类型错误、超出正常范围都应被当作可恢复错误，而不是继续使用未初始化的数据。

## 23.7 在 RTOS 中安排 HTTP 任务

HTTP 请求可能等待数秒，因此不要把它放在按键任务、显示刷新任务或 UART ISR 中。一个清晰的设计是：

~~~text
Task_ConfigFetch
  ├─ 等待网络已连接
  ├─ 发 HTTP 请求
  ├─ 解析并校验配置
  └─ 通过 Queue 把新配置发给业务任务
~~~

这样即使服务器不可用，传感器采样和 OLED 刷新仍能继续。

## 23.8 本章练习

1. 用 PC 上的本地 HTTP 服务端返回一个 JSON 文件；
2. 故意返回 404、错误 JSON 和超长响应，验证错误处理；
3. 把 weather 请求改成从配置 Topic 或本地文件读取；
4. 在串口打印状态码和响应长度，但不要打印 WiFi 密码或密钥。

## 23.9 DNS、HTTPS 与公网 API 的现实

第一个 HTTP 实验可以连接局域网或教学服务器，但真实公网 API 通常要求 HTTPS：

- DNS：先把域名解析为 IP；
- TLS：需要证书校验、加密和更多 RAM；
- 模块能力：确认 AT 模块是否支持 SSL/TLS、SNI 和证书配置；
- 时间：证书校验通常依赖正确系统时间；
- 响应：可能使用 Chunked 编码，而不一定给 Content-Length。

因此，先用本地 HTTP 服务理解协议，再根据模块文档评估 HTTPS。不能因为电脑浏览器能访问，就假定小型 AT 模块也能直接访问。

## 23.10 用状态机接收 HTTP：头与 Body 可以被拆开

HTTP 响应的 `\r\n\r\n` 分隔符、状态行和 Content-Length 都可能跨多个 TCP/UART 片段到达。第一版解析器应只支持自己能明确验证的子集：`HTTP/1.1` + `Content-Length`；若检测到 `Transfer-Encoding: chunked`，记录并拒绝，而不是假装 body 已完整。

~~~c
typedef enum {
    HTTP_RX_HEADERS,
    HTTP_RX_BODY,
    HTTP_RX_DONE,
    HTTP_RX_ERROR
} HttpRxState;

typedef struct {
    HttpRxState state;
    char headers[512];
    size_t header_len;
    size_t content_length;
    size_t body_len;
    char body[1024];
} HttpResponse;

/* 每收到一段字节就追加；找到 \r\n\r\n 后解析状态码和 Content-Length。
   任何缓冲区不足、长度缺失或不支持的编码都进入 HTTP_RX_ERROR。 */
~~~

实现时注意四条边界：

1. 所有追加都先检查缓冲区上限；
2. `Content-Length` 只在完整头部后解析；
3. body 可能有二进制 `\0`，不要只用 `strstr` 处理所有内容；
4. 只有 `body_len == content_length` 时才把数据交给 JSON 层。

### cJSON 的最小安全用法

~~~c
cJSON *root = cJSON_ParseWithLength(resp.body, resp.body_len);
if (root == NULL) {
    /* 记录解析失败和前若干字节，不打印敏感完整响应 */
    return false;
}

cJSON *temperature = cJSON_GetObjectItemCaseSensitive(root, "temperature");
if (!cJSON_IsNumber(temperature)) {
    cJSON_Delete(root);
    return false;
}

double value = temperature->valuedouble;
cJSON_Delete(root);  /* 释放整棵树；不要保留其内部指针 */
~~~

必须同时检查“HTTP 成功”和“业务字段有效”。`200 OK` 也可能返回错误 JSON、旧配置或不是你期望的 Content-Type。

### 本地 HTTP 实验

1. 先让 PC 服务返回一个很短、固定 Content-Length 的 JSON；
2. 在服务端故意把响应分两次写出，验证 STM32 不会半包解析；
3. 改一个字段的类型（数字改字符串），确认 cJSON 校验会拒绝；
4. 改为 Chunked 响应，确认第一版解析器明确报“不支持”，而不是读错。

| 现象 | 优先检查 |
|---|---|
| 请求发不出去 | AT 发送长度、Host、连接状态、CRLF |
| 状态行不完整 | TCP/UART 分段处理、接收缓存、超时 |
| JSON 偶发失败 | body 未收全、Content-Length、缓冲区截断 |
| 堆逐渐下降 | 忘记 `cJSON_Delete`、反复分配、错误路径没有释放 |
| 公网可用本地失败 | DNS/TLS/证书与纯 HTTP 是不同问题 |

## 23.11 用一个故意分段的教学服务验证解析器

浏览器通常替你处理了分段、连接和 TLS；为了证明 STM32 解析器真的正确，使用一个故意把响应拆开的最小服务。它仅供局域网教学：

~~~python
# split_http_server.py
import socket, time

body = b'{"temperature":2534,"unit":"centi"}'
head = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Connection: close\r\n\r\n")

with socket.socket() as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", 8080))
    s.listen(1)
    conn, addr = s.accept()
    with conn:
        conn.recv(1024)       # 教学示例：忽略请求内容
        conn.sendall(head[:23])
        time.sleep(0.2)
        conn.sendall(head[23:] + body[:7])
        time.sleep(0.2)
        conn.sendall(body[7:])
~~~

设备端必须在每个分段后保持 `HTTP_RX_HEADERS` 或 `HTTP_RX_BODY`，直到条件满足；如果只在 `read()` 后直接调用 cJSON，这个服务会稳定暴露 bug。

### 请求构造也要检查边界

~~~c
int n = snprintf(request, sizeof(request),
    "GET /config HTTP/1.1\r\n"
    "Host: %s\r\n"
    "Connection: close\r\n\r\n", host);

if (n < 0 || (size_t)n >= sizeof(request)) {
    /* Host 或路径太长；不要把截断请求发出去。 */
    return false;
}
~~~

长度检查、CRLF、Host 和 AT 发送字节数都属于同一个端到端契约。HTTP 请求文本“看起来像对的”不等于 TCP 实际发出的长度正确。

### 回归用例

| 用例 | 期望 |
|---|---|
| 头部分三段 | 不解析 JSON，直到头完整 |
| Body 分五段 | 只在收满 Content-Length 后交给 cJSON |
| Content-Length 大于缓冲区 | 明确报错，不越界 |
| 返回 404 + JSON | 记录状态码，业务层不当成功 |
| Chunked | 第一版明确拒绝或走专门实现 |
| 字段类型变化 | `cJSON_IsNumber/String` 拒绝不匹配字段 |

练习：把服务端 body 的温度字段依次改成缺失、字符串、负数和超长 JSON，记录固件的状态码、解析错误和内存行为。

## 23.12 先冻结一个 HTTP 子集，解析器才有可验证的边界

HTTP 很大；第一轮 ZET6 实验只支持一个明确子集，比声称“支持 HTTP”安全得多。下面是推荐的教学契约：

| 项目 | 第一轮支持 | 明确不支持/需另写状态机 |
|---|---|---|
| 方法 | `GET`；需要时再单独加入小 Body 的 `POST` | 复杂上传、流式请求 |
| 协议 | HTTP/1.1，显式 `Connection: close` | 持久连接复用、HTTP/2 |
| 响应边界 | `Content-Length`；或连接关闭作为最后边界 | Chunked 编码、无限流 |
| 头部/Body 上限 | 编译期常量，超出即拒绝并计数 | 按服务器输入无限扩容 |
| 重定向/压缩 | 直接报告“不支持” | 自动跳转、gzip 解压 |
| JSON | 完整 Body 到齐后解析 | 半包、超长、类型不符时继续使用旧数据 |

这样 `HTTP 任务` 的状态机就能写得很小且可回放：

~~~text
IDLE → BUILD_REQUEST → TCP_CONNECT → SEND
  → READ_HEADERS → CHECK_STATUS_AND_LENGTH → READ_BODY
  → PARSE_JSON → DELIVER_CONFIG → CLOSE → IDLE
                       └─ 任意超时/超长/格式错 → CLOSE + ERROR + 退避
~~~

只有在 `Content-Length` 已验证且所有 Body 字节到齐时，才允许调用 `cJSON_Parse`。若选择依赖连接关闭作为边界，就必须给总响应长度和等待时间上限，避免一台异常服务永远占住任务。

### 内存与 HTTPS 的明确取舍

cJSON 的分配来源、解析最大尺寸和错误释放策略都应写在项目配置中。若使用动态内存，测试连续错误 JSON 是否导致 heap 持续下降；若改用自定义 allocator，`cJSON_InitHooks` 的初始化时机和线程安全也要说明。

公网服务通常要求 HTTPS。选择路线前依次确认：AT 模块是否真支持目标 TLS 版本、域名/SNI、证书存储与校验；系统时间从何而来；握手时 RAM/供电是否足够。任意一项未验证时，只把实验限定在受控的局域网 HTTP 服务，不要通过“浏览器可以访问”来推断 MCU 的连接安全。

## 23.13 本章要点

- HTTP 请求先组装，再根据真实长度发送 AT+CIPSEND；
- TCP/UART 收包不保证一次收到完整 HTTP 响应；
- 解析 JSON 前必须验证状态码、边界、长度和字段类型；
- 网络请求应放在独立任务中；
- HTTP 很适合学习和调试 REST 接口，持续设备消息通常更适合 MQTT。

---

[上一章：第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)

[下一章：第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

# 第 23 章 · HTTP、响应解析与 cJSON（SPL 版）

第 21 章用 MQTT 做持续消息通信。本章换成 HTTP，完成一次请求—响应：STM32 通过 WiFi AT 模块发送 HTTP/1.1 GET，按字节流接收响应，确认 Body 完整后再交给 cJSON。

第一轮实验只连接局域网内可控的 HTTP 服务。解析器明确支持 `Content-Length`，暂不实现 Chunked、压缩、重定向和持久连接。HTTPS 留到确认无线模块的 TLS、SNI、证书和时间能力之后。

## 23.1 本章为什么用 HTTP

HTTP 适合“发一个请求，拿一个结果”的场景，例如读取设备配置、调用 REST API 或查询一次数据。持续遥测和服务端主动下发更适合前面已经实现的 MQTT。

两者最终都经过 TCP，因此第 20 章的规则仍然成立：TCP 只提供字节流，`read()`、UART 中断或 AT Payload 都不会替 HTTP 保留消息边界。

本章只实现下面这条路径：

```text
BUILD_REQUEST
    ↓
TCP_CONNECT
    ↓
SEND_REQUEST
    ↓
READ_HEADERS
    ↓
READ_BODY
    ↓
PARSE_JSON
    ↓
DELIVER_RESULT
```

任一步发生超时、超长或格式错误，都关闭当前事务并记录原因。

## 23.2 一条最小 GET 请求

HTTP/1.1 请求由请求行、头部、空行和可选 Body 组成。GET 示例：

```text
GET /api/v1/config HTTP/1.1\r\n
Host: 192.168.1.100:8080\r\n
Connection: close\r\n
\r\n
```

协议在线路上使用 `\r\n`。最后一个空行表示请求头结束；少掉它，服务端可能继续等待后续头部。

`Host` 是 HTTP/1.1 请求的一部分。局域网实验如果使用非默认端口，可以把端口一起写入 Host；真实公网接口则按目标服务文档构造域名和路径。

## 23.3 请求先完整构造，再计算发送长度

`AT+CIPSEND=<len>` 中的长度必须等于随后实际发送的 HTTP 字节数。先 `snprintf()`，检查是否截断，再把返回长度交给底层发送接口：

```c
static bool Http_BuildGet(char *out, size_t cap,
                          const char *host, const char *path,
                          size_t *out_len)
{
    int n = snprintf(out, cap,
                     "GET %s HTTP/1.1\r\n"
                     "Host: %s\r\n"
                     "Connection: close\r\n"
                     "\r\n",
                     path, host);

    if (n < 0 || (size_t)n >= cap)
        return false;

    *out_len = (size_t)n;
    return true;
}
```

调用时：

```c
char request[256];
size_t request_len;

if (!Http_BuildGet(request, sizeof request,
                   "192.168.1.100:8080", "/api/v1/config",
                   &request_len)) {
    return false;
}

if (request_len > UINT16_MAX)
    return false;

if (TCP_SendRaw((const uint8_t *)request,
                (uint16_t)request_len) != 0) {
    return false;
}
```

这里沿用第 21 章已经封装好的 `TCP_SendRaw()`。不要在 HTTP 层再次手写 `AT+CIPSEND` 和 `>` 等待，否则两个发送入口很容易重复执行 AT 事务。

路径和 Host 如果来自配置，还要限制长度和允许的字符范围。不要把未经校验的网络输入直接拼成新的 HTTP 请求头。

## 23.4 第一版响应解析器只支持一个明确子集

本章约定服务端返回：

- HTTP/1.1；
- 一个最终响应；
- `Content-Length`；
- `Connection: close`；
- Body 不超过本地固定上限；
- JSON 响应不使用 gzip 等内容编码。

遇到 `Transfer-Encoding: chunked`、重定向或响应尺寸超限，第一版直接返回“不支持”。明确拒绝比把不完整 Body 交给 cJSON 更容易排错。

响应示例：

```text
HTTP/1.1 200 OK\r\n
Content-Type: application/json\r\n
Content-Length: 54\r\n
Connection: close\r\n
\r\n
{"sample_period_ms":1000,"upload_period_ms":10000}
```

状态码、头部和 Body 都可能跨多个 TCP/AT Payload 到达。解析器必须保存状态，不能在每次收到一段数据时重新从零开始找字符串。

## 23.5 用状态机收 Header 和 Body

一个教学版响应对象可以使用固定缓冲区：

```c
#define HTTP_HEADER_MAX  512U
#define HTTP_BODY_MAX   1024U

typedef enum {
    HTTP_RX_HEADERS,
    HTTP_RX_BODY,
    HTTP_RX_DONE,
    HTTP_RX_ERROR
} HttpRxState;

typedef struct {
    HttpRxState state;

    uint8_t headers[HTTP_HEADER_MAX];
    size_t header_len;

    int status_code;
    size_t content_length;

    uint8_t body[HTTP_BODY_MAX];
    size_t body_len;
} HttpResponse;
```

接收流程分两段：

```text
HTTP_RX_HEADERS
  ├─ 逐字节追加，并寻找 \r\n\r\n
  ├─ 头部超限 → ERROR
  └─ 找到完整头部
        ↓
      解析状态码和 Content-Length
        ↓
      HTTP_RX_BODY
        ├─ 累计到 content_length → DONE
        └─ 超限/超时 → ERROR
```

Header 分隔符可能正好跨两个输入片段，因此搜索范围必须包含上一次结尾留下的字节。找到 `\r\n\r\n` 时，同一个输入片段后面可能已经带着一部分 Body，这部分字节要立即转入 Body，不能丢掉。

所有长度都用显式计数管理。Body 可能包含 `0x00`，HTTP 层不要把它当 C 字符串处理。

## 23.6 Header 解析需要边界检查

只有完整 Header 到齐后才解析状态行和字段。第一版至少检查：

1. 状态行格式能解析出三位状态码；
2. 只有一个可接受的 `Content-Length` 值；
3. `Content-Length <= HTTP_BODY_MAX`；
4. 没有本实现不支持的 `Transfer-Encoding: chunked`；
5. 如果业务要求 JSON，再检查 `Content-Type` 是否为预期媒体类型。

Header 名称在 HTTP 中大小写不敏感。自己写查找函数时不能只接受 `Content-Length` 这一种大小写。

`Content-Length` 也不能直接交给 `atoi()` 后就相信结果。解析时要拒绝负号、非十进制字符、整数溢出和超过本地上限的值。

本章使用 `Connection: close` 简化连接生命周期，但 Body 的完成条件仍以已经验证的 `Content-Length` 为准。服务器提前关闭连接且 Body 尚未收满时，这次响应失败。

## 23.7 状态码成功后，业务数据还要继续验证

HTTP 状态码说明 HTTP 请求的处理结果，不说明 JSON 一定满足固件的数据模型。例如 `200 OK` 的 Body 仍可能缺字段、字段类型变化或数值越界。

配置接口可以约定：

```json
{
  "sample_period_ms": 1000,
  "upload_period_ms": 10000
}
```

只有完整 Body 到齐后才调用 cJSON：

```c
static bool Config_Parse(const uint8_t *body, size_t body_len,
                         uint32_t *sample_ms,
                         uint32_t *upload_ms)
{
    cJSON *root;
    cJSON *sample;
    cJSON *upload;
    bool ok = false;

    root = cJSON_ParseWithLength((const char *)body, body_len);
    if (root == NULL)
        return false;

    sample = cJSON_GetObjectItemCaseSensitive(root, "sample_period_ms");
    upload = cJSON_GetObjectItemCaseSensitive(root, "upload_period_ms");

    if (!cJSON_IsNumber(sample) || !cJSON_IsNumber(upload))
        goto out;

    if (sample->valuedouble < 100.0 || sample->valuedouble > 3600000.0)
        goto out;
    if (upload->valuedouble < sample->valuedouble ||
        upload->valuedouble > 86400000.0)
        goto out;

    *sample_ms = (uint32_t)sample->valuedouble;
    *upload_ms = (uint32_t)upload->valuedouble;
    ok = true;

out:
    cJSON_Delete(root);
    return ok;
}
```

这里的 100 ms、1 h 和 24 h 是示例项目的配置边界，不是 HTTP 或 cJSON 的规定。实际产品应按传感器采样能力、功耗和服务端限制确定范围。

如果项目要求配置必须是整数，还应额外验证 JSON 数值没有小数部分，避免 `1000.9` 被强制转换成 `1000` 后悄悄通过。

## 23.8 cJSON 的内存边界

cJSON 会为解析树分配内存。STM32F103ZET6 的 SRAM 有限，本章已经用 `HTTP_BODY_MAX` 限制输入大小，还需要检查连续错误响应是否造成 heap 持续下降。

每个成功 `cJSON_Parse...()` 的返回值最终都要对应一次 `cJSON_Delete()`。错误路径也一样，不能只在正常分支释放。

业务层不要保存 `cJSON` 树内部的字符串指针后再删除根节点。需要长期保存的配置应复制到自己的固定结构体，再释放整棵 JSON 树。

如果项目通过 `cJSON_InitHooks()` 更换 allocator，应在并发解析开始前完成初始化，并确认所用 allocator 的线程安全和失败行为。本章先保持单个配置任务解析 JSON。

## 23.9 在 FreeRTOS 中隔离 HTTP 事务

HTTP 请求可能等待 TCP、服务端响应和重连。把完整事务放进独立任务：

```text
ConfigTask
  ↓ 等待网络可用
BUILD_REQUEST
  ↓
SEND / RECEIVE
  ↓
VALIDATE HTTP
  ↓
PARSE JSON
  ↓
Queue 发送已验证的 Config
```

SensorTask 和 DisplayTask 不等待 HTTP。ConfigTask 只在得到一份完整、范围合法的新配置后才通过 Queue 交给业务任务；解析失败时继续使用上一份已验证配置，并记录失败原因。

如果 WiFi、MQTT 和 HTTP 共用同一个 AT 模块 UART，还要继续遵守第 17、18 章的单一所有者规则。ConfigTask 可以向通信任务提交请求，但不要与 MQTT 任务同时直接发送 AT 命令。

## 23.10 用故意分段的服务测试解析器

下面的 PC 服务把 Header 和 Body 故意拆成几次发送。它只用于受控局域网实验：

```python
import socket
import time

body = b'{"sample_period_ms":1000,"upload_period_ms":10000}'
head = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: application/json\r\n"
    b"Content-Length: " + str(len(body)).encode("ascii") + b"\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", 8080))
    server.listen(1)

    conn, addr = server.accept()
    with conn:
        conn.recv(1024)  # 教学服务暂不解析请求
        conn.sendall(head[:23])
        time.sleep(0.2)
        conn.sendall(head[23:] + body[:7])
        time.sleep(0.2)
        conn.sendall(body[7:])
```

设备应在前两次输入后继续保持 `HTTP_RX_HEADERS` 或 `HTTP_RX_BODY`，直到 `body_len == content_length` 才产生完整响应事件。这个测试能稳定暴露“每收到一段就直接 `strstr()` / `cJSON_Parse()`”的问题。

再增加几组故障输入：Header 超过 512 字节、`Content-Length` 大于 1024、Body 提前断开、404 + JSON、错误 JSON、字段类型错误，以及 Chunked 响应。每一种都应得到明确错误，不越界，也不更新当前配置。

## 23.11 HTTPS 和公网接口

公网 API 通常使用 HTTPS。浏览器能访问某个地址，不能证明当前 AT 模块能完成相同连接；浏览器已经替你处理了 DNS、TLS、证书、SNI、时间、重定向、压缩和更复杂的 HTTP 响应。

接入公网前逐项确认：

- AT 模块固件是否支持目标 TLS 版本；
- 是否支持目标域名需要的 SNI；
- 根证书或服务器证书如何配置、更新和校验；
- 设备时间从哪里来；
- TLS 握手期间的 RAM 和供电是否满足要求；
- 服务端是否可能返回 Chunked、重定向或压缩内容。

这些条件没有验证时，本章的代码只声称支持受控局域网 HTTP 子集，不把它描述成通用 Web 客户端。

## 23.12 本章完成标准

完成下面这些测试后再继续下一章：

- 能构造 GET，并确认 `CIPSEND` 长度与实际 HTTP 请求字节数一致；
- Header 被拆成多段时仍能找到完整 `\r\n\r\n`；
- Header 和第一段 Body 粘在一起时不丢 Body；
- 只在收满 `Content-Length` 后解析 JSON；
- 404、超长响应、提前断开和 Chunked 都进入明确错误路径；
- JSON 字段缺失、类型错误和范围错误不会更新当前配置；
- 连续错误响应不会造成可观察的 heap 持续下降。

最后再检查一次任务边界：网络失败只能影响 ConfigTask/通信任务，不能拖住传感器采样和显示刷新。

> **上一章**：[第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)
>
> **下一章**：[第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

# 第 23 章 · HTTP、响应解析与 cJSON（SPL 版）

第 21 章用 MQTT 做持续消息通信。本章改用 HTTP 完成一次请求—响应：STM32 通过 WiFi AT 模块发送 HTTP/1.1 GET，按字节流接收响应，收完整个 Body 后再交给 cJSON。

第一版只支持受控局域网里的一个小子集：`Content-Length`、`Connection: close`、固定响应上限和未压缩 JSON。遇到 Chunked、重定向或其他未实现格式时明确报错。HTTPS 等模块的 TLS 能力验证完成后再接入。

## 23.1 HTTP 事务仍建立在 TCP 字节流上

HTTP 适合读取一次配置、调用 REST API 等请求—响应场景。它最终仍经过 TCP，因此一次 UART 中断、AT Payload 或 socket `read()` 不对应一条 HTTP 消息。

本章实现下面这条路径：

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
VALIDATE_RESPONSE
    ↓
PARSE_JSON
```

超时、超长、格式错误和连接提前关闭都结束当前事务，并保留具体错误原因。

## 23.2 构造一条 HTTP/1.1 GET

最小实验请求如下：

```text
GET /api/v1/config HTTP/1.1\r\n
Host: 192.168.1.100:8080\r\n
Connection: close\r\n
\r\n
```

HTTP/1.1 的请求行和 Header 行使用 `\r\n`，Header 最后再用一个空行结束。`Host` 是 HTTP/1.1 请求需要的字段；使用非默认端口时，本实验把端口一起写入 Host。

先完整构造请求，再把实际长度交给第 21 章的 `TCP_SendRaw()`：

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

调用端检查长度：

```c
char request[256];
size_t request_len;

if (!Http_BuildGet(request, sizeof request,
                   "192.168.1.100:8080",
                   "/api/v1/config",
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

HTTP 层不再实现一套 `AT+CIPSEND`。如果 Host 或 path 来自配置，还要限制长度并按实际用途验证内容，避免控制字符进入请求行或 Header。

## 23.3 第一版响应格式

教学服务返回：

```text
HTTP/1.1 200 OK\r\n
Content-Type: application/json\r\n
Content-Length: 54\r\n
Connection: close\r\n
\r\n
{"sample_period_ms":1000,"upload_period_ms":10000}
```

本章解析器只接受：HTTP/1.1 最终响应、合法 `Content-Length`、Body 不超过本地上限，以及业务需要时的 JSON Content-Type。暂不支持 `Transfer-Encoding: chunked`、内容压缩、重定向和连接复用。

HTTP 状态码、Header 和 Body 都可能被 TCP/AT 任意拆分。解析器要保存已经收到的字节和当前状态，不能对每个输入片段单独调用 `strstr()`。

## 23.4 Header 和 Body 用状态机累计

固定上限先写清楚：

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

接收过程是：

```text
HTTP_RX_HEADERS
  ├─ 累计字节并寻找 \r\n\r\n
  ├─ 超过 HTTP_HEADER_MAX → ERROR
  └─ Header 完整
        ↓
      解析状态行和 Header
        ↓
      HTTP_RX_BODY
        ├─ body_len == content_length → DONE
        └─ 超限 / 超时 / 提前断开 → ERROR
```

`\r\n\r\n` 可能跨两个输入片段。找到它时，同一片段后面也可能已经带着 Body，剩余字节要立即交给 Body 状态处理。

HTTP Body 是按长度管理的字节序列，里面可以出现 `0x00`。HTTP 层不要依赖 `strlen()` 判断 Body 是否完整。

## 23.5 Header 解析要处理语法和边界

完整 Header 到齐后，第一版至少做这些检查：

1. 状态行符合预期格式，并能得到三位状态码；
2. `Content-Length` 只有一个一致且可接受的值；
3. 长度是非负十进制数，没有溢出，且不超过 `HTTP_BODY_MAX`；
4. 没有本实现不支持的 Transfer-Encoding；
5. 业务要求 JSON 时，Content-Type 与接口约定一致。

HTTP 字段名大小写不敏感，因此 `content-length` 和 `Content-Length` 应被同样识别。字段值还需要处理前后的可选空白，不能把整行做一次固定大小写的字符串比较就结束。

若出现多个 Content-Length，稳妥的教学实现可以直接拒绝；如果选择接受，也只能接受所有值完全一致的情况。不要让不同代码路径各取一个长度。

本章发送 `Connection: close` 来简化连接生命周期，但响应是否完整仍由已验证的 `Content-Length` 决定。Body 没收满就遇到连接关闭，这次事务失败。

## 23.6 HTTP 成功以后再验证 JSON

`200 OK` 只说明 HTTP 请求得到成功状态，不保证 Body 符合固件需要的数据模型。配置接口约定：

```json
{
  "sample_period_ms": 1000,
  "upload_period_ms": 10000
}
```

Body 收完整后再调用 cJSON：

```c
static bool JsonNumberToU32(const cJSON *item,
                            uint32_t min_value,
                            uint32_t max_value,
                            uint32_t *out)
{
    double value;
    uint32_t converted;

    if (!cJSON_IsNumber(item))
        return false;

    value = item->valuedouble;
    if (value < (double)min_value || value > (double)max_value)
        return false;

    converted = (uint32_t)value;
    if ((double)converted != value)
        return false;

    *out = converted;
    return true;
}

static bool Config_Parse(const uint8_t *body, size_t body_len,
                         uint32_t *sample_ms,
                         uint32_t *upload_ms)
{
    cJSON *root;
    cJSON *sample;
    cJSON *upload;
    uint32_t sample_value;
    uint32_t upload_value;
    bool ok = false;

    root = cJSON_ParseWithLength((const char *)body, body_len);
    if (root == NULL)
        return false;

    sample = cJSON_GetObjectItemCaseSensitive(root, "sample_period_ms");
    upload = cJSON_GetObjectItemCaseSensitive(root, "upload_period_ms");

    if (!JsonNumberToU32(sample, 100U, 3600000U, &sample_value))
        goto out;
    if (!JsonNumberToU32(upload, sample_value, 86400000U, &upload_value))
        goto out;

    *sample_ms = sample_value;
    *upload_ms = upload_value;
    ok = true;

out:
    cJSON_Delete(root);
    return ok;
}
```

这里顺手解决了原来直接把 `valuedouble` 强制转换成 `uint32_t` 的问题。配置要求整数时，`1000.9` 会被拒绝，不会静默变成 `1000`。

100 ms、1 h 和 24 h 是本实验的业务边界。实际项目要根据传感器允许的采样周期、功耗和服务端限制重新定义。

## 23.7 cJSON 的内存生命周期

cJSON 解析时会为节点和字符串分配内存。F103ZET6 只有 64 KB SRAM，本章先用 `HTTP_BODY_MAX` 限制输入规模，再检查解析失败和连续请求时 heap 是否稳定。

每次成功的 `cJSON_Parse...()` 最终都要对应 `cJSON_Delete()`。业务代码也不要在删除根节点后继续保存树内部的字符串指针；需要长期使用的值复制到自己的 `Config` 结构体。

如果项目通过 `cJSON_InitHooks()` 更换 allocator，要在开始并发使用 cJSON 前完成初始化，并明确 allocator 的并发和失败语义。本章只让一个配置处理路径解析 JSON。

还要区分“输入大小上限”和“解析树占用”。1 KB JSON 不代表只消耗 1 KB heap；节点、字符串和 allocator 元数据都会增加内存占用，因此最终用实际 heap/栈监测结果决定上限。

## 23.8 FreeRTOS 中继续保持 AT 模块单一所有者

HTTP 事务会等待 DNS/TCP、发送和响应。业务上可以由 ConfigTask 发起：

```text
ConfigTask
    ↓ 提交 HTTP 请求
CommunicationTask
    ↓ 独占 AT / UART / TCP
HTTP transaction
    ↓ 返回完整结果
ConfigTask
    ↓ 校验 HTTP + JSON
    ↓ 发布新的 Config
```

SensorTask 和 DisplayTask 不等待 HTTP。只有完整、合法的新配置才替换当前配置；请求失败时继续使用上一份已验证配置，并记录错误。

如果 MQTT 和 HTTP 共用一个 AT 模块，不能让 MQTT 任务和 ConfigTask 同时直接发送 AT 命令。可以由 CommunicationTask 串行执行网络事务，或者在模块和固件确实支持多连接时设计更完整的连接复用层；无论哪种方式，UART 接收和 AT 响应的归属都必须唯一。

## 23.9 用分段输入测试解析器

下面的 PC 服务故意把 Header 和 Body 拆开发送：

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

设备在 Body 收满以前不能产生成功事件。这个测试可以直接暴露“每收到一段就 `strstr()` 或 `cJSON_Parse()`”的实现错误。

再加入 Header 超过 512 字节、Content-Length 超过 1024、Body 提前断开、404、错误 JSON、字段类型错误、非整数配置和 Chunked 响应。每一种输入都应得到明确结果，不越界，也不覆盖上一份有效配置。

## 23.10 HTTPS 接入前检查模块能力

公网 API 通常使用 HTTPS。PC 浏览器能访问一个 URL，只说明 PC 的网络栈和 TLS 实现能处理它，不能推出当前 AT 模块也支持同样的协议组合。

接入公网前确认模块固件支持目标 TLS 版本、SNI、CA/证书加载、服务器名验证和所需时间来源。还要检查服务端是否会返回重定向、Chunked 或压缩内容，因为这些格式超出了本章解析器的范围。

TLS 握手失败时保留模块的具体错误码。错误 CA、服务器名不匹配和时间错误都应进入失败路径，不能为了“先连通”长期关闭证书验证。

## 23.11 本章完成标准

完成下面这些测试：

- `CIPSEND` 长度与实际 HTTP 请求字节数一致；
- `\r\n\r\n` 跨输入片段时仍能找到 Header 结尾；
- Header 与 Body 粘在同一片段时不丢字节；
- 只在收满 Content-Length 后解析 JSON；
- 404、超长响应、提前断开和 Chunked 都进入明确错误路径；
- JSON 缺字段、类型错误、非整数和范围错误不会更新当前配置；
- 连续成功和失败解析后，heap 没有持续下降；
- HTTP 失败不会阻塞 SensorTask 和 DisplayTask。

通过这些测试后，HTTP 客户端的支持范围就已经明确。下一步再根据目标服务决定是否增加 Chunked、重定向、认证 Header 或 HTTPS。

> **上一章**：[第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)
>
> **下一章**：[第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

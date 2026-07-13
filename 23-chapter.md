# 第 23 章 · HTTP、响应解析与 cJSON（SPL版）

> **本章产出**：能用 WiFi AT 模块发送一条正确的 HTTP 请求；知道如何安全地从响应中分离 Body 并解析 JSON。
>
> **前置知识**：第 20 章 TCP，以及第 22 章的配置管理。
>
> **用在哪**：REST API、天气查询、设备配置拉取、调试云端接口。

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

## 23.10 本章要点

- HTTP 请求先组装，再根据真实长度发送 AT+CIPSEND；
- TCP/UART 收包不保证一次收到完整 HTTP 响应；
- 解析 JSON 前必须验证状态码、边界、长度和字段类型；
- 网络请求应放在独立任务中；
- HTTP 很适合学习和调试 REST 接口，持续设备消息通常更适合 MQTT。

---

[上一章：第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)

[下一章：第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)

# 第 21-24 章 · 网关与云（SPL版）

> MQTT 报文拼装、云平台认证、HTTP 请求、cJSON 解析、网关架构——这些和用 SPL 还是 HAL **完全无关**。它们是纯 C 逻辑，不碰外设寄存器。
>
> MQTT 协议、HTTP、JSON 是互联网标准，和 SPL/HAL 完全无关——报文格式、QoS、Topic 这些概念不需要任何库。本章用 SPL AT 指令封装 + MQTT/HTTP 标准协议讲解。

---

## SPL 工程中的 MQTT（第 21 章）

MQTT 报文构建代码和 HAL 版**一模一样**——都是逐字节填充 `uint8_t packet[]`。唯一需要调整的是发送函数：

```c
// SPL 版 TCP 发送（替代 ESP8266_TCPSendRaw）
void MQTT_SendPacket(uint8_t *data, uint16_t len) {
    char cmd[32];
    snprintf(cmd, sizeof(cmd), "AT+CIPSEND=%d", len);
    AT_SendCmd(cmd);
    if (!AT_WaitResponse(">", 5000)) return;

    for (uint16_t i = 0; i < len; i++) {
        while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET);
        USART_SendData(USART2, data[i]);
    }
    AT_WaitResponse("SEND OK", 10000);
}

// MQTT CONNECT（报文拼装和 HAL 版相同，最后调用上面的发送函数）
void MQTT_Connect(const char *client_id) {
    uint8_t packet[128];
    uint16_t idx = 0;
    // ... 构建 CONNECT 报文（同 HAL 版第 21 章）...
    MQTT_SendPacket(packet, idx);
}
```

---

## 云平台对接（第 22 章）——三元组与 HMAC

阿里云 IoT 的三元组认证和 HMAC-SHA1 计算是**纯算法**，不依赖任何外设库。

```c
// HMAC-SHA1 在 SPL 工程中同样用：
// - 开源库：见 code/spl/hmac_sha1.c
// - 或自己实现（约 150 行）
// 代码和 HAL 版完全一致
```

---

## HTTP + cJSON（第 23 章）

HTTP 请求是通过 WiFi 模块的 TCP 连接发送的纯文本。cJSON 是纯 C 库。

```c
// SPL 版 HTTP GET
const char *request =
    "GET /api/v1/weather HTTP/1.1\r\n"
    "Host: api.example.com\r\n"
    "Connection: close\r\n\r\n";

// 通过 TCP 发送（和 MQTT 同样的发送方式）
AT_SendCmd("AT+CIPSTART=\"TCP\",\"api.example.com\",80");
AT_WaitResponse("CONNECT", 10000);

int len = strlen(request);
AT_SendCmd("AT+CIPSEND=<len>");  // 用 snprintf 构建
AT_WaitResponse(">", 5000);
AT_SendString(request);           // 直接发，不带 \r\n
AT_WaitResponse("200 OK", 10000);

// 接收响应（UART2 中断自动存入 at_rx_buf）
// 解析 JSON 体（在 \r\n\r\n 之后）
char *body = strstr(at_rx_buf, "\r\n\r\n");
if (body) {
    body += 4;
    cJSON *root = cJSON_Parse(body);
    // ... 处理和 HAL 版相同
}
```

---

## 网关架构（第 24 章）

> 网关的软件分层、协议转换、边缘计算是纯软件架构设计——和 HAL/SPL 无关。这里直接讲清楚设计模式，底层通信适配 SPL。

唯一硬件相关的差异：SPL 版使用 UART 中断接收替代 HAL 的 `HAL_UART_Receive_IT`：

```c
// SPL 中断接收（已在第 17-20 章实现）
void USART2_IRQHandler(void) {
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t ch = USART_ReceiveData(USART2);
        RingBuffer_Put(&rx_ring, ch);  // 入环形缓冲区
    }
}
```

---

> **下一步**：[第 25-27 章 · 综合实战项目（SPL版）](./25-27-chapter.md)
>
> 三个综合项目的完整 SPL 版代码——环境监测节点、BLE 门锁、多协议网关。

# 第 17-20 章 · 无线通信（SPL版）

> 无线通信的核心概念——频谱、AT 指令、WiFi/BLE 协议——是行业通用标准，和 SPL/HAL 无关。本章用 SPL UART 驱动封装 AT 指令，核心协议部分直接讲解。
>
> 这些章节的核心不是外设库，而是**协议和指令**。SPL 和 HAL 的差异只在 UART 初始化和收发上。下面给出 SPL UART 封装 + 完整的 AT 指令逻辑。

---

## SPL UART 封装（AT 指令收发的基础）

第 8 章的 SPL UART 代码在这里重写为更工程化的 AT 指令接口：

```c
#include "stm32f10x_usart.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

// ===== UART2 初始化（给 WiFi 模块用）=====
void UART2_Init(uint32_t baudrate) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_USART2, ENABLE);

    // PA2=TX (复用推挽), PA3=RX (浮空输入)
    GPIO_InitTypeDef g;
    GPIO_StructInit(&g);
    g.GPIO_Pin = GPIO_Pin_2; g.GPIO_Speed = GPIO_Speed_50MHz;
    g.GPIO_Mode = GPIO_Mode_AF_PP; GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_3; g.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &g);

    USART_InitTypeDef u;
    USART_StructInit(&u);
    u.USART_BaudRate = baudrate;
    u.USART_Mode = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART2, &u);
    USART_Cmd(USART2, ENABLE);
}

// ===== AT 指令收发 =====
#define AT_RX_BUF_SIZE 512
static char at_rx_buf[AT_RX_BUF_SIZE];
static volatile uint16_t at_rx_idx = 0;

// UART2 中断接收 ISR
void USART2_IRQHandler(void) {
    if (USART_GetITStatus(USART2, USART_IT_RXNE) != RESET) {
        uint8_t ch = USART_ReceiveData(USART2);
        if (at_rx_idx < AT_RX_BUF_SIZE - 1) {
            at_rx_buf[at_rx_idx++] = ch;
        }
        USART_ClearITPendingBit(USART2, USART_IT_RXNE);
    }
}

// 发送字符串到模块
void AT_SendString(const char *str) {
    while (*str) {
        while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET);
        USART_SendData(USART2, *str++);
    }
}

// 发送 AT 指令（自动加 \r\n）
void AT_SendCmd(const char *cmd) {
    AT_SendString(cmd);
    AT_SendString("\r\n");
}

// 等待响应（包含 expect 子串则成功，超时或 ERROR 则失败）
int AT_WaitResponse(const char *expect, uint32_t timeout_ms) {
    uint32_t start = xTaskGetTickCount();
    at_rx_idx = 0;
    memset(at_rx_buf, 0, AT_RX_BUF_SIZE);

    while ((xTaskGetTickCount() - start) < pdMS_TO_TICKS(timeout_ms)) {
        vTaskDelay(pdMS_TO_TICKS(50));
        if (strstr(at_rx_buf, expect)) return 1;
        if (strstr(at_rx_buf, "ERROR"))   return 0;
    }
    return 0;  // 超时
}
```

### ESP8266 / DX-WF24 WiFi 连接（核心 4 步）

```c
// 1. 测试通信
AT_SendCmd("AT");
if (!AT_WaitResponse("OK", 3000)) { /* 模块无响应 */ }

// 2. 设为 STA 模式
AT_SendCmd("AT+CWMODE=1");
AT_WaitResponse("OK", 2000);

// 3. 连接 WiFi
AT_SendCmd("AT+CWJAP=\"MyWiFi\",\"password123\"");
AT_WaitResponse("WIFI GOT IP", 15000);

// 4. TCP 连接
AT_SendCmd("AT+CIPSTART=\"TCP\",\"192.168.1.100\",8888");
AT_WaitResponse("CONNECT", 10000);

// 5. 发送数据
AT_SendCmd("AT+CIPSEND=5");
AT_WaitResponse(">", 5000);
AT_SendString("Hello");  // 直接发数据，不带 \r\n
AT_WaitResponse("SEND OK", 10000);
```

---

## MQTT 报文（第 21 章）SPL 版说明

MQTT 报文的拼装逻辑和 HAL 版第 21 章完全一样——都是逐字节构建 `uint8_t packet[]` 然后通过 TCP 发送。唯一区别是发送函数：

```c
// HAL 版:
ESP8266_TCPSendRaw(packet, len);

// SPL 版:
AT_SendCmd("AT+CIPSEND=<len>");
AT_WaitResponse(">", 5000);
for (int i = 0; i < len; i++) {
    while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET);
    USART_SendData(USART2, packet[i]);
}
AT_WaitResponse("SEND OK", 10000);
```

其余 CONNECT/SUBSCRIBE/PUBLISH 报文构建代码**一字不改**。

---

## 重要提示：RTL8711 / DX-WF24 用户

你的 DX-WF24 同时有 WiFi 和 BLE。STM32 端只需**一个 UART**（比如 USART2）连接模块：
- WiFi 命令用 `AT+CW...` / `AT+CIP...` 系列
- 蓝牙命令用 `AT+BLUFI...` 系列（见第 19 章兼容说明）

不需要像书中 HC-05 + HM-10 那样用两个独立模块。接线更简单：

```
STM32 PA2 (TX) ──→ DX-WF24 RX
STM32 PA3 (RX) ──→ DX-WF24 TX
STM32 GND    ──→ DX-WF24 GND
DX-WF24 3.3V ── 独立稳压 3.3V（峰值 300mA）
```

---

## 第 17-20 章阅读指引

| 章节 | 内容 | SPL 版怎么读 |
|------|------|-------------|
| 第 17 章 | 无线基础、AT 指令 | SPL UART 封装层 + 协议讲解 |
| 第 18 章 | WiFi 实战 | 看 HAL 版流程，用上面的 SPL UART 封装替代 HAL UART 调用 |
| 第 19 章 | 蓝牙实战 | 看 HAL 版流程+上面的兼容说明，UART 同理 |
| 第 20 章 | TCP/IP、lwIP | lwIP 和 SPL/HAL 无关——它是独立的网络栈，照官方文档配置即可 |

---

> **下一章**：[第 21-24 章 · 网关与云（SPL版）](./21-24-chapter.md)
>
> MQTT 报文拼装、云平台对接、HTTP + cJSON、网关架构——核心逻辑不变，SPL 版完整代码在这里。

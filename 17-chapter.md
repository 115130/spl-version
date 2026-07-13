# 第 17 章 · 无线通信基础与 AT 模块（SPL版）

> **本章产出**：理解 WiFi、BLE、无线模块和 STM32 各自负责什么；能安全接入 AT 模块，并设计一个不会把主程序卡死的 AT 命令流程。
>
> **用在哪**：第 18 章 WiFi 温度记录仪、第 19 章 BLE 温度记录仪，以及后续 MQTT、HTTP、网关项目。
>
> **前置知识**：第 8 章 UART、第 16 章 FreeRTOS。

---

## 17.1 MCU 不会自动“懂 WiFi”

STM32F103ZET6 擅长实时控制、GPIO、ADC、定时器和串口；它本身没有 WiFi 或 BLE 射频。无线功能由外部模块完成。

~~~text
传感器 → STM32（采样、控制、协议）
              ↕ UART
        WiFi/BLE AT 模块（联网、射频、TCP/BLE 协议）
              ↕ 无线
          路由器 / 手机 / 网关
~~~

因此，本书的重点不是让 STM32 实现完整 WiFi 协议栈，而是让它可靠地控制一个 AT 模块。

## 17.2 WiFi、BLE 和“是否联网”是三件事

| 特性 | WiFi | BLE |
|---|---|---|
| 典型对象 | 路由器、局域网、互联网 | 手机、近距离设备 |
| 带宽 | 较高 | 较低 |
| 功耗 | 较高 | 较低 |
| 适合 | MQTT、HTTP、连续上报 | 手机直连、低频控制 |
| 常见交互 | TCP/UDP socket | 广播、连接、Service/Characteristic |

选择依据不是“哪个更先进”，而是设备需要去哪里、多久发一次数据、靠电池还是外部供电。

## 17.3 AT 模块的本质

AT 模块把复杂的无线协议收进固件。STM32 只需经 UART 发文本命令或原始字节：

~~~text
STM32                       无线模块
  |--- AT\r\n ------------->|  探测模块
  |<-- OK\r\n --------------|
  |--- AT+CWJAP=... ------->|  加入 WiFi
  |<-- WIFI CONNECTED ------|
  |--- AT+CIPSTART=... ---->|  建 TCP
  |<-- CONNECT -------------|
~~~

AT 命令有两个常见陷阱：

- 模块返回的内容是字节流，OK、ERROR、+IPD 可能被拆成多次 UART 接收；
- 某些命令会等待数秒，不能放在按键扫描、显示刷新或 ISR 中。

## 17.4 接线和供电先于命令

最小 UART 连接：

~~~text
ZET6 USART2 TX (PA2) ───→ 模块 RX
ZET6 USART2 RX (PA3) ←─── 模块 TX
ZET6 GND             ───── 模块 GND
~~~

还必须确认：

1. 模块 TX/RX 是 3.3V 逻辑；
2. 模块的供电电压和峰值电流满足说明书要求；
3. WiFi 发射瞬间的电流通常高于 MCU GPIO 可提供的能力；
4. 模块的天线区域不要被金属、杜邦线束或人体长期遮挡。

如果“发 AT 后偶尔复位”，先怀疑供电，而不是先怀疑字符串拼错。

## 17.5 用状态机管理 AT，而不是到处 delay

不推荐：

~~~c
AT_SendCmd("AT+CWJAP=\"ssid\",\"password\"");
Delay_ms(10000);                 /* 期间系统无法做别的事 */
AT_SendCmd("AT+CIPSTART=...");
~~~

更好的模型：

~~~text
IDLE → JOINING_WIFI → OPENING_TCP → CONNECTED
  ↑          |               |           |
  └──── timeout/error ───────┴───────────┘
~~~

每个状态都应有：

- 进入时发送什么；
- 等待哪个响应；
- 最大等待多久；
- 超时后去哪里；
- 日志写什么。

在 FreeRTOS 中，把它放入独立的 Task_WiFi 或 Task_Radio；采样和显示任务不应该等待它。

## 17.6 最小 AT 驱动接口

后续章节可以统一使用以下概念接口：

~~~c
void AT_SendCmd(const char *cmd);
bool AT_WaitResponse(const char *token, uint32_t timeout_ms);
int  AT_SendRaw(const uint8_t *data, uint16_t len);
void AT_ProcessRxByte(uint8_t ch);  /* UART 接收任务调用 */
~~~

函数名可以不同，但职责不要混淆：发送命令、等待状态、发送原始数据、处理接收字节应当各自独立。

## 17.7 第一次无线实验

在接入传感器前，先完成四步：

1. 串口发送 AT，收到 OK；
2. 读取模块版本；
3. 连接路由器，串口记录成功或错误原因；
4. 断电重启模块，确认状态机能回到可连接状态。

只有这四步稳定后，才进入第 18 章的传感器与网关项目。

## 17.8 本章要点

- STM32 负责控制和数据，AT 模块负责无线与协议栈；
- WiFi 更适合联网，BLE 更适合近距离低功耗连接；
- UART 是字节流，AT 响应需要状态机而不是固定延时；
- 模块供电、GND、电平和峰值电流与代码同样重要；
- 无线连接必须作为可失败、可超时、可重连的后台任务。

---

[上一章：第 16 章 · FreeRTOS 实战](./16-chapter.md)

[下一章：第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)

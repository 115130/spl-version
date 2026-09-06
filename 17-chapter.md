# 第 17 章 · 无线通信基础与 AT 模块（SPL 版）

这一章把外部 WiFi / BLE AT 模块接到 STM32。重点不是记某一家的 AT 命令，而是建立一条可靠路径：UART 收字节，解析文本行和长度型数据，管理当前命令事务，再把连接、断线和 Payload 交给无线任务处理。

具体命令名、默认波特率、启动提示和数据前缀都要看手上模块的 AT 手册。本章只固定 STM32 这一侧的接收、超时和状态管理方式。

## 17.1 STM32 和无线模块各做什么

STM32F103ZET6 本身没有 WiFi 或 BLE 射频。常见 AT 模块内部带无线芯片和厂商固件，STM32 通过 UART 控制它。

```text
传感器 / 按键
      ↓
STM32F103
采样、控制、业务状态
      ↕ UART
WiFi / BLE 模块
射频、连接和厂商 AT 协议
      ↕
路由器 / 手机 / 网关
```

模块内部到底承担到哪一层，取决于产品。有的 AT 固件只提供 WiFi 和 socket，有的还能处理 TLS、MQTT 或 BLE GATT。STM32 侧不要假定所有模块具有同一套能力。

WiFi 和 BLE 的选择也要按实际链路决定。需要接入局域网、TCP、MQTT 或 HTTP 时通常使用 WiFi；需要手机近距离连接、广播或低频控制时常见 BLE。功耗、带宽和连接距离都与具体芯片、发射功率和工作方式有关，不用一张固定优劣表替代模块数据手册。

## 17.2 先确认供电和 UART

本章示例使用 USART2：

```text
PA2 / USART2_TX ───→ 模块 RX
PA3 / USART2_RX ←─── 模块 TX
GND             ───── GND
```

接线前确认模块供电电压和 UART 逻辑电平。模块标注“5 V 供电”不代表 UART TX 一定输出 5 V，也不代表一定是 3.3 V；以模块原理图或数据手册为准。

无线发送时电流会随芯片和射频状态变化，电源必须覆盖模块规定的峰值需求。如果模块在发射、关联 AP 或建立连接时反复复位，先测电源轨和复位脚，再检查 AT 文本。

第一次实验只做三件事：上电后记录模块启动输出，发送最简单的探测命令，读取版本信息。UART 这一层稳定以后再开始配网。

## 17.3 AT 接口本质上还是字节流

STM32 发出：

```text
AT\r\n
```

模块可能回：

```text
OK\r\n
```

但 UART 驱动实际收到的是一串字节。一次 DMA、一次中断或一次任务读取不保证正好对应一整行，下面几种切分都可能出现：

```text
"O" + "K\r\n"
"OK\r" + "\n"
"OK\r\nWIFI DISCONNECT\r\n"
```

无线模块还可能主动上报连接变化、复位提示和网络数据。因此接收路径需要先解决字节边界，再判断这些内容属于当前命令响应、异步事件还是网络 Payload。

## 17.4 命令要有明确事务边界

不要依赖“发完命令固定等几秒”推进流程。网络环境、模块状态和错误路径都会改变响应时间。

一次 AT 事务至少保存：当前状态、预期结果、截止时间和错误统计。

```c
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "FreeRTOS.h"
#include "task.h"

typedef enum {
    AT_IDLE,
    AT_WAITING,
    AT_OK,
    AT_ERROR,
    AT_TIMEOUT
} AtState;

typedef struct {
    AtState state;
    const char *expect;
    TickType_t deadline;
    uint32_t tx_count;
    uint32_t error_count;
    uint32_t timeout_count;
} AtTransaction;
```

开始事务：

```c
static bool At_Begin(AtTransaction *t,
                     const char *cmd,
                     const char *expect,
                     TickType_t timeout)
{
    if (t == NULL || cmd == NULL || expect == NULL)
        return false;

    if (t->state == AT_WAITING)
        return false;

    if (!RadioUart_WriteLine(cmd))
        return false;

    t->expect = expect;
    t->deadline = xTaskGetTickCount() + timeout;
    t->state = AT_WAITING;
    ++t->tx_count;
    return true;
}
```

收到完整文本行后再更新当前事务：

```c
static void At_OnLine(AtTransaction *t, const char *line)
{
    if (t == NULL || line == NULL || t->state != AT_WAITING)
        return;

    if (strcmp(line, t->expect) == 0) {
        t->state = AT_OK;
        return;
    }

    if (strcmp(line, "ERROR") == 0 || strcmp(line, "FAIL") == 0) {
        ++t->error_count;
        t->state = AT_ERROR;
    }
}
```

这里用完整行比较，避免等待 `OK` 时把某个更长文本里的两个字符误判成成功。具体模块如果成功响应不是独立的 `OK` 行，就按它的协议定义更明确的匹配规则。

超时检查：

```c
static void At_PollTimeout(AtTransaction *t)
{
    if (t == NULL || t->state != AT_WAITING)
        return;

    if ((int32_t)(xTaskGetTickCount() - t->deadline) >= 0) {
        ++t->timeout_count;
        t->state = AT_TIMEOUT;
    }
}
```

超时值属于每条命令的策略。简单的 `AT` 探测和加入 WiFi 的等待时间通常不会相同，应该按模块手册和实际测试分别设置。

## 17.5 RadioTask 管理连接状态

AT 事务只表示“一条命令有没有完成”，网络连接还需要更高一层状态机。例如 WiFi 模块可以维护：

```text
BOOT
  ↓
PROBING
  ↓
JOINING_AP
  ↓
OPENING_SOCKET
  ↓
ONLINE
```

任一阶段发生超时、`ERROR`、模块复位或异步断线事件，都要进入明确的恢复路径。不要在某条命令失败后继续执行下一条并保留“已连接”状态。

在 FreeRTOS 中，这套状态机放进独立的 `RadioTask`。SensorTask 继续采样，DisplayTask 继续显示；网络断线只影响无线任务和需要联网的数据队列。

重试也要限速。连续失败时可以逐步增加等待时间，例如 1 s、2 s、4 s，再限制到某个最大值。具体退避参数由产品需求决定，重点是避免断网时用紧循环持续发 AT、刷日志和占用 CPU。

## 17.6 文本行解析器

很多 AT 响应以 CRLF 结束，可以先把普通文本字节整理成完整行。

```c
#include <stddef.h>

typedef struct {
    char line[128];
    size_t used;
    bool discard_until_eol;
    uint32_t line_overflow;
} AtLineReader;

static bool AtLineReader_Push(AtLineReader *r,
                              uint8_t ch,
                              const char **out)
{
    if (r == NULL || out == NULL)
        return false;

    if (ch == '\r')
        return false;

    if (ch == '\n') {
        if (r->discard_until_eol) {
            r->discard_until_eol = false;
            r->used = 0U;
            return false;
        }

        if (r->used == 0U)
            return false;

        r->line[r->used] = '\0';
        *out = r->line;
        r->used = 0U;
        return true;
    }

    if (r->discard_until_eol)
        return false;

    if (r->used + 1U >= sizeof r->line) {
        ++r->line_overflow;
        r->used = 0U;
        r->discard_until_eol = true;
        return false;
    }

    r->line[r->used++] = (char)ch;
    return false;
}
```

过长行出现后，解析器会一直丢到下一个换行符，再开始收新行。这样不会把超长行的后半段误认成一条独立 AT 响应。

可以先在 PC 侧给这个函数做字节级测试：正常 `OK\r\n`、空行、127 字节边界、超长行后紧跟一个正常 `OK\r\n`。最后一种情况必须只增加一次 overflow，并正确恢复后续行。

## 17.7 文本行和网络 Payload 要分开

有些模块会用类似下面的格式上报网络数据：

```text
+IPD,5:HELLO
```

这里的 `HELLO` 是长度为 5 的 Payload。实际前缀、连接 ID 和格式由模块 AT 固件定义，这里只用它说明解析边界。

Payload 可能包含 `\r\n`、`OK`、零字节和任意二进制内容。进入 Payload 状态后，必须按声明长度接收固定字节数，不能继续用行解析器或 `strstr()` 判断内容。

接收器可以定义这些事件：

```c
typedef enum {
    AT_EVENT_LINE,
    AT_EVENT_PAYLOAD,
    AT_EVENT_OVERFLOW,
    AT_EVENT_RESYNC
} AtEventType;

typedef struct {
    AtEventType type;
    const uint8_t *data;
    uint16_t length;
} AtEvent;
```

内部至少需要三个状态：

```text
TEXT
  ├── 普通 CRLF 行 → AT_EVENT_LINE
  └── 长度型前缀 → READ_LENGTH

READ_LENGTH
  ├── 长度合法 → READ_PAYLOAD
  └── 长度非法/过大 → 记录错误并重新同步

READ_PAYLOAD
  └── 收满 N 字节 → AT_EVENT_PAYLOAD → TEXT
```

Payload 长度必须有上限。模块声明的长度超过本地缓冲能力时，可以丢弃指定字节数、关闭当前连接或重置解析器，具体策略要明确，并留下 `payload_oversize` 计数。

如果声明了 N 字节但只收到一部分，解析器也需要 Payload 超时。超时后丢弃半包并重新同步，不能无限停在 READ_PAYLOAD。

## 17.8 异步事件不能归到当前命令里

模块可能在等待某条命令时主动发送：

```text
WIFI DISCONNECT
ready
CLOSED
```

这些行不一定属于当前事务。解析完整行后，先分类：当前命令的响应交给 `AtTransaction`；连接变化、模块复位等交给 `RadioTask` 状态机；网络 Payload 交给后面的 TCP / MQTT / HTTP 层。

模块出现 `ready` 一类启动提示时，应认为原先的连接和命令上下文已经失效，清理当前事务并重新探测模块。不要只增加一条日志，然后继续沿用旧的 ONLINE 状态。

建议至少记录这些统计：

```c
typedef struct {
    uint32_t command_ok;
    uint32_t command_error;
    uint32_t command_timeout;
    uint32_t line_overflow;
    uint32_t payload_oversize;
    uint32_t payload_timeout;
    uint32_t module_reset;
    uint32_t uart_overflow;
} RadioStats;
```

这些计数能区分“UART 已经丢字节”“模块明确回错”“网络命令超时”和“模块自己重启”。

## 17.9 第一次配网怎么验收

先不要接传感器和 MQTT。按下面顺序验证无线模块：

1. 上电后捕获完整启动日志，确认 UART 波特率和模块复位行为。
2. 连续发送多次基础探测命令，确认每次都有明确成功、错误或超时结果。
3. 读取版本信息并保存到调试日志，后续排查 AT 命令差异时知道当前固件版本。
4. 加入一个已知可用的 AP，记录成功响应和实际连接事件。
5. 关闭 AP 或输错密码，确认状态机会退出等待并进入限速重试。
6. 模块重新上电，确认 `RadioTask` 能从 BOOT 重新走完整流程。

如果模块支持 socket，再加一项：建立 TCP 连接后从 PC 发送包含 `\r\n` 和 `OK` 字样的 Payload，确认它仍被当作二进制数据交给上层，不会误触发 AT 事务。

## 17.10 排错顺序

完全没有响应时，先检查供电、共地、TX/RX、波特率和模块启动输出。能收到乱码时再检查双方帧格式和实际串口时钟。

基础 `AT` 稳定但配网经常失败时，保留模块返回的完整错误行，检查 SSID、密码、频段、信号和固件命令集。不要把所有失败统一变成一个 `false`。

运行一段时间后解析异常时，看 UART overflow、line overflow 和 payload timeout。底层已经丢字节时，上层状态机无法恢复原始数据，只能重新同步并报告本次消息丢失。

## 17.11 练习

1. 给 `AtLineReader_Push()` 写一组 PC 单元测试，覆盖正常行、空行、超长行和溢出后的重新同步。
2. 实现一个最小 `+IPD,<len>:` 解析器，Payload 中放入 `OK\r\n`，验证它不会被命令事务消费。
3. 给 `RadioTask` 增加模块复位事件。收到 `ready` 后取消当前事务，并重新进入 PROBING。
4. 实现限速重试，连续五次配网失败时把每次实际等待间隔打印出来。
5. 扩展第 8 章的 `STATUS` 命令，输出 `RadioStats` 中的错误、超时和溢出计数。

完成这一章后，无线模块已经有一条明确的数据路径：UART 只负责字节，解析器负责行和 Payload 边界，AT 事务负责单条命令，RadioTask 负责连接状态。下一章再把温度数据接进这条链路。

> **上一章**：[第 16 章 · FreeRTOS 实战](./16-chapter.md)
>
> **下一章**：[第 18 章 · 温度记录仪 WiFi 版](./18-chapter.md)

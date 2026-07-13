# 第 8 章 · UART：从字节流到可靠控制台（SPL 版）

> **本章产出**：搭建一条可验证的 USART1 调试通道；用中断环形缓冲接收字节，在主循环中解析一行命令，并记录错误/丢包证据。
>
> **前置知识**：第 3 章 GPIO、第 5 章时钟、第 6 章中断。
>
> **硬件准备**：3.3V USB-TTL；PA9(TX)→TTL RX、PA10(RX)←TTL TX、GND 共地。先确认 USB-TTL 的逻辑电平，不把未知 5V TX 接入 MCU。

---

## 8.1 UART 的边界：异步字节流，不是消息协议

UART 只有电平和时间：空闲高、起始位低、数据位（通常 LSB 先发）、可选校验、停止位高。常见 `8N1` 指 8 个数据位、无校验、1 个停止位。

```text
空闲高 ──────┐ start  d0 d1 ... d7  stop ─────
             └──低───[     8 位     ]──高─────
```

UART 不知道“命令从哪里开始/结束”“一行有多长”“校验是否正确”。这些属于上层协议：例如以 `\r\n` 结束一行、限制最大长度、超时丢弃不完整行、或使用长度字段与 CRC。后面的 RS485/Modbus 会进一步处理帧边界和校验。

### 时钟、帧格式和错误预算

USART1 使用 PCLK2，USART2/3/UART4/UART5 使用 PCLK1。改变第 5 章的时钟后，必须重新初始化 USART。波特率容差取决于双方振荡器、采样、线缆和帧长度，不能把“超过 2% 一定失败”当成通用阈值；出现乱码时先量/查实际波特率和帧格式。

| 标志 | 物理含义 | 正确动作 |
|---|---|---|
| TXE | 数据寄存器空，可装下一个字节 | 用于连续发送 |
| TC | 移位寄存器也空，最后停止位已出线 | 仅在最后一个字节、关串口或 RS485 切回接收前等待 |
| RXNE | 接收数据寄存器有新字节 | 及时读 DR |
| ORE | 新字节到来前旧字节未取走 | 记录溢出，按 SR→DR 序列清状态 |
| FE/NE/PE | 帧/噪声/校验错误 | 记录并丢弃或交由上层决定 |

## 8.2 ZET6 的串口资源

下表是默认复用映射，不含重映射选项；实际板载 CH340/USB 串口接哪一路必须看原理图。

| 外设 | 默认 TX | 默认 RX | 总线 | 常见用途 |
|---|---|---|---|---|
| USART1 | PA9 | PA10 | APB2 | 本书外接调试默认 |
| USART2 | PA2 | PA3 | APB1 | 外设模块/第二调试通道 |
| USART3 | PB10 | PB11 | APB1 | 额外串口 |
| UART4 | PC10 | PC11 | APB1 | 高密度芯片额外通道 |
| UART5 | PC12 | PD2 | APB1 | 高密度芯片额外通道 |

不要假定调试器一定提供虚拟串口。外接 USB-TTL 常出现为 `/dev/ttyUSB0`（CH340/FTDI/CP210x），USB CDC 设备常出现为 `/dev/ttyACM0`。插入设备后可用：

```bash
dmesg -w
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
picocom -b 115200 /dev/ttyUSB0   # 按实际设备名替换
```

## 8.3 最小可发日志的 USART1

先用轮询发送验证电平、时钟、端口和终端；轮询函数必须有超时，不能在异常线路上永久卡死。

```c
#include <stdbool.h>
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_usart.h"

#define UART_WAIT_LIMIT  1000000U

static void USART1_Init_115200(void)
{
    GPIO_InitTypeDef gpio;
    USART_InitTypeDef uart;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1 |
                            RCC_APB2Periph_GPIOA, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_9;
    gpio.GPIO_Mode = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOA, &gpio);

    gpio.GPIO_Pin = GPIO_Pin_10;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    USART_StructInit(&uart);
    uart.USART_BaudRate = 115200U;
    uart.USART_WordLength = USART_WordLength_8b;
    uart.USART_StopBits = USART_StopBits_1;
    uart.USART_Parity = USART_Parity_No;
    uart.USART_HardwareFlowControl = USART_HardwareFlowControl_None;
    uart.USART_Mode = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART1, &uart);
    USART_Cmd(USART1, ENABLE);
}

static bool USART1_WriteByte(uint8_t byte)
{
    uint32_t left = UART_WAIT_LIMIT;
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET) {
        if (left-- == 0U)
            return false;
    }
    USART_SendData(USART1, byte);
    return true;
}

static bool USART1_Write(const char *text)
{
    while (*text != '\0') {
        if (!USART1_WriteByte((uint8_t)*text++))
            return false;
    }
    return true;
}
```

调用 `USART1_Write("boot\\r\\n")` 后，先确认终端稳定收到固定文本；再接 RX。若 TX 都不对，不要先写中断、命令解析或无线模块代码。

### `printf` 是可选适配层

使用 newlib/nano 的裸机工程可提供 `_write`；但不同 C 库、链接选项和 `nosys.specs` 的行为不同，必须在自己的工程构建后验证：

```c
#include <sys/types.h>

int _write(int file, char *ptr, int len)
{
    (void)file;
    for (int i = 0; i < len; ++i) {
        if (!USART1_WriteByte((uint8_t)ptr[i]))
            return i;
    }
    return len;
}
```

默认 `nano.specs` 往往不链接 `printf` 浮点格式化；若强行添加 `-u _printf_float` 会明显增加 Flash。教学日志优先输出整数、十六进制、定点值；不要把“`printf("%f")` 没输出”误诊成 UART 故障。

## 8.4 中断接收：ISR 只搬运，主循环才解释

单字节 `rx_ready` 会在主循环忙时丢失后续字节；ISR 中 `printf`、回显、等待 TXE 会拉长中断并与后续字节竞争。使用单生产者（USART ISR）/单消费者（主循环）的环形缓冲：

```c
#define UART_RX_CAP 128U             /* 必须是 2 的幂，且小于 256。 */

static uint8_t rx_buf[UART_RX_CAP];
static volatile uint8_t rx_head;     /* 只由 ISR 写 */
static volatile uint8_t rx_tail;     /* 只由主循环写 */
static volatile uint32_t rx_overflow;
static volatile uint32_t rx_error;

static void USART1_RxPush(uint8_t byte)
{
    uint8_t next = (uint8_t)((rx_head + 1U) & (UART_RX_CAP - 1U));
    if (next == rx_tail) {
        rx_overflow++;                /* 明确丢弃新字节，并留下证据。 */
        return;
    }
    rx_buf[rx_head] = byte;
    rx_head = next;                   /* 最后发布 head。 */
}

void USART1_IRQHandler(void)
{
    uint16_t sr = USART1->SR;
    uint8_t byte = (uint8_t)USART1->DR; /* F1：读 SR 再读 DR 清 RXNE/错误状态。 */

    if ((sr & (USART_SR_ORE | USART_SR_NE | USART_SR_FE | USART_SR_PE)) != 0U) {
        rx_error++;
        return;
    }
    if ((sr & USART_SR_RXNE) != 0U)
        USART1_RxPush(byte);
}

static bool USART1_ReadByte(uint8_t *out)
{
    if (rx_tail == rx_head)
        return false;
    *out = rx_buf[rx_tail];
    rx_tail = (uint8_t)((rx_tail + 1U) & (UART_RX_CAP - 1U));
    return true;
}
```

初始化时配置 NVIC（分组已由第 6 章统一）：

```c
USART_ITConfig(USART1, USART_IT_RXNE, ENABLE);
NVIC_InitTypeDef nvic = {
    .NVIC_IRQChannel = USART1_IRQn,
    .NVIC_IRQChannelPreemptionPriority = 1U,
    .NVIC_IRQChannelSubPriority = 0U,
    .NVIC_IRQChannelCmd = ENABLE,
};
NVIC_Init(&nvic);
```

这是一种容量有限的流缓冲，不是无损协议。若 `rx_overflow` 增长，优先减少主循环阻塞、增大缓冲、降低速率或在第 12 章转向 DMA；不要静默忽略。

## 8.5 在主循环解析一行命令

解析器只在 `USART1_ReadByte()` 后运行，所以 ISR 永远不碰字符串、回显或业务函数：

```c
#define LINE_CAP 48U

typedef struct {
    char data[LINE_CAP];
    uint8_t len;
    uint8_t discard_until_eol;
} LineParser;

static void Console_Execute(const char *line);

static void Console_Poll(LineParser *p)
{
    uint8_t byte;
    while (USART1_ReadByte(&byte)) {
        if (byte == '\r' || byte == '\n') {
            if (p->discard_until_eol == 0U && p->len != 0U) {
                p->data[p->len] = '\0';
                Console_Execute(p->data);  /* 这里可以回显/printf/控制 LED。 */
            }
            p->len = 0U;
            p->discard_until_eol = 0U;
        } else if (p->discard_until_eol == 0U) {
            if (p->len + 1U < LINE_CAP)
                p->data[p->len++] = (char)byte;
            else
                p->discard_until_eol = 1U; /* 过长行整个丢弃，直到换行再恢复。 */
        }
    }
}

static void Console_Execute(const char *line)
{
    if (strcmp(line, "LED ON") == 0) {
        BoardLed_Write(1U);
        USART1_Write("OK\\r\\n");
    } else if (strcmp(line, "LED OFF") == 0) {
        BoardLed_Write(0U);
        USART1_Write("OK\\r\\n");
    } else {
        USART1_Write("ERR: commands are LED ON, LED OFF\\r\\n");
    }
}
```

实际编译应包含 `<string.h>`。命令定义从 `LED ON`/`LED OFF` 起步，不把尚未验证的 WiFi/BLE/传感器模块固件命令混进 UART 基础章；这些模块从第 17 章开始按各自数据手册和板卡接线处理。

## 8.6 验收、排错与练习

按顺序验证，而不是一次接全：

1. 测 PA9 空闲高电平，发送 `boot`；
2. 在终端选择正确设备节点、115200、8N1、关闭硬件流控；
3. 发送 `LED ON\r\n`、`LED OFF\r\n`，确认业务在主循环运行；
4. 快速粘贴长文本，观察 `rx_overflow`/`rx_error`，验证系统不会卡死；
5. 断开 RX、短接错误线路或故意设错波特率时，记录错误现象，不把错误字节当有效命令执行。

| 现象 | 先检查 |
|---|---|
| 终端没有任何文本 | 电平、GND、TX/RX 是否交叉、设备节点、PA9 复用、USART1 时钟 |
| 全部乱码 | 波特率/8N1、实际 PCLK2、时钟配置和 USB-TTL 电平 |
| 第一行正常随后丢字 | RXNE ISR 是否及时读 DR；环形缓冲是否溢出；ISR 是否做了阻塞工作 |
| 终端输入无反应 | PA10/RX 接线、RXNE/NVIC、行结束符、命令缓冲是否被截断 |
| `printf` 无输出但 `USART1_Write` 正常 | `_write`/C 库/链接选项问题，不是 UART 物理层 |

练习：

1. 给 `Console_Execute` 加 `STATUS`，输出 `rx_overflow` 与 `rx_error`；
2. 改为长度前缀帧，写出最大长度与超时策略；
3. 为发送侧增加 TX 环形缓冲，比较轮询、TXE 中断和第 12 章 DMA 的适用边界；
4. 将 USART1 改为 USART2，重新推导 PCLK1、引脚和 OpenOCD/USB-TTL 接线，不只改一个实例名。

## 8.7 本章要点

- UART 是异步字节流；行、长度、超时、校验属于你设计的上层协议。
- TXE 用于继续填发送寄存器，TC 只用于最后一位真的出线后的时刻。
- 串口实例的 PCLK、默认引脚和板载 USB 转串口接线必须分别确认。
- ISR 只读状态/数据并放进缓冲；回显、`printf`、命令解析与业务控制都在主循环。
- 环形缓冲必须有容量、溢出策略与错误计数；“没看到错误”不是可靠性的证据。

---

> **上一章**：[第 7 章 · 定时器](./07-chapter.md)
>
> **下一章**：[第 9 章 · ADC 与 DAC](./09-chapter.md)

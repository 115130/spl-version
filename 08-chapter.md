# 第 8 章 · UART：从字节流到可靠控制台（SPL 版）

这一章用 USART1 建立调试串口，再把接收从单字节轮询扩展到中断环形缓冲。最终效果是：终端可以发送一行命令，主循环解析并执行，同时保留接收错误和缓冲区溢出的计数。

实验使用 3.3 V USB-TTL：PA9（TX）接 USB-TTL RX，PA10（RX）接 USB-TTL TX，GND 共地。接线前确认转换器 TX 的逻辑电平符合 MCU 输入要求。

## 8.1 UART 传输的是字节流

UART 没有独立时钟线，收发双方按约定波特率解释信号。线路空闲时为高电平，一帧通常包含起始位、数据位、可选校验位和停止位。常见的 8N1 表示 8 个数据位、无校验、1 个停止位。

```text
空闲高 ──────┐ start  d0 d1 ... d7  stop ─────
             └──低───[     8 位     ]──高─────
```

UART 外设只负责按帧格式收发数据。`LED ON\r\n` 里的换行符、最大命令长度、超时和 CRC 都属于上层协议。本章先用 `\r` 或 `\n` 作为一行结束标记，后面的协议章节再处理更完整的帧结构。

STM32F103 上，USART1 使用 PCLK2；USART2、USART3 以及高密度器件上的 UART4、UART5 使用 PCLK1。系统时钟或 APB 分频改变后，要按新的 PCLK 重新初始化 USART，否则实际波特率会改变。

调试时常见的几个状态位如下：

| 标志 | 含义 | 使用位置 |
|---|---|---|
| TXE | 发送数据寄存器可写 | 连续发送下一个字节 |
| TC | 数据寄存器和移位发送都已完成 | 等最后一个停止位真正发送完 |
| RXNE | 接收数据寄存器里有新数据 | 读取 DR |
| ORE | 新数据到来时旧数据还没读走 | 记录接收溢出并按手册清状态 |
| FE / NE / PE | 帧错误、噪声错误、校验错误 | 记录错误并决定是否丢弃该字节 |

TXE 和 TC 很容易混淆。发送多个字节时等 TXE 即可继续写 DR；RS485 切换方向、关闭 USART 或确认最后一个字节已经完全离开发送引脚时才需要 TC。

## 8.2 USART1 接线和设备节点

本章使用 USART1 默认引脚 PA9/PA10，不启用重映射。板载 USB 转串口是否连接 USART1 要看实际开发板原理图，本章不依赖板载串口，直接使用外接 USB-TTL。

Linux 插入常见 USB-TTL 后，设备节点可能是 `/dev/ttyUSB0`；USB CDC 类设备常见 `/dev/ttyACM0`。实际名称由系统枚举结果决定：

```bash
dmesg -w
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
picocom -b 115200 /dev/ttyUSB0
```

终端配置使用 115200、8N1，并关闭硬件流控。TX/RX 要交叉连接，同时必须共地。

## 8.3 先让 USART1 稳定发送

先只验证 TX。USART1 初始化包括 GPIOA 和 USART1 时钟、PA9 复用推挽输出、PA10 输入，以及帧格式和波特率配置。

USART 在 16 倍过采样下的基本关系为：

```text
baud = PCLK / (16 × USARTDIV)
```

例如 USART1 的 PCLK2 为 72 MHz、目标波特率为 115200 时：

```text
USARTDIV = 72 000 000 / (16 × 115 200) ≈ 39.0625
```

SPL 的 `USART_Init()` 会根据 `USART_BaudRate` 和当前外设时钟计算 BRR。这里的 72 MHz 只适用于第 5 章对应的时钟配置；系统若回退到 HSI，必须重新初始化 USART。

```c
#include <stdbool.h>
#include <stdint.h>
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

`UART_WAIT_LIMIT` 是轮询次数，不是固定的毫秒超时；它受 CPU 时钟、编译优化和函数实现影响。这里给轮询加上退出条件，是为了避免异常状态下永久卡住。需要确定时间上限时，改用第 5 章的时间基准。

初始化后发送：

```c
USART1_Write("boot\r\n");
```

先确认终端连续收到正确文本，再继续接收部分。此时如果没有输出，问题范围还只包括供电和接线、GPIO 复用、USART 时钟、波特率以及终端配置。

### 可选：把 `printf` 接到串口

使用 newlib/newlib-nano 的工程可以通过 `_write` 把标准输出转给 USART：

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

具体是否调用这个 `_write` 取决于 C 库和链接配置，编译后要实际验证。浮点 `printf` 也可能需要额外链接选项并增加代码体积；基础调试日志先用整数和十六进制即可。

## 8.4 用中断接收连续字节

如果只保留一个 `rx_ready` 和一个字节变量，主循环还没取走旧字节时，新字节就会覆盖它。这里改用 128 字节环形缓冲。为了区分空和满，保留一个槽位，因此最多存 127 个尚未消费的字节。

```c
#define UART_RX_CAP 128U

static uint8_t rx_buf[UART_RX_CAP];
static volatile uint8_t rx_head;     /* ISR 写 */
static volatile uint8_t rx_tail;     /* 主循环写 */
static volatile uint32_t rx_overflow;
static volatile uint32_t rx_error;

static void USART1_RxPush(uint8_t byte)
{
    uint8_t next = (uint8_t)((rx_head + 1U) & (UART_RX_CAP - 1U));

    if (next == rx_tail) {
        rx_overflow++;
        return;
    }

    rx_buf[rx_head] = byte;
    rx_head = next;
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

`UART_RX_CAP` 取 2 的幂，索引回绕就可以用按位与完成。这里索引使用 `uint8_t`，因此容量还必须适合这个索引类型；如果以后扩大缓冲区，应一起修改索引类型和回绕逻辑。

USART1 接收中断初始化：

```c
static void USART1_RxInterruptInit(void)
{
    NVIC_InitTypeDef nvic;

    USART_ITConfig(USART1, USART_IT_RXNE, ENABLE);

    nvic.NVIC_IRQChannel = USART1_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 1U;
    nvic.NVIC_IRQChannelSubPriority = 0U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}
```

优先级分组仍由第 6 章统一设置，这里只配置 USART1 的优先级。

STM32F1 的 USART 接收错误清除顺序需要注意。读取 SR 后再读取 DR，会完成 RXNE 以及 ORE、NE、FE、PE 等相关接收状态的清除序列。ISR 可以先保存 SR，再读取 DR：

```c
void USART1_IRQHandler(void)
{
    uint16_t sr = USART1->SR;

    if ((sr & (USART_SR_RXNE |
               USART_SR_ORE |
               USART_SR_NE |
               USART_SR_FE |
               USART_SR_PE)) != 0U) {
        uint8_t byte = (uint8_t)USART1->DR;

        if ((sr & (USART_SR_ORE |
                   USART_SR_NE |
                   USART_SR_FE |
                   USART_SR_PE)) != 0U) {
            rx_error++;
            return;
        }

        if ((sr & USART_SR_RXNE) != 0U)
            USART1_RxPush(byte);
    }
}
```

这样没有接收相关状态时不会无条件读取 DR。错误字节在本章直接丢弃，并增加 `rx_error`；缓冲区满时丢弃新字节，并增加 `rx_overflow`。两种情况都留下计数，后面可以从控制台读取。

环形缓冲这里只安排一个生产者和一个消费者：ISR 发布 `rx_head`，主循环推进 `rx_tail`。不要再让其他 ISR 或主循环代码直接修改 `rx_head`，否则这个简单协议就不成立了。

## 8.5 主循环解析命令

ISR 只收字节。字符串处理、命令比较和 LED 控制都放在主循环。

本章使用最多 47 个字符加结尾 `\0` 的行缓冲。收到 `\r` 或 `\n` 就结束当前行；超过长度的整行丢弃，直到下一个行结束符再恢复。

```c
#include <string.h>

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
                Console_Execute(p->data);
            }

            p->len = 0U;
            p->discard_until_eol = 0U;
            continue;
        }

        if (p->discard_until_eol != 0U)
            continue;

        if (p->len + 1U < LINE_CAP) {
            p->data[p->len++] = (char)byte;
        } else {
            p->discard_until_eol = 1U;
        }
    }
}

static void Console_Execute(const char *line)
{
    if (strcmp(line, "LED ON") == 0) {
        BoardLed_Write(1U);
        USART1_Write("OK\r\n");
    } else if (strcmp(line, "LED OFF") == 0) {
        BoardLed_Write(0U);
        USART1_Write("OK\r\n");
    } else if (strcmp(line, "STATUS") == 0) {
        /* 可在这里输出 rx_overflow 和 rx_error。 */
        USART1_Write("OK\r\n");
    } else {
        USART1_Write("ERR\r\n");
    }
}
```

常见终端会发送 `\r\n`。上面的解析器收到 `\r` 后执行一次命令，紧接着的 `\n` 因为空行不会再次执行，适合这个简单控制台。

主循环只需要持续调用：

```c
LineParser parser = {0};

for (;;) {
    Console_Poll(&parser);
    /* 其他非阻塞任务。 */
}
```

如果 `Console_Execute()` 以后加入耗时操作，接收 ISR 仍会继续把字节写入环形缓冲，但 127 字节容量最终仍可能耗尽。出现 `rx_overflow` 时，应减少主循环阻塞、调整缓冲容量或改用后面的 DMA 方案。

## 8.6 验证和排错

按层验证能明显缩小问题范围：

1. 只接 TX 和 GND，发送固定的 `boot\r\n`，确认 PA9 和终端输出正常。
2. 接入 RX，在终端发送 `LED ON\r\n` 和 `LED OFF\r\n`，确认命令只在主循环执行一次。
3. 快速粘贴超过 127 字节的数据，观察 `rx_overflow` 是否增加，确认程序不会卡死。
4. 故意把终端波特率设错，观察乱码或 `rx_error`，再恢复正确配置。
5. 用 GDB 查看 `rx_head`、`rx_tail`、`rx_overflow` 和 `rx_error`，确认故障有可观察状态。

没有任何输出时，先检查 GND、TX/RX 接线、设备节点、PA9 模式和 USART1 时钟。持续乱码时核对终端 8N1、实际 PCLK2 和波特率配置。能用 `USART1_Write()` 输出但 `printf` 不工作时，再查 `_write`、C 库和链接参数。

接收一段时间后开始丢字，先看 `rx_overflow`。如果错误计数没有增加而溢出计数持续增长，问题通常在消费速度或缓冲容量；如果 `rx_error` 增长，再检查线路、电平、波特率和接收时序。

## 8.7 练习

1. 完成 `STATUS` 命令，输出 `rx_overflow` 和 `rx_error`。
2. 给行解析器增加明确的空闲超时：一行开始后超过设定时间仍没有结束符，就丢弃当前行。
3. 为发送侧增加 TX 环形缓冲，用 TXE 中断逐字节发送，并比较它和当前轮询发送的主循环占用。
4. 把实验改到 USART2，重新确认 PA2/PA3、PCLK1 和 USB-TTL 接线，再测实际波特率。

完成本章后，UART 已经可以承担后续章节的调试日志和简单命令输入。继续扩展协议时，保留这里的几个边界：ISR 只搬运数据，缓冲区有明确容量，错误和丢包有计数，帧边界由上层协议定义。

> **上一章**：[第 7 章 · 定时器](./07-chapter.md)
>
> **下一章**：[第 9 章 · ADC 与 DAC](./09-chapter.md)

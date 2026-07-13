# 第 12 章 · DMA：缓冲区所有权、UART 流与 SDIO 数据通道

> **本章产出**：能为一次 DMA 传输说明“谁启动、谁拥有缓冲区、何时完成、失败怎样收尾”；能正确实现 UART 的 DMA TX 与循环 RX 的基础层；知道 SDIO DMA 为什么使用 32 位 FIFO 访问。
>
> **前置知识**：第 6 章中断、第 8 章 UART、第 11 章 SPI/SDIO。
>
> **本章边界**：DMA 只是数据搬运机制，不替代 UART 协议解析、SD 卡命令状态机或文件系统。

DMA 很容易被误解成“后台线程”。它不是：DMA 只会在某个外设请求到来时，按你预先给出的地址、宽度和计数搬一项数据。它不知道一帧 UART 消息在哪里结束，也不知道一块 SD 数据是否属于正确的卡命令。这些仍是程序的职责。

## 12.1 先建立传输契约

每一条 DMA 代码前，先能写出下面这张表。写不出来，就还不该调用 `DMA_Cmd(..., ENABLE)`。

| 问题 | 例：USART1 TX DMA |
|---|---|
| 外设请求源 | USART1 的 TX DMA 请求 |
| 固定外设地址 | `&USART1->DR` |
| 内存地址和宽度 | 待发字节数组，字节宽度 |
| 方向 | 内存 → 外设 |
| 计数单位 | 字节数，不是 C 字符串的“元素数”猜测 |
| 缓冲区所有者 | 发送服务；启动后调用者不能改写/释放该数据 |
| 完成含义 | DMA 已把最后一字节写入 DR；不一定已从 TX 引脚发完 |
| 错误收尾 | 关 DMA 通道、清标志、记录原因、唤醒上层 |

F103 的 DMA 没有数据缓存一致性问题（Cortex-M3 没有 D-Cache），但 C 编译器不知道“DMA 正在改内存”。直接由 DMA 写、CPU 读的缓冲区可声明为 `volatile`；这只保证编译器每次真的读取内存，**不**替你解决帧边界、并发顺序或缓冲区被覆盖的问题。

## 12.2 本书使用的固定请求映射

DMA 通道与外设请求在 STM32F103 上是硬件固定映射，不能像现代 SoC 那样随意挑一个空闲 channel。下表只列出本书实际会用到的映射；使用其他外设时仍应查 RM0008 的 DMA request mapping。

| 外设方向 | DMA 控制器 / 通道 | 本书用途 |
|---|---|---|
| ADC1 | DMA1 Channel 1 | 第 9 章连续采样 |
| SPI1 RX | DMA1 Channel 2 | 可选的 SPI 大块读 |
| SPI1 TX | DMA1 Channel 3 | 可选的 SPI 大块写 |
| USART1 TX | DMA1 Channel 4 | 控制台批量发送 |
| USART1 RX | DMA1 Channel 5 | 控制台循环接收 |
| USART2 RX | DMA1 Channel 6 | 可选 RS485 接收 |
| USART2 TX | DMA1 Channel 7 | 可选 RS485 发送 |
| SDIO | DMA2 Channel 4 | SD 卡数据 FIFO |

同一个通道的多个候选请求不能同时工作。此限制应在设计阶段显式写入资源表，而不是等到“串口偶尔不收数据”才发现 SPI 与 UART 抢了 channel。

### 12.2.1 正常、循环与内存到内存模式

| 模式 | 计数到 0 后 | 适合 | 不适合 |
|---|---|---|---|
| Normal | 停止并置完成标志 | 一帧 TX、一个 SD 块 | 无边界的串口字节流 |
| Circular | 自动从初始地址/计数重新开始 | ADC、UART RX 环形缓冲区 | 不做消费进度管理的协议帧 |
| Memory-to-memory | 不等待外设请求 | 明确的内存复制任务 | 以为它能自动处理外设 |

DMA 的优先级只影响多个 DMA 请求争用总线时的仲裁；它不改变外设协议，不会让错误的波特率、错误的 SD 地址或错误的 CS 自动正确。

## 12.3 UART TX DMA：DMA 完成不等于串口线已空

最常见的错误是第一次发送前就等待 `DMA1_FLAG_TC4`。该标志在你还没有启动任何传输时当然不会成为“上一笔已完成”的可靠条件，于是程序会永久等住。

正确模式是显式维护软件状态：只有发送服务启动过的任务才是 busy；DMA TC 中断表示内存到 DR 的搬运完成；若下游需要释放 RS485 的 DE，则还必须等待 USART 的 `TC`（最后一个停止位离开 TX 引脚）。

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "stm32f10x_dma.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_usart.h"

static volatile bool usart1_tx_dma_busy;
static volatile bool usart1_tx_dma_error;

void USART1_DmaTxInit(void)
{
    DMA_InitTypeDef dma;

    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);
    DMA_DeInit(DMA1_Channel4);
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&USART1->DR;
    dma.DMA_MemoryBaseAddr     = 0U;  /* 每次发送时填写 */
    dma.DMA_DIR                = DMA_DIR_PeripheralDST;
    dma.DMA_BufferSize         = 1U;  /* 每次发送时填写 */
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Byte;
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_Byte;
    dma.DMA_Mode               = DMA_Mode_Normal;
    dma.DMA_Priority           = DMA_Priority_Medium;
    dma.DMA_M2M                = DMA_M2M_Disable;
    DMA_Init(DMA1_Channel4, &dma);

    DMA_ITConfig(DMA1_Channel4, DMA_IT_TC | DMA_IT_TE, ENABLE);
    USART_DMACmd(USART1, USART_DMAReq_Tx, ENABLE);
    /* 此处还要按第 6 章配置 DMA1_Channel4_IRQn。 */
}

/* 只能从同一个发送服务上下文调用；多个生产者应先排队。 */
bool USART1_DmaTxStart(const uint8_t *data, uint16_t length)
{
    if (data == NULL || length == 0U || usart1_tx_dma_busy) {
        return false;
    }

    usart1_tx_dma_busy = true;       /* 在使能通道之前先占有缓冲区 */
    DMA_Cmd(DMA1_Channel4, DISABLE);
    DMA_ClearFlag(DMA1_FLAG_GL4);
    DMA1_Channel4->CMAR  = (uint32_t)data;
    DMA1_Channel4->CNDTR = length;
    DMA_Cmd(DMA1_Channel4, ENABLE);
    return true;
}

void DMA1_Channel4_IRQHandler(void)
{
    if (DMA_GetITStatus(DMA1_IT_TE4) != RESET) {
        DMA_Cmd(DMA1_Channel4, DISABLE);
        DMA_ClearITPendingBit(DMA1_IT_TE4);
        usart1_tx_dma_error = true;
        usart1_tx_dma_busy = false;
        return;
    }
    if (DMA_GetITStatus(DMA1_IT_TC4) != RESET) {
        DMA_Cmd(DMA1_Channel4, DISABLE);
        DMA_ClearITPendingBit(DMA1_IT_TC4);
        usart1_tx_dma_busy = false;
    }
}
```

上面的接口刻意不接受临时栈数组：调用成功后，`data` 必须一直有效到 DMA TC 中断到来。安全来源包括静态字符串、静态发送槽、或发送队列自己拥有的缓冲区；下面这种写法是错误的：

```c
void SendBad(void)
{
    uint8_t local[] = "hello\r\n";
    (void)USART1_DmaTxStart(local, sizeof(local));
} /* 返回后 local 已无效，DMA 仍可能在读它 */
```

同一 USART 的 `printf` 轮询重定向与 DMA TX 也不能混着用。二者都会向 `USART1->DR` 写数据，输出可能交错。要么全部经由一个串行化的 TX 服务，要么把调试日志放到另一 UART。

### 12.3.1 什么时候要等待 USART `TC`

对普通控制台，只要 DMA TC 后继续给同一 UART 排下一段数据即可，硬件会在 TXE 条件满足时续传。对半双工 RS485 则不同：DMA TC 后最后一字节可能仍在移位寄存器中。必须这样收尾：

```text
DMA TC -> 最后一个字节已写入 USART DR
等待 USART_FLAG_TC -> 最后一个停止位已从 TX 引脚发出
DE 拉低 -> 回到接收模式
```

第 12B 章会把这个序列连同超时、收发方向与 Modbus 帧边界一起实现。

## 12.4 UART RX Circular DMA：它是字节流，不是消息队列

循环 DMA 很适合让 CPU 不必每个字符进一次中断，但它只维护“写指针”。它不知道 `\r\n`、长度字段、CRC 或 Modbus 的静默间隔；这些属于解析器。

设缓冲区容量为 256（2 的幂便于取模），当前 DMA 写入位置为：

```c
#define UART_RX_CAP  256U
#define UART_RX_MASK (UART_RX_CAP - 1U)

static volatile uint8_t uart1_rx_dma[UART_RX_CAP];
static volatile uint32_t uart1_rx_wraps;
static volatile bool uart1_rx_event;
static uint32_t uart1_rx_consumed;

static uint16_t USART1_RxWriteIndex(void)
{
    return (uint16_t)((UART_RX_CAP -
            DMA_GetCurrDataCounter(DMA1_Channel5)) & UART_RX_MASK);
}
```

初始化时使用 `DMA_DIR_PeripheralSRC`、`DMA_Mode_Circular`、`DMA_PeripheralInc_Disable`、`DMA_MemoryInc_Enable`、两侧字节宽度，然后使能 `USART_DMAReq_Rx`。同时打开 DMA HT/TC 中断：半满时尽快服务，完整回卷时记录圈数。

```c
void DMA1_Channel5_IRQHandler(void)
{
    if (DMA_GetITStatus(DMA1_IT_HT5) != RESET) {
        DMA_ClearITPendingBit(DMA1_IT_HT5);
        uart1_rx_event = true;
    }
    if (DMA_GetITStatus(DMA1_IT_TC5) != RESET) {
        ++uart1_rx_wraps;
        DMA_ClearITPendingBit(DMA1_IT_TC5);
        uart1_rx_event = true;
    }
}
```

此外可打开 USART 的 IDLE 中断，把“线路空闲”当作一次尽快唤醒解析器的提示。清 IDLE 的 F1 规定动作是读 SR 后读 DR；ISR 不解析协议、不打印：

```c
void USART1_IRQHandler(void)
{
    if (USART_GetITStatus(USART1, USART_IT_IDLE) != RESET) {
        volatile uint32_t discard;
        discard = USART1->SR;
        discard = USART1->DR;
        (void)discard;
        uart1_rx_event = true;
    }
}
```

主循环里的消费器按“生产的总字节数”推进读指针。这里的 `wraps` 与 `CNDTR` 快照在临近回卷时有竞争窗口，因此实际工程还应使用 HT/TC/IDLE 事件、足够大的缓冲区，并保证主循环在一个缓冲区周期内得到运行机会。下面的代码展示的是**丢失检测与边界**，不是以一个瞬时 `CNDTR` 值伪造可靠帧：

```c
void USART1_RxService(void)
{
    uint32_t wraps;
    uint16_t write_index;
    uint32_t produced;

    if (!uart1_rx_event) {
        return;
    }
    uart1_rx_event = false;

    wraps       = uart1_rx_wraps;
    write_index = USART1_RxWriteIndex();
    produced    = wraps * UART_RX_CAP + write_index;

    if (produced - uart1_rx_consumed > UART_RX_CAP) {
        /* 生产者追过消费者至少一整圈：旧字节已不可恢复。 */
        uart1_rx_consumed = produced - UART_RX_CAP;
        Protocol_ReportRxOverrun();
    }

    while (uart1_rx_consumed != produced) {
        const uint16_t index = (uint16_t)(uart1_rx_consumed & UART_RX_MASK);
        Protocol_FeedByte(uart1_rx_dma[index]);
        ++uart1_rx_consumed;
    }
}
```

`Protocol_FeedByte()` 是第 8 章的状态机入口。它根据协议自身的长度、结束符或 CRC 决定何时交付一帧。对 Modbus RTU 来说，IDLE 只是线索，真正的帧边界仍要由第 12B 章的字符时间规则判断。

## 12.5 SDIO DMA：FIFO 是 32 位数据通道

SDIO 的数据路径不是“把 `uint8_t[512]` 原样交给任意 DMA 宽度”。F103 的 SDIO FIFO 是 32 位宽；ST 的 F1 勘误表也明确指出，SDIO 的 DMA 字节/半字访问不受支持。使用 DMA 读一个 512 字节块时，应以 128 个 word 配置 DMA2 Channel4，并让缓冲区 4 字节对齐。

```c
#include "stm32f10x_sdio.h"

#define SD_BLOCK_BYTES 512U
#define SD_BLOCK_WORDS (SD_BLOCK_BYTES / sizeof(uint32_t))

static uint32_t sd_read_block[SD_BLOCK_WORDS]
    __attribute__((aligned(4)));

void Sdio_DmaPrepareOneBlockRead(uint32_t *words)
{
    DMA_InitTypeDef dma;

    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA2, ENABLE);
    DMA_Cmd(DMA2_Channel4, DISABLE);
    DMA_DeInit(DMA2_Channel4);
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&SDIO->FIFO;
    dma.DMA_MemoryBaseAddr     = (uint32_t)words;
    dma.DMA_DIR                = DMA_DIR_PeripheralSRC;
    dma.DMA_BufferSize         = SD_BLOCK_WORDS;
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Word;
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_Word;
    dma.DMA_Mode               = DMA_Mode_Normal;
    dma.DMA_Priority           = DMA_Priority_High;
    dma.DMA_M2M                = DMA_M2M_Disable;
    DMA_Init(DMA2_Channel4, &dma);
    DMA_ClearFlag(DMA2_FLAG_GL4);
}
```

这只是“准备一块 DMA 内存”的小接口。一个完整的 `Sd_ReadBlock()` 还必须：

1. 根据 SDSC/SDHC 类型计算正确命令参数；
2. 在状态机允许的时机配置 SDIO 数据长度、方向和超时；
3. 启动 DMA 与相应数据命令；
4. 同时检查 SDIO 的 `DATAEND`、数据 CRC、数据超时、FIFO 溢出/欠载和 DMA TC；
5. 无论成功或失败都关闭 DMA、清理标志、让缓冲区所有权回到调用者。

不要把“DMA TC”单独当作读块成功：它只说明 128 个 word 已搬入 RAM。卡命令、SDIO 数据 CRC 与状态机错误仍可能失败。关于这个 32 位访问限制，见 [STM32F101xC/D/E 与 STM32F103xC/D/E 勘误表](https://www.st.com/resource/en/errata_sheet/es0340-stm32f101xcde-stm32f103xcde-device-errata-stmicroelectronics.pdf)。

## 12.6 诊断、验收与练习

| 现象 | 首先检查 |
|---|---|
| 第一次 TX DMA 永远不发 | 是否错误地先等 TC4；USART TX DMA 请求是否使能 |
| DMA TC 了但 RS485 少最后一字节 | 把 DMA TC 误当 USART TC，DE 释放太早 |
| DMA TX 内容偶发乱码 | 源数组在栈上、发送期间被改写，或 `printf` 与 DMA 同时写 DR |
| RX 缓冲区看似随机丢帧 | 消费者落后一整圈，或把 Circular DMA 当作“每次一帧” |
| SDIO DMA 的 512 字节错位 | 使用了 Byte/HalfWord，或块缓冲区未按 word 管理 |

最小验收不需要先做完整文件系统：

1. UART TX DMA 发送固定的静态字符串，记录 DMA TC 和 USART TC 的时间顺序。
2. 向 UART 连续发送超过一个 RX 缓冲区的数据，验证溢出计数会增长，而不是静默假装完整。
3. 用逻辑分析仪验证 RS485 DE（第 12B 章）直到最后一个停止位后才释放。
4. 对 SDIO 读块，比较已知扇区的 512 字节内容与 PC 上的十六进制转储；同时分别打印 DMA 与 SDIO 状态。

### 练习

1. 实现一个有两个静态槽位的 UART TX 队列，明确满队列时丢弃、返回忙还是覆盖旧日志。
2. 为 RX 循环缓冲区增加 HT/TC 事件计数，并设计一个能够复现“消费者慢一圈”的压力测试。
3. 为 SDIO DMA 设计 `enum SdTransferResult`，区分命令超时、数据 CRC、DMA 异常和地址参数错误。
4. 画出“应用 → 块设备 → SDIO 状态机 → DMA → FIFO”的所有权转移图，并标出每一次失败的清理点。

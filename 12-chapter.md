# 第 12 章 · DMA：缓冲区所有权与数据通道

这一章把 DMA 接到 USART1 和 SDIO。重点是一次传输从启动到结束期间，谁可以访问缓冲区、哪个标志代表哪一层完成，以及失败后怎样把外设和 DMA 恢复到可再次使用的状态。

DMA 按外设请求搬运数据，不解析 UART 帧，也不知道 SD 卡命令是否成功。协议边界仍由 UART 解析器、SDIO 状态机和后面的文件系统处理。

## 12.1 先确定一次 DMA 传输的边界

配置 DMA 前至少要确定这些信息：外设请求源、外设地址、内存地址、传输方向、数据宽度、数量、Normal/Circular 模式，以及传输期间谁拥有内存缓冲区。

以 USART1 TX 为例，外设地址固定为 `&USART1->DR`，方向是内存到外设，数据宽度为 1 字节。DMA 启动后，源缓冲区必须保持有效且不能被修改，直到 DMA 完成或传输被明确取消。

STM32F103 的 Cortex-M3 没有 D-Cache，因此这里没有数据缓存一致性维护问题。`volatile` 仍只解决编译器访问语义；它不能防止 CPU 在 DMA 正在读取时改写同一块内存，也不能提供 UART 帧边界。

STM32F103 的 DMA 请求与通道是固定映射。本章会用到：ADC1 对应 DMA1 Channel 1，USART1 TX/RX 对应 DMA1 Channel 4/5，SDIO 对应 DMA2 Channel 4。SPI1 RX/TX 则对应 DMA1 Channel 2/3。使用其他外设前应查 RM0008 的 DMA request mapping，不能任意挑空闲通道。

Normal 模式在计数减到 0 后停止，适合一次 UART TX 或一个 SD 数据块；Circular 模式会重新装载初始地址和计数，适合连续 ADC 或 UART RX。循环模式只解决连续搬运，消费者仍要跟踪自己读到了哪里。

## 12.2 USART1 TX：区分 DMA TC 和 USART TC

USART1 TX 使用 DMA1 Channel 4。DMA TC 表示最后一个字节已经从内存搬到 USART 数据寄存器；此时最后一字节可能仍在移位寄存器中。USART 的 `TC` 才表示整个帧连同停止位已经发送完成。

普通控制台连续发送时，DMA TC 后可以安排下一段数据。RS485 切换 DE、关闭 USART 或其他必须等线路真正空闲的操作，需要继续等待 USART TC。

```c
#include <stdbool.h>
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
    dma.DMA_MemoryBaseAddr = 0U;
    dma.DMA_DIR = DMA_DIR_PeripheralDST;
    dma.DMA_BufferSize = 1U;
    dma.DMA_PeripheralInc = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Byte;
    dma.DMA_MemoryDataSize = DMA_MemoryDataSize_Byte;
    dma.DMA_Mode = DMA_Mode_Normal;
    dma.DMA_Priority = DMA_Priority_Medium;
    dma.DMA_M2M = DMA_M2M_Disable;
    DMA_Init(DMA1_Channel4, &dma);

    DMA_ITConfig(DMA1_Channel4, DMA_IT_TC | DMA_IT_TE, ENABLE);
    USART_DMACmd(USART1, USART_DMAReq_Tx, ENABLE);

    /* DMA1_Channel4_IRQn 的 NVIC 配置按第 6 章统一设置。 */
}

bool USART1_DmaTxStart(const uint8_t *data, uint16_t length)
{
    if (data == NULL || length == 0U || usart1_tx_dma_busy)
        return false;

    usart1_tx_dma_busy = true;

    DMA_Cmd(DMA1_Channel4, DISABLE);
    DMA_ClearFlag(DMA1_FLAG_GL4);
    DMA1_Channel4->CMAR = (uint32_t)data;
    DMA1_Channel4->CNDTR = length;
    DMA_Cmd(DMA1_Channel4, ENABLE);

    return true;
}

void DMA1_Channel4_IRQHandler(void)
{
    if (DMA_GetITStatus(DMA1_IT_TE4) != RESET) {
        DMA_Cmd(DMA1_Channel4, DISABLE);
        DMA_ClearITPendingBit(DMA1_IT_GL4);
        usart1_tx_dma_error = true;
        usart1_tx_dma_busy = false;
        return;
    }

    if (DMA_GetITStatus(DMA1_IT_TC4) != RESET) {
        DMA_Cmd(DMA1_Channel4, DISABLE);
        DMA_ClearITPendingBit(DMA1_IT_GL4);
        usart1_tx_dma_busy = false;
    }
}
```

这里用软件 `busy` 表示当前是否存在由发送服务启动的任务。第一次发送前不能靠等待 DMA TC 来判断“上一笔结束”，因为此时根本没有上一笔传输。

源缓冲区的生命周期也必须覆盖整个 DMA 过程。下面这种代码有问题：

```c
void SendBad(void)
{
    uint8_t local[] = "hello\r\n";
    (void)USART1_DmaTxStart(local, sizeof local);
}
```

函数返回后 `local` 的生命周期结束，DMA 仍可能继续读取这块栈内存。可以使用静态发送槽、发送队列拥有的缓冲区，或者让调用者在完成通知前保持缓冲区有效。

同一个 USART 也不要同时让轮询 `_write()` 和 DMA TX 写 `DR`。如果日志和业务数据都走 USART1，应让它们进入同一个发送服务，由这个服务串行化访问。

## 12.3 USART1 RX：Circular DMA 只提供连续字节

USART1 RX 使用 DMA1 Channel 5。256 字节循环缓冲可以减少逐字节中断，但 DMA 不知道 `\r\n`、长度字段或 CRC。主循环仍要把新字节送进第 8 章的协议解析器。

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

DMA 配置使用外设到内存、两侧字节宽度、内存地址递增和 Circular 模式，并使能 `USART_DMAReq_Rx`。HT 和 TC 中断可以分别在半缓冲和整缓冲边界提醒主循环尽快消费：

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

还可以使用 USART IDLE 中断降低短帧的处理延迟。STM32F1 清 IDLE 的序列是先读 SR，再读 DR：

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

IDLE 只表示接收线上出现了一段空闲，不自动等于协议帧结束。第 8 章的行协议可以利用它尽快唤醒解析器；Modbus RTU 等协议仍要按自己的字符时间规则判断帧边界。

主循环可以用 DMA 当前剩余计数估算写位置，再按累计生产量推进消费者：

```c
void USART1_RxService(void)
{
    uint32_t wraps;
    uint16_t write_index;
    uint32_t produced;

    if (!uart1_rx_event)
        return;

    uart1_rx_event = false;

    wraps = uart1_rx_wraps;
    write_index = USART1_RxWriteIndex();
    produced = wraps * UART_RX_CAP + write_index;

    if (produced - uart1_rx_consumed > UART_RX_CAP) {
        uart1_rx_consumed = produced - UART_RX_CAP;
        Protocol_ReportRxOverrun();
    }

    while (uart1_rx_consumed != produced) {
        uint16_t index = (uint16_t)(uart1_rx_consumed & UART_RX_MASK);
        Protocol_FeedByte(uart1_rx_dma[index]);
        ++uart1_rx_consumed;
    }
}
```

这里有一个必须知道的边界：`uart1_rx_wraps` 和 DMA `CNDTR` 不是同一个原子快照。如果恰好在回卷附近读取，两个值可能属于不同瞬间。HT/TC/IDLE 能缩短服务间隔，但不能把这段示例变成无条件可靠的高速接收器。

实际工程可以在很短的临界区内取得一致快照，或者改用固定半缓冲块的生产/消费协议。无论选哪一种，都要保证消费者在 DMA 覆盖旧数据前完成处理，并在落后一整圈时明确报告丢失。

## 12.4 SDIO DMA：按 32 位访问 FIFO

STM32F103 的 SDIO FIFO 是 32 位宽。对应器件 errata 对 DMA 访问还有额外限制，因此本章按 word 配置 DMA2 Channel 4。一个 512 字节扇区对应 128 个 `uint32_t`。

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
    dma.DMA_MemoryBaseAddr = (uint32_t)words;
    dma.DMA_DIR = DMA_DIR_PeripheralSRC;
    dma.DMA_BufferSize = SD_BLOCK_WORDS;
    dma.DMA_PeripheralInc = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Word;
    dma.DMA_MemoryDataSize = DMA_MemoryDataSize_Word;
    dma.DMA_Mode = DMA_Mode_Normal;
    dma.DMA_Priority = DMA_Priority_High;
    dma.DMA_M2M = DMA_M2M_Disable;
    DMA_Init(DMA2_Channel4, &dma);

    DMA_ClearFlag(DMA2_FLAG_GL4);
}
```

这个函数只准备 DMA 通道，还没有构成一次 SD 读块。完整的读块操作至少要完成：

1. 根据 SDSC 或 SDHC/SDXC 计算命令参数；
2. 配置 SDIO 数据长度、块大小、方向和数据超时；
3. 准备并启动 DMA，再发送对应的数据命令；
4. 同时检查 SDIO 数据完成、CRC、超时、FIFO 错误和 DMA 状态；
5. 无论成功或失败，都关闭数据路径和 DMA、清状态，再把缓冲区交还调用者。

DMA TC 只说明 128 个 word 已经搬进 RAM。SDIO 数据 CRC 或卡状态仍可能报告失败，因此读块结果不能只看 DMA TC。

## 12.5 DMA 完成之后谁拥有缓冲区

TX 和 RX 的方向不同，但所有权规则可以写得很具体。

TX 启动前，发送服务取得源缓冲区；DMA 运行期间调用者不能改写它；DMA TC 后，普通 UART TX 可以归还缓冲区。如果业务要求线路完全发送完，则把归还点延后到 USART TC。

RX 时 DMA 持续写缓冲区，CPU 只能读取已经确认写完、且暂时不会被 DMA 覆盖的区域。Circular DMA 没有天然的“这一帧归 CPU”时刻，因此需要 HT/TC 分块、读写位置或双缓冲协议建立边界。

SDIO 块读更适合 Normal DMA：传输开始后块缓冲区归数据通道使用；只有 DMA 和 SDIO 两层都确认完成后，调用者才能把这 512 字节交给块设备层。错误路径同样要完成清理后再归还缓冲区。

## 12.6 验证和排错

UART TX 先发送固定静态字符串，同时观察 DMA TC 和 USART TC。两者应该按顺序出现；如果 RS485 在 DMA TC 时立刻拉低 DE，逻辑分析仪可以直接看到最后一个字节被截断。

UART RX 可以连续发送超过 256 字节的数据，并故意让主循环延迟处理。程序应该能够记录消费者落后或数据覆盖，而不是继续把被覆盖的数据当成完整协议帧。

SDIO 先读一个已知扇区，把 512 字节与 PC 上的十六进制结果比较，同时分别记录 DMA 状态和 SDIO 数据状态。出现错位时检查 word 宽度、缓冲区对齐、数据长度和块大小；出现 CRC 或超时时继续查 SDIO 时钟和卡状态机。

## 12.7 练习

1. 实现两个静态槽位的 USART1 TX 队列，规定队列满时返回 busy，并确保正在 DMA 发送的槽位不会被生产者改写。
2. 给 UART RX 增加 HT、TC、IDLE 三类事件计数，构造主循环故意延迟的压力测试并记录首次丢数据的位置。
3. 修改 RX 消费器，在短临界区中取得 `wraps` 和 `CNDTR` 的一致快照，再比较修改前后的压力测试结果。
4. 定义 `SdTransferResult`，分别返回命令错误、数据 CRC、数据超时、DMA 错误和参数错误，并保证每条失败路径都释放 DMA 和数据通道。

完成这一章后，后续使用 DMA 时先确定缓冲区所有权，再配置通道。调试时分别观察 DMA 完成、外设完成和协议完成，不把三个层次压成一个 `done` 标志。

> **上一章**：[第 11 章 · SPI 与 SD 卡](./11-chapter.md)
>
> **下一章**：[第 13 章 · FatFs 与文件系统](./13-chapter.md)

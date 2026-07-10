# 第 12 章 · DMA 控制器

## 12.1 为什么需要 DMA

**没有 DMA**：CPU 逐字节从 UART DR 搬到 buffer，全程占着 CPU。

**有 DMA**：告诉 DMA「把 USART1 DR 搬到 buffer，搬 1024 字节」，CPU 继续做别的事。搬完 DMA 触发中断通知。

DMA = **数据搬运工**。CPU 下命令后自己可以干别的。

> OS 课回顾：程序控制 I/O → 中断驱动 I/O → DMA，三种演进。STM32 全实现了。

## 12.2 STM32F103 DMA 架构

DMA1 7 个通道，硬件固定映射：

| 通道 | 外设 |
|------|------|
| CH1 | ADC1 |
| CH2 | SPI1_RX |
| CH3 | SPI1_TX |
| CH4 | USART1_TX |
| CH5 | USART1_RX |
| CH6 | USART2_TX |
| CH7 | USART2_RX |

**关键限制**：每个通道同一时间只能服务于一个外设。USART1_TX 和 SPI2_RX 共用 CH4，不能同时用。

## 12.3 SPL DMA 配置

```c
#include "stm32f10x_dma.h"

// DMA1 CH4: USART1 TX（内存 → 外设）
void USART1_DMA_TX_Init(void) {
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);

    DMA_InitTypeDef dma;
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&USART1->DR;
    dma.DMA_MemoryBaseAddr     = (uint32_t)tx_buffer;
    dma.DMA_DIR                = DMA_DIR_PeripheralDST;   // 内存→外设
    dma.DMA_BufferSize         = sizeof(tx_buffer);
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable; // DR 地址不变
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;      // buffer 地址递增
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Byte;
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_Byte;
    dma.DMA_Mode               = DMA_Mode_Normal;           // 搬完就停
    dma.DMA_Priority           = DMA_Priority_High;
    dma.DMA_M2M                = DMA_M2M_Disable;
    DMA_Init(DMA1_Channel4, &dma);

    USART_DMACmd(USART1, USART_DMAReq_Tx, ENABLE);  // USART → DMA 触发
    DMA_Cmd(DMA1_Channel4, ENABLE);
}
```

**关键参数**：
- `DMA_Mode_Normal`：搬一次就停
- `DMA_Mode_Circular`：搬完从头再来（ADC 连续采样用）
- `DMA_PeripheralInc_Disable`：外设地址不动（DR 寄存器固定）
- `DMA_MemoryInc_Enable`：内存地址每次+1（填 buffer）

---

## 12.4 动手①：UART DMA 收发——printf 不占 CPU

第 8 章的 `printf` 重定向用的是 `fputc` → `USART_SendData` + 轮询 TXE，每个字符 CPU 都在等。用 DMA 发一批数据，CPU 只需启动一次 DMA。

### UART1 TX DMA

```c
// 发送缓冲区
uint8_t dma_tx_buf[256];

void USART1_DMA_Transmit(const uint8_t *data, uint16_t len) {
    // 等上一次传输完成
    while (DMA_GetFlagStatus(DMA1_FLAG_TC4) == RESET);

    // 关闭后修改参数
    DMA_Cmd(DMA1_Channel4, DISABLE);

    DMA1_Channel4->CMAR = (uint32_t)data;     // 内存地址指向要发的数据
    DMA1_Channel4->CNDTR = len;               // 要发的字节数

    DMA_Cmd(DMA1_Channel4, ENABLE);
}

int main(void) {
    USART1_Init();
    USART1_DMA_TX_Init();      // 配 CH4（在 12.3 节）
    USART_DMACmd(USART1, USART_DMAReq_Tx, ENABLE);

    const char *msg = "Hello DMA! 这串数据是 DMA 自动搬的，CPU 没逐字节参与。\r\n";

    while (1) {
        USART1_DMA_Transmit((uint8_t *)msg, strlen(msg));
        // CPU 在 DMA 搬数据时可以干别的
        printf("DMA 正在后台发数据，CPU 在这里执行其他代码\r\n");
        Delay_ms(2000);
    }
}
```

### UART1 RX DMA（接收不定长数据）

接收更实用——DMA 在后台自动收字节到 buffer，CPU 不用逐字节响应中断：

```c
#define RX_BUF_SIZE  256
uint8_t dma_rx_buf[RX_BUF_SIZE];
volatile uint16_t rx_count = 0;

void USART1_DMA_RX_Init(void) {
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA1, ENABLE);

    DMA_InitTypeDef dma;
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&USART1->DR;
    dma.DMA_MemoryBaseAddr     = (uint32_t)dma_rx_buf;
    dma.DMA_DIR                = DMA_DIR_PeripheralSRC;    // 外设→内存
    dma.DMA_BufferSize         = RX_BUF_SIZE;
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;
    dma.DMA_Mode               = DMA_Mode_Circular;        // 循环，写满自动从头写
    DMA_Init(DMA1_Channel5, &dma);        // CH5 = USART1 RX

    USART_DMACmd(USART1, USART_DMAReq_Rx, ENABLE);
    DMA_Cmd(DMA1_Channel5, ENABLE);
}

// 读当前 DMA 收到了多少字节
uint16_t USART1_RX_Available(void) {
    return RX_BUF_SIZE - DMA_GetCurrDataCounter(DMA1_Channel5);
}

int main(void) {
    USART1_Init();
    USART1_DMA_RX_Init();

    printf("DMA RX 已开启，串口收数据自动存入 buffer（循环模式）\r\n");

    while (1) {
        uint16_t n = USART1_RX_Available();
        if (n > 0 && n != rx_count) {
            printf("DMA 收到 %d 字节: ", n);
            for (uint16_t i = rx_count; i < n; i++)
                USART_SendData(USART1, dma_rx_buf[i]);
            rx_count = n;
        }
        // CPU 可以做别的事，DMA 在后台收数据
    }
}
```

### UART DMA 效果对比

| 方式 | 发 1KB 数据 | 收 1KB 数据 |
|------|-----------|-----------|
| 轮询 | CPU 忙等 ~10ms | CPU 忙等 ~10ms |
| 中断 | CPU 进 ~1000 次 ISR | CPU 进 ~1000 次 ISR |
| **DMA** | **CPU 启动一次即走** | **CPU 启动一次即走** |

---

## 12.5 动手②：SDIO + DMA 读 SD 卡扇区

第 11 章用 SDIO 初始化了 SD 卡，但读数据需要轮询 FIFO——每个字 CPU 都要等。加上 DMA 后，SDIO 读一整个扇区自动搬运到内存，CPU 只等一次完成中断。

### SDIO DMA 配置

STM32F103 VET6/ZET6（你的板子）有 **DMA2**，SDIO 固定接 **DMA2 通道 4**：

```c
// 512 字节的扇区 buffer
uint8_t sdio_buffer[512];

void SDIO_DMA_Init(void) {
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_DMA2, ENABLE);

    DMA_InitTypeDef dma;
    DMA_StructInit(&dma);
    dma.DMA_PeripheralBaseAddr = (uint32_t)&SDIO->FIFO;   // SDIO FIFO 地址
    dma.DMA_MemoryBaseAddr     = (uint32_t)sdio_buffer;    // 内存 buffer
    dma.DMA_DIR                = DMA_DIR_PeripheralSRC;    // 外设→内存（读卡）
    dma.DMA_BufferSize         = 128;                       // 512 字节 / 4 = 128 个字
    dma.DMA_PeripheralInc      = DMA_PeripheralInc_Disable;
    dma.DMA_MemoryInc          = DMA_MemoryInc_Enable;
    dma.DMA_PeripheralDataSize = DMA_PeripheralDataSize_Word;  // FIFO 32 位
    dma.DMA_MemoryDataSize     = DMA_MemoryDataSize_Word;
    dma.DMA_Mode               = DMA_Mode_Normal;
    dma.DMA_Priority           = DMA_Priority_VeryHigh;
    DMA_Init(DMA2_Channel4, &dma);

    SDIO_DMACmd(ENABLE);          // SDIO 使能 DMA
}
```

### 读一个扇区

```c
uint8_t SD_ReadBlock_DMA(uint32_t sector) {
    uint32_t resp[4];

    // 1. CMD16: 设块大小 512
    SDIO_SendCmd(16, 512, SDIO_Response_Short, NULL);

    // 2. CMD17: 读单块
    SDIO_SendCmd(17, sector * 512, SDIO_Response_Short, resp);
    if (resp[0] & 0xFF) return 1;   // 检查错误位

    // 3. 配置 DMA 开始搬运
    DMA_Cmd(DMA2_Channel4, DISABLE);
    DMA2_Channel4->CMAR  = (uint32_t)sdio_buffer;
    DMA2_Channel4->CNDTR = 128;       // 512 字节 → 128 次 32 位传输
    DMA_Cmd(DMA2_Channel4, ENABLE);

    // 4. 启动 SDIO 数据通道
    SDIO_DataInitTypeDef data;
    SDIO_DataStructInit(&data);
    data.SDIO_DataTimeOut   = 0xFFFFFF;
    data.SDIO_DataLength    = 512;
    data.SDIO_DataBlockSize = SDIO_DataBlockSize_512b;
    data.SDIO_TransferDir   = SDIO_TransferDir_ToSDIO;       // 卡→主机
    data.SDIO_TransferMode  = SDIO_TransferMode_Block;
    data.SDIO_DPSM          = SDIO_DPSM_Enable;
    SDIO_DataConfig(&data);

    // 5. 等 DMA 传输完成
    while (DMA_GetFlagStatus(DMA2_FLAG_TC4) == RESET);
    DMA_ClearFlag(DMA2_FLAG_TC4);

    return 0;
}

int main(void) {
    USART1_Init();
    SD_Init();               // 第 11 章的 SDIO 初始化
    SDIO_DMA_Init();

    if (SD_ReadBlock_DMA(0) == 0) {    // 读第 0 扇区（MBR）
        printf("第 0 扇区前 16 字节:\r\n");
        for (int i = 0; i < 16; i++)
            printf("%02X ", sdio_buffer[i]);
        printf("\r\n");
    }
    while (1);
}
```

输出：
```
第 0 扇区前 16 字节:
EB 3C 90 4D 53 44 4F 53 35 2E 30 00 02 08 3E 00
```

这是 FAT 文件系统的 MBR 引导扇区。

### 数据流对比

```
无 DMA：CPU 发 CMD17 → 循环读 FIFO (128 次) → 拿到数据
                           CPU 被绑死在这里

有 DMA：CPU 发 CMD17 → 启动 DMA → 等一次完成中断 → 拿数据
                           DMA 干活，CPU 做别的
```

CPU 从「逐字等待」变成「只等一次完成通知」，效率提升一个数量级。配合后续第 13 章的 FatFs 文件系统，读 SD 卡上的文件只需要 `f_open` + `f_read`，底层全部由 SDIO + DMA 自动完成。

---

## 12.6 SPL vs HAL DMA 对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 初始化 | `DMA_Init()` + 手配通道/外设请求 | `HAL_DMA_Init()` + `HAL_PPP_Transmit_DMA()` |
| UART TX | 开 `USART_DMAReq_Tx` + 配 DMA 通道 | `HAL_UART_Transmit_DMA()` 一步 |
| UART RX | 循环模式 + 查 CNDTR 剩余计数值 | `HAL_UART_Receive_DMA()` + 回调 |
| SDIO | 手动配 DMA2 通道 4 | `HAL_SD_ReadBlocks_DMA()` 一步 |
| ADC 连续 | ADC 开 DMA 请求 + DMA 循环模式 | `HAL_ADC_Start_DMA()` + 回调 |

HAL 把「外设请求 + DMA 通道」封装成一步函数，内部自动配中断和回调。SPL 的优势在于你同时看到外设侧的 `USART_DMACmd()` 和 DMA 侧的通道配置——理解了 DMA 的完整工作流。

## 12.7 本章要点

- DMA = Direct Memory Access，**自动搬运数据**，CPU 只需启动和收完成通知
- UART TX DMA：发大量数据不占 CPU；UART RX DMA 循环模式：自动收数据到环形 buffer
- SDIO + DMA：读 SD 卡扇区不再逐字等待，DMA 搬完一整块再通知 CPU
- **循环模式**（`Circular`）用于不间断数据流（ADC、UART RX）
- **普通模式**（`Normal`）用于一次性传输（SPI Flash 读、SD 卡读块）
- 第 9 章的 ADC 多通道 DMA 是 DMA 在 ADC 上的应用——DMA 是连接各章外设的「黏合剂」


---

> **上一章**：[第 11 章 · SPI 总线](./11-chapter.md)
>
> **下一章**：[第 13 章 · 存储器与文件系统](./13-chapter.md)
>
> DMA 解放了 CPU。配上海量存储（Flash/SD卡），你的系统才能真正独立工作。

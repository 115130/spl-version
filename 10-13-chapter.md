# 第 10-13 章 · I2C / SPI / DMA / FatFs（SPL 版）

> 四个重要外设和子系统：I2C（OLED 屏）、SPI（Flash 存储）、DMA（零拷贝传输）、FatFs（SD 卡文件系统）。
> 每部分先讲原理，再给 SPL 代码。

---

# 第 10 章 · I2C 总线

## 10.1 为什么需要总线

8 个传感器如果各用 3 根线，需要 24 根 GPIO。如果共享 2 根线——只需要 2 根。**I2C 就是这 2 根线的总线协议。**

### 物理层

```
SDA (数据) ──┬──┬──┬── ... ──┬── VDD (上拉电阻)
SCL (时钟) ──┼──┼──┼── ... ──┼── VDD (上拉电阻)
             │  │  │         │
          ┌──┴──┴──┴─┐    ┌──┴──┐
          │   MCU    │    │ 设备 │
          │  (主机)   │    │ (从机)│
          └──────────┘    └─────┘
```

两根线都需要**上拉电阻**（4.7kΩ→VDD）。I2C 用**开漏输出**——设备只能拉低，不能拉高。高电平由上拉电阻提供。为什么？多设备共享同一条线，推挽输出会导致短路。开漏确保「谁拉低谁赢」的**线与**逻辑。

### 速度

| 模式 | 速率 | 常用 |
|------|------|------|
| 标准 | 100kHz | 大多数传感器 |
| 快速 | 400kHz | OLED 屏 |
| Fm+ | 1MHz | 高速传输 |

STM32F103 支持标准和快速模式。

### 协议

```
起始条件 → 地址 + R/W → ACK → 数据 → ACK → ... → 停止条件

起始条件：SCL 高时 SDA 下降沿
停止条件：SCL 高时 SDA 上升沿
地址：7 位地址 + 1 位 R/W（0=写, 1=读）
ACK：第 9 个 SCL 脉冲，从机拉低 SDA 表示「收到」
```

常见 I2C 设备地址：SSD1306 OLED = 0x3C，AT24C02 EEPROM = 0x50。

## 10.2 SPL I2C 初始化（SSD1306 OLED）

```c
#include "stm32f10x_i2c.h"

void I2C1_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_I2C1, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    // PB6 = SCL, PB7 = SDA（复用开漏）
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin   = GPIO_Pin_6 | GPIO_Pin_7;
    gpio.GPIO_Mode  = GPIO_Mode_AF_OD;  // 开漏！
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOB, &gpio);

    I2C_InitTypeDef i2c;
    I2C_StructInit(&i2c);
    i2c.I2C_Mode              = I2C_Mode_I2C;
    i2c.I2C_ClockSpeed        = 400000;    // 快速模式 400kHz
    i2c.I2C_DutyCycle         = I2C_DutyCycle_2;
    i2c.I2C_Ack               = I2C_Ack_Enable;
    i2c.I2C_AcknowledgedAddress = I2C_AcknowledgedAddress_7bit;
    i2c.I2C_OwnAddress1       = 0x00;      // 主机模式不需要自己的地址
    I2C_Init(I2C1, &i2c);
    I2C_Cmd(I2C1, ENABLE);
}
```

### SPL I2C 写入（写命令/数据到 SSD1306）

```c
void I2C_WriteByte(uint8_t addr, uint8_t reg, uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, addr << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, reg);              // 控制字节
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, data);             // 数据字节
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);
}
```

**SPL I2C 比 HAL 繁琐**：需要手动 START → 等标志 → 发地址 → 等标志 → 发数据 → STOP。每个步骤都要检查事件标志。这是 SPL 底层透明性的代价——但你能看到 I2C 协议的每一步。

---

# 第 11 章 · SPI 总线

## 11.1 SPI 协议原理

四线全双工同步串行总线，比 I2C 快（几十 MHz vs 400kHz），多两根线。

```
          SCLK (时钟) ────────────
主机      MOSI (发) ────→  从机
          MISO (收) ←────
          NSS  (片选) ────→
          GND  ────────────
```

| 信号 | 方向 | 功能 |
|------|------|------|
| SCLK | 主机→从机 | 时钟 |
| MOSI | 主机→从机 | 数据 |
| MISO | 从机→主机 | 数据 |
| NSS | 主机→从机 | 片选（低有效 = 选中） |

**关键特性**：
- **全双工**：收发同时，主机发一个字节也收到了一个
- **没有标准协议层**：SPI 只定义物理层，上层由芯片自定义
- **没有应答**：发完就完，错了不知道

### 四种模式（CPOL / CPHA）

| Mode | CPOL | CPHA | 空闲 SCLK | 采样沿 |
|------|------|------|----------|--------|
| 0 | 0 | 0 | 低 | 上升沿 |
| 1 | 0 | 1 | 低 | 下降沿 |
| 2 | 1 | 0 | 高 | 下降沿 |
| 3 | 1 | 1 | 高 | 上升沿 |

**Mode 0 最常用**——W25Q64 Flash、SD 卡 SPI 模式都用 Mode 0。

## 11.2 SPL SPI 初始化和收发

```c
#include "stm32f10x_spi.h"

void SPI1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_SPI1 | RCC_APB2Periph_GPIOA, ENABLE);

    // PA5=SCK, PA7=MOSI (复用推挽)；PA6=MISO (浮空输入)
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Pin   = GPIO_Pin_5 | GPIO_Pin_7;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    GPIO_Init(GPIOA, &gpio);
    gpio.GPIO_Pin   = GPIO_Pin_6;
    gpio.GPIO_Mode  = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    SPI_InitTypeDef spi;
    SPI_StructInit(&spi);
    spi.SPI_Direction         = SPI_Direction_2Lines_FullDuplex;
    spi.SPI_Mode              = SPI_Mode_Master;
    spi.SPI_DataSize          = SPI_DataSize_8b;
    spi.SPI_CPOL              = SPI_CPOL_Low;      // Mode 0
    spi.SPI_CPHA              = SPI_CPHA_1Edge;
    spi.SPI_NSS               = SPI_NSS_Soft;      // 软件片选
    spi.SPI_BaudRatePrescaler = SPI_BaudRatePrescaler_8;  // 72/8=9MHz
    spi.SPI_FirstBit          = SPI_FirstBit_MSB;
    SPI_Init(SPI1, &spi);
    SPI_Cmd(SPI1, ENABLE);
}

uint8_t SPI_Transfer(uint8_t tx) {
    while (SPI_I2S_GetFlagStatus(SPI1, SPI_I2S_FLAG_TXE) == RESET);
    SPI_I2S_SendData(SPI1, tx);
    while (SPI_I2S_GetFlagStatus(SPI1, SPI_I2S_FLAG_RXNE) == RESET);
    return SPI_I2S_ReceiveData(SPI1);
}
```

**片选脚**（如 PB12 接 W25Q64 的 CS）需要自己手动控制：`GPIO_ResetBits(GPIOB, GPIO_Pin_12)` 选中芯片，传输完 `GPIO_SetBits(...)` 释放。

---

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

# 第 13 章 · 存储器与文件系统

## 13.1 存储体系

ZET6 Flash 512KB：你的程序用了几 KB，剩下的可以当 EEPROM 存配置参数。

**Flash 操作铁律**：
- 只能按页擦除（1KB/页）
- 擦除后全为 1，写只能 1→0
- 寿命 ~10,000 次擦除（存配置够用，别每毫秒写）

## 13.2 SPL 内部 Flash 写配置

```c
#include "stm32f10x_flash.h"

#define CONFIG_PAGE_ADDR  0x0807F800  // Flash 最后一页（ZET6: 512KB 的最后一页）

void Flash_WriteConfig(uint32_t data) {
    FLASH_Unlock();                            // 解锁
    FLASH_ErasePage(CONFIG_PAGE_ADDR);         // 擦除整页（1KB）
    FLASH_ProgramWord(CONFIG_PAGE_ADDR, data); // 写一个字
    FLASH_Lock();                              // 上锁
}

uint32_t Flash_ReadConfig(void) {
    return *(volatile uint32_t *)CONFIG_PAGE_ADDR;
}
```

⚠️ 写 Flash 时 CPU 会暂停（Flash 总线被占用），不要写太频繁。

## 13.3 FatFs 文件系统

FatFs 是一个独立的 C 库，**不依赖 HAL 或 SPL**。你需要实现的只有底层磁盘 I/O：

```c
// diskio.c — 你需要实现的 6 个函数
DSTATUS disk_initialize(BYTE pdrv);              // 初始化 SD 卡
DSTATUS disk_status(BYTE pdrv);                  // 查询状态
DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count);
DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count);
DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff);
DWORD   get_fattime(void);                      // 返回当前时间戳
```

这些函数内部调 SPI 收发函数（上面第 11 章的 `SPI_Transfer`）来跟 SD 卡通信。SD 卡初始化序列在 HAL 版第 13 章有完整的图——那个流程和库无关，直接用。

移植后使用：

```c
FATFS fs;
f_mount(&fs, "0:", 1);           // 挂载 SD 卡
f_open(&file, "data.txt", FA_WRITE | FA_CREATE_ALWAYS);
f_write(&file, "hello", 5, &bw);
f_close(&file);
```

**FatFs 和 SPL/HAL 无关**——这是纯 C 算法库，任何平台都能用。

---

## SPL I2C EEPROM 读写（AT24C02）

AT24C02 是 2Kbit（256 字节）I2C EEPROM。地址 0x50：

```c
void EEPROM_WriteByte(uint8_t addr, uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0xA0, I2C_Direction_Transmitter);  // 0x50<<1 | 0
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, addr);    // EEPROM 内部地址
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, data);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);
    Delay_ms(5);  // EEPROM 写周期 ~5ms
}

uint8_t EEPROM_ReadByte(uint8_t addr) {
    // 先写地址（伪写）
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));
    I2C_Send7bitAddress(I2C1, 0xA0, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));
    I2C_SendData(I2C1, addr);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    // 再重启读
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));
    I2C_Send7bitAddress(I2C1, 0xA1, I2C_Direction_Receiver);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_RECEIVER_MODE_SELECTED));

    // 读一个字节后 NACK
    I2C_AcknowledgeConfig(I2C1, DISABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_RECEIVED));
    uint8_t data = I2C_ReceiveData(I2C1);

    I2C_GenerateSTOP(I2C1, ENABLE);
    I2C_AcknowledgeConfig(I2C1, ENABLE);
    return data;
}
```

---

## SPL SPI Flash 驱动（W25Q64）

W25Q64 = 8MB SPI NOR Flash。Mode 0，CS 用 PB12。

```c
#define FLASH_CS_LOW()   GPIO_ResetBits(GPIOB, GPIO_Pin_12)
#define FLASH_CS_HIGH()  GPIO_SetBits(GPIOB, GPIO_Pin_12)

uint32_t Flash_ReadID(void) {
    FLASH_CS_LOW();
    SPI_Transfer(0x9F);             // JEDEC ID 命令
    uint32_t id  = SPI_Transfer(0xFF) << 16;
    id          |= SPI_Transfer(0xFF) << 8;
    id          |= SPI_Transfer(0xFF);
    FLASH_CS_HIGH();
    return id;  // W25Q64 → 0xEF4017
}

void Flash_ReadData(uint32_t addr, uint8_t *buf, uint16_t len) {
    FLASH_CS_LOW();
    SPI_Transfer(0x03);                    // Read Data 命令
    SPI_Transfer((addr >> 16) & 0xFF);     // 地址高字节
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    for (uint16_t i = 0; i < len; i++)
        buf[i] = SPI_Transfer(0xFF);       // 发 dummy 字节，收数据
    FLASH_CS_HIGH();
}

void Flash_WritePage(uint32_t addr, uint8_t *buf, uint16_t len) {
    Flash_WriteEnable();                   // 先写使能
    FLASH_CS_LOW();
    SPI_Transfer(0x02);                    // Page Program 命令
    SPI_Transfer((addr >> 16) & 0xFF);
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    for (uint16_t i = 0; i < len; i++)
        SPI_Transfer(buf[i]);
    FLASH_CS_HIGH();
    Flash_WaitBusy();                      // 等写完成
}

void Flash_EraseSector(uint32_t addr) {
    Flash_WriteEnable();
    FLASH_CS_LOW();
    SPI_Transfer(0x20);                    // Sector Erase (4KB)
    SPI_Transfer((addr >> 16) & 0xFF);
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    FLASH_CS_HIGH();
    Flash_WaitBusy();
}
```

**Flash 铁律**：写之前必须先擦除（erase-before-write）。擦除后全为 0xFF，写只能 1→0。

---

## DMA + UART 不定长数据接收（IDLE 中断）

UART 空闲中断（IDLE）在总线静默一帧时间后触发——完美用于不定长帧：

```c
volatile uint8_t dma_rx_done = 0;

void USART1_IRQHandler(void) {
    if (USART_GetITStatus(USART1, USART_IT_IDLE) != RESET) {
        USART_ReceiveData(USART1);           // 读 DR 清 IDLE
        DMA_Cmd(DMA1_Channel5, DISABLE);     // 暂停 DMA
        uint16_t len = DMA_GetCurrDataCounter(DMA1_Channel5);  // 剩余 = 总-已收
        dma_rx_len = RX_BUF_SIZE - len;     // 实际收到字节数
        dma_rx_done = 1;
        DMA_SetCurrDataCounter(DMA1_Channel5, RX_BUF_SIZE);  // 重置计数
        DMA_Cmd(DMA1_Channel5, ENABLE);     // 重新启动
    }
}
```

---

## DMA + ADC 乒乓缓冲

ADC 连续采样用 DMA 搬运时，用半传输/全传输中断实现乒乓缓冲——一组填数据时，CPU 处理另一组：

```c
#define BUF_SIZE 256
uint16_t adc_buf[2][BUF_SIZE];  // 双缓冲
volatile uint8_t ping_pong = 0;

void DMA1_Channel1_IRQHandler(void) {
    if (DMA_GetITStatus(DMA1_IT_HT1)) {    // 半传输完成
        DMA_ClearITPendingBit(DMA1_IT_HT1);
        // 后半缓冲区正在填，CPU 处理前半
        ProcessADC(adc_buf[0], BUF_SIZE / 2);
    }
    if (DMA_GetITStatus(DMA1_IT_TC1)) {    // 全传输完成
        DMA_ClearITPendingBit(DMA1_IT_TC1);
        // 前半重新填，CPU 处理后半
        ProcessADC(adc_buf[0] + BUF_SIZE / 2, BUF_SIZE / 2);
    }
}
```

---

## SD 卡 SPI 模式

SD 卡上电后原生 SD 模式，需要发 CMD0 切到 SPI 模式：

```c
// SD 卡 SPI 初始化序列：
// 1. 上电后发 ≥74 个时钟脉冲（SPI 发 10 字节 0xFF）
// 2. CS 拉低，发 CMD0 (0x40 00 00 00 00 95)  → SD 卡回应 0x01（进入 SPI 模式）
// 3. 发 CMD8 (0x48 00 00 01 AA 87) → 检查 SD 版本
// 4. 循环发 CMD55 + ACMD41 → 等 SD 卡退出 idle 状态
// 5. 发 CMD58 读 OCR → 检查 CCS 位（SDHC/SDXC 支持）

// FatFs 的 disk_initialize() 就是在做上述序列
// SPL 只需要实现 SPI_Transfer()，剩下的交给 FatFs
```

移植 FatFs 时，`diskio.c` 中的 SPI 收发调用上面的 `SPI_Transfer`，片选用 `GPIO_ResetBits`/`GPIO_SetBits` 控制。FatFs 本身不管你的 SPI 用 HAL 还是 SPL——只要给它能用的 `disk_read`/`disk_write`。

---

## SPL API 速查

| I2C | 函数 |
|-----|------|
| 初始化 | `I2C_Init(I2C1, &cfg)` |
| 起始条件 | `I2C_GenerateSTART(I2C1, ENABLE)` |
| 发地址 | `I2C_Send7bitAddress(I2C1, addr<<1, Dir)` |
| 发数据 | `I2C_SendData(I2C1, byte)` |
| 停止条件 | `I2C_GenerateSTOP(I2C1, ENABLE)` |

| SPI | 函数 |
|-----|------|
| 收发 | `SPI_I2S_SendData` / `SPI_I2S_ReceiveData` |

| DMA | 函数 |
|-----|------|
| 初始化 | `DMA_Init(DMA1_Channel4, &cfg)` |
| 使能 | `DMA_Cmd(DMA1_Channel4, ENABLE)` |

| Flash | 函数 |
|------|------|
| 解锁/上锁 | `FLASH_Unlock()` / `FLASH_Lock()` |
| 擦除页 | `FLASH_ErasePage(addr)` |
| 编程字 | `FLASH_ProgramWord(addr, data)` |

---

> **下一章**：[第 14 章 · FreeRTOS 入门（SPL版）](./14-chapter.md)
>
> 裸机部分告一段落。接下来进入多任务世界——让你的 MCU 同时做多件事。

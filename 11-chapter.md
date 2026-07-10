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

## 11.3 动手：通过 SDIO 读取 SD 卡

你的板子上有 **SD 卡槽**（TF/MicroSD），连接的是 STM32 的 **SDIO 外设**（不是 SPI），引脚固定：

| SDIO 信号 | STM32 引脚 | SD 卡槽 |
|-----------|-----------|---------|
| SDIO_D0 | PC8 | DAT0 |
| SDIO_D1 | PC9 | DAT1（1 位模式可省略）|
| SDIO_D2 | PC10 | DAT2（1 位模式可省略）|
| SDIO_D3 | PC11 | DAT3（1 位模式可省略）|
| SDIO_SCK | PC12 | CLK |
| SDIO_CMD | PD2 | CMD |

供电：VCC → 3.3V，GND → GND。

> SDIO 有两种模式：**1 位模式**（只用 D0 + CMD）和 **4 位模式**（D0-D3 全用）。1 位模式更简单，代码量少很多。这里用 1 位模式初始化。

### SDIO 初始化

SDIO 外设比 SPI 复杂——它有专门的命令状态机和 CRC 硬件，不需要手动逐字节传。

```c
void SDIO_Init_1Bit(void) {
    // 1. SDIO 时钟（RCC）
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC | RCC_APB2Periph_GPIOD, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_SDIO, ENABLE);

    // 2. GPIO：PC8 (D0)、PC9 (D1)、PC10 (D2)、PC11 (D3)、PC12 (SCK)→复用推挽
    //    PD2 (CMD)→复用推挽
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Pin   = GPIO_Pin_8 | GPIO_Pin_9 | GPIO_Pin_10 | GPIO_Pin_11 | GPIO_Pin_12;
    GPIO_Init(GPIOC, &gpio);
    gpio.GPIO_Pin   = GPIO_Pin_2;
    GPIO_Init(GPIOD, &gpio);

    // 3. SDIO 配置：1 位模式、时钟分频
    SDIO_InitTypeDef sdio;
    SDIO_StructInit(&sdio);
    sdio.SDIO_ClockEdge           = SDIO_ClockEdge_Rising;
    sdio.SDIO_ClockBypass         = SDIO_ClockBypass_Disable;
    sdio.SDIO_ClockPowerSave      = SDIO_ClockPowerSave_Disable;
    sdio.SDIO_BusWide             = SDIO_BusWide_1b;      // 1 位模式
    sdio.SDIO_HardwareFlowControl = SDIO_HardwareFlowControl_Disable;
    sdio.SDIO_ClockDiv            = 0x02;                 // 72/(2+2) = 18MHz
    SDIO_Init(&sdio);

    SDIO_SetPowerState(SDIO_PowerState_ON);   // 上电
    while (SDIO_GetPowerState() != SDIO_PowerState_ON);
}
```

### 发送命令函数

SDIO 用硬件命令状态机——填好命令寄存器，硬件自动发 CRC 和等响应：

```c
uint8_t SDIO_SendCmd(uint8_t cmd, uint32_t arg, uint32_t resp_type, uint32_t *resp) {
    SDIO_CmdInitTypeDef sdio_cmd;
    SDIO_CmdStructInit(&sdio_cmd);
    sdio_cmd.SDIO_CmdIndex  = cmd;
    sdio_cmd.SDIO_Argument  = arg;
    sdio_cmd.SDIO_Response  = resp_type;  // 见下方宏
    sdio_cmd.SDIO_Wait      = SDIO_Wait_No;
    sdio_cmd.SDIO_CPSM      = SDIO_CPSM_Enable;
    SDIO_SendCommand(&sdio_cmd);

    // 等命令完成
    while (SDIO_GetFlagStatus(SDIO_FLAG_CMDSENT) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CMDREND) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CCRCFAIL) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CTIMEOUT) == RESET);

    if (SDIO_GetFlagStatus(SDIO_FLAG_CTIMEOUT)) {
        SDIO_ClearFlag(SDIO_FLAG_CTIMEOUT);
        return 0xFF;   // 超时
    }

    // 读响应
    if (resp_type != SDIO_Response_No) {
        resp[0] = SDIO_GetResponse(SDIO_RESP1);
        resp[1] = SDIO_GetResponse(SDIO_RESP2);
        resp[2] = SDIO_GetResponse(SDIO_RESP3);
        resp[3] = SDIO_GetResponse(SDIO_RESP4);
    }
    return 0;   // 成功
}
```

### 完整初始化

```c
uint8_t SD_Init(void) {
    uint32_t resp[4];

    SDIO_Init_1Bit();

    // 1. 上电后等至少 74 个时钟（SDIO 发 8 个空命令带足够脉冲）
    for (int i = 0; i < 10; i++) {
        SDIO_SendCmd(0, 0, SDIO_Response_No, resp);  // 发空 CMD0 带时钟
    }

    // 2. CMD0 = 复位到空闲状态
    SDIO_SendCmd(0, 0x00000000, SDIO_Response_Short, resp);
    Delay_ms(10);

    // 3. CMD8 = 检查 SDC v2+ 电压
    SDIO_SendCmd(8, 0x000001AA, SDIO_Response_Short, resp);
    if (resp[0] == 0x1AA) {  // 电压匹配
        // SDC v2+ 卡
    } else {
        return 1;
    }

    // 4. 发送 ACMD41（循环直到卡就绪）
    uint32_t retry = 0;
    do {
        SDIO_SendCmd(55, 0, SDIO_Response_Short, resp);  // CMD55
        SDIO_SendCmd(41, 0x40000000, SDIO_Response_Short, resp); // ACMD41
        Delay_ms(10);
        retry++;
    } while ((resp[0] & 0x80000000) == 0 && retry < 100);

    if (retry >= 100) return 2;

    // 5. CMD2 = 读 CID（卡标识）
    SDIO_SendCmd(2, 0, SDIO_Response_Long, resp);
    // resp 包含 16 字节 CID

    // 6. CMD3 = 获取 RCA（相对卡地址）
    SDIO_SendCmd(3, 0, SDIO_Response_Short, resp);
    uint16_t rca = (resp[0] >> 16) & 0xFFFF;

    // 7. CMD9 = 读 CSD
    SDIO_SendCmd(9, (uint32_t)rca << 16, SDIO_Response_Long, resp);

    // 从 resp[0..3] 提取容量（略——需要用 CSD 格式解析）

    return 0;
}
```

### 验证

```c
int main(void) {
    USART1_Init();
    uint8_t err = SD_Init();
    if (err) {
        printf("SD 卡初始化失败: %d\r\n", err);
    } else {
        printf("SD 卡初始化成功！\r\n");
    }
    while (1);
}
```

### SPI vs SDIO 对比

| | SPI 模式 | SDIO 原生模式 |
|--|---------|-------------|
| **接线** | SCK + MOSI + MISO + CS（4 线）| CLK + CMD + D0-D3（6 线）|
| **你的板子** | 需要额外接线到 SPI 引脚 | **直接可用**（PC8-PC12 + PD2）|
| **速度** | ~1MB/s | ~25MB/s（4 位模式）|
| **复杂度** | 简单，手动逐字节传 | 复杂，硬件状态机 |
| **外设** | 任何 SPI 都可以 | 仅限有 SDIO 的 MCU（F103 VET6/ZET6 有）|

你的板子 VET6/ZET6 带 SDIO 外设，所以原生 SDIO 是最合适的方式——速度快、不占用 SPI 总线、接线即用。但 SDIO 的学习曲线比 SPI 陡——上面的代码只是初始化部分，完整读写还要配数据通道（Data Path）、设置块长度、处理中断和 DMA。

> **如果你只想调试 SPI 本身**：板上的 **W25Q64 SPI Flash** 是更好的实验对象——它连在 SPI1（PA5/PA6/PA7）上，用普通 SPI 操作即可，而且内容更丰富（读 ID、擦除、读写数据）。SD 卡完整的 SDIO 数据读写会在第 12 章 DMA 和第 13 章 FatFs 中展开。


---

> **上一章**：[第 10 章 · I2C 总线](./10-chapter.md)
>
> **下一章**：[第 12 章 · DMA 控制器](./12-chapter.md)
>
> SPI 通信速度更快、全双工。但频繁传输会占 CPU——让 DMA 来干这个活。

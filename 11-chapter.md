# 第 11 章 · SPI 事务与 SDIO 卡初始化

这一章分两部分。先用 SPI1 做一条可靠的同步串行总线，重点处理 CPOL/CPHA、片选和超时；再看 STM32F103ZET6 的 SDIO 外设，理解 SD 卡从上电到进入传输状态需要经过哪些步骤。

SPI 和 SDIO 都能连接存储器，但接口和协议完全不同。SPI 是通用串行总线，SDIO 是 SD 卡专用主机接口。后面的 512 字节块传输、DMA 和文件系统分别放到第 12、13 章。

## 11.1 SPI1 的引脚和基本时序

SPI1 默认使用：

- PA5：SCK
- PA6：MISO
- PA7：MOSI
- CS：由板级接线决定，通常用普通 GPIO 控制

外部 Flash、显示屏或其他 SPI 从机的 CS 接在哪个引脚，要看原理图。本章通过 `StorageCs_Assert()` 和 `StorageCs_Deassert()` 隔离这部分板卡差异。

SPI 是全双工总线。主机每发送一个字节，也会同时收到一个字节；读取设备时仍要发送填充字节来提供时钟，常见填充值是 `0xFF`。SPI 本身没有 ACK，命令是否成功要通过设备返回的 ID、状态寄存器、CRC 或后续数据判断。

CPOL 和 CPHA 必须与从机手册一致。它们决定 SCK 空闲电平和采样边沿。设备工作在 Mode 0、Mode 3 或其他模式都很常见，不能因为某个 Flash 使用 Mode 0 就把它当成所有 SPI 设备的默认事实。

## 11.2 初始化 SPI1

先低速验证接线和模式，再根据器件规格提高时钟。下面假设 PCLK2 为 72 MHz，分频 `/256` 后 SPI 时钟约 281.25 kHz。

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_spi.h"

static void SPI1_InitSlow(void)
{
    GPIO_InitTypeDef gpio;
    SPI_InitTypeDef spi;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA |
                           RCC_APB2Periph_SPI1, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_5 | GPIO_Pin_7;
    gpio.GPIO_Mode = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOA, &gpio);

    gpio.GPIO_Pin = GPIO_Pin_6;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    SPI_I2S_DeInit(SPI1);
    SPI_StructInit(&spi);
    spi.SPI_Direction = SPI_Direction_2Lines_FullDuplex;
    spi.SPI_Mode = SPI_Mode_Master;
    spi.SPI_DataSize = SPI_DataSize_8b;
    spi.SPI_CPOL = SPI_CPOL_Low;
    spi.SPI_CPHA = SPI_CPHA_1Edge;
    spi.SPI_NSS = SPI_NSS_Soft;
    spi.SPI_BaudRatePrescaler = SPI_BaudRatePrescaler_256;
    spi.SPI_FirstBit = SPI_FirstBit_MSB;
    SPI_Init(SPI1, &spi);

    SPI_NSSInternalSoftwareConfig(SPI1, SPI_NSSInternalSoft_Set);
    SPI_Cmd(SPI1, ENABLE);
}
```

这里的 Mode 0 只是示例配置。换设备时要按手册重新确认 CPOL、CPHA、位序和最高 SCK 频率。

软件 NSS 模式下要把内部 NSS 保持为高，否则主机可能触发 MODF。外部设备的 CS 仍由普通 GPIO 单独控制。

## 11.3 单字节传输和事务结束

SPI 发送一个字节时，先等 TXE，再写数据；随后等 RXNE 并读走接收数据。片选释放前还要等 BSY 清零，因为 RXNE 只表示接收寄存器里有数据，不能证明最后一个时钟边沿已经结束。

```c
typedef enum {
    SPI1_OK = 0,
    SPI1_TIMEOUT_TXE,
    SPI1_TIMEOUT_RXNE,
    SPI1_TIMEOUT_BSY
} Spi1Result;

static bool Spi1_WaitFlag(uint16_t flag, FlagStatus wanted,
                          uint32_t timeout_ms)
{
    uint32_t start = Timebase_NowMs();

    while (SPI_I2S_GetFlagStatus(SPI1, flag) != wanted) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return false;
    }

    return true;
}

static Spi1Result Spi1_Transfer(uint8_t tx, uint8_t *rx)
{
    if (rx == NULL)
        return SPI1_TIMEOUT_RXNE;

    if (!Spi1_WaitFlag(SPI_I2S_FLAG_TXE, SET, 2U))
        return SPI1_TIMEOUT_TXE;

    SPI_I2S_SendData(SPI1, tx);

    if (!Spi1_WaitFlag(SPI_I2S_FLAG_RXNE, SET, 2U))
        return SPI1_TIMEOUT_RXNE;

    *rx = (uint8_t)SPI_I2S_ReceiveData(SPI1);
    return SPI1_OK;
}

static Spi1Result Spi1_EndTransaction(void)
{
    if (!Spi1_WaitFlag(SPI_I2S_FLAG_BSY, RESET, 2U))
        return SPI1_TIMEOUT_BSY;

    return SPI1_OK;
}
```

`2 ms` 是本章给轮询事务使用的策略值，不是 SPI 协议规定时间。寄存器访问本身通常远短于这个时间；这里主要保证故障状态下函数能返回。某个器件若规定了微秒级 CS 建立或保持时间，使用第 7 章的微秒计时器实现，不要靠空循环猜时间。

一次完整事务按这个顺序进行：

```text
CS 拉低
  ↓
发送命令 / 地址 / 数据
  ↓
读完最后一个 RXNE
  ↓
等待 BSY = 0
  ↓
CS 拉高
```

CS 拉高过早，最后一个字节可能还在移位寄存器里发送，设备看到的事务会被截断。

## 11.4 用 JEDEC ID 验证 SPI

许多 SPI NOR Flash 支持 `0x9F` JEDEC ID 命令。它适合验证 CS、SCK、MOSI、MISO 和模式是否基本正常，但具体返回值仍要和实际芯片手册核对。

```c
typedef struct {
    uint8_t manufacturer;
    uint8_t memory_type;
    uint8_t capacity_code;
} JedecId;

void StorageCs_Assert(void);
void StorageCs_Deassert(void);

static bool NorFlash_ReadJedecId(JedecId *id)
{
    uint8_t discard;

    if (id == NULL)
        return false;

    StorageCs_Assert();

    if (Spi1_Transfer(0x9FU, &discard) != SPI1_OK ||
        Spi1_Transfer(0xFFU, &id->manufacturer) != SPI1_OK ||
        Spi1_Transfer(0xFFU, &id->memory_type) != SPI1_OK ||
        Spi1_Transfer(0xFFU, &id->capacity_code) != SPI1_OK ||
        Spi1_EndTransaction() != SPI1_OK) {
        StorageCs_Deassert();
        return false;
    }

    StorageCs_Deassert();
    return true;
}
```

读到全 `0xFF` 时，常见原因是 CS 没有真正拉低、MISO 悬空或设备没供电。读到全 `0x00` 时，要检查 MISO 是否被拉低、SPI 模式是否错误，以及是否有另一个从设备同时驱动 MISO。

WP#、HOLD# 等额外引脚也要按芯片手册处理。它们如果悬空或处于错误电平，SPI 波形正常也可能得不到预期响应。

## 11.5 多个从设备共用 SPI

一组 SPI1 只能同时进行一个事务。多个设备可以共享 SCK、MOSI、MISO，但每个设备要有独立 CS，并保证空闲时所有 CS 都为高。

裸机阶段可以把 SPI 操作集中在一个服务层里。中断里不要直接访问 SPI，也不要在 ISR 中等 BSY；ISR 只记录事件，主循环再执行事务。这样能避免一个设备的事务执行到一半时被另一个上下文拉低其他 CS。

如果两个设备需要不同 CPOL/CPHA 或时钟，在拉低对应 CS 前重新配置 SPI，完成事务后再释放总线。模式切换本身也属于总线状态的一部分，不能让两个驱动各自无约束地改 SPI1 配置。

## 11.6 SD 卡可以走 SPI，也可以走 SDIO

SD 卡支持 SPI 模式，也可以通过 STM32F103ZET6 的 SDIO 外设工作。本书这一节讲原生 SDIO，因为它和前面的通用 SPI 是两套独立硬件和状态机。

ZET6 默认 SDIO 引脚为：

- PC8：D0
- PC9：D1
- PC10：D2
- PC11：D3
- PC12：CK
- PD2：CMD

1 位模式只使用 D0、CK、CMD，4 位模式再加入 D1–D3。开发板是否真的把卡槽接到这些引脚，以及卡检测、供电开关、CMD/DAT 上拉怎么连接，都要看原理图。

SDIO 时钟来自 AHB 侧的 SDIO 外设时钟。不要把它当成 APB1 外设。

## 11.7 初始化阶段先保持低速

SD 卡识别阶段的 SD 时钟不能直接拉到工作频率。本章按 `SDIO_CK = SDIOCLK / (ClockDiv + 2)` 计算；若 SDIOCLK 为 72 MHz，`ClockDiv = 178` 得到 400 kHz。

```c
#define SDIO_IDENT_CLOCK_DIV  178U

static void Sdio_ApplyBus(uint8_t clock_div, uint32_t bus_width)
{
    SDIO_InitTypeDef sdio;

    SDIO_ClockCmd(DISABLE);
    SDIO_StructInit(&sdio);
    sdio.SDIO_ClockEdge = SDIO_ClockEdge_Rising;
    sdio.SDIO_ClockBypass = SDIO_ClockBypass_Disable;
    sdio.SDIO_ClockPowerSave = SDIO_ClockPowerSave_Disable;
    sdio.SDIO_BusWide = bus_width;
    sdio.SDIO_HardwareFlowControl = SDIO_HardwareFlowControl_Disable;
    sdio.SDIO_ClockDiv = clock_div;
    SDIO_Init(&sdio);
    SDIO_ClockCmd(ENABLE);
}

static void Sdio_PeripheralInitForIdentification(void)
{
    GPIO_InitTypeDef gpio;

    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_SDIO, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC |
                           RCC_APB2Periph_GPIOD, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_8 | GPIO_Pin_12;
    gpio.GPIO_Mode = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOC, &gpio);

    gpio.GPIO_Pin = GPIO_Pin_2;
    GPIO_Init(GPIOD, &gpio);

    SDIO_SetPowerState(SDIO_PowerState_ON);
    Sdio_ApplyBus(SDIO_IDENT_CLOCK_DIV, SDIO_BusWide_1b);
}
```

这里先配置 1 位模式。识别成功后，再根据卡能力和实际 D1–D3 连线决定是否切 4 位模式。

## 11.8 SDIO 命令要区分响应类型

SD 命令的响应长度不同。CMD0 没有响应，CMD2/CMD9 使用长响应，CMD8、CMD3 等使用短响应。驱动接口应该把这些情况区分开，避免用一个通用函数隐藏响应长度和 CRC 规则。

下面的函数只处理短响应命令：

```c
typedef enum {
    SD_CMD_OK = 0,
    SD_CMD_TIMEOUT,
    SD_CMD_CRC_ERROR,
    SD_CMD_WRONG_INDEX,
    SD_CMD_ARGUMENT_ERROR
} SdCmdResult;

static SdCmdResult Sdio_SendShortCommand(uint8_t index,
                                         uint32_t argument,
                                         uint32_t *response,
                                         uint32_t timeout_ms)
{
    SDIO_CmdInitTypeDef cmd;
    uint32_t start;

    if (response == NULL)
        return SD_CMD_ARGUMENT_ERROR;

    SDIO_ClearFlag(SDIO_FLAG_CCRCFAIL |
                   SDIO_FLAG_CMDREND |
                   SDIO_FLAG_CTIMEOUT);

    SDIO_CmdStructInit(&cmd);
    cmd.SDIO_Argument = argument;
    cmd.SDIO_CmdIndex = index;
    cmd.SDIO_Response = SDIO_Response_Short;
    cmd.SDIO_Wait = SDIO_Wait_No;
    cmd.SDIO_CPSM = SDIO_CPSM_Enable;
    SDIO_SendCommand(&cmd);

    start = Timebase_NowMs();
    while (SDIO_GetFlagStatus(SDIO_FLAG_CMDREND) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CTIMEOUT) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CCRCFAIL) == RESET) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return SD_CMD_TIMEOUT;
    }

    if (SDIO_GetFlagStatus(SDIO_FLAG_CTIMEOUT) != RESET) {
        SDIO_ClearFlag(SDIO_FLAG_CTIMEOUT);
        return SD_CMD_TIMEOUT;
    }

    if (SDIO_GetFlagStatus(SDIO_FLAG_CCRCFAIL) != RESET) {
        SDIO_ClearFlag(SDIO_FLAG_CCRCFAIL);
        return SD_CMD_CRC_ERROR;
    }

    if (SDIO_GetCommandResponse() != index) {
        SDIO_ClearFlag(SDIO_FLAG_CMDREND);
        return SD_CMD_WRONG_INDEX;
    }

    *response = SDIO_GetResponse(SDIO_RESP1);
    SDIO_ClearFlag(SDIO_FLAG_CMDREND);
    return SD_CMD_OK;
}
```

这个函数不负责解释 R1、R6 或 R7 里的具体字段。调用状态机还要根据命令类型检查返回内容。例如 CMD8 要验证电压范围和检查模式，ACMD41 要检查 OCR 的 ready 位。

## 11.9 SD 卡初始化顺序

SD 卡上电后要经过一组状态转换，不能直接开始读 512 字节扇区。

常见初始化顺序如下：

1. **CMD0**：让卡进入 idle。
2. **CMD8**：探测 v2 卡并检查接口电压；旧卡可能不支持，需要分支处理。
3. **CMD55 + ACMD41**：循环询问卡是否完成上电初始化，整个过程必须有总超时。
4. **CMD2**：读取 CID，返回长响应。
5. **CMD3**：取得 RCA。
6. **CMD9**：读取 CSD，确认容量、寻址类型等能力。
7. **CMD7**：选择卡并进入 transfer 状态。
8. 如果卡和板卡都支持，再通过 **CMD55 + ACMD6** 切换 4 位总线。

SDSC 和 SDHC/SDXC 的数据地址含义不同。SDSC 的读写命令通常使用字节地址；SDHC/SDXC 使用 512 字节块号。块设备层必须保存卡类型，不能对所有卡都无条件做 `sector * 512`。

CMD16 也要按卡类型处理。SDHC/SDXC 的块长度固定为 512 字节；SDSC 流程中才可能需要设置块长度。

识别完成后才能提高 SDIO 时钟。每次修改总线宽度或时钟后，先读取已知扇区并检查返回状态和数据，再进入 DMA 和文件系统。

## 11.10 验证和排错

SPI 先验证设备 ID。逻辑分析仪上应该能看到 CS 拉低、`0x9F` 命令、连续时钟和三个返回字节；最后一个时钟结束后 CS 才拉高。若两个从设备共用 SPI1，还要确认任何时刻只有一个 CS 为低。

SDIO 初始化时把每一步命令、返回状态和关键响应打印到 UART。CMD0 都超时时，先检查卡槽供电、PC8/PC12/PD2 是否真的连到卡、SDIO AHB 时钟和引脚配置；不要直接跳到 FatFs 排错。

初始化成功但扇区位置不对时，首先检查卡类型和地址单位。SDSC 与 SDHC/SDXC 的寻址差异会直接导致读写位置错误。

## 11.11 练习

1. 给 SPI 设备定义一个配置结构，保存 CPOL、CPHA、最大 SCK 和 CS 操作，在每次事务前应用对应配置。
2. 连续读取三次 JEDEC ID，要求三次结果一致；不一致时记录 SPI 错误和原始返回字节。
3. 用逻辑分析仪抓一次完整 SPI 事务，标出 CS、SCK、MOSI、MISO 和最后一个字节结束的位置。
4. 把 SDIO 初始化写成明确的枚举状态机，为 CMD8、ACMD41、CMD2、CMD3、CMD9、CMD7 分别保留错误码和超时。
5. 识别一张 SDSC 和一张 SDHC/SDXC 卡时，记录容量类型和读扇区命令的参数差异。

完成本章后，SPI 层已经有明确的事务边界和总线所有权，SDIO 层也已经能把卡带到 transfer 状态。下一章再处理 512 字节数据通道和 DMA。

> **上一章**：[第 10 章 · I2C](./10-chapter.md)
>
> **下一章**：[第 12 章 · DMA](./12-chapter.md)

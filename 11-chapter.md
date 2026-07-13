# 第 11 章 · SPI 事务与 SDIO 卡初始化

> **本章产出**：能把 SPI 的一次事务写成“片选—传输—确认总线空闲—释放片选”的受限操作；能区分 SPI 与原生 SDIO，并能解释 SD 卡从上电到可读写所经过的状态。
>
> **前置知识**：第 3 章 GPIO、第 5 章时钟、第 8 章串口、第 10 章 I2C 的超时与恢复思路。
>
> **本章边界**：本章实现 SPI 的可靠基础层，并讲清 SDIO 的初始化状态机。512 字节块传输与 DMA 放到第 12 章；文件系统放到第 13 章。

SPI 与 SDIO 经常被一起称为“接存储器的接口”，但它们不是同一件事。SPI 是一个通用的同步串行总线；SDIO 是 SD 卡协议的专用主机控制器。把两者混成一段代码，出了问题时会不知道应检查时序、命令状态，还是文件系统。

## 11.1 先确认实际资源

本书固定 MCU 为 STM32F103ZET6。它的 SPI1 默认引脚是固定的：

| SPI1 信号 | MCU 默认引脚 | 方向（主机） | 说明 |
|---|---:|---|---|
| SCK | PA5 | 输出 | 时钟 |
| MISO | PA6 | 输入 | 从机输出、主机输入 |
| MOSI | PA7 | 输出 | 主机输出、从机输入 |
| CS/NSS | **由板级连线决定** | GPIO 输出 | 每个从设备各有一个，不能从 MCU 型号推导 |

板上是否装有 W25Q、其片选在哪个 GPIO、SD 卡槽是否接到 SDIO，都属于板级事实。先在 [ZET6 板卡资源档案](board-zet6-profile.md) 中填写原理图或万用表确认的结果；本章的 `StorageCs_*()`、`Board_HasSdioSocket()` 都是你应在 `board.h` 或板级模块中实现的接口，而不是默认某个 PB 引脚。

### 11.1.1 SPI 的最小电气模型

```text
主机                               从机
SCK   ----------------------------> CLK
MOSI  ----------------------------> DI / SI
MISO  <---------------------------- DO / SO
CS#   ----------------------------> CS#
GND   ----------------------------- GND
```

SPI 没有统一的“命令成功”信号。主机每发送一个字节，同时也会接收一个字节；读数据时仍必须发送填充字节（常见 `0xFF`）来产生时钟。是否应答、命令长度、地址宽度、忙状态，全由具体从设备的数据手册定义。

| 概念 | 你要回答的问题 |
|---|---|
| CPOL/CPHA | 空闲时 SCK 是高还是低？数据在哪个边沿采样？ |
| 位序 | MSB 先还是 LSB 先？ |
| 最大频率 | 该器件在当前电压、走线和模式下允许多快？ |
| CS 时序 | CS 拉低后多久可发命令？最后一位后何时可拉高？ |
| 软件应答 | 读 ID、状态寄存器或 CRC 后，什么值说明命令可信？ |

不要把“Mode 0 最常见”理解为“可以不看手册”。例如 NOR Flash 常见 Mode 0，某些传感器可能要求 Mode 3；错误的模式通常只会读到稳定的错误值，看起来比完全断线更像“软件偶发 bug”。

## 11.2 把 SPI 写成事务，而不是裸 `Transfer`

一段能跑的 `SPI_Transfer()` 还不是可复用驱动。它至少应保证：

1. 等待发送寄存器可写；
2. 等待本字节的接收数据到达，再读出它；
3. 在释放 CS 前等待 `BSY=0`，避免最后一位仍在 SCK 上移动；
4. 每一个等待都有上限；
5. 一次失败后由上层决定复位 SPI、重新识别设备或报错，不能永久卡在 `while` 中。

下面的代码假设第 5 章已经提供 `Timebase_NowMs()`。这里的超时单位是毫秒，适合初始化、读 ID、普通寄存器操作；若器件规定了微秒级 CS 建立/保持时间，应使用第 7 章的定时器微秒接口补足，而不是拿空循环凑延时。

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "stm32f10x_spi.h"
#include "timebase.h"

typedef enum {
    SPI1_OK = 0,
    SPI1_TIMEOUT_TXE,
    SPI1_TIMEOUT_RXNE,
    SPI1_TIMEOUT_BSY
} Spi1Result;

static bool Spi1_WaitFlag(uint16_t flag, FlagStatus wanted,
                          uint32_t timeout_ms)
{
    const uint32_t start = Timebase_NowMs();

    while (SPI_I2S_GetFlagStatus(SPI1, flag) != wanted) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms) {
            return false;
        }
    }
    return true;
}

static Spi1Result Spi1_Transfer(uint8_t tx, uint8_t *rx)
{
    if (!Spi1_WaitFlag(SPI_I2S_FLAG_TXE, SET, 2U)) {
        return SPI1_TIMEOUT_TXE;
    }

    SPI_I2S_SendData(SPI1, tx);

    if (!Spi1_WaitFlag(SPI_I2S_FLAG_RXNE, SET, 2U)) {
        return SPI1_TIMEOUT_RXNE;
    }

    *rx = (uint8_t)SPI_I2S_ReceiveData(SPI1);
    return SPI1_OK;
}

static Spi1Result Spi1_EndTransaction(void)
{
    return Spi1_WaitFlag(SPI_I2S_FLAG_BSY, RESET, 2U)
         ? SPI1_OK : SPI1_TIMEOUT_BSY;
}
```

`RXNE` 表示接收寄存器已有数据，不等价于“最后一位已经安全离开引脚”。因此片选的正确顺序是：读走所有 `RXNE` 数据，等待 `BSY` 清零，再拉高 CS。

### 11.2.1 慢速、安全的 SPI1 初始化

先用低速读设备 ID，确认电气和模式正确后，再根据具体器件手册提高分频。72 MHz 的 PCLK2 下 `/256` 约为 281 kHz，适合作为保守起点；它不是所有设备最终都应使用的频率。

```c
void SPI1_InitSlow(void)
{
    GPIO_InitTypeDef gpio;
    SPI_InitTypeDef  spi;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA |
                           RCC_APB2Periph_SPI1, ENABLE);

    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Pin   = GPIO_Pin_5 | GPIO_Pin_7;   // SCK, MOSI
    GPIO_Init(GPIOA, &gpio);

    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    gpio.GPIO_Pin  = GPIO_Pin_6;                 // MISO
    GPIO_Init(GPIOA, &gpio);

    SPI_I2S_DeInit(SPI1);
    SPI_StructInit(&spi);
    spi.SPI_Direction         = SPI_Direction_2Lines_FullDuplex;
    spi.SPI_Mode              = SPI_Mode_Master;
    spi.SPI_DataSize          = SPI_DataSize_8b;
    spi.SPI_CPOL              = SPI_CPOL_Low;    // Mode 0：由设备手册确认
    spi.SPI_CPHA              = SPI_CPHA_1Edge;
    spi.SPI_NSS               = SPI_NSS_Soft;
    spi.SPI_BaudRatePrescaler = SPI_BaudRatePrescaler_256;
    spi.SPI_FirstBit          = SPI_FirstBit_MSB;
    SPI_Init(SPI1, &spi);

    /* 软件 NSS 必须置为内部高电平，否则主机可能触发 MODF。 */
    SPI_NSSInternalSoftwareConfig(SPI1, SPI_NSSInternalSoft_Set);
    SPI_Cmd(SPI1, ENABLE);
}
```

### 11.2.2 以 JEDEC ID 为例的完整事务

下面只把 `0x9F` 当作“某个兼容 JEDEC 的 NOR Flash 的识别命令”。返回的三字节是什么，必须与实物数据手册和你读到的容量一致；不要把某个厂商 ID 写进逻辑判断后就默认板上一定是 W25Q64。

```c
typedef struct {
    uint8_t manufacturer;
    uint8_t memory_type;
    uint8_t capacity_code;
} JedecId;

/* 由 board.c 实现：仅操作该存储芯片的 CS，且空闲时为高。 */
void StorageCs_Assert(void);
void StorageCs_Deassert(void);

bool NorFlash_ReadJedecId(JedecId *id)
{
    uint8_t discard;

    if (id == NULL) {
        return false;
    }

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

若这里超时或 ID 全为 `0x00`/`0xFF`，先停止提高频率和继续写 Flash。按这个顺序检查更快：CS 是否真的连到该芯片；GND 是否共地；WP#/HOLD# 是否被拉到有效电平；示波器或逻辑分析仪上是否有 CS、SCK、MOSI；CPOL/CPHA 是否匹配；MISO 是否被另一个从设备同时驱动。

### 11.2.3 谁拥有总线

SPI1 只有一组 SCK/MOSI/MISO。若外部 Flash、显示屏、ADC 同挂 SPI1，任意时刻只能有一个“事务拥有者”。最简单的裸机规则是：

- 主循环中的一个存储服务函数是唯一调用 `StorageCs_*()` 的地方；
- 中断里不发 SPI 命令、不等待 `BSY`；中断只投递事件；
- 每个从设备有自己的 CS，空闲时所有 CS 都为高；
- 出错时先释放当前 CS，再重置/重新初始化 SPI，不能把半个命令接到下一个设备。

这和第 8 章“UART ISR 只收字节、主循环解析”的边界是同一种思想：把有等待、会失败、需要资源所有权的工作放在一个可观察的上下文中。

## 11.3 SD 卡的两条路线：SPI 模式与原生 SDIO

SD 卡可以工作在 SPI 模式，也可以使用 STM32 的 SDIO 外设。两条路线不能把初始化代码混用。

| 路线 | 优点 | 代价 | 适用条件 |
|---|---|---|---|
| SPI 模式 | 可复用本章 SPI 层，协议相对直观 | 吞吐较低，仍需实现 SD 命令 | 卡槽确实接在 SPI 引脚，或你自己转接 |
| 原生 SDIO | 有专用命令、响应、CRC、数据通道 | 状态机和错误分支更多 | 原理图确认卡槽接 PC8–PC12、PD2 |

本节讨论原生 SDIO。它不是“SPI 快一点”，而是另一组寄存器和命令状态机。

### 11.3.1 原生 SDIO 的引脚与前提

| SDIO 信号 | F103ZET6 默认引脚 | 1 位模式是否需要 | 4 位模式是否需要 |
|---|---:|---:|---:|
| D0 | PC8 | 是 | 是 |
| D1 | PC9 | 否 | 是 |
| D2 | PC10 | 否 | 是 |
| D3 | PC11 | 否 | 是 |
| CK | PC12 | 是 | 是 |
| CMD | PD2 | 是 | 是 |

卡槽、卡检测、供电开关、CMD/DAT 上拉的实际连接由原理图决定。没有确认这些连线前，不应仅因为 MCU 有 SDIO 外设就宣称“板载 SDIO 可用”。SD 规范还要求上电与命令线具备合适的上拉和电平；这不是 GPIO 配成复用推挽就能替代的。

### 11.3.2 初始化阶段必须不超过 400 kHz

在 F103 的 SDIO 时钟公式中，识别阶段可按 `SDIO_CK = SDIOCLK / (ClockDiv + 2)` 理解。若 `SDIOCLK=72 MHz`，设 `ClockDiv=178` 正好得到 400 kHz。不要像普通 SPI 一样一上电就以十几 MHz 发 CMD0。

```c
#define SDIO_IDENT_CLOCK_DIV  178U  /* 72 MHz / (178 + 2) = 400 kHz */

static void Sdio_ApplyBus(uint8_t clock_div, uint32_t bus_width)
{
    SDIO_InitTypeDef sdio;

    SDIO_ClockCmd(DISABLE);
    SDIO_StructInit(&sdio);
    sdio.SDIO_ClockEdge           = SDIO_ClockEdge_Rising;
    sdio.SDIO_ClockBypass         = SDIO_ClockBypass_Disable;
    sdio.SDIO_ClockPowerSave      = SDIO_ClockPowerSave_Disable;
    sdio.SDIO_BusWide             = bus_width;
    sdio.SDIO_HardwareFlowControl = SDIO_HardwareFlowControl_Disable;
    sdio.SDIO_ClockDiv            = clock_div;
    SDIO_Init(&sdio);
    SDIO_ClockCmd(ENABLE);
}

void Sdio_PeripheralInitForIdentification(void)
{
    GPIO_InitTypeDef gpio;

    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_SDIO, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC |
                           RCC_APB2Periph_GPIOD, ENABLE);

    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Pin   = GPIO_Pin_8 | GPIO_Pin_12;  /* D0, CK：先用 1 位 */
    GPIO_Init(GPIOC, &gpio);
    gpio.GPIO_Pin = GPIO_Pin_2;                  /* CMD */
    GPIO_Init(GPIOD, &gpio);

    SDIO_SetPowerState(SDIO_PowerState_ON);
    Sdio_ApplyBus(SDIO_IDENT_CLOCK_DIV, SDIO_BusWide_1b);
}
```

注意 SDIO 的时钟在 **AHB**，不是 APB1。把它写成 `RCC_APB1PeriphClockCmd(...SDIO...)` 是很常见、也很隐蔽的错误。

### 11.3.3 命令函数先定义“哪一种响应”

不能写一个 `SDIO_SendCmd(..., uint32_t *resp)` 然后在调用方传 `NULL`。CMD0 没有响应，CMD2/CMD9 有长响应，CMD3/CMD8/R1 类型是短响应；这些情形的完成标志、响应寄存器数目和可接受的 CRC 行为不同。

下面的函数故意只负责**短响应命令**，因而其接口明确且可测试。CMD0 和长响应命令由各自的小函数处理。

```c
typedef enum {
    SD_CMD_OK = 0,
    SD_CMD_TIMEOUT,
    SD_CMD_CRC_ERROR,
    SD_CMD_WRONG_INDEX,
    SD_CMD_ARGUMENT_ERROR
} SdCmdResult;

static SdCmdResult Sdio_SendShortCommand(uint8_t index, uint32_t argument,
                                         uint32_t *response,
                                         uint32_t timeout_ms)
{
    SDIO_CmdInitTypeDef cmd;
    const uint32_t start = Timebase_NowMs();

    if (response == NULL) {
        return SD_CMD_ARGUMENT_ERROR;
    }

    SDIO_ClearFlag(SDIO_FLAG_CCRCFAIL | SDIO_FLAG_CMDREND |
                   SDIO_FLAG_CTIMEOUT);
    SDIO_CmdStructInit(&cmd);
    cmd.SDIO_Argument = argument;
    cmd.SDIO_CmdIndex = index;
    cmd.SDIO_Response = SDIO_Response_Short;
    cmd.SDIO_Wait     = SDIO_Wait_No;
    cmd.SDIO_CPSM     = SDIO_CPSM_Enable;
    SDIO_SendCommand(&cmd);

    while (SDIO_GetFlagStatus(SDIO_FLAG_CMDREND) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CTIMEOUT) == RESET &&
           SDIO_GetFlagStatus(SDIO_FLAG_CCRCFAIL) == RESET) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms) {
            return SD_CMD_TIMEOUT;
        }
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

该函数也不是“完整 SD 驱动”。例如 CMD8 的合法 R7 响应、旧卡对 CMD8 的超时、ACMD41 的轮询次数、R1 中的错误位，都必须在卡状态机中分别解释，不能被一个 `0/1` 返回值吞掉。

## 11.4 SDIO 初始化是一台状态机

建议先在串口上逐步打印状态与响应，再实现读块。以下是应有的状态，而不是可以跳过的命令清单：

| 阶段 | 代表命令 | 关键判断 |
|---|---|---|
| 空闲 | CMD0 | 无响应完成，卡进入 idle |
| 版本探测 | CMD8 | R7 正确则可按 v2 流程；超时可能是旧卡，需要单独处理 |
| 反复初始化 | CMD55 + ACMD41 | 在总超时内轮询 OCR 的 ready 位；不能无限重试 |
| 取得身份 | CMD2、CMD3 | 保存 CID 和 RCA；CMD2 是长响应，CMD3 返回 RCA |
| 读取能力 | CMD9 | 解析 CSD，得到容量、寻址类型和可用传输速率 |
| 选择卡 | CMD7 | 进入 transfer 状态 |
| 可选 4 位 | CMD55 + ACMD6 | 仅在卡、插座和 D1–D3 连线均确认时切换 |
| 块长度 | CMD16 | **仅 SDSC** 可能需要；SDHC/SDXC 固定 512 字节，不能照抄 |

容量类型直接影响数据命令参数：SDSC 常使用字节地址，SDHC/SDXC 使用 512 字节块号。若把 `sector * 512` 无条件传给所有卡，可能在一张卡上“看似能初始化”、读写却落到错误地址。

完成这台状态机后，才在 CSD、卡能力和板级信号质量允许的范围内提高时钟；再用 ACMD6 切换 4 位模式。每次改变总线宽度或时钟后都先读一个已知扇区并验证 CRC/内容，不能只以“命令未超时”为成功标准。

## 11.5 验收、诊断与练习

### 最小验收顺序

1. SPI1 在低速下读到稳定、合理的设备 ID；断开 MISO 或 CS 时能报错而不是死循环。
2. 同一条 SPI 总线上交替访问两个从设备，确认没有两个 CS 同时为低。
3. SDIO 在 400 kHz 下完成 CMD0、CMD8（或明确识别旧卡）、ACMD41；串口输出每一步的结果。
4. 拔出 SD 卡或让初始化超时，程序仍能回到主循环并报告“无卡/初始化失败”。
5. 完成块读以后，再进入第 12 章给数据通道接 DMA；最后才让第 13 章的 FatFs 使用这个块设备。

| 现象 | 优先检查 |
|---|---|
| SPI 读到全 `0xFF` | MISO 上拉/悬空、CS 未真正拉低、从设备未供电 |
| SPI 读到全 `0x00` | MISO 被拉低、模式错误、两从设备争用 MISO |
| 偶发最后一个字节错误 | CS 在 `BSY=1` 时释放，或逻辑分析仪显示时序未满足 |
| SDIO CMD0 都超时 | 卡槽电源、CMD/CLK/D0 走线、SDIO AHB 时钟、引脚是否真接 SDIO |
| SDIO 初始化后读错地址 | 没区分 SDSC 字节地址和 SDHC 块地址 |

### 练习

1. 给 SPI 事务层增加一个“设备模式”结构体，使不同从设备能分别选择 CPOL/CPHA 和最高时钟。
2. 为 `NorFlash_ReadJedecId()` 写一个失败策略：连续三次不一致时禁用存储服务并保留诊断码。
3. 把 SDIO 初始化状态画成枚举和转换表；为每个状态定义最长等待时间与串口诊断文本。
4. 在逻辑分析仪中抓取一次 SPI 读 ID，标出 CS、命令、三个返回字节和 `BSY` 对应的最后一个时钟。

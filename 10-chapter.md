# 第 10 章 · I2C：有状态、有超时、可恢复的两线总线（SPL 版）

> **本章产出**：以 I2C1/PB6/PB7 建立一条 100kHz 外接总线；用带超时与错误码的写事务验证 ACK；理解 F1 BUSY 勘误恢复和 OLED 帧缓冲的必要性。
>
> **前置知识**：第 3 章开漏、第 5 章时钟、第 8 章 UART 日志。
>
> **硬件前提**：SCL/SDA 均需上拉到安全的 3.3V 电平并共地。PB6/PB7 是外接默认映射，不代表所有板载 I2C 器件都接在这里。

---

## 10.1 I2C 的物理层与地址边界

I2C 的 SCL、SDA 都是开漏“线与”总线：任一设备只能主动拉低，释放后由上拉电阻变高。因此第一件事不是 `I2C_Init()`，而是断电检查上拉/电平、上电后测两根线在空闲时都为高。

```text
3.3V ── Rp ── SCL ── MCU / 从机 A / 从机 B
3.3V ── Rp ── SDA ── MCU / 从机 A / 从机 B
GND  ───────────────── 共地
```

地址要分清：数据手册常写 7 位地址 `0x3C`；SPL 的 `I2C_Send7bitAddress()` 参数是左移过的地址字节，因此传 `addr7 << 1`，不要再把读写位手工 OR 进去。

| 写法 | 含义 |
|---|---|
| `0x3C` | 7 位设备地址（例：某些 SSD1306 模块） |
| `0x3C << 1` | 传给 SPL 发送函数的地址字段 |
| `0x78/0x79` | 线上写/读地址字节；不应同时作为“7 位地址”存储 |

`0x3C`、`0x50`、`0x68` 只是在不同模块上常见，不是 ZET6 开发板的保证。先查模块数据手册/原理图，再用单一从机做 ACK 验证。

## 10.2 初始化：从 100kHz 开始

400kHz 不是“更高级的默认”。上拉阻值、线长、电容、从机支持和 F1 勘误都影响可靠性；先稳定跑 100kHz，再逐项测量升级。

```c
#include <stdbool.h>
#include "stm32f10x_gpio.h"
#include "stm32f10x_i2c.h"
#include "stm32f10x_rcc.h"

static void I2C1_Apply100kHzConfig(void)
{
    I2C_InitTypeDef i2c;
    I2C_StructInit(&i2c);
    i2c.I2C_Mode = I2C_Mode_I2C;
    i2c.I2C_DutyCycle = I2C_DutyCycle_2;
    i2c.I2C_OwnAddress1 = 0U;           /* 单主机主模式仍填一个合法值。 */
    i2c.I2C_Ack = I2C_Ack_Enable;
    i2c.I2C_AcknowledgedAddress = I2C_AcknowledgedAddress_7bit;
    i2c.I2C_ClockSpeed = 100000U;
    I2C_Init(I2C1, &i2c);
    I2C_Cmd(I2C1, ENABLE);
}

static void I2C1_Init(void)
{
    GPIO_InitTypeDef gpio;
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_I2C1, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_6 | GPIO_Pin_7;
    gpio.GPIO_Mode = GPIO_Mode_AF_OD;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);
    I2C1_Apply100kHzConfig();
}
```

`I2C_Init()` 用当前 PCLK1 计算时序；因此必须在第 5 章时钟稳定、`SystemCoreClockUpdate()` 后执行。时钟切换后重新初始化 I2C，而不是继续使用旧分频。

## 10.3 把等待变成可返回的结果

裸 `while (!I2C_CheckEvent(...));` 会在断线、NACK、BUSY 或异常 STOP 时永久卡死。先定义可传播的错误：

```c
typedef enum {
    I2C_OK,
    I2C_TIMEOUT,
    I2C_NACK,
    I2C_BUS_ERROR,
    I2C_ARBITRATION_LOST
} I2C_Result;

static I2C_Result I2C1_ReadAndClearError(void)
{
    uint16_t sr1 = I2C1->SR1;
    if ((sr1 & I2C_SR1_AF) != 0U) {
        I2C1->SR1 &= (uint16_t)~I2C_SR1_AF;
        return I2C_NACK;
    }
    if ((sr1 & (I2C_SR1_BERR | I2C_SR1_OVR)) != 0U) {
        I2C1->SR1 &= (uint16_t)~(I2C_SR1_BERR | I2C_SR1_OVR);
        return I2C_BUS_ERROR;
    }
    if ((sr1 & I2C_SR1_ARLO) != 0U) {
        I2C1->SR1 &= (uint16_t)~I2C_SR1_ARLO;
        return I2C_ARBITRATION_LOST;
    }
    return I2C_OK;
}

static I2C_Result I2C1_WaitEvent(uint32_t event, uint32_t timeout_ms)
{
    const uint32_t start = Timebase_NowMs();
    while (I2C_CheckEvent(I2C1, event) == ERROR) {
        I2C_Result error = I2C1_ReadAndClearError();
        if (error != I2C_OK)
            return error;
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return I2C_TIMEOUT;
    }
    return I2C_OK;
}

static I2C_Result I2C1_WaitBusFree(uint32_t timeout_ms)
{
    const uint32_t start = Timebase_NowMs();
    while (I2C_GetFlagStatus(I2C1, I2C_FLAG_BUSY) != RESET) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return I2C_TIMEOUT;
    }
    return I2C_OK;
}
```

下一层的接口接收**7 位地址**和缓冲区，而不是把 OLED/EEPROM 的地址/控制字节写死在总线驱动里：

```c
static I2C_Result I2C1_MasterWrite7(uint8_t addr7,
                                    const uint8_t *data, uint16_t len)
{
    I2C_Result r;
    if (data == NULL || len == 0U)
        return I2C_BUS_ERROR;

    if ((r = I2C1_WaitBusFree(20U)) != I2C_OK)
        return r;

    I2C_GenerateSTART(I2C1, ENABLE);
    if ((r = I2C1_WaitEvent(I2C_EVENT_MASTER_MODE_SELECT, 20U)) != I2C_OK)
        goto abort;

    I2C_Send7bitAddress(I2C1, (uint8_t)(addr7 << 1),
                         I2C_Direction_Transmitter);
    if ((r = I2C1_WaitEvent(I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED, 20U)) != I2C_OK)
        goto abort;

    while (len-- != 0U) {
        I2C_SendData(I2C1, *data++);
        if ((r = I2C1_WaitEvent(I2C_EVENT_MASTER_BYTE_TRANSMITTED, 20U)) != I2C_OK)
            goto abort;
    }
    I2C_GenerateSTOP(I2C1, ENABLE);
    return I2C_OK;

abort:
    I2C_GenerateSTOP(I2C1, ENABLE);
    return r;
}
```

这是一个轮询、单主机、写事务的教学基础，不是完整 I2C 框架。对“读 1/2/N 字节”，F1 的 ACK、ADDR、BTF、STOP 顺序不同，且该系列有接收相关勘误；应在一个专门的读状态机中按 RM0008 和勘误表处理，而不是把“写事务”复制后把方向改为 Receiver。

## 10.4 F1 BUSY 锁死：区分两种恢复

如果 SDA/SCL 物理上都高，而 `I2C_FLAG_BUSY` 仍在复位后重新置位，可能是 F103 的模拟滤波器勘误。ST 的 [ES0340 2.9.7](https://www.st.com/resource/en/errata_sheet/es0340-stm32f101xcde-stm32f103xcde-device-errata-stmicroelectronics.pdf) 要求通过 GPIO 开漏强制**指定的电平转换序列**，随后 SWRST；它不是泛用“发九个时钟”。

```c
static bool I2C1_RecoverBusyErrata(void)
{
    GPIO_InitTypeDef gpio;

    I2C_Cmd(I2C1, DISABLE);                         /* 1 */
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_6 | GPIO_Pin_7;
    gpio.GPIO_Mode = GPIO_Mode_Out_OD;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_SetBits(GPIOB, GPIO_Pin_6 | GPIO_Pin_7);   /* 2: 两线高 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) == Bit_RESET ||
        GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) == Bit_RESET)
        goto failed;                                 /* 3: 外部仍拉低，不能强行继续 */

    GPIO_ResetBits(GPIOB, GPIO_Pin_7);               /* 4: SDA 低 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) != Bit_RESET) goto failed;
    GPIO_ResetBits(GPIOB, GPIO_Pin_6);               /* 6: SCL 低 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) != Bit_RESET) goto failed;
    GPIO_SetBits(GPIOB, GPIO_Pin_6);                 /* 8: SCL 高 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) != Bit_SET) goto failed;
    GPIO_SetBits(GPIOB, GPIO_Pin_7);                 /* 10: SDA 高 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) != Bit_SET) goto failed;

    gpio.GPIO_Mode = GPIO_Mode_AF_OD;                /* 12 */
    GPIO_Init(GPIOB, &gpio);
    I2C_SoftwareResetCmd(I2C1, ENABLE);              /* 13 */
    I2C_SoftwareResetCmd(I2C1, DISABLE);             /* 14 */
    I2C1_Apply100kHzConfig();                        /* 15: 重新写时序并使能 */
    return I2C_GetFlagStatus(I2C1, I2C_FLAG_BUSY) == RESET;

failed:
    /* 失败时释放两根线并恢复 AF 开漏；由调用者上报物理总线故障。 */
    GPIO_SetBits(GPIOB, GPIO_Pin_6 | GPIO_Pin_7);
    gpio.GPIO_Mode = GPIO_Mode_AF_OD;
    GPIO_Init(GPIOB, &gpio);
    I2C1_Apply100kHzConfig();
    return false;
}
```

若 SDA 本来就被从机拉低，或电平检查失败，停止恢复并检查上拉、供电、短路、从机复位状态。对“从机卡在未完成字节”这类协议层总线恢复，9 个 SCL 脉冲可能有帮助，但它是另一问题：只能在知道总线、电平和从机允许时使用，并且仍须重新初始化/验证 ACK。

## 10.5 OLED：控制字节、寻址模式与帧缓冲

以一个已确认地址为 `OLED_ADDR7` 的 128×64 SSD1306 I2C 模块为例。OLED 的 `0x00` 是“后面是命令”、`0x40` 是“后面是显示数据”的**控制字节**，不是寄存器地址。分辨率、COM 引脚配置、地址、上拉和初始化序列随模块而变，先核对数据手册。

采用页寻址时，显示 RAM 是 8 页 × 128 列，每个字节代表垂直 8 个像素。单像素函数若直接写 `0` 或 `1<<bit` 到 OLED，会擦掉同一字节的其余 7 个像素；因此先修改 1024B 帧缓冲：

```c
#define OLED_ADDR7 0x3CU       /* 仅示例：须由实物确认。 */
#define OLED_WIDTH 128U
#define OLED_PAGES 8U

static uint8_t oled_fb[OLED_WIDTH * OLED_PAGES];

static void OLED_SetPixel(uint8_t x, uint8_t y, uint8_t on)
{
    if (x >= OLED_WIDTH || y >= 64U)
        return;
    uint16_t index = (uint16_t)(y >> 3) * OLED_WIDTH + x;
    uint8_t mask = (uint8_t)(1U << (y & 7U));
    if (on != 0U) oled_fb[index] |= mask;
    else          oled_fb[index] &= (uint8_t)~mask;
}

static I2C_Result OLED_FlushPage(uint8_t page)
{
    uint8_t packet[1U + OLED_WIDTH];
    if (page >= OLED_PAGES)
        return I2C_BUS_ERROR;

    packet[0] = 0x40U;
    for (uint8_t x = 0U; x < OLED_WIDTH; ++x)
        packet[1U + x] = oled_fb[(uint16_t)page * OLED_WIDTH + x];
    return I2C1_MasterWrite7(OLED_ADDR7, packet, sizeof packet);
}
```

初始化时必须选择一种寻址模式并匹配刷新方式。例如页寻址使用页/列命令；若初始化为水平寻址，就应设置列/页窗口并连续发送。不要把两种模式的命令片段混在一起。先验证：ACK → 固定全亮/全灭 → 单页图案 → 帧缓冲像素，逐级排错。

## 10.6 验收、排错与练习

| 现象 | 优先检查 |
|---|---|
| 永远等不到 START/EV5 | SCL/SDA 是否空闲高、BUSY、时钟/上拉、F1 勘误恢复 |
| 地址 NACK | 7 位/左移是否混淆、模块供电、电平、地址脚/器件型号 |
| 事务偶发卡死 | 每个等待是否有超时；错误后是否 STOP；是否需要恢复/重新初始化 |
| SDA 永远低 | 外部设备/短路/上拉问题；不要盲目强推高 |
| 400kHz 不稳定 | 线长/电容/上拉/从机能力；先退回 100kHz |
| OLED 有电却图像破碎 | 地址/初始化寻址模式、控制字节、页/列顺序、帧缓冲刷新 |

验收顺序：

1. 不接从机，测 SCL/SDA 空闲高；
2. 只接一台已知从机，记录地址、ACK/NACK、错误码和总线频率；
3. 断线/错误地址测试超时路径，确认程序可继续运行；
4. 若遇 BUSY，先检查物理线，再按勘误序列恢复并重新验证；
5. OLED 最后加入，先刷固定页，再上帧缓冲。

练习：

1. 把 `I2C1_MasterWrite7` 的每个状态与 START、SLA+W、ACK、DATA、STOP 对应画成时序图；
2. 写一个只检查 ACK 的地址探测工具，并限制为你允许扫描的地址范围；
3. 在 `I2C_Result` 中区分“总线线低”“NACK”“时间到”，把它们输出到 UART；
4. 实现一个专用的单字节寄存器读状态机，并逐步核对 ACK/ADDR/STOP 的 F1 接收序列和勘误；
5. 给 OLED 帧缓冲加入 `dirty_pages`，只刷新修改过的页。

## 10.7 本章要点

- I2C 高电平来自上拉，不来自推挽输出；空闲前先确认 SCL/SDA 都高。
- 设备地址与线上地址字节不同：应用层保存 7 位地址，SPL 调用时左移一次。
- 所有状态等待都需要超时、错误识别、STOP/恢复路径；轮询不等于可靠。
- F103 的 BUSY 模拟滤波器勘误有官方 GPIO 电平转换 + SWRST 序列，不能用泛用 9 时钟代替。
- OLED 单像素绘制要先改帧缓冲；寻址模式、控制字节、分辨率和地址必须互相一致。

---

> **上一章**：[第 9 章 · ADC、DMA 与 DAC](./09-chapter.md)
>
> **下一章**：[第 11 章 · SPI 与 SD 卡](./11-chapter.md)

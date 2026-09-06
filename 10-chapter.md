# 第 10 章 · I2C：事务、超时与总线恢复（SPL 版）

这一章使用 I2C1 的默认引脚 PB6/PB7 建立 100 kHz 总线。先完成一个带超时和错误返回的主机写事务，再处理 STM32F1 的 BUSY 勘误，最后用 SSD1306 OLED 说明设备协议和帧缓冲怎样建立在 I2C 事务之上。

实验前先确认从机工作电压、共地和上拉。SCL、SDA 是开漏信号，空闲高电平由上拉电阻提供；上拉应接到 MCU 和从机都允许的逻辑电压。本章按 3.3 V 总线处理。

## 10.1 开漏总线和 7 位地址

I2C 设备只主动把 SCL 或 SDA 拉低。释放线路后，上拉电阻把电平恢复为高。多台设备可以共享两根线，但总线电容会随器件、连接器和线长增加，直接影响上升沿。

```text
3.3 V ── Rp ── SCL ── MCU / 从机 A / 从机 B
3.3 V ── Rp ── SDA ── MCU / 从机 A / 从机 B
GND   ───────────────── 共地
```

调代码前先用万用表或示波器确认空闲状态下两根线都为高。如果 SDA 已被外部设备持续拉低，软件等待 BUSY 超时只是故障表现，继续反复发 START 不能修复供电、短路或从机状态问题。

地址还要区分 7 位设备地址和线上发送的地址字节。以 7 位地址 `0x3C` 为例，写方向在线上发送 `0x78`，读方向发送 `0x79`。本章接口统一保存 7 位地址，调用 SPL 时再左移：

```c
I2C_Send7bitAddress(I2C1, (uint8_t)(addr7 << 1),
                     I2C_Direction_Transmitter);
```

不要在应用层同时保存 `0x3C`、`0x78` 两种形式，否则很容易重复左移。具体地址必须来自器件数据手册、地址脚配置或板卡原理图。

## 10.2 初始化 I2C1

先使用 100 kHz。等 ACK、波形和错误路径都验证后，再根据从机规格、总线电容和上升时间决定是否提高到 400 kHz。

```c
#include <stdbool.h>
#include <stdint.h>
#include "stm32f10x_gpio.h"
#include "stm32f10x_i2c.h"
#include "stm32f10x_rcc.h"

static void I2C1_Apply100kHzConfig(void)
{
    I2C_InitTypeDef i2c;

    I2C_StructInit(&i2c);
    i2c.I2C_Mode = I2C_Mode_I2C;
    i2c.I2C_DutyCycle = I2C_DutyCycle_2;
    i2c.I2C_OwnAddress1 = 0U;
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

`I2C_Init()` 根据 PCLK1 计算 CCR 和 TRISE 等时序参数。第 5 章的系统时钟配置完成后再初始化 I2C；如果运行期间改变 PCLK1，需要重新配置 I2C。

PB6/PB7 是 I2C1 默认 SCL/SDA 引脚。开发板上某个板载器件是否真的接到这里仍要看原理图，本章使用外接从机，不依赖板载连接。

## 10.3 每个等待都要能退出

最简单的 I2C 示例常写成：

```c
while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));
```

从机断电、地址 NACK 或总线异常时，这段代码会永久阻塞。这里用第 5 章的毫秒时基做超时，并把常见错误返回给调用者：

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
    uint32_t start = Timebase_NowMs();

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
    uint32_t start = Timebase_NowMs();

    while (I2C_GetFlagStatus(I2C1, I2C_FLAG_BUSY) != RESET) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return I2C_TIMEOUT;
    }

    return I2C_OK;
}
```

20 ms 之类的超时值属于系统策略，不是 I2C 协议规定值。实际值要覆盖正常事务、从机可能的 clock stretching 和系统调度延迟，同时又不能让故障长期阻塞主循环。

先实现一个单主机写事务。接口接收 7 位地址和数据缓冲，不写死某个 OLED 或 EEPROM 的协议：

```c
static I2C_Result I2C1_MasterWrite7(uint8_t addr7,
                                    const uint8_t *data,
                                    uint16_t len)
{
    I2C_Result r;

    if (data == NULL || len == 0U || addr7 > 0x7FU)
        return I2C_BUS_ERROR;

    r = I2C1_WaitBusFree(20U);
    if (r != I2C_OK)
        return r;

    I2C_GenerateSTART(I2C1, ENABLE);
    r = I2C1_WaitEvent(I2C_EVENT_MASTER_MODE_SELECT, 20U);
    if (r != I2C_OK)
        goto abort;

    I2C_Send7bitAddress(I2C1, (uint8_t)(addr7 << 1),
                         I2C_Direction_Transmitter);
    r = I2C1_WaitEvent(I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED, 20U);
    if (r != I2C_OK)
        goto abort;

    while (len-- != 0U) {
        I2C_SendData(I2C1, *data++);
        r = I2C1_WaitEvent(I2C_EVENT_MASTER_BYTE_TRANSMITTED, 20U);
        if (r != I2C_OK)
            goto abort;
    }

    I2C_GenerateSTOP(I2C1, ENABLE);
    return I2C_OK;

abort:
    I2C_GenerateSTOP(I2C1, ENABLE);
    return r;
}
```

这个函数只覆盖轮询主机发送。STM32F1 接收 1、2、N 字节时，ACK、ADDR、BTF 和 STOP 的处理顺序并不相同，器件勘误也涉及主接收流程。读事务应按 RM0008 和目标芯片对应的 errata 单独实现和验证，不要把发送函数改一个方向参数就当成完整读驱动。

## 10.4 BUSY 要先判断是哪种故障

STM32F1 的 I2C 有一个已知问题：某些情况下模拟滤波器会让 BUSY 位在外部 SCL/SDA 都已经为高时仍保持置位。对应 errata 给出了 GPIO 电平转换后执行软件复位的恢复序列。

先区分两种情况：

- **SDA 或 SCL 物理上仍为低**：先查从机供电、短路、上拉和未完成事务。此时 MCU 不能靠写寄存器把外部线路变高。
- **两根线实际都为高，但 I2C 外设仍报告 BUSY**：再使用 STM32F1 errata 的恢复流程。

恢复函数可以写成：

```c
static bool I2C1_RecoverBusyErrata(void)
{
    GPIO_InitTypeDef gpio;

    I2C_Cmd(I2C1, DISABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_6 | GPIO_Pin_7;
    gpio.GPIO_Mode = GPIO_Mode_Out_OD;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_SetBits(GPIOB, GPIO_Pin_6 | GPIO_Pin_7);
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) == Bit_RESET ||
        GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) == Bit_RESET)
        goto failed;

    GPIO_ResetBits(GPIOB, GPIO_Pin_7);  /* SDA: 1 -> 0 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) != Bit_RESET)
        goto failed;

    GPIO_ResetBits(GPIOB, GPIO_Pin_6);  /* SCL: 1 -> 0 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) != Bit_RESET)
        goto failed;

    GPIO_SetBits(GPIOB, GPIO_Pin_6);    /* SCL: 0 -> 1 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_6) != Bit_SET)
        goto failed;

    GPIO_SetBits(GPIOB, GPIO_Pin_7);    /* SDA: 0 -> 1 */
    if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_7) != Bit_SET)
        goto failed;

    gpio.GPIO_Mode = GPIO_Mode_AF_OD;
    GPIO_Init(GPIOB, &gpio);

    I2C_SoftwareResetCmd(I2C1, ENABLE);
    I2C_SoftwareResetCmd(I2C1, DISABLE);
    I2C1_Apply100kHzConfig();

    return I2C_GetFlagStatus(I2C1, I2C_FLAG_BUSY) == RESET;

failed:
    GPIO_SetBits(GPIOB, GPIO_Pin_6 | GPIO_Pin_7);
    gpio.GPIO_Mode = GPIO_Mode_AF_OD;
    GPIO_Init(GPIOB, &gpio);
    I2C1_Apply100kHzConfig();
    return false;
}
```

这段代码处理的是 STM32F1 外设内部 BUSY 状态异常。另一类常见恢复方法是手动产生若干 SCL 脉冲，让卡在发送字节过程中的从机继续推进状态机；它处理的是外部从机占住 SDA 的问题。两种故障条件不同，不能互相替代。

恢复完成后还要重新验证 BUSY、发送地址并检查 ACK。一次恢复成功只能说明当前总线回到了可通信状态；如果故障持续出现，应继续查电源、复位时序、线路和事务中断位置。

## 10.5 OLED 建立在 I2C 事务之上

以 128×64 SSD1306 模块为例。假设实物确认 7 位地址为 `0x3C`，I2C 数据流里还要带 SSD1306 自己定义的控制字节：`0x00` 表示后面发送命令，`0x40` 表示后面发送显示数据。这两个字节属于 OLED 协议，与 I2C 地址无关。

页寻址下，128×64 显存可以看成 8 页，每页 128 字节，一个字节控制同一列上的 8 个垂直像素。若每次改一个像素就直接向 OLED 写一个字节，会覆盖这个字节中另外 7 个像素。先在 RAM 里维护 1024 字节帧缓冲，再按页刷新更容易保持像素状态一致。

```c
#define OLED_ADDR7  0x3CU
#define OLED_WIDTH  128U
#define OLED_PAGES  8U

static uint8_t oled_fb[OLED_WIDTH * OLED_PAGES];

static void OLED_SetPixel(uint8_t x, uint8_t y, uint8_t on)
{
    uint16_t index;
    uint8_t mask;

    if (x >= OLED_WIDTH || y >= 64U)
        return;

    index = (uint16_t)(y >> 3) * OLED_WIDTH + x;
    mask = (uint8_t)(1U << (y & 7U));

    if (on != 0U)
        oled_fb[index] |= mask;
    else
        oled_fb[index] &= (uint8_t)~mask;
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

`OLED_FlushPage()` 假设初始化配置与刷新方式匹配。SSD1306 支持多种显存寻址方式，初始化选了页寻址，就按页和列设置位置；选了水平寻址，则应配置页/列窗口后连续传输。模块分辨率、地址和 COM 配置也可能不同，不能把某块 128×64 模块的初始化序列直接当成所有 SSD1306 模块的固定配置。

验证顺序保持简单：先确认设备 ACK，再发送最小初始化序列，然后刷固定的全灭、全亮或单页图案，最后再测试 `OLED_SetPixel()`。这样能把 I2C 物理层、设备初始化和绘图逻辑分开排查。

## 10.6 验证和排错

先不接从机，确认 SCL/SDA 空闲高。接一台已知从机后，用逻辑分析仪查看 START、地址字节、ACK、数据和 STOP，同时记录驱动返回的错误码。故意使用错误地址或断开从机，程序应该在超时或 NACK 后返回主循环，不能永久停在等待状态。

遇到 BUSY 时先直接测两根线。如果线路为低，处理外部总线问题；如果线路已经为高，再执行 F1 errata 恢复。400 kHz 不稳定时先退回 100 kHz，观察上升沿，再检查上拉、电容和从机规格。

OLED 有 ACK 但显示异常时，I2C 通信已经完成了一部分验证。继续检查控制字节、初始化命令、寻址模式、页/列位置和帧缓冲，不要反复修改 I2C 时钟来碰运气。

## 10.7 练习

1. 用逻辑分析仪捕获一次 `I2C1_MasterWrite7()`，标出 START、7 位地址、R/W 位、ACK、每个数据字节和 STOP。
2. 写一个地址探测函数，只扫描你明确允许的 7 位地址范围，并把 ACK 地址输出到 UART。
3. 给错误返回增加“总线物理线低”状态，在执行 BUSY 恢复前读取 PB6/PB7 并记录结果。
4. 按 RM0008 和目标芯片 errata 实现一个单字节寄存器读取函数，重点验证 ADDR、ACK 和 STOP 顺序。
5. 给 OLED 增加 dirty page 标记，只发送修改过的页，并统计一次刷新实际发送的字节数。

完成这一章后，I2C 驱动至少具备三个边界：所有等待都能超时退出，地址统一使用 7 位形式，BUSY 恢复会先区分外部线路故障和 STM32F1 外设状态异常。后续接 EEPROM、传感器或 OLED 时，设备协议继续放在这层事务接口之上。

> **上一章**：[第 9 章 · ADC、DMA 与 DAC](./09-chapter.md)
>
> **下一章**：[第 11 章 · SPI 与 SD 卡](./11-chapter.md)

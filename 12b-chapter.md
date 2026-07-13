# 第 12B 章 · RS485 物理层与 Modbus RTU

> **本章产出**：能把 UART 字节流安全地接到半双工 RS485；能按 Modbus RTU 的字符时间、CRC、地址和异常响应验证一帧；能区分总线帧间隔与设备响应超时。
>
> **前置知识**：第 8 章 UART、第 12 章 DMA（可选）。
>
> **本章边界**：RS485 规定电气传输，Modbus RTU 规定帧。某个温湿度模块的寄存器地址、波特率和寄存器含义必须以该模块自己的说明书为准。

## 12B.1 三个层次，不要混为一谈

```text
应用：           “读取 2 个保持寄存器”
Modbus RTU：     地址 + 功能码 + 数据 + CRC + 帧间隔
UART：           波特率、数据位、校验位、停止位
RS485：          差分 A/B 线、驱动使能、终端与偏置
```

RS485 不知道寄存器是什么，也不保证某个字节“收到”。它只定义差分收发器应如何在一对线上表示逻辑状态。Modbus RTU 也不规定传感器把温度放在哪个地址。层次分清以后，故障定位才有顺序：先看电气和 UART，再看帧边界和 CRC，最后才解释业务寄存器。

## 12B.2 先把物理层接对

### 12B.2.1 A/B 标签不是跨厂商的绝对真理

许多器件将非反相端标为 A、反相端标为 B，也有模块反过来标。不要仅凭颜色、丝印习惯或网上接线图确认极性；查双方收发器数据手册并在低风险环境下实测。若 UART 发出的波形、供电、DE 都正确却完全收不到帧，交换 A/B 是一个需要记录的诊断步骤，而不是“玄学修复”。

推荐拓扑是线性主干，而不是星形：

```text
终端                 短支线        短支线                 终端
[120 Ω]--A/B 主干------设备 1--------设备 2------...-----[120 Ω]
             \___________________________________________/
                 参考导体 / 系统定义的信号参考路径
```

| 元件 | 正确边界 |
|---|---|
| 终端电阻 | 通常只放在物理主干的两个端点；中间每个节点都加会过度负载总线 |
| 偏置（fail-safe） | 全总线通常只需一处，数值和位置按收发器/系统设计；不能每块模块随意叠加 |
| 参考线 | 系统需要定义的共模参考路径；不能把 “A/B 差分” 简化为“GND 可选” |
| 屏蔽 | 按现场 EMC、接地和隔离方案处理，不能替代参考与终端设计 |
| 1200 m 说法 | 只是特定速率、线缆、拓扑与环境下的上限量级，不是任何配置都保证的距离 |

### 12B.2.2 MCU 与收发器之间也需要板级证据

典型收发器有 `DI`（接 UART TX）、`RO`（接 UART RX）、`DE`（驱动使能）和 `/RE`（接收使能）。但板上可能把 DE 与 `/RE` 直接相连、经反相器连接，或将其接到不同 GPIO。因此不要把“USART2 + PC0”写成 ZET6 的固定事实。

在 `board.h` 中只暴露一个有语义的接口：

```c
/* 由 board.c 根据实际原理图实现 DE、/RE 的极性与连接方式。 */
void Board_Rs485SetTransmit(bool transmit);
bool Board_HasRs485(void);
```

调用层不关心某个 GPIO 是高还是低，只关心总线处于 TX 还是 RX。上电默认应为 RX/高阻驱动状态，避免复位时占住总线。

## 12B.3 半双工方向切换的真正完成点

发送一帧的顺序不是“DE 拉高、写完数组、DE 拉低”。最后一个字节还会在 USART 的移位寄存器里走完起始位、数据位和停止位。

```text
设置 TX 方向
  -> 等收发器使能时间（按数据手册；必要时用微秒定时器）
  -> 逐字节写 DR，或启动 UART TX DMA
  -> DMA TC（若使用 DMA：最后一字节已到 DR）
  -> USART TC（最后一个停止位已离开 TX 引脚）
  -> 等收发器关断/周转时间（若器件要求）
  -> 设置 RX 方向
```

下面是轮询版本，适合作为第一次总线验收。每次等待都有截止时间；`response_timeout_ms` 之类的应用超时不应被偷偷塞进这里。

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "stm32f10x_usart.h"
#include "timebase.h"

typedef enum {
    RS485_OK = 0,
    RS485_ARGUMENT,
    RS485_TXE_TIMEOUT,
    RS485_TC_TIMEOUT
} Rs485Result;

static bool UartWaitFlag(uint16_t flag, uint32_t timeout_ms)
{
    const uint32_t start = Timebase_NowMs();
    while (USART_GetFlagStatus(USART2, flag) == RESET) {
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms) {
            return false;
        }
    }
    return true;
}

Rs485Result Rs485_SendFrame(const uint8_t *data, uint16_t length)
{
    uint16_t i;

    if (data == NULL || length == 0U) {
        return RS485_ARGUMENT;
    }

    Board_Rs485SetTransmit(true);
    /* 如收发器手册要求，在这里等待 tEN；不要猜一个空循环。 */

    for (i = 0U; i < length; ++i) {
        if (!UartWaitFlag(USART_FLAG_TXE, 10U)) {
            Board_Rs485SetTransmit(false);
            return RS485_TXE_TIMEOUT;
        }
        USART_SendData(USART2, data[i]);
    }

    if (!UartWaitFlag(USART_FLAG_TC, 20U)) {
        Board_Rs485SetTransmit(false);
        return RS485_TC_TIMEOUT;
    }

    Board_Rs485SetTransmit(false);
    return RS485_OK;
}
```

量产版可把中间的逐字节发送换成第 12 章的 DMA TX，但仍必须在 DMA TC 后等 `USART_FLAG_TC` 才释放 DE。若收发器允许发送时仍接收，软件可能看到自己的回显；这是板级策略，应明确丢弃回显或保留作诊断，不能让它混入设备响应。

## 12B.4 Modbus RTU 的帧边界来自“静默时间”

Modbus RTU 没有固定起止字节。一帧由总线静默时间隔开：

- 波特率不高于 19,200 bit/s：`t1.5 = 1.5 个字符时间`，`t3.5 = 3.5 个字符时间`；
- 更高波特率：规范建议固定 `t1.5 = 750 µs`、`t3.5 = 1.75 ms`；
- `t3.5` 以上的静默标识前一帧结束；帧内超过 `t1.5` 的中断应按错误/不完整帧处理。

字符时间取决于 UART 格式。8N1 通常是 1 起始 + 8 数据 + 1 停止 = 10 位；8E1/8N2 常为 11 位。下面的计算使用第 7 章配置的 1 MHz 自由运行定时器时间 `TimerUs_Now()`；1 ms SysTick 对 9,600 bit/s 下约 1.56 ms 的 `t1.5` 不够精细。

```c
typedef struct {
    uint32_t t15_us;
    uint32_t t35_us;
} RtuTiming;

static RtuTiming Modbus_RtuTiming(uint32_t baud, uint8_t bits_per_char)
{
    RtuTiming timing;

    if (baud <= 19200U) {
        timing.t15_us = (1500000UL * bits_per_char + baud - 1U) / baud;
        timing.t35_us = (3500000UL * bits_per_char + baud - 1U) / baud;
    } else {
        timing.t15_us = 750U;
        timing.t35_us = 1750U;
    }
    return timing;
}
```

例如 9,600 bit/s、8N1 时，一个字符约 1042 µs，`t3.5` 约 3646 µs。把“等 100 ms”当作帧间隔会把多帧粘在一起；100 ms 只能是某个设备的**应用层响应超时**，与 RTU 的字符时间是两类计时器。

### 12B.4.1 推荐的初版接收策略

第一次实现 Modbus 时，优先使用第 8 章的 UART RX 中断环形队列，并在收到每个字节时记录微秒时间戳。ISR 只保存 `{byte, timestamp}`，主循环按时间戳组帧、验证 CRC、解释功能码。这样能清楚复现实验中的帧内间隔。

DMA 循环接收可以降低中断频率，但它不会给每个字节附带时间。可以用 IDLE、HT、TC 事件唤醒主循环，再保守地等待完整 `t3.5`；若设备或总线负载要求严格帧内错误判断，就要设计时间戳/定时器捕获方案，而不是假设 DMA 的 `CNDTR` 自带帧边界。

## 12B.5 CRC、请求与响应验证

### 12B.5.1 CRC16/Modbus

Modbus CRC 初始值为 `0xFFFF`，多项式在 LSB 优先实现中为 `0xA001`。发送时 CRC 的低字节在前。位运算版代码很小，也足够作为第一版的可读参考：

```c
#include <stddef.h>
#include <stdint.h>

uint16_t Modbus_RtuCrc(const uint8_t *data, size_t length)
{
    uint16_t crc = 0xFFFFU;
    size_t i;
    uint8_t bit;

    for (i = 0U; i < length; ++i) {
        crc ^= data[i];
        for (bit = 0U; bit < 8U; ++bit) {
            if ((crc & 1U) != 0U) {
                crc = (uint16_t)((crc >> 1) ^ 0xA001U);
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}
```

已知测试向量：对请求正文 `01 03 00 01 00 02`，函数返回 `0xCB95`，在线上的完整请求必须是：

```text
01 03 00 01 00 02 95 CB
                         ^低字节 ^高字节
```

接收时可对**包含末尾两个 CRC 字节**的整帧再算一次；结果为 0 才是 CRC 通过。不要只比较地址和功能码就把数据交给业务层。

### 12B.5.2 一次读保持寄存器请求

`0x03` 是“读保持寄存器”，但起始地址、数量上限、数值缩放、寄存器编号是否从 0 还是 1 展示，都由目标设备文档规定。下面的例子只展示 Modbus 线上的编码，不声称某个 SHT30 或其他模块一定这样定义：

```c
bool Modbus_BuildReadHolding(uint8_t address, uint16_t start,
                             uint16_t quantity, uint8_t out[8])
{
    uint16_t crc;

    if (address == 0U || quantity == 0U || quantity > 125U) {
        return false;
    }
    out[0] = address;
    out[1] = 0x03U;
    out[2] = (uint8_t)(start >> 8);
    out[3] = (uint8_t)start;
    out[4] = (uint8_t)(quantity >> 8);
    out[5] = (uint8_t)quantity;
    crc = Modbus_RtuCrc(out, 6U);
    out[6] = (uint8_t)crc;
    out[7] = (uint8_t)(crc >> 8);
    return true;
}
```

响应不能只看“收到了 7 个字节”。对于一次读 `quantity` 个 16 位寄存器，正常响应必须满足：

| 检查 | 正常响应要求 |
|---|---|
| 地址 | 等于本次请求地址 |
| 功能码 | 等于请求的 `0x03` |
| 字节数 | 等于 `quantity * 2` |
| 总长度 | `3 + byte_count + 2` |
| CRC | 整帧计算结果为 0 |

若响应功能码为 `request_function | 0x80`，则是 Modbus 异常帧，长度通常为 5 字节（地址、异常功能码、异常码、CRC）。它是设备返回的合法协议结果，不能当作“串口乱码”重试到无穷。

广播地址 0 只适用于特定写操作，主机不能期待响应；读请求发送到 0 是设计错误。

## 12B.6 一次完整主站事务的状态

把下面的状态写成显式枚举，日志中带上失败原因，而不是在一个函数中塞一连串 `Delay_ms(100)`：

```text
IDLE
  -> 确认上一帧 t3.5 已满足
  -> 清理本次 RX 状态（不清掉仍在 DMA 中的未知字节）
  -> 切为 TX，发送请求，等待 USART TC
  -> 切回 RX
  -> 等首字节：应用层 response timeout，例如设备文档给出的 100 ms
  -> 收集字节：按 t1.5/t3.5 判定帧结束
  -> 验证长度、地址、功能码、CRC、异常码
  -> 成功 / 可诊断失败
```

“等待首字节”与“帧内静默”必须分开记录：前者用于判断从站没响应，后者用于判断已响应的数据帧是否完整。请求重试也应有次数上限，并在重试前满足总线静默要求；多个主机同时挂在一个 Modbus RTU 总线上并不是正常工作模式。

## 12B.7 验收、故障定位与练习

| 现象 | 优先检查 |
|---|---|
| 一直没有响应 | 电源、A/B 极性、参考路径、UART 格式、DE 默认状态、从站地址 |
| 有字节但 CRC 总错 | 波特率/校验/停止位、终端与偏置、帧间隔、收发回显混入 |
| 最后一个字节偶尔缺失 | DE 在 USART TC 前释放，或收发器关断时间未满足 |
| 两帧被拼成一帧 | 用应用层 100 ms 代替 t3.5，或没有记录真实接收时间 |
| 读寄存器总是异常 | 寄存器地址、功能码、数量或设备权限不符合从站文档 |

最小验收步骤：

1. 先做一收一发回环或可信从站的 UART 验证，再接 A/B 总线。
2. 抓取 `01 03 00 01 00 02 95 CB`，用 PC 工具或脚本复算 CRC。
3. 在逻辑分析仪上测 DE 与 TX：DE 必须覆盖整帧和最后停止位。
4. 人为插入超过 `t1.5` 的帧内空隙，确认软件拒绝该帧；人为延迟从站首字节，确认触发的是 response timeout 而不是 CRC 错误。
5. 用从站手册给出的一个已知寄存器交叉验证数值、字节序和缩放。

Modbus RTU 的正式时序与帧规则可对照 [Modbus over Serial Line Specification](https://www.modbus.org/file/secure/modbusoverserial.pdf)。

### 练习

1. 为 `Rs485_SendFrame()` 增加明确的参数错误枚举和收发器 `tEN/tDIS` 微秒延时接口。
2. 写一个只验证地址、功能码、字节数和 CRC 的 `Modbus_ParseReadHoldingResponse()`；把寄存器业务解释放到另一个函数。
3. 将 UART 格式从 8N1 改成 8E1，重新计算 9,600 bit/s 下的 `t1.5` 与 `t3.5`，并用示波器/逻辑分析仪验证。
4. 用两台从站和一个短支线搭建总线，分别测试无终端、两个端点终端、每节点终端，记录波形和 CRC 失败率。

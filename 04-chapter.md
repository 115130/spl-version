# 第 4 章 · C 语言的嵌入式边界（SPL 版）

> **本章产出**：能判断一段 C 代码是在操作普通内存、硬件寄存器还是 ISR 共享状态；能把位操作、`volatile`、`const`、指针、链接脚本和单线时序放到正确边界内。
>
> **前置知识**：完成第 0–3 章，能读基本 C；不要求会汇编。
>
> **通过标准**：解释为什么 `volatile` 既不能让 `counter++` 原子，也不能替代 RTOS 同步；能用 map/nm 验证 `.data`、`.bss` 和 `.rodata`；能画出 DS18B20 与 DHT11 的共同电气层和不同协议层。

---

## 4.1 位操作：先问“谁还会改这一位”

外设寄存器通常把多个功能塞进一个 32 位数。最基本的操作仍然是：

```c
/* 设置一位；清除一位；读取一位。 */
REG |=  (1UL << 5);
REG &= ~(1UL << 5);
uint32_t bit5 = (REG >> 5) & 1UL;

/* 用掩码更新一个位域。 */
REG = (REG & ~(0x3UL << 4)) | (0x2UL << 4);
```

最后一行是“读—改—写”。若 ISR、DMA 或另一段代码可能同时改同一寄存器的其他位，它会把对方刚写的值覆盖掉。GPIO 的 BSRR 专门避免了这一问题：

```c
GPIOB->BSRR = GPIO_Pin_5;              // 只置 PB5
GPIOB->BSRR = (uint32_t)GPIO_Pin_5 << 16; // 只复位 PB5
```

**选择规则**：有“专用置位/清位寄存器”就优先用它；只有在确认唯一写者时，才对 ODR/普通控制寄存器做 `|=`、`&=` 或 `^=`。第 3 章的 `GPIO_ToggleBits` 是唯一写者下的教学工具，不是 ISR 与主循环共享端口时的通用方案。

## 4.2 `volatile`：保留访问，不提供同步

### 硬件寄存器必须按宽度和方向访问

GPIOB 的 IDR 是 32 位**只读**寄存器。下面的写法既说明正确的类型，也提醒“不能向 IDR 写配置”：

```c
const volatile uint32_t * const gpiob_idr =
    (const volatile uint32_t *)0x40010C08UL;

uint32_t pb0_level = (*gpiob_idr >> 0) & 1UL;
```

`volatile` 的含义是：每个 C 层面的读/写都是可观察访问，编译器不能把它当成可随意消除或缓存的普通内存。CMSIS 已把外设寄存器成员定义为 `volatile`，所以正常代码应写：

```c
uint32_t input = GPIOB->IDR;
GPIOB->BSRR = GPIO_Pin_5;
```

而不需要手写裸地址宏。裸地址只适合作为理解和核对参考手册的练习。

### `volatile` 不保证什么

它**不**保证以下事情：

| 误解 | 正确边界 |
|---|---|
| “`volatile` 防止所有重排” | 它约束 volatile 访问的优化，不等价于通用内存屏障或并发协议 |
| “`volatile counter++` 是原子的” | `++` 是读、加、写的复合操作；可能丢失更新 |
| “任务间共享变量加 volatile 就安全” | FreeRTOS 任务间用队列、通知、互斥量或临界区；ISR 使用对应的 ISR 安全 API |
| “把所有变量都标 volatile 更安全” | 会掩盖设计问题、增加访问成本，且仍不能修复竞态 |

主循环与 ISR 的最小模式是单向事件：

```c
static volatile uint8_t button_event;

void EXTI0_IRQHandler(void)
{
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        button_event = 1U;       // 单次对齐字节赋值
    }
}

int main(void)
{
    for (;;) {
        if (button_event != 0U) {
            uint8_t event;
            uint32_t primask = __get_PRIMASK();
            __disable_irq();
            event = button_event;
            button_event = 0U;
            if (primask == 0U) __enable_irq();

            if (event != 0U) {
                /* 业务处理放在 ISR 外。 */
            }
        }
    }
}
```

保存并恢复 `PRIMASK` 很重要：无条件 `__enable_irq()` 会错误地打开上层原本关闭的中断。更复杂的队列、计数、结构体交接在第 6、14 章使用明确的临界区/RTOS 原语实现。

## 4.3 `const`、段与实际内存占用

`const` 表示“不可通过这个名字修改”，它是 C 的类型限定符；**C 语言本身不承诺放在 Flash**。对本书的 GNU ARM 链接脚本而言，文件作用域的只读对象通常进入 `.rodata`，该段与 `.text` 放在 Flash：

```c
static const uint16_t sine_table[4] = {0, 1024, 2048, 3072};
static uint16_t samples[128];
static uint32_t boot_count = 3;
```

| 对象 | 通常所在段 | RAM 影响 |
|---|---|---|
| `sine_table` | `.rodata`（Flash） | 不占运行期数组 RAM |
| `samples` | `.bss`（RAM，复位清零） | 占 256B RAM |
| `boot_count` | `.data`（RAM，初值存 Flash） | 占 4B RAM，启动时要复制 |

不要凭印象判断。构建后检查：

```bash
arm-none-eabi-size build/blink.elf
arm-none-eabi-nm -S --size-sort build/blink.elf | tail -n 20
rg 'sine_table|samples|boot_count' build/blink.map
```

字符串字面量、`const` 指针和可变指针仍要分清：`const char *p` 是“不能经由 `p` 改字符”，不是“`p` 不可改”；`char * const p` 才是指针本身不可改。

## 4.4 指针映射寄存器：类型也是硬件协议的一部分

以下定义把地址、访问宽度和易变性写在同一个地方：

```c
#define GPIOB_BASE 0x40010C00UL
#define GPIOB_ODR  (*(volatile uint32_t *)(GPIOB_BASE + 0x0CUL))
#define GPIOB_BSRR (*(volatile uint32_t *)(GPIOB_BASE + 0x10UL))
```

但不要为了“直接”而绕开 CMSIS：错误的地址、宽度、保留位或读写方向都可能造成难以定位的故障。外设结构体把偏移也编码进类型：

```c
typedef struct {
    volatile uint32_t CRL;   /* +0x00 */
    volatile uint32_t CRH;   /* +0x04 */
    volatile uint32_t IDR;   /* +0x08，读 */
    volatile uint32_t ODR;   /* +0x0C，读写 */
    volatile uint32_t BSRR;  /* +0x10，写 */
    volatile uint32_t BRR;   /* +0x14，写 */
    volatile uint32_t LCKR;  /* +0x18 */
} GPIO_TypeDef;
```

同类型的 `uint32_t` 成员以 4 字节间隔，正好对应 RM0008 的 GPIO 偏移。真实工程使用 ST 提供的 `GPIO_TypeDef`，并在阅读参考手册时核对寄存器的“reset value / access / reserved bits”。

## 4.5 链接脚本和启动代码：一份双向契约

第 0 章模板的 `link.ld` 与 `startup_stm32f10x_hd.s` 使用同一组符号：

```ld
FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 64K

_estack = ORIGIN(RAM) + LENGTH(RAM);
/* .data 在 RAM 运行，初始镜像在 Flash。 */
_sidata = LOADADDR(.data);
/* 启动文件复制/清零的边界。 */
_sdata; _edata; _sbss; _ebss;
```

启动过程不是“编译器自动完成”：CPU 从向量表第一项取得 `_estack`，从第二项取得 `Reset_Handler`；处理器随后执行 `.data` 复制、`.bss` 清零、`SystemInit()` 和 `main()`。因此下面四项必须一起验证：

| 检查 | 正确状态 |
|---|---|
| 设备密度 | `STM32F10X_HD` 与 HD 启动向量表 |
| 向量表段 | `.isr_vector` 被链接脚本 `KEEP` 到 Flash 开头 |
| 内存 | 512KB Flash、64KB RAM |
| 边界符号 | 启动汇编与链接脚本都使用 `_sidata/_sdata/_edata/_sbss/_ebss` |

栈从 RAM 高地址向下增长，`.data/.bss` 从低地址向上增长；堆是否启用、预留多少，取决于链接脚本和 C 库。不要把“有 64KB SRAM”误解成每个全局数组都安全：还要给 ISR 嵌套、函数局部变量和可能的堆预留空间。

## 4.6 Mini-GPIO：只为理解，不替代 SPL

下面的例子展示必要边界：先开 RCC 时钟，再配置一个引脚；置位/复位用 BSRR；不提供可并发的 `Toggle`。

```c
typedef struct {
    volatile uint32_t CRL, CRH, IDR, ODR, BSRR, BRR, LCKR;
} MyGPIO;

#define MY_GPIOB ((MyGPIO *)0x40010C00UL)

static void MyGpioB_Pin5_Output2MHz(void)
{
    RCC->APB2ENR |= RCC_APB2ENR_IOPBEN;
    MY_GPIOB->CRL = (MY_GPIOB->CRL & ~(0xFUL << 20)) |
                     (0x2UL << 20);   /* MODE=10, CNF=00 */
}

static void MyGpio_Set(MyGPIO *gpio, uint8_t pin)
{
    gpio->BSRR = 1UL << pin;
}

static void MyGpio_Reset(MyGPIO *gpio, uint8_t pin)
{
    gpio->BSRR = 1UL << (pin + 16U);
}
```

这个示例没有处理参数检查、所有 GPIO 模式、时钟复位或复用重映射，所以不应被复制成产品驱动。它的目的只是让你看见 SPL 的 `GPIO_Init()` 最终也在进行相同的寄存器配置。

## 4.7 单线传感器：共用电气层，不共用协议

DS18B20 使用 Dallas/Maxim 1-Wire；DHT11 使用自己的单线时序协议。它们都常见为“数据线 + 上拉电阻”，但**命令、应答、位时序、校验都不同**，不能共用“1-Wire 驱动”或把 DHT11 称作 Dallas 1-Wire。

### 先建立可释放的数据线

为外接实验选择一个普通 GPIO（本书默认 DS18B20 为 PB0、DHT11 为 PB1，但必须先确认资源表）。数据线通过约 4.7kΩ 上拉到 3.3V；MCU 使用开漏输出：

```c
#define OW_PORT GPIOB
#define OW_PIN  GPIO_Pin_0

static void OneWireBus_Init(void)
{
    GPIO_InitTypeDef gpio;
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = OW_PIN;
    gpio.GPIO_Mode = GPIO_Mode_Out_OD;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(OW_PORT, &gpio);
    GPIO_SetBits(OW_PORT, OW_PIN);     /* 释放，不是强推高 */
}

static inline void Bus_Low(void)     { GPIO_ResetBits(OW_PORT, OW_PIN); }
static inline void Bus_Release(void) { GPIO_SetBits(OW_PORT, OW_PIN); }
static inline uint8_t Bus_Read(void)
{
    return GPIO_ReadInputDataBit(OW_PORT, OW_PIN);
}
```

不能用推挽输出的“高电平”来释放共享数据线：如果从机正在拉低，两个输出会对抗。开漏输出在写 1 时断开下拉晶体管，IDR 仍能读到真实总线电平。

### 微秒延时的前提

这些协议的关键是**实测的微秒时序**。不要用空 `for` 循环或“72MHz 下一条 NOP 约多少 ns”估算：优化级别、函数调用和 Flash 等待周期都会改变它。为时序驱动提供一个经验证的接口：

```c
void TimerUs_Delay(uint32_t us);     /* 用 1MHz 定时器实现，见第 7 章 */
uint32_t TimerUs_Now(void);          /* 若需要超时轮询 */
```

用逻辑分析仪或示波器检查低脉冲、释放后的上升沿和采样点；上拉过大、线太长或模块自带上拉不明都会使“代码正确但读不到设备”。

### DS18B20：Dallas 1-Wire 的最小原语

以下是基于开漏释放和定时器延时的核心时隙，数值仍应以所用器件数据手册为准：

```c
static uint8_t DS18B20_Reset(void)
{
    Bus_Low();
    TimerUs_Delay(480U);
    Bus_Release();
    TimerUs_Delay(70U);
    uint8_t present = (Bus_Read() == Bit_RESET);
    TimerUs_Delay(410U);
    return present;
}

static void OneWire_WriteBit(uint8_t bit)
{
    Bus_Low();
    if (bit != 0U) {
        TimerUs_Delay(6U);
        Bus_Release();
        TimerUs_Delay(64U);
    } else {
        TimerUs_Delay(60U);
        Bus_Release();
        TimerUs_Delay(10U);
    }
}

static uint8_t OneWire_ReadBit(void)
{
    Bus_Low();
    TimerUs_Delay(3U);
    Bus_Release();
    TimerUs_Delay(10U);
    uint8_t bit = Bus_Read();
    TimerUs_Delay(55U);
    return bit;
}
```

完成 `WriteByte`/`ReadByte` 后，单只设备可用 `Skip ROM (0xCC)`、`Convert T (0x44)`、`Read Scratchpad (0xBE)`；但要明确检查每次 reset 的 presence、等待转换完成、读取完整 9 字节并校验 Dallas CRC8。`0xCC` 只适用于总线上确实只有一个 DS18B20 的情况。温度原始值是有符号 1/16°C，优先先输出原始值或整数毫摄氏度，避免第 8 章尚未解释的 `printf` 浮点支持问题。

### DHT11：相同电气层，不同状态机

DHT11 的主机起始信号为低电平至少约 18ms，随后释放并等待传感器应答；传感器发送 40 位，位值由高电平持续时间区分。它不是 reset/presence/ROM 的 1-Wire 流程。

可靠实现要有每一步的超时，不能无限等待：

```c
static uint8_t WaitLevel(uint8_t level, uint32_t timeout_us)
{
    uint32_t start = TimerUs_Now();
    while (Bus_Read() != level) {
        if ((uint32_t)(TimerUs_Now() - start) >= timeout_us)
            return 0U;
    }
    return 1U;
}
```

读到 5 个字节后验证 `b0 + b1 + b2 + b3 == b4`（低 8 位）。超时或校验失败应返回错误码并保留上一次有效读数；不要把未初始化缓冲区当传感器数据。DHT11 的采样间隔也受器件规格限制，不能在主循环中无间隔读取。

## 4.8 验收、排错与练习

| 现象 | 先检查 |
|---|---|
| 优化后 ISR 标志偶尔失效 | 变量是否 `volatile`；是否把读清操作做成了竞态；是否保存/恢复 PRIMASK |
| RAM 突然不够 | `size` 和 map 中 `.bss/.data` 最大符号；是否遗漏 `const`；栈预留是否合理 |
| DS18B20 始终不存在 | 3.3V/GND、4.7k 上拉、开漏释放、定时器实际微秒宽度、单设备 ROM 假设 |
| DHT11 卡死 | 每一个等待是否有超时；是否误用了 Dallas 1-Wire 代码；起始低电平是否足够长 |
| 总线高电平上升很慢 | 上拉阻值、线长、电容、模块上已有的上拉并联关系 |

练习：

1. 在第 0 章 blink 中分别加入有初值、无初值和 `const` 的 1KB 数组，用 map 验证段归属；
2. 将 `volatile uint32_t counter` 的 `++` 放入主循环和 ISR，设计一个可观察的丢计数实验，再用临界区修复；
3. 用逻辑分析仪记录一次 DS18B20 reset/presence，标出 480µs、70µs 和采样点；
4. 为 DHT11 的所有等待分支写出错误码，确认断线时函数可以在有限时间内返回。

## 4.9 本章要点

- 位操作必须考虑读—改—写是否会覆盖其他上下文；GPIO BSRR 能避免单引脚写的竞态。
- `volatile` 用于硬件寄存器和最小 ISR 共享状态；它不等于原子、锁、内存屏障或 RTOS 同步。
- `const` 是否节省 SRAM 要由链接脚本和 map 验证，不能只凭 C 关键字推断。
- 启动文件和链接脚本是 `_sidata/_sdata/_edata/_sbss/_ebss` 的共同契约。
- DS18B20 是 Dallas 1-Wire，DHT11 是另一种单线时序协议；二者共享“开漏释放 + 上拉 + 定时器延时”的电气/时间基础，但不共享协议驱动。

---

> **上一章**：[第 3 章 · GPIO 与寄存器编程](./03-chapter.md)
>
> **下一章**：[第 5 章 · 时钟系统](./05-chapter.md)

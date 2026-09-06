# 第 4 章 · C 语言的嵌入式边界（SPL 版）

这一章把前几章已经用到的 C 语言细节集中讲清楚：位操作、`volatile`、`const`、指针、链接段，以及微秒级时序代码。

重点不是重新学一遍 C，而是知道这些语法到了 MCU 上以后分别约束什么硬件行为。

## 4.1 位操作先看有没有并发写者

外设寄存器经常把多个功能放在同一个 32 位值里。常见操作有：

```c
REG |=  (1UL << 5);        /* 置位 */
REG &= ~(1UL << 5);        /* 清位 */
uint32_t bit5 = (REG >> 5) & 1UL;

REG = (REG & ~(0x3UL << 4)) |
      (0x2UL << 4);        /* 更新位域 */
```

`|=`、`&=` 和最后一行都会先读寄存器，再修改，再写回。只有一个执行上下文会改这个寄存器时，这种写法通常没问题；如果 ISR、DMA 或另一段代码也会改同一个寄存器，就可能覆盖对方刚写进去的位。

GPIO 提供了专门的置位和复位寄存器。STM32F1 上可以这样写：

```c
GPIOB->BSRR = GPIO_Pin_5;  /* PB5 置 1 */
GPIOB->BRR  = GPIO_Pin_5;  /* PB5 清 0 */
```

这两次写操作都只影响指定引脚，不需要先读取 ODR。需要并发修改 GPIO 时，优先使用这种专用寄存器。

## 4.2 `volatile` 保证访问发生

硬件寄存器的值可能在程序之外变化。比如 USART 收到字节后，硬件会修改状态寄存器；GPIO 输入电平变化后，IDR 也会变化。编译器不能把这些地址当成普通内存缓存起来。

CMSIS 已经把外设寄存器定义成 `volatile`，正常代码直接写：

```c
uint32_t input = GPIOB->IDR;
GPIOB->BSRR = GPIO_Pin_5;
```

理解裸地址时，可以把 GPIOB 的 IDR 写成：

```c
const volatile uint32_t * const gpiob_idr =
    (const volatile uint32_t *)0x40010C08UL;

uint32_t pb0 = (*gpiob_idr >> 0) & 1UL;
```

这里三个限定各有作用：

- `volatile`：每次读取都真的访问这个地址。
- `const uint32_t`：不能通过这个指针写 IDR。
- `* const`：指针本身不能再指向别的地址。

`volatile` 不会把复合操作变成原子操作。下面这句仍然包含读取、加一、写回：

```c
volatile uint32_t counter;
counter++;
```

如果主循环和 ISR 同时执行 `counter++`，其中一次更新可能被覆盖。需要保护这种读改写时，要用临界区、原子操作或 RTOS 提供的同步机制。

主循环和 ISR 之间传一个简单事件，可以这样写：

```c
static volatile uint8_t button_event;

void EXTI0_IRQHandler(void)
{
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        button_event = 1U;
    }
}
```

主循环如果要“读取并清零”这个事件，就要保护这两个动作：

```c
static uint8_t TakeButtonEvent(void)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();

    uint8_t event = button_event;
    button_event = 0U;

    if (primask == 0U)
        __enable_irq();

    return event;
}
```

保存原来的 `PRIMASK` 很重要。无条件调用 `__enable_irq()`，可能会把上层代码原本关闭的中断重新打开。

## 4.3 `const` 不等于“自动放进 Flash”

`const` 是 C 的类型限定符，它只限制通过这个名字修改对象。对象最终放进 Flash 还是 RAM，由编译器和链接脚本决定。

在本书当前 GCC 链接脚本下，这几个对象通常会得到这样的布局：

```c
static const uint16_t sine_table[4] = {
    0, 1024, 2048, 3072
};

static uint16_t samples[128];
static uint32_t boot_count = 3;
```

`sine_table` 通常进入 `.rodata`，跟代码一起放在 Flash；`samples` 进入 `.bss`，占 256 字节 SRAM；`boot_count` 进入 `.data`，运行时占 4 字节 SRAM，同时它的初始值还要保存在 Flash 中。

不要只凭关键字判断，直接检查 ELF 和 MAP：

```bash
arm-none-eabi-size build/blink.elf
arm-none-eabi-nm -S --size-sort build/blink.elf | tail -n 20
rg 'sine_table|samples|boot_count' build/blink.map
```

指针上的 `const` 也要看位置：

```c
const char *p;       /* 不能通过 p 修改字符，p 可以改 */
char * const p2 = x; /* p2 不能改，字符可以改 */
```

## 4.4 用结构体映射外设寄存器

直接写地址可以帮助理解寄存器映射：

```c
#define GPIOB_BASE 0x40010C00UL
#define GPIOB_ODR  (*(volatile uint32_t *)(GPIOB_BASE + 0x0CUL))
#define GPIOB_BSRR (*(volatile uint32_t *)(GPIOB_BASE + 0x10UL))
```

实际工程更适合使用 CMSIS 已经定义好的外设结构体。GPIO 的寄存器布局大致是：

```c
typedef struct {
    volatile uint32_t CRL;   /* +0x00 */
    volatile uint32_t CRH;   /* +0x04 */
    volatile uint32_t IDR;   /* +0x08 */
    volatile uint32_t ODR;   /* +0x0C */
    volatile uint32_t BSRR;  /* +0x10 */
    volatile uint32_t BRR;   /* +0x14 */
    volatile uint32_t LCKR;  /* +0x18 */
} GPIO_TypeDef;
```

每个 `uint32_t` 占 4 字节，因此结构体成员偏移正好对应 RM0008 里的寄存器偏移。`GPIOB->ODR` 本质上就是“GPIOB 基地址 + ODR 偏移”的一次 32 位访问。

这种写法把地址、访问宽度和字段偏移统一放进类型定义里，也减少了手写裸地址时的偏移错误。

## 4.5 `.data`、`.bss` 和启动代码

链接脚本定义 Flash 和 SRAM 的地址范围：

```ld
FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 64K

_estack = ORIGIN(RAM) + LENGTH(RAM);
_sidata = LOADADDR(.data);
```

启动文件和链接脚本还共同使用：

```text
_sdata  _edata
_sbss   _ebss
```

复位以后，`Reset_Handler` 先把 `.data` 的初始值从 Flash 复制到 SRAM，再把 `.bss` 清零，然后执行 `SystemInit()`，最后进入 `main()`。

这也是为什么有初始值的全局变量会同时消耗 Flash 和 SRAM：Flash 保存初始镜像，SRAM 保存运行时那一份。

栈也在 SRAM 中，通常从高地址向低地址增长。64 KB SRAM 不能全部拿去放全局数组，还要给函数局部变量、中断嵌套以及可能存在的堆留空间。

## 4.6 写一个最小 GPIO 封装

下面用自己的结构体写一次 GPIO，只用于理解 SPL 的工作方式：

```c
typedef struct {
    volatile uint32_t CRL;
    volatile uint32_t CRH;
    volatile uint32_t IDR;
    volatile uint32_t ODR;
    volatile uint32_t BSRR;
    volatile uint32_t BRR;
    volatile uint32_t LCKR;
} MyGPIO;

#define MY_GPIOB ((MyGPIO *)0x40010C00UL)

static void MyGpioB_Pin5_Output2MHz(void)
{
    RCC->APB2ENR |= RCC_APB2ENR_IOPBEN;

    MY_GPIOB->CRL =
        (MY_GPIOB->CRL & ~(0xFUL << 20)) |
        (0x2UL << 20);   /* MODE=10, CNF=00 */
}

static void MyGpio_Set(MyGPIO *gpio, uint8_t pin)
{
    gpio->BSRR = 1UL << pin;
}

static void MyGpio_Reset(MyGPIO *gpio, uint8_t pin)
{
    gpio->BRR = 1UL << pin;
}
```

对应的 SPL 写法是：

```c
GPIO_InitTypeDef gpio;

RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

GPIO_StructInit(&gpio);
gpio.GPIO_Pin = GPIO_Pin_5;
gpio.GPIO_Mode = GPIO_Mode_Out_PP;
gpio.GPIO_Speed = GPIO_Speed_2MHz;
GPIO_Init(GPIOB, &gpio);
```

SPL 主要替你处理参数检查、寄存器位计算和常用模式组合。需要确认某个函数到底改了什么，直接打开 `stm32f10x_gpio.c` 对照 RM0008 即可。

## 4.7 单线传感器先看电气层

DS18B20 和 DHT11 都只需要一根数据线，但协议不同。

DS18B20 使用 Dallas/Maxim 1-Wire。DHT11 使用自己的单线脉冲协议。两者不能共用命令、位时序或校验代码。

它们可以共用一个基本电气原则：MCU 能把总线拉低，也能释放总线，让外部上拉电阻把电平拉高。

以 PB0 为例：

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

    GPIO_SetBits(OW_PORT, OW_PIN); /* 释放总线 */
}

static inline void Bus_Low(void)
{
    GPIO_ResetBits(OW_PORT, OW_PIN);
}

static inline void Bus_Release(void)
{
    GPIO_SetBits(OW_PORT, OW_PIN);
}

static inline uint8_t Bus_Read(void)
{
    return GPIO_ReadInputDataBit(OW_PORT, OW_PIN);
}
```

外部上拉阻值要按器件数据手册和实际总线电容选择。常见实验电路会看到约 4.7 kΩ，但不要把这个值当成所有线长和所有器件都适用的固定答案。

开漏写 1 时，MCU 停止拉低，总线由上拉电阻和其他设备决定。共享线不能用推挽高电平代替“释放”，否则另一端正在拉低时会产生输出对抗。

## 4.8 微秒时序要靠定时器验证

DS18B20 和 DHT11 的协议都依赖微秒级脉冲。空 `for` 循环不适合作为稳定时基，因为优化等级、函数调用和 Flash 等待周期都会改变执行时间。

后面的定时器章节会提供类似接口：

```c
void TimerUs_Delay(uint32_t us);
uint32_t TimerUs_Now(void);
```

真正写协议前，先用逻辑分析仪或示波器确认这些函数产生的脉冲宽度。时序代码能不能工作，最终看引脚上的实际波形。

DS18B20 的 reset 可以写成：

```c
static uint8_t DS18B20_Reset(void)
{
    Bus_Low();
    TimerUs_Delay(480U);

    Bus_Release();
    TimerUs_Delay(70U);

    uint8_t present =
        (Bus_Read() == Bit_RESET);

    TimerUs_Delay(410U);
    return present;
}
```

这些数值来自 DS18B20 的时序要求，正式实现时仍应以当前器件数据手册为准，并留足规定的时间窗口。

写位和读位也遵循同样原则：主机先拉低，再在规定时间释放或采样。

```c
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

单个 DS18B20 的基本命令流程可以从 `Skip ROM (0xCC)`、`Convert T (0x44)`、`Read Scratchpad (0xBE)` 开始。每次 reset 都要检查 presence，读取 scratchpad 后校验 CRC8；`Skip ROM` 只适合总线上只有一个 1-Wire 设备的情况。

DHT11 的流程完全不同。主机先保持低电平至少约 18 ms，再释放并等待传感器应答。随后传感器发送 40 位数据，高电平持续时间用于区分 0 和 1。

每一步等待都要有超时：

```c
static uint8_t WaitLevel(uint8_t level,
                         uint32_t timeout_us)
{
    uint32_t start = TimerUs_Now();

    while (Bus_Read() != level) {
        if ((uint32_t)(TimerUs_Now() - start) >= timeout_us)
            return 0U;
    }

    return 1U;
}
```

DHT11 返回 5 个字节后，要检查前 4 个字节求和的低 8 位是否等于第 5 个字节。断线、超时或校验失败时函数应该返回错误，不要继续使用未完成的数据。

## 4.9 怎么验证这一章

先用一个 1 KB 的有初值数组、一个 1 KB 的无初值数组和一个 1 KB 的 `const` 数组重新构建工程。通过 MAP 文件确认它们分别落到 `.data`、`.bss` 和 `.rodata`。

再做一次并发实验：让主循环和 ISR 都对同一个 `volatile uint32_t counter` 执行 `++`，观察计数是否会丢，再用最小临界区保护读改写。

做单线传感器实验时，不要先写完整温度解析。先验证三件事：总线空闲高电平正常、MCU 能拉低并释放、逻辑分析仪上能看到符合数据手册时间窗口的 reset 或起始脉冲。

如果 DS18B20 一直没有 presence，检查供电、GND、上拉、开漏模式和实际脉宽。DHT11 如果函数卡死，优先检查每一个等待分支是否都有超时。

完成这些实验后，这一章应该留下四个明确结论：`volatile` 解决访问可见性，不解决竞态；链接段决定对象实际占用；外设结构体只是地址映射；微秒协议最终靠波形验证。

> **上一章**：[第 3 章 · GPIO 与寄存器编程](./03-chapter.md)
>
> **下一章**：[第 5 章 · 时钟系统](./05-chapter.md)

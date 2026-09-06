# 第 3 章 · GPIO 与寄存器编程（SPL版）

这一章开始真正操作引脚。先把 GPIO 的输入、推挽、开漏、上拉和下拉弄清楚，再用 SPL 配置 LED 和按键，最后看这些函数实际改了哪些寄存器。

硬件上需要 STM32F103ZET6 和 ST-Link。外接 LED 要串限流电阻；按键输入要有明确的上拉或下拉，不能让输入脚悬空。

## 3.1 GPIO 里有什么

一个 GPIO 引脚同时有输入和输出两部分。输入电平通过输入缓冲进入 IDR；输出部分由 ODR、BSRR/BRR 和输出驱动电路控制。

```text
外部引脚
   │
   ├── 输入缓冲 ─────────────→ IDR
   │      └── 内部上拉 / 下拉
   │
   └── 输出驱动 ← ODR / BSRR / BRR
          ├── 推挽
          └── 开漏
```

STM32F1 每个引脚在 CRL 或 CRH 里占 4 个配置位。Pin 0–7 在 CRL，Pin 8–15 在 CRH。输出模式的 4 位由 `MODE[1:0]` 和 `CNF[1:0]` 组成，输入模式则用 `MODE=00`，再由 CNF 选择模拟、浮空或上拉/下拉。

这些位不用背，后面直接看 SPL 怎么填写。

## 3.2 推挽输出

推挽输出可以主动把引脚拉高，也可以主动拉低。控制 LED、片选、普通数字控制线时通常使用这种模式。

```text
        VDD
         │
      上管
         │
GPIO ────┤
         │
      下管
         │
        GND
```

输出 1 时，上拉驱动导通，引脚接近 VDD；输出 0 时，下拉驱动导通，引脚接近 GND。具体输出电压、允许电流和压降要看数据手册，不能把 GPIO 当成电源使用。

SPL 配置：

```c
GPIO_InitTypeDef gpio;
GPIO_StructInit(&gpio);

gpio.GPIO_Pin = GPIO_Pin_5;
gpio.GPIO_Mode = GPIO_Mode_Out_PP;
gpio.GPIO_Speed = GPIO_Speed_2MHz;
GPIO_Init(GPIOB, &gpio);
```

`GPIO_Speed` 控制输出驱动速度等级。LED、片选这类低速信号通常没有必要选 50 MHz；较慢的边沿还能减少不必要的 EMI 和瞬态电流。

## 3.3 开漏输出

开漏输出只有下拉驱动。写 0 时，引脚被拉到 GND；写 1 时，下拉管关闭，引脚进入高阻状态，需要外部上拉电阻产生高电平。

```text
3.3V
  │
 上拉电阻
  │
  ├──── GPIO
  │       │
  │      下拉管
  │       │
  └────── GND
```

这种结构适合多个器件共享一根线。只要任意一个器件把线拉低，整根线就是低电平；所有器件都释放后，上拉电阻才把线拉高。I2C 的 SDA 和 SCL 就使用这种电气方式。

SPL 中普通开漏和复用开漏分别写成：

```c
gpio.GPIO_Mode = GPIO_Mode_Out_OD;
gpio.GPIO_Mode = GPIO_Mode_AF_OD;
```

开漏不等于“可以安全接 5V”。上拉电压必须符合 MCU 引脚和总线上所有器件的数据手册。书里的实验默认使用 3.3V 上拉。

## 3.4 复用输出

USART、SPI、定时器等外设需要直接控制引脚时，GPIO 要配置成复用模式。

USART TX、SPI SCK/MOSI、定时器 PWM 常用复用推挽：

```c
gpio.GPIO_Mode = GPIO_Mode_AF_PP;
```

I2C SCL/SDA 使用复用开漏：

```c
gpio.GPIO_Mode = GPIO_Mode_AF_OD;
```

配置成复用模式后，输出电平由对应外设控制。比如 PA9 配成 USART1_TX 后，发送数据时由 USART 外设产生高低电平，不需要业务代码再手动写 GPIO ODR。

## 3.5 输入模式

### 浮空输入

`GPIO_Mode_IN_FLOATING` 不启用内部上拉或下拉。引脚电平完全由外部电路决定。

```c
gpio.GPIO_Pin = GPIO_Pin_10;
gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
GPIO_Init(GPIOA, &gpio);
```

USART RX 这类由外部芯片持续驱动的信号可以使用浮空输入。没有外部驱动时，浮空脚电平不确定，不能拿来直接接按键。

### 上拉和下拉输入

STM32F1 的上拉/下拉输入都使用同一个 GPIO 配置编码。SPL 用两个模式名把它们区分开：

```c
gpio.GPIO_Mode = GPIO_Mode_IPU;   // 内部上拉
gpio.GPIO_Mode = GPIO_Mode_IPD;   // 内部下拉
```

底层配置 CRL/CRH 后，还会用对应 ODR 位选择上拉还是下拉。也就是说，在 F1 上，输入上拉/下拉和 ODR 有直接关系；这和后续一些 STM32 系列使用独立 PUPDR 寄存器的做法不同。

如果按键一端接 GND，通常使用内部上拉：

```text
未按下：内部上拉 → IDR 读 1
按下：   按键接地 → IDR 读 0
```

### 模拟输入

ADC 输入应该配置为 `GPIO_Mode_AIN`：

```c
gpio.GPIO_Pin = GPIO_Pin_0;
gpio.GPIO_Mode = GPIO_Mode_AIN;
GPIO_Init(GPIOA, &gpio);
```

模拟模式关闭数字输入路径，避免数字输入缓冲对模拟采样增加不必要的功耗和干扰。第 10 章讲 ADC 时会继续使用这个配置。

## 3.6 先点亮一个外接 LED

下面用 PB5 做一个独立实验。它只是外接测试引脚，不代表你的板载 LED 一定接 PB5。

假设 LED 阳极通过限流电阻接 3.3V，阴极接 PB5，那么 PB5 输出低电平时 LED 亮，输出高电平时 LED 灭。

```c
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

static void Led_Init(void)
{
    GPIO_InitTypeDef gpio;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_5;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_SetBits(GPIOB, GPIO_Pin_5);  /* 默认灭 */
}
```

控制函数：

```c
static void Led_On(void)
{
    GPIO_ResetBits(GPIOB, GPIO_Pin_5);
}

static void Led_Off(void)
{
    GPIO_SetBits(GPIOB, GPIO_Pin_5);
}
```

如果你的 LED 是高电平点亮，逻辑正好相反。板载 LED 继续通过 `board.h` 统一处理有效电平，不要把某块板的接法写死到业务代码里。

## 3.7 SPL 到底改了哪些寄存器

GPIOB Pin 5 位于 CRL。每个引脚占 4 位，因此 PB5 对应 CRL 的 bit 23:20。

推挽输出、2 MHz 的配置为：

```text
CNF  = 00
MODE = 10
```

等价寄存器操作可以写成：

```c
GPIOB->CRL &= ~(0xFU << 20);
GPIOB->CRL |=  (0x2U << 20);
```

SPL 的 `GPIO_Init()` 会遍历 `GPIO_Pin` 中选中的位，再更新 CRL 或 CRH。用库函数可以少写掩码，但最终仍然是这些寄存器操作。

时钟使能同样如此：

```c
RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
```

最终会修改 RCC 的 APB2 外设时钟使能寄存器，把 IOPBEN 对应位置 1。没有打开 GPIOB 时钟时，不能依赖对 GPIOB 寄存器的访问产生预期效果。

## 3.8 ODR、BSRR 和 BRR

ODR 保存输出锁存值。你可以直接写它：

```c
GPIOB->ODR |= GPIO_Pin_5;
GPIOB->ODR &= ~GPIO_Pin_5;
```

但这两句都是读—改—写。程序先读取整个 ODR，修改其中一位，再写回整个寄存器。如果中断或其他代码也在修改同一个 GPIO 端口，就可能覆盖对方刚写入的位。

设置单个位时优先使用 BSRR/BRR。STM32F1 SPL 的实现是：

```c
GPIO_SetBits(GPIOB, GPIO_Pin_5);    /* 写 BSRR */
GPIO_ResetBits(GPIOB, GPIO_Pin_5);  /* 写 BRR  */
```

BSRR 的低 16 位用于置位，对应位置写 1 就把 ODR 置 1。BRR 的低 16 位用于复位，对应位置写 1 就把 ODR 清 0。这两种操作都不需要先读 ODR。

直接寄存器写法：

```c
GPIOB->BSRR = GPIO_Pin_5;
GPIOB->BRR  = GPIO_Pin_5;
```

有些 STM32 系列把置位和复位都放在 32 位 BSRR 里，高 16 位负责复位。这里讲的是 STM32F1 及本书使用的 SPL 实现，阅读其他系列代码时要重新查对应参考手册。

## 3.9 纯寄存器方式点灯

把上面的初始化改成直接写寄存器：

```c
#define GPIOB_BASE   0x40010C00UL
#define RCC_BASE     0x40021000UL

#define GPIOB_CRL    (*(volatile uint32_t *)(GPIOB_BASE + 0x00U))
#define GPIOB_BSRR   (*(volatile uint32_t *)(GPIOB_BASE + 0x10U))
#define GPIOB_BRR    (*(volatile uint32_t *)(GPIOB_BASE + 0x14U))
#define RCC_APB2ENR  (*(volatile uint32_t *)(RCC_BASE + 0x18U))

static void RegLed_Init(void)
{
    RCC_APB2ENR |= (1U << 3);       /* IOPBEN */

    GPIOB_CRL &= ~(0xFU << 20);
    GPIOB_CRL |=  (0x2U << 20);     /* 推挽输出，2 MHz */

    GPIOB_BSRR = (1U << 5);         /* 默认高电平 */
}

static void RegLed_On(void)
{
    GPIOB_BRR = (1U << 5);
}

static void RegLed_Off(void)
{
    GPIOB_BSRR = (1U << 5);
}
```

对应的 SPL 版本：

```c
static void SplLed_Init(void)
{
    GPIO_InitTypeDef gpio;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_5;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_SetBits(GPIOB, GPIO_Pin_5);
}
```

两种写法操作的是同一套硬件。学习阶段可以通过寄存器版理解底层结构，项目代码优先选择可读性更好的写法；需要直接处理特定寄存器行为时再下到寄存器层。

不要用固定的“多占多少字节”评价 SPL。函数是否内联、链接优化、`--gc-sections` 和编译选项都会改变最终代码大小，应该以实际 ELF 和 MAP 文件为准。

## 3.10 读取按键

假设外接按键一端接 PA0，另一端接 GND。PA0 使用内部上拉：

```c
static void Key_Init(void)
{
    GPIO_InitTypeDef gpio;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IPU;
    GPIO_Init(GPIOA, &gpio);
}

static uint8_t Key_Read(void)
{
    return GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0);
}
```

未按下时返回 1，按下时返回 0。先用最简单的轮询验证接线：

```c
while (1) {
    if (Key_Read() == Bit_RESET)
        BoardLed_Write(1U);
    else
        BoardLed_Write(0U);
}
```

如果不按键时输入值不断变化，优先检查输入是不是浮空、按键有没有真正接到 GND，以及代码配置的端口和实际接线是否一致。

## 3.11 机械按键为什么会抖

机械触点闭合或断开的瞬间会发生弹跳。一次按下可能产生多次很短的高低电平变化，持续时间取决于具体按键，不能假定所有器件都是固定的 5 ms 或 20 ms。

```text
理想：  ─────────┐___________

实际：  ────────┐_┌─┐__┌____
                 └─┘ └──┘
```

主循环如果把每次电平变化都当成一次按键事件，就会出现一次按下被计算多次的问题。需要先确认电平已经稳定一段时间，再提交新的按键状态。

下面使用 30 ms 作为本实验的起始参数，实际产品应根据按键和采样结果调整。

```c
typedef struct {
    uint8_t raw;
    uint8_t stable;
    uint32_t changed_at;
} KeyDebouncer;

static KeyDebouncer key = {
    .raw = 1U,
    .stable = 1U,
    .changed_at = 0U,
};

static uint8_t Key_PollPressed(void)
{
    uint8_t sample = GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0);
    uint32_t now = Timebase_NowMs();

    if (sample != key.raw) {
        key.raw = sample;
        key.changed_at = now;
    }

    if (key.raw != key.stable &&
        (uint32_t)(now - key.changed_at) >= 30U) {
        uint8_t old = key.stable;
        key.stable = key.raw;

        if (old == 1U && key.stable == 0U)
            return 1U;
    }

    return 0U;
}
```

这段代码没有在检测到按键后原地 `Delay_ms(30)`。主循环可以继续处理其他任务，只要周期性调用 `Key_PollPressed()` 即可。第 5 章会完整建立毫秒时基，第 6 章会继续讲中断和事件交接。

## 3.12 按键切换 LED 状态

有了稳定的“按下一次”事件，就可以让 LED 在灭、亮、闪烁之间切换：

```c
typedef enum {
    MODE_OFF,
    MODE_ON,
    MODE_BLINK
} LedMode;

int main(void)
{
    LedMode mode = MODE_OFF;
    uint32_t last_blink = 0U;
    uint8_t led_on = 0U;

    BoardLed_Init();
    Key_Init();

    while (1) {
        uint32_t now = Timebase_NowMs();

        if (Key_PollPressed())
            mode = (LedMode)((mode + 1) % 3);

        switch (mode) {
        case MODE_OFF:
            led_on = 0U;
            BoardLed_Write(0U);
            break;

        case MODE_ON:
            led_on = 1U;
            BoardLed_Write(1U);
            break;

        case MODE_BLINK:
            if ((uint32_t)(now - last_blink) >= 500U) {
                led_on ^= 1U;
                BoardLed_Write(led_on);
                last_blink = now;
            }
            break;
        }
    }
}
```

如果你的板载按键不在 PA0，不要直接改这个示例里的假设去“碰运气”。先查原理图，再把板级事实放进 `board.h` 或对应板级文件。

## 3.13 多个 LED

如果手头有 4 个外接 LED，可以分别经限流电阻接到 PB0–PB3，练习一次配置多个引脚：

```c
#define LED_PORT GPIOB
#define LED_PINS (GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2 | GPIO_Pin_3)

static void Leds_Init(void)
{
    GPIO_InitTypeDef gpio;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = LED_PINS;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_SetBits(GPIOB, LED_PINS);
}
```

假设 LED 阳极经电阻接 3.3V、阴极接 GPIO，可以依次拉低各引脚：

```c
const uint16_t pin_order[] = {
    GPIO_Pin_0,
    GPIO_Pin_1,
    GPIO_Pin_2,
    GPIO_Pin_3,
};

while (1) {
    for (uint32_t i = 0U; i < 4U; ++i) {
        GPIO_ResetBits(GPIOB, pin_order[i]);
        Delay_ms(200U);
        GPIO_SetBits(GPIOB, pin_order[i]);
    }
}
```

PB0–PB3 后面还可能用于定时器、ADC 或其他实验。接外部模块之前先看 [板卡资源约定](./board-zet6-profile.md)，避免一个引脚同时接两个会主动驱动的设备。

## 3.14 常见问题

LED 逻辑相反：先确认 LED 是高电平还是低电平点亮。板载 LED 的有效电平由具体电路决定。

GPIO 没有变化：检查 GPIO 端口时钟、端口号、引脚号和当前复用功能。PA13、PA14 默认用于 SWD，调试阶段不要随意占用。

按键随机触发：检查输入是否浮空，上拉/下拉方向是否和实际接法一致。按键接 GND 时，内部上拉是最常见的配置。

开漏输出一直是低电平：检查外部上拉是否存在，以及上拉电压是否正确。开漏释放后不会自己主动输出高电平。

同一端口偶尔出现其他位被改：检查有没有对 ODR 做读—改—写，同时 ISR 或其他模块也在写该端口。单位置位和复位优先使用 BSRR/BRR。

外接 LED 不亮：量 GPIO 实际电压，再查 LED 极性、限流电阻和 GND。不要只根据代码推断引脚已经变化。

## 3.15 验收和练习

完成这一章后，至少做下面几项：

1. 用 SPL 配置一个推挽输出，用万用表测出高、低两个电平。
2. 用内部上拉读取一个接 GND 的按键，确认未按为 1、按下为 0。
3. 在 `stm32f10x_gpio.c` 中找到 `GPIO_Init()`、`GPIO_SetBits()` 和 `GPIO_ResetBits()`，确认它们分别操作哪些寄存器。
4. 用 GDB 查看 GPIO 的 CRL/CRH、IDR、ODR、BSRR 或 BRR，至少观察一个寄存器随程序变化。
5. 把一个输出改成开漏，加 3.3V 外部上拉，再测写 0 和写 1 时的实际电压。

这一章需要记住的寄存器只有几类：CRL/CRH 配模式，IDR 读输入，ODR 保存输出值，BSRR/BRR负责单位置位和复位。后面 USART、SPI、I2C、定时器的引脚配置都会继续建立在这些规则上。

> **上一章**：[第 2 章 · STM32F103 硬件概览](./02-chapter.md)
>
> **下一章**：[第 4 章 · C 语言嵌入式视角回顾（SPL版）](./04-chapter.md)

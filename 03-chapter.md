# 第 3 章 · GPIO 与寄存器编程（SPL版）

> **本章产出**：用 SPL 函数 + 纯寄存器两种方式控制 GPIO、驱动流水灯、驱动按键输入并理解消抖
>
> **用到项目的哪里**：GPIO 是嵌入式开发的起点——LED、按键、继电器、蜂鸣器、片选信号，所有项目的第一步都要配 GPIO

---

## 3.1 GPIO 硬件结构

STM32 的每个 GPIO 引脚内部结构：

```
引脚 (I/O Pin)
      │
      ├──→ 输入驱动器 ──→ 施密特触发器 ──→ 输入数据寄存器 (IDR)
      │         │
      │    上拉电阻 (～40kΩ) ──→ VDD
      │    下拉电阻 (～40kΩ) ──→ GND
      │
      └──← 输出驱动器 ←── 输出数据寄存器 (ODR) 或 位设置/复位寄存器 (BSRR)
                │
           推挽 (Push-Pull)：能输出高低电平
           开漏 (Open-Drain)：只能输出低电平或高阻态，需要外部上拉
```

### 推挽 vs 开漏

| 模式 | 类比 | 用途 |
|------|------|------|
| **推挽** | 两个开关：一个接 VDD，一个接 GND，同一时间只闭合一个 | 驱动 LED、控制大多数外设 |
| **开漏** | 只有一个开关接 GND，高电平时断开（高阻态） | I2C 总线（线与逻辑）、多设备共享一根线 |

内部上下拉电阻：当引脚配置为输入且外部悬空时，上拉（Pull-Up）默认读到 1，下拉（Pull-Down）默认读到 0。按键通常用上拉——未按下被拉到高电平，按下时接地变低。

## 3.2 寄存器——SPL 背后的真实硬件

以 GPIOB 为例（基地址 `0x4001_0C00`）：

| 寄存器 | 偏移 | 作用 |
|--------|------|------|
| **CRL** | 0x00 | 配置 Pin0-Pin7（每引脚 4 位） |
| **CRH** | 0x04 | 配置 Pin8-Pin15 |
| **IDR** | 0x08 | 读输入电平 |
| **ODR** | 0x0C | 设置输出电平 |
| **BSRR** | 0x10 | 原子位操作——写 1 置位/复位，写 0 无效 |
| **BRR** | 0x14 | 写 1 清除 ODR 对应位 |

### CRL/CRH：模式配置

每引脚 4 位（CNF[1:0] + MODE[1:0]）：

```
MODE[1:0]（低 2 位）：
   00 = 输入
   01 = 输出，最大 10MHz
   10 = 输出，最大 2MHz
   11 = 输出，最大 50MHz ← LED/普通外设用这个

CNF[1:0]（高 2 位）：
   输入模式下：00=模拟, 01=浮空, 10=上拉/下拉, 11=保留
   输出模式下：00=推挽, 01=开漏, 10=复用推挽, 11=复用开漏
```

**例子**：把 PB5 配成 50MHz 推挽输出。PB5 在 CRL 里占 bits[23:20]，CNF=00（推挽），MODE=11（50MHz）→ 写入 `0x0030_0000`。

### BSRR 为什么比 ODR 好

ODR 是「读-改-写」：读当前值 → 改一位 → 写回去。中断可能在读和写之间改了 ODR，你的写操作会覆盖中断的修改（竞态）。

BSRR 是纯写入：写 `1` 到低 16 位 → 对应 ODR 位置 1；写 `1` 到高 16 位 → 对应 ODR 位清零。写 `0` 无效果。这是**原子操作**，不需要读。

SPL 的 `GPIO_SetBits` / `GPIO_ResetBits` 就是操作 BSRR：

```c
GPIO_SetBits(GPIOB, GPIO_Pin_5);    // → GPIOB->BSRR = (1 << 5);     低 16 位置位
GPIO_ResetBits(GPIOB, GPIO_Pin_5);  // → GPIOB->BSRR = (1 << 21);    高 16 位复位
```

## 3.3 纯寄存器方式点灯（绕过 SPL）

理解 SPL 在做什么的最好方式——亲手写一遍寄存器版：

```c
// 定义 GPIOB 寄存器地址（不用 stm32f10x.h 里的宏）
#define GPIOB_BASE      0x40010C00UL
#define RCC_BASE        0x40021000UL
#define GPIOB_CRL       (*(volatile uint32_t *)(GPIOB_BASE + 0x00))
#define GPIOB_BSRR      (*(volatile uint32_t *)(GPIOB_BASE + 0x10))
#define RCC_APB2ENR     (*(volatile uint32_t *)(RCC_BASE + 0x18))

void reg_led_init(void) {
    RCC_APB2ENR |= (1 << 3);          // Bit 3 = IOPBEN：使能 GPIOB 时钟
    GPIOB_CRL &= ~(0xF << 20);        // 清除 PB5 的旧配置
    GPIOB_CRL |= (0x3 << 20);         // CNF=00(推挽), MODE=11(50MHz)
}

void reg_led_on(void)  { GPIOB_BSRR = (1 << 5);       }  // BS5 置位 → PB5 高
void reg_led_off(void) { GPIOB_BSRR = (1 << (5 + 16)); }  // BR5 复位 → PB5 低
```

对比 SPL 版：

```c
void spl_led_init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = GPIO_Pin_5;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOB, &gpio);
}
```

**SPL 的优势**：函数名就是中文注释、不用翻寄存器手册确认 bit 位、自动处理 &=`~` | `|=` 读改写。代价：结构体赋值 + 函数调用多约 20 字节 Flash。

**寄存器的优势**：你确知每一行在操作哪个寄存器的哪个位，没有黑箱。代价：可读性差、容易写错掩码。

**工程实践**：你的 SPL 工程里两种写法可以混用——`GPIO_SetBits` 比 `GPIOB->BSRR = ...` 意义更清晰，但写硬件驱动时直接操作寄存器更精确。不冲突。

## 3.4 SPL GPIO API 快速参考

| 功能 | SPL 函数 | 等效寄存器操作 |
|------|---------|--------------|
| 初始化 | `GPIO_Init(GPIOx, &cfg)` | 写 CRL/CRH |
| 输出高 | `GPIO_SetBits(GPIOx, Pin)` | 写 BSRR 低 16 位 |
| 输出低 | `GPIO_ResetBits(GPIOx, Pin)` | 写 BSRR 高 16 位 |
| 翻转（手动实现） | `GPIOx->ODR ^= Pin` | 异或 ODR |
| 读输入 | `GPIO_ReadInputDataBit(GPIOx, Pin)` | 读 IDR |
| 写整个端口 | `GPIO_Write(GPIOx, val)` | 写 ODR |

```c
// 翻转引脚（SPL 没有原生 Toggle，自己加一行宏）
#define GPIO_ToggleBits(GPIOx, Pin)  ((GPIOx)->ODR ^= (Pin))

GPIO_ToggleBits(GPIOB, GPIO_Pin_5);   // PB5 翻转
```

## 3.5 动手：流水灯

有了单 LED 的控制，扩展到多个——做个经典流水灯。

### 接线

将板载的多个 LED（或外接 LED 到 PB0-PB3）依次点亮：

| 引脚 | 颜色（依板子）|
|------|-------------|
| PB0 | 红 |
| PB1 | 绿 |
| PB2 | 蓝 |
| PB3 | 黄（或其他）|

普中玄武板上通常有 3-4 个可编程 LED，查原理图确认引脚。

### 代码

```c
#define LED_PORT  GPIOB
#define LED_PINS  (GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2 | GPIO_Pin_3)

void LED_All_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = LED_PINS;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(LED_PORT, &gpio);

    // 初始全灭（推挽输出默认高电平还是低电平要看电路设计）
    LED_PORT->ODR |= LED_PINS;
}
```

主循环：

```c
const uint8_t pin_order[] = {GPIO_Pin_0, GPIO_Pin_1, GPIO_Pin_2, GPIO_Pin_3};

while (1) {
    for (int i = 0; i < 4; i++) {
        GPIO_ResetBits(LED_PORT, pin_order[i]);     // 亮
        Delay_ms(200);                               // 保持
        GPIO_SetBits(LED_PORT, pin_order[i]);        // 灭
    }
}
```

LED 像水一样「流」过——这就是嵌入式初体验中最有成就感的 10 行代码。

> **如果只有一个 LED 或引脚不同**：用 `GPIO_ToggleBits` 配合 `Delay_ms` 做呼吸节奏也行。流水灯的思想是「一组引脚依次输出」——你学会了 `ODR` 批量操作。

---

## 3.6 动手：按键输入与消抖

### 3.6.1 最简单按键读取

先不关心抖动——先让 MCU「读到按键状态」：

```c
void Key_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA, ENABLE);

    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IPU;        // 输入 + 内部上拉
    GPIO_Init(GPIOA, &gpio);
}

uint8_t Key_Read(void) {
    return GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0);
}
```

最简单的「按键点灯」：

```c
while (1) {
    if (Key_Read() == 0)          // 按下
        GPIO_ResetBits(GPIOB, GPIO_Pin_5);   // 亮
    else
        GPIO_SetBits(GPIOB, GPIO_Pin_5);     // 灭
}
```

烧进去试试——大概率发现：**按一次 LED 闪烁多次、反应不灵敏、甚至按住时 LED 忽亮忽暗**。这就是下面要说的抖动问题。

### 3.6.2 按键的物理抖动

机械按键按下过程不是干净的电平变化：

```
理想波形（按下 -> 释放）：
    +------------------+         +--
    |                  |         |
----+                  +---------+

实际波形（按下 -> 释放）：
    + ++--++--+  +-+-+  ++-+
    |                   |
----+                   +--------
        抖动 5-20ms       抖动
```

机械触点在接触瞬间会弹跳几次——每次弹跳持续几微秒到几毫秒。CPU 跑 72MHz，几十微秒内能采样几百次——读到的不是干净的一次按下，而是一串 0 和 1 的交替。

### 3.6.3 软件消抖

思路：**检测到电平变化 -> 跳过抖动期（等 20-50ms）-> 再读一次确认**。

```c
uint8_t Key_Debounce(void) {
    static uint32_t last_tick = 0;
    static uint8_t  last_state = 1;     // 上拉初始 = 1

    uint8_t cur = GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0);

    // 状态变化：记录时间，暂不确认
    if (cur != last_state) {
        last_tick  = uwTick;            // SysTick 计数值，见第 5 章
        last_state = cur;
        return 0;
    }

    // 状态稳定超过 30ms -> 确认是有效按压（非抖动）
    if ((uwTick - last_tick) > 30) {
        if (cur == 0 && last_state == 0) {
            last_state = 2;             // 标记已处理
            return 1;                   // 确认为一次有效按下
        }
        if (cur == 1) last_state = 1;   // 释放后复位
    }
    return 0;
}
```

核心：不阻塞（`Delay_ms(30)` 会让 CPU 原地等 30ms——太浪费了），而是用 `uwTick` 计时。这就是第 6 章要讲的中断思路的雏形。

### 3.6.4 完整实验：按键切换 LED 模式

```c
typedef enum { MODE_OFF, MODE_ON, MODE_BLINK } led_mode_t;

int main(void) {
    LED_Init();         // GPIOB PB5
    Key_Init();         // GPIOA PA0

    led_mode_t mode = MODE_OFF;
    uint32_t last_blink = 0;

    while (1) {
        if (Key_Debounce()) {
            mode = (mode + 1) % 3;
        }

        switch (mode) {
        case MODE_OFF:
            GPIO_SetBits(GPIOB, GPIO_Pin_5);     // 灭
            break;
        case MODE_ON:
            GPIO_ResetBits(GPIOB, GPIO_Pin_5);   // 亮
            break;
        case MODE_BLINK:
            if (uwTick - last_blink > 500) {
                GPIO_ToggleBits(GPIOB, GPIO_Pin_5);
                last_blink = uwTick;
            }
            break;
        }
    }
}
```

**效果**：每按一次按键（确认一次有效按下，排除了抖动干扰），LED 在「灭 -> 常亮 -> 闪烁」之间循环切换。

### 使用场景

消抖不止在按键：继电器触点、拨码开关、限位开关——任何机械触点都有抖动。学会这个模式，你以后所有「接了一个物理开关」的场景都能套用。

---

## 3.7 GPIO_InitTypeDef 结构体解析

你每次调用 `GPIO_Init` 都要传一个 `GPIO_InitTypeDef`，它长这样：

```c
typedef struct {
    uint16_t GPIO_Pin;       // 选中哪些引脚（可多选，按位或: GPIO_Pin_5 | GPIO_Pin_6）
    GPIOSpeed_TypeDef GPIO_Speed; // 最大翻转速度: 10MHz / 2MHz / 50MHz
    GPIOMode_TypeDef GPIO_Mode;   // 模式: 输入/输出/复用等 8 种
} GPIO_InitTypeDef;
```

`GPIO_Init()` 内部做的事（简化版）：

```c
void GPIO_Init(GPIO_TypeDef *GPIOx, GPIO_InitTypeDef *cfg) {
    uint32_t pinpos, pos, curpin = 0;
    uint32_t tmpreg = 0;

    for (pinpos = 0; pinpos < 16; pinpos++) {
        curpin = cfg->GPIO_Pin & (1 << pinpos);
        if (curpin == 0) continue;

        // CRL 管 Pin0-7, CRH 管 Pin8-15
        if (pinpos < 8) {
            tmpreg = GPIOx->CRL;
            pos = pinpos * 4;  // 每引脚占 4 位
            tmpreg &= ~(0xF << pos);               // 清零旧值
            tmpreg |= (cfg->GPIO_Mode | cfg->GPIO_Speed) << pos;  // 写入新配置
            GPIOx->CRL = tmpreg;
        } else {
            // … CRH 同理
        }
    }
}
```

这就是 SPL 的「魔法」——它不是一个黑盒，而是一个你随时可以打开的 C 源文件。打开 `lib/stm32f10x_gpio.c` 看一眼，你会看到上面这些 for 循环和位操作。**不是编译器生成的，就是普通 C 代码。**

---

## 3.8 本章要点

- GPIO 推挽驱动 LED/按键，开漏用于 I2C；上拉给悬空引脚默认高电平
- CRL/CRH 配制模式，IDR 读输入，ODR/BSRR 写输出；BSRR 原子写优于 ODR
- SPL 的 `GPIO_Init` 本质是帮你填 CRL/CRH 寄存器——打开源文件就能看到，没有黑箱
- SPL 和纯寄存器方式**可以在同一工程混用**
- 按键消抖 = 检测变化 → 延迟 20-50ms → 确认稳定；用 `uwTick` 计时，不阻塞 CPU
- 使用任何 GPIO 前必须 `RCC_APB2PeriphClockCmd()` 使能对应时钟——忘了就全部不响应

---
> **上一章**：[第 2 章 · STM32F103 硬件概览](./02-chapter.md)

> **下一章**：[第 4 章 · C 语言嵌入式视角回顾（SPL版）](./04-chapter.md)
>
> 你刚才写了不少位操作和 `volatile`。我们停下来，系统回顾嵌入式 C——位运算、volatile 的深层含义、链接脚本、结构体映射寄存器的魔法。

---
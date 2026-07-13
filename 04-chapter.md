# 第 4 章 · C 语言嵌入式视角回顾（SPL版）

> **本章产出**：彻底理解位运算、`volatile`、`const` 在 Flash 中的行为、结构体映射寄存器、链接脚本
>
> **用到项目的哪里**：本章教的不是「知识点」，是「基本功」——后面每一行嵌入式 C 代码都会用到

---

## 这一章怎么读

这一章的内容跨度很大。对于“会写一些 C、但第一次接触硬件”的读者，建议分两层：

| 必须先掌握 | 可以第二遍再深入 |
|---|---|
| 位运算、volatile、指针映射寄存器 | 链接脚本细节、Mini-GPIO、1-Wire 时序 |
| 为什么 GPIO 寄存器地址能被 C 指针访问 | 启动文件与段布局的完整实现 |
| 为什么 const/全局变量会影响 RAM | 自己实现驱动库 |

先完成第 3 章的 GPIO 实验，再用本章解释“刚才那几行代码为什么真的控制了电路”。不要因为第一次看不懂链接脚本而停在这里。

## 4.1 位运算

嵌入式最频繁的操作不是加减乘除，是位操作。

### 六种基本位运算

```c
uint8_t a = 0b1010_1100;  // 172
uint8_t b = 0b1111_0000;  // 240

a & b   // 0b1010_0000  = 160  按位与：两个都是 1 才出 1
a | b   // 0b1111_1100  = 252  按位或：有一个是 1 就出 1
a ^ b   // 0b0101_1100  =  92  按位异或：不同出 1
~a      // 0b0101_0011  =  83  按位取反
a << 2  // 0b1011_0000  = 176  左移 2 位（相当于 ×4）
a >> 2  // 0b0010_1011  =  43  右移 2 位（相当于 ÷4）
```

### 嵌入式常用位操作模式

```c
/* 1. 置位 */
REG |= (1 << 5);      // 把第 5 位置 1，其他位不变

/* 2. 清零 */
REG &= ~(1 << 5);     // 把第 5 位清 0，其他位不变

/* 3. 翻转 */
REG ^= (1 << 5);      // 翻转第 5 位

/* 4. 检测 */
if (REG & (1 << 5)) { /* 第 5 位是 1 */ }

/* 5. 修改多位 */
REG &= ~(0x3 << 4);   // 先清除 bits[5:4]
REG |=  (0x2 << 4);   // 再写入 bits[5:4] = 10₂

/* 6. 提取位域 */
uint8_t val = (REG >> 4) & 0x3;  // 提取 bits[5:4] 并右移对齐
```

> **Java 对比**：Java 里你很少用位运算。嵌入式里位运算就是日常——你要直接操作硬件寄存器，没得选。

## 4.2 `volatile` ——编译器你别自作聪明

### 问题：这段代码有什么 bug？

```c
uint8_t *p = (uint8_t *)0x40010C08;  // GPIOB_IDR 的地址

*p = 1;     // 配置些什么
*p = 2;     // 再配置些什么

uint8_t val = *p;   // 读引脚状态——但编译器可能会跳过这次读！
```

优化级别 `-O2` 时，编译器发现 `*p` 刚被写过 2，就「优化」掉实际的硬件读操作，直接用缓存的值。但 `*p` 不是普通内存——它是硬件寄存器，值可能被外部电路改变。

### 解决：`volatile`

```c
volatile uint8_t *p = (volatile uint8_t *)0x40010C08;

*p = 1;   // 编译器：必须生成写指令
*p = 2;   // 编译器：必须生成写指令（不会优化掉上一个）

uint8_t val = *p;  // 编译器：必须真的去读硬件
```

`volatile` 告诉编译器：
- **每次读都从内存（硬件）重读，不用寄存器缓存**
- **每次写都真的写进去，不省略、不重排**
- **这个变量的值可能在编译器不知道的情况下改变**（硬件改的、中断改的）

### 你的 SPL 工程里随处可见 volatile

打开 `inc/stm32f10x.h`：

```c
typedef struct {
    volatile uint32_t CRL;     // ← 每个成员都是 volatile
    volatile uint32_t CRH;
    volatile uint32_t IDR;
    volatile uint32_t ODR;
    volatile uint32_t BSRR;
    volatile uint32_t BRR;
    volatile uint32_t LCKR;
} GPIO_TypeDef;
```

这就是为什么你写 `GPIOB->BSRR = (1 << 5)` 编译器一定生成写指令——因为 BSRR 是 `volatile` 的。SPL 替你加好了所有的 `volatile`。

### 什么时候必须加 volatile

| 场景 | 示例 |
|------|------|
| 硬件寄存器 | `#define GPIOB_ODR (*(volatile uint32_t *)0x40010C0C)` |
| 中断与主循环共享的变量 | `volatile uint8_t uart_data_ready;` // ISR 设 1，主循环检测 |
| FreeRTOS 任务间共享变量 | `volatile uint32_t sensor_value;` |
| 内存映射 I/O | 所有外设寄存器 |

### 什么时候不需要

普通局部变量、函数参数、只在单一上下文访问的变量——不需要。

## 4.3 `const` 与 Flash 存储

```c
const char    *msg1 = "Hello";   // 指向的内容是 const，指针可变
char *const    msg2 = buffer;    // 指针是 const，内容可变
const char *const msg3 = "Hi";   // 两者都是 const
```

在 STM32 中，`const` 全局变量被放在 `.rodata` 段（只读数据），**这个段在 Flash 中**，不占 SRAM！

```c
// 放在 Flash → 不占 RAM（你只有 64KB，不能浪费）
const uint16_t sine_table[256] = {
    2048, 2098, 2148, 2198, ...
};

// 放在 SRAM → 占 512 字节 RAM
uint16_t buffer[256];
```

**经验法则**：查找表、字模、常量字符串——加 `const`。SRAM 是稀缺资源。

## 4.4 指针与内存映射 —— 嵌入式 C 的核心魔法

> **把硬件寄存器的地址，当成指向特定类型变量的指针来用。**

```c
// GPIOB_ODR 是地址 0x40010C0C 上的 32 位寄存器
#define GPIOB_ODR (*(volatile uint32_t *)0x40010C0C)

// 拆开：
//   (volatile uint32_t *)0x40010C0C  → 把 0x40010C0C 解释为 volatile uint32_t 指针
//   *(volatile uint32_t *)0x40010C0C → 解引用：读或写那个地址

// 使用：
GPIOB_ODR = 0xFFFF;          // 写——GPIOB 所有引脚置高
uint32_t val = GPIOB_ODR;    // 读——获取当前引脚状态
```

**这在 Java 里不可想象**——Java 没有指针，也没有「某个地址上有硬件寄存器」这个概念。这是嵌入式最底层的思维模型。

## 4.5 `struct` 映射寄存器组

单个 `#define` 操作一个寄存器。要操作一整套（如 GPIO 的 CRL/CRH/IDR/ODR/BSRR/BRR/LCKR），用结构体：

```c
typedef struct {
    volatile uint32_t CRL;    // 偏移 0x00
    volatile uint32_t CRH;    // 偏移 0x04
    volatile uint32_t IDR;    // 偏移 0x08
    volatile uint32_t ODR;    // 偏移 0x0C
    volatile uint32_t BSRR;   // 偏移 0x10
    volatile uint32_t BRR;    // 偏移 0x14
    volatile uint32_t LCKR;   // 偏移 0x18
} GPIO_TypeDef;

#define GPIOB  ((GPIO_TypeDef *)0x40010C00)

// 现在可以这样用：
GPIOB->ODR  = 0xFFFF;    // 清晰、直观
GPIOB->BSRR = (1 << 5);  // 设置 PB5
```

**关键约束**：结构体成员的顺序必须和硬件寄存器的地址偏移严格一致。ARM 嵌入式 ABI 中同类型成员连续排列，编译器不会插入填充。

这就是你 `inc/stm32f10x.h` 里的内容——打开看看，你会看到 GPIO_TypeDef、USART_TypeDef、SPI_TypeDef……每一个外设都有对应的结构体。SPL 就建立在这些结构体之上。

## 4.6 链接脚本

你的工程里 `link.ld` 就是链接脚本。它定义内存布局和各段放哪里：

```ld
MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 512K
    RAM   (rw) : ORIGIN = 0x20000000, LENGTH = 64K
}

SECTIONS
{
    /* 中断向量表——必须在 Flash 最开头 */
    .isr_vector : {
        KEEP(*(.isr_vector))
    } > FLASH

    /* 代码 + 只读数据 */
    .text : {
        *(.text*)            /* 函数 */
        *(.rodata*)          /* const 全局数据——不走 RAM */
    } > FLASH

    /* 已初始化的全局变量——初值在 Flash，启动时由 Reset_Handler 复制到 RAM */
    .data : {
        _sdata = .;
        *(.data*)
        _edata = .;
    } > RAM AT > FLASH
    _sidata = LOADADDR(.data);

    /* 零初始化全局变量——启动时由 Reset_Handler 清零 */
    .bss : {
        _sbss = .;
        *(.bss*)
        _ebss = .;
    } > RAM
}
```

| 段 | 存什么 | 在哪 | 启动时 |
|----|--------|------|--------|
| `.text` | 你的代码 | Flash | 直接执行 |
| `.rodata` | `const` 数据、字符串常量 | Flash | 直接读 |
| `.data` | `int x = 5;` 这种有初值的全局变量 | 初值存 Flash，运行时复制到 RAM | `Reset_Handler` 逐字节复制 |
| `.bss` | `int y;` 这种无初值的全局变量 | RAM | `Reset_Handler` 清零 |
| 栈 | 局部变量、函数调用帧 | RAM（`.bss` 之后，向低地址长） | 动态分配 |
| 堆 | `malloc` 分配的内存 | RAM（另一头向高地址长） | 动态分配 |

```
RAM 布局（64KB ZET6）：
低地址 ┌──────────┐
       │  .data   │  已初始化全局变量
       ├──────────┤
       │  .bss    │  零初始化的全局变量
       ├──────────┤
       │   堆 →   │  malloc 的
       │  ← 栈    │  局部变量
高地址 └──────────┘
```

**栈溢出是嵌入式最常见的 bug**——堆和栈碰上了就 Hard Fault。写代码时始终在想「这个变量在 Flash 还是 RAM」。

## 4.7 动手：实现你自己的 Mini-GPIO 库

用刚学的知识，封一个不依赖 SPL 的微型 GPIO 库：

```c
/* mygpio.h */
typedef struct {
    volatile uint32_t CRL, CRH, IDR, ODR, BSRR, BRR, LCKR;
} MyGPIO;

#define MY_GPIOB  ((MyGPIO *)0x40010C00)
#define MY_GPIOE  ((MyGPIO *)0x40011800)

void MyGPIO_Init(MyGPIO *gpio, uint8_t pin, uint8_t mode);
void MyGPIO_Set(MyGPIO *gpio, uint8_t pin);
void MyGPIO_Reset(MyGPIO *gpio, uint8_t pin);
void MyGPIO_Toggle(MyGPIO *gpio, uint8_t pin);
uint8_t MyGPIO_Read(MyGPIO *gpio, uint8_t pin);
```

```c
/* mygpio.c */
#include "mygpio.h"

void MyGPIO_Init(MyGPIO *gpio, uint8_t pin, uint8_t mode) {
    // mode: 0=输入, 3=50MHz推挽输出
    volatile uint32_t *cr = (pin < 8) ? &gpio->CRL : &gpio->CRH;
    uint8_t pos = (pin % 8) * 4;
    *cr &= ~(0xF << pos);
    *cr |= (mode << pos);
}

void MyGPIO_Set(MyGPIO *gpio, uint8_t pin) {
    gpio->BSRR = (1 << pin);           // 低 16 位：置位
}

void MyGPIO_Reset(MyGPIO *gpio, uint8_t pin) {
    gpio->BSRR = (1 << (pin + 16));    // 高 16 位：复位
}

void MyGPIO_Toggle(MyGPIO *gpio, uint8_t pin) {
    gpio->ODR ^= (1 << pin);
}

uint8_t MyGPIO_Read(MyGPIO *gpio, uint8_t pin) {
    return (gpio->IDR >> pin) & 0x1;
}
```

使用：

```c
MyGPIO_Init(MY_GPIOB, 5, 3);   // PB5 50MHz 推挽输出
MyGPIO_Set(MY_GPIOB, 5);       // PB5 高电平
MyGPIO_Reset(MY_GPIOB, 5);     // PB5 低电平
```

**这就是 SPL 的微型复刻**。SPL 比这个多出来的东西：所有外设的结构体定义、完整的模式枚举、错误检查（`assert_param`）、更丰富的配置选项。但核心原理就是指针 + 结构体 + 位操作。

---

## 4.8 动手：单总线（1-Wire）与 DS18B20 / DHT11

普中玄武板通过板载接口外接 DHT11 和 DS18B20 两个传感器。DS18B20 本体是裸露的 TO-92 封装元件，直接插在板上的 4 针座子上；DHT11 自带一块小 PCB 板，引出 VCC、GND、DATA 三根线。它们都用**单总线（1-Wire）协议**——这是你能用 GPIO 实现的最简单的通信协议。

### 单总线通信：一根 GPIO 怎么又发又收

I2C 是两根线，SPI 是三根线——1-Wire 只有**一根数据线**。没有时钟线，不上拉时默认高电平。

```
一根线又当爹又当妈：
主机（MCU）─────┬────── 从机（DS18B20 或 DHT11）
                │
             4.7kΩ 上拉到 3.3V（空闲高电平）
```

单总线的核心是**时序**——用脉冲的宽度表示 0 和 1：

```
写 1：┌────┐  ──────────  （拉低 ~6μs 后释放，总线自行变高）
      │    │
      └────┘

写 0：┌──────────────┐──  （拉低 ~60μs）
      │              │
      └──────────────┘

读    主机拉低 ~3μs → 释放 → 从机决定总线电平
      ┌──┐  ┌─────┐           ┌──┐  ┌─────┐
      │  │  │     │    ← 1    │  │  │  ← 0
      └──┘  └─────┘           └──┘  └──┘
```

关键在于 **微秒级的精确定时**。你不能用 `Delay_ms(1)`——太粗了。需要 `Delay_us(10)` 或纯 CPU 空转循环（用 NOP 指令数计算时间）。

### 延时微秒函数

```c
// 72MHz 下一条 NOP 约 14ns，粗略循环 10 次 ≈ 1μs
// （精确值不关键——只要时序在 DS18B20/DHT11 容差范围内就行）
void Delay_us(uint32_t us) {
    while (us--) {
        for (volatile uint8_t i = 0; i < 10; i++);  // volatile 防止编译器优化掉
    }
}
```

> 这个 `Delay_us` 精度不高——72MHz 下编译器优化级别会影响实际延时。这里先用着，第 5 章学了 SysTick 之后再回来升级成精确延时。

### 电气连接

| 传感器 | 形态 | 接线 | 说明 |
|--------|------|------|------|
| DS18B20 | 裸露 TO-92 本体，插板载 4 针座 | VCC → 3.3V, GND → GND, DQ → **PB0** | 单总线脚，板上自带 4.7kΩ 上拉 |
| DHT11 | 自带小 PCB 板，接座子或杜邦线 | VCC → 3.3V, GND → GND, DATA → **PB1** | 单总线脚，板上自带 4.7kΩ 上拉 |

板载接口已自带 4.7kΩ 上拉电阻——DS18B20 直接插到 4 针座子上即可，DHT11 小板的 VCC/GND/DATA 对应接到座子即可。查原理图确认具体引脚。

### DS18B20 读取温度

DS18B20 是达拉斯半导体的高精度数字温度传感器（±0.5°C）。通信流程：

```
1. 复位脉冲：主机拉低 480μs → 释放 → 从机拉低 60-240μs 回应存在脉冲
2. 发 ROM 命令：0xCC（跳过 ROM 搜索，只有一个 DS18B20 时用）
3. 发功能命令：0x44（启动温度转换）
4. 等待转换完成（~750ms）
5. 再次复位 → 发 0xCC → 发 0xBE（读暂存器）
6. 读 9 字节：温度值在 byte[0]（低 8 位）+ byte[1]（高 8 位）
```

```c
// ============================================================
// 引脚宏——把 GPIO 操作封装成"总线动作"
//
// 为什么不用 GPIO_SetBits(GPIOB, GPIO_Pin_0) 到处写？
//   - 如果以后要换引脚（比如从 PB0 换到 PC3），只需要改上面三行
//   - DQ_LOW() / DQ_HIGH() / DQ_READ() 读起来像"总线操作"，不是"寄存器操作"
//     语义更清晰：你在拉低总线、读总线，不是在操作某个 GPIO
// ============================================================
#define DQ_PORT     GPIOB
#define DQ_PIN      GPIO_Pin_0
#define DQ_LOW()    GPIO_ResetBits(DQ_PORT, DQ_PIN)        // 总线拉低 → 输出 0
#define DQ_HIGH()   GPIO_SetBits(DQ_PORT, DQ_PIN)           // 总线拉高 → 输出 1
#define DQ_READ()   GPIO_ReadInputDataBit(DQ_PORT, DQ_PIN)  // 读总线当前电平

// ------------------------------------------------------------
// 复位 + 检测存在脉冲（Presence Pulse）
//
// 1-Wire 总线上每次通信前必须复位——就像打电话前先"喂"一声，
// 看对方在不在。
//
// 时序图：
//  主机拉低 ── 480μs ──→ 释放 ── 70μs ──→ 从机回应？── 410μs ──→ 结束
//                          │                   │
//                          │              ┌────┘
//                          │         从机拉低 60-240μs（存在脉冲）
//                          │              │
//                    上拉电阻拉高 ←─── 主机切换为输入
//
// 返回 1 = 检测到 DS18B20（从机拉低了总线）
// 返回 0 = 超时/未接（总线一直高）
// ------------------------------------------------------------
// 复位 + 检测存在
uint8_t DS18B20_Reset(void) {
    // ── 第 1 步：配置为推挽输出 ──
    // 复位时主机必须主动拉低总线，所以需要输出能力
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin  = DQ_PIN;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(DQ_PORT, &gpio);

    // ── 第 2 步：拉低 480μs（复位脉冲） ──
    // DS18B20 规格书要求：复位脉冲必须 ≥480μs，小于 960μs
    // 太短 → 从机不认；太长 → 可能被当成写 0 时序槽
    DQ_LOW();
    Delay_us(480);

    // ── 第 3 步：释放总线 ──
    // 拉高 = 停止驱动，让上拉电阻把总线拉回高电平
    DQ_HIGH();
    Delay_us(70);        // 给从机 70μs 准备时间

    // ── 第 4 步：切为输入，等从机拉低 ──
    // 关键：只有切为输入，DS18B20 才能控制总线电平
    // 如果保持输出模式，主机一直在强推高电平，从机根本拉不动
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(10);

    // ── 第 5 步：读电平判断是否存在 ──
    // DS18B20 检测到复位脉冲后，会在 60-240μs 内拉低总线
    // 读到低电平（0）→ 从机存在；读到高电平（1）→ 没设备
    uint8_t presence = (DQ_READ() == 0) ? 1 : 0;
    Delay_us(410);  // 等剩余存在脉冲走完，保持时序完整

    // ── 第 6 步：切回输出，为后续读写做准备 ──
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(DQ_PORT, &gpio);

    return presence;
}

// ------------------------------------------------------------
// 写一个位 —— 用脉冲宽度表示 0 还是 1
//
// 1-Wire 的写时序槽（Write Slot）：
//
//         写 1                         写 0
//   ┌──┐                       ┌──────────────┐
//   │  │  ← 拉低 ~2μs          │              │  ← 持续低 60μs
//   └──┴────── 然后释放 ──→    └──────────────┘
//   ↑                          ↑
//   起始信号                    起始信号
//   （主机拉低，宣告        （主机一直保持低电平，
//    这是一个时序槽）         直到结束时才释放）
//
// 区别在于：写 1 在起始信号后释放总线，让上拉电阻拉高；
//          写 0 则一直保持低电平，直到时序槽结束。
// 从机在 15-60μs 之间采样总线电平来判断 0 或 1。
// ------------------------------------------------------------
void DS18B20_WriteBit(uint8_t bit) {
    // 起始信号：所有时序槽都以主机拉低开始
    DQ_LOW();
    Delay_us(2);

    if (bit) {
        // 写 1：拉低 2μs 后就释放 → 上拉电阻把总线拉高
        DQ_HIGH();
        Delay_us(60);
    } else {
        // 写 0：继续保持低电平 60μs
        Delay_us(60);
        DQ_HIGH();  // 结束，释放总线
    }
}

// ------------------------------------------------------------
// 读一个位 —— 主机发起，从机回应
//
// 读时序槽（Read Slot）和写时序槽很像，但方向反了：
//
//     主机拉低 ─→ 释放 ─→ 从机控制总线
//     ┌──┐         ┌─────┐               ┌──┐         ┌─────┐
//     │  │         │     │  ← 从机输出 1  │  │         │     │  ← 从机输出 0
//     └──┴─────────┘     └──────────       └──┴─────────┘     └────
//       2μs  释放        从机控制期          2μs  释放        从机控制期
//                            ↑                                ↑
//                      主机在第 15μs 采样                 主机采样到低电平
//
// 核心思路：主机只负责"发起时序"，然后立即释放总线（切为输入），
// 让 DS18B20 来决定总线电平。读到的值就是 DS18B20 想说的。
// ------------------------------------------------------------
uint8_t DS18B20_ReadBit(void) {
    uint8_t val = 0;

    // ── 发起时序 ──
    // 和写时序一样，先拉低几微秒宣告"我要开始一个读时序了"
    DQ_LOW();
    Delay_us(2);

    // ── 释放总线 ──
    // 拉高后马上切输入——从此刻起总线由 DS18B20 控制
    DQ_HIGH();
    Delay_us(2);      // 给从机一点时间响应

    // 切为输入，不再驱动总线
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin  = DQ_PIN;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(1);

    // ── 采样 ──
    // 现在读到的电平就是 DS18B20 输出的位：
    //   从机写 1 → 释放总线，上拉电阻拉高，读到 1
    //   从机写 0 → 主动拉低，读到 0
    val = DQ_READ();

    // ── 切回输出，为下一轮操作做准备 ──
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(55);     // 等剩余时序槽走完

    return val;
}

// ------------------------------------------------------------
// 写一个字节 —— 8 位，最低位先发
//
// 1-Wire 协议规定：字节传输必须 LSB（Least Significant Bit）先行，
// 也就是先发 bit 0，再发 bit 1……最后发 bit 7。
//
// 这和人们习惯的"从左到右"相反，但很多串行协议都这么干
// （UART 也是 LSB 先发），原因和移位寄存器的硬件实现有关。
//
// 举个例子：发送 0x53（0b0101_0011）：
//   发送顺序：1 → 1 → 0 → 0 → 1 → 0 → 1 → 0
//            ↑LSB                          ↑MSB
// ------------------------------------------------------------
void DS18B20_WriteByte(uint8_t byte) {
    // i=0 取 bit 0，i=1 取 bit 1……逐位移出
    for (uint8_t i = 0; i < 8; i++) {
        DS18B20_WriteBit(byte & (1 << i));
        // 注意是 (1 << i) 而不是 (1 << (7-i))——因为 LSB 先行
    }
}

// ------------------------------------------------------------
// 读一个字节 —— 同样 LSB 先行
//
// 和写对称：先收到的位是最低位，逐位移到最高位。
//   byte = bit0 | (bit1<<1) | (bit2<<2) | ... | (bit7<<7)
// ------------------------------------------------------------
uint8_t DS18B20_ReadByte(void) {
    uint8_t byte = 0;
    for (uint8_t i = 0; i < 8; i++) {
        if (DS18B20_ReadBit()) {
            byte |= (1 << i);   // 第 i 位是 1 → 置位
        }
        // 读到 0 的话不用动，byte 那一位初始化就是 0
    }
    return byte;
}

// ------------------------------------------------------------
// 读取温度 —— 从 DS18B20 拿到的原始值转摄氏温度
//
// 通信步骤：
//   1. 复位 → 发 0xCC（跳过 ROM）→ 发 0x44（启动转换）
//   2. 等待 750ms（DS18B20 完成温度测量）
//   3. 复位 → 发 0xCC → 发 0xBE（读暂存器）
//   4. 读低字节 + 高字节，拼成 16 位原始值
//
// 原始值格式（11 位有符号 + 4 位小数）：
//   bit[15:11] = 符号位（温度正负）
//   bit[10:4]  = 整数部分
//   bit[3:0]   = 小数部分（精度 1/16 = 0.0625°C）
//
// 所以：温度℃ = raw × 0.0625
// 即：raw ÷ 16
// ------------------------------------------------------------
float DS18B20_ReadTemp(void) {
    // ── 第 1 步：启动温度转换 ──
    DS18B20_Reset();            // 复位
    DS18B20_WriteByte(0xCC);    // 跳过 ROM——总线上只有一个 DS18B20
    DS18B20_WriteByte(0x44);    // 启动转换
    Delay_ms(750);              // 等 750ms（最大转换时间）

    // ── 第 2 步：读暂存器 ──
    DS18B20_Reset();            // 再次复位
    DS18B20_WriteByte(0xCC);    // 跳过 ROM
    DS18B20_WriteByte(0xBE);    // 读暂存器命令

    // 暂存器 byte[0] = 温度低 8 位，byte[1] = 温度高 8 位
    int16_t raw = DS18B20_ReadByte() | (DS18B20_ReadByte() << 8);

    // ── 第 3 步：转为摄氏温度 ──
    return raw * 0.0625f;       // 相当于 raw / 16
}
```

使用：

```c
if (DS18B20_Reset()) {
    float temp = DS18B20_ReadTemp();
    printf("DS18B20: %.2f°C\r\n", temp);
} else {
    printf("DS18B20 未连接\r\n");
}
```

### DHT11 读取温湿度

DHT11 比 DS18B20 更简单（精度更低但带湿度）。通信流程：

```
1. 主机拉低 ≥18ms（启动信号）→ 释放 → 上拉电阻拉高
2. 从机拉低 80μs → 拉高 80μs（响应信号）
3. 从机发送 40 位数据（每 1 位 = 50μs 低 + 26-28μs高=0 / 70μs高=1）
```

数据格式 = 8bit 湿度整数 + 8bit 湿度小数 + 8bit 温度整数 + 8bit 温度小数 + 8bit 校验和

```c
uint8_t DHT11_Read(uint8_t buf[5]) {
    // 启动信号：拉低 ≥18ms
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin   = GPIO_Pin_1;  // DHT11 在 PB1
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOB, &gpio);

    GPIO_ResetBits(GPIOB, GPIO_Pin_1);
    Delay_ms(20);                      // 拉低 20ms ≥ 18ms
    GPIO_SetBits(GPIOB, GPIO_Pin_1);  // 释放
    Delay_us(30);

    // 切输入，等从机响应
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOB, &gpio);

    // 等 DHT11 拉低（80μs）
    uint16_t timeout = 0;
    while (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_1))
        if (++timeout > 500) return 0;  // 超时

    // 等 DHT11 拉高（80μs）
    while (!GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_1))
        if (++timeout > 500) return 0;

    // 读 40 位
    for (uint8_t i = 0; i < 40; i++) {
        while (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_1) == 0);  // 等低结束
        Delay_us(40);  // 等 40μs
        // 此时如果在高电平区 → 看持续多久
        // 26-28μs = 0, 70μs = 1
        if (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_1))
            buf[i / 8] = (buf[i / 8] << 1) | 1;
        else
            buf[i / 8] = (buf[i / 8] << 1) | 0;
        while (GPIO_ReadInputDataBit(GPIOB, GPIO_Pin_1));  // 等高结束
    }

    // 校验和验证（前 4 字节和 = 第 5 字节）
    if ((uint8_t)(buf[0] + buf[1] + buf[2] + buf[3]) != buf[4])
        return 0;  // 校验失败

    return 1;  // 成功
}
```

读取：

```c
uint8_t data[5];
if (DHT11_Read(data)) {
    printf("湿度: %d.%d%%  温度: %d.%d°C\r\n",
           data[0], data[1], data[2], data[3]);
}
```

### 1-Wire vs I2C vs SPI 对比

| | 1-Wire | I2C | SPI |
|--------|--------|-----|-----|
| 信号线数 | **1**（DQ） | 2（SCL+SDA） | 3-4（SCK+MOSI+MISO+CS）|
| 速度 | 低速（~16kbps） | 100k-400kHz | 最高 18MHz |
| 时序要求 | **严格**（μs 级精确，CPU 空转） | 硬件外设自动处理 | 硬件外设自动处理 |
| 协议复杂度 | 简单（但实现繁琐） | 中等 | 简单 |
| 多设备支持 | 可级联（ROM 搜索复杂） | 地址区分 | 片选区分 |
| 嵌入式初学 | **非常适合**（逼你理解时序） | 一般（外设自动处理） | 一般（外设自动处理） |

**1-Wire 最底层的魅力**：你写 `DQ_LOW()` 的那一瞬间，就是在零延迟操作硅片上的晶体管。I2C/SPI 的硬件外设屏蔽了这些细节，但 1-Wire 让你**亲手触碰到物理层的每一次电压变化**。

这就是为什么把 1-Wire 放在 GPIO 之后、其他通信协议之前——它会彻底教会你「时序」这两个字意味着什么。

---

## 4.9 本章要点

- **位运算**是嵌入式日常：置位 `|=`，清零 `&= ~`，翻转 `^=`
- **`volatile`** 阻止编译器优化掉硬件读写——所有外设寄存器、中断共享变量都需要
- SPL 的 GPIO_TypeDef 结构体成员全部是 `volatile`，替你加好了
- **`const`** 把数据放 Flash，省 SRAM——查找表不加 const 是浪费
- **结构体 + 指针 = 寄存器映射**——这就是 SPL 和 HAL 共同的底层原理
- **链接脚本**：`.text/.rodata` 在 Flash，`.data/.bss` 在 RAM，栈和堆共享剩余 RAM
- 写嵌入式 C 时，始终在想「这个变量在 Flash 还是 SRAM」

---
> **上一章**：[第 3 章 · GPIO 与寄存器操作](./03-chapter.md)
> **下一章**：[第 5 章 · 时钟系统、SysTick 与精确延时（SPL版）](./05-chapter.md)
>
> 你现在有了精确的位操作能力。接下来给 MCU 配一个准确的心跳——系统时钟和 SysTick 定时器。

---


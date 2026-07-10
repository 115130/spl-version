# 第 4 章 · C 语言嵌入式视角回顾（SPL版）

> **本章产出**：彻底理解位运算、`volatile`、`const` 在 Flash 中的行为、结构体映射寄存器、链接脚本
>
> **用到项目的哪里**：本章教的不是「知识点」，是「基本功」——后面每一行嵌入式 C 代码都会用到

---

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

普中玄武板上焊着 DHT11（温湿度）和 DS18B20（精密温度）两个传感器。它们都用**单总线（1-Wire）协议**——这是你能用 GPIO 实现的最简单的通信协议。

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

| 传感器 | 引脚 | 接 STM32 |
|--------|------|---------|
| DS18B20 | VDD → 3.3V, GND → GND, DQ → **PB0** | 单总线脚，需 4.7kΩ 上拉 |
| DHT11 | VDD → 3.3V, GND → GND, DATA → **PB1** | 单总线脚，需 4.7kΩ 上拉 |

普中玄武板上的 DS18B20 和 DHT11 已经带好上拉电阻和 PCB 走线——你不需要额外接线，直接用 GPIO 控制对应的引脚就行。查原理图确认具体引脚。

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
// 单总线引脚宏（DS18B20 在 PB0）
#define DQ_PORT     GPIOB
#define DQ_PIN      GPIO_Pin_0
#define DQ_LOW()    GPIO_ResetBits(DQ_PORT, DQ_PIN)
#define DQ_HIGH()   GPIO_SetBits(DQ_PORT, DQ_PIN)
#define DQ_READ()   GPIO_ReadInputDataBit(DQ_PORT, DQ_PIN)

// 复位 + 检测存在
uint8_t DS18B20_Reset(void) {
    // 配为推挽输出
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin  = DQ_PIN;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(DQ_PORT, &gpio);

    DQ_LOW();
    Delay_us(480);       // 拉低 480μs
    DQ_HIGH();
    Delay_us(70);        // 等从机响应

    // 切换为输入（开漏模式）——让上拉电阻拉高总线
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(10);

    uint8_t presence = (DQ_READ() == 0) ? 1 : 0;  // 从机拉低 = 存在
    Delay_us(410);

    // 切回输出
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(DQ_PORT, &gpio);

    return presence;  // 1=检测到 DS18B20
}

// 写一个位
void DS18B20_WriteBit(uint8_t bit) {
    DQ_LOW();
    Delay_us(2);    // 起始信号
    if (bit) {
        DQ_HIGH();  // 写 1 → 拉高
        Delay_us(60);
    } else {
        Delay_us(60);  // 写 0 → 继续保持低
        DQ_HIGH();
    }
}

// 读一个位
uint8_t DS18B20_ReadBit(void) {
    uint8_t val = 0;
    DQ_LOW();
    Delay_us(2);      // 主机起始信号
    DQ_HIGH();
    Delay_us(2);      // 释放总线，等从机响应

    // 切换输入读电平
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin  = DQ_PIN;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(1);

    val = DQ_READ();   // 从机写 0 会拉低总线

    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(DQ_PORT, &gpio);
    Delay_us(55);

    return val;
}

// 写一个字节（LSB 先行）
void DS18B20_WriteByte(uint8_t byte) {
    for (uint8_t i = 0; i < 8; i++) {
        DS18B20_WriteBit(byte & (1 << i));
    }
}

// 读一个字节
uint8_t DS18B20_ReadByte(void) {
    uint8_t byte = 0;
    for (uint8_t i = 0; i < 8; i++) {
        if (DS18B20_ReadBit()) byte |= (1 << i);
    }
    return byte;
}

// 读取温度（摄氏度 × 16，转为浮点）
float DS18B20_ReadTemp(void) {
    DS18B20_Reset();
    DS18B20_WriteByte(0xCC);   // 跳过 ROM
    DS18B20_WriteByte(0x44);   // 启动转换
    Delay_ms(750);               // 等 750ms

    DS18B20_Reset();
    DS18B20_WriteByte(0xCC);   // 跳过 ROM
    DS18B20_WriteByte(0xBE);   // 读暂存器

    int16_t raw = DS18B20_ReadByte() | (DS18B20_ReadByte() << 8);
    return raw * 0.0625f;       // 分辨率 0.0625°C
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


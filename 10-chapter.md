# 第 10 章 · I2C 总线

> **本章产出**：能从 I2C 的电气规则、起止条件、ACK 和地址开始，稳定驱动一个 OLED、EEPROM 或传感器；总线出错时能判断是接线、上拉、地址还是状态机问题。
>
> **前置知识**：第 3、5、8 章；第 8 章 UART 用作 I2C 调试日志。
>
> **硬件准备**：3.3V I2C 模块、SCL/SDA 上拉电阻或带上拉的模块；不要把未知 5V I2C 信号直接连到 ZET6。

## 10.1 为什么需要总线

8 个传感器如果各用 3 根线，需要 24 根 GPIO。如果共享 2 根线——只需要 2 根。**I2C 就是这 2 根线的总线协议。**

### 物理层

```
SDA (数据) ──┬──┬──┬── ... ──┬── VDD (上拉电阻)
SCL (时钟) ──┼──┼──┼── ... ──┼── VDD (上拉电阻)
             │  │  │         │
          ┌──┴──┴──┴─┐    ┌──┴──┐
          │   MCU    │    │ 设备 │
          │  (主机)   │    │ (从机)│
          └──────────┘    └─────┘
```

两根线都需要**上拉电阻**（4.7kΩ→VDD）。I2C 用**开漏输出**——设备只能拉低，不能拉高。高电平由上拉电阻提供。为什么？多设备共享同一条线，推挽输出会导致短路。开漏确保「谁拉低谁赢」的**线与**逻辑。

### 速度

| 模式 | 速率 | 常用 |
|------|------|------|
| 标准 | 100kHz | 大多数传感器 |
| 快速 | 400kHz | OLED 屏 |
| Fm+ | 1MHz | 高速传输 |

STM32F103 支持标准和快速模式。

### 协议

```
起始条件 → 地址 + R/W → ACK → 数据 → ACK → ... → 停止条件

起始条件：SCL 高时 SDA 下降沿
停止条件：SCL 高时 SDA 上升沿
地址：7 位地址 + 1 位 R/W（0=写, 1=读）
ACK：第 9 个 SCL 脉冲，从机拉低 SDA 表示「收到」
```

常见 I2C 设备地址：SSD1306 OLED = 0x3C，AT24C02 EEPROM = 0x50。

---

### 10.1.5 I²C 外设的有限状态机

新手写 I²C 代码最困惑的就是——"为什么地址要左移一位？" 和 "`I2C_CheckEvent` 到底在等什么？"

#### ① 地址左移一位的真相

I²C 总线上传输的 **7 位地址**是裸地址，不包含 R/W 位。STM32 的 I²C 外设要求你把地址**左移 1 位**，最低位填 R/W：

```
I²C 设备地址 = 0x3C（7 位）

    7 位地址        R/W
┌──┬──┬──┬──┬──┬──┬──┬──┐
│ 0│ 1│ 1│ 1│ 1│ 0│ 0│ 0│      ← 0x3C << 1 = 0x78（写）
└──┴──┴──┴──┴──┴──┴──┴──┘
└──┬──┬──┬──┬──┬──┬──┘  ↑
   裸的 7 位地址         最后 1 位 = R/W

    0x78 = 写（R/W=0）
    0x79 = 读（R/W=1）
```

所以代码里写的：

```c
I2C_Send7bitAddress(I2C1, 0x3C << 1, I2C_Direction_Transmitter);
//                     ↑
//                 左移一位，填入 R/W 位
```

不是 STM32 故意设计得别扭——是因为 I²C 协议在线上传输的就是 8 位（7 位地址 + 1 位 R/W），STM32 外设只是如实反映了协议定义。

#### ② SPL I²C 的事件序列（有限状态机）

STM32 的 I²C 外设内部是一个**有限状态机**——它不会一次性帮你完成"发起始→发地址→发数据→收应答→发停止"这一整串操作。它每完成一步，就设一个事件标志等你检查。**你的代码必须逐个等这些事件，告诉外设"继续下一步"**。

以一个写操作为例，状态机跑过的状态：

```
主机写一字节到 I²C 从机的完整状态序列：

CPU 写 CR1_START=1
    │
    ▼
┌─────────────────────────────────┐
│ SB（Start Bit）= 1              │ ← 起始条件已发出
│ I2C_EVENT_MASTER_MODE_SELECT    │
│           ↓ CPU 读 SR1 清 SB    │
├─────────────────────────────────┤
│ ADDR（Address Sent）= 1         │ ← 地址+R/W 已发出，收到 ACK
│ I2C_EVENT_MASTER_TRANSMITTER    │
│    _MODE_SELECTED               │
│           ↓ CPU 读 SR1+SR2 清   │
├─────────────────────────────────┤
│ TXE（Data Register Empty）= 1   │ ← TDR 空，CPU 可以写数据
│ I2C_EVENT_MASTER_BYTE_TRANSMITT │
│    ING                          │
│           ↓ CPU 写 DR           │
├─────────────────────────────────┤
│ BTF（Byte Transfer Finished）   │ ← 一字节已发出，收到 ACK
│ I2C_EVENT_MASTER_BYTE_TRANSMITT │
│    ED                           │
│           ↓ CPU 写下一字节       │
├─────────────────────────────────┤
│ 重复或 CPU 写 STOP=1            │
│           ↓                     │
└─────────────────────────────────┘
```

所以 SPL 的 I²C 代码看起来像是在反复检查标志：

```c
void I2C_WriteByte(uint8_t dev_addr, uint8_t reg, uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);                        // 发起始
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECTED));  // 等 SB

    I2C_Send7bitAddress(I2C1, dev_addr << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));  // 等 ADDR

    I2C_SendData(I2C1, reg);                                // 写寄存器地址
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));  // 等 BTF

    I2C_SendData(I2C1, data);                               // 写数据
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));  // 等 BTF

    I2C_GenerateSTOP(I2C1, ENABLE);                         // 发停止
}
```

**每一个 `while` 都是在等 I²C 外设状态机走到下一步。** 你不等它，下一步的动作会失效，或者上一个动作还没完成就被覆盖了。

#### ③ 什么是时钟拉伸

I²C 从机有一个"刹车"机制——如果从机来不及处理收到的数据，会主动把 SCL **拉低**，强制主机等待：

```
正常情况下 SCL 由主机驱动：
主机 ──┬──┬──┬──┬──┬──┬──┬──  （主机控制 SCL 高低）
       │  │  │  │  │  │  │

从机来不及处理时，从机拉低 SCL：
主机 ──┬──┬──┬──┬──┬─────────
       │  │  │  │  │  ← 从机把 SCL 拉低不放
       └──┴──┴──┴──┘
                      └── 从机处理完了释放 SCL → 继续
```

STM32 的 I²C 外设**自动处理时钟拉伸**——硬件检测到 SCL 被拉低，就自动等待。你的代码不需要管这件事。但知道它的存在有助于你理解"为什么 I²C 上传一字节的时间不固定"。

#### ④ 错误场景：NACK

如果从机没收到数据（或根本不存这个地址），它会不发 ACK，即 SDA 在第 9 个 SCL 脉冲时继续保持高电平。STM32 外设此时会置 `AF`（Acknowledge Failure）标志：

```c
if (I2C_GetFlagStatus(I2C1, I2C_FLAG_AF) == SET) {
    // 从机没有响应！
    printf("I²C 设备无应答（地址 0x%02X）\r\n", dev_addr);
    I2C_ClearFlag(I2C1, I2C_FLAG_AF);
}
```

如果总线上根本没接那个设备、或者地址不对、或者接线断了，`I2C_CheckEvent` 就会一直等不到 ADDR 事件——程序卡死。所以工业代码里要么加超时，要么加 NACK 检测。

---

## 10.2 SPL I2C 初始化（SSD1306 OLED）

```c
#include "stm32f10x_i2c.h"

void I2C1_Init(void) {
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_I2C1, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);

    // PB6 = SCL, PB7 = SDA（复用开漏）
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin   = GPIO_Pin_6 | GPIO_Pin_7;
    gpio.GPIO_Mode  = GPIO_Mode_AF_OD;  // 开漏！
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOB, &gpio);

    I2C_InitTypeDef i2c;
    I2C_StructInit(&i2c);
    i2c.I2C_Mode              = I2C_Mode_I2C;
    i2c.I2C_ClockSpeed        = 400000;    // 快速模式 400kHz
    i2c.I2C_DutyCycle         = I2C_DutyCycle_2;
    i2c.I2C_Ack               = I2C_Ack_Enable;
    i2c.I2C_AcknowledgedAddress = I2C_AcknowledgedAddress_7bit;
    i2c.I2C_OwnAddress1       = 0x00;      // 主机模式不需要自己的地址
    I2C_Init(I2C1, &i2c);
    I2C_Cmd(I2C1, ENABLE);
}
```

### SPL I2C 写入（写命令/数据到 SSD1306）

### SPL I2C 写入（SSD1306 命令/数据）

SSD1306 OLED 用 I2C 发送时，需要区分**命令**和**数据**：

```c
// 发命令：reg=0x00, data=命令字节
void OLED_WriteCmd(uint8_t cmd) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0x3C << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, 0x00);              // 命令标识
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, cmd);               // 命令内容
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);
}

// 发数据：reg=0x40, data=显示像素
void OLED_WriteData(uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0x3C << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, 0x40);              // 数据标识
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, data);              // 像素数据
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);
}
```

---

## 10.3 动手：让 OLED 显示「Hello」

### 接线

SSD1306 OLED 模块（4 针 I2C 版，如果买了的话）接 PB6/PB7：

| OLED | STM32 |
|------|-------|
| VCC | 3.3V |
| GND | GND |
| SCL | PB6 (I2C1_SCL) |
| SDA | PB7 (I2C1_SDA) |

> 没有 OLED 也不影响——板载的 AT24C02 EEPROM 和 MPU6050 也是 I²C 设备，下面直接用它们做实验。

### SSD1306 初始化序列

每个外设芯片上电后都需要发一组配置命令：

```c
void OLED_Init(void) {
    Delay_ms(100);
    OLED_WriteCmd(0xAE);
    OLED_WriteCmd(0x20); OLED_WriteCmd(0x00);
    OLED_WriteCmd(0xC8);
    OLED_WriteCmd(0x81); OLED_WriteCmd(0xFF);
    OLED_WriteCmd(0xA1);
    OLED_WriteCmd(0xA8); OLED_WriteCmd(0x3F);
    OLED_WriteCmd(0xD5); OLED_WriteCmd(0xF0);
    OLED_WriteCmd(0xDA); OLED_WriteCmd(0x12);
    OLED_WriteCmd(0x8D); OLED_WriteCmd(0x14);
    OLED_WriteCmd(0xAF);
}
```

### 清屏

```c
void OLED_Clear(void) {
    for (uint8_t p = 0; p < 8; p++) {
        OLED_WriteCmd(0xB0 + p);
        OLED_WriteCmd(0x00); OLED_WriteCmd(0x10);
        for (uint8_t c = 0; c < 128; c++)
            OLED_WriteData(0x00);
    }
}
```

### 点亮全屏

```c
void OLED_Fill(uint8_t data) {
    for (uint8_t p = 0; p < 8; p++) {
        OLED_WriteCmd(0xB0 + p);
        OLED_WriteCmd(0x00); OLED_WriteCmd(0x10);
        for (uint8_t c = 0; c < 128; c++)
            OLED_WriteData(data);
    }
}

OLED_Fill(0xFF);  Delay_ms(500);
OLED_Fill(0x00);  Delay_ms(500);
OLED_Fill(0xF0);  Delay_ms(500);
```

### 画像素

SSD1306 显存按页组织：128 列 x 8 页（每页 8 行，1 bit/像素）：

```c
void OLED_DrawPixel(uint8_t x, uint8_t y, uint8_t color) {
    uint8_t page = y / 8;
    uint8_t bit  = y % 8;
    OLED_WriteCmd(0xB0 + page);
    OLED_WriteCmd(0x00 + (x & 0x0F));
    OLED_WriteCmd(0x10 + (x >> 4));
    OLED_WriteData(color ? (1 << bit) : 0);
}
```

> OLED 不能读——需帧缓冲。

---

## 10.4 动手：读写 AT24C02 EEPROM

板载的 **AT24C02** 是一个 2Kbit（256 字节）的 I²C EEPROM——掉电不丢数据，适合存配置参数、校准值、设备序列号。

**地址**：0x50（7 位，左移 1 位后 = 0xA0 写 / 0xA1 读）

**接线**：什么线都不用接——AT24C02 已经在你的板子上连好了 I²C 总线（SCL→PB6, SDA→PB7），和 OLED、MPU6050 共用同一条 I²C 总线。

### 写一个字节

```c
void AT24C02_WriteByte(uint8_t addr, uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0x50 << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, addr);        // 写入地址（0~255）
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, data);        // 写入数据
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);

    Delay_ms(10);                    // AT24C02 内部写时间~5ms
}
```

### 读一个字节

```c
uint8_t AT24C02_ReadByte(uint8_t addr) {
    uint8_t data;

    // 先「假写」——发地址，告诉 EEPROM 要读哪个位置
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0x50 << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, addr);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    // 重新发起 START，这次读
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, 0x50 << 1, I2C_Direction_Receiver);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_RECEIVER_MODE_SELECTED));

    // 读之前关 ACK——只读一个字节，读完就 STOP
    I2C_AcknowledgeConfig(I2C1, DISABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_RECEIVED));
    data = I2C_ReceiveData(I2C1);

    I2C_GenerateSTOP(I2C1, ENABLE);
    I2C_AcknowledgeConfig(I2C1, ENABLE);   // 恢复 ACK，不影响后面传输

    return data;
}
```

### 验证：写入再读出

```c
int main(void) {
    I2C1_Init();
    USART1_Init();

    // 写位置 0x10 存 0xAA，位置 0x11 存 0xBB
    AT24C02_WriteByte(0x10, 0xAA);
    AT24C02_WriteByte(0x11, 0xBB);

    Delay_ms(10);

    uint8_t v1 = AT24C02_ReadByte(0x10);
    uint8_t v2 = AT24C02_ReadByte(0x11);

    printf("读回: 0x%02X 0x%02X\r\n", v1, v2);
    // 输出: 读回: 0xAA 0xBB

    while (1);
}
```

**关掉开发板电源再开，重新读——数据还在！** 这就是非易失存储的意义。以后你的项目里设 Wi-Fi 密码、PID 参数、设备地址，都存在这里。

### EEPROM vs Flash

| 特性 | AT24C02 (EEPROM) | W25Q64 (SPI Flash) |
|------|-----------------|-------------------|
| 容量 | 256 字节 | 8MB |
| 写入 | 字节写入（可改单个字节） | 必须先擦除整个扇区（4KB）再写 |
| 寿命 | 100 万次 | 10 万次 |
| 用途 | 配置参数、校准数据 | 字库、固件包、大量日志 |

EEPROM 的好处是**字节级随机写**——改一个配置不用擦除整个扇区。

---

## 10.5 动手：读取 MPU6050 六轴数据

**MPU6050** 是板载的六轴运动传感器（三轴加速度计 + 三轴陀螺仪），有硬件 DMP 可做姿态解算。I²C 地址：**0x68**。

接线也什么都不用加——MPU6050 和 AT24C02、OLED 共用同一条 I²C 总线。

### 初始化

```c
#define MPU6050_ADDR  0x68

// 对 MPU6050 写寄存器
void MPU_WriteReg(uint8_t reg, uint8_t data) {
    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, MPU6050_ADDR << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, reg);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_SendData(I2C1, data);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTOP(I2C1, ENABLE);
}

// 从 MPU6050 读寄存器
uint8_t MPU_ReadReg(uint8_t reg) {
    uint8_t data;

    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, MPU6050_ADDR << 1, I2C_Direction_Transmitter);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_TRANSMITTER_MODE_SELECTED));

    I2C_SendData(I2C1, reg);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_TRANSMITTED));

    I2C_GenerateSTART(I2C1, ENABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_MODE_SELECT));

    I2C_Send7bitAddress(I2C1, MPU6050_ADDR << 1, I2C_Direction_Receiver);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_RECEIVER_MODE_SELECTED));

    I2C_AcknowledgeConfig(I2C1, DISABLE);
    while (!I2C_CheckEvent(I2C1, I2C_EVENT_MASTER_BYTE_RECEIVED));
    data = I2C_ReceiveData(I2C1);

    I2C_GenerateSTOP(I2C1, ENABLE);
    I2C_AcknowledgeConfig(I2C1, ENABLE);
    return data;
}

void MPU6050_Init(void) {
    MPU_WriteReg(0x6B, 0x00);   // 退出休眠模式
    MPU_WriteReg(0x19, 0x07);   // 采样率分频
    MPU_WriteReg(0x1A, 0x00);   // 无低通滤波
    MPU_WriteReg(0x1B, 0x00);   // 陀螺仪满量程 ±250°/s
    MPU_WriteReg(0x1C, 0x00);   // 加速度计满量程 ±2g

    printf("MPU6050 WHO_AM_I = 0x%02X\r\n", MPU_ReadReg(0x75));
    // 应该读到 0x68，说明通信成功
}
```

### 读取原始数据

加速度计和陀螺仪各 3 轴，每个值 16 位（高 8 位 + 低 8 位），连续存放：

```c
typedef struct {
    int16_t accel_x, accel_y, accel_z;   // 加速度计（±2g: 16384 LSB/g）
    int16_t temp;                          // 温度
    int16_t gyro_x, gyro_y, gyro_z;       // 陀螺仪（±250°/s: 131 LSB/°/s）
} MPU6050_Data_t;

void MPU6050_ReadAll(MPU6050_Data_t *d) {
    uint8_t buf[14];
    // 从 0x3B 开始连续读 14 个字节
    for (int i = 0; i < 14; i++)
        buf[i] = MPU_ReadReg(0x3B + i);

    d->accel_x = (buf[0]  << 8) | buf[1];
    d->accel_y = (buf[2]  << 8) | buf[3];
    d->accel_z = (buf[4]  << 8) | buf[5];
    d->temp    = (buf[6]  << 8) | buf[7];
    d->gyro_x  = (buf[8]  << 8) | buf[9];
    d->gyro_y  = (buf[10] << 8) | buf[11];
    d->gyro_z  = (buf[12] << 8) | buf[13];
}

int main(void) {
    I2C1_Init();
    USART1_Init();
    MPU6050_Init();

    MPU6050_Data_t mpu;

    while (1) {
        MPU6050_ReadAll(&mpu);
        printf("ACC: %6d %6d %6d  "
               "GYRO: %6d %6d %6d\r\n",
               mpu.accel_x, mpu.accel_y, mpu.accel_z,
               mpu.gyro_x,  mpu.gyro_y,  mpu.gyro_z);
        Delay_ms(200);
    }
}
```

### 转换成物理值

```c
// 加速度 m/s²（满量程 ±2g 时，1g = 16384 LSB）
float ax = mpu.accel_x / 16384.0f * 9.8f;

// 角速度 °/s（满量程 ±250°/s 时，1°/s = 131 LSB）
float gx = mpu.gyro_x / 131.0f;
```

### 你能看到什么

- 板子静止水平放：**ACC_Z ≈ 16384**（1g 重力），ACC_X/Y ≈ 0
- 快速转动板子：陀螺仪值剧烈变化
- 温度值可读出芯片内部温度

**注意**：同一个 I²C 总线上挂了多个设备，地址不能冲突。AT24C02=0x50，MPU6050=0x68，SSD1306=0x3C——各不冲突，共享 SCL/SDA 没问题。

---

## 10.6 SPL vs HAL I2C 对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 初始化 | `I2C_Init()` + 手配 GPIO 开漏 | `HAL_I2C_Init()` + CubeMX 自动 |
| 主机发 | 手动 START->ADDR->DATA->STOP | `HAL_I2C_Master_Transmit()` 一步 |
| 状态检查 | `I2C_CheckEvent()` 查事件标志 | `HAL_I2C_GetState()` 查状态机 |
| OLED 命令 | 自己封装 `OLED_WriteCmd` | `HAL_I2C_Mem_Write()` 一步 |

## 10.7 上拉、电平与 I2C 总线恢复

I2C 的 SDA/SCL 是开漏信号：设备只能主动拉低，变成高电平依赖上拉电阻。因此“代码没有错但总线一直 BUSY”时，优先检查：

1. SDA/SCL 是否有合适上拉；
2. 设备地址是否为 7 位地址，读写位是否由驱动处理；
3. MCU 与模块是否共地、逻辑电平是否兼容；
4. 某个从设备是否在异常复位后一直把 SDA 拉低；
5. 时钟频率是否超过模块允许范围。

若总线被拉死，常见恢复方法是临时将 SCL 配为 GPIO，手动输出若干个时钟脉冲，再重新初始化 I2C。恢复前先断定问题来自总线，而不是盲目重启整个系统。

## 10.8 I2C 验收与“总线卡死”排错

先让一台设备 ACK，再写 OLED 或读传感器；不要一次同时连三个模块。

| 现象 | 优先检查 | 典型恢复动作 |
|---|---|---|
| 一直等 EV5/EV6 | 7 位地址是否左移、SCL/SDA 是否接反、上拉是否存在 | 用逻辑分析仪或 GPIO 手动观察两根线 |
| ACK 永远收不到 | 设备地址、供电、电平、模块是否已经被占用 | 断电后只保留一个从机测试 |
| SDA 永远低 | 从机在中途复位、上拉太弱、主机异常停止 | 临时把 SCL 配 GPIO，输出 9 个时钟并生成 STOP |
| 偶发 NACK | 频率过高、线太长、上拉不合适、读写时序错误 | 降速、缩短线、核对手册时序 |
| OLED 有电但不显示 | 地址、初始化命令、屏幕分辨率、控制字节 | 先发送单一像素/固定字符串 |

练习：在 UART 上输出每次 START、地址、ACK/NACK 和 STOP 的结果；遇到失败时只修改一个变量（地址、频率或上拉）再复测。

## 10.9 本章要点

- I2C = 两根线（SCL+SDA）+ 上拉电阻，开漏输出多设备共享。谁拉低谁赢
- 每个从机有唯一 7 位地址，SSD1306 = 0x3C
- 完整写流程：START -> 地址+R/W -> ACK -> 数据 -> ACK -> STOP
- SSD1306 需要 25 条初始化命令——配外设的标准流程
- 显存页模式：128x64 = 8 页 x 每页 128 字节
- 帧缓冲是显示复杂画面的前提

---

> **上一章**：[第 9 章 · ADC 模数转换](./09-chapter.md)
>
> **下一章**：[第 11 章 · SPI 总线](./11-chapter.md)
>
> I2C 是你的芯片间短距通信利器，下一步 SPI——更快、更灵活。

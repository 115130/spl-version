# 第 10 章 · I2C 总线

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

## 10.7 本章要点

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

# 第 25-27 章 · 综合实战项目（SPL版）

> 三个综合项目的系统设计、任务架构、状态机和数据流是纯软件设计——和 SPL/HAL 无关。用 SPL 做底层硬件抽象，给完整骨架代码。

---

## 项目 25 · 智能环境监测节点（SPL 版）

### FreeRTOS 任务架构

```
Task_Sensor(prio 3)  ──Queue──→ Task_MQTT(prio 4) ──WiFi──→ 云平台
                    ──Queue──→ Task_Display(prio 2) ──I2C──→ OLED
                    ──Queue──→ Task_SDLog(prio 2) ──SPI──→ SD卡

Button ISR ──Sem──→ Task_Button(prio 4)
```

### 核心外设初始化（SPL）

```c
void AllPeriph_Init(void) {
    // ── LED (PC13) ──
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC, ENABLE);
    GPIO_InitTypeDef g;
    GPIO_StructInit(&g);
    g.GPIO_Pin = GPIO_Pin_13; g.GPIO_Speed = GPIO_Speed_50MHz;
    g.GPIO_Mode = GPIO_Mode_Out_PP; GPIO_Init(GPIOC, &g);

    // ── USART1 (printf 调试) ──
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1 | RCC_APB2Periph_GPIOA, ENABLE);
    g.GPIO_Pin = GPIO_Pin_9; g.GPIO_Mode = GPIO_Mode_AF_PP; GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_10; g.GPIO_Mode = GPIO_Mode_IN_FLOATING; GPIO_Init(GPIOA, &g);
    USART_InitTypeDef u;
    USART_StructInit(&u);
    u.USART_BaudRate = 115200; u.USART_Mode = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART1, &u); USART_Cmd(USART1, ENABLE);

    // ── USART2 (WiFi 模块 DX-WF24) ──
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_USART2, ENABLE);
    g.GPIO_Pin = GPIO_Pin_2; g.GPIO_Mode = GPIO_Mode_AF_PP; GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_3; g.GPIO_Mode = GPIO_Mode_IN_FLOATING; GPIO_Init(GPIOA, &g);
    u.USART_BaudRate = 115200;  // DX-WF24 默认波特率
    USART_Init(USART2, &u); USART_Cmd(USART2, ENABLE);
    USART_ITConfig(USART2, USART_IT_RXNE, ENABLE);

    // ── I2C1 (OLED + BH1750) ──
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_I2C1, ENABLE);
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOB, ENABLE);
    g.GPIO_Pin = GPIO_Pin_6 | GPIO_Pin_7; g.GPIO_Mode = GPIO_Mode_AF_OD;
    GPIO_Init(GPIOB, &g);
    I2C_InitTypeDef i2c;
    I2C_StructInit(&i2c);
    i2c.I2C_ClockSpeed = 400000;
    I2C_Init(I2C1, &i2c); I2C_Cmd(I2C1, ENABLE);

    // ── SPI1 (SD 卡) ──
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_SPI1 | RCC_APB2Periph_GPIOA, ENABLE);
    g.GPIO_Pin = GPIO_Pin_5 | GPIO_Pin_7; g.GPIO_Mode = GPIO_Mode_AF_PP;
    GPIO_Init(GPIOA, &g);
    g.GPIO_Pin = GPIO_Pin_6; g.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &g);
    // CS (PA4) 手动控制
    g.GPIO_Pin = GPIO_Pin_4; g.GPIO_Mode = GPIO_Mode_Out_PP;
    GPIO_Init(GPIOA, &g);
    GPIO_SetBits(GPIOA, GPIO_Pin_4);  // CS 拉高

    SPI_InitTypeDef spi;
    SPI_StructInit(&spi);
    spi.SPI_BaudRatePrescaler = SPI_BaudRatePrescaler_256;  // SD 卡初始化先慢速
    spi.SPI_Mode = SPI_Mode_Master;
    SPI_Init(SPI1, &spi); SPI_Cmd(SPI1, ENABLE);

    // ── ADC1 (电池电压) ──
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_ADC1, ENABLE);
    g.GPIO_Pin = GPIO_Pin_1; g.GPIO_Mode = GPIO_Mode_AIN;
    GPIO_Init(GPIOA, &g);
    ADC_InitTypeDef adc;
    ADC_StructInit(&adc);
    adc.ADC_NbrOfChannel = 1;
    ADC_Init(ADC1, &adc);
    ADC_RegularChannelConfig(ADC1, ADC_Channel_1, 1, ADC_SampleTime_55Cycles5);
    ADC_Cmd(ADC1, ENABLE);
    // 校准
    ADC_ResetCalibration(ADC1); while(ADC_GetResetCalibrationStatus(ADC1));
    ADC_StartCalibration(ADC1); while(ADC_GetCalibrationStatus(ADC1));
}
```

### 关键差异对照表（HAL → SPL）

| 操作 | HAL 版 | SPL 版 |
|------|--------|--------|
| LED | `HAL_GPIO_WritePin(...)` | `GPIO_SetBits/ResetBits(GPIOC, GPIO_Pin_13)` |
| 按键 | CubeMX 自动 EXTI | 手写 `GPIO_EXTILineConfig + EXTI_Init + NVIC_Init` |
| I2C OLED | `HAL_I2C_Master_Transmit(...)` | SPL I2C 驱动：`I2C_GenerateSTART → 等 SB → 发地址 → 发数据` |
| SPI SD | `HAL_SPI_Transmit(...)` | `SPI_I2S_SendData(SPI1, byte)` + 手动 CS |
| ADC | `HAL_ADC_Start + PollForConversion` | `ADC_Cmd + SoftwareStartConv + while(!EOC)` |
| 延时 | `HAL_Delay` | FreeRTOS: `vTaskDelay`；无 RTOS: 第 5 章 `Delay_ms` |
| printf | `<stdio.h>` + `__io_putchar` | 相同 |

---

## 项目 26 · BLE 智能门锁（SPL 版）

核心是和项目 25 一样的外设初始化 + BLE UART 通信。舵机控制用 TIM PWM（SPL 版第 7 章已覆盖）。

状态机逻辑和 HAL 版**一字不改**。

---

## 项目 27 · 多协议智能网关（SPL 版）

这是全书最终项目。SPL 版的关键：USART2 接 WiFi/蓝牙二合一模块（DX-WF24），UART 中断接收同时处理 WiFi AT 响应和 BLE 数据。

协议转换、设备管理、本地规则引擎——纯 C 逻辑，和 SPL/HAL 无关。直接在 FreeRTOS 任务中以标准 C 实现。

---

## 编译和部署

```bash
# 编译（Makefile 里加上所有外设的 .c 文件）
make

# 串口监控
screen /dev/ttyUSB0 115200

# 烧录
make flash
```

---

> **下一步**：[第 28-30 章 · 工程实践（SPL版）](./28-30-chapter.md)
>
> 调试、低功耗、产品化——SPL 版特有的工具链视角。

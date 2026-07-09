# 阶段项目④⑤⑥（SPL版）

> 阶段项目④⑤⑥的架构设计用 FreeRTOS+无线+云，底层 SPL 替代 HAL，上层协议和应用层不变。

---

## 项目④ · FreeRTOS 多任务数据采集器

和 HAL 版（`../part4-project.md`）的差异：

| HAL 版 | SPL 版 |
|--------|--------|
| 外设初始化 = CubeMX 生成 | 手写初始化（见第 16 章完整代码） |
| I2C Mutex = `xSemaphoreCreateMutex()` | 相同 |
| Queue = `xQueueCreate()` | 相同 |
| 任务创建 = `xTaskCreate()` | 相同 |

SPL 版完整代码已在第 16 章给出，直接使用。

---

## 项目⑤ · WiFi 无线串口透传

和 HAL 版（`../part5-project.md`）的差异：

```c
// HAL 版 WiFi 任务:
ESP8266_TCPConnect(...);        // HAL UART 封装
ESP8266_TCPSend(...);

// SPL 版 WiFi 任务:
AT_SendCmd("AT+CIPSTART=...");  // SPL UART 封装（见第 17-20 章）
AT_WaitResponse("CONNECT", 10000);
AT_SendCmd("AT+CIPSEND=5");
AT_WaitResponse(">", 5000);
// 手动逐字节发送
for (int i = 0; i < len; i++) {
    while (USART_GetFlagStatus(USART2, USART_FLAG_TXE) == RESET);
    USART_SendData(USART2, data[i]);
}

// LED 控制（HAL → SPL）:
// HAL_GPIO_WritePin(LED_GPIO_Port, LED_Pin, GPIO_PIN_RESET)
// → GPIO_ResetBits(GPIOC, GPIO_Pin_13)
```

---

## 项目⑥ · MQTT 温湿度上云节点

和 HAL 版（`../part6-project.md`）的差异：

MQTT 报文拼装代码完全不变。唯一需要改的是 MQTT 发送函数（见第 21-24 章 `MQTT_SendPacket`）。

云平台认证参数、Topic 格式、JSON 上报——纯协议和应用逻辑，和库无关。

---

## SPL 阶段项目通用 Makefile 模板

```makefile
TARGET = project

CC      = arm-none-eabi-gcc
MCU     = cortex-m3
CFLAGS  = -mcpu=$(MCU) -mthumb -O0 -g3 -Wall
CFLAGS += -DSTM32F10X_HD -I./inc -I./freertos/include

# SPL 外设驱动（按需添加）
C_SRCS += lib/stm32f10x_rcc.c lib/stm32f10x_gpio.c
C_SRCS += lib/stm32f10x_usart.c lib/stm32f10x_i2c.c
C_SRCS += lib/stm32f10x_spi.c lib/stm32f10x_adc.c
C_SRCS += lib/stm32f10x_tim.c

# FreeRTOS
C_SRCS += freertos/tasks.c freertos/queue.c freertos/list.c
C_SRCS += freertos/timers.c freertos/port.c freertos/heap_4.c

# 你的驱动和应用代码
C_SRCS += drivers/led.c drivers/uart_at.c
C_SRCS += middleware/mqtt_client.c middleware/cjson.c
C_SRCS += app/task_sensor.c app/task_mqtt.c app/task_display.c

ASM_SRCS = lib/startup_stm32f10x_hd.s

OBJS = $(C_SRCS:.c=.o) $(ASM_SRCS:.s=.o)

all: $(TARGET).elf $(TARGET).bin

$(TARGET).elf: $(OBJS)
	$(CC) -T link.ld -mcpu=$(MCU) -mthumb -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

flash: $(TARGET).elf
	openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
	        -c "program $< verify reset exit"

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(OBJS)
```

---

> **返回导航**：[SPL 版 README](./README.md)

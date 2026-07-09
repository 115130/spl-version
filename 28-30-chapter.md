# 第 28-30 章 · 工程实践（SPL版）

> 调试技巧、低功耗设计、从原型到产品——核心技术和方法论和库无关。本章补充 SPL+GDB+OpenOCD 工具链特有视角，但调试方法论是通用的。

---

## 第 28 章 · 调试与排错（SPL 版）

### SPL 版的调试工具链

| HAL 版 | SPL 版 |
|--------|--------|
| CubeIDE 图形 Debug | **GDB 命令行** + OpenOCD |
| 断点 = 双击行号 | `(gdb) break main.c:42` |
| 变量监视 = Add Watch | `(gdb) print counter` |
| 内存查看 = Memory View | `(gdb) x/16x 0x20000000` |

### GDB 调试快速入门

```bash
# 终端 1：启动 OpenOCD
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg

# 终端 2：连接 GDB
arm-none-eabi-gdb blink.elf

(gdb) target remote :3333      # 连接 OpenOCD
(gdb) monitor reset halt        # 复位并暂停
(gdb) load                      # 烧录
(gdb) break main                # main 入口设断点
(gdb) continue                  # 运行到断点
(gdb) step                      # 单步
(gdb) print led_mode            # 看变量
(gdb) info registers            # 看 R0-R15
(gdb) x/4xw 0x40011000          # 看 GPIOC 寄存器
```

### Hard Fault 调试

和 HAL 版第 28 章完全一样的栈帧分析方法。SPL 版的优势：你的代码和寄存器之间没有 HAL 层，更容易从 PC 值反推到出错的 C 语句。

```bash
# 从 Hard Fault 栈帧拿到 PC 值后：
arm-none-eabi-addr2line -e blink.elf 0x08000234
# 输出: /home/you/stm32/blink/main.c:47
# ← 直接告诉你崩溃在哪一行
```

### SPL 独有的调试技巧

```c
// 在 Makefile 中启用更多警告
CFLAGS += -Wall -Wextra -Wshadow -Wundef

// 在代码中检查外设时钟
printf("GPIOA clock: %s\r\n",
    (RCC->APB2ENR & RCC_APB2ENR_IOPAEN) ? "ON" : "OFF");

// 检查栈使用（FreeRTOS）
printf("Task Sensor stack free: %lu words\r\n",
    uxTaskGetStackHighWaterMark(hSensorTask));
```

---

## 第 29 章 · 低功耗设计（SPL 版）

低功耗模式（Sleep/Stop/Standby）的进入和唤醒**和外设库无关**——都是操作 Cortex-M3 内核的 `__WFI()` 指令和 PWR 寄存器。SPL 版代码和 HAL 版几乎一样。

```c
// SPL 进入 Sleep 模式
__WFI();  // Wait For Interrupt

// SPL 进入 Stop 模式
PWR_EnterSTOPMode(PWR_Regulator_LowPower, PWR_STOPEntry_WFI);
// 唤醒后必须重配时钟！
SystemClock_Config();

// SPL 进入 Standby 模式
PWR_WakeUpPinCmd(ENABLE);  // 允许 WKUP 引脚唤醒
PWR_EnterSTANDBYMode();
// 唤醒 = 复位，程序从头开始
```

---

## 第 30 章 · 从原型到产品（SPL 版）

### 代码分层（SPL 工程结构）

```
stm32-project/
├── Makefile
├── FreeRTOSConfig.h
├── main.c
├── stm32f10x_conf.h
├── stm32f10x_it.c
├── lib/                    ← SPL 源文件
│   ├── startup_stm32f10x_hd.s
│   ├── stm32f10x_rcc.c
│   ├── stm32f10x_gpio.c
│   ├── stm32f10x_usart.c
│   ├── ...
├── freertos/               ← FreeRTOS 内核
├── drivers/                ← 你写的驱动
│   ├── led.c / led.h
│   ├── button.c / button.h
│   ├── uart_at.c / uart_at.h
│   ├── ssd1306_i2c.c
│   └── sdcard_spi.c
├── middleware/              ← 中间件
│   ├── mqtt_client.c
│   ├── cjson.c
│   └── fatfs/
├── app/                    ← 应用层
│   ├── task_sensor.c
│   ├── task_mqtt.c
│   └── task_display.c
└── utils/
    ├── ring_buffer.c
    └── delay.c
```

### OTA 固件升级

SPL 版的 Bootloader 和 HAL 版原理相同：

```c
// Bootloader 跳转到 APP
void JumpToApp(uint32_t app_addr) {
    uint32_t sp = *(volatile uint32_t *)app_addr;
    uint32_t pc = *(volatile uint32_t *)(app_addr + 4);

    __set_MSP(sp);

    void (*app)(void) = (void (*)(void))pc;
    __disable_irq();
    app();
}

// APP 端设置向量表偏移
SCB->VTOR = 0x08002000;  // APP 在 Flash 0x08002000
```

### Makefile 多目标构建

```makefile
# 同时编译 bootloader 和 app
all: bootloader.bin app.bin

bootloader.bin:
	$(MAKE) -f Makefile.bootloader

app.bin:
	$(MAKE) -f Makefile.app
```

---

## 全书结束

你完成了 SPL 版的全部内容。回顾你学了什么：

- 不用 IDE，纯命令行构建 STM32 工程
- 亲手写 Makefile、链接脚本、FreeRTOSConfig.h
- SPL 每个 API 背后对应的寄存器操作
- GDB + OpenOCD 调试
- 从 GPIO 到 MQTT 上云的全链路

你现在能在**任何一台有 GCC 的 Linux 机器上**开发 STM32——不需要 CubeIDE，不需要 Windows，不需要破解任何软件。

> **附录**：寄存器速查、电路基础、采购清单、推荐资源——它们和库无关。HAL 版附录 A-D 可以直接用，或直接看 RM0008 参考手册。
>
> 祝你在嵌入式的路上越走越远。

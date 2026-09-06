# 第 0 章 · 开发环境搭建（ZET6 SPL 版）

这一章把最小工程真正跑起来：能编译、能烧录、能调试，最后让板载 LED 按约 500 ms 的节奏亮灭。

开始前先完成 [第 0.5 章](./00.5-hardware-basics.md)。至少确认 SWDIO、SWCLK、GND、板卡供电方式，以及 LED 的实际引脚和有效电平。

完成这一章后，你应该能得到 ELF、BIN、HEX 和 MAP 文件；OpenOCD `verify` 成功；GDB 能停在 `Reset_Handler` 和 `main`；LED 的实际行为和 `board.h` 配置一致。

## 0.1 先把工程身份固定下来

本书的硬件基线是 STM32F103ZET6。对应的 SPL 宏是 `STM32F10X_HD`，启动文件使用 `startup_stm32f10x_hd.s`，链接脚本按 512 KB Flash 和 64 KB SRAM 配置。调试接口使用 SWD，核心信号是 PA13（SWDIO）、PA14（SWCLK）和 GND。

这几项必须互相匹配。拿 C8T6 或 Medium Density 工程改几个宏，可能编译能过，但启动文件里的中断向量、芯片密度宏和链接脚本已经不一致，后面很难排错。

板载 LED、按键、USB 串口和 SPI Flash 的接线属于开发板配置。把这些信息统一写进 [板卡资源约定](./board-zet6-profile.md)，代码里通过 `board.h` 使用。

## 0.2 安装工具链

PC 上的编译器默认生成 x86-64 或 ARM64 程序，STM32F103 使用 Cortex-M3 指令集，需要 `arm-none-eabi` 交叉工具链。

Ubuntu / Debian：

```bash
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi
```

Arch：

```bash
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-binutils
```

Fedora：

```bash
sudo dnf install arm-none-eabi-gcc arm-none-eabi-binutils
```

安装后检查：

```bash
arm-none-eabi-gcc --version
arm-none-eabi-objcopy --version
arm-none-eabi-gdb --version
```

还需要 OpenOCD。它负责通过 ST-Link 或 DAP-Link 与 STM32 的 SWD 接口通信，GDB 也通过它访问目标芯片。

```bash
# Ubuntu / Debian
sudo apt install openocd

# Arch
sudo pacman -S openocd

# Fedora
sudo dnf install openocd

openocd --version
```

如果 OpenOCD 用 `sudo` 能连、普通用户不能连，先运行 `lsusb` 找到调试器的 VID:PID，再按发行版或调试器文档配置 udev 规则。规则修改后重新插拔调试器，再用普通用户测试。

## 0.3 准备 SPL

本书按 `STM32F10x_StdPeriph_Lib_V3.5.0` 的目录结构编写。解压后保留原始目录，工程通过 `SPL_ROOT` 引用它，不需要把 CMSIS 和驱动文件复制到每个示例里。

```text
STM32F10x_StdPeriph_Lib_V3.5.0/
└── Libraries/
    ├── CMSIS/
    │   ├── CM3/CoreSupport/core_cm3.c
    │   └── CM3/DeviceSupport/ST/STM32F10x/
    │       ├── system_stm32f10x.c
    │       └── stm32f10x.h
    └── STM32F10x_StdPeriph_Driver/
        ├── inc/
        └── src/
```

第一个 blink 工程只需要 CMSIS、`system_stm32f10x.c`、RCC 和 GPIO。以后用到 USART、SPI、ADC 等外设，再把对应的 SPL `.c` 文件加入 Makefile，并在 `stm32f10x_conf.h` 中包含相应头文件。

这里要分清头文件和实现文件。`#include "stm32f10x_gpio.h"` 只让编译器知道 `GPIO_Init()` 的声明；链接阶段还需要 `stm32f10x_gpio.c` 编译出的目标文件，否则会出现 `undefined reference to GPIO_Init`。

## 0.4 编译第一个工程

仓库里的 [`examples/00-blink-zet6`](./examples/00-blink-zet6) 是这一章对应的完整工程。

```bash
cd examples/00-blink-zet6

make check-spl \
  SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0

make \
  SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
```

`check-spl` 先检查库路径。它失败时先修正 `SPL_ROOT`，不要继续追编译错误。

工程结构如下：

```text
00-blink-zet6/
├── Makefile
├── link.ld
├── main.c
├── board.h
├── stm32f10x_conf.h
└── build/
```

`Makefile` 决定用什么编译器、从哪里找 SPL、哪些源码参与构建。`link.ld` 定义 Flash、SRAM 和各段的位置。`main.c` 负责 SysTick 和 LED 逻辑，`board.h` 保存板卡相关引脚，`build/` 只放自动生成的文件。

启动文件在仓库根目录 [`code/startup_stm32f10x_hd.s`](./code/startup_stm32f10x_hd.s)。它包含 High Density STM32F1 的中断向量表和 `Reset_Handler`，不能替换成 Medium Density 版本。

Makefile 里最关键的几行是：

```makefile
SPL_ROOT ?= ../../STM32F10x_StdPeriph_Lib_V3.5.0

CFLAGS += -DSTM32F10X_HD -DUSE_STDPERIPH_DRIVER
CFLAGS += -I. -I$(DEVICE) -I$(CMSIS)/CoreSupport -I$(SPL)/inc
CFLAGS += -MMD -MP -ffunction-sections -fdata-sections

OBJS += $(BUILD)/stm32f10x_rcc.o $(BUILD)/stm32f10x_gpio.o
LDFLAGS += -Wl,--gc-sections,-Map,$(BUILD)/$(TARGET).map,--cref
```

`STM32F10X_HD` 让设备头文件按 High Density 芯片选择定义。`OBJS` 决定哪些 SPL 实现最终参与链接；`-MMD -MP` 生成头文件依赖；`--gc-sections` 删除没有被引用的函数；`-Map` 生成链接地图，后面查 Flash、RAM 和符号位置都会用到。

Makefile 的命令行必须以 Tab 开头。看到 `missing separator` 时，先检查命令前面是不是被编辑器换成了空格。

## 0.5 启动文件和链接脚本怎么配合

STM32F103 复位后，CPU 从向量表取出初始栈顶地址和复位入口。启动文件里的 `Reset_Handler` 随后复制 `.data`、清零 `.bss`，完成后进入 C 运行环境，再调用 `main()`。

链接脚本给这些步骤提供实际地址。ZET6 的内存区域是：

```ld
FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 64K

_estack = ORIGIN(RAM) + LENGTH(RAM);
```

初始化过的全局变量运行时放在 RAM，但初始值保存在 Flash。启动代码根据 `_sidata`、`_sdata`、`_edata` 把它们复制到 RAM；未初始化的全局变量落在 `.bss`，由 `_sbss` 和 `_ebss` 标出范围，复位时清零。

向量表所在的 `.isr_vector` 需要在链接脚本中用 `KEEP` 保留。工程启用了 `--gc-sections`，没有 `KEEP` 时，链接器可能把入口段当成未引用内容删除。

启动文件和链接脚本使用的符号名必须一致。比如启动文件查找 `_sdata`，链接脚本就要提供 `_sdata`；段名也一样，启动文件把向量表放进 `.isr_vector`，链接脚本就要保留这个段。

## 0.6 在 `board.h` 里写板卡差异

模板默认示例使用 PC13、低电平点亮：

```c
#define BOARD_LED_PORT       GPIOC
#define BOARD_LED_PIN        GPIO_Pin_13
#define BOARD_LED_ACTIVE_LOW 1
```

先根据自己的原理图确认这三个值。很多 STM32F103 开发板的 LED 接法不同，有的接 PC13，有的接 PB5，也有高电平点亮的设计。

业务代码只调用：

```c
BoardLed_Init();
BoardLed_Write(1U);
```

以后换板时，优先改板级配置，不要把具体 LED 引脚散落到各章代码里。

## 0.7 用 SysTick 做 500 ms 闪烁

这个工程不使用空循环延时。空循环持续时间会受主频、编译优化和指令生成结果影响，同一段源码换一个优化等级，实际延时就可能变化。

`main.c` 把 SysTick 配成 1 ms 中断：

```c
SystemCoreClockUpdate();
SysTick_Config(SystemCoreClock / 1000U);
```

SysTick ISR 每次只把毫秒计数加一。主循环记录起始时间，通过无符号减法判断已经过去多少毫秒；这种写法可以正确跨过 `uint32_t` 回绕点，只要单次比较的时间跨度小于计数器周期。

等待下一次事件时可以执行 `__WFI()`。CPU 会停下来等中断，SysTick 到来后继续运行，不需要让空循环一直占用处理器。

## 0.8 看懂构建结果

成功构建后，`build/` 里会有几种文件：

- `blink.elf`：包含机器码、符号和调试信息，GDB 使用它。
- `blink.bin`：纯二进制镜像。
- `blink.hex`：Intel HEX 格式镜像。
- `blink.map`：链接器生成的段和符号地图。

先看看程序实际占用了多少空间：

```bash
arm-none-eabi-size build/blink.elf
```

再确认关键启动符号存在：

```bash
arm-none-eabi-nm -n build/blink.elf \
  | rg '(_estack|_sidata|_sdata|_edata|_sbss|_ebss|Reset_Handler|main)'
```

`size` 显示的是当前程序占用，不代表芯片总容量。Flash 512 KB、SRAM 64 KB 的边界由 `link.ld` 限制；如果链接器报告 RAM overflow，要从 MAP 文件里查 `.bss`、`.data` 和栈占用。

## 0.9 烧录

先断电检查 SWDIO、SWCLK、GND 和供电，再连接调试器。接线确认后执行：

```bash
make flash \
  SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
```

这个目标通过 OpenOCD 写入程序，并执行 `verify`。日志出现 `verified`，说明写入 Flash 的内容读回后与镜像一致。

如果 `verify` 成功但 LED 没动，烧录链路已经基本确认，可以继续检查 `board.h`、LED 有效电平和实际板卡接线。

## 0.10 用 GDB 检查启动过程

LED 不亮时，先确认程序有没有进入 `main()`。终端 A 启动 OpenOCD：

```bash
make debug
```

终端 B 启动 GDB：

```gdb
arm-none-eabi-gdb build/blink.elf
(gdb) target remote :3333
(gdb) monitor reset halt
(gdb) break Reset_Handler
(gdb) break main
(gdb) continue
```

正常情况下会先停在 `Reset_Handler`，继续后再停在 `main`。如果连 `Reset_Handler` 都到不了，重点检查启动文件、向量表、链接脚本和芯片连接；如果能到 `main`，再查 LED 引脚和 GPIO 配置。

## 0.11 常见问题

`arm-none-eabi-gcc: command not found`：先运行 `arm-none-eabi-gcc --version`。命令本身找不到，就检查工具链安装和 `PATH`。

`SPL_ROOT must point ...`：检查 `SPL_ROOT` 是否指向 `STM32F10x_StdPeriph_Lib_V3.5.0` 根目录，并确认下面存在 `Libraries/CMSIS` 和 `Libraries/STM32F10x_StdPeriph_Driver`。

`undefined reference to GPIO_Init`：通常是 `stm32f10x_gpio.c` 没有参与链接。头文件已经找到，只说明编译阶段通过；继续检查 Makefile 的对象文件列表。

OpenOCD 找不到芯片：先量目标板供电，再查 GND、SWDIO、SWCLK、调试器配置和 Linux 权限。不要先改程序代码。

`verify` 成功，但 GDB 到不了 `main`：检查是否真的用了 `startup_stm32f10x_hd.s`、`STM32F10X_HD` 和 ZET6 链接脚本，再核对 `.isr_vector` 和启动符号。

GDB 能到 `main`，LED 仍不闪：检查 `board.h`。用万用表或逻辑分析仪量目标 GPIO，能看到约 500 ms 高低变化时，程序已经在工作，剩下是 LED 接线或有效电平问题。

## 0.12 验收和练习

做完后保存这些结果：实际 LED 端口和有效电平、`make check-spl` 输出、构建输出、`build/blink.map`、OpenOCD `verify` 结果，以及 GDB 命中 `Reset_Handler` 和 `main` 的记录。

然后做三个小实验：

1. 修改 `BOARD_LED_ACTIVE_LOW`，先预测 LED 会发生什么，再实际验证并恢复。
2. 在 `main.c` 增加一个已初始化全局变量和一个未初始化全局变量，用 `arm-none-eabi-nm` 或 MAP 文件确认它们分别进入 `.data` 和 `.bss`。
3. 复制工程到临时目录，把链接脚本里的 RAM 改成 20 KB，观察链接器在什么情况下开始报告 RAM overflow。实验结束后删除临时目录，不修改正常工程。

到这里，第一个 ZET6 SPL 工程已经具备完整的构建、烧录和调试链路。下一章开始看复位向量、Flash、SRAM、栈和 `main()` 之间的关系。

> **下一章**：[第 1 章 · 什么是嵌入式系统](./01-chapter.md)

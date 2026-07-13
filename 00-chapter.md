# 第 0 章 · 开发环境搭建（ZET6 SPL 版）

> **本章产出**：一个可构建、可烧录、可调试的 STM32F103ZET6 SPL 最小工程，而不是只在教程里“看起来能运行”的代码。
>
> **硬件前置**：先完成 [第 0.5 章](./00.5-hardware-basics.md)。你至少应能确认 SWDIO、SWCLK、GND、板卡供电方式，以及 LED 的实际引脚与有效电平。
>
> **通过标准**：生成 ELF/BIN/HEX/MAP；OpenOCD `verify` 成功；GDB 能先停在 `Reset_Handler` 再停在 `main`；LED 以约 500 ms 开、500 ms 关的节奏变化。

---

## 0.1 这一章解决什么问题

你熟悉的 Web 项目通常由运行时、操作系统和 IDE 接住大量细节；裸机工程必须明确回答下面六个问题：

| 问题 | 本章中的答案 |
|---|---|
| 由谁把 C 编译成 ARM 指令？ | `arm-none-eabi-gcc` |
| 哪些 SPL 源文件参与构建？ | Makefile 中明确列出的 RCC、GPIO、CMSIS 文件 |
| 复位后从哪里开始？ | HD 启动文件的完整中断向量表与 `Reset_Handler` |
| 程序和变量分别放在哪里？ | 链接脚本：Flash 512KB、SRAM 64KB |
| 如何烧录与调试？ | OpenOCD + ST-Link/DAP-Link + GDB |
| LED 实际在哪个引脚？ | `board.h`；由你的原理图/测量确认 |

本书不支持把 C8T6/MD 工程改几个宏后“凑合运行”。ZET6 的工程身份必须始终一致：

| 项目 | 固定值 |
|---|---|
| MCU | STM32F103ZET6（LQFP144） |
| SPL 宏 | `STM32F10X_HD` |
| 启动文件 | `startup_stm32f10x_hd.s` |
| Flash / SRAM | 512KB / 64KB |
| 调试接口 | SWD：PA13、PA14、GND |

板载 LED、按键、USB 串口、板载 Flash 的接线不是上述“芯片身份”的一部分。请先填写 [板卡资源约定](./board-zet6-profile.md)；它是全书唯一的板卡事实入口。

## 0.2 安装命令行工具

### ARM GCC 交叉编译器

你的 PC 是 x86-64/ARM64，而目标是 Cortex-M3；因此必须使用“为 ARM 生成代码”的交叉编译器。

```bash
# Ubuntu/Debian
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi

# Arch
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-binutils

# Fedora
sudo dnf install arm-none-eabi-gcc arm-none-eabi-binutils

arm-none-eabi-gcc --version
arm-none-eabi-objcopy --version
arm-none-eabi-gdb --version
```

### OpenOCD

OpenOCD 让命令行、GDB 与 ST-Link/DAP-Link 通过 SWD 通信。

```bash
# Ubuntu/Debian
sudo apt install openocd

# Arch
sudo pacman -S openocd

# Fedora
sudo dnf install openocd

openocd --version
```

Linux 上若普通用户无法访问调试器，需要为**自己的调试器型号**配置 udev 规则。先用 `lsusb` 看 VID:PID，再按发行版与调试器官方文档添加规则；不要把来源不明的 `0666` 规则当成通用解法。规则生效后，重新插拔调试器并确认 OpenOCD 能连接。

## 0.3 获取并识别 SPL

本章按 ST 的 `STM32F10x_StdPeriph_Lib_V3.5.0` 目录结构编写。下载/解压后，不要把 CMSIS、驱动源码、头文件随机散拷到多个工程；先保持原始库树，并通过 `SPL_ROOT` 指向它。

```text
STM32F10x_StdPeriph_Lib_V3.5.0/
└── Libraries/
    ├── CMSIS/
    │   ├── CM3/CoreSupport/core_cm3.c
    │   └── CM3/DeviceSupport/ST/STM32F10x/
    │       ├── system_stm32f10x.c
    │       └── stm32f10x.h
    └── STM32F10x_StdPeriph_Driver/
        ├── inc/      ← GPIO、RCC 等头文件
        └── src/      ← GPIO、RCC 等实现
```

最小 blink 只需要 CMSIS、`system_stm32f10x.c`、RCC 与 GPIO。之后每增加一个外设，才把对应 SPL 的 `.c` 文件和头文件加入 Makefile/`stm32f10x_conf.h`。**头文件被 include 不等于实现已经参与链接**；最终是否链接，由 Makefile 的源文件列表决定。

## 0.4 使用可构建的起步工程

仓库中的 [`examples/00-blink-zet6`](./examples/00-blink-zet6) 是本书第一个工程的唯一源码版本。不要手抄下面以外的旧 Makefile、旧链接脚本或不完整向量表。

```bash
cd examples/00-blink-zet6

# 先只验证 SPL 路径。失败时不要继续编译。
make check-spl SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0

# 编译，并生成 ELF/BIN/HEX/MAP。
make SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
```

工程结构如下：

```text
00-blink-zet6/
├── Makefile               ← 工具链、SPL 路径、参与编译的源码
├── link.ld                ← ZET6 的 Flash/SRAM 与段布局
├── main.c                 ← SysTick 1 ms 时基 + LED 状态机
├── board.h                ← 唯一允许写板载 LED 物理引脚的地方
├── stm32f10x_conf.h       ← 本例启用的 SPL 头文件
└── build/                 ← 自动生成，禁止手工编辑
```

启动文件位于仓库根目录 [`code/startup_stm32f10x_hd.s`](./code/startup_stm32f10x_hd.s)，由 Makefile 以相对路径编译。它包含高容量 F1 的完整向量表：除了常见 GPIO/USART 中断，还包括 ADC3、FSMC、SDIO、TIM5–7、SPI3、UART4/5、DMA2 等条目。不能用 C8T6/Medium Density 启动文件替代它。

### 读懂 Makefile 的关键部分

```makefile
SPL_ROOT ?= ../../STM32F10x_StdPeriph_Lib_V3.5.0

CFLAGS += -DSTM32F10X_HD -DUSE_STDPERIPH_DRIVER
CFLAGS += -I. -I$(DEVICE) -I$(CMSIS)/CoreSupport -I$(SPL)/inc
CFLAGS += -MMD -MP -ffunction-sections -fdata-sections

OBJS += $(BUILD)/stm32f10x_rcc.o $(BUILD)/stm32f10x_gpio.o
LDFLAGS += -Wl,--gc-sections,-Map,$(BUILD)/$(TARGET).map,--cref
```

| 项 | 作用 | 出错时先看什么 |
|---|---|---|
| `SPL_ROOT` | 未修改 SPL 根目录的位置 | 目录下是否同时存在 `Libraries/CMSIS` 和 `Libraries/STM32F10x_StdPeriph_Driver` |
| `STM32F10X_HD` | 让设备头文件选择高容量 F1 定义 | 不要写成 `MD`，也不要在多个文件重复定义不同密度 |
| `-MMD -MP` | 生成头文件依赖，改 `.h` 后能重编 | `build/*.d` 是自动产物 |
| `-ffunction-sections` + `--gc-sections` | 允许链接器删除未引用函数 | 不会替你修复漏加的 SPL `.c` 文件 |
| `-Map` | 输出符号/段布局地图 | 这是 Flash/RAM 超限和符号冲突的第一手证据 |

`Makefile` 中的命令行必须以 **Tab** 开头，不能用空格。若你复制后看到 `missing separator`，优先检查这一点。

### 链接脚本和启动文件必须配对

链接脚本不是“随便写个内存大小”。它向链接器承诺每个段放在哪里，并导出启动汇编需要的边界符号：

```ld
FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
RAM   (xrw) : ORIGIN = 0x20000000, LENGTH = 64K

_estack = ORIGIN(RAM) + LENGTH(RAM);
/* .data 在 RAM 运行、在 Flash 保存初始化值。 */
_sdata, _edata, _sidata
/* .bss 只占 RAM，复位时清零。 */
_sbss, _ebss
```

| 组件 | 契约 |
|---|---|
| 向量表第一项 | `_estack`，CPU 复位时装入 MSP |
| `Reset_Handler` | 从 `_sidata` 复制到 `_sdata.._edata`，清零 `_sbss.._ebss` |
| `.isr_vector` | 必须 `KEEP`，否则 `--gc-sections` 可能删除入口 |
| 链接脚本 | 为 ZET6 保留 512KB Flash、64KB SRAM，并在 RAM 溢出时失败 |

如果启动文件使用 `_data_start`、而链接脚本只提供 `_sdata`，或者向量表段名与链接脚本 `KEEP` 的段名不同，构建即使侥幸通过，复位后也可能无法到达 `main`。本书模板已经统一使用 `_sidata/_sdata/_edata/_sbss/_ebss` 和 `.isr_vector`。

### `board.h`：把“板子差异”关进一个文件

模板默认把 PC13、低有效作为**常见示例**，并非所有 ZET6 板都如此。先修改下面三个宏，再运行程序：

```c
#define BOARD_LED_PORT       GPIOC
#define BOARD_LED_PIN        GPIO_Pin_13
#define BOARD_LED_ACTIVE_LOW 1
```

业务代码只调用 `BoardLed_Init()` 与 `BoardLed_Write(on)`。换板时改 `board.h`，不要把同一份 LED 引脚复制到第 3、7、8 章的业务文件里。

### 为什么 blink 不再用空循环延时

`main.c` 配置 SysTick 为 1 ms：

```c
SystemCoreClockUpdate();
SysTick_Config(SystemCoreClock / 1000U);
```

中断中只做 `g_ms++`；主循环用无符号减法判断经过的时间。这样即使计数器回绕，`(uint32_t)(now - start) < delay` 仍在一个周期内成立。`__WFI()` 让 CPU 在等待 SysTick 中断时休眠，而不是用一个对优化等级和时钟频率敏感的空循环占满 CPU。第 5 章会系统讲时钟与这个时基的边界。

## 0.5 构建、烧录与调试

### 构建产物分别是什么

| 文件 | 用途 |
|---|---|
| `build/blink.elf` | 带符号和调试信息；烧录/调试首选它 |
| `build/blink.bin` | 裸二进制，适合某些下载器 |
| `build/blink.hex` | Intel HEX，适合某些烧录工具 |
| `build/blink.map` | 段、符号、交叉引用；分析占用和链接问题 |

构建后先检查容量，而不是看到“Build finished”就结束：

```bash
arm-none-eabi-size build/blink.elf
arm-none-eabi-nm -n build/blink.elf | rg '(_estack|_sidata|_sdata|_edata|_sbss|_ebss|Reset_Handler|main)'
```

`size` 的数值是当前镜像占用，不是芯片总容量；64KB RAM 和 512KB Flash 的上限由 `link.ld` 保证。若链接报 RAM overflow，先看 map 中的 `.bss`、`.data` 和栈预留，而不是擅自把内存长度改大。

### 连接和烧录

断电确认 SWD 线序后，按第 0.5 章的供电方式连接目标板和调试器。然后：

```bash
make flash SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
```

该目标执行 `program ... verify reset exit`。日志出现 `verified` 只证明 Flash 写入与读回一致；它不证明 LED 引脚、有效电平或板载电路假设正确。

### 用 GDB 验证“代码确实在跑”

终端 A：

```bash
make debug
```

终端 B：

```gdb
arm-none-eabi-gdb build/blink.elf
(gdb) target remote :3333
(gdb) monitor reset halt
(gdb) break Reset_Handler
(gdb) break main
(gdb) continue
```

先命中 `Reset_Handler`、再命中 `main`，再观察 LED。这样可以把“启动链路错误”和“LED 接线错误”分开排查。

## 0.6 常见失败路径

| 现象 | 证据/原因 | 先做什么 |
|---|---|---|
| `arm-none-eabi-gcc: command not found` | 工具链未装或 PATH 不含它 | 运行 `arm-none-eabi-gcc --version` |
| `SPL_ROOT must point ...` | 路径不是 SPL 根目录或库版本结构不同 | 运行 `make check-spl SPL_ROOT=...`，检查三个必需 `.c` 文件 |
| `undefined reference to GPIO_Init` | 头文件存在但 `stm32f10x_gpio.c` 未参与链接 | 检查 Makefile 的 `OBJS`，不要只加 include |
| OpenOCD 找不到目标 | 供电、GND、SWDIO/SWCLK、权限或调试器配置错误 | 回第 0.5 章，先量供电并确认线序 |
| `verify` 成功但不能到 `main` | 启动文件、向量表段、链接脚本符号不一致 | 用 GDB 断在 `Reset_Handler`；核对 HD 文件和 `.isr_vector` |
| 到了 `main` 但 LED 不动 | LED 引脚、低/高有效、板载电路不符 | 修改 `board.h`，或先用万用表测该 GPIO 电平 |
| LED 亮但节奏错误/串口乱码 | 时钟假设与实际不一致 | 记录 `SystemCoreClock`，第 5/8 章再校准时钟/波特率 |

## 0.7 本章验收与练习

完成后保存一次实验记录：

- [ ] 写下板卡的实际 LED 端口、引脚和有效电平；
- [ ] `make check-spl`、`make` 和 `make flash` 的输出已保存；
- [ ] `build/blink.map` 存在，链接脚本写的是 512KB Flash / 64KB RAM；
- [ ] GDB 断点已分别命中 `Reset_Handler` 与 `main`；
- [ ] LED 的实际观察结果与 `board.h` 匹配。

练习按风险从低到高进行：

1. 只改 `board.h` 的有效电平，预测 LED 行为并恢复；
2. 在 `main.c` 添加一个已初始化全局变量和一个未初始化全局变量，用 `nm`/map 找到它们分别进入 `.data` 与 `.bss`；
3. 复制整个目录到临时位置，把链接脚本故意改为 20KB RAM，观察 `size`、map 和链接错误的变化，然后恢复。不要在可用工程中做破坏性实验。

## 0.8 本章要点

- ZET6 工程身份是 HD 启动文件、`STM32F10X_HD`、512KB Flash、64KB SRAM 的组合；四者缺一不可。
- Makefile 的源码列表决定真正参与链接的 SPL 驱动；头文件不会自动带来实现。
- 启动文件、向量表段名、链接脚本符号和内存长度是一个不可拆分的契约。
- `board.h` 隔离开发板差异；芯片功能表不能替代原理图。
- `verify`、GDB 断点、GPIO 电平/LED 观察分别验证不同层次，不能用其中一个代替全部。

---

> **下一章**：[第 1 章 · 什么是嵌入式系统](./01-chapter.md)
>
> 现在工程已经能被验证。下一章解释复位向量、Flash、SRAM、栈和 `main()` 是如何连成一条启动链路的。

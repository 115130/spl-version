# 第 0 章 · 开发环境搭建（SPL版）

> **本章产出**：Linux 下完整的 STM32 开发环境就绪——GCC + SPL + Makefile + OpenOCD + 第一个 SPL 工程（LED 闪烁）
>
> **预计时间**：一个下午

---

## 0.1 为什么选这套工具链

嵌入式初学者常被 IDE 裹挟——Keil、IAR、CubeIDE 各搞一套，换个平台就不会了。

**Linux + GCC + Makefile + OpenOCD + SPL** 这套方案的好处：

| | 商业 IDE（Keil/IAR） | 本书方案 |
|---|---|---|
| 价格 | 收费（或破解） | **免费** |
| 平台 | Windows 为主 | **Linux 原生** |
| 你看到的 | GUI 按钮背后的魔法 | **每一行编译选项你都知道什么意思** |
| 换芯片 | 可能要换 IDE | 改 Makefile 几行就行 |
| 找工作 | 部分公司用 | **所有公司都用 GCC 做 CI/CD** |

> 你学完这套工具链，就不只是「会用 STM32」了——你懂了 ARM 嵌入式开发的全流程。

## 0.2 安装工具链

### Step 1：安装 ARM GCC 交叉编译器

```bash
# Ubuntu/Debian
sudo apt install gcc-arm-none-eabi binutils-arm-none-eabi

# Arch
sudo pacman -S arm-none-eabi-gcc arm-none-eabi-binutils

# Fedora
sudo dnf install arm-none-eabi-gcc arm-none-eabi-binutils

# 验证安装
arm-none-eabi-gcc --version
# arm-none-eabi-gcc (15:13.3.rel1-2) 13.3.1 20240614
```

### Step 2：安装 OpenOCD（调试和烧录）

```bash
# Ubuntu/Debian
sudo apt install openocd

# Arch
sudo pacman -S openocd

# Fedora
sudo dnf install openocd

# 验证
openocd --version
# Open On-Chip Debugger 0.12.0
```

### Step 3：解决 USB 权限问题

Linux 默认不允许普通用户访问 USB 调试器：

```bash
# 方法一：安装 udev 规则（推荐）
# 创建文件 /etc/udev/rules.d/99-stlink.rules
sudo tee /etc/udev/rules.d/99-stlink.rules << 'EOF'
# ST-Link V2
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3748", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

# 拔插 ST-Link
```

## 0.3 准备 SPL 标准外设库

### 下载 SPL

ST 官网现在不太好找 SPL 的下载链接。下面是两种获取方式：

**方式一**：ST 官网下载 `STM32F10x_StdPeriph_Lib_V3.5.0.zip`（需要注册 ST 账号）

**方式二**：GitHub 上有人维护了镜像：
```bash
git clone https://github.com/abhishekkCTRL/STM32F10x_StdPeriph_Driver.git
```

### 了解 SPL 的目录结构

```
STM32F10x_StdPeriph_Lib_V3.5.0/
├── CMSIS/
│   ├── CM3/
│   │   ├── CoreSupport/       ← core_cm3.c/h (ARM 内核支持)
│   │   └── DeviceSupport/ST/STM32F10x/
│   │       ├── startup/       ← 启动文件（汇编）
│   │       │   ├── startup_stm32f10x_md.s  ← F103C8 用这个（Medium Density）
│   │       │   └── ...
│   │       ├── stm32f10x.h   ← 寄存器地址定义
│   │       └── system_stm32f10x.c  ← 系统时钟初始化
│   └── ...
└── STM32F10x_StdPeriph_Driver/
    ├── inc/                   ← 头文件：stm32f10x_gpio.h, stm32f10x_usart.h ...
    └── src/                   ← 源文件：stm32f10x_gpio.c, stm32f10x_usart.c ...
```

**你需要的核心文件**（在一个最小 SPL 工程中）：

| 文件 | 作用 |
|------|------|
| `startup_stm32f10x_md.s` | 启动代码（中断向量表 + Reset_Handler） |
| `system_stm32f10x.c` | 系统时钟初始化 `SystemInit()` |
| `core_cm3.c` | ARM Cortex-M3 内核访问函数 |
| `stm32f10x_rcc.c` | 时钟控制 |
| `stm32f10x_gpio.c` | GPIO 控制 |
| `stm32f10x_conf.h` | 你写的——决定哪些外设驱动被编译 |
| `main.c` | 你的代码 |
| `Makefile` | 构建脚本 |

## 0.4 你的第一个 SPL 工程

### 目录结构

```
~/stm32/01-blink-spl/
├── Makefile
├── main.c
├── stm32f10x_conf.h
├── stm32f10x_it.c          ← 中断服务函数（可留空）
├── lib/                    ← 从 SPL 包拷贝过来的文件
│   ├── startup_stm32f10x_md.s
│   ├── system_stm32f10x.c
│   ├── core_cm3.c
│   ├── stm32f10x_rcc.c
│   └── stm32f10x_gpio.c
├── inc/                    ← 头文件
│   ├── stm32f10x.h          ← 主头文件（会 include 下面几个）
│   ├── system_stm32f10x.h   ← SystemCoreClock 声明（必须！）
│   ├── stm32f10x_rcc.h
│   ├── stm32f10x_gpio.h
│   └── core_cm3.h
└── build/                  ← 编译产物（自动生成）
```

### Makefile 入门：从零理解 Makefile

如果你没写过 Makefile，先花几分钟搞懂它的基本语法。Makefile 只有三种东西：

#### 1. 变量

```makefile
CC = arm-none-eabi-gcc     # 定义变量 CC
CFLAGS = -mcpu=cortex-m3   # 定义编译选项

# 使用时用 $(变量名)：
$(CC) $(CFLAGS) -c main.c
# 展开后变成：arm-none-eabi-gcc -mcpu=cortex-m3 -c main.c
```

`+=` 是追加（不覆盖）：

```makefile
CFLAGS = -Wall         # CFLAGS = -Wall
CFLAGS += -O2          # CFLAGS = -Wall -O2
```

#### 2. 规则（Rule）

```makefile
目标: 依赖1 依赖2
	命令1
	命令2
```

规则的意思是：**要生成「目标」，需要先有「依赖」；然后用「命令」来生成。**

```makefile
# 例子：blink.elf 依赖 main.o 和 gpio.o，用 gcc 把它们链接起来
blink.elf: main.o gpio.o
	arm-none-eabi-gcc -o blink.elf main.o gpio.o
```

> ⚠️ 命令行前面**必须是 Tab 键，不能是空格**。这是 Makefile 最常见的坑。

#### 3. 模式规则（Pattern Rule）

`%.o: %.c` 的意思是：「任何 `.o` 文件都可以从同名的 `.c` 文件编译出来」：

```makefile
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<
#                          ↑  ↑
#                          │  └── $< = 第一个依赖（.c 文件）
#                          └───── $@ = 目标名（.o 文件）
```

#### 4. 不写规则的第一个目标 = 默认目标

```makefile
all: blink.elf     # ← 这是第一个目标，执行 make 时默认执行它
```

---

### 逐行解读本书的 Makefile

现在回到 SPL 工程的 Makefile，逐段拆解：

```makefile
# ===== 第一段：定义变量 =====
TARGET = blink              # 最终产物叫 blink.elf / blink.bin

CC      = arm-none-eabi-gcc # C 编译器
AS      = arm-none-eabi-as  # 汇编器
LD      = arm-none-eabi-gcc # 链接器（和编译器同一个程序）
OBJCOPY = arm-none-eabi-objcopy  # 格式转换工具
SIZE    = arm-none-eabi-size     # 显示代码大小
```

```makefile
# ===== 第二段：编译选项（传给 gcc 的参数）=====
MCU     = cortex-m3         # CPU 架构
FLOAT   = -msoft-float      # Cortex-M3 没有硬件浮点，用软件模拟

CFLAGS  = -mcpu=$(MCU) -mthumb $(FLOAT)
#          生成 cortex-m3 指令  用 Thumb 模式  软浮点

CFLAGS += -O0 -g3 -Wall -fmessage-length=0
#         优化0  调试信息3  所有警告  不截断错误信息
#         ↑ O0 不做优化，每行 C 对应明确的汇编，方便调试

CFLAGS += -DSTM32F10X_MD
#         定义宏 STM32F10X_MD（告诉 stm32f10x.h 你的芯片是中容量）

CFLAGS += -I./inc
#         头文件搜索路径：-I 后面跟目录，-I./inc 表示也在 ./inc 里找 .h

LDFLAGS = -T link.ld -mcpu=$(MCU) -mthumb $(FLOAT)
#          链接脚本   CPU 参数（和编译时保持一致）

LDFLAGS += -Wl,--gc-sections
#           告诉链接器：删掉没被引用的函数（省 Flash）

LDFLAGS += -specs=nosys.specs -specs=nano.specs
#           用 nano 版 C 标准库（体积小）  不依赖操作系统
```

```makefile
# ===== 第三段：源文件列表 =====
C_SRCS  = main.c stm32f10x_it.c                     # 你的代码
C_SRCS += lib/system_stm32f10x.c lib/core_cm3.c     # CMSIS 内核
C_SRCS += lib/stm32f10x_rcc.c lib/stm32f10x_gpio.c  # SPL 外设驱动

ASM_SRCS = lib/startup_stm32f10x_md.s  # 启动汇编

# 把 .c 和 .s 分别替换成 .o
OBJS = $(C_SRCS:.c=.o) $(ASM_SRCS:.s=.o)
#      └──────────────┘ └──────────────┘
#        main.c → main.o     startup.s → startup.o
```

```makefile
# ===== 第四段：规则 =====

# 默认目标：make 或 make all 就执行这个
all: $(TARGET).elf $(TARGET).bin $(TARGET).hex
	$(SIZE) $(TARGET).elf       # 编译完后显示 Flash/RAM 占用

# 链接：把所有 .o 合成一个 .elf
$(TARGET).elf: $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^
#                        ↑  ↑
#                        │  └── $^ = 所有依赖（所有 .o 文件）
#                        └───── $@ = 目标（blink.elf）

# 编译 .c → .o（模式规则，自动匹配）
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# 汇编 .s → .o（模式规则，自动匹配）
%.o: %.s
	$(AS) -mcpu=$(MCU) -mthumb -o $@ $<

# .elf → .bin（用于烧录，纯二进制）
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# .elf → .hex（Intel Hex 格式，有些烧录工具用）
$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex $< $@
```

```makefile
# ===== 第五段：辅助目标 =====

# 烧录——make flash
flash: $(TARGET).elf
	openocd -f interface/stlink.cfg \
	        -f target/stm32f1x.cfg \
	        -c "program $< verify reset exit"
#           └── 写 Flash → 校验 → 复位 → 退出 OpenOCD

# 清理——make clean
clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).hex $(OBJS)
```

### Makefile 的依赖链

当你执行 `make` 时，Make 会自动追踪依赖关系：

```
make (默认目标 all)
  │
  ├──→ 需要 blink.elf
  │      ├──→ 需要 main.o ──→ main.c 存在 → 执行编译命令
  │      ├──→ 需要 stm32f10x_rcc.o ──→ stm32f10x_rcc.c 存在 → 编译
  │      └──→ ... 所有 .o 都就绪 → 执行链接命令
  │
  ├──→ 需要 blink.bin ──→ blink.elf 就绪 → 执行 objcopy
  └──→ 需要 blink.hex ──→ blink.elf 就绪 → 执行 objcopy
```

**智能重编译**：如果你只改了 `main.c`，下次 `make` 只重新编译 `main.c → main.o` 然后重新链接，其他 `.o` 不动。Make 靠比较文件修改时间来判断哪些需要重编。

---

### Makefile

```makefile
# 项目名称
TARGET = blink

# 工具链
CC      = arm-none-eabi-gcc
AS      = arm-none-eabi-as
LD      = arm-none-eabi-gcc
OBJCOPY = arm-none-eabi-objcopy
SIZE    = arm-none-eabi-size

# MCU 配置
MCU     = cortex-m3
FPU     =
FLOAT   = -msoft-float
CHIP    = STM32F103C8

# 编译选项
CFLAGS  = -mcpu=$(MCU) -mthumb $(FLOAT)
CFLAGS += -O0 -g3 -Wall -fmessage-length=0
CFLAGS += -D$(CHIP) -DSTM32F10X_MD  # ← Medium Density（64KB Flash）
CFLAGS += -I./inc

LDFLAGS = -T link.ld -mcpu=$(MCU) -mthumb $(FLOAT)
LDFLAGS += -Wl,--gc-sections -specs=nosys.specs -specs=nano.specs

# 源文件
C_SRCS  = main.c stm32f10x_it.c
C_SRCS += lib/system_stm32f10x.c lib/core_cm3.c
C_SRCS += lib/stm32f10x_rcc.c lib/stm32f10x_gpio.c

ASM_SRCS = lib/startup_stm32f10x_md.s

OBJS = $(C_SRCS:.c=.o) $(ASM_SRCS:.s=.o)

all: $(TARGET).elf $(TARGET).bin $(TARGET).hex
	$(SIZE) $(TARGET).elf

$(TARGET).elf: $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.s
	$(AS) -mcpu=$(MCU) -mthumb -o $@ $<

$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex $< $@

# 烧录（通过 OpenOCD + ST-Link）
flash: $(TARGET).elf
	openocd -f interface/stlink.cfg \
	        -f target/stm32f1x.cfg \
	        -c "program $< verify reset exit"

# 调试
debug:
	openocd -f interface/stlink.cfg -f target/stm32f1x.cfg
	# 另开终端：arm-none-eabi-gdb $(TARGET).elf
	# (gdb) target remote :3333
	# (gdb) load
	# (gdb) monitor reset halt
	# (gdb) continue

clean:
	rm -f $(TARGET).elf $(TARGET).bin $(TARGET).hex $(OBJS)
```

### 链接脚本 `link.ld`

```ld
MEMORY
{
    FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 64K
    SRAM  (rwx): ORIGIN = 0x20000000, LENGTH = 20K
}

_stack_top = ORIGIN(SRAM) + LENGTH(SRAM);

SECTIONS
{
    .isr_vector :
    {
        KEEP(*(.isr_vector))
    } > FLASH

    .text :
    {
        *(.text*)
        *(.rodata*)
    } > FLASH

    .data :
    {
        _data_start = .;
        *(.data*)
        _data_end = .;
    } > SRAM AT > FLASH

    .bss :
    {
        _bss_start = .;
        *(.bss*)
        _bss_end = .;
    } > SRAM
}
```

> ⚠️ **芯片型号差异**：上面的 Makefile 和链接脚本是基于 **STM32F103C8T6**（MD, Medium Density, 64KB Flash / 20KB SRAM）。如果你用的是其他型号，需要改 3 处：
>
> | 你的芯片 | 密度 | 启动文件 | 编译宏 | Flash/SRAM |
> |---------|------|---------|--------|-----------|
> | STM32F103C8 (蓝色小板) | MD | `startup_stm32f10x_md.s` | `-DSTM32F10X_MD` | 64K / 20K |
> | **STM32F103ZE (野火板)** | **HD** | **`startup_stm32f10x_hd.s`** | **`-DSTM32F10X_HD`** | **512K / 64K** |
> | STM32F103VG | HD | `startup_stm32f10x_hd.s` | `-DSTM32F10X_HD` | 1024K / 96K |
>
> 野火 ZET6 用户只需把 Makefile 里的 `_MD` 改成 `_HD`，链接脚本里的 `64K`/`20K` 改成 `512K`/`64K` 即可。启动文件 (`startup_stm32f10x_hd.s`) 在 SPL 包的 `CMSIS/CM3/DeviceSupport/ST/STM32F10x/startup/arm/` 目录下。

### `stm32f10x_conf.h`（精简版）

```c
#ifndef __STM32F10x_CONF_H
#define __STM32F10x_CONF_H

// 只用 GPIO 和 RCC，其他外设暂时注释掉
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
// #include "stm32f10x_usart.h"  ← 后面用到时取消注释
// #include "stm32f10x_tim.h"
// ...

#endif
```

### `main.c`：用 SPL 点亮 LED

```c
#include "stm32f10x.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

// 简陋的延时（不用 SysTick，纯 CPU 空转）
void Delay_ms(uint32_t ms) {
    for (uint32_t i = 0; i < ms * 8000; i++) {
        __NOP();  // 空指令，防止被优化掉
    }
}

int main(void)
{
    // 1. 开启 GPIOC 的时钟
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOC, ENABLE);

    // 2. 配置 PC13 为推挽输出
    GPIO_InitTypeDef gpio;
    GPIO_StructInit(&gpio);  // 先填默认值
    gpio.GPIO_Pin   = GPIO_Pin_13;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    gpio.GPIO_Mode  = GPIO_Mode_Out_PP;  // 推挽输出
    GPIO_Init(GPIOC, &gpio);

    // 3. 主循环——LED 闪烁
    while (1) {
        GPIO_ResetBits(GPIOC, GPIO_Pin_13);  // PC13 输出低（LED 亮）
        Delay_ms(500);
        GPIO_SetBits(GPIOC, GPIO_Pin_13);    // PC13 输出高（LED 灭）
        Delay_ms(500);
    }
    // SPL 没有 HAL_Delay——后面用 SysTick 写一个
}
```

### 编译和烧录

```bash
cd ~/stm32/01-blink-spl

# 编译
make

# 烧录
make flash

# 或者分开烧录：
openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
        -c "program blink.elf verify reset exit"
```

**效果**：板载 LED 以 1 秒周期闪烁。你的第一个 SPL 工程跑起来了。

## 0.5 和 HAL 版的关键区别

HAL 版第 0 章做了同样的事——点亮 LED。对比一下：

| | HAL 版 | SPL 版 |
|---|---|---|
| **IDE** | CubeIDE（GUI + 自动生成） | 纯命令行（VS Code 编辑 + 终端编译） |
| **工程创建** | CubeMX 点几下 → 生成 20+ 个文件 | 手动拷贝 7 个文件 + 手写 Makefile |
| **LED 初始化** | `MX_GPIO_Init()`（CubeMX 生成的函数） | `GPIO_Init()`（你亲手写的配置） |
| **延时** | `HAL_Delay(500)`（SysTick 自动配置好了） | `Delay_ms(500)`（自己用空循环写的,简陋） |
| **编译** | 点 Build 按钮 | `make` |
| **烧录** | 点 Run 按钮 | `make flash`（一行命令） |
| **调试** | 点 Debug 按钮 | 终端里 `gdb` 连接 OpenOCD |

**SPL 版更「原始」**——但正因为原始，你对每一行代码、每一个编译选项都了如指掌。

## 0.6 如果灯不亮

| 现象 | 可能原因 |
|------|---------|
| `make` 报 `arm-none-eabi-gcc: command not found` | 工具链没装好。跑 `which arm-none-eabi-gcc` |
| `make flash` 报 `Error: open failed` | ST-Link 没插好或者没权限。跑 `lsusb` 确认 ST-Link 被识别 |
| 编译通过但 LED 不闪 | `SystemInit()` 没被调用（默认启动文件里会调）。检查 `startup` 文件是否正确 |
| LED 一直亮 | PC13 低电平有效（灯亮）——注意 `GPIO_ResetBits` = 亮, `GPIO_SetBits` = 灭 |

---

## 0.7 本章要点

- 工具链：`arm-none-eabi-gcc` + OpenOCD + Makefile + SPL
- SPL 工程 = 启动文件 + CMSIS 内核文件 + 外设驱动（按需拷贝）+ 你的 `main.c`
- `stm32f10x_conf.h` 决定哪些外设驱动被编译——不需要的外设不编译，省 Flash
- `Makefile` 是你自己写的，每个 `CFLAGS` 都知道什么意思
- SPL 的 GPIO API：`GPIO_Init()` 配置，`GPIO_SetBits/ResetBits` 控制电平

---

> **下一章**：[第 1 章 · 什么是嵌入式系统（SPL版）](./01-chapter.md)
>
> 第 1 章已经是独立 SPL 版本——嵌入式概念、MCU 启动流程、裸机 vs RTOS vs Linux、嵌入式全栈。请直接阅读 SPL 版 [第 1 章](./01-chapter.md)。

# 00-blink-zet6

第 0 章的最小、可构建 SPL 工程。它使用 ZET6 的 High Density 启动文件、512KB Flash、64KB SRAM 和外部 `STM32F10x_StdPeriph_Lib`。

## 准备

1. 下载并解压未经改名的 STM32F10x Standard Peripheral Library v3.5.0；
2. 设置 `SPL_ROOT`，或把库目录放到本工程同级；
3. 根据你的开发板编辑 `board.h` 中 LED 的端口、引脚与有效电平；`timebase.h` 提供后续章节可复用的 1ms 时基接口；
4. 执行 `make`、`make flash`。

```bash
make SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
make flash SPL_ROOT=$HOME/opt/STM32F10x_StdPeriph_Lib_V3.5.0
```

## 通过标准

- `build/blink.elf`、`.bin`、`.hex`、`.map` 都生成；先单独运行 `make check-spl` 可以只检查库路径；
- `arm-none-eabi-size build/blink.elf` 显示的 RAM 上限来自 64KB 链接脚本；
- OpenOCD `verify` 成功；
- LED 以约 0.5 秒开、0.5 秒关的节奏变化。

若 LED 不动，先改 `board.h`，不要先改时钟、启动文件或链接脚本。若 `make` 失败，先保存完整命令输出，并确认 `SPL_ROOT` 指向的目录内同时有 `Libraries/CMSIS` 与 `Libraries/STM32F10x_StdPeriph_Driver`。

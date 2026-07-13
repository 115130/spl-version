# 教材示例工程约定

本目录用于承载与章节一一对应的、可构建的 STM32F103ZET6 示例工程。

## 目标结构

~~~text
examples/
  00-blink-zet6/
  03-gpio-button/
  08-uart-console/
  10-i2c-oled/
  18-wifi-temperature-logger/
  25-environment-monitor/
~~~

每个示例应包含：

- README：目标、硬件清单、接线、编译、烧录、预期输出；
- Makefile：统一使用 STM32F103ZET6、STM32F10X_HD、512KB Flash / 64KB SRAM；
- 链接脚本和启动文件说明；
- 不提交真实 WiFi 密码、云端密钥或本机构建产物；
- 至少一份人工或硬件验收记录。

在没有实际板卡与 SPL 库文件的环境中，不应假装示例已经通过硬件验证。每个新增示例都应在 README 标注“已编译”“已烧录”或“仅骨架”的状态。

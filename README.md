# 深入浅出STM32嵌入式开发：从零到IoT网关（SPL标准外设库版）

> **本书是 SPL（标准外设库 / Standard Peripheral Library）版本**
>
> 如果你用的是 **HAL 库 + STM32CubeIDE**，请移步上级目录的 HAL 版本。
>
> 如果你用的是 **Linux + VS Code + arm-none-eabi-gcc + SPL 标准外设库**，你来对地方了。

---

## 🧭 从哪里开始

本书的正文、接线、启动文件和链接脚本均以 **STM32F103ZET6** 为唯一基线。阅读顺序建议是：

[前言](./00-preface.md) → [第 0.5 章 · 硬件零基础生存手册](./00.5-hardware-basics.md) → [第 0 章 · 开发环境搭建](./00-chapter.md)

如果你会软件开发但从未接触硬件，请不要跳过第 0.5 章；它会先解决电压、GND、ST-Link 和 UART 接线这些最容易卡住的问题。

---

## 📖 SPL 版 vs HAL 版

| | SPL 版（本书） | HAL 版（上级目录） |
|---|---|---|
| **开发环境** | Linux + VS Code + GCC + Makefile | STM32CubeIDE（跨平台） |
| **外设库** | SPL（STM32F10x_StdPeriph_Lib_V3.5） | HAL（Hardware Abstraction Layer） |
| **代码生成** | 手动搭建工程、手写初始化 | CubeMX 图形配置生成代码 |
| **API 风格** | `GPIO_SetBits(GPIOC, GPIO_Pin_13)` | `HAL_GPIO_WritePin(GPIOC, GPIO_PIN_13, SET)` |
| **适合谁** | 想从底层理解外设、喜欢命令行工具链、Linux 用户 | 想快速上手、喜欢图形化工具、Windows 用户 |

两个版本**章节结构完全一致**——31 章 + 6 个阶段项目 + 3 个综合项目 + 4 个附录。同一本书，两种库实现方式。

---

## 🗺️ 全书结构

与 HAL 版相同，详见上级目录 `README.md`。

SPL 版特别之处：

```
PART 0 · 启程（SPL 工程搭建）
PART 1 · 入门（SPL GPIO + 寄存器）
PART 2 · 核心外设（SPL TIM/UART/ADC + 中断）
PART 3 · 总线与存储（SPL I2C/SPI/DMA/RS485 + FatFs）
PART 4 · RTOS（FreeRTOS——库无关，两边一样）
PART 5 · 无线连接（AT 指令——库无关，两边一样）
PART 6 · 网关与云（MQTT/HTTP——库无关，两边一样）
PART 7 · 综合实战（整合上述所有）
PART 8 · 工程实践（调试/低功耗/产品化）
附录
```

## 📘 第 0–13 章目录

前半部分已经按“前提 → 原理 → 最小实现 → 验证 → 故障定位”的教材节奏组织。建议顺序阅读，不要跳过第 0.5 章和资源表：

- **启程与硬件边界**
  - [前言](./00-preface.md)
  - [第 0.5 章 · 硬件零基础生存手册](./00.5-hardware-basics.md)
  - [第 0 章 · 开发环境搭建](./00-chapter.md)
  - [ZET6 板卡资源约定](./board-zet6-profile.md)
- **裸机基础**
  - [第 1 章 · 什么是嵌入式系统](./01-chapter.md)
  - [第 2 章 · STM32F103 硬件概览](./02-chapter.md)
  - [第 3 章 · GPIO 与寄存器编程](./03-chapter.md)
  - [第 4 章 · C 语言的嵌入式边界](./04-chapter.md)
  - [第 5 章 · 时钟、时基与可测时间](./05-chapter.md)
  - [第 6 章 · 中断、事件与并发边界](./06-chapter.md)
  - [第 7 章 · 定时器：从公式到波形](./07-chapter.md)
- **外设、总线与存储**
  - [第 8 章 · UART：从字节流到可靠控制台](./08-chapter.md)
  - [第 9 章 · ADC、DMA 与 DAC](./09-chapter.md)
  - [第 10 章 · I2C：有状态、有超时、可恢复的两线总线](./10-chapter.md)
  - [第 11 章 · SPI 事务与 SDIO 卡初始化](./11-chapter.md)
  - [第 12 章 · DMA：缓冲区所有权、UART 流与 SDIO 数据通道](./12-chapter.md)
  - [第 12B 章 · RS485 物理层与 Modbus RTU](./12b-chapter.md)
  - [第 13 章 · 存储语义：原始 NOR 日志与 FatFs 的正确边界](./13-chapter.md)


---

## 📚 第 21–30 章目录

后半部分已按独立章节组织，可从第 20 章顺序阅读：

- **PART 6 · 网关与云**
  - [第 21 章 · MQTT：让设备持续发布数据](./21-chapter.md)
  - [第 22 章 · 云平台接入、设备身份与 HMAC](./22-chapter.md)
  - [第 23 章 · HTTP、响应解析与 cJSON](./23-chapter.md)
  - [第 24 章 · 网关架构与 UART 接收通路](./24-chapter.md)
- **PART 7 · 综合实战**
  - [第 25 章 · 智能环境监测节点](./25-chapter.md)
  - [第 26 章 · BLE 智能门锁](./26-chapter.md)
  - [第 27 章 · 多协议智能网关](./27-chapter.md)
- **PART 8 · 工程实践**
  - [第 28 章 · 调试与排错：从现象定位到代码](./28-chapter.md)
  - [第 29 章 · 低功耗设计：先测量，再进入睡眠](./29-chapter.md)
  - [第 30 章 · 从原型到产品：结构、测试与升级](./30-chapter.md)

---

## 💻 你需要准备

| 物品 | 说明 |
|------|------|
| Linux 系统 | 任何发行版（Ubuntu/Debian/Arch/Fedora） |
| VS Code | 代码编辑 |
| `arm-none-eabi-gcc` | ARM 交叉编译工具链 |
| OpenOCD | 调试和烧录 |
| STM32F103ZET6 开发板 | 本书唯一硬件基线（HD，512KB Flash / 64KB SRAM） |
| ST-Link v2 | 调试烧录器 |
| SPL 库文件 | `STM32F10x_StdPeriph_Lib_V3.5.0.zip`（ST 官网下载） |
| 硬件套件 | 见 [附录 A · ZET6、供电与接线速查](./appendix-a-zet6-reference.md) |

---

## 📎 附录与实验支持

- [附录 A · STM32F103ZET6、供电与接线速查](./appendix-a-zet6-reference.md)
- [附录 B · 怎样读数据手册、参考手册与 SPL 头文件](./appendix-b-reference-manual-guide.md)
- [附录 C · 调试工具与最小测量方法](./appendix-c-tools-and-measurement.md)
- [附录 D · 全书逐章实验验收路线](./appendix-d-lab-validation.md)
- [教材示例工程约定](./examples/README.md)

---

## ⚠️ SPL 的现状

ST 公司在 2015 年左右停止了 SPL 的更新，转向 HAL 和 LL（低层库）。SPL 的最后版本是 **V3.5.0**，不会再有新版本。

但 SPL 仍然是学习 STM32 的绝佳材料：
- **代码量小、结构清晰**——你能读懂每一行
- **离寄存器近**——`GPIO_SetBits` 本质上就是操作 `BSRR` 寄存器，不像 HAL 藏了好几层
- **学会 SPL 后，HAL 一看就懂**——因为 HAL 是在 SPL 基础上加了抽象层

本书的路线：**SPL 入门 → 建立 MCU/外设直觉 → FreeRTOS 与通信 → 网关实战 → 工程实践**。理解 SPL 后，再迁移到 HAL/LL 会更容易；但本书所有构建约定与示例接口仍以 SPL 为准。

---

> **开始阅读**：[前言](./00-preface.md) → [第 0.5 章 · 硬件零基础生存手册](./00.5-hardware-basics.md)

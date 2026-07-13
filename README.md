# 深入浅出STM32嵌入式开发：从零到IoT网关（SPL标准外设库版）

> **本书是 SPL（标准外设库 / Standard Peripheral Library）版本**
>
> 如果你用的是 **HAL 库 + STM32CubeIDE**，请移步上级目录的 HAL 版本。
>
> 如果你用的是 **Linux + VS Code + arm-none-eabi-gcc + SPL 标准外设库**，你来对地方了。

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
| STM32F103C8T6 最小系统板 | 和 HAL 版用的一样 |
| ST-Link v2 | 调试烧录器 |
| SPL 库文件 | `STM32F10x_StdPeriph_Lib_V3.5.0.zip`（ST 官网下载） |
| 硬件套件 | 和 HAL 版一样（详见上级目录附录 C） |

---

## ⚠️ SPL 的现状

ST 公司在 2015 年左右停止了 SPL 的更新，转向 HAL 和 LL（低层库）。SPL 的最后版本是 **V3.5.0**，不会再有新版本。

但 SPL 仍然是学习 STM32 的绝佳材料：
- **代码量小、结构清晰**——你能读懂每一行
- **离寄存器近**——`GPIO_SetBits` 本质上就是操作 `BSRR` 寄存器，不像 HAL 藏了好几层
- **学会 SPL 后，HAL 一看就懂**——因为 HAL 是在 SPL 基础上加了抽象层

本书的路线：**SPL 入门 → 理解 MCU 本质 → 第 14 章过渡到 HAL → 后续项目用 HAL 提高效率**。这就是「先学开车原理，再开自动挡」。

---

> **开始阅读**：[00-preface.md](./00-preface.md)

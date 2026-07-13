# 第 30 章 · 从原型到产品：结构、测试与升级（SPL版）

> **本章产出**：把“能跑的实验”整理为可维护工程；理解版本、配置、日志、升级和验收为什么是产品的一部分。
>
> **前置知识**：完成至少一个综合项目，并掌握第 28–29 章的调试与低功耗方法。
>
> **提醒**：本章讲工程方法与教学级 Bootloader 骨架，不构成量产安全方案。

---

## 30.1 原型与产品的区别

原型回答“这个想法能不能实现”；产品还必须回答：

- 断电、断网、复位后会怎样？
- 不同设备如何配置身份和密钥？
- 有问题时如何定位？
- 如何升级，升级失败如何恢复？
- 谁验证过它在边界条件下仍能工作？

把这些问题提前写进目录、接口和测试计划，后面会省下大量返工。

## 30.2 推荐目录结构

~~~text
stm32-project/
├── Makefile
├── FreeRTOSConfig.h
├── app/                 应用任务和业务状态机
├── drivers/             led、uart、i2c、sensor 等硬件驱动
├── middleware/          mqtt、fatfs、json 等通用组件
├── platform/            启动文件、链接脚本、时钟、SPL 适配
├── config/              可提交的默认配置与 example 配置
├── tests/               主机侧协议和数据模型测试
├── tools/               烧录、日志解析、打包脚本
└── docs/                接线、版本、故障与发布说明
~~~

依赖方向应尽量单向：app 可以调用 drivers 和 middleware；drivers 不应反过来知道 MQTT Topic 或产品页面。

## 30.3 构建可重复

至少支持下面几个目标：

~~~makefile
all: app.elf app.bin

flash: app.elf
	@openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
	    -c "program $< verify reset exit"

size: app.elf
	@arm-none-eabi-size $<

clean:
	@rm -rf build
~~~

每次发布记录：

| 项目 | 示例 |
|---|---|
| 固件版本 | v0.3.0 |
| Git 提交 | 8 位短 SHA |
| 目标板 | STM32F103ZET6 |
| 编译器 | arm-none-eabi-gcc 版本 |
| 配置模板版本 | config-v2 |

这能避免“我这里能编译，你那里不能”的问题。

## 30.4 配置与密钥

提交到仓库的应是 device_config.h.example；真实 WiFi 密码、Device Secret 和服务器令牌必须在本地或产线配置中注入。

量产设备至少需要：

- 唯一 device_id；
- 独立密钥；
- 固件版本；
- 校准参数；
- 恢复出厂设置的机制。

不要让所有设备共享一个管理员密码或同一份 Secret。

## 30.5 教学级 Bootloader 跳转骨架

Bootloader 的第一步不是跳转，而是验证应用向量表是否看起来合理。下面是帮助理解顺序的骨架，地址和验证规则必须按你的芯片、分区与链接脚本调整。

~~~c
static bool AppVectorLooksValid(uint32_t app_addr)
{
    uint32_t sp = *(const uint32_t *)app_addr;
    uint32_t reset = *(const uint32_t *)(app_addr + 4);

    bool sp_in_sram = (sp & 0x2FFE0000U) == 0x20000000U;
    bool reset_in_flash = (reset & 0xFF000000U) == 0x08000000U;
    return sp_in_sram && reset_in_flash;
}

void JumpToApp(uint32_t app_addr)
{
    if (!AppVectorLooksValid(app_addr)) {
        return;
    }

    uint32_t app_sp = *(const uint32_t *)app_addr;
    uint32_t app_reset = *(const uint32_t *)(app_addr + 4);

    __disable_irq();
    SysTick->CTRL = 0;
    SysTick->LOAD = 0;
    SysTick->VAL = 0;

    SCB->VTOR = app_addr;
    __DSB();
    __ISB();

    __set_MSP(app_sp);
    ((void (*)(void))app_reset)();
}
~~~

真实 OTA 还需要镜像长度、CRC 或签名、掉电保护、回滚、外设去初始化和失败恢复。没有这些，不能称为安全升级。

## 30.6 发布前测试清单

- [ ] 全新克隆后能按文档构建；
- [ ] 烧录、复位和首次配置可重复；
- [ ] 断网、断电、传感器缺失、SD 卡缺失均有预期行为；
- [ ] 栈、堆、队列和环形缓冲区在长时间运行中稳定；
- [ ] 真实密钥没有出现在仓库、日志或截图中；
- [ ] 每个硬件版本都有接线表和已知限制；
- [ ] 固件二进制、版本号和变更说明一起发布。

## 30.7 持续集成、许可证与发布边界

即使暂时没有完整的自动化测试，也应为项目留下可验证的入口：

- 文档链接检查：避免章节导航和附录失效；
- 构建检查：在固定工具链版本下生成 ELF/BIN；
- 静态检查：把编译警告保持为零或明确记录；
- 发布说明：列出目标板、已验证功能、已知限制和升级方式。

许可证属于项目所有者的法律与发布决定，不能随意从别的仓库复制。确定开源方式前，应选择并明确写入 LICENSE；在此之前，不要声称代码可以被任意复用。

## 30.8 给这本书的下一步

完成本书后，你已经能从命令行建立 SPL 工程、读懂寄存器、调试中断、组织 FreeRTOS 任务，并完成一条从传感器到云端的数据链路。

接下来可以选择：

1. 把同一项目迁移到 HAL/CubeIDE，比较两种抽象；
2. 为一个综合项目补齐真实源码、构建脚本和 CI；
3. 选择一项通信协议做更深的可靠性与安全设计；
4. 阅读参考手册，验证每一项时钟和低功耗行为。

## 30.9 一次发布演练：把“别人也能复现”当作验收

发布前用一份干净环境或新目录做演练，不复用你本机的私有文件：

| 项目 | 通过标准 |
|---|---|
| 工具链 | 文档中的版本或最小版本可安装 |
| 构建 | 一条命令生成 ELF、BIN、MAP 和大小报告 |
| 配置 | 示例配置能编译；真实配置不在仓库 |
| 烧录 | 板型、启动文件、链接脚本均为 ZET6/HD |
| 日志 | 启动时打印固件版本、构建标识和关键配置摘要 |
| 回滚 | 已知上一个版本可重新烧录并识别 |
| 文档 | 接线、预期现象、错误恢复和限制完整 |

建议给固件定义可读版本，而不是只依赖 Git 提交号：

~~~c
#define FW_VERSION "0.3.0"
#define FW_TARGET  "STM32F103ZET6/SPL"

void App_PrintBanner(void)
{
    printf("\r\nfw=%s target=%s\r\n", FW_VERSION, FW_TARGET);
}
~~~

### CI 和升级的边界

CI 至少应验证“干净构建、静态检查、文档链接和没有提交密钥”。没有真实板卡的 CI 不能证明外设或低功耗真的正确；硬件验收仍需要记录板卡、接线、测量工具和固件版本。

Bootloader/OTA 也不是“跳到新地址”就结束：镜像来源、长度、CRC/签名、掉电恢复、向量表、回滚和版本兼容性必须共同设计。本书只保留教学骨架，不把它描述为量产方案。

练习：让一位没有参与开发的人，严格按 README、附录 A 和项目章节从零构建并完成 LED/UART 健康检查；把其遇到的每一步摩擦都当作文档缺陷修复。

## 30.10 配置版本、接口演进与发布物清单

能维护的嵌入式项目必须允许“代码升级了，但现场配置还在”。给配置和协议明确版本：

~~~c
typedef struct {
    uint16_t magic;
    uint16_t version;
    uint32_t sequence;
    uint16_t length;
    /* payload + crc */
} PersistentConfigHeader;
~~~

启动时检查 magic、version、length 和 CRC；未知版本要进入明确的迁移或安全默认路径，不能把旧字节强转成新结构体后继续运行。

### 一次发布应产出什么

| 产物 | 用途 |
|---|---|
| `.elf` | GDB/addr2line 调试符号 |
| `.bin/.hex` | 烧录或升级镜像 |
| `.map` 与 size 报告 | 追踪 Flash/SRAM 变化 |
| 版本说明 | 改动、已知限制、迁移/回滚条件 |
| 硬件验收记录 | 板型、接线、工具、测量、日志 |
| 配置模板 | 可公开、可构建、无真实 Secret |
| 校验值 | 确认拿到的镜像确实是该版本 |

### 变更的最小审查问题

1. 这个改动是否改变了硬件引脚、时钟、内存、协议或配置格式？
2. 是否有把正常故障变成断言/死循环，或反过来吞掉了错误？
3. 是否能在没有开发者私有文件的环境重新构建？
4. 是否有测试了断电、断网、复位、队列满和错误帧？
5. 是否更新了版本、迁移说明和已知限制？

练习：模拟把 `EnvSample` 加一个字段的版本升级。写出旧固件、旧日志、PC 网关和新固件各自如何识别或拒绝不兼容数据。

## 30.11 本章要点

- 产品化的核心是可重复构建、可观测、可恢复和可验证；
- 目录与依赖方向决定项目后期是否还能维护；
- 密钥、版本和配置必须被当作产品资产管理；
- Bootloader 需要验证、清理中断和设置向量表；
- 发布前的故障测试比“正常运行演示”更重要。

## 延伸资料

- [附录 A · ZET6、供电与接线速查](./appendix-a-zet6-reference.md)
- [附录 B · 数据手册与参考手册阅读法](./appendix-b-reference-manual-guide.md)
- [附录 C · 调试工具与最小测量方法](./appendix-c-tools-and-measurement.md)
- [附录 D · 全书逐章实验验收路线](./appendix-d-lab-validation.md)



---

[上一章：第 29 章 · 低功耗设计](./29-chapter.md)

[返回目录](./README.md)

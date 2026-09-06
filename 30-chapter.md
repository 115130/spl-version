# 第 30 章 · 从原型到产品：结构、测试与升级（SPL 版）

前面的综合项目证明了功能可以运行。这一章整理交付边界：别人能从干净环境构建同一个固件，设备能识别自己的配置和版本，现场故障有证据可查，升级失败有恢复路径，发布物能对应到具体源码和硬件。

这里的 Bootloader 代码用于解释 Cortex-M3 应用跳转顺序。量产升级还需要镜像认证、密钥保护、掉电恢复、防回滚等设计，本章不提供完整安全方案。

## 30.1 先整理工程依赖

一个可维护的目录可以是：

```text
stm32-project/
├── Makefile
├── app/          任务、业务状态机
├── drivers/      UART、I2C、SPI、传感器等硬件驱动
├── middleware/   MQTT、FatFs、JSON 等组件
├── platform/     启动文件、链接脚本、时钟、SPL 适配
├── config/       默认配置和公开模板
├── tests/        主机侧协议、状态机、配置迁移测试
├── tools/        烧录、打包、日志解析脚本
└── docs/         接线、调试、发布和已知限制
```

`app` 可以依赖驱动和中间件，底层驱动不读取 MQTT Topic、云端账号或产品业务状态。这样更换传感器、网络协议或业务规则时，不需要把整个依赖图一起改掉。

第三方源码也要记录来源和版本。FreeRTOS、FatFs、cJSON、SPL 等组件升级以后，行为和内存占用都可能变化，不能只把一份源码复制进仓库后长期不知道来自哪个版本。

## 30.2 干净环境必须能重复构建

Makefile 至少提供构建、大小检查、烧录和清理入口：

```makefile
all: app.elf app.bin

size: app.elf
	arm-none-eabi-size $<

flash: app.elf
	openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
	    -c "program $< verify reset exit"

clean:
	rm -rf build
```

实际文件名和 OpenOCD 配置以项目为准。发布演练要在新 clone 或干净工作目录中完成，不读取开发者机器上未记录的头文件、环境变量或私有配置。

每个构建保存固件版本、完整 Git commit、目标 MCU/硬件版本、编译器版本和构建参数。短 SHA 可以显示给人看，发布 manifest 中保留完整 commit，避免仓库增长后出现歧义。

## 30.3 配置格式要能识别旧版本

现场设备升级固件时，Flash 中可能仍保存旧配置。持久配置至少带 magic、版本、长度和完整性校验：

```c
typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t length;
    uint32_t sequence;
    /* payload ... */
    /* crc ... */
} PersistentConfigHeader;
```

启动时先验证 header 和 CRC，再按 `version` 选择当前解析器、迁移函数或安全默认配置。未知版本不能直接强转成当前 C 结构体继续运行，因为字段布局、长度和含义都可能已经变化。

配置更新也要定义原子性。常见做法是写入新的完整记录，验证成功后再把它选为当前版本；具体双槽、append log 或页级方案根据 Flash 布局和掉电要求选择。

## 30.4 设备身份和 Secret 不进入仓库

仓库提交公开模板，例如：

```text
config/device.example
```

真实 WiFi 密码、Device Secret、私钥和服务器令牌由本地或产线流程注入。设备身份、密钥、校准数据和硬件版本分别管理，不要让所有设备共享一个管理员凭据。

Secret 如果曾经提交到 Git 历史，处理动作是撤销或轮换对应凭据，再清理历史降低继续泄露的机会。只删除当前文件不能让已经泄露的 Secret 重新变安全。

量产流程还要能回答谁生成凭据、怎样写入、怎样验证、怎样吊销和怎样替换。调试日志不输出 Secret、Authorization 字段或可直接重放的认证材料。

## 30.5 Bootloader 先固定 Flash 分区

STM32F103ZET6 的 Flash 从 `0x08000000` 开始，具体应用起始地址由项目的 Bootloader 分区决定。这个地址必须同时出现在 Bootloader、应用链接脚本、烧录/升级工具和发布 manifest 中。

```text
0x08000000 ─ Bootloader
             ─ 项目定义的边界
APP_BASE   ─ Application 向量表
             ─ Application image
```

分区还要符合目标器件的 Flash 擦除边界，并给 Bootloader 自身、应用和可能的下载/回滚区域留下实际需要的空间。不要从其他工程复制一个 `0x0800xxxx` 偏移就开始链接应用。

链接以后检查 map 文件和向量表地址，确认应用确实从 `APP_BASE` 开始。升级包中的目标硬件版本也要与设备实际硬件匹配。

## 30.6 应用跳转要验证向量表范围

只检查地址高字节过于宽松。项目已经知道 SRAM 和应用 Flash 的实际边界，就直接做范围检查，并确认 Reset Handler 地址带 Thumb bit：

```c
#define SRAM_BASE_ADDR  0x20000000UL
#define SRAM_END_ADDR   0x20010000UL   /* F103ZET6: 64 KB SRAM */

#define APP_BASE_ADDR   APP_BASE       /* 由链接/分区配置提供 */
#define APP_END_ADDR    APP_FLASH_END  /* 项目定义的应用区域末尾 */

static bool AppVectorLooksValid(uint32_t app_addr)
{
    uint32_t sp = *(const uint32_t *)app_addr;
    uint32_t reset = *(const uint32_t *)(app_addr + 4U);
    uint32_t reset_addr = reset & ~1UL;

    bool sp_ok = (sp >= SRAM_BASE_ADDR) &&
                 (sp <= SRAM_END_ADDR) &&
                 ((sp & 0x7U) == 0U);

    bool reset_ok = ((reset & 1U) != 0U) &&
                    (reset_addr >= APP_BASE_ADDR) &&
                    (reset_addr < APP_END_ADDR);

    return sp_ok && reset_ok;
}
```

这里仍只是在检查向量表“看起来合理”。它不能替代镜像长度、完整性和真实性验证。

MSP 初始值允许等于 SRAM 顶端，因此示例对 `SRAM_END_ADDR` 使用 `<=`。具体栈对齐要求还要与所用 ABI、启动代码和项目约束一致。

## 30.7 跳转前清理 Bootloader 留下的运行状态

教学骨架：

```c
typedef void (*AppEntry)(void);

void JumpToApp(uint32_t app_addr)
{
    uint32_t app_sp;
    uint32_t app_reset;

    if (!AppVectorLooksValid(app_addr))
        return;

    app_sp = *(const uint32_t *)app_addr;
    app_reset = *(const uint32_t *)(app_addr + 4U);

    __disable_irq();

    SysTick->CTRL = 0U;
    SysTick->LOAD = 0U;
    SysTick->VAL  = 0U;

    Boot_PeripheralsDeinit();
    Boot_ClearPendingInterrupts();

    SCB->VTOR = app_addr;
    __DSB();
    __ISB();

    __set_MSP(app_sp);
    ((AppEntry)app_reset)();

    for (;;) {
    }
}
```

`Boot_PeripheralsDeinit()` 和 `Boot_ClearPendingInterrupts()` 必须由项目实现，清理 Bootloader 实际启用过的 DMA、UART、定时器、外部中断和 NVIC pending 状态。只调用 `__disable_irq()` 会屏蔽中断响应，但不会自动清除外设 pending 标志。

应用启动代码也要建立自己的中断和外设状态。Bootloader 与 Application 的契约写进文档，避免双方都假定对方已经完成某项初始化。

## 30.8 镜像验证分成完整性和真实性

CRC 或 SHA-256 可以发现传输损坏并标识镜像内容，但不能单独证明镜像来自可信发布者。需要防止未授权固件时，Bootloader 要验证数字签名或等价的认证机制，并保护验证所依赖的信任根。

一个升级 manifest 至少包含目标硬件、版本、镜像长度、镜像摘要和格式版本。是否允许降级、怎样处理配置迁移、签名算法和密钥轮换都属于升级协议的一部分。

掉电恢复也要有明确状态。设备在擦除旧应用、写新镜像、验证镜像和切换启动目标的任一步骤掉电后，都应有定义好的下一次启动行为。单应用区直接覆盖时尤其要评估失败后是否还存在可启动代码。

## 30.9 Watchdog 要检查系统是否真的在前进

IWDG 可以帮助系统从死锁或失控状态恢复，但喂狗点放错以后也可能掩盖故障。不要只在高优先级定时器或 idle hook 中无条件喂狗。

可以由各关键任务更新自己的 progress counter 或 heartbeat，HealthTask 检查 SensorTask、NetworkTask、LogTask 等是否在允许时间内继续推进。只有满足项目定义的健康条件时才喂 IWDG。

Watchdog timeout 要大于经过验证的最长合法阻塞时间，并覆盖 Flash 擦写、SD 同步、网络退避等项目实际路径。具体数值由测量和故障策略决定。

复位启动时尽早读取 RCC reset flags，记录上一次是 POR、外部复位、软件复位还是 watchdog 等原因，再按参考手册要求清除标志。这样现场连续重启时能留下基本证据。

## 30.10 CI 只声明它实际验证过的内容

CI 适合自动执行：

- 固定工具链下的干净构建；
- 编译警告和静态检查；
- 主机侧 Parser、CRC、状态机和配置迁移测试；
- Markdown 链接和章节导航检查；
- Secret 扫描；
- ELF/BIN/MAP、size 报告和发布 manifest 生成。

没有真实板卡的 CI 不能证明 I2C 时序、WiFi 峰值供电、Stop 电流或执行器动作正确。硬件测试保留板型、模块固件、接线、测量工具、固件 commit 和结果，作为发布记录的一部分。

如果以后接入硬件在环测试，也要把“跑了哪些板、哪些故障注入、通过条件是什么”写清楚，不能只用一个绿色状态代替测试范围。

## 30.11 发布物必须能回到源码和测试证据

每个版本生成一个 manifest，例如：

```text
firmware:
  version: v0.3.0
  target: STM32F103ZET6 / STM32F10X_HD
  git_commit: <full commit>
  toolchain: arm-none-eabi-gcc <version>
artifacts:
  app.bin.sha256: <...>
  app.elf.sha256: <...>
memory:
  flash_used: <...>
  sram_used: <...>
validation:
  build: pass
  host_tests: pass
  docs_check: pass
  hardware_record: <id/path>
known_limits:
  - <...>
```

发布目录保留 `.elf`、`.bin`/`.hex`、`.map`、size 报告、manifest、配置模板、版本说明和硬件验收记录。ELF 用于 GDB/addr2line，map 和 size 用于追踪 Flash/SRAM 变化，二进制摘要用于确认拿到的是同一份发布物。

发布说明写清配置是否需要迁移、能否回滚、支持哪些硬件版本和已知限制。版本号本身不包含这些信息。

## 30.12 发布前做一次干净演练

让一个没有参与当前修改的人或一套新的环境按 README 完成：

```text
clone
  → 安装记录的工具链
  → 使用公开 example 配置构建
  → 检查 ELF/BIN/MAP/size
  → 烧录指定硬件
  → 完成 LED/UART 健康检查
  → 执行该版本要求的硬件故障测试
```

至少覆盖断电、复位、网络不可用、传感器缺失、存储故障、Queue 压力和协议错误中与当前产品有关的路径。升级功能还要测试镜像损坏、版本不兼容、升级中掉电和恢复路径。

演练中发现“只有开发者电脑上才有的文件”“必须手工改一个没写进 README 的宏”或“发布包找不到对应 ELF”，都直接作为发布缺陷修复。

## 30.13 本章完成标准

项目准备发布时，应能回答：

- 一个干净环境怎样构建同一份固件；
- 发布二进制对应哪个完整 Git commit、工具链和硬件版本；
- 旧配置如何验证、迁移或拒绝；
- 每台设备的身份和 Secret 从哪里注入、怎样轮换；
- Bootloader、链接脚本和升级工具怎样共享同一个应用分区；
- 镜像损坏和未授权镜像分别由什么机制发现；
- 升级中断电以后设备从哪里恢复；
- watchdog 根据哪些任务进度决定喂狗；
- CI 验证了什么，哪些结论来自真实硬件测试；
- 发布包中的 ELF、map、manifest 和验收记录怎样互相对应。

这些信息能从仓库和发布记录中直接找到，项目才具备继续维护、升级和排查现场问题的基础。

## 延伸资料

- [附录 A · ZET6、供电与接线速查](./appendix-a-zet6-reference.md)
- [附录 B · 数据手册与参考手册阅读法](./appendix-b-reference-manual-guide.md)
- [附录 C · 调试工具与最小测量方法](./appendix-c-tools-and-measurement.md)
- [附录 D · 全书逐章实验验收路线](./appendix-d-lab-validation.md)

> **上一章**：[第 29 章 · 低功耗设计](./29-chapter.md)
>
> **返回目录**：[README](./README.md)

# 第 13 章 · 存储语义：原始 NOR 日志与 FatFs 的正确边界

> **本章产出**：能安全地读、擦、页写一个外部 SPI NOR；能设计掉电后可扫描恢复的追加日志；知道 FatFs 应接到 SD 块设备或经过验证的翻译层，而不是直接套在裸 NOR 上。
>
> **前置知识**：第 11 章 SPI/SDIO、第 12 章 DMA（SD 卡大块传输时使用）。
>
> **本章边界**：本章不假定板上一定有某一颗 W25Q，也不提供未经实现的“Flash 上 FatFs”捷径。先建立可验证的存储语义，再选择文件系统。

## 13.1 先按介质的物理规则设计

STM32F103ZET6 的内部 Flash 为 512 KiB，SRAM 为 64 KiB；高密度 F103 的内部 Flash 擦除页为 **2 KiB**。外部 SPI NOR 的容量、页大小、扇区大小、指令集和擦写次数则取决于实物芯片，必须由 JEDEC ID 与数据手册确认。

| 介质 | 擦除 / 写入事实 | 合适用途 | 不应假设 |
|---|---|---|---|
| STM32 内部 Flash | 按页擦除；编程/擦除会影响从 Flash 取指 | 程序、少量关键配置 | 可以像 RAM 一样频繁改一个字节 |
| SPI NOR Flash | 先擦后写，写只能把位从 1 变 0；通常页编程、扇区擦除 | 资源、追加日志、受控分区 | 擦一扇区后仍能保留其中其他文件 |
| SD 卡 | 对上层呈现 512 字节块；卡内部有自己的控制器 | FatFs、可交换文件、批量日志 | 断电时写入必然原子完成 |

第 11 章的 SPI 是事务层，不保证这些介质语义；第 13 章的设计必须在事务层之上显式处理范围、擦除、忙状态、校验与掉电。

### 13.1.1 首次连通只验证“这颗芯片能说话”

对兼容 JEDEC 的 NOR，`0x9F` 常可读出厂商、类型和容量编码。它是很好的 SPI 验收命令，但不能单凭某个常见值就把容量写死为 8 MiB。保存识别结果后，用一个几何结构驱动范围检查：

```c
typedef struct {
    uint32_t capacity_bytes;
    uint32_t erase_unit_bytes;
    uint16_t page_bytes;
} NorGeometry;

/* 仅在识别值与对应数据手册均确认后填写。 */
static NorGeometry g_nor;
```

对于使用 3 字节地址命令的器件，地址空间本身最多覆盖 16 MiB。容量更大的芯片可能需要 4 字节地址模式或其他厂商命令；不要把本章的 3 字节示例扩展到未知容量。

## 13.2 原始 NOR 的安全基础层

### 13.2.1 擦除必须有明确的授权范围

擦除是破坏性操作。第一次实验只允许碰一个在配置中明确命名的测试分区，绝不接受“任意地址都可以擦”：

```c
#define NOR_TEST_BASE  0x00100000UL  /* 由你的分区表决定，不是通用常量 */
#define NOR_TEST_SIZE  0x00010000UL

static bool Nor_IsInTestPartition(uint32_t address, uint32_t length)
{
    return length <= NOR_TEST_SIZE &&
           address >= NOR_TEST_BASE &&
           address - NOR_TEST_BASE <= NOR_TEST_SIZE - length;
}
```

这里的减法顺序很重要：先确认 `address >= base`，再计算 `address - base`，避免无符号下溢把越界地址误判为安全。真实项目应把分区表集中在一个文件中，并为启动镜像、资源、日志、工厂数据分别指定不可重叠范围。

### 13.2.2 页写的前置条件

绝大多数常见 SPI NOR 的 Page Program 不能跨页：如果页为 256 字节，地址低 8 位为 250 时最多只可写 6 个字节。跨页的行为常是地址在同一页内回绕，导致“前面几字节看似正确，页首被悄悄覆盖”。因此把边界检查放进最低层接口。

以下代码把底层 SPI 事务抽象为 `Nor_Begin()`、`Nor_End()` 和 `Nor_TxRx()`；它们应使用第 11 章的 CS、`BSY` 与超时规则。故意不在这里再复制一个没有超时的 `SPI_Transfer()`。

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "timebase.h"

typedef enum {
    NOR_OK = 0,
    NOR_ARGUMENT,
    NOR_RANGE,
    NOR_ALIGNMENT,
    NOR_BUS_ERROR,
    NOR_WEL_NOT_SET,
    NOR_TIMEOUT
} NorResult;

bool Nor_Begin(void);                 /* CS 拉低，取得 SPI 总线所有权 */
bool Nor_End(void);                   /* 等 BSY=0，再释放 CS */
bool Nor_TxRx(uint8_t tx, uint8_t *rx);

static bool Nor_RangeValid(uint32_t address, uint32_t length)
{
    return length <= g_nor.capacity_bytes &&
           address <= g_nor.capacity_bytes - length;
}

static NorResult Nor_ReadStatus(uint8_t *status)
{
    uint8_t ignored;

    if (status == NULL || !Nor_Begin() ||
        !Nor_TxRx(0x05U, &ignored) ||
        !Nor_TxRx(0xFFU, status) || !Nor_End()) {
        return NOR_BUS_ERROR;
    }
    return NOR_OK;
}

static NorResult Nor_WaitReady(uint32_t timeout_ms)
{
    const uint32_t start = Timebase_NowMs();
    uint8_t status;

    for (;;) {
        if (Nor_ReadStatus(&status) != NOR_OK) {
            return NOR_BUS_ERROR;
        }
        if ((status & 0x01U) == 0U) {  /* WIP = 0 */
            return NOR_OK;
        }
        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms) {
            return NOR_TIMEOUT;
        }
    }
}

static NorResult Nor_WriteEnable(void)
{
    uint8_t ignored;
    uint8_t status;

    if (!Nor_Begin() || !Nor_TxRx(0x06U, &ignored) || !Nor_End()) {
        return NOR_BUS_ERROR;
    }
    if (Nor_ReadStatus(&status) != NOR_OK) {
        return NOR_BUS_ERROR;
    }
    return (status & 0x02U) != 0U ? NOR_OK : NOR_WEL_NOT_SET;
}
```

`WIP`（write in progress）和 `WEL`（write enable latch）的位定义、指令码与超时上限必须按你的芯片数据手册确认。上面的写使能检查是故障早发现，不是对所有兼容品的保证。

### 13.2.3 只写一页的接口

```c
NorResult Nor_ProgramOnePage(uint32_t address, const uint8_t *data,
                             uint16_t length, uint32_t timeout_ms)
{
    uint16_t i;
    uint8_t ignored;

    if (data == NULL || length == 0U || length > g_nor.page_bytes) {
        return NOR_ARGUMENT;
    }
    if (!Nor_RangeValid(address, length)) {
        return NOR_RANGE;
    }
    if ((uint32_t)(address % g_nor.page_bytes) + length > g_nor.page_bytes) {
        return NOR_ALIGNMENT;
    }
    {
        const NorResult wel = Nor_WriteEnable();
        if (wel != NOR_OK) {
            return wel;
        }
    }
    if (!Nor_Begin()) {
        return NOR_BUS_ERROR;
    }

    if (!Nor_TxRx(0x02U, &ignored) ||       /* Page Program：需按芯片确认 */
        !Nor_TxRx((uint8_t)(address >> 16), &ignored) ||
        !Nor_TxRx((uint8_t)(address >> 8), &ignored) ||
        !Nor_TxRx((uint8_t)address, &ignored)) {
        (void)Nor_End();
        return NOR_BUS_ERROR;
    }
    for (i = 0U; i < length; ++i) {
        if (!Nor_TxRx(data[i], &ignored)) {
            (void)Nor_End();
            return NOR_BUS_ERROR;
        }
    }
    if (!Nor_End()) {
        return NOR_BUS_ERROR;
    }
    return Nor_WaitReady(timeout_ms);
}
```

写任意长度数据的上层函数必须按“当前页剩余空间”分段调用 `Nor_ProgramOnePage()`；擦除函数同理应拒绝未按 `erase_unit_bytes` 对齐的地址。写后立刻读回并逐字节比较，才是第一次实验的验收。SPI/DMA 可以减少 CPU 参与传输的时间，但**编程和擦除期间的 WIP 仍需要轮询或做成异步状态机**，不能据此宣称“Flash 写入不阻塞”。

## 13.3 追加日志：把掉电当作正常事件

原始 NOR 最适合先做追加式日志：从空白区域顺序向后写，写满一个擦除单元后切到下一个。它避免了“把旧数据改回 1”这一难题，并让恢复过程可以只扫描记录。

### 13.3.1 一条记录应有哪些逻辑字段

不要直接把 C 结构体裸写进 Flash：编译器填充、字节序和未来字段变动都会破坏兼容性。定义固定的字节序列化格式，例如：

```text
magic | format_version | header_length | payload_length | sequence
      | payload_crc32 | ...可扩展字段... | payload | commit_word
```

其中：

- `magic` 防止把擦除态或随机数据当记录；
- `format_version` 和 `header_length` 允许以后扩展；
- `payload_length` 必须先做分区范围检查，不能相信损坏值；
- `sequence` 用于找最新记录、发现缺失；
- `payload_crc32` 覆盖 payload；
- `commit_word` 独立放在最后，擦除态为全 `1`，完成态只把某些位编程为 `0`。

一次安全的写入顺序是：预先擦好当前擦除单元 → 写未提交的头 → 分页写 payload → 读回/校验必要部分 → 最后只写 `commit_word`。掉电后，扫描器只有同时满足“头合法、长度在界内、commit 完成、CRC 正确”的记录才交给应用。

若在未提交/损坏记录处断电，不能盲目信任其中的长度以跳到“下一条”。简单安全策略是把该擦除单元余下区域视为不可用，切换到下一个已擦除单元；之后按你的数据保留策略再回收这一单元。循环使用多个擦除单元并轮转写入位置，才能均匀分摊擦除寿命。

### 13.3.2 启动扫描的责任

启动恢复程序至少应输出：扫描到的最后合法 `sequence`、跳过的损坏/未提交记录数、当前可写位置、每个擦除单元的状态。这样你才能通过断电实验回答“最多丢哪一条记录”，而不是只说“理论上有 CRC”。

对内部 Flash 做同类日志时，页大小应按 ZET6 的 2 KiB 处理；更重要的是遵守 F1 编程/擦除流程，并评估中断与代码取指受 Flash 操作影响的时段。小配置若需要频繁更新，也应使用页轮换和序号，不要反复擦同一页。

## 13.4 FatFs 的正确底座：512 字节块设备

FatFs 是 FAT 文件系统实现。它期望的底层介质语义是：给出逻辑扇区号和数量，可靠地读/写完整扇区，并在 `CTRL_SYNC` 时完成底层同步。最自然的介质是已经完成初始化的 SD 卡块驱动。

```text
应用（日志 / 配置文件）
        ↓
FatFs: f_open / f_write / f_sync / f_close
        ↓
diskio.c: disk_read / disk_write / disk_ioctl
        ↓
SD 块设备：读写 512 字节逻辑扇区，处理 SDSC/SDHC 地址差异
        ↓
SDIO 状态机 + DMA（第 11、12 章）
```

裸 SPI NOR 不能直接假装成 SD 卡。FAT 会在任意扇区反复更新目录、FAT 表和文件内容，而 NOR 需要先擦除整个较大单元、且擦除会毁掉邻近扇区。仅仅“地址每 4 KiB 时擦一次，再页写两个 256 字节”会在 FAT 更新时破坏已有文件。若确实要在 NOR 上使用 FatFs，必须先实现并验证磨损均衡、擦除块回收、逻辑到物理映射与掉电恢复的 FTL/托管 Flash 层；这是一项独立工程，不是 `diskio.c` 的几行代码。

### 13.4.1 `diskio.c` 的语义契约

以下是接 SD 卡时应该满足的语义，而不是可直接复制的完整驱动。具体的 `LBA_t`、`UINT` 与是否需要 `disk_write` 取决于你所用 FatFs 版本和 `ffconf.h` 配置。

```c
DRESULT disk_read(BYTE pdrv, BYTE *buffer, LBA_t sector, UINT count)
{
    if (pdrv != 0U || buffer == NULL || count == 0U || !Sd_IsReady()) {
        return RES_NOTRDY;
    }
    return Sd_ReadBlocks((uint32_t)sector, buffer, count)
         ? RES_OK : RES_ERROR;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buffer, LBA_t sector, UINT count)
{
    if (pdrv != 0U || buffer == NULL || count == 0U || !Sd_IsReady()) {
        return RES_NOTRDY;
    }
    return Sd_WriteBlocks((uint32_t)sector, buffer, count)
         ? RES_OK : RES_ERROR;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE command, void *buffer)
{
    if (pdrv != 0U || !Sd_IsReady()) {
        return RES_NOTRDY;
    }
    switch (command) {
    case CTRL_SYNC:        return Sd_Synchronize() ? RES_OK : RES_ERROR;
    case GET_SECTOR_SIZE:  *(WORD *)buffer = 512U; return RES_OK;
    case GET_SECTOR_COUNT: return Sd_GetSectorCount((LBA_t *)buffer)
                              ? RES_OK : RES_ERROR;
    case GET_BLOCK_SIZE:   return Sd_GetEraseBlockSectors((DWORD *)buffer)
                              ? RES_OK : RES_ERROR;
    default:               return RES_PARERR;
    }
}
```

块驱动应对上层隐藏 SDSC 的字节地址与 SDHC/SDXC 的块地址差异；FatFs 只看到从 0 开始的 512 字节 LBA。任一次 `Sd_ReadBlocks` 或 `Sd_WriteBlocks` 要么完成请求的所有扇区，要么返回失败，不能在已写一半时仍返回 `RES_OK`。

### 13.4.2 应用层写文件也有失败边界

一次日志写入至少检查每个 `FRESULT` 和写入字节数，并在希望落盘的位置调用 `f_sync()`：

```c
FRESULT WriteOneRecord(FIL *file, const void *record, UINT length)
{
    UINT written = 0U;
    FRESULT result = f_write(file, record, length, &written);

    if (result != FR_OK || written != length) {
        return (result == FR_OK) ? FR_DISK_ERR : result;
    }
    return f_sync(file);
}
```

`f_sync()` 和 `f_close()` 也可能失败，必须被日志服务记录。它们能请求 FatFs/块驱动提交数据，但不能让突然断电的所有硬件内部状态变成绝对原子；重要日志仍应有序号、长度和应用级 CRC。首次格式化是破坏性维护操作：只在明确的维护模式、确认设备为空且按当前 FatFs 版本 `ff.h` 的 `f_mkfs` 签名调用，不要把某一版本的四参数示例硬塞进所有工程。

## 13.5 验收与故障定位

### 原始 NOR 的四阶段验收

1. **识别**：低速 SPI 下连续读 ID，断开 CS/MISO 时能得到可诊断错误。
2. **擦写**：只擦预定义测试分区；页内写、跨页拒绝、读回逐字节比较。
3. **边界**：尝试越过容量、页尾和擦除单元边界，所有操作必须拒绝且不修改邻近数据。
4. **掉电**：在头、payload、commit 三个阶段分别复位；启动扫描只接受完整 CRC 记录。

### FatFs/SD 的验收

| 测试 | 通过条件 |
|---|---|
| 挂载已格式化 SD 卡 | `f_mount` 成功，容量与块驱动一致 |
| 写入后读回 | 比较全部字节，不只打印字符串开头 |
| 拔卡/初始化失败 | `diskio` 返回错误，主循环仍可运行 |
| `f_sync` 后复位 | 文件系统能挂载，应用记录能识别最近完整条目 |
| 未格式化卡 | 仅在明确维护流程下格式化；普通运行报 `FR_NO_FILESYSTEM` |

| 现象 | 优先检查 |
|---|---|
| NOR 写入后页首被改 | 一次 Page Program 跨了页边界 |
| NOR 擦完后其他数据丢失 | 擦除单元/分区边界设计错误 |
| NOR 一直忙 | WIP 轮询无超时、CS 时序错误或供电异常 |
| FatFs 写一次后旧文件坏 | 试图把裸 NOR 伪装为可随机覆写磁盘 |
| 文件存在但最后记录缺失 | 未检查 `f_sync`/`f_close`，或掉电策略未定义 |

### 练习

1. 定义一个以小端或大端明确编码的日志头，并为它写 encode/decode 单元测试向量。
2. 让写入器在每一页后故意复位，验证扫描器永不接受未提交记录。
3. 为 NOR 分区表加一个“只读资源区”和“可擦日志区”，并在 API 层拒绝跨区操作。
4. 为 SD `diskio.c` 记录最后一个命令错误、最后一个数据错误和失败 LBA；用它解释一次拔卡失败。
5. 比较“原始追加日志”和“FatFs 文件日志”在掉电恢复、电脑可读性、实现成本上的取舍。

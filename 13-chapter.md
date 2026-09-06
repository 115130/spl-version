# 第 13 章 · 存储语义：NOR 日志与 FatFs

这一章处理两种存储路线。外部 SPI NOR 用来做受控分区和追加日志；SD 卡通过 512 字节块设备接入 FatFs。两类介质的写入规则不同，驱动接口也不能混在一起。

STM32F103ZET6 内部 Flash 为 512 KiB，SRAM 为 64 KiB。外部 NOR 的容量、页大小、擦除单元和指令集必须根据 JEDEC ID 和对应数据手册确认，不能写死成某个常见 W25Q 型号。

## 13.1 先按介质规则设计

NOR Flash 写入前要先保证目标位处于擦除态。编程通常只能把位从 1 写成 0，恢复成 1 需要擦除整个擦除单元。常见 NOR 还要求 Page Program 不能跨页，具体页大小和擦除粒度由芯片决定。

SD 卡对上层提供逻辑块接口。块设备层按 LBA 读写完整扇区，卡内部怎样擦写 NAND 由卡控制器处理。FatFs 依赖的正是这种随机读写块语义。

这两个差异决定了后面的结构：NOR 先做顺序追加和分区保护；FatFs 放在 SD 块设备上。若要在裸 NOR 上运行 FAT，需要额外实现逻辑到物理映射、擦除块回收、磨损均衡和掉电恢复，这已经属于独立的 FTL 层。

## 13.2 先识别 NOR 几何参数

兼容 JEDEC 的 NOR 通常可以用 `0x9F` 读取识别信息。读到 ID 后，再根据数据手册填入几何参数：

```c
typedef struct {
    uint32_t capacity_bytes;
    uint32_t erase_unit_bytes;
    uint16_t page_bytes;
} NorGeometry;

static NorGeometry g_nor;
```

容量决定地址范围，`page_bytes` 决定一次 Page Program 的边界，`erase_unit_bytes` 决定擦除对齐。使用 3 字节地址命令时可直接覆盖的地址范围最多是 16 MiB；更大器件可能需要 4 字节地址模式或厂商规定的切换方式。

识别阶段先连续读几次 ID，确认结果稳定。断开 CS、MISO 或器件供电时，也应该得到可诊断的失败，而不是把 `0xFF` 当成正常 ID 继续运行。

## 13.3 擦除和写入必须限制范围

第一次实验只允许操作一个明确的测试分区。比如：

```c
#define NOR_TEST_BASE  0x00100000UL
#define NOR_TEST_SIZE  0x00010000UL

static bool Nor_IsInTestPartition(uint32_t address, uint32_t length)
{
    return length <= NOR_TEST_SIZE &&
           address >= NOR_TEST_BASE &&
           address - NOR_TEST_BASE <= NOR_TEST_SIZE - length;
}
```

这里先判断 `address >= NOR_TEST_BASE`，再做无符号减法，避免下溢。实际项目应把启动镜像、只读资源、配置和日志分区统一放在一个分区表里，底层 API 直接拒绝跨区访问。

页写也要在最低层检查边界。假设页大小为 256 字节，从页内偏移 250 开始时，本次最多写 6 字节；超过页尾应直接返回错误，由上层拆成两次 Page Program。

## 13.4 NOR 的最小状态接口

下面继续使用第 11 章已经建立的 SPI 事务层：

```c
bool Nor_Begin(void);
bool Nor_End(void);
bool Nor_TxRx(uint8_t tx, uint8_t *rx);
```

再定义 NOR 层自己的错误码：

```c
typedef enum {
    NOR_OK = 0,
    NOR_ARGUMENT,
    NOR_RANGE,
    NOR_ALIGNMENT,
    NOR_BUS_ERROR,
    NOR_WEL_NOT_SET,
    NOR_TIMEOUT
} NorResult;
```

范围检查：

```c
static bool Nor_RangeValid(uint32_t address, uint32_t length)
{
    return length <= g_nor.capacity_bytes &&
           address <= g_nor.capacity_bytes - length;
}
```

常见 NOR 会提供状态寄存器，其中 WIP 表示器件仍在编程或擦除，WEL 表示写使能已置位。具体位定义仍要看芯片数据手册。

```c
static NorResult Nor_ReadStatus(uint8_t *status)
{
    uint8_t ignored;

    if (status == NULL ||
        !Nor_Begin() ||
        !Nor_TxRx(0x05U, &ignored) ||
        !Nor_TxRx(0xFFU, status) ||
        !Nor_End()) {
        return NOR_BUS_ERROR;
    }

    return NOR_OK;
}

static NorResult Nor_WaitReady(uint32_t timeout_ms)
{
    uint32_t start = Timebase_NowMs();
    uint8_t status;

    for (;;) {
        if (Nor_ReadStatus(&status) != NOR_OK)
            return NOR_BUS_ERROR;

        if ((status & 0x01U) == 0U)
            return NOR_OK;

        if ((uint32_t)(Timebase_NowMs() - start) >= timeout_ms)
            return NOR_TIMEOUT;
    }
}
```

这里的 `0x05`、WIP bit0 都必须和目标芯片手册一致。

写使能后再读一次状态，可以提前发现总线或器件状态异常：

```c
static NorResult Nor_WriteEnable(void)
{
    uint8_t ignored;
    uint8_t status;

    if (!Nor_Begin() ||
        !Nor_TxRx(0x06U, &ignored) ||
        !Nor_End()) {
        return NOR_BUS_ERROR;
    }

    if (Nor_ReadStatus(&status) != NOR_OK)
        return NOR_BUS_ERROR;

    return (status & 0x02U) != 0U
         ? NOR_OK : NOR_WEL_NOT_SET;
}
```

## 13.5 只写一页

最低层页写接口只接受单页范围内的数据：

```c
NorResult Nor_ProgramOnePage(uint32_t address,
                             const uint8_t *data,
                             uint16_t length,
                             uint32_t timeout_ms)
{
    uint16_t i;
    uint8_t ignored;
    NorResult r;

    if (data == NULL || length == 0U || length > g_nor.page_bytes)
        return NOR_ARGUMENT;

    if (!Nor_RangeValid(address, length))
        return NOR_RANGE;

    if ((uint32_t)(address % g_nor.page_bytes) + length > g_nor.page_bytes)
        return NOR_ALIGNMENT;

    r = Nor_WriteEnable();
    if (r != NOR_OK)
        return r;

    if (!Nor_Begin())
        return NOR_BUS_ERROR;

    if (!Nor_TxRx(0x02U, &ignored) ||
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

    if (!Nor_End())
        return NOR_BUS_ERROR;

    return Nor_WaitReady(timeout_ms);
}
```

任意长度写入由上层按当前页剩余空间拆分。擦除函数也应检查地址和长度是否按 `erase_unit_bytes` 对齐，并且只允许操作可擦分区。

第一次验收不要只看函数返回值。写完后把目标区域重新读回，逐字节比较；再测试页尾、容量边界和未擦除区域，确认 API 会按预期拒绝或失败。

## 13.6 追加日志和掉电恢复

原始 NOR 很适合做追加日志。预先擦好一个擦除单元，从头向后顺序写记录；当前单元空间不足时，再切到下一个已擦除单元。

记录格式不要直接使用裸 C 结构体。编译器填充、字节序和后续字段变化都会影响兼容性。可以定义固定的序列化格式：

```text
magic
format_version
header_length
payload_length
sequence
payload_crc32
payload
commit_word
```

`payload_length` 必须先做范围检查；`sequence` 用来排序和发现缺口；CRC 用来判断 payload 是否完整。`commit_word` 单独放在最后，擦除态保持全 1，整条记录写完并校验后，再把其中预定的位写成 0。

一次记录的写入顺序可以是：

1. 写未提交的头部；
2. 分页写 payload；
3. 读回并检查关键内容或 CRC；
4. 最后写 `commit_word`。

启动扫描时只接受头部合法、长度在分区范围内、commit 已完成并且 CRC 正确的记录。若在一条未完成记录处发现损坏，简单做法是放弃当前擦除单元剩余空间，切换到下一个单元，避免信任损坏的长度字段继续跳转。

循环轮换多个擦除单元还能分散擦除次数。若日志长期运行，还需要记录当前写位置和回收策略，不能始终擦同一个扇区。

## 13.7 FatFs 接到 SD 块设备

FatFs 通过 `diskio.c` 访问块设备。对于本书的 SD 路线，上层只看到从 0 开始编号的 512 字节逻辑扇区：

```text
应用
  ↓
FatFs: f_open / f_write / f_sync / f_close
  ↓
diskio.c
  ↓
SD 块设备：LBA + 扇区数量
  ↓
SDIO 状态机 + DMA
```

块设备层负责隐藏 SDSC 字节地址和 SDHC/SDXC 块地址的差异。FatFs 不应该知道 CMD17、CMD24 或 DMA2 Channel 4。

一个最小 `disk_read()` 可以长这样：

```c
DRESULT disk_read(BYTE pdrv,
                  BYTE *buffer,
                  LBA_t sector,
                  UINT count)
{
    if (pdrv != 0U ||
        buffer == NULL ||
        count == 0U ||
        !Sd_IsReady()) {
        return RES_NOTRDY;
    }

    return Sd_ReadBlocks((uint32_t)sector, buffer, count)
         ? RES_OK : RES_ERROR;
}
```

写接口同样要求：请求的扇区必须全部完成后才能返回 `RES_OK`。如果底层只完成了一部分，就应该把整个调用视为失败，并保留具体失败 LBA 和 SD 错误码供诊断。

`disk_ioctl()` 至少要正确处理当前 FatFs 配置需要的命令，例如 `CTRL_SYNC`、扇区大小和扇区数量。接口类型和函数签名以实际使用的 FatFs 版本为准，不要从旧教程直接复制。

## 13.8 文件写入也要检查结果

应用层写文件时，`f_write()` 返回 `FR_OK` 还不够，还要确认实际写入字节数：

```c
FRESULT WriteOneRecord(FIL *file,
                       const void *record,
                       UINT length)
{
    UINT written = 0U;
    FRESULT result;

    result = f_write(file, record, length, &written);
    if (result != FR_OK)
        return result;

    if (written != length)
        return FR_DISK_ERR;

    return f_sync(file);
}
```

`f_sync()` 和 `f_close()` 也可能失败，日志服务要记录这些错误。`f_sync()` 会推动 FatFs 和块设备提交缓存，但它不能让突然掉电变成绝对原子操作。重要应用日志仍然适合带序号、长度和应用级校验，这样重启后可以识别最后一条完整记录。

格式化属于破坏性操作。普通启动流程遇到 `FR_NO_FILESYSTEM` 时应报告状态，不要自动 `f_mkfs()`。只有明确进入维护或首次初始化流程后，才允许格式化选定的存储设备。

## 13.9 验证和排错

NOR 先做四组实验：稳定读 ID；只在测试分区做擦写并读回比较；故意传入跨页、越界和未对齐参数；最后在记录头、payload、commit 三个阶段分别复位，检查启动扫描结果。

FatFs 则先验证块设备。读一个已知扇区并和 PC 上的十六进制内容比较，再测试多扇区读写。块层可靠后再挂载文件系统，创建文件、写入、`f_sync()`、重新挂载并逐字节读回。

如果 NOR 页首被意外覆盖，先查 Page Program 是否跨页；擦掉邻近数据则查擦除单元和分区边界。FatFs 写一次后旧文件损坏时，先确认底层是不是把裸 NOR 当成随机可覆写块设备，或者 SD 块写接口有没有在部分失败时错误返回成功。

## 13.10 练习

1. 定义固定字节序的日志头，并写 encode/decode 测试向量，确认编译器结构体布局不会影响 Flash 格式。
2. 在每个 Page Program 后主动复位，验证启动扫描不会接受没有 commit 的记录。
3. 给 NOR 分区表增加只读资源区和可擦日志区，并测试所有跨区操作都会被拒绝。
4. 给 SD 块设备记录最后失败的 LBA、命令错误和数据错误，用拔卡实验验证诊断信息。
5. 对同一份传感器日志分别实现 NOR 追加记录和 FatFs 文件写入，比较掉电恢复、PC 可读性和代码复杂度。

完成这一章后，存储层应该有明确分工：NOR 驱动遵守擦除和页写边界，追加日志负责掉电恢复；SD 驱动提供完整 512 字节块语义，FatFs 只工作在这个块设备接口之上。

# 第 13 章 · 存储器与文件系统

> **本章产出**：能从 SPI Flash 的页写、扇区擦除和掉电边界出发，设计一个可检查的本地日志；理解“写成功返回”不等于永远不会丢数据。
>
> **前置知识**：第 11 章 SPI、第 12 章 DMA（可选）；第 8 章 UART 用于打印文件系统错误码。
>
> **硬件准备**：3.3V W25Q 系列或兼容 SPI Flash；确认 CS、WP、HOLD 和供电，先在空白或可擦除的测试芯片上实验。

> **本章覆盖**：W25Q64 SPI Flash 驱动、FatFs 文件系统移植、SPI Flash 上读写文件
>
> **用到项目的哪里**：存储配置参数、日志记录、字库/图片资源

## 13.1 为什么需要外部存储器

你的 ZET6 有 512KB 内部 Flash，但：

| 需求 | 需要多大 | 内部 Flash 够吗 |
|------|---------|----------------|
| 存几张图片（128×64 OLED） | 128×64×8bit/张 ≈ 8KB | ✅ |
| 汉字字库（16×16 点阵，常用 6763 字）| 6763×32 ≈ 216KB | ❌ 太大 |
| 记录传感器日志（每小时 1KB，存一年） | 1KB×24×365 ≈ 8.7MB | ❌ |
| 固件升级包（OTA） | 几十到几百 KB | ❌ |

**你的板子上**：**W25Q64**（8MB SPI NOR Flash）就是干这个的。它挂在 SPI1（PA5/PA6/PA7），CS 用 PB12。

## 13.2 W25Q64 SPI Flash 驱动

### 接线

第 11 章已经配置了 SPI1，引脚直接复用：

| SPI1 信号 | STM32 | W25Q64 |
|-----------|-------|--------|
| SCK | PA5 | CLK |
| MISO | PA6 | DO |
| MOSI | PA7 | DI |
| CS | PB12 | CS# |

### 基本操作

W25Q64 的命令很简单——发命令码 + 参数，然后收/发数据：

```c
#define FLASH_CS_LOW()   GPIO_ResetBits(GPIOB, GPIO_Pin_12)
#define FLASH_CS_HIGH()  GPIO_SetBits(GPIOB, GPIO_Pin_12)
```

#### 读 JEDEC ID（验证通信）

```c
uint32_t Flash_ReadID(void) {
    FLASH_CS_LOW();
    SPI_Transfer(0x9F);                          // JEDEC ID 命令
    uint32_t id  = SPI_Transfer(0xFF) << 16;
    id          |= SPI_Transfer(0xFF) << 8;
    id          |= SPI_Transfer(0xFF);
    FLASH_CS_HIGH();
    return id;   // W25Q64 = 0xEF4017
}

int main(void) {
    SPI1_Init();           // 第 11 章
    USART1_Init();
    uint32_t id = Flash_ReadID();
    printf("Flash ID = 0x%06lX\r\n", id);
    while (1);
}
```

输出：
```
Flash ID = 0xEF4017
```

`0xEF` = 华邦（Winbond）厂商 ID，`0x4017` = W25Q64 型号。看到这个值说明 SPI 通信通了。

#### 读数据（任意地址，任意长度）

```c
void Flash_ReadData(uint32_t addr, uint8_t *buf, uint32_t len) {
    FLASH_CS_LOW();
    SPI_Transfer(0x03);                          // Read Data
    SPI_Transfer((addr >> 16) & 0xFF);            // 地址 3 字节
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    for (uint32_t i = 0; i < len; i++)
        buf[i] = SPI_Transfer(0xFF);              // 读数据
    FLASH_CS_HIGH();
}
```

#### 擦除扇区（写之前必须先擦除）

```c
void Flash_WriteEnable(void) {
    FLASH_CS_LOW();
    SPI_Transfer(0x06);                          // Write Enable
    FLASH_CS_HIGH();
}

void Flash_WaitBusy(void) {
    FLASH_CS_LOW();
    SPI_Transfer(0x05);                          // Read Status Register
    while (SPI_Transfer(0xFF) & 0x01);            // BUSY 位
    FLASH_CS_HIGH();
}

void Flash_EraseSector(uint32_t addr) {
    Flash_WriteEnable();
    FLASH_CS_LOW();
    SPI_Transfer(0x20);                          // Sector Erase (4KB)
    SPI_Transfer((addr >> 16) & 0xFF);
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    FLASH_CS_HIGH();
    Flash_WaitBusy();                            // ~150ms
}
```

#### 写一页（256 字节）

```c
void Flash_WritePage(uint32_t addr, const uint8_t *data, uint16_t len) {
    Flash_WriteEnable();
    FLASH_CS_LOW();
    SPI_Transfer(0x02);                          // Page Program
    SPI_Transfer((addr >> 16) & 0xFF);
    SPI_Transfer((addr >> 8)  & 0xFF);
    SPI_Transfer( addr        & 0xFF);
    for (uint16_t i = 0; i < len; i++)
        SPI_Transfer(data[i]);
    FLASH_CS_HIGH();
    Flash_WaitBusy();                            // ~3ms
}
```

### 验证：写一组数据再读回来

```c
int main(void) {
    SPI1_Init();
    USART1_Init();

    uint8_t write_buf[] = "Hello W25Q64! 这是 SPI Flash 写入的数据。";
    uint8_t read_buf[64] = {0};

    uint32_t test_addr = 0x00010000;             // 避开前 64KB（可能放启动代码）

    Flash_EraseSector(test_addr);                // 擦除 4KB
    Flash_WritePage(test_addr, write_buf, sizeof(write_buf));
    Flash_ReadData(test_addr, read_buf, sizeof(read_buf));

    printf("读回: %s\r\n", read_buf);
    while (1);
}
```

输出：
```
读回: Hello W25Q64! 这是 SPI Flash 写入的数据。
```

### 内部 Flash vs SPI NOR Flash 对比

| | STM32 内部 Flash | W25Q64（SPI NOR Flash）|
|--|-----------------|------------------------|
| 容量 | 512KB | **8MB** |
| 接口 | 内部总线（AHB） | SPI 总线 |
| 擦除单位 | 1KB 页 | **4KB 扇区** |
| 擦除寿命 | 1 万次 | **10 万次** |
| 写入时 CPU | 暂停（Flash 总线被锁）| **不暂停**（SPI 后台传输）|
| 用途 | 程序代码、关键参数 | 字库、日志、OTA 固件包 |

> **SPI Flash 比内部 Flash 更适合存大量数据**——容量大、不阻塞 CPU、寿命更长。唯一的代价是速度（SPI 9MHz vs 内部 AHB 72MHz），但对大多数数据存储场景足够。

---

## 13.3 动手：在 SPI Flash 上跑 FatFs 文件系统

上面我们直接往 SPI Flash 写地址+数据，但项目里你不会这么用——你需要的是 **文件**：

```c
f_open(&file, "log.txt", FA_WRITE | FA_CREATE_ALWAYS);
f_printf(&file, "温度: %.1f°C\r\n", temp);
f_close(&file);
```

FatFs 就是一个帮你把「扇区读写」变成「文件操作」的中间层。

### FatFs 是什么

FatFs 是一个**纯 C 的 FAT 文件系统库**，跟 SPL/HAL 无关。它不知道你的存储介质是 SPI Flash 还是 SD 卡——它只需要 6 个底层函数。

### 移植：对接 6 个 diskio 函数

FatFs 的 `ff.c` 调用 `diskio.c` 中的 6 个函数。对于 W25Q64：

```c
// diskio.c —— 完整实现

DSTATUS disk_initialize(BYTE pdrv) {
    if (pdrv != 0) return STA_NODISK;
    SPI1_Init();                // 确保 SPI 已初始化
    return 0;                   // 成功
}

DSTATUS disk_status(BYTE pdrv) {
    if (pdrv != 0) return STA_NODISK;
    return 0;                   // 永远 Ready
}

DRESULT disk_read(BYTE pdrv, BYTE *buffer, LBA_t sector, UINT count) {
    // FatFs 把 W25Q64 当成 512 字节/扇区的磁盘（每 512 字节 = 1 个模拟扇区）
    for (UINT i = 0; i < count; i++)
        Flash_ReadData((sector + i) * 512, buffer + i * 512, 512);
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buffer, LBA_t sector, UINT count) {
    for (UINT i = 0; i < count; i++) {
        uint32_t addr = (sector + i) * 512;
        // 检查是否是扇区起始地址（4KB 对齐），是则擦除
        if ((addr & 0xFFF) == 0)
            Flash_EraseSector(addr);
        Flash_WritePage(addr, buffer + i * 512, 256);            // 前 256 字节
        Flash_WritePage(addr + 256, buffer + i * 512 + 256, 256); // 后 256 字节
    }
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    switch (cmd) {
    case GET_SECTOR_COUNT:
        *(LBA_t *)buff = 16384;         // 8MB / 512 = 16384 个扇区
        return RES_OK;
    case GET_SECTOR_SIZE:
        *(WORD *)buff = 512;
        return RES_OK;
    case GET_BLOCK_SIZE:
        *(DWORD *)buff = 8;             // 4KB/512 = 8 个扇区/擦除块
        return RES_OK;
    default:
        return RES_PARERR;
    }
}

DWORD get_fattime(void) {
    // 返回固定时间戳（如果不连 RTC）
    return (2025 - 1980) << 25 | 1 << 21 | 1 << 16;  // 2025-01-01
}
```

### 使用 FatFs：创建文件并写入

```c
FATFS   fs;        // 文件系统对象
FIL     file;      // 文件对象
UINT    bw;        // 写入字节数

int main(void) {
    USART1_Init();

    // 1. 挂载文件系统（逻辑驱动器 "0:"）
    FRESULT res = f_mount(&fs, "0:", 1);
    if (res == FR_NO_FILESYSTEM) {
        // 首次使用，需要格式化
        printf("未检测到文件系统，正在格式化...\r\n");
        f_mkfs("0:", 0, 0, 512);        // 格式化为 FAT16
        f_mount(&fs, "0:", 1);          // 重新挂载
    }

    // 2. 创建文件并写入
    res = f_open(&file, "0:hello.txt", FA_WRITE | FA_CREATE_ALWAYS);
    if (res == FR_OK) {
        f_printf(&file, "Hello from STM32F103 + W25Q64!\r\n");
        f_printf(&file, "温度: %.1f°C\r\n", 25.5f);
        f_close(&file);
        printf("文件写入成功\r\n");
    }

    // 3. 读回确认
    char buf[128];
    res = f_open(&file, "0:hello.txt", FA_READ);
    if (res == FR_OK) {
        f_gets(buf, sizeof(buf), &file);
        printf("文件内容: %s", buf);
        f_close(&file);
    }

    while (1);
}
```

第一次运行输出：
```
未检测到文件系统，正在格式化...
文件写入成功
文件内容: Hello from STM32F103 + W25Q64!
```

**关电再开**，文件还在——这就是非易失存储 + 文件系统的意义。

### FatFs 文件操作速查

| 函数 | 作用 | 类似 C 标准库 |
|------|------|-------------|
| `f_open` | 打开/创建文件 | `fopen` |
| `f_close` | 关闭文件 | `fclose` |
| `f_read` | 读数据 | `fread` |
| `f_write` | 写数据 | `fwrite` |
| `f_printf` | 格式化写 | `fprintf` |
| `f_gets` | 读一行 | `fgets` |
| `f_lseek` | 移动读写指针 | `fseek` |
| `f_mkdir` | 创建目录 | `mkdir` |
| `f_unlink` | 删除文件 | `remove` |
| `f_rename` | 重命名 | `rename` |

### SPI Flash + FatFs 能干什么

- **数据日志**：每隔 10 秒写一条传感器数据到 `log.csv`，攒满一个月用电脑读
- **字库存储**：把汉字字库存到 Flash，上电后加载到内存
- **配置文件**：WiFi 密码、PID 参数以 INI 格式存储，电脑上也能编辑
- **OTA 固件包**：下载固件→存到 Flash→重启→从 Flash 加载执行

---

## 13.4 掉电、寿命与日志策略

文件系统的难点不只是“写进去”，而是“写到一半断电时还能知道发生了什么”。

建议把日志策略写清楚：

| 问题 | 建议 |
|---|---|
| 数据多久落盘 | 按记录数量或时间间隔调用同步，而不是每字节同步 |
| 突然掉电 | 启动时检查文件完整性、最后一条记录和序号 |
| Flash 擦除寿命 | 避免反复写同一个小区域，采用循环日志或分区 |
| 日志格式 | 选择可恢复、可检查的 CSV/JSONL/二进制帧 |
| 存储失败 | 上报错误，保留 RAM 中最近样本，不要卡死采样任务 |

对温度记录仪来说，seq、时间戳和 CRC 往往比“把每一行写得漂亮”更重要；它们能帮助你判断缺失、重复和损坏。

## 13.5 实验验收与常见坑

- [ ] 连续写入多条记录并重启，确认能识别最后状态；
- [ ] 模拟 SD 卡或 SPI Flash 不存在，任务能超时返回；
- [ ] 记录写入失败次数、剩余空间和最近 seq；
- [ ] 不在 ISR 中操作文件系统；
- [ ] 在说明中写出“掉电时可能丢失多少最近数据”。

## 13.6 存储实验验收与练习

用“写入—读回—断电—恢复”四步证明日志策略，而不是只做一次成功演示。

1. 擦除一个明确的测试区域；
2. 写入带版本、长度和 CRC 的记录；
3. 立即读回并逐字节比较；
4. 在不同记录阶段模拟复位，再启动扫描恢复；
5. 统计擦除次数和写入失败次数。

| 现象 | 优先检查 |
|---|---|
| 写后读回全 FF | 写使能、页边界、CS、擦除状态 |
| 记录偶尔损坏 | 掉电窗口、CRC、页/扇区边界、未等待 busy 清除 |
| 文件系统挂载失败 | 块设备回调、扇区大小、格式化状态、SPI 事务 |
| 寿命越来越差 | 反复擦同一扇区、没有轮换或批量写策略 |

练习：设计一条 32 字节日志记录，其中包含 magic、版本、序号、长度、payload 和 CRC；写出启动时如何跳过最后一条半写入记录。

## 13.7 本章要点

- W25Q64 = 8MB SPI NOR Flash，用 SPI1（PA5/PA6/PA7/PB12）操作
- SPI Flash 铁律：**写之前必须先擦除**，擦除以 4KB 扇区为单位
- W25Q64 的基本命令：`0x9F` 读 ID、`0x03` 读数据、`0x02` 页写、`0x20` 扇区擦除、`0x06` 写使能
- FatFs 是一个**库无关的文件系统**——只需要实现 6 个 `diskio.c` 函数就能在任何存储介质上跑 FAT
- SPI Flash + FatFs = 嵌入式设备的「硬盘」：存日志、字库、配置文件
- 存储层次：内部 Flash（代码）→ W25Q64（大量数据）→ SD 卡（可插拔、更大容量）

---

> **上一章**：[第 12.5 章 · RS485 与 Modbus RTU](./12b-chapter.md)
>
> **下一章**：[第 14 章 · 为什么需要 RTOS（SPL版）](./14-chapter.md)
>
> 裸机部分告一段落。接下来进入多任务世界——让你的 MCU 同时做多件事。

# 第 8 章 · 串口通信 UART

## 8.1 串行通信基础

### 并行 vs 串行

| | 并行 | 串行 |
|---|---|---|
| 线数 | 8/16 根数据线 + 时钟 | 1-2 根 |
| 距离 | 短 | 长（几米到上千米 RS485） |
| 嵌入式中 | 极少 | **到处都是** |

UART 是最简单的串行——不需要时钟线（异步），双方约定波特率。

### 异步串行协议

```
空闲：高电平
起始位：1 位低电平（「我要发了」）
数据位：5-9 位（通常 8 位，LSB 先发）
校验位：可选
停止位：1 或 2 位高电平

发 0x41 ('A') = 0b0100_0001（8N1：8 数据位、无校验、1 停止位）

空闲 ─┐  ┌─┐  ┌─┐     ┌─┐  ┌───────
      └──┘S└─┘0└─┘ ... └─┘1└─────
         0   1   2       7   停止
```

- **波特率**：常见 9600, 115200, 921600
- **帧格式**：8N1 最常用
- **波特率误差 > 2% 出错**——所以 HSE（晶振 ±30ppm）比 HSI（±1%）可靠

## 8.2 STM32 USART 外设

ZET6 有 5 个 USART：

| USART | TX | RX | 总线 |
|-------|-----|-----|------|
| USART1 | PA9 | PA10 | APB2 (72MHz) |
| USART2 | PA2 | PA3 | APB1 (36MHz) |
| USART3 | PB10 | PB11 | APB1 |

连接：**TX ↔ RX，RX ↔ TX，GND ↔ GND**。

---

### 8.2.5 UART 的硬件内部机理（从零讲起）

你要理解 UART 外设硬件在干什么，得先知道"串行发送"到底是怎么一回事。下面从最基础的概念一步一步来。

---

#### ① 什么是"串行发送"？ —— 一根线，按时间顺序逐个传出

你在内存里有一个字节 `0x53`（二进制 `0101_0011`）。它在内存里是"并行"存放的：

```
内存中的一个地址，存了 8 个 bit：
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│  0  │  1  │  0  │  1  │  0  │  0  │  1  │  1  │   ← 8 个 bit 并列
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘
  bit7   bit6   bit5   bit4   bit3   bit2   bit1   bit0
```

并行 = 8 根线同时传 8 个 bit。但 UART 只有 **1 根 TX 线**，所以必须把这 8 个 bit **按时间顺序**排成一串传出去。把"并列"转成"一串"的硬件叫**移位寄存器**。

---

#### ② 移位寄存器 —— 把并行的 8 个 bit 转成串行的一串

移位寄存器可以想象成一个**8 格的队列**：

```
         ┌──────────────────────────────────┐
         │         移位寄存器                │
         │  ┌──┬──┬──┬──┬──┬──┬──┬──┐      │
         │  │  │  │  │  │  │  │  │  │ → 逐位移出
         │  └──┴──┴──┴──┴──┴──┴──┴──┘      │
         │  bit7  6   5   4   3   2   1   0  │
         └──────────────────────────────────┘
```

每个"格子"存 1 个 bit。在时钟信号的控制下，每个时钟周期所有格子的内容向右移一格，最右边那个格子的 bit 被推到 TX 引脚上。

```
举例：把 0x53（0101_0011）放进移位寄存器

第 0 步（写入后）：
┌───┬───┬───┬───┬───┬───┬───┬───┐
│ 0 │ 1 │ 0 │ 1 │ 0 │ 0 │ 1 │ 1 │  右端是 bit0 = 1
└───┴───┴───┴───┴───┴───┴───┴───┘
                                          ↙ TX 引脚

第 1 个时钟：最右边那个 1 被推到 TX 引脚
所有位右移一格，左边空出来填 0
┌───┬───┬───┬───┬───┬───┬───┬───┐      TX 输出：1
│ 0 │ 0 │ 1 │ 0 │ 1 │ 0 │ 0 │ 1 │
└───┴───┴───┴───┴───┴───┴───┴───┘
                                          ↙ TX 引脚

第 2 个时钟：最右边那个 1 被推出
┌───┬───┬───┬───┬───┬───┬───┬───┐      TX 输出：1
│ 0 │ 0 │ 0 │ 1 │ 0 │ 1 │ 0 │ 0 │
└───┴───┴───┴───┴───┴───┴───┴───┘

……重复 8 次后，8 个 bit 全部发出。
```

**这就是"串行"的物理含义**——把 8 个并排的 bit 拆成先后顺序，逐个送到一根线上。

接收方也有一个一模一样的移位寄存器，但方向相反：从 RX 引脚逐个收 bit（每来一个时钟周期从右边移入一个 bit），收满 8 个后 CPU 并行读取。

---

#### ③ 双缓冲 —— 为什么要有两个寄存器

如果直接让 CPU 把数据写到移位寄存器里——CPU 写入需要时间，移位寄存器也在移位，两者会冲突。

所以 USART 内部把"CPU 写入口"和"真正在移位的那部分"分成了两层：

```
         ┌───────────────┐
CPU 写 → │ 数据寄存器 TDR  │  ← 这是"放货架"，专门给 CPU 放
         │ （1 字节容量）   │
         └───────┬───────┘
                  │ CPU 写完，硬件自动瞬间转入
                  ▼
         ┌───────────────┐
         │ 移位寄存器      │  ← 这是"传送带"，自己慢慢移
         │ （1 字节容量）   │
         └───────┬───────┘
                  │ 每个时钟周期往 TX 引脚推一个 bit
                  ▼
               TX 引脚
```

**没有双缓冲会怎样（假设只有移位寄存器没有 TDR）：**

```
CPU 写移位寄存器（花 1 个周期）→ 等它慢慢移完 8 bit（花 8 个周期）
→ CPU 再写下一个（1 周期）→ 再等 8 个周期……
CPU 每发一字节都要等 8 个周期，效率很低。
```

**有双缓冲（TDR + 移位寄存器）：**

```
CPU 写 TDR（瞬间完成）                    ← CPU 几乎不用等
硬件自动把 TDR 内容转给移位寄存器（也瞬间完成）
移位寄存器开始慢慢移（8 个周期）
同时 CPU 可以写下一个字节到 TDR             ← CPU 不用等移位完成！
8 个周期后移位寄存器空了，从 TDR 拿下一个
```

**你连续发一串 "Hello" 不卡顿，就是双缓冲的功劳**——CPU 的写入操作和硬件的串行发送重叠进行，互不阻塞。

---

#### ④ TXE vs TC —— 终于能说清这两个标志了

有了上面的双层结构，这两个标志极其好理解：

```
TDR（放货架）  ──→  移位寄存器（传送带）  ──→  TX 引脚

TXE = TDR 空了，你可以放下一箱了
     ↑ CPU 写完 TDR 后硬件自动置 1

TC  = 移位寄存器也发完了，最后一个 bit 已经飞出 TX 引脚
     ↑ 8 个时钟周期后才置 1
```

**类比**：你在传送带上放箱子（每个箱子就是一字节数据）：

- **TXE** = 你面前的放货架空了，你可以把下一箱放上去（但传送带上的那箱还没运走）
- **TC** = 整条传送带上的最后一个箱子也已经滚下去了（可以关传送带了）

所以 `fputc` 应该等 TXE，而不是 TC：

```c
int fputc(int ch, FILE *f) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    //   ↑ 等放货架空了就放下一箱，不等传送带走完
    USART_SendData(USART1, (uint8_t)ch);
    return ch;
}
```

什么时候等 TC？你发出的**最后一个字节**，或者要关串口/休眠的时候：

```c
void USART_SendLastByte(uint8_t ch) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, ch);
    // 确保这个字节真的从 TX 引脚飞出去了，而不是还在移位寄存器里
    while (USART_GetFlagStatus(USART1, USART_FLAG_TC) == RESET);
    // 现在可以安全关 USART 时钟了，最后一个 bit 已经发出了
}
```

---

#### ⑤ 波特率是怎么产生的

发送方和接收方必须用同一个速度——发送方按某个速度往 TX 线上推 bit，接收方按同样的速度从 RX 线上读 bit。这个速度就是波特率。

STM32 内部没有"UART 专用振荡器"。USART 用的是**系统总线的时钟**（USART1→72MHz，USART2/3→36MHz）。72MHz 太快了，UART 要的是 115200Hz。所以需要一个**分频器**把 72MHz 降到 115200Hz。

**分频器的工作原理**——就是个计数器：

```
72MHz = 每秒 72,000,000 个脉冲
目标波特率 = 115200

分频系数 = 72,000,000 ÷ 115200 = 625

分频器每数 625 个输入脉冲，输出 1 个脉冲。
这样就把 72MHz 降到了 115200Hz。
```

（实际 USART 的分频公式更复杂——要 ×16，但核心思想完全一样：用一个高精度时钟数出想要的低速时钟。）

**这就是为什么外部晶振（HSE，精度 ±30ppm）比内部振荡器（HSI，精度 ±1%）串口更可靠**——源时钟不准，数出来的波特率也不准，双方波特率误差超过 ±2% 就会收错数据。

---

#### ⑥ 没有时钟线，接收方怎么知道什么时候读？ —— 过采样

I²C 和 SPI 都有 SCL 时钟线——发送方和接收方共用一根时钟线，接收方在时钟沿采样即可。

UART **没有时钟线**。双方只约定了"115200 波特率"，但接收方**不知道发送方从哪一刻开始发**。

**解决办法**：接收方内部用更快的时钟（16 倍波特率）不停地看 RX 引脚。

```
发送方 TX：空闲高               起始位低
           ─────────┐  ┌──┐  ┌──┐  ┌──┐
                    │  │  │  │  │  │
                    └──┘  └──┘  └──┘  └────

接收方内部 16 倍时钟：
           ┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐┌┐  ← 16 倍波特率
```

接收器做了两件事：

**第一步：检测起始位**

```
RX 引脚： ────────┐  ← 从高跳到低——"注意！有人要说话了"
                  │
                  └──
```

**第二步：在数据位的正中间采样**

```
检测到下降沿后，接收器等 1.5 个采样周期（进入起始位的中央），
然后每 16 个采样周期读一次——正好是一个 bit 的时间宽度。

           ←1.5→←──── 16 个采样周期 = 1 个 bit ────→←──── 16 ────→
RX：  ────┐  ↑                                        ↑
          │  第一次采样（起始位中间）    第二次采样（bit0 中间）
          └──
```

为什么要读 16 倍而不是直接按波特率读？

- 如果直接按波特率读，你不知道起始位从哪一时刻开始——前后误差可能累计
- 16 倍采样在每个 bit 上测了 16 次，可以用"多数表决"判断电平，**对噪声有容错**
- 16 倍采样也给收发双方的时钟误差留了余量——允许 ±2% 以内的误差

---

#### ⑦ 帧格式 —— 起始位 + 数据 + 停止位

UART 实际在线上传一个字节，不止传 8 个 bit，而是加了"包装"：

```
                    起始位       8 个数据位       停止位
                    ┌──────┐┌────────────────┐┌──────┐
TX 引脚（空闲高）───┘      └┴────────────────┘└──────┴──── 继续保持高
                    拉低         按顺序发送        拉高
                 「我要发了」                    「发完了」
```

| 阶段 | TX 引脚上的电平 | 作用 |
|------|----------------|------|
| 空闲 | 高 | 总线上没人说话 |
| **起始位** | **从高变低** | **告诉对方：注意，要开始了** |
| 数据位 | 逐位输出 0 或 1 | 实际数据 |
| **停止位** | **回到高** | **告诉对方：结束了，把线让出来** |

8N1 = 8 个数据位、None 无校验、1 个停止位。

发送方用移位寄存器逐个移出这些 bit，接收方用 16 倍时钟检测起始位的下降沿后开始采样——完成一次 UART 传输。

---

#### ⑧ 错误标志的物理含义

你现在理解了全部流程，看这几个标志就很直观了：

| 标志 | TXE | TC | RXNE | FE | ORE |
|------|-----|-----|------|-----|-----|
| 含义 | TDR 空了 | 移位寄存器也空了 | RDR 有数据 | 停止位该高却低 | 上一字节还没读就被覆盖 |
| 你该做什么 | 写下一个字节 | 关串口或发完通知 | 读 DR | 检查波特率/接线 | 加快读取速度 |

---

## 8.3 SPL UART 初始化 + printf 重定向

```c
#include "stm32f10x_usart.h"

void USART1_Init(void) {
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_USART1 | RCC_APB2Periph_GPIOA, ENABLE);

    // PA9 = TX（复用推挽）
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin   = GPIO_Pin_9;
    gpio.GPIO_Mode  = GPIO_Mode_AF_PP;
    gpio.GPIO_Speed = GPIO_Speed_50MHz;
    GPIO_Init(GPIOA, &gpio);

    // PA10 = RX（浮空输入）
    gpio.GPIO_Pin  = GPIO_Pin_10;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // USART: 115200, 8N1
    USART_InitTypeDef uart;
    uart.USART_BaudRate            = 115200;
    uart.USART_WordLength          = USART_WordLength_8b;
    uart.USART_StopBits            = USART_StopBits_1;
    uart.USART_Parity              = USART_Parity_No;
    uart.USART_HardwareFlowControl = USART_HardwareFlowControl_None;
    uart.USART_Mode                = USART_Mode_Rx | USART_Mode_Tx;
    USART_Init(USART1, &uart);

    USART_Cmd(USART1, ENABLE);
}

// printf 重定向到 USART1
#include <stdio.h>
int fputc(int ch, FILE *f) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, (uint8_t)ch);
    return ch;
}
// 现在 printf("Hello %d\n", 42) 就输出到串口了
```

**验证**：接上 ST-Link 反面的 TXD/RXD → `minicom -D /dev/ttyACM0 -b 115200`，看到 printf 输出。

## 8.4 SPL UART 中断接收与轮询收发

```c
volatile uint8_t rx_byte;
volatile uint8_t rx_ready = 0;

void USART1_IRQHandler(void) {
    if (USART_GetITStatus(USART1, USART_IT_RXNE) != RESET) {
        rx_byte  = USART_ReceiveData(USART1);  // 读 DR 自动清 RXNE
        rx_ready = 1;
    }
}

// 初始化时开启 RXNE 中断：
USART_ITConfig(USART1, USART_IT_RXNE, ENABLE);
NVIC_EnableIRQ(USART1_IRQn);

// 主循环处理：
while (1) {
    if (rx_ready) {
        rx_ready = 0;
        printf("收到: 0x%02X (%c)\n", rx_byte, rx_byte);
    }
}
```

### UART 轮询方式收发

最简单的收发——CPU 忙等：

```c
void UART_PutChar(uint8_t ch) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);
    USART_SendData(USART1, ch);
}

uint8_t UART_GetChar(void) {
    while (USART_GetFlagStatus(USART1, USART_FLAG_RXNE) == RESET);
    return USART_ReceiveData(USART1);
}
```

轮询简单但阻塞 CPU。初期调试用轮询，正式代码用中断。

## 8.5 动手：串口指令控制台

### 目标

用串口发命令控制开发板——不按键、不重烧程序，用终端直接交互。

```
串口助手输入：  LED ON     → 板上 LED 亮
               LED OFF    → 板上 LED 灭
               PWM 600    → PWM 占空比设到 60%
               TEMP?      → 返回模拟温度
               ?          → 显示帮助菜单
```

### 接线

开发板上 USART1（PA9 TX、PA10 RX）通过 ST-Link 的虚拟串口连到电脑——你接线已经完成了。用 `picocom -b 115200 /dev/ttyACM0` 或任意串口助手连上即可。

### 代码

```c
#define CMD_BUF_LEN 32
char cmd_buf[CMD_BUF_LEN];
uint8_t cmd_idx = 0;
volatile uint8_t cmd_ready = 0;

void USART1_IRQHandler(void) {
    if (USART_GetITStatus(USART1, USART_IT_RXNE) != RESET) {
        char ch = USART_ReceiveData(USART1);

        // 回显（让你在终端能看到打进去的字）
        USART_SendData(USART1, ch);
        while (USART_GetFlagStatus(USART1, USART_FLAG_TXE) == RESET);

        if (ch == '\r' || ch == '\n') {
            cmd_buf[cmd_idx] = '\0';
            cmd_idx = 0;
            cmd_ready = 1;
            printf("\r\n");             // 换行
        } else if (cmd_idx < CMD_BUF_LEN - 1) {
            cmd_buf[cmd_idx++] = ch;
        }
    }
}
```

主循环解析：

```c
void ShowHelp(void) {
    printf("\r\n=== 命令菜单 ===\r\n");
    printf("LED ON    - 点亮 LED\r\n");
    printf("LED OFF   - 熄灭 LED\r\n");
    printf("PWM <val> - 设占空比 0-999\r\n");
    printf("TEMP?     - 读温度\r\n");
    printf("?         - 显示此菜单\r\n");
    printf("===============\r\n");
}

while (1) {
    if (cmd_ready) {
        cmd_ready = 0;

        if      (strcmp(cmd_buf, "LED ON")  == 0) {
            GPIO_ResetBits(GPIOB, GPIO_Pin_5);
            printf("LED 已开\r\n");
        }
        else if (strcmp(cmd_buf, "LED OFF") == 0) {
            GPIO_SetBits(GPIOB, GPIO_Pin_5);
            printf("LED 已关\r\n");
        }
        else if (strncmp(cmd_buf, "PWM ", 4) == 0) {
            uint16_t duty = atoi(cmd_buf + 4);
            TIM_SetCompare3(TIM3, duty);
            printf("PWM 已设为 %d\r\n", duty);
        }
        else if (strcmp(cmd_buf, "TEMP?")   == 0) {
            printf("芯片温度: 25°C（实际需 ADC）\r\n");
        }
        else if (strcmp(cmd_buf, "?") == 0) {
            ShowHelp();
        }
        else {
            printf("未知命令: %s（输入 ? 看帮助）\r\n", cmd_buf);
        }

        printf("> ");  // 显示提示符
    }
}
```

### 预期效果

```
=== 命令菜单 ===
LED ON    - 点亮 LED
LED OFF   - 熄灭 LED
PWM <val> - 设占空比 0-999
TEMP?     - 读温度
?         - 显示此菜单
===============
> LED ON
LED 已开
> PWM 500
PWM 已设为 500
> ?
...菜单...
```

这就是一个**交互式调试系统**的雏形——后面控制 WiFi 模块、读取传感器、测试硬件都用这种方式。完成了串口指令系统，你就有了一个从电脑操纵 MCU 的「遥控器」。

---

## 8.6 实验系列：printf 内容三路发送

下面三个实验本质上是同一个项目。核心代码：

```c
// 模拟温度读数（ADC 章节后会换成真实传感器值）
uint32_t seed = 0;
float Read_Temperature(void) {
    seed = seed * 1103515245 + 12345;        // glibc LCG 算法
    return 25.0f + (float)(seed % 10) / 10.0f;
}

int main(void) {
    USART1_Init();       // 调试串口（所有实验都必需）
    // 根据实验选择初始化第二路串口：
    //   实验① → 只需要 USART1，无额外初始化
    //   实验② → USART2_Init_115200()   // USART2 → DX-WF24（115200）
    //   实验③ → USART2_Init_115200()   // USART2 → DX-WF24（BLE 模式）

    while (1) {
        float temp = Read_Temperature();
        char msg[64];
        snprintf(msg, sizeof(msg), "温度: %.2f°C\r\n", temp);

        // 三个实验的不同之处仅在于怎么发送 msg
        //   实验① → printf("%s", msg);               // USART1 打印
        //   实验② → WiFi_SendData(msg);              // USART2 → DX-WF24
        //   实验③ → BLE_SendData(msg);                // USART2 → DX-WF24 BLE

        printf("发送: %s", msg);   // 调试串口打一下日志
        Delay_ms(5000);
    }
}
```

**三个实验用同一块板子、同一个 STM32 工程**。区别只在 STM32 的第二路 UART 接了什么模块，以及电脑端用什么工具收。

---

### 实验①：UART 直连（DAP-Link 虚拟串口 → USB）

这是你已经会了的基础。STM32 的 USART1（PA9/PA10）通过板载调试器（DAP-Link / ST-Link）的虚拟串口功能，转 USB 连到电脑。

**接线**：已经把板子用 USB 线连到电脑就行。设备名为 `/dev/ttyACM0`（如果同时插了多个调试器可能是 `/dev/ttyACM1`）。

**代码**：直接用第 8.3 节的 `USART1_Init()` 和 `printf` 重定向，不需要任何额外模块。

**NixOS 收数据（终端）**：

```bash
# 查看哪个设备
ls /dev/ttyACM*

# minicom（8.3 节用的）
minicom -D /dev/ttyACM0 -b 115200

# 或 picocom
picocom -b 115200 /dev/ttyACM0

# 退出 picocom：Ctrl+A → Ctrl+X
# 退出 minicom：Ctrl+A → X
```

**预期输出**：
```
温度: 25.31°C
温度: 25.37°C
温度: 25.25°C
```

**这个实验验证**：你的 SPL 工程能跑、串口能收、printf 通了。是一切无线实验的基础。

---

### 实验②：WiFi 无线发送（DX-WF24）

STM32 把 printf 的内容通过 USART2 发给 DX-WF24，DX-WF24 通过 WiFi 传到你的电脑。

**接线**：

| STM32 (USART2) | DX-WF24 针脚 | 类型 | 说明 |
|----------------|-------------|------|------|
| PA2 (TX) | **RXD** | 输入（3.3V） | STM32 发→模块收。交叉接 |
| PA3 (RX) | **TXD** | 输出（3.3V） | 模块发→STM32 收。交叉接 |
| GND | **GND** | 电源地 | 共地，必接 |
| 3.3V | **VCC** | 电源输入 | 3.3V 供电（禁止 5V）|
| — | **KEY** | 输入（内部上拉） | 悬空=正常；拉低后上电=AT 配置模式 |
| — | **LINK** | 推挽输出 | 连接成功后自动拉低，可驱动 LED 指示 |

**只需要接这 4 根线即可工作：**

```
STM32 PA2 (TX) ────────── DX-WF24 RXD    ← STM32 发送，模块接收
STM32 PA3 (RX) ────────── DX-WF24 TXD    ← 模块发送，STM32 接收
STM32 GND      ────────── DX-WF24 GND    ← 共地
STM32 3.3V     ────────── DX-WF24 VCC    ← 供电
```

正常工作只需要 4 根线：PA2→RXD、PA3→TXD、GND→GND、3.3V→VCC。KEY 和 LINK 可以不接。

> **关于 KEY 和 LINK 的详细说明：**
>
> **KEY** 是模块的配置模式选择脚（内部连到模块 MCU 的 BOOT/GPIO 引脚）。悬空时模块正常启动。如果你需要重新烧录固件或进入 AT 命令配置模式，先把 KEY 拉低（接 GND），再上电 VCC。正常使用中保持悬空即可。
>
> **LINK** 是模块的状态输出脚。模块成功连上 WiFi 或 BLE 后，LINK 会被模块内部拉低（输出低电平），你可以接一个 LED 来指示连接状态：`LINK → 1kΩ 电阻 → LED 正极 → LED 负极 → GND`。不接也不影响通信。
>
> ⚠️ DX-WF24 只能在 3.3V 下工作，严禁接 5V。板子空载时 USB 供电足够，但模块 WiFi 发射时峰值电流约 300mA——如果 ST-Link 供电不稳定，换外部 5V 适配器通过板载稳压到 3.3V。

**【第一步】电脑上启动 TCP 服务器**

在 NixOS 上开一个终端做接收端：

```bash
# 查本机 WiFi IP
ip addr show wlp2s0 | grep inet
# 假设 IP = 192.168.1.100

# 启动 TCP 服务器（监听端口 8080）
nc -lk 8080
# 一直开着，等数据
```

**【第二步】DX-WF24 连接 WiFi**

先拿串口助手或直接 STM32 发 AT 命令配置一次（配好后模块会自动重连）：

```c
WiFi_SendCmd("AT\r\n", 2000);                  // 测试
WiFi_SendCmd("AT+CWMODE=1\r\n", 2000);         // Station 模式
WiFi_SendCmd("AT+CWJAP=\"MyWiFi\",\"pass\"\r\n", 10000); // 连自家 WiFi
WiFi_SendCmd("AT+CIPSTART=\"TCP\",\"192.168.1.100\",8080\r\n", 5000); // 连电脑
```

**【第三步】STM32 通过 WiFi 发数据**

```c
void WiFi_SendData(const char *data) {
    char buf[64];
    int len = snprintf(buf, sizeof(buf), "AT+CIPSEND=%d\r\n", strlen(data));
    WiFi_SendCmd(buf, 1000);                    // 告诉模块要发多少字节
    WiFi_SendCmd(data, 2000);                   // 发实际数据
}

int main(void) {
    USART1_Init();
    USART2_Init_115200();       // DX-WF24 默认 115200
    // 先 AT 一次配网（配一次后模块自动重连，下次可跳过）
    WiFi_SendCmd("AT+CWJAP=\"MyWiFi\",\"pass\"\r\n", 10000);
    WiFi_SendCmd("AT+CIPSTART=\"TCP\",\"192.168.1.100\",8080\r\n", 5000);

    while (1) {
        char msg[64];
        float t = 25.0f + (float)(seed % 10) / 10.0f; seed = seed * 1103515245 + 12345;
        snprintf(msg, sizeof(msg), "{\"temp\":%.2f}\r\n", t);
        WiFi_SendData(msg);
        Delay_ms(5000);
    }
}
```

**预期效果**：

电脑上的 `nc -lk 8080` 终端收到：
```
{"temp":25.31}
{"temp":25.37}
```

**这个实验验证**：你的 STM32 已经通过 WiFi「联网」了——虽然只是发了几个字节，但概念上这就是物联网的第一步。

> ⚠️ DX-WF24（RTL8711DAN）兼容 ESP8266 AT 指令集，默认波特率 115200。KEY 悬空为正常模式，拉低后上电进入 AT 固件配置模式。`AT+UART_DEF?` 可查当前波特率。

---


### 实验③：蓝牙 BLE 无线发送（同一块 DX-WF24 的 BLE 模式）

实验②用 WiFi，现在用同一块 DX-WF24 的 BLE 5.2——**不换接线，不换模块**。PA2/PA3 仍然接着 DX-WF24，只换 AT 命令。

**【第一步】DX-WF24 切换到 BLE 模式**

STM32 通过 USART2 发 AT 命令初始化 BLE：

```c
WiFi_SendCmd("AT+BLEINIT=2\r\n", 2000);    // 初始化 BLE，GATT Server 模式
WiFi_SendCmd("AT+BLEGATTSSRV=1\r\n", 2000);// 创建自定义服务
WiFi_SendCmd("AT+BLEGATTSCHAR=1,0xFFE0,2,20\r\n", 2000); // 特征值，支持通知
WiFi_SendCmd("AT+BLEADVSTART\r\n", 2000);   // 开始广播
```

> 部分固件一次只支持一种模式。切 BLE 前可 `AT+CWMODE=0` 关 WiFi。具体 AT 命令集以你模块的固件手册为准——这里以 ESP32 BLE AT 命令为例。

**【第二步】电脑端接收 BLE 数据**

Linux 用 BlueZ 工具链（笔记本自带蓝牙）：

```bash
# 确保蓝牙已启用
sudo systemctl start bluetooth

bluetoothctl
# scan on                       → 看到 DX-WF24（显示 "DX-WF24" 或 "ESP_*"）
# scan off
# trust XX:XX:XX:XX:XX:XX      → 信任
# connect XX:XX:XX:XX:XX:XX    → 连接
# menu gatt
# list-attributes               → 列出服务和特征值
# select-attribute 0xXXXX       → 选你建的 notify 特征值
# notify on                     → 开启通知，数据显示
```

或用 `gatttool`（更底层）：

```bash
# 查特征值 handle
gatttool -b XX:XX:XX:XX:XX:XX --primary
gatttool -b XX:XX:XX:XX:XX:XX --characteristics

# 开启通知（handle 值以实际返回为准）
gatttool -b XX:XX:XX:XX:XX:XX --char-write-req --handle=0x0005 --value=0100

# 监听数据
gatttool -b XX:XX:XX:XX:XX:XX --listen
```

**【第三步】STM32 通过 BLE 发数据**

```c
void BLE_SendData(const char *data) {
    char buf[128];
    snprintf(buf, sizeof(buf), "AT+BLEGATTSEND=1,%s\r\n", data);
    WiFi_SendCmd(buf, 2000);   // 重用同一个 USART2！
}

int main(void) {
    USART1_Init();
    USART2_Init_115200();       // 和 WiFi 实验共用波特率

    // BLE 初始化
    WiFi_SendCmd("AT+BLEINIT=2\r\n", 2000);
    WiFi_SendCmd("AT+BLEGATTSSRV=1\r\n", 2000);
    WiFi_SendCmd("AT+BLEGATTSCHAR=1,0xFFE0,2,20\r\n", 2000);
    WiFi_SendCmd("AT+BLEADVSTART\r\n", 2000);

    while (1) {
        char msg[32];
        float temp = 25.0f + (float)(seed % 10) / 10.0f; seed = seed * 1103515245 + 12345;
        snprintf(msg, sizeof(msg), "{\"temp\":%.2f}\r\n", temp);
        BLE_SendData(msg);
        Delay_ms(5000);
    }
}
```

**预期效果**：

电脑终端（`gatttool --listen`）收到：
```
{"temp":25.31}
{"temp":25.37}
```

**这个实验验证**：同一块模块、同一组 USART2 引脚、两个实验之间唯一不同的是 AT 命令。UART 是万能接口，AT 命令是通用语言。

---

| | 实验① UART | 实验② WiFi | 实验③ 蓝牙 |
|---|-----------|-----------|-----------|
| 需要额外硬件 | 无（板载调试器） | DX-WF24 | 同 DX-WF24（BLE 模式）|
| 电脑端工具 | `minicom` / `picocom` | `nc -lk` | `bluetoothctl` + `gatttool` |
| 接线 | USB 线 | PA2/PA3 → DX-WF24 | PA2/PA3 → DX-WF24（同②）|
| 距离 | 1 米（USB 线长） | 整栋楼（WiFi 范围） | 10 米（BLE 5.2） |
| STM32 代码改动 | 无 | +WiFi_SendData 函数 | +BLE_SendData 函数 |
| UART 知识点 | USART1 初始化 | USART2 + AT 命令 | USART2 + BLE AT 命令 |

三者共用同一份 `main()` 逻辑——只是数据出口不同。这就是第 8 章想传达的核心：**UART 是万能接口，学会了它你就掌握了跟几乎任何外设「说话」的能力。**

---

## 8.7 SPL vs HAL UART 对照

| 操作 | SPL | HAL |
|------|-----|-----|
| 初始化 | `USART_Init()` + 手动配 GPIO | `HAL_UART_Init()` + CubeMX 自动配 GPIO |
| printf 重定向 | 重写 `_write` 调 `USART_SendData` | 重写 `_write` 调 `HAL_UART_Transmit` |
| 中断接收 | 写 `USART1_IRQHandler` 手动收 | `HAL_UART_Receive_IT()` + `HAL_UART_RxCpltCallback` |
| 发送字节 | `USART_SendData()` + 查 TXE 标志 | `HAL_UART_Transmit()`（阻塞） |
| 状态标志 | `USART_GetFlagStatus(USART_FLAG_RXNE/TXE)` | `__HAL_UART_GET_FLAG()` |
| DMA 收发 | 标准 DMA 配置 + UART 请求使能 | `HAL_UART_Transmit_DMA()` / `HAL_UART_Receive_DMA()` |

SPL 的方式更「薄」——每一步你都在操作参考手册里的寄存器。HAL 封装了状态机，但中断处理多了一层回调。

## 8.8 本章要点

- UART = 异步串行，没有时钟线，双方约定波特率。每个字符：起始位(1) → 数据位(8) → 停止位(1)
- 三种收发方式：**轮询**（阻塞，调试用）→ **中断**（不阻塞，通用）→ **DMA**（不占 CPU，高速/大数据）
- `printf` 重定向 = 最强大的嵌入式调试手段——`printf("GPIOB ODR=%08x\n", GPIOB->ODR)` 随时看寄存器
- 串口 ISR 只做最少的活：读 DR 存到缓冲区。**解析逻辑放主循环**
- **回显**（Echo）让你打字时能看到字符——基础交互体验，USART ISR 里做了
- 后面的 WiFi/BLE、GPS、通信模块全是串口 AT 指令——本章是这一切的地基

---

> **上一章**：[第 7 章 · 定时器](./07-chapter.md)
>
> **下一章**：[第 9 章 · ADC 模数转换](./09-chapter.md)
>
> 你可以和板子「说话」了。但从物理世界感知信息还需要 ADC——把温度、光线、电压变成数字。这才是物联网「感知」的基础。
> 串口让你的 MCU 和外设「说话」。ADC 让你的 MCU 能「感知」世界——把电压变成数字。

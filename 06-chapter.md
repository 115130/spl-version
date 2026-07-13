# 第 6 章 · 中断系统（SPL版）

> **本章产出**：理解 NVIC 中断管理、EXTI 外部中断、用 SPL 手写 ISR、中断与主循环安全共享数据
>
> **用到项目的哪里**：按键不再需要轮询、串口数据到达时自动接收、定时器到点自动触发——所有项目中，中断无处不在

---

## 6.1 什么是中断

### 生活的类比

你在认真看书（CPU 在执行主程序）。

- **轮询方式**：每隔 30 秒抬头看看门口有没有快递。可能没来，也可能错过了。
- **中断方式**：门铃响了（中断信号）。你放下书，记下页码（保存现场），去开门（中断服务函数），回来继续读（恢复现场）。

**中断的核心价值**：CPU 不用一直等，外设主动通知 CPU「我有事找你」。

### 中断在 STM32 上的流程

```
外设触发中断信号（如 GPIO 引脚电平变化）
    ↓
EXTI（外部中断/事件控制器）检测
    ↓
NVIC（嵌套向量中断控制器）仲裁优先级
    ↓
CPU 暂停当前执行
    ↓
硬件自动保存 R0-R3, R12, LR, PC, xPSR 到栈上
    ↓
CPU 从向量表查中断服务函数（ISR）地址，跳转过去
    ↓
执行你的 ISR 代码
    ↓
硬件自动恢复寄存器，回到断点继续执行
```

**关键**：中断的「打断」是硬件级的——不是代码里调函数，是 CPU 在执行指令时检测到中断信号，自动插入了跳转逻辑。

## 6.2 NVIC 嵌套向量中断控制器

### 为什么叫「嵌套向量」？

- **向量**：每个中断源在向量表中有固定位置，存的是 ISR 地址。CPU 直接读表跳转，不用软件查询。
- **嵌套**：低优先级中断正在执行时，可以被高优先级中断打断。

### 中断优先级

STM32F103 的 NVIC 支持 **16 个可编程优先级**（4 位字段），分为两种分组：

```
优先级分组：
  Group_0：0 位抢占 + 4 位子优先级（16 级子优先，无嵌套）
  Group_1：1 位抢占 + 3 位子优先级（2 级抢占，8 级子优先）
  Group_2：2 位抢占 + 2 位子优先级（4 级抢占，4 级子优先）← SPL 默认
  Group_3：3 位抢占 + 1 位子优先级（8 级抢占，2 级子优先）
  Group_4：4 位抢占 + 0 位子优先级（16 级抢占，无子优先）
```

**抢占优先级 vs 子优先级**：

| | 高抢占优先级 | 低抢占优先级 |
|---|---|---|
| **能打断低抢占优先级？** | ✅ 可以 | ❌ 不能 |
| **同抢占、不同子优先同时到达** | 子优先级高的先执行 | 子优先级低的等 |
| **同抢占、高子优先到来时低子优先正在执行** | ❌ 不能打断 | — |

### STM32F103 常用中断向量

| 中断号 | 名称 | 来源 |
|--------|------|------|
| -14 | SysTick | Cortex-M3 内核 |
| 6 | EXTI0 | PA0-PG0 引脚 |
| 7 | EXTI1 | PA1-PG1 引脚 |
| 28 | TIM2 | 通用定时器 2 |
| 37 | USART1 | 串口 1 |
| 11 | DMA1_Channel1 | DMA1 通道 1 |

中断号越小，同优先级时越先响应（硬件自然优先级）。

## 6.3 EXTI：外部中断/事件控制器

### 信号通路

EXTI 是 GPIO 和 NVIC 之间的「翻译官」。一条完整的信号链路：

```
GPIO 引脚 (PA0, PB0...)
    │
    ├──→ GPIO 输入数据寄存器 (IDR)  ← CPU 轮询读
    │
    └──→ EXTI 边沿检测电路            ← 电平变化
              │
              ├── 软件可屏蔽（中断掩码）
              │
        EXTI 线 → NVIC 中断控制器 → CPU 内核
```

**GPIO 只管电平**——引脚上是 0 还是 1，写到 IDR 里。**EXTI 管变化**——电平从 0→1（上升沿）或 1→0（下降沿）时产生一个脉冲，送到 NVIC。

### 为什么只有 16 条 EXTI 线

STM32F103 有几十个 GPIO 引脚，但 EXTI 只有 16 个通道（EXTI0-EXTI15）。**不是每个引脚独占一条 EXTI 线**——同编号的引脚共享一条：

```
EXTI0 ──┬── PA0
        ├── PB0
        ├── PC0
        └── ...（同一时间只能选一个端口连接到 EXTI0）
```

你不能同时让 PA0 和 PB0 都触发 EXTI0 中断——只能用 AFIO 选择其中一个。这就是为什么 AFIO 的时钟需要先打开（`RCC_APB2Periph_AFIO`）。AFIO 里面有一组选择器寄存器，决定哪个端口的引脚连到哪条 EXTI 线。

> **实际项目最常用**：EXTI0 配 PA0（一个按键），EXTI1-EXTI15 配其他引脚。如果你的按键多于 16 个——使用**GPIO 位 OR**，把所有按键接到同一条 EXTI 线共用。

### 触发方式与配置

```c
EXTI_InitTypeDef exti;
EXTI_StructInit(&exti);
exti.EXTI_Line    = EXTI_Line0;         // 选择哪条 EXTI 线
exti.EXTI_Mode    = EXTI_Mode_Interrupt; // 中断模式（另一种是事件模式）
exti.EXTI_Trigger = EXTI_Trigger_Falling; // 下降沿触发（按下按键=低电平）
exti.EXTI_LineCmd = ENABLE;
EXTI_Init(&exti);
```

三种触发方式：

| 触发 | 含义 | 使用场景 |
|------|------|---------|
| **上升沿** | 引脚从 0→1 | 检测按键释放、脉冲上升 |
| **下降沿** | 引脚从 1→0 | 检测按键按下、信号下降 |
| **双边沿** | 任一变化 | 编码器、脉冲宽度测量 |

### 中断模式 vs 事件模式

`EXTI_Mode` 有两个选项：

| 模式 | 行为 | 用途 |
|------|------|------|
| `EXTI_Mode_Interrupt` | 产生中断信号 → NVIC → CPU 跳 ISR | **最常用**，需要 CPU 响应 |
| `EXTI_Mode_Event` | 仅触发一个脉冲信号到外设（如定时器捕获） | 高频信号直接驱动外设，不占用 CPU |

事件模式不产生中断——它直接给其他外设（如定时器）发一个触发信号，适合高速场景。初学只用中断模式。

## 6.4 SPL 配置按键中断

### 完整配置流程

要配一个按键中断，需要 5 步，每一步对应芯片里的一个硬件模块：

| 步骤 | 做什么 | 对应硬件 |
|------|--------|---------|
| ① 开时钟 | GPIO + AFIO 时钟打开 | RCC 寄存器 |
| ② 配 GPIO | PA0 设为浮空输入 | CRL 寄存器 |
| ③ 选择 EXTI 线 | 把 PA0 连到 EXTI0 线（AFIO 选择器） | AFIO_EXTICR 寄存器 |
| ④ 配 EXTI | EXTI0 下降沿触发，中断模式 | EXTI 的边沿检测寄存器 |
| ⑤ 配 NVIC | EXTI0 中断使能，设优先级 | NVIC_ISER + NVIC_IPR |

### 代码

```c
#include "stm32f10x_exti.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "misc.h"  // NVIC 配置

void Button_EXTI_Init(void) {
    // ① 开启 GPIOA 和 AFIO 时钟
    //    AFIO 不开启，第 ③ 步的 GPIO_EXTILineConfig 不会生效
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA | RCC_APB2Periph_AFIO, ENABLE);

    // ② PA0 配成浮空输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // ③ 把 PA0 映射到 EXTI0 线
    GPIO_EXTILineConfig(GPIO_PortSourceGPIOA, GPIO_PinSource0);

    // ④ 配置 EXTI0：下降沿触发，中断模式
    EXTI_InitTypeDef exti;
    EXTI_StructInit(&exti);
    exti.EXTI_Line    = EXTI_Line0;
    exti.EXTI_Mode    = EXTI_Mode_Interrupt;     // 中断模式
    exti.EXTI_Trigger = EXTI_Trigger_Falling;     // 高→低触发
    exti.EXTI_LineCmd = ENABLE;
    EXTI_Init(&exti);

    // ⑤ 配置 NVIC：EXTI0 中断优先级
    NVIC_InitTypeDef nvic;
    nvic.NVIC_IRQChannel                   = EXTI0_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 0x01;
    nvic.NVIC_IRQChannelSubPriority        = 0x00;
    nvic.NVIC_IRQChannelCmd                = ENABLE;
    NVIC_Init(&nvic);
}
```

### 中断服务函数（ISR）

中断触发后 CPU 停止当前指令，跳转到启动文件中定义的中断向量表——找到 `EXTI0_IRQHandler` 这个函数名开始执行：

```c
// 这个函数名是固定的——由启动文件 startup_stm32f10x_hd.s 的
// 中断向量表决定。名字写错、写漏，中断来了 CPU 找不到入口。
// 正确写法：EXTI0_IRQHandler（向量表第 0x10 项）
void EXTI0_IRQHandler(void) {
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {  // 确认是 EXTI0 触发
        EXTI_ClearITPendingBit(EXTI_Line0);        // 清挂起位（必须！否则反复进中断）
        GPIOB->ODR ^= GPIO_Pin_5;                  // ISR 中直接翻转
    }
}
```

### 主函数

```c
int main(void) {
    SystemClock_Config();
    SysTick_Init();
    LED_Init();
    Button_EXTI_Init();     // 配好 PA0 的外部中断

    while (1) {
        // CPU 自由了！按键自行触发中断，主循环不用轮询
        // 甚至可以进低功耗等待中断：__WFI();
    }
}
```

### ISR 注意事项

- **ISR 要短**：中断执行期间，同优先级和低优先级的中断被阻塞。ISR 跑 10μs = CPU 损失 10μs
- **不能阻塞等待**：`Delay_ms(30)` 依赖 SysTick，如果 SysTick 中断优先级比当前低，SysTick 进不来——`uwTick` 不更新——死锁
- **不能在 ISR 里做的**：printf（太慢）、malloc（不确定时间）、复杂的 I²C/SPI 通信
- **正确做法**：ISR 只设一个 `volatile` 标志位，主循环检测到标志再处理耗时操作。这就是下面 6.5 要讲的模式

---

## 6.5 ISR 与主循环的数据共享

### 基本原则：ISR 只设标志，主循环处理

中断 ISR 和主循环 `while(1)` 是两个「线程」（虽然 Cortex-M3 没有 MMU，但逻辑上就是多线程）。它们共享的变量需要特殊处理：

```
时间轴 ─────────────────────────────────────────►
           ISR 触发                        ISR 触发
             │                               │
主循环 ──────┼───────────────┼───────────────┼──────►
             │               │               │
             └──→ 设 flag=1   │  设 flag=1    │
             主循环读到        │  主循环读到
             flag=1 → 处理     │  flag=1 → 处理
```

```c
// 全局共享变量——必须用 volatile！
// volatile 让编译器每次读都从内存读，而不是从 CPU 寄存器取缓存值
volatile uint8_t button_pressed = 0;

void EXTI0_IRQHandler(void) {
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        button_pressed = 1;  // 只设标志，尽快退出
    }
}

int main(void) {
    // ... 各种初始化 ...
    while (1) {
        if (button_pressed) {        // 主循环检测标志
            button_pressed = 0;      // 清标志

            // 耗时操作在中断外做——消抖后确认
            Delay_ms(30);
            if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
                GPIOB->ODR ^= GPIO_Pin_5;
            }
        }
    }
}
```

> **为什么 `volatile` 是必须的？**
> 没有 `volatile`，编译器看到 `button_pressed` 在主循环里只读不写，可能会优化成：
> ```c
> // 编译器的「优化」版本：
> register uint8_t cached = button_pressed;
> while (1) {
>     if (cached) ...  // ← 永远读的是缓存值，ISR 修改了内存，但 CPU 不知道
> }
> ```
> `volatile` 强制每次 `if` 都从真实地址读，不缓存。详见第 4 章。

### `counter++` 不是原子的

```c
volatile uint32_t counter = 0;

void ISR(void) {
    counter++;   // CPU 执行三条指令：读 counter → 加 1 → 写回 counter
}

// 主循环也在读 counter：
uint32_t c = counter;  // 可能读到「加 1 写到一半」的值！
```

`counter++` 在汇编级是读→改→写三条指令。如果主循环在读的过程中被中断打断去执行 ISR，ISR 改了 `counter`，回到主循环时读到的值就是旧的。对于整型赋值（`flag = 0` 或 `flag = 1`），单次 32 位写是原子的，不需要保护。但对于 `++` 需要用临界区：

```c
// 临时关所有中断——保护这段代码不被中断打断
__disable_irq();     // 关全局中断
counter++;
__enable_irq();      // 开全局中断
```

临界区的代价：关中断期间，所有外设的中断请求都被延迟响应。所以临界区要**尽可能短**——只包住那一条 `counter++`，不要包住整个函数。

### 三种共享数据的保护方式

| 场景 | 方案 | 说明 |
|------|------|------|
| 标志位赋值（`flag = 1`） | `volatile` 就够了 | 单次 32 位写是原子的，ISR 和主循环间简单传递信号 |
| 计数增减（`counter++`） | `volatile` + 临界区 | `__disable_irq()` / `__enable_irq()` 包住读写 |
| 复杂数据类型（数组/结构体） | 临界区或双缓冲 | 超过 4 字节的操作必须加临界区保护 |

---

## 6.6 SPL vs HAL 中断对照

| 操作 | SPL | HAL |
|------|-----|-----|
| GPIO→EXTI 映射 | `GPIO_EXTILineConfig()` | CubeMX 自动 |
| EXTI 配置 | `EXTI_Init()` | CubeMX 自动 |
| NVIC 配置 | `NVIC_Init()` | CubeMX 自动 |
| 清中断标志 | `EXTI_ClearITPendingBit()` | HAL 回调内部清 |
| ISR | 直接写在 `IRQHandler` 里 | `HAL_GPIO_EXTI_Callback()` |

SPL 方式更直白——每一步你都能在参考手册里找到对应的寄存器操作。HAL 也做同样的事，只是包了一层。

---

## 6.7 ISR 的安全边界与验收

中断服务函数应当短、确定、可恢复：

- 读入硬件数据、清除标志、设置标志位或发轻量通知；
- 不执行长延时、printf、文件系统、网络请求或等待循环；
- 主循环/任务和 ISR 共享变量时，先考虑 volatile、原子性和临界区；
- 同一个中断反复触发时，必须确认标志位被正确清除。

验收时，连续快速按键或模拟多个中断源，观察是否漏触发、重复触发或卡死。能稳定处理“最坏情况”比偶尔按一次成功更重要。

## 6.8 本章要点

- 中断 = 外设主动通知 CPU，不用轮询；打断是硬件级的
- NVIC 管理优先级：抢占优先级决定谁能打断谁，子优先级决定排队顺序
- EXTI 把 GPIO 电平变化变成中断信号，16 条线，每条对应所有端口同号引脚
- ISR 要**短、快、不阻塞**——只设标志位，实际处理放主循环
- ISR 和主循环共享的变量必须 `volatile`；复杂操作（`++`）需要临界区保护

---
> **上一章**：[第 5 章 · 时钟与系统滴答](./05-chapter.md)
> **下一章**：[第 7 章 · 定时器（SPL版）](./07-chapter.md)

> SysTick 只能做简单定时。STM32 的通用定时器能做 PWM、能测脉冲宽度、能做编码器接口——这是电机控制、灯光、音频的基础。

---



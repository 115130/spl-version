# 第 6 章 · 中断、事件与并发边界（SPL 版）

> **本章产出**：能把 GPIO 边沿变成一个可消费的事件，配置 NVIC 优先级分组，并安全地在 ISR 与主循环之间交接最小数据。
>
> **前置知识**：第 3 章 GPIO、第 5 章 1ms 时基。
>
> **通过标准**：连续按键、抖动和两个中断源同时发生时不死锁、不无限重入；能解释为什么“`volatile` + `counter++`”仍会丢更新。

---

## 6.1 中断是硬件事件到代码入口的路径

轮询是 CPU 反复问“发生了吗？”；中断是外设在事件到来时请求 CPU 跳到预先登记的处理函数。对一次 PA0 按键下降沿，路径是：

```text
PA0 电平变化 → AFIO 把 GPIOA.0 连接到 EXTI0
             → EXTI0 检测下降沿并置 pending
             → NVIC 根据使能/优先级发出异常请求
             → 向量表的 EXTI0_IRQHandler 被执行
             → ISR 清 pending、记录最小事件
             → 异常返回，主循环稍后处理业务
```

ISR 不是线程：它打断当前代码，在同一栈上运行，可能被更高抢占优先级的中断再次打断。因此 ISR 的职责应尽量短：读取必要状态、清硬件标志、写事件/放数据；不要 `printf`、`Delay_ms`、等待外设或访问文件系统。

## 6.2 NVIC：先确定优先级分组，再分配数字

Cortex-M3 的 NVIC 负责使能、pending、嵌套与优先级。F103 实现 4 个有效优先级位；“抢占优先级”和“子优先级”如何切分，取决于**全局优先级分组**。必须在初始化任何中断前只配置一次：

```c
/* 2 位抢占优先级 + 2 位子优先级。本书的示例统一采用它。 */
NVIC_PriorityGroupConfig(NVIC_PriorityGroup_2);
```

| 字段 | 决定什么 | 例子 |
|---|---|---|
| 抢占优先级 | 一个 ISR 能否打断另一个 ISR | SysTick=0 可打断按键=2 |
| 子优先级 | 两个同时 pending 的 ISR 先后顺序 | 同一抢占级下 UART=0 先于 DMA=1 |
| 数字方向 | 数字越小优先级越高 | `0` 高于 `3` |

不要在不同驱动里各自调用 `NVIC_PriorityGroupConfig()`。那会改变已有优先级数字的解释。先做系统表，再填 `NVIC_InitTypeDef`：

```c
NVIC_InitTypeDef nvic;
nvic.NVIC_IRQChannel = EXTI0_IRQn;
nvic.NVIC_IRQChannelPreemptionPriority = 2U;
nvic.NVIC_IRQChannelSubPriority = 0U;
nvic.NVIC_IRQChannelCmd = ENABLE;
NVIC_Init(&nvic);
```

## 6.3 EXTI 的硬件限制与按键接法

EXTI 有 0–15 共 16 条线。每条线一次只能选 A–G 中一个同号引脚：例如 EXTI0 可以来自 PA0 或 PB0，但不能同时来自两者。选择由 AFIO 配置，触发边沿和 pending 由 EXTI 配置。

> **AFIO 是什么？** AFIO（Alternate Function IO，复用功能 IO）是 STM32F1 上的一个辅助模块，负责两件事：一是**把 GPIO 引脚连接到 EXTI 线**（即这里的 `GPIO_EXTILineConfig`），二是**重映射外设的默认引脚**（例如把 USART1 从 PA9/PA10 移到 PB6/PB7）。如果要使用 EXTI、重映射或调试 IO 配置，都必须先打开 AFIO 时钟。这就是代码中 `RCC_APB2PeriphClockCmd(..., RCC_APB2Periph_AFIO, ENABLE)` 的原因。

本章采用**外接**默认实验：PA0 通过按键接 GND，MCU 开内部上拉；松开为高、按下为低，所以选择下降沿。它不是板载按键的断言，实际接线先写进 [板卡资源约定](./board-zet6-profile.md)。

```c
static void ButtonExti_Init(void)
{
    GPIO_InitTypeDef gpio;
    EXTI_InitTypeDef exti;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA |
                            RCC_APB2Periph_AFIO, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IPU;       /* 内部上拉，按下接地 */
    GPIO_Init(GPIOA, &gpio);

    GPIO_EXTILineConfig(GPIO_PortSourceGPIOA, GPIO_PinSource0);
    EXTI_StructInit(&exti);
    exti.EXTI_Line = EXTI_Line0;
    exti.EXTI_Mode = EXTI_Mode_Interrupt;
    exti.EXTI_Trigger = EXTI_Trigger_Falling;
    exti.EXTI_LineCmd = ENABLE;
    EXTI_Init(&exti);
    EXTI_ClearITPendingBit(EXTI_Line0);    /* 开 NVIC 前清遗留 pending */

    NVIC_InitTypeDef nvic;
    nvic.NVIC_IRQChannel = EXTI0_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 2U;
    nvic.NVIC_IRQChannelSubPriority = 0U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}
```

## 6.4 ISR 与主循环：事件不是变量“恰好能用”

机械按键会在 5–20ms 内产生多次边沿。ISR 不在里面延时消抖；它只把多个边沿合并为“有一个按键候选事件”，主循环用第 5 章时基验证稳定电平：

```c
static volatile uint8_t g_button_edge;

void EXTI0_IRQHandler(void)
{
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        g_button_edge = 1U;      /* 多次抖动可安全合并为一个候选事件。 */
    }
}

static uint8_t TakeButtonEdge(void)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    uint8_t edge = g_button_edge;
    g_button_edge = 0U;
    if (primask == 0U)
        __enable_irq();
    return edge;
}

typedef enum {
    BUTTON_IDLE,
    BUTTON_DEBOUNCING_PRESS,
    BUTTON_WAIT_RELEASE,
    BUTTON_DEBOUNCING_RELEASE
} ButtonState;

static uint8_t Button_PollPressed(void)
{
    static ButtonState state;
    static uint32_t confirm_at;
    uint32_t now = Timebase_NowMs();

    if (state == BUTTON_IDLE && TakeButtonEdge() != 0U) {
        state = BUTTON_DEBOUNCING_PRESS;
        confirm_at = now + 30U;
    }

    if (state == BUTTON_DEBOUNCING_PRESS &&
        (int32_t)(now - confirm_at) >= 0) {
        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
            state = BUTTON_WAIT_RELEASE;
            return 1U;            /* 只在一次稳定按下时发事件。 */
        }
        state = BUTTON_IDLE;
    }

    if (state == BUTTON_WAIT_RELEASE &&
        GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_SET) {
        state = BUTTON_DEBOUNCING_RELEASE;
        confirm_at = now + 30U;
    }

    if (state == BUTTON_DEBOUNCING_RELEASE &&
        (int32_t)(now - confirm_at) >= 0) {
        state = GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_SET
              ? BUTTON_IDLE : BUTTON_WAIT_RELEASE;
    }

    /* 消费抖动期间的重复边沿；真正状态由稳定电平决定。 */
    if (state != BUTTON_IDLE)
        (void)TakeButtonEdge();
    return 0U;
}
```

这个模型故意使用一个 bit，因为按键不关心“30ms 内到底抖了几次”。串口、采样或网络数据不能这样丢事件，后续章节会使用环形缓冲、DMA、队列和序号。

### 为什么 `volatile` 还不够

`volatile uint32_t counter; counter++;` 至少包含读取、加法、写回三个动作。主循环和 ISR 若同时执行，可能发生：

```text
main 读取 10 → 被 ISR 打断 → ISR 写回 11 → main 用旧值写回 11
```

最终只增加一次。对齐的单次 8/16/32 位加载或存储通常可在 Cortex-M3 上作为单条访问完成，但“读取再修改再写回”不是原子的；64 位对象、结构体和数组更不能假设原子。临界区必须保存原有 PRIMASK：

```c
static volatile uint32_t counter;

static uint32_t Counter_TakeAndClear(void)
{
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    uint32_t value = counter;
    counter = 0U;
    if (primask == 0U)
        __enable_irq();
    return value;
}
```

临界区只包住必要的读写；在里面 `printf`、I2C 轮询或延时会增加中断延迟。FreeRTOS 启用后不能直接照搬裸机 `__disable_irq()` 规则，应使用其临界区和 ISR 安全 API。

## 6.5 中断设计检查表

每加一个 IRQ，填写以下表，避免“代码有 Handler 就算完成”：

| 项 | 要回答的问题 |
|---|---|
| 来源 | 外设/引脚/边沿或状态位是什么？ |
| 清除 | 哪个 pending/状态位在什么时候清？ |
| 交接 | ISR 给主循环/任务的是标志、计数、缓冲区还是队列？ |
| 并发 | 谁写、谁读、需要临界区还是原子协议？ |
| 优先级 | 分组已定吗？是否会与 SysTick/UART/DMA 互相抢占？ |
| 预算 | ISR 最长执行时间、允许的中断延迟是什么？ |
| 验收 | 用什么信号证明没有漏、重、卡死？ |

## 6.6 验收、排错与练习

| 现象 | 优先检查 |
|---|---|
| 一次也不进 ISR | GPIO 时钟、AFIO 时钟、端口到 EXTI 映射、边沿选择、NVIC 使能、Handler 名称 |
| 一按进很多次 | 机械抖动；确认 ISR 只置事件，主循环负责确认 |
| 进一次后持续重入 | pending 位没有清，或电平/边沿配置不符合接线 |
| 主程序偶发卡死 | ISR 中有延时/等待/printf，或临界区没有恢复原 PRIMASK |
| 变量偶尔错误 | 复合操作没有保护；多个写者没有协议 |
| 优先级“数字正确却行为怪” | 优先级分组被不同模块改过，或混淆了抢占与子优先级 |

练习：

1. 让 PA0 按下只设置事件位，主循环切换 `BoardLed_Write()`；连续按 20 次并记录漏/重触发；
2. 给 EXTI0 和一个定时器分别设不同抢占优先级，用 GPIO 脉冲观察嵌套顺序；
3. 把事件 bit 改成计数器，先演示 `++` 丢计数，再通过最小临界区修复；
4. 删除 `BUTTON_WAIT_RELEASE` 分支并长按按键，观察为何会出现重复事件；恢复该状态后再验证。

## 6.7 本章要点

- 中断路径包含 GPIO/外设、pending、NVIC、向量表和正确命名的 Handler；漏任一步都不会工作。
- 优先级数字只有在固定的 `NVIC_PriorityGroupConfig()` 下才有含义。
- ISR 短、确定、只交接最小数据；耗时业务和消抖进入主循环/任务。
- `volatile` 保留访问，但不让复合操作原子；读清/计数/结构体交接需要明确并发协议。
- 临界区要保存并恢复先前的 PRIMASK，且范围应尽可能小。

---

> **上一章**：[第 5 章 · 时钟、时基与可测时间](./05-chapter.md)
>
> **下一章**：[第 7 章 · 定时器](./07-chapter.md)

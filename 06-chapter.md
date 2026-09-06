# 第 6 章 · 中断、事件与并发边界（SPL 版）

这一章把 GPIO 边沿接进 EXTI 和 NVIC，再把中断里捕获的事件安全交给主循环。完成后，PA0 按键可以通过下降沿触发 EXTI0，ISR 只记录事件，主循环完成消抖和业务处理。

前面已经用过 GPIO 和 1 ms 时基。本章重点是中断路径、优先级、pending 位，以及 ISR 和主循环同时访问数据时会发生什么。

## 6.1 从引脚边沿到 ISR

以 PA0 的下降沿为例，硬件路径如下：

```text
PA0 电平变化
  ↓
AFIO：把 GPIOA.0 映射到 EXTI0
  ↓
EXTI0：检测下降沿并置 pending
  ↓
NVIC：检查使能和优先级
  ↓
向量表：找到 EXTI0_IRQHandler
  ↓
ISR：清 pending，记录事件
  ↓
异常返回，继续执行被打断的代码
```

CPU 进入 ISR 时会保存异常返回所需的现场，处理结束后恢复执行。更高抢占优先级的中断还可能在当前 ISR 执行期间进入，因此 ISR 的执行时间会直接影响其他中断的响应时间。

ISR 里只做必须立即完成的工作：读取状态、清硬件标志、保存字节或设置事件。`printf`、毫秒延时、等待 I2C/SPI 完成以及较长的业务处理都放到主循环；这些操作放在 ISR 里会延长中断占用时间，有些还依赖其他中断继续运行。

## 6.2 NVIC 优先级

Cortex-M3 的 NVIC 负责中断使能、pending、优先级和嵌套。STM32F103 实现 4 个优先级位，SPL 再根据优先级分组把它们解释为抢占优先级和子优先级。

本书示例统一使用：

```c
NVIC_PriorityGroupConfig(NVIC_PriorityGroup_2);
```

`NVIC_PriorityGroup_2` 分配 2 位抢占优先级和 2 位子优先级。抢占优先级决定一个 ISR 能否打断另一个 ISR；抢占优先级相同时，子优先级用于决定多个 pending 中断的响应顺序。两者都是数字越小优先级越高。

优先级分组是全局配置，初始化阶段设置一次即可。不要让各个驱动分别调用 `NVIC_PriorityGroupConfig()`，否则同一组优先级数字可能在运行期间被重新解释。

EXTI0 的 NVIC 配置可以写成：

```c
NVIC_InitTypeDef nvic;

nvic.NVIC_IRQChannel = EXTI0_IRQn;
nvic.NVIC_IRQChannelPreemptionPriority = 2U;
nvic.NVIC_IRQChannelSubPriority = 0U;
nvic.NVIC_IRQChannelCmd = ENABLE;
NVIC_Init(&nvic);
```

优先级要按系统里的实际中断一起分配。后面加入 UART、DMA 和定时器后，再检查哪些中断允许互相抢占，不要单独看某一个驱动里的数字。

## 6.3 配置 PA0 → EXTI0

STM32F1 的 EXTI0–EXTI15 与 GPIO 引脚号对应。EXTI0 可以选择 PA0、PB0、PC0 等同号引脚中的一个作为输入源，同一时刻不能同时接两个端口的 0 号引脚。这个映射由 AFIO 完成，因此使用 GPIO EXTI 映射前要打开 AFIO 时钟。

本章实验使用外接按键：PA0 开内部上拉，按键另一端接 GND。松开时 PA0 为高电平，按下时变低，因此 EXTI0 检测下降沿。板载按键的实际接法仍以 [板卡资源约定](./board-zet6-profile.md) 为准。

```c
static void ButtonExti_Init(void)
{
    GPIO_InitTypeDef gpio;
    EXTI_InitTypeDef exti;
    NVIC_InitTypeDef nvic;

    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA |
                            RCC_APB2Periph_AFIO, ENABLE);

    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IPU;
    GPIO_Init(GPIOA, &gpio);

    GPIO_EXTILineConfig(GPIO_PortSourceGPIOA, GPIO_PinSource0);

    EXTI_StructInit(&exti);
    exti.EXTI_Line = EXTI_Line0;
    exti.EXTI_Mode = EXTI_Mode_Interrupt;
    exti.EXTI_Trigger = EXTI_Trigger_Falling;
    exti.EXTI_LineCmd = ENABLE;
    EXTI_Init(&exti);

    EXTI_ClearITPendingBit(EXTI_Line0);

    nvic.NVIC_IRQChannel = EXTI0_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 2U;
    nvic.NVIC_IRQChannelSubPriority = 0U;
    nvic.NVIC_IRQChannelCmd = ENABLE;
    NVIC_Init(&nvic);
}
```

这里在使能 NVIC 前清一次 EXTI pending，避免初始化期间留下的状态在 NVIC 打开后立刻触发处理函数。运行时则由 ISR 在处理对应事件时清除 pending。

## 6.4 ISR 只记录按键事件

机械按键在按下和松开的瞬间可能产生一串快速电平变化。具体抖动时间取决于按键本身，代码不能把某个固定毫秒数当成所有按键的物理参数。本章用 30 ms 作为实验消抖窗口，实际产品应根据按键和测量结果调整。

ISR 只记录“出现过下降沿”：

```c
static volatile uint8_t g_button_edge;

void EXTI0_IRQHandler(void)
{
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        g_button_edge = 1U;
    }
}
```

这里用一个 bit 有明确含义：多个下降沿可以合并，因为主循环只需要知道“有一次候选按下需要确认”。UART 字节、ADC 样本这类每个数据都可能有意义的输入不能这样处理，后面会使用环形缓冲、DMA 或队列。

主循环取走事件时，要避免“读到 1 后、清零前又来一次中断”的竞态。最直接的做法是用很短的临界区完成读和清零：

```c
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
```

保存 `PRIMASK` 是为了恢复进入函数前的中断状态。如果调用者原本已经关中断，无条件执行 `__enable_irq()` 会提前打开中断。

## 6.5 在主循环里消抖

收到下降沿后先等待一段时间，再读取 PA0 的实际电平。电平仍为低，才确认一次按下；随后等待释放并确认高电平稳定，避免长按期间重复产生按下事件。

```c
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
            return 1U;
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
        if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_SET)
            state = BUTTON_IDLE;
        else
            state = BUTTON_WAIT_RELEASE;
    }

    if (state != BUTTON_IDLE)
        (void)TakeButtonEdge();

    return 0U;
}
```

主循环可以这样消费事件：

```c
for (;;) {
    if (Button_PollPressed() != 0U) {
        led_on ^= 1U;
        BoardLed_Write(led_on);
    }

    /* UART、定时任务等其他工作继续在这里运行。 */
}
```

消抖期间没有阻塞延时，主循环仍能继续处理其他任务。这里丢弃消抖期间重复出现的 EXTI0 边沿，因为最终判断依据是稳定后的 GPIO 电平。

## 6.6 `volatile` 不能解决复合操作竞态

`volatile` 会让编译器保留对共享变量的实际访问，但 `counter++` 仍然包含读取、加一、写回。主循环和 ISR 同时修改它时可能出现：

```text
counter = 10

main: 读取 10
ISR : 读取 10 → 加一 → 写回 11
main:          加一 → 写回 11
```

两次 `++` 最终只留下 11。问题发生在读—改—写被中断插入，与变量是否声明为 `volatile` 无关。

需要“取出当前计数并清零”时，可以把这两个操作放进同一个临界区：

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

临界区越长，中断被推迟的时间越长。这里只保护必要的共享状态读写，不要把 `printf`、外设轮询或延时放进去。第 14 章加入 FreeRTOS 后，任务和 ISR 之间改用 RTOS 提供的临界区、队列、通知等机制。

## 6.7 共享数据要先确定协议

ISR 和主循环共享数据时，先确定谁写、谁读，以及数据能不能合并。按键事件可以用一个 bit；累计次数可以用计数器；连续字节通常需要环形缓冲；一组必须保持一致的多个字段则需要临界区、双缓冲或其他明确的交接方式。

还要确认硬件标志如何清除。EXTI 使用 `EXTI_ClearITPendingBit()`；USART、DMA、定时器各有自己的状态位和清除规则。ISR 如果没有按参考手册要求清掉触发源，退出后可能马上再次进入。

中断优先级也属于这个协议的一部分。两个 ISR 共享同一资源时，要考虑是否允许嵌套，以及高优先级 ISR 是否会在低优先级 ISR 更新到一半时访问同一状态。

## 6.8 验证和排错

先做最小实验：按一次 PA0，确认 `EXTI0_IRQHandler` 能进入，并在 GDB 中观察 `g_button_edge`。随后连续按键和长按，确认一次稳定按下只产生一次业务事件。

遇到问题时按路径往回查：

- 一次也不进 ISR：检查 GPIOA/AFIO 时钟、EXTI 映射、触发边沿、NVIC 使能和 `EXTI0_IRQHandler` 名称。
- 进入一次后持续重入：检查 EXTI pending 是否正确清除，以及实际电平和触发边沿是否匹配。
- 一次按键产生多次业务动作：检查主循环消抖和释放状态，不要在 ISR 里直接切换业务状态。
- 主程序偶发停顿：检查 ISR 或临界区里有没有延时、阻塞轮询和输出大量日志。
- 共享计数偶尔少一次：检查是否存在未保护的 `++`、读后清零等复合操作。
- 优先级表现和预期不同：确认整个工程只设置了一次 NVIC 优先级分组，再核对抢占优先级和子优先级。

如果有逻辑分析仪，可以在 ISR 入口置一个空闲 GPIO，在退出前清零。脉冲宽度能直接反映 ISR 执行时间；同时触发两个中断源，还可以观察实际的抢占顺序。

## 6.9 练习

1. 用 PA0 下降沿产生按键事件，在主循环中切换 LED。连续按 20 次，记录实际业务事件数量。
2. 给 EXTI0 和一个定时器设置不同抢占优先级，在两个 ISR 中分别输出测试 GPIO，观察嵌套顺序。
3. 让主循环和 ISR 同时执行 `counter++`，构造足够高的中断频率观察丢计数，再用临界区修复。
4. 临时去掉 `BUTTON_WAIT_RELEASE`，长按按键并观察业务事件变化；恢复状态机后重新验证。

完成这一章后，后面的 UART、定时器和 DMA 都沿用同一套检查方法：确认触发源和 pending，缩短 ISR，把数据按明确协议交给主循环或任务。

> **上一章**：[第 5 章 · 时钟、时基与可测时间](./05-chapter.md)
>
> **下一章**：[第 7 章 · 定时器](./07-chapter.md)

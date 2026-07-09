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

EXTI 把 GPIO 引脚的电平变化转化为中断信号。STM32F103 只有 16 条 EXTI 线（EXTI0-EXTI15），每条线对应所有端口同号引脚：

```
EXTI0 ← PA0 或 PB0 或 PC0...（同一时间只能选一个端口）
EXTI1 ← PA1 或 PB1 或 PC1...
...
EXTI15 ← PA15 或 PB15...
```

通过 AFIO_EXTICR 寄存器选择哪个端口的引脚连到 EXTI 线。SPL 用 `GPIO_EXTILineConfig()` 做这个映射。

触发方式：
- **上升沿**（0→1）
- **下降沿**（1→0）
- **双边沿**（任一变化都触发）

---

## 6.4 SPL 配置按键中断

### 场景：PA0 接按键，下降沿触发中断，翻转 LED

```c
#include "stm32f10x_exti.h"
#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"
#include "misc.h"  // NVIC 配置

void Button_EXTI_Init(void) {
    // ① 开启 GPIOA 和 AFIO 时钟（AFIO 管理 EXTI 引脚映射）
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA | RCC_APB2Periph_AFIO, ENABLE);

    // ② 配置 PA0 为浮空输入
    GPIO_InitTypeDef gpio;
    gpio.GPIO_Pin  = GPIO_Pin_0;
    gpio.GPIO_Mode = GPIO_Mode_IN_FLOATING;
    GPIO_Init(GPIOA, &gpio);

    // ③ 把 PA0 映射到 EXTI0 线（AFIO 选择器）
    GPIO_EXTILineConfig(GPIO_PortSourceGPIOA, GPIO_PinSource0);

    // ④ 配置 EXTI0：下降沿触发，中断模式
    EXTI_InitTypeDef exti;
    exti.EXTI_Line    = EXTI_Line0;
    exti.EXTI_Mode    = EXTI_Mode_Interrupt;
    exti.EXTI_Trigger = EXTI_Trigger_Falling;  // 按键按下 = 高→低
    exti.EXTI_LineCmd = ENABLE;
    EXTI_Init(&exti);

    // ⑤ 配置 NVIC：EXTI0 中断优先级
    NVIC_InitTypeDef nvic;
    nvic.NVIC_IRQChannel                   = EXTI0_IRQn;
    nvic.NVIC_IRQChannelPreemptionPriority = 0x01;  // 抢占优先级 1
    nvic.NVIC_IRQChannelSubPriority        = 0x00;  // 子优先级 0
    nvic.NVIC_IRQChannelCmd                = ENABLE;
    NVIC_Init(&nvic);
}
```

### 中断服务函数

```c
// 在 main.c 或 stm32f10x_it.c 中
void EXTI0_IRQHandler(void) {
    // ① 检查是否是 EXTI0 触发
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        // ② 清除中断挂起位（必须清！否则反复进中断）
        EXTI_ClearITPendingBit(EXTI_Line0);

        // ③ 处理事件——翻转 LED
        GPIOB->ODR ^= GPIO_Pin_5;
    }
}
```

### 主函数

```c
int main(void) {
    SystemClock_Config();
    SysTick_Init();
    LED_Init();
    Button_EXTI_Init();

    while (1) {
        // CPU 可以干别的事了——按键靠中断响应，不用轮询
        // 甚至可以进入低功耗：__WFI();
    }
}
```

**⚠️ ISR 注意事项**：
- ISR 打断了主循环，**要尽快执行完**
- 不能用 `Delay_ms`（SysTick 中断优先级比 EXTI 低时，等不到 `sys_tick_ms++` 而死循环）
- 不能在 ISR 里做耗时操作——只设标志位，实际处理放主循环

---

## 6.5 中断与主循环的安全数据共享

### ISR 中只设标志，主循环处理

```c
// 全局标志——必须 volatile！
volatile uint8_t button_pressed = 0;

void EXTI0_IRQHandler(void) {
    if (EXTI_GetITStatus(EXTI_Line0) != RESET) {
        EXTI_ClearITPendingBit(EXTI_Line0);
        button_pressed = 1;  // 只设标志，ISR 尽快退出
    }
}

int main(void) {
    // ... 初始化 ...
    while (1) {
        if (button_pressed) {
            button_pressed = 0;

            // 消抖 + 处理在中断外做
            Delay_ms(30);
            if (GPIO_ReadInputDataBit(GPIOA, GPIO_Pin_0) == Bit_RESET) {
                GPIOB->ODR ^= GPIO_Pin_5;
            }
        }
    }
}
```

### `counter++` 是原子操作吗？

```c
volatile uint32_t counter = 0;

// ISR 中
void ISR(void) { counter++; }  // 「读→加1→写」三条指令，不是原子的！

// 主循环也在操作 counter 时需要临界区保护
```

**解决方案**：对于简单标志位（`flag = 0/1`），单次 32 位赋值是原子的，不需要保护。对于 `++`/`--` 这种「读-改-写」操作，用临界区：

```c
__disable_irq();
counter++;
__enable_irq();
```

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

## 6.7 本章要点

- 中断 = 外设主动通知 CPU，不用轮询；打断是硬件级的
- NVIC 管理优先级：抢占优先级决定谁能打断谁，子优先级决定排队顺序
- EXTI 把 GPIO 电平变化变成中断信号，16 条线，每条对应所有端口同号引脚
- ISR 要**短、快、不阻塞**——只设标志位，实际处理放主循环
- ISR 和主循环共享的变量必须 `volatile`；复杂操作（`++`）需要临界区保护

---

> **下一章**：[第 7 章 · 定时器（SPL版）](./07-09-chapter.md)

> SysTick 只能做简单定时。STM32 的通用定时器能做 PWM、能测脉冲宽度、能做编码器接口——这是电机控制、灯光、音频的基础。

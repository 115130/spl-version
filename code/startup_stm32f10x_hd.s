/* 精简版 startup_stm32f10x_hd.s —— GCC 汇编器用
   放到你的 lib/ 目录下，Makefile 里 ASM_SRCS 包含它 */

.syntax unified
.cpu cortex-m3
.thumb

/* 栈顶地址由链接脚本定义 */
.word _stack_top
.word Reset_Handler
.word NMI_Handler
.word HardFault_Handler
.word MemManage_Handler
.word BusFault_Handler
.word UsageFault_Handler
.word 0
.word 0
.word 0
.word 0
.word SVC_Handler
.word DebugMon_Handler
.word 0
.word PendSV_Handler
.word SysTick_Handler

/* 外设中断向量（只列出常用的，其余用 Default_Handler） */
.word WWDG_IRQHandler
.word PVD_IRQHandler
.word TAMPER_IRQHandler
.word RTC_IRQHandler
.word FLASH_IRQHandler
.word RCC_IRQHandler
.word EXTI0_IRQHandler
.word EXTI1_IRQHandler
.word EXTI2_IRQHandler
.word EXTI3_IRQHandler
.word EXTI4_IRQHandler
.word DMA1_Channel1_IRQHandler
.word DMA1_Channel2_IRQHandler
.word DMA1_Channel3_IRQHandler
.word DMA1_Channel4_IRQHandler
.word DMA1_Channel5_IRQHandler
.word DMA1_Channel6_IRQHandler
.word DMA1_Channel7_IRQHandler
.word ADC1_2_IRQHandler
.word USB_HP_CAN1_TX_IRQHandler
.word USB_LP_CAN1_RX0_IRQHandler
.word CAN1_RX1_IRQHandler
.word CAN1_SCE_IRQHandler
.word EXTI9_5_IRQHandler
.word TIM1_BRK_IRQHandler
.word TIM1_UP_IRQHandler
.word TIM1_TRG_COM_IRQHandler
.word TIM1_CC_IRQHandler
.word TIM2_IRQHandler
.word TIM3_IRQHandler
.word TIM4_IRQHandler
.word I2C1_EV_IRQHandler
.word I2C1_ER_IRQHandler
.word I2C2_EV_IRQHandler
.word I2C2_ER_IRQHandler
.word SPI1_IRQHandler
.word SPI2_IRQHandler
.word USART1_IRQHandler
.word USART2_IRQHandler
.word USART3_IRQHandler
.word EXTI15_10_IRQHandler
.word RTCAlarm_IRQHandler
.word USBWakeUp_IRQHandler
/* 后面还有几十个，完整版请看 SPL 包里的原文件 */

.section .text.Reset_Handler
.weak Reset_Handler
.type Reset_Handler, %function
Reset_Handler:
    /* 把 .data 段从 Flash 复制到 SRAM */
    ldr r0, =_data_start
    ldr r1, =_data_end
    ldr r2, =_etext
    cmp r0, r1
    beq 2f
1:  ldr r3, [r2], #4
    str r3, [r0], #4
    cmp r0, r1
    bne 1b
2:
    /* 清零 .bss 段 */
    ldr r0, =_bss_start
    ldr r1, =_bss_end
    mov r2, #0
    cmp r0, r1
    beq 4f
3:  str r2, [r0], #4
    cmp r0, r1
    bne 3b
4:
    /* 调 SystemInit() 然后跳 main() */
    bl SystemInit
    bl main
    b .

/* 默认中断处理——死循环 */
.section .text.Default_Handler
.weak Default_Handler
.type Default_Handler, %function
Default_Handler:
    b .

/* 所有没单独定义的中断都指向 Default_Handler */
.macro def_irq name
.weak \name
.set \name, Default_Handler
.endm

def_irq NMI_Handler
def_irq HardFault_Handler
def_irq MemManage_Handler
def_irq BusFault_Handler
def_irq UsageFault_Handler
def_irq SVC_Handler
def_irq DebugMon_Handler
def_irq PendSV_Handler
def_irq SysTick_Handler
def_irq WWDG_IRQHandler
def_irq EXTI0_IRQHandler
def_irq TIM2_IRQHandler
def_irq USART1_IRQHandler
def_irq USART2_IRQHandler
/* ... 更多 def_irq 见完整版 */

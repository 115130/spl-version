/*
 * STM32F103xHD / STM32F103ZET6 minimal GCC startup file.
 *
 * This file intentionally contains the complete high-density vector table.
 * Do not replace it with an MD/C8T6 table: high-density parts add ADC3,
 * FSMC, SDIO, TIM5-7, SPI3, UART4/5 and DMA2 vectors.
 */

.syntax unified
.cpu cortex-m3
.fpu softvfp
.thumb

.global g_pfnVectors
.global Reset_Handler

.section .isr_vector,"a",%progbits
.align 2
.type g_pfnVectors, %object
g_pfnVectors:
    .word _estack
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
    .word TIM8_BRK_IRQHandler
    .word TIM8_UP_IRQHandler
    .word TIM8_TRG_COM_IRQHandler
    .word TIM8_CC_IRQHandler
    .word ADC3_IRQHandler
    .word FSMC_IRQHandler
    .word SDIO_IRQHandler
    .word TIM5_IRQHandler
    .word SPI3_IRQHandler
    .word UART4_IRQHandler
    .word UART5_IRQHandler
    .word TIM6_IRQHandler
    .word TIM7_IRQHandler
    .word DMA2_Channel1_IRQHandler
    .word DMA2_Channel2_IRQHandler
    .word DMA2_Channel3_IRQHandler
    .word DMA2_Channel4_5_IRQHandler
.size g_pfnVectors, . - g_pfnVectors

.section .text.Reset_Handler,"ax",%progbits
.align 2
.type Reset_Handler, %function
Reset_Handler:
    /* Copy initialized data from Flash to SRAM. */
    ldr r0, =_sidata
    ldr r1, =_sdata
    ldr r2, =_edata
1:
    cmp r1, r2
    bcc 2f
    b 3f
2:
    ldr r3, [r0], #4
    str r3, [r1], #4
    b 1b

    /* Zero the .bss section. */
3:
    ldr r1, =_sbss
    ldr r2, =_ebss
    movs r3, #0
4:
    cmp r1, r2
    bcc 5f
    b 6f
5:
    str r3, [r1], #4
    adds r1, r1, #4
    b 4b

    /* SPL/CMSIS clock setup, C++ constructors (if any), then application. */
6:
    bl SystemInit
    bl __libc_init_array
    bl main
7:
    b 7b
.size Reset_Handler, . - Reset_Handler

.section .text.Default_Handler,"ax",%progbits
.align 2
.type Default_Handler, %function
Default_Handler:
8:
    b 8b
.size Default_Handler, . - Default_Handler

.macro WEAK_DEFAULT name
    .weak \name
    .thumb_set \name, Default_Handler
.endm

WEAK_DEFAULT NMI_Handler
WEAK_DEFAULT HardFault_Handler
WEAK_DEFAULT MemManage_Handler
WEAK_DEFAULT BusFault_Handler
WEAK_DEFAULT UsageFault_Handler
WEAK_DEFAULT SVC_Handler
WEAK_DEFAULT DebugMon_Handler
WEAK_DEFAULT PendSV_Handler
WEAK_DEFAULT SysTick_Handler
WEAK_DEFAULT WWDG_IRQHandler
WEAK_DEFAULT PVD_IRQHandler
WEAK_DEFAULT TAMPER_IRQHandler
WEAK_DEFAULT RTC_IRQHandler
WEAK_DEFAULT FLASH_IRQHandler
WEAK_DEFAULT RCC_IRQHandler
WEAK_DEFAULT EXTI0_IRQHandler
WEAK_DEFAULT EXTI1_IRQHandler
WEAK_DEFAULT EXTI2_IRQHandler
WEAK_DEFAULT EXTI3_IRQHandler
WEAK_DEFAULT EXTI4_IRQHandler
WEAK_DEFAULT DMA1_Channel1_IRQHandler
WEAK_DEFAULT DMA1_Channel2_IRQHandler
WEAK_DEFAULT DMA1_Channel3_IRQHandler
WEAK_DEFAULT DMA1_Channel4_IRQHandler
WEAK_DEFAULT DMA1_Channel5_IRQHandler
WEAK_DEFAULT DMA1_Channel6_IRQHandler
WEAK_DEFAULT DMA1_Channel7_IRQHandler
WEAK_DEFAULT ADC1_2_IRQHandler
WEAK_DEFAULT USB_HP_CAN1_TX_IRQHandler
WEAK_DEFAULT USB_LP_CAN1_RX0_IRQHandler
WEAK_DEFAULT CAN1_RX1_IRQHandler
WEAK_DEFAULT CAN1_SCE_IRQHandler
WEAK_DEFAULT EXTI9_5_IRQHandler
WEAK_DEFAULT TIM1_BRK_IRQHandler
WEAK_DEFAULT TIM1_UP_IRQHandler
WEAK_DEFAULT TIM1_TRG_COM_IRQHandler
WEAK_DEFAULT TIM1_CC_IRQHandler
WEAK_DEFAULT TIM2_IRQHandler
WEAK_DEFAULT TIM3_IRQHandler
WEAK_DEFAULT TIM4_IRQHandler
WEAK_DEFAULT I2C1_EV_IRQHandler
WEAK_DEFAULT I2C1_ER_IRQHandler
WEAK_DEFAULT I2C2_EV_IRQHandler
WEAK_DEFAULT I2C2_ER_IRQHandler
WEAK_DEFAULT SPI1_IRQHandler
WEAK_DEFAULT SPI2_IRQHandler
WEAK_DEFAULT USART1_IRQHandler
WEAK_DEFAULT USART2_IRQHandler
WEAK_DEFAULT USART3_IRQHandler
WEAK_DEFAULT EXTI15_10_IRQHandler
WEAK_DEFAULT RTCAlarm_IRQHandler
WEAK_DEFAULT USBWakeUp_IRQHandler
WEAK_DEFAULT TIM8_BRK_IRQHandler
WEAK_DEFAULT TIM8_UP_IRQHandler
WEAK_DEFAULT TIM8_TRG_COM_IRQHandler
WEAK_DEFAULT TIM8_CC_IRQHandler
WEAK_DEFAULT ADC3_IRQHandler
WEAK_DEFAULT FSMC_IRQHandler
WEAK_DEFAULT SDIO_IRQHandler
WEAK_DEFAULT TIM5_IRQHandler
WEAK_DEFAULT SPI3_IRQHandler
WEAK_DEFAULT UART4_IRQHandler
WEAK_DEFAULT UART5_IRQHandler
WEAK_DEFAULT TIM6_IRQHandler
WEAK_DEFAULT TIM7_IRQHandler
WEAK_DEFAULT DMA2_Channel1_IRQHandler
WEAK_DEFAULT DMA2_Channel2_IRQHandler
WEAK_DEFAULT DMA2_Channel3_IRQHandler
WEAK_DEFAULT DMA2_Channel4_5_IRQHandler

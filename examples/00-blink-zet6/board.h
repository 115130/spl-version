#ifndef BOARD_H
#define BOARD_H

#include "stm32f10x_gpio.h"
#include "stm32f10x_rcc.h"

/*
 * Common ZET6-board default only. Confirm this from your schematic and change
 * this file if necessary; application code must not hard-code LED pins.
 */
#define BOARD_LED_RCC       RCC_APB2Periph_GPIOC
#define BOARD_LED_PORT      GPIOC
#define BOARD_LED_PIN       GPIO_Pin_13
#define BOARD_LED_ACTIVE_LOW 1

static inline void BoardLed_Init(void)
{
    GPIO_InitTypeDef gpio;
    RCC_APB2PeriphClockCmd(BOARD_LED_RCC, ENABLE);
    GPIO_StructInit(&gpio);
    gpio.GPIO_Pin = BOARD_LED_PIN;
    gpio.GPIO_Mode = GPIO_Mode_Out_PP;
    gpio.GPIO_Speed = GPIO_Speed_2MHz;
    GPIO_Init(BOARD_LED_PORT, &gpio);
}

static inline void BoardLed_Write(uint8_t on)
{
#if BOARD_LED_ACTIVE_LOW
    if (on) GPIO_ResetBits(BOARD_LED_PORT, BOARD_LED_PIN);
    else    GPIO_SetBits(BOARD_LED_PORT, BOARD_LED_PIN);
#else
    if (on) GPIO_SetBits(BOARD_LED_PORT, BOARD_LED_PIN);
    else    GPIO_ResetBits(BOARD_LED_PORT, BOARD_LED_PIN);
#endif
}

#endif

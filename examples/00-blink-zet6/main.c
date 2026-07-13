#include "stm32f10x.h"
#include "board.h"
#include "timebase.h"

static volatile uint32_t g_ms;

void SysTick_Handler(void)
{
    g_ms++;
}

int Timebase_Init_1ms(void)
{
    SystemCoreClockUpdate();
    return SysTick_Config(SystemCoreClock / 1000U);
}

uint32_t Timebase_NowMs(void)
{
    return g_ms;
}

void Delay_ms(uint32_t delay)
{
    const uint32_t start = Timebase_NowMs();
    while ((uint32_t)(Timebase_NowMs() - start) < delay) {
        __WFI();
    }
}

int main(void)
{
    BoardLed_Init();
    BoardLed_Write(0);

    if (Timebase_Init_1ms() != 0) {
        for (;;) {
            BoardLed_Write(1);
        }
    }

    for (;;) {
        BoardLed_Write(1);
        Delay_ms(500);
        BoardLed_Write(0);
        Delay_ms(500);
    }
}

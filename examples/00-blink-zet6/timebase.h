#ifndef TIMEBASE_H
#define TIMEBASE_H

#include <stdint.h>

int Timebase_Init_1ms(void);
uint32_t Timebase_NowMs(void);
void Delay_ms(uint32_t delay);

#endif

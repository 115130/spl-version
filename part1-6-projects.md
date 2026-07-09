# 阶段项目①-⑥（SPL版）

> 所有阶段项目的逻辑、结构、状态机设计是纯软件设计。底层用 SPL 替代 HAL，上层逻辑不变。
>
> **SPL 版完整代码**：
> - 项目①②③（Part 1-3）：外设初始化使用 SPL API，详见第 3-13 章各外设的 SPL 代码示例
> - [项目④⑤⑥（Part 4-6）](./part4-6-projects.md)：SPL + FreeRTOS + WiFi + MQTT 完整代码

### SPL → HAL 快速替换表

| HAL | SPL |
|-----|-----|
| `HAL_GPIO_WritePin(PORT, PIN, RESET)` | `GPIO_ResetBits(PORT, PIN)` |
| `HAL_GPIO_WritePin(PORT, PIN, SET)` | `GPIO_SetBits(PORT, PIN)` |
| `HAL_GPIO_ReadPin(PORT, PIN)` | `GPIO_ReadInputDataBit(PORT, PIN)` |
| `HAL_GPIO_TogglePin(PORT, PIN)` | `PORT->ODR ^= PIN` |
| `HAL_Delay(ms)` | `Delay_ms(ms)`（第 5 章自实现） |
| `HAL_GetTick()` | `GetTick()`（第 5 章自实现） |
| `HAL_UART_Transmit(...)` | `USART_SendData(...)` + 等 TXE |
| `HAL_ADC_GetValue(...)` | `ADC_GetConversionValue(...)` |
| `__HAL_TIM_SET_COMPARE(...)` | `TIM_SetCompare1(...)` |
| `HAL_I2C_Master_Transmit(...)` | `I2C_xxx` 系列（较繁琐，见第 10 章） |
| `HAL_SPI_Transmit(...)` | `SPI_I2S_SendData(...)` + 等标志 |

> 继续阅读：[第 14 章 · FreeRTOS（SPL版）](./14-chapter.md)

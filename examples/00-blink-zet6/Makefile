TARGET := blink
BUILD := build
# Point this at the root of the unmodified SPL v3.5.0 archive.
SPL_ROOT ?= ../../STM32F10x_StdPeriph_Lib_V3.5.0

CC := arm-none-eabi-gcc
OBJCOPY := arm-none-eabi-objcopy
SIZE := arm-none-eabi-size
OBJDUMP := arm-none-eabi-objdump

CMSIS := $(SPL_ROOT)/Libraries/CMSIS/CM3
DEVICE := $(CMSIS)/DeviceSupport/ST/STM32F10x
SPL := $(SPL_ROOT)/Libraries/STM32F10x_StdPeriph_Driver

CFLAGS := -std=c11 -mcpu=cortex-m3 -mthumb -mfloat-abi=soft
CFLAGS += -O0 -g3 -Wall -Wextra -ffunction-sections -fdata-sections -fno-common
CFLAGS += -MMD -MP -DSTM32F10X_HD -DUSE_STDPERIPH_DRIVER
CFLAGS += -I. -I$(DEVICE) -I$(CMSIS)/CoreSupport -I$(SPL)/inc
LDFLAGS := -Tlink.ld -mcpu=cortex-m3 -mthumb -mfloat-abi=soft -nostartfiles
LDFLAGS += -Wl,--gc-sections,-Map,$(BUILD)/$(TARGET).map,--cref
LDFLAGS += -specs=nano.specs -specs=nosys.specs

OBJS := $(BUILD)/main.o $(BUILD)/startup.o $(BUILD)/system_stm32f10x.o
OBJS += $(BUILD)/core_cm3.o $(BUILD)/stm32f10x_rcc.o $(BUILD)/stm32f10x_gpio.o

.PHONY: all check-spl flash debug size clean
all: check-spl $(BUILD)/$(TARGET).elf $(BUILD)/$(TARGET).bin $(BUILD)/$(TARGET).hex size

check-spl:
	@test -f "$(SPL)/src/stm32f10x_gpio.c" && \
	      -f "$(DEVICE)/system_stm32f10x.c" && \
	      -f "$(CMSIS)/CoreSupport/core_cm3.c" || { \
		echo "SPL_ROOT must point to STM32F10x_StdPeriph_Lib_V3.5.0"; exit 2; }

$(BUILD):
	mkdir -p $@

$(BUILD)/main.o: main.c board.h timebase.h stm32f10x_conf.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/startup.o: ../../code/startup_stm32f10x_hd.s | $(BUILD)
	$(CC) -mcpu=cortex-m3 -mthumb -c $< -o $@

$(BUILD)/system_stm32f10x.o: $(DEVICE)/system_stm32f10x.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/core_cm3.o: $(CMSIS)/CoreSupport/core_cm3.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/stm32f10x_rcc.o: $(SPL)/src/stm32f10x_rcc.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/stm32f10x_gpio.o: $(SPL)/src/stm32f10x_gpio.c | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS) link.ld
	$(CC) $(OBJS) $(LDFLAGS) -o $@

$(BUILD)/$(TARGET).bin: $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/$(TARGET).hex: $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O ihex $< $@

size: $(BUILD)/$(TARGET).elf
	$(SIZE) $<
	$(OBJDUMP) -h $<

flash: $(BUILD)/$(TARGET).elf
	openocd -f interface/stlink.cfg -f target/stm32f1x.cfg \
		-c "program $< verify reset exit"

debug:
	openocd -f interface/stlink.cfg -f target/stm32f1x.cfg

clean:
	rm -rf $(BUILD)

-include $(OBJS:.o=.d)

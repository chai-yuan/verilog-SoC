#ifndef GPIO_REG_H
#define GPIO_REG_H

#include <stdbool.h>
#include <stdint.h>

typedef void    *GPIO_Addr;
typedef uint32_t GPIO_Value;
typedef uint8_t  GPIO_Pin;

enum {
    GPIO_INTERRUPT_LOW_LEVEL    = 0u,
    GPIO_INTERRUPT_HIGH_LEVEL   = 1u,
    GPIO_INTERRUPT_FALLING_EDGE = 2u,
    GPIO_INTERRUPT_RISING_EDGE  = 3u
};

#define GPIO_DETAIL_INPUT_DATA_OFFSET 0x00u
#define GPIO_DETAIL_OUTPUT_DATA_OFFSET 0x04u
#define GPIO_DETAIL_DIRECTION_OFFSET 0x08u
#define GPIO_DETAIL_INTERRUPT_ENABLE_OFFSET 0x0Cu
#define GPIO_DETAIL_INTERRUPT_TYPE_LOW_OFFSET 0x10u
#define GPIO_DETAIL_INTERRUPT_TYPE_HIGH_OFFSET 0x14u
#define GPIO_DETAIL_INTERRUPT_STATUS_OFFSET 0x18u
#define GPIO_DETAIL_INTERRUPT_CLEAR_OFFSET 0x1Cu

static inline GPIO_Value GPIO_GetInputData(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INPUT_DATA_OFFSET);
}

static inline GPIO_Value GPIO_GetOutputData(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_OUTPUT_DATA_OFFSET);
}

static inline void GPIO_SetOutputData(GPIO_Addr gpioaddr, GPIO_Value value) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_OUTPUT_DATA_OFFSET) = value;
}

static inline GPIO_Value GPIO_GetDirection(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_DIRECTION_OFFSET);
}

static inline void GPIO_SetDirection(GPIO_Addr gpioaddr, GPIO_Value value) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_DIRECTION_OFFSET) = value;
}

static inline GPIO_Value GPIO_GetInterruptEnable(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_ENABLE_OFFSET);
}

static inline void GPIO_SetInterruptEnable(GPIO_Addr gpioaddr, GPIO_Value value) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_ENABLE_OFFSET) = value;
}

static inline GPIO_Value GPIO_GetInterruptTypeLow(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_TYPE_LOW_OFFSET);
}

static inline void GPIO_SetInterruptTypeLow(GPIO_Addr gpioaddr, GPIO_Value value) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_TYPE_LOW_OFFSET) = value;
}

static inline GPIO_Value GPIO_GetInterruptTypeHigh(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_TYPE_HIGH_OFFSET);
}

static inline void GPIO_SetInterruptTypeHigh(GPIO_Addr gpioaddr, GPIO_Value value) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_TYPE_HIGH_OFFSET) = value;
}

static inline GPIO_Value GPIO_GetInterruptStatus(GPIO_Addr gpioaddr) {
    return *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_STATUS_OFFSET);
}

/* Writing 1 to bit 0 clears all latched interrupt status bits. */
static inline void GPIO_ClearInterruptStatus(GPIO_Addr gpioaddr) {
    *(volatile uint32_t *)((uintptr_t)gpioaddr + GPIO_DETAIL_INTERRUPT_CLEAR_OFFSET) = 1u;
}

/* Per-pin helpers. */
static inline void GPIO_SetPinOutput(GPIO_Addr gpioaddr, GPIO_Pin pin, bool high) {
    GPIO_Value value = GPIO_GetOutputData(gpioaddr);
    if (high) {
        value |= (1u << pin);
    } else {
        value &= ~(1u << pin);
    }
    GPIO_SetOutputData(gpioaddr, value);
}

static inline bool GPIO_GetPinInput(GPIO_Addr gpioaddr, GPIO_Pin pin) {
    return (GPIO_GetInputData(gpioaddr) & (1u << pin)) != 0u;
}

static inline void GPIO_SetPinDirection(GPIO_Addr gpioaddr, GPIO_Pin pin, bool output) {
    GPIO_Value value = GPIO_GetDirection(gpioaddr);
    if (output) {
        value |= (1u << pin);
    } else {
        value &= ~(1u << pin);
    }
    GPIO_SetDirection(gpioaddr, value);
}

static inline void GPIO_SetPinInterruptType(GPIO_Addr gpioaddr, GPIO_Pin pin, uint8_t type) {
    GPIO_Value mask  = 3u << (pin * 2u);
    GPIO_Value field = (type & 3u) << (pin * 2u);

    if (pin < 16u) {
        GPIO_SetInterruptTypeLow(gpioaddr, (GPIO_GetInterruptTypeLow(gpioaddr) & ~mask) | field);
    } else {
        GPIO_Value shift_pin = pin - 16u;
        mask                 = 3u << (shift_pin * 2u);
        field                = (type & 3u) << (shift_pin * 2u);
        GPIO_SetInterruptTypeHigh(gpioaddr, (GPIO_GetInterruptTypeHigh(gpioaddr) & ~mask) | field);
    }
}

#undef GPIO_DETAIL_INPUT_DATA_OFFSET
#undef GPIO_DETAIL_OUTPUT_DATA_OFFSET
#undef GPIO_DETAIL_DIRECTION_OFFSET
#undef GPIO_DETAIL_INTERRUPT_ENABLE_OFFSET
#undef GPIO_DETAIL_INTERRUPT_TYPE_LOW_OFFSET
#undef GPIO_DETAIL_INTERRUPT_TYPE_HIGH_OFFSET
#undef GPIO_DETAIL_INTERRUPT_STATUS_OFFSET
#undef GPIO_DETAIL_INTERRUPT_CLEAR_OFFSET

#endif

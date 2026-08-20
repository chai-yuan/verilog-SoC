#ifndef UART_REG_H
#define UART_REG_H

#include <stdbool.h>
#include <stdint.h>

typedef void   *UART_Addr;
typedef uint8_t UART_Status;

enum {
    UART_RX_VALID      = 1u << 0,
    UART_RX_FULL       = 1u << 1,
    UART_TX_EMPTY      = 1u << 2,
    UART_TX_FULL       = 1u << 3,
    UART_INTR_ENABLED  = 1u << 4,
    UART_OVERRUN_ERROR = 1u << 5,
    UART_FRAME_ERROR   = 1u << 6,
    UART_PARITY_ERROR  = 1u << 7
};

#define UART_DETAIL_RX_OFFSET 0x00u
#define UART_DETAIL_TX_OFFSET 0x04u
#define UART_DETAIL_STATUS_OFFSET 0x08u
#define UART_DETAIL_CONTROL_OFFSET 0x0Cu

#define UART_DETAIL_TX_RESET (1u << 0)
#define UART_DETAIL_RX_RESET (1u << 1)
#define UART_DETAIL_INTR_ENABLE (1u << 4)

/*
 * Reading STATUS clears the latched overrun and frame error flags in hardware.
 * Keep the returned snapshot when more than one status field must be checked.
 */
static inline UART_Status UART_GetStatus(UART_Addr uartaddr) {
    return (UART_Status)(*(volatile uint32_t *)((uintptr_t)uartaddr + UART_DETAIL_STATUS_OFFSET));
}

/* A halfword access selects control-register byte lanes 2 and 3 only. */
static inline void UART_SetPrescale(UART_Addr uartaddr, uint16_t prescale) {
    *(volatile uint16_t *)((uintptr_t)uartaddr + UART_DETAIL_CONTROL_OFFSET + 2u) = prescale;
}

/* A byte access updates interrupt enable without overwriting prescale. */
static inline void UART_SetInterrupt(UART_Addr uartaddr, bool enabled) {
    *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_CONTROL_OFFSET) = enabled ? UART_DETAIL_INTR_ENABLE : 0u;
}

/* FIFO reset helpers preserve interrupt enable. Their STATUS read clears errors. */
static inline void UART_ResetTxFIFO(UART_Addr uartaddr) {
    uint8_t control = (UART_GetStatus(uartaddr) & UART_INTR_ENABLED) ? UART_DETAIL_INTR_ENABLE : 0u;

    *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_CONTROL_OFFSET) = (uint8_t)(control | UART_DETAIL_TX_RESET);
}

static inline void UART_ResetRxFIFO(UART_Addr uartaddr) {
    uint8_t control = (UART_GetStatus(uartaddr) & UART_INTR_ENABLED) ? UART_DETAIL_INTR_ENABLE : 0u;

    *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_CONTROL_OFFSET) = (uint8_t)(control | UART_DETAIL_RX_RESET);
}

static inline void UART_ResetFIFO(UART_Addr uartaddr) {
    uint8_t control = (UART_GetStatus(uartaddr) & UART_INTR_ENABLED) ? UART_DETAIL_INTR_ENABLE : 0u;

    *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_CONTROL_OFFSET) =
        (uint8_t)(control | UART_DETAIL_TX_RESET | UART_DETAIL_RX_RESET);
}

static inline void UART_WriteByte(UART_Addr uartaddr, uint8_t data) {
    *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_TX_OFFSET) = data;
}

static inline uint8_t UART_ReadByte(UART_Addr uartaddr) {
    return *(volatile uint8_t *)((uintptr_t)uartaddr + UART_DETAIL_RX_OFFSET);
}

#undef UART_DETAIL_RX_OFFSET
#undef UART_DETAIL_TX_OFFSET
#undef UART_DETAIL_STATUS_OFFSET
#undef UART_DETAIL_CONTROL_OFFSET
#undef UART_DETAIL_TX_RESET
#undef UART_DETAIL_RX_RESET
#undef UART_DETAIL_INTR_ENABLE

#endif

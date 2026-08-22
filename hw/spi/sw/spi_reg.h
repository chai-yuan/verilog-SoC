#ifndef SPI_REG_H
#define SPI_REG_H

#include <stdbool.h>
#include <stdint.h>

typedef void *SPI_Addr;

#define SPI_DETAIL_CONFIG_OFFSET   0x00u
#define SPI_DETAIL_PRESCALE_OFFSET 0x04u
#define SPI_DETAIL_DATA_OFFSET     0x08u
#define SPI_DETAIL_SS_OFFSET       0x0Cu

#define SPI_DETAIL_CONFIG_CPOL     (1u << 0)
#define SPI_DETAIL_CONFIG_CPHA     (1u << 1)
#define SPI_DETAIL_CONFIG_LENGTH_SHIFT 8u
#define SPI_DETAIL_CONFIG_LENGTH_MASK  (0xFFu << SPI_DETAIL_CONFIG_LENGTH_SHIFT)

#define SPI_DETAIL_SS_ASSERT        0u
#define SPI_DETAIL_SS_DEASSERT      1u

static inline uint32_t SPI_GetConfig(SPI_Addr spiaddr) {
    return *(volatile uint32_t *)((uintptr_t)spiaddr + SPI_DETAIL_CONFIG_OFFSET);
}

static inline void SPI_SetConfig(SPI_Addr spiaddr, bool cpol, bool cpha, uint8_t length) {
    uint32_t config = ((uint32_t)length << SPI_DETAIL_CONFIG_LENGTH_SHIFT) &
                      SPI_DETAIL_CONFIG_LENGTH_MASK;

    if (cpol) {
        config |= SPI_DETAIL_CONFIG_CPOL;
    }
    if (cpha) {
        config |= SPI_DETAIL_CONFIG_CPHA;
    }

    *(volatile uint32_t *)((uintptr_t)spiaddr + SPI_DETAIL_CONFIG_OFFSET) = config;
}

static inline void SPI_SetPrescale(SPI_Addr spiaddr, uint8_t prescale) {
    *(volatile uint8_t *)((uintptr_t)spiaddr + SPI_DETAIL_PRESCALE_OFFSET) = prescale;
}

static inline uint8_t SPI_GetPrescale(SPI_Addr spiaddr) {
    return *(volatile uint8_t *)((uintptr_t)spiaddr + SPI_DETAIL_PRESCALE_OFFSET);
}

/* Writing DATA starts one SPI transaction. The returned DATA value is RX data. */
static inline void SPI_WriteData(SPI_Addr spiaddr, uint32_t data) {
    *(volatile uint32_t *)((uintptr_t)spiaddr + SPI_DETAIL_DATA_OFFSET) = data;
}

static inline uint32_t SPI_ReadData(SPI_Addr spiaddr) {
    return *(volatile uint32_t *)((uintptr_t)spiaddr + SPI_DETAIL_DATA_OFFSET);
}

/* SS is active-low: 0 asserts the slave, 1 releases it. */
static inline void SPI_SetSS(SPI_Addr spiaddr, bool asserted) {
    *(volatile uint8_t *)((uintptr_t)spiaddr + SPI_DETAIL_SS_OFFSET) =
        asserted ? SPI_DETAIL_SS_ASSERT : SPI_DETAIL_SS_DEASSERT;
}

static inline bool SPI_GetSS(SPI_Addr spiaddr) {
    return *(volatile uint8_t *)((uintptr_t)spiaddr + SPI_DETAIL_SS_OFFSET) ==
           SPI_DETAIL_SS_ASSERT;
}

#undef SPI_DETAIL_CONFIG_OFFSET
#undef SPI_DETAIL_PRESCALE_OFFSET
#undef SPI_DETAIL_DATA_OFFSET
#undef SPI_DETAIL_SS_OFFSET
#undef SPI_DETAIL_CONFIG_CPOL
#undef SPI_DETAIL_CONFIG_CPHA
#undef SPI_DETAIL_CONFIG_LENGTH_SHIFT
#undef SPI_DETAIL_CONFIG_LENGTH_MASK
#undef SPI_DETAIL_SS_ASSERT
#undef SPI_DETAIL_SS_DEASSERT

#endif

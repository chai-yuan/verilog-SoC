#ifndef DMA_REG_H
#define DMA_REG_H

#include <stdbool.h>
#include <stdint.h>

typedef void    *DMA_Addr;
typedef uint32_t DMA_Address;
typedef uint32_t DMA_Count;
typedef uint8_t  DMA_Size;
typedef uint32_t DMA_Status;

enum {
    DMA_STATUS_BUSY              = 1u << 0,
    DMA_STATUS_DONE              = 1u << 1,
    DMA_STATUS_ERROR             = 1u << 2,
    DMA_STATUS_READ_BUSY         = 1u << 3,
    DMA_STATUS_WRITE_BUSY        = 1u << 4,
    DMA_STATUS_READ_ERROR        = 1u << 5,
    DMA_STATUS_WRITE_ERROR       = 1u << 6,
    DMA_STATUS_CONFIG_ERROR      = 1u << 7,
    DMA_STATUS_FIFO_FULL         = 1u << 8,
    DMA_STATUS_FIFO_RAM_EMPTY    = 1u << 9,
    DMA_STATUS_INTERRUPT_ENABLED = 1u << 10,
    DMA_STATUS_ABORTING          = 1u << 11
};

#define DMA_DETAIL_READ_BEGIN_OFFSET 0x00u
#define DMA_DETAIL_READ_STEP_OFFSET 0x04u
#define DMA_DETAIL_READ_COUNT_OFFSET 0x08u
#define DMA_DETAIL_READ_SIZE_OFFSET 0x0Cu
#define DMA_DETAIL_WRITE_BEGIN_OFFSET 0x10u
#define DMA_DETAIL_WRITE_STEP_OFFSET 0x14u
#define DMA_DETAIL_WRITE_COUNT_OFFSET 0x18u
#define DMA_DETAIL_WRITE_SIZE_OFFSET 0x1Cu
#define DMA_DETAIL_CONTROL_OFFSET 0x20u
#define DMA_DETAIL_STATUS_OFFSET 0x24u

#define DMA_DETAIL_CONTROL_START (1u << 0)
#define DMA_DETAIL_CONTROL_ABORT (1u << 1)
#define DMA_DETAIL_CONTROL_CLEAR_STATUS (1u << 2)
#define DMA_DETAIL_CONTROL_INTERRUPT_ENABLE (1u << 8)

static inline void DMA_ConfigureRead(
    DMA_Addr dmaaddr,
    DMA_Address begin,
    DMA_Address step,
    DMA_Count count,
    DMA_Size size
) {
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_READ_BEGIN_OFFSET) = begin;
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_READ_STEP_OFFSET) = step;
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_READ_COUNT_OFFSET) = count;
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_READ_SIZE_OFFSET) = size;
}

static inline void DMA_ConfigureWrite(
    DMA_Addr dmaaddr,
    DMA_Address begin,
    DMA_Address step,
    DMA_Count count,
    DMA_Size size
) {
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_WRITE_BEGIN_OFFSET) = begin;
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_WRITE_STEP_OFFSET) = step;
    *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_WRITE_COUNT_OFFSET) = count;
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_WRITE_SIZE_OFFSET) = size;
}

/*
 * The read and write configurations must describe the same total byte count:
 * read_count * read_size == write_count * write_size.
 */
static inline void DMA_Start(DMA_Addr dmaaddr) {
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_CONTROL_OFFSET) =
        DMA_DETAIL_CONTROL_START;
}

/*
 * Abort stops issuing stream data, then drains any accepted AXI-Lite request.
 * Already accepted writes may still take effect. BUSY clears after draining completes.
 */
static inline void DMA_Abort(DMA_Addr dmaaddr) {
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_CONTROL_OFFSET) =
        DMA_DETAIL_CONTROL_ABORT;
}

static inline void DMA_ClearStatus(DMA_Addr dmaaddr) {
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_CONTROL_OFFSET) =
        DMA_DETAIL_CONTROL_CLEAR_STATUS;
}

/* Byte lane 1 contains CONTROL bit 8, so this does not trigger command bits 0-2. */
static inline void DMA_SetInterrupt(DMA_Addr dmaaddr, bool enabled) {
    *(volatile uint8_t *)((uintptr_t)dmaaddr + DMA_DETAIL_CONTROL_OFFSET + 1u) =
        enabled ? 1u : 0u;
}

static inline DMA_Status DMA_GetStatus(DMA_Addr dmaaddr) {
    return *(volatile uint32_t *)((uintptr_t)dmaaddr + DMA_DETAIL_STATUS_OFFSET);
}

static inline bool DMA_IsBusy(DMA_Addr dmaaddr) {
    return (DMA_GetStatus(dmaaddr) & DMA_STATUS_BUSY) != 0u;
}

static inline bool DMA_IsDone(DMA_Addr dmaaddr) {
    return (DMA_GetStatus(dmaaddr) & DMA_STATUS_DONE) != 0u;
}

static inline bool DMA_HasError(DMA_Addr dmaaddr) {
    return (DMA_GetStatus(dmaaddr) & DMA_STATUS_ERROR) != 0u;
}

/* Safe convenience operation for arbitrary byte-aligned source and destination ranges. */
static inline void DMA_CopyBytes(
    DMA_Addr dmaaddr,
    DMA_Address destination,
    DMA_Address source,
    DMA_Count length
) {
    if (length == 0u) {
        return;
    }

    DMA_ConfigureRead(dmaaddr, source, 1u, length, 1u);
    DMA_ConfigureWrite(dmaaddr, destination, 1u, length, 1u);
    DMA_Start(dmaaddr);
}

#undef DMA_DETAIL_READ_BEGIN_OFFSET
#undef DMA_DETAIL_READ_STEP_OFFSET
#undef DMA_DETAIL_READ_COUNT_OFFSET
#undef DMA_DETAIL_READ_SIZE_OFFSET
#undef DMA_DETAIL_WRITE_BEGIN_OFFSET
#undef DMA_DETAIL_WRITE_STEP_OFFSET
#undef DMA_DETAIL_WRITE_COUNT_OFFSET
#undef DMA_DETAIL_WRITE_SIZE_OFFSET
#undef DMA_DETAIL_CONTROL_OFFSET
#undef DMA_DETAIL_STATUS_OFFSET
#undef DMA_DETAIL_CONTROL_START
#undef DMA_DETAIL_CONTROL_ABORT
#undef DMA_DETAIL_CONTROL_CLEAR_STATUS
#undef DMA_DETAIL_CONTROL_INTERRUPT_ENABLE

#endif

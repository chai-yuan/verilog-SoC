import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import AxiLiteBus, AxiLiteRam


CLOCK_PERIOD_NS = 10
DATA_WIDTH = 32
DATA_MASK = (1 << DATA_WIDTH) - 1

READ_BEGIN = 0x00
READ_STEP = 0x04
READ_COUNT = 0x08
READ_SIZE = 0x0C
WRITE_BEGIN = 0x10
WRITE_STEP = 0x14
WRITE_COUNT = 0x18
WRITE_SIZE = 0x1C
CONTROL = 0x20
STATUS = 0x24

CONTROL_START = 1 << 0
CONTROL_ABORT = 1 << 1
CONTROL_CLEAR_STATUS = 1 << 2

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1
STATUS_ERROR = 1 << 2
STATUS_CONFIG_ERROR = 1 << 7
STATUS_INTERRUPT_ENABLED = 1 << 10
STATUS_ABORTING = 1 << 11


class TB:
    def __init__(self, dut):
        self.dut = dut
        cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())
        self.ram = AxiLiteRam(
            AxiLiteBus.from_prefix(dut, "m_axil"),
            dut.clock,
            dut.reset,
            size=4096,
        )

        dut.s_valid.value = 0
        dut.s_addr.value = 0
        dut.s_write.value = 0
        dut.s_wdata.value = 0
        dut.s_wstrb.value = 0

    async def reset(self):
        self.dut.reset.value = 1
        await RisingEdge(self.dut.clock)
        await RisingEdge(self.dut.clock)
        self.dut.reset.value = 0
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)

    async def write(self, address, data, strobe=0xF):
        self.dut.s_addr.value = address
        self.dut.s_write.value = 1
        self.dut.s_wdata.value = data & DATA_MASK
        self.dut.s_wstrb.value = strobe
        self.dut.s_valid.value = 1
        await Timer(1, unit="ns")
        assert self.dut.s_ready.value == 1
        assert self.dut.s_error.value == 0
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)
        self.dut.s_valid.value = 0
        self.dut.s_write.value = 0
        self.dut.s_wstrb.value = 0

    async def read(self, address):
        self.dut.s_addr.value = address
        self.dut.s_write.value = 0
        self.dut.s_valid.value = 1
        await Timer(1, unit="ns")
        assert self.dut.s_ready.value == 1
        assert self.dut.s_error.value == 0
        value = int(self.dut.s_rdata.value)
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)
        self.dut.s_valid.value = 0
        return value

    async def configure(self, read, write):
        for address, value in zip(
            (READ_BEGIN, READ_STEP, READ_COUNT, READ_SIZE), read
        ):
            await self.write(address, value)
        for address, value in zip(
            (WRITE_BEGIN, WRITE_STEP, WRITE_COUNT, WRITE_SIZE), write
        ):
            await self.write(address, value)

    async def wait_status(self, mask, expected, limit=1000):
        for _ in range(limit):
            status = await self.read(STATUS)
            if status & mask == expected:
                return status
        raise AssertionError(
            f"status timeout: mask=0x{mask:08x}, expected=0x{expected:08x}"
        )


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_registers_and_config_error(dut):
    tb = TB(dut)
    await tb.reset()

    assert await tb.read(STATUS) & (STATUS_BUSY | STATUS_DONE | STATUS_ERROR) == 0

    await tb.write(READ_BEGIN, 0x11223344)
    await tb.write(READ_BEGIN + 1, 0x0000AA00, strobe=0x2)
    assert await tb.read(READ_BEGIN) == 0x1122AA44

    await tb.configure(
        read=(0x100, 4, 1, 4),
        write=(0x200, 4, 1, 4),
    )
    await tb.write(CONTROL, CONTROL_START | CONTROL_ABORT, strobe=0x1)
    await RisingEdge(dut.clock)
    assert await tb.read(STATUS) & (STATUS_BUSY | STATUS_DONE) == 0

    await tb.configure(
        read=(0x100, 4, 2, 4),
        write=(0x200, 4, 1, 4),
    )
    await tb.write(CONTROL, CONTROL_START, strobe=0x1)
    status = await tb.read(STATUS)
    assert status & (STATUS_ERROR | STATUS_CONFIG_ERROR) == (
        STATUS_ERROR | STATUS_CONFIG_ERROR
    )
    assert status & STATUS_BUSY == 0

    await tb.write(CONTROL, CONTROL_CLEAR_STATUS, strobe=0x1)
    assert await tb.read(STATUS) & (STATUS_DONE | STATUS_ERROR) == 0

    dut.s_addr.value = 0x40
    dut.s_write.value = 0
    dut.s_valid.value = 1
    await Timer(1, unit="ns")
    assert dut.s_error.value == 1
    dut.s_valid.value = 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_memory_copy_grouping_and_interrupt(dut):
    tb = TB(dut)
    await tb.reset()

    source = 0x100
    destination = 0x202
    payload = bytes((0x31 + index * 0x17) & 0xFF for index in range(16))
    tb.ram.write(source, payload)

    for index in range(8):
        tb.ram.write(0x200 + index * 4, b"\xA5\xA5\xA5\xA5")

    await tb.configure(
        read=(source, 4, 4, 4),
        write=(destination, 4, 8, 2),
    )
    await tb.write(CONTROL + 1, 0x00000100, strobe=0x2)
    assert await tb.read(STATUS) & STATUS_INTERRUPT_ENABLED

    await tb.write(CONTROL, CONTROL_START, strobe=0x1)
    await tb.wait_status(STATUS_DONE | STATUS_BUSY, STATUS_DONE)

    for index in range(8):
        expected = b"\xA5\xA5" + payload[index * 2 : index * 2 + 2]
        assert tb.ram.read(0x200 + index * 4, 4) == expected

    assert dut.interrupt.value == 1
    await tb.write(CONTROL, CONTROL_CLEAR_STATUS, strobe=0x1)
    await Timer(1, unit="ns")
    assert dut.interrupt.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_abort_drains_and_allows_restart(dut):
    tb = TB(dut)
    await tb.reset()

    tb.ram.write(0x300, bytes(range(16)))
    await tb.configure(
        read=(0x300, 4, 4, 4),
        write=(0x400, 4, 4, 4),
    )

    assert tb.ram.read_if is not None
    tb.ram.read_if.r_channel.pause = True
    await tb.write(CONTROL, CONTROL_START, strobe=0x1)
    await tb.wait_status(STATUS_BUSY, STATUS_BUSY)
    await tb.write(CONTROL, CONTROL_ABORT, strobe=0x1)
    status = await tb.read(STATUS)
    assert status & (STATUS_BUSY | STATUS_ABORTING) == (
        STATUS_BUSY | STATUS_ABORTING
    )

    tb.ram.read_if.r_channel.pause = False
    await tb.wait_status(STATUS_BUSY, 0)

    payload = b"restart!"
    tb.ram.write(0x500, payload)
    await tb.configure(
        read=(0x500, 1, len(payload), 1),
        write=(0x600, 1, len(payload), 1),
    )
    await tb.write(CONTROL, CONTROL_START, strobe=0x1)
    await tb.wait_status(STATUS_DONE | STATUS_BUSY, STATUS_DONE)
    assert tb.ram.read(0x600, len(payload)) == payload


def run_tests():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    build_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem
    sources = [
        proj_path.parents[1] / "axis" / "rtl" / "axis_fifo.v",
        proj_path.parents[1] / "axil" / "rtl" / "axil_dma_rd.v",
        proj_path.parents[1] / "axil" / "rtl" / "axil_dma_wr.v",
        proj_path.parent / "rtl" / "dma_reg_top.v",
    ]
    parameters = {"ADDR_WIDTH": 32, "DATA_WIDTH": 32, "FIFO_DEPTH": 16}

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="dma_reg_top",
        parameters=parameters,
        build_dir=build_dir,
        always=False,
        waves=True,
        build_args=[
            "--timing",
            "-Wno-PINCONNECTEMPTY",
            "-Wno-SELRANGE",
            "-Wno-SYMRSVDWORD",
        ],
    )
    results_file = runner.test(
        hdl_toplevel="dma_reg_top",
        test_module=Path(__file__).stem,
        parameters=parameters,
        build_dir=build_dir,
        results_xml="results.xml",
        waves=True,
        test_args=["--trace-file", str(build_dir / "dma_reg_top.vcd")],
    )
    test_count, failed_count = get_results(results_file)
    if failed_count:
        raise RuntimeError(f"{failed_count} of {test_count} DMA tests failed")

    print("All dma_reg_top tests passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_tests())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"dma_reg_top test failed: {error}", file=sys.stderr)
        sys.exit(1)

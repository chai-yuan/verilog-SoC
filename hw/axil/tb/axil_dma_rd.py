import itertools
import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import (
    AxiLiteRamRead,
    AxiLiteReadBus,
    AxiStreamBus,
    AxiStreamSink,
)


CLOCK_PERIOD_NS = 10
DATA_WIDTH = int(os.getenv("PARAM_DATA_WIDTH", "32"))
BYTE_LANES = DATA_WIDTH // 8


def cycle_pause(pattern):
    return itertools.cycle(pattern)


class ErrorInjectingAxiLiteRamRead(AxiLiteRamRead):
    def __init__(self, *args, **kwargs):
        self.error_addresses = set()
        super().__init__(*args, **kwargs)

    async def _read(self, address, length):
        if address in self.error_addresses:
            raise IOError("injected AXI-Lite read error")
        return await super()._read(address, length)


class TB:
    def __init__(self, dut):
        self.dut = dut
        cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())

        self.ram = ErrorInjectingAxiLiteRamRead(
            AxiLiteReadBus.from_prefix(dut, "m_axil"),
            dut.clock,
            dut.reset,
            size=4096,
        )
        self.sink = AxiStreamSink(
            AxiStreamBus.from_prefix(dut, "m_axis"), dut.clock, dut.reset
        )

        dut.read_begin.value = 0
        dut.read_step.value = 0
        dut.read_count.value = 0
        dut.read_size.value = 0
        dut.read_start.value = 0

    async def reset(self):
        self.dut.reset.value = 1
        await RisingEdge(self.dut.clock)
        await RisingEdge(self.dut.clock)
        self.dut.reset.value = 0
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)

        assert self.dut.read_busy.value == 0
        assert self.dut.read_error.value == 0
        assert self.dut.m_axil_arvalid.value == 0
        assert self.dut.m_axil_rready.value == 0
        assert self.dut.m_axis_tvalid.value == 0

    async def start(self, begin, step, count, size):
        self.dut.read_begin.value = begin
        self.dut.read_step.value = step
        self.dut.read_count.value = count
        self.dut.read_size.value = size
        self.dut.read_start.value = 1
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)
        self.dut.read_start.value = 0

    async def wait_idle(self, limit=200):
        for _ in range(limit):
            await FallingEdge(self.dut.clock)
            if not self.dut.read_busy.value:
                return
        raise AssertionError("DMA did not become idle")

    async def read_frame(self):
        frame = await self.sink.recv()
        return bytes(frame.tdata)


def make_word(seed):
    return bytes((seed + lane * 0x23) & 0xFF for lane in range(BYTE_LANES))


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_full_width_reads(dut):
    tb = TB(dut)
    await tb.reset()

    begin = 0x100
    addresses = [begin + index * BYTE_LANES for index in range(3)]
    word_data = [make_word(0x10 + index * 0x31) for index in range(3)]
    expected = b"".join(word_data)
    for address, data in zip(addresses, word_data):
        tb.ram.write(address, data)

    await tb.start(begin, BYTE_LANES, len(addresses), BYTE_LANES)
    received = await tb.read_frame()
    await tb.wait_idle()

    assert received == expected
    assert tb.sink.empty(), "DMA generated an unexpected extra frame"
    assert dut.read_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_short_reads_and_backpressure(dut):
    tb = TB(dut)
    await tb.reset()

    size = max(1, BYTE_LANES // 2)
    offset = BYTE_LANES - size
    begin = 0x200 + offset
    addresses = [begin + index * BYTE_LANES for index in range(4)]
    word_data = [make_word(0x21 + index * 0x19) for index in range(4)]
    expected = b"".join(data[offset : offset + size] for data in word_data)
    for address, data in zip(addresses, word_data):
        tb.ram.write(address - offset, data)

    tb.ram.ar_channel.set_pause_generator(cycle_pause([1, 1, 0, 1, 0, 0]))
    tb.ram.r_channel.set_pause_generator(cycle_pause([1, 0, 1, 1, 0]))
    tb.sink.set_pause_generator(cycle_pause([1, 1, 0, 1, 0, 0]))

    await tb.start(begin, BYTE_LANES, len(addresses), size)
    received = await tb.read_frame()
    await tb.wait_idle()

    assert received == expected
    assert tb.sink.empty(), "TLAST split the transfer into multiple frames"
    assert dut.read_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_empty_invalid_and_error_reads(dut):
    tb = TB(dut)
    await tb.reset()

    await tb.start(0x300, BYTE_LANES, 0, 1)
    await FallingEdge(dut.clock)
    assert dut.read_busy.value == 0
    assert dut.read_error.value == 0
    assert dut.m_axil_arvalid.value == 0

    await tb.start(0x300, BYTE_LANES, 1, 0)
    await tb.wait_idle()
    assert dut.read_error.value == 1
    assert dut.m_axil_arvalid.value == 0

    if BYTE_LANES > 1:
        await tb.start(0x300 + BYTE_LANES - 1, BYTE_LANES, 1, 2)
        await tb.wait_idle()
        assert dut.read_error.value == 1
        assert dut.m_axil_arvalid.value == 0

    address = 0x400
    tb.ram.error_addresses.add(address)
    await tb.start(address, BYTE_LANES, 1, 1)
    await tb.wait_idle()

    assert dut.read_error.value == 1
    assert tb.sink.empty(), "Failed AXI-Lite read produced stream data"

    await tb.start(0, BYTE_LANES, 0, 1)
    await FallingEdge(dut.clock)
    assert dut.read_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_reset_aborts_active_read(dut):
    tb = TB(dut)
    await tb.reset()

    tb.ram.write(0x500, make_word(0x63))
    tb.sink.pause = True
    await tb.start(0x500, BYTE_LANES, 2, 1)

    for _ in range(20):
        await FallingEdge(dut.clock)
        if dut.m_axis_tvalid.value:
            break

    assert dut.read_busy.value == 1
    assert dut.m_axis_tvalid.value == 1

    await tb.reset()
    assert tb.sink.empty()


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem

    for data_width in (8, 32, 64):
        parameters = {"DATA_WIDTH": data_width, "ADDR_WIDTH": 32}
        build_dir = output_dir / f"data_width-{data_width}"
        runner = get_runner(sim)
        runner.build(
            sources=[proj_path.parent / "rtl" / "axil_dma_rd.v"],
            hdl_toplevel="axil_dma_rd",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=["--timing", "--Wall"],
        )
        results_file = runner.test(
            hdl_toplevel="axil_dma_rd",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={
                "PARAM_DATA_WIDTH": str(data_width),
                "PYTHONWARNINGS": "ignore::DeprecationWarning:cocotbext.axi",
            },
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "axil_dma_rd.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"DATA_WIDTH={data_width}: {failed_count} of {test_count} tests failed"
            )

    print("All axil_dma_rd parameter configurations passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"axil_dma_rd test failed: {error}", file=sys.stderr)
        sys.exit(1)

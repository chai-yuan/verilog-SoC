import itertools
import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import (
    AxiLiteRamWrite,
    AxiLiteWriteBus,
    AxiStreamBus,
    AxiStreamFrame,
    AxiStreamSource,
)


CLOCK_PERIOD_NS = 10
DATA_WIDTH = int(os.getenv("PARAM_DATA_WIDTH", "32"))
BYTE_LANES = DATA_WIDTH // 8


def cycle_pause(pattern):
    return itertools.cycle(pattern)


class ErrorInjectingAxiLiteRamWrite(AxiLiteRamWrite):
    def __init__(self, *args, **kwargs):
        self.error_addresses = set()
        super().__init__(*args, **kwargs)

    async def _write(self, address, data):
        if address in self.error_addresses:
            raise IOError("injected AXI-Lite write error")
        await super()._write(address, data)


class TB:
    def __init__(self, dut, with_source=True):
        self.dut = dut
        cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())

        self.ram = ErrorInjectingAxiLiteRamWrite(
            AxiLiteWriteBus.from_prefix(dut, "m_axil"),
            dut.clock,
            dut.reset,
            size=4096,
        )
        self.source = None
        if with_source:
            self.source = AxiStreamSource(
                AxiStreamBus.from_prefix(dut, "s_axis"), dut.clock, dut.reset
            )
        else:
            dut.s_axis_tvalid.value = 0
            dut.s_axis_tdata.value = 0
            dut.s_axis_tlast.value = 0

        dut.write_begin.value = 0
        dut.write_step.value = 0
        dut.write_count.value = 0
        dut.write_size.value = 0
        dut.write_start.value = 0

    async def reset(self):
        self.dut.reset.value = 1
        await RisingEdge(self.dut.clock)
        await RisingEdge(self.dut.clock)
        self.dut.reset.value = 0
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)

        assert self.dut.write_busy.value == 0
        assert self.dut.write_error.value == 0
        assert self.dut.m_axil_awvalid.value == 0
        assert self.dut.m_axil_wvalid.value == 0
        assert self.dut.m_axil_bready.value == 0
        assert self.dut.s_axis_tready.value == 0

    async def start(self, begin, step, count, size):
        self.dut.write_begin.value = begin
        self.dut.write_step.value = step
        self.dut.write_count.value = count
        self.dut.write_size.value = size
        self.dut.write_start.value = 1
        await RisingEdge(self.dut.clock)
        await FallingEdge(self.dut.clock)
        self.dut.write_start.value = 0

    async def wait_idle(self, limit=300):
        for _ in range(limit):
            await FallingEdge(self.dut.clock)
            if not self.dut.write_busy.value:
                return
        raise AssertionError("DMA did not become idle")

    async def send(self, payload):
        assert self.source is not None
        await self.source.send(AxiStreamFrame(payload))

    async def send_beat(self, data, last):
        assert self.source is None
        self.dut.s_axis_tdata.value = data
        self.dut.s_axis_tlast.value = last
        self.dut.s_axis_tvalid.value = 1
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.s_axis_tready.value:
                break
        await FallingEdge(self.dut.clock)
        self.dut.s_axis_tvalid.value = 0
        self.dut.s_axis_tlast.value = 0


def make_payload(length, seed):
    return bytes((seed + index * 0x23) & 0xFF for index in range(length))


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_full_width_writes(dut):
    tb = TB(dut)
    await tb.reset()

    begin = 0x100
    count = 3
    payload = make_payload(count * BYTE_LANES, 0x10)

    assert tb.source is not None
    await tb.send(payload)
    await tb.start(begin, BYTE_LANES, count, BYTE_LANES)
    await tb.source.wait()
    await tb.wait_idle()

    assert tb.ram.read(begin, len(payload)) == payload
    assert dut.write_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_short_writes_and_backpressure(dut):
    tb = TB(dut)
    await tb.reset()

    size = max(1, BYTE_LANES // 2)
    offset = BYTE_LANES - size
    begin = 0x200 + offset
    step = BYTE_LANES * 2
    count = 4
    payload = make_payload(count * size, 0x31)
    sentinel = bytes([0xA5] * BYTE_LANES)

    for index in range(count):
        tb.ram.write((begin - offset) + index * step, sentinel)

    tb.ram.aw_channel.set_pause_generator(cycle_pause([1, 1, 0, 1, 0, 0]))
    tb.ram.w_channel.set_pause_generator(cycle_pause([0, 1, 0, 0, 1]))
    tb.ram.b_channel.set_pause_generator(cycle_pause([1, 0, 1, 1, 0]))
    assert tb.source is not None
    tb.source.set_pause_generator(cycle_pause([1, 0, 0, 1, 0]))

    await tb.send(payload)
    await tb.start(begin, step, count, size)
    await tb.source.wait()
    await tb.wait_idle()

    for index in range(count):
        word_address = (begin - offset) + index * step
        expected = bytearray(sentinel)
        expected[offset : offset + size] = payload[index * size : (index + 1) * size]
        assert tb.ram.read(word_address, BYTE_LANES) == bytes(expected)

    assert dut.write_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_empty_invalid_and_error_writes(dut):
    tb = TB(dut)
    await tb.reset()

    await tb.start(0x300, BYTE_LANES, 0, 1)
    await FallingEdge(dut.clock)
    assert dut.write_busy.value == 0
    assert dut.write_error.value == 0
    assert dut.s_axis_tready.value == 0

    await tb.start(0x300, BYTE_LANES, 1, 0)
    await tb.wait_idle()
    assert dut.write_error.value == 1
    assert dut.s_axis_tready.value == 0

    if BYTE_LANES > 1:
        await tb.start(0x300 + BYTE_LANES - 1, BYTE_LANES, 1, 2)
        await tb.wait_idle()
        assert dut.write_error.value == 1
        assert dut.s_axis_tready.value == 0

    address = 0x400
    payload = b"\x5a"
    tb.ram.error_addresses.add(address)
    assert tb.source is not None
    await tb.send(payload)
    await tb.start(address, BYTE_LANES, 1, len(payload))
    await tb.source.wait()
    await tb.wait_idle()

    assert dut.write_error.value == 1

    await tb.start(0, BYTE_LANES, 0, 1)
    await FallingEdge(dut.clock)
    assert dut.write_error.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_stream_frame_length_errors(dut):
    tb = TB(dut, with_source=False)
    await tb.reset()

    await tb.start(0x500, BYTE_LANES, 2, 1)
    await tb.send_beat(0x11, last=True)
    await tb.wait_idle()
    assert dut.write_error.value == 1
    assert tb.ram.read(0x500, BYTE_LANES) == bytes(BYTE_LANES)

    await tb.start(0x600, BYTE_LANES, 1, 1)
    await tb.send_beat(0x22, last=False)
    await tb.wait_idle()
    assert dut.write_error.value == 1
    assert tb.ram.read(0x600, BYTE_LANES) == bytes(BYTE_LANES)


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_reset_aborts_active_write(dut):
    tb = TB(dut)
    await tb.reset()

    assert tb.source is not None
    tb.source.pause = True
    await tb.send(b"\x63")
    await tb.start(0x700, BYTE_LANES, 1, 1)

    await FallingEdge(dut.clock)
    assert dut.write_busy.value == 1
    assert dut.s_axis_tready.value == 1

    await tb.reset()


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem

    for data_width in (8, 32, 64):
        parameters = {"DATA_WIDTH": data_width, "ADDR_WIDTH": 32}
        build_dir = output_dir / f"data_width-{data_width}"
        runner = get_runner(sim)
        runner.build(
            sources=[proj_path.parent / "rtl" / "axil_dma_wr.v"],
            hdl_toplevel="axil_dma_wr",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=["--timing", "--Wall"],
        )
        results_file = runner.test(
            hdl_toplevel="axil_dma_wr",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={
                "PARAM_DATA_WIDTH": str(data_width),
                "PYTHONWARNINGS": "ignore::DeprecationWarning:cocotbext.axi",
            },
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "axil_dma_wr.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"DATA_WIDTH={data_width}: {failed_count} of {test_count} tests failed"
            )

    print("All axil_dma_wr parameter configurations passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"axil_dma_wr test failed: {error}", file=sys.stderr)
        sys.exit(1)

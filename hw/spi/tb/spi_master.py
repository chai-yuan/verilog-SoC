import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


CLOCK_PERIOD_NS = 10
DATA_WIDTH = int(os.getenv("PARAM_DATA_WIDTH", "32"))
DATA_MASK = (1 << DATA_WIDTH) - 1


async def slave_exchange(dut, response, length, cpol, cpha):
    """Drive MISO and sample MOSI using the selected SPI mode."""
    received_bits = []
    response_bit = length - 1

    if not cpha:
        dut.MISO.value = (response >> response_bit) & 1

    for _ in range(2 * length):
        await dut.SCK.value_change
        leading_edge = int(dut.SCK.value) != cpol

        if leading_edge:
            if cpha:
                dut.MISO.value = (response >> response_bit) & 1
            else:
                received_bits.append(int(dut.MOSI.value))
        else:
            if cpha:
                received_bits.append(int(dut.MOSI.value))
            elif response_bit > 0:
                response_bit -= 1
                dut.MISO.value = (response >> response_bit) & 1

        if cpha and not leading_edge and response_bit > 0:
            response_bit -= 1

    received = 0
    for bit in received_bits:
        received = (received << 1) | bit
    return received


async def setup_dut(dut):
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, "ns").start())

    dut.prescale.value = 2
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.cmd_bits.value = DATA_WIDTH
    dut.cmd_data.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_cs_autofree.value = 1
    dut.rsp_ready.value = 0
    dut.MISO.value = 0

    dut.reset.value = 1
    await ClockCycles(dut.clock, 2)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 2)


async def configure_mode(dut, cpol, cpha, prescale=2):
    dut.cpol.value = cpol
    dut.cpha.value = cpha
    dut.prescale.value = prescale
    await RisingEdge(dut.clock)
    await FallingEdge(dut.clock)
    assert int(dut.SCK.value) == cpol, "空闲 SCK 未匹配 CPOL"
    assert int(dut.SS.value) == 1, "空闲时 SS 应为高电平"


async def send_word(dut, value, autofree):
    await FallingEdge(dut.clock)
    dut.cmd_data.value = value
    dut.cmd_cs_autofree.value = autofree
    dut.cmd_valid.value = 1

    while True:
        await Timer(1, "ps")
        if int(dut.cmd_ready.value):
            await RisingEdge(dut.clock)
            break
        await FallingEdge(dut.clock)

    await FallingEdge(dut.clock)
    dut.cmd_valid.value = 0


async def receive_word(dut):
    while not int(dut.rsp_valid.value):
        await FallingEdge(dut.clock)

    value = int(dut.rsp_data.value)
    dut.rsp_ready.value = 1
    await RisingEdge(dut.clock)
    await FallingEdge(dut.clock)
    dut.rsp_ready.value = 0
    return value


async def monitor_frame(dut):
    previous_sck = int(dut.SCK.value)
    active = False
    edge_cycles = []
    cycle = 0

    while cycle < 1000:
        await FallingEdge(dut.clock)
        cycle += 1
        sck = int(dut.SCK.value)
        ss = int(dut.SS.value)

        if ss == 0:
            active = True
        if sck != previous_sck:
            if active:
                edge_cycles.append(cycle)
            previous_sck = sck
        if active and ss == 1:
            return edge_cycles

    raise AssertionError("等待 SPI 帧结束超时")


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_all_spi_modes_and_frame_boundaries(dut):
    """Transfer a multi-word frame in each mode and check SS/tlast behavior."""
    await setup_dut(dut)
    payload = [0xA5A55A5A & DATA_MASK, 0x3CC33CC3 & DATA_MASK, 0x81E71827 & DATA_MASK]
    responses = [0x5AA5A55A & DATA_MASK, 0xC33CC33C & DATA_MASK, 0x7E7E817E & DATA_MASK]

    for mode in range(4):
        cpol = (mode >> 1) & 1
        cpha = mode & 1
        await configure_mode(dut, cpol, cpha, prescale=2)
        monitor = cocotb.start_soon(monitor_frame(dut))

        received = []
        for index, (value, response) in enumerate(zip(payload, responses)):
            autofree = index == len(payload) - 1
            slave = cocotb.start_soon(slave_exchange(
                dut, response, DATA_WIDTH, cpol, cpha
            ))
            await Timer(1, "ps")
            await send_word(dut, value, autofree)
            if not autofree:
                assert int(dut.SS.value) == 0, "非末字节后 SS 被提前释放"
                assert int(dut.SCK.value) == cpol, "字节间停顿时 SCK 未回到空闲电平"
            rx_value = await receive_word(dut)
            slave_received = await slave
            assert slave_received == value, (
                f"SPI mode {mode} MOSI 数据错误: "
                f"expected=0x{value:02x}, actual=0x{slave_received:02x}"
            )
            received.append(rx_value)

        edge_cycles = await monitor
        assert received == responses, (
            f"SPI mode {mode} MISO 数据错误: expected={responses}, actual={received}"
        )
        assert len(edge_cycles) == 2 * DATA_WIDTH * len(payload), (
            f"SPI mode {mode} SCK 边沿数错误: {len(edge_cycles)}"
        )
        assert int(dut.SS.value) == 1
        assert int(dut.SCK.value) == cpol


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_receive_backpressure(dut):
    """Keep RX blocked and verify that data and bus outputs remain stable."""
    await setup_dut(dut)
    await configure_mode(dut, cpol=0, cpha=0, prescale=2)

    response = 0x4B4B4B4B & DATA_MASK
    payload = 0xD6D6D6D6 & DATA_MASK
    slave = cocotb.start_soon(
        slave_exchange(dut, response, DATA_WIDTH, cpol=0, cpha=0)
    )
    await Timer(1, "ps")
    await send_word(dut, payload, True)
    while not int(dut.rsp_valid.value):
        await FallingEdge(dut.clock)

    assert int(dut.rsp_data.value) == response
    assert int(dut.cmd_ready.value) == 0, "RX 堵塞时不应接受新的发送数据"
    held_sck = int(dut.SCK.value)

    await ClockCycles(dut.clock, 12)
    assert int(dut.rsp_valid.value) == 1
    assert int(dut.rsp_data.value) == response
    assert int(dut.SCK.value) == held_sck
    assert int(dut.SS.value) == 1
    assert await slave == payload

    dut.rsp_ready.value = 1
    await RisingEdge(dut.clock)
    await FallingEdge(dut.clock)
    dut.rsp_ready.value = 0
    assert int(dut.rsp_valid.value) == 0
    assert int(dut.cmd_ready.value) == 1


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_prescale_edge_intervals(dut):
    """Check SCK half-period timing, including the defined prescale=0 case."""
    await setup_dut(dut)

    for prescale in (0, 1, 4):
        effective_prescale = max(1, prescale)
        await configure_mode(dut, cpol=1, cpha=1, prescale=prescale)
        monitor = cocotb.start_soon(monitor_frame(dut))
        slave = cocotb.start_soon(
            slave_exchange(dut, 0x96969696 & DATA_MASK, DATA_WIDTH, cpol=1, cpha=1)
        )
        await Timer(1, "ps")
        await send_word(dut, 0x69696969 & DATA_MASK, True)
        received = await receive_word(dut)
        edge_cycles = await monitor

        assert received == (0x96969696 & DATA_MASK)
        assert await slave == (0x69696969 & DATA_MASK)
        assert len(edge_cycles) == 2 * DATA_WIDTH
        intervals = [b - a for a, b in zip(edge_cycles, edge_cycles[1:])]
        assert intervals == [effective_prescale] * (2 * DATA_WIDTH - 1), (
            f"prescale={prescale} 的 SCK 间隔错误: {intervals}"
        )


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_configurable_transfer_lengths(dut):
    """Check transfers shorter than DATA_WIDTH and the zero-length fallback."""
    await setup_dut(dut)
    lengths = sorted(set((1, min(8, DATA_WIDTH), DATA_WIDTH)))

    for length in lengths:
        dut.cmd_bits.value = length
        payload = (0xA5A55A5A ^ length) & ((1 << length) - 1)
        response = (0x5A5AC33C ^ (length << 1)) & ((1 << length) - 1)
        slave = cocotb.start_soon(slave_exchange(dut, response, length, 0, 0))
        await Timer(1, "ps")
        await send_word(dut, payload, True)
        received = await receive_word(dut)
        assert received == response, (
            f"length={length} MISO 数据错误: expected=0x{response:x}, actual=0x{received:x}"
        )
        assert await slave == payload

    dut.cmd_bits.value = 0
    response = 0x12345678 & DATA_MASK
    slave = cocotb.start_soon(slave_exchange(dut, response, DATA_WIDTH, 0, 0))
    await Timer(1, "ps")
    await send_word(dut, 0x87654321 & DATA_MASK, True)
    received = await receive_word(dut)
    assert received == response
    assert await slave == (0x87654321 & DATA_MASK)


def run_tests():
    sim = os.getenv("SIM", "verilator")
    test_dir = Path(__file__).resolve().parent
    build_dir = Path("/tmp") / "mnpu-soc" / "spi_master"
    source = test_dir.parent / "rtl" / "spi_master.v"
    widths = (8, 16, 32) if "PARAM_DATA_WIDTH" not in os.environ else (DATA_WIDTH,)
    total_count = 0
    for width in widths:
        width_build_dir = build_dir / f"data_width-{width}"
        runner = get_runner(sim)
        runner.build(
            sources=[source],
            hdl_toplevel="spi_master",
            parameters={"DATA_WIDTH": width},
            build_dir=width_build_dir,
            always=True,
            waves=True,
            build_args=["--timing", "-Wno-SYMRSVDWORD"],
        )
        results_file = runner.test(
            hdl_toplevel="spi_master",
            test_module=Path(__file__).stem,
            parameters={"DATA_WIDTH": width},
            build_dir=width_build_dir,
            extra_env={"PARAM_DATA_WIDTH": str(width)},
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(width_build_dir / "spi_master.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        total_count += test_count
        if failed_count:
            raise RuntimeError(
                f"DATA_WIDTH={width}: {failed_count} of {test_count} SPI tests failed"
            )

    print(f"All {total_count} spi_master tests passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_tests())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"spi_master test failed: {error}", file=sys.stderr)
        sys.exit(1)

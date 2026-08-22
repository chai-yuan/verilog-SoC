import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


CLOCK_PERIOD_NS = 10
SPI_DATA_WIDTH = int(os.getenv("PARAM_SPI_DATA_WIDTH", "32"))
SPI_MASK = (1 << SPI_DATA_WIDTH) - 1

CONFIG_ADDR = 0x00
PRESCALE_ADDR = 0x04
DATA_ADDR = 0x08
SS_ADDR = 0x0C


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clock)
        await Timer(1, "ns")


async def setup_dut(dut):
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, "ns").start())

    dut.s_valid.value = 0
    dut.s_addr.value = 0
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0
    dut.MISO.value = 0

    dut.reset.value = 1
    await wait_cycles(dut, 2)
    dut.reset.value = 0
    await wait_cycles(dut, 2)


async def bus_write(dut, address, value, strobe=0xF):
    dut.s_addr.value = address
    dut.s_write.value = 1
    dut.s_wdata.value = value
    dut.s_wstrb.value = strobe
    dut.s_valid.value = 1
    await Timer(1, "ns")
    assert int(dut.s_ready.value) == 1
    assert int(dut.s_error.value) == 0
    await RisingEdge(dut.clock)
    await Timer(1, "ns")
    dut.s_valid.value = 0
    dut.s_write.value = 0
    dut.s_wstrb.value = 0


async def bus_read(dut, address, expect_error=False):
    dut.s_addr.value = address
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0
    dut.s_valid.value = 1
    await Timer(1, "ns")
    assert int(dut.s_ready.value) == 1
    assert int(dut.s_error.value) == int(expect_error)
    value = int(dut.s_rdata.value)
    await RisingEdge(dut.clock)
    await Timer(1, "ns")
    dut.s_valid.value = 0
    return value


async def slave_exchange(dut, response, length, cpol, cpha):
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


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_spi_registers_and_transfer(dut):
    await setup_dut(dut)

    assert await bus_read(dut, CONFIG_ADDR) == (SPI_DATA_WIDTH << 8)
    assert await bus_read(dut, PRESCALE_ADDR) == 1
    assert await bus_read(dut, DATA_ADDR) == 0
    assert await bus_read(dut, SS_ADDR) == 1

    # 配置 8 位、SPI mode 3，并只更新配置寄存器的低两个字节。
    length = min(8, SPI_DATA_WIDTH)
    config = (length << 8) | 0x3
    await bus_write(dut, CONFIG_ADDR, config, strobe=0x3)
    await bus_write(dut, PRESCALE_ADDR, 2, strobe=0x1)
    assert await bus_read(dut, CONFIG_ADDR) == config
    assert await bus_read(dut, PRESCALE_ADDR) == 2

    payload = 0xA5 & ((1 << length) - 1)
    response = 0x5A & ((1 << length) - 1)
    slave = cocotb.start_soon(slave_exchange(dut, response, length, 1, 1))
    await Timer(1, "ps")
    await bus_write(dut, SS_ADDR, 0, strobe=0x1)
    await bus_write(dut, DATA_ADDR, payload)

    while not int(dut.interrupt.value):
        await FallingEdge(dut.clock)
    await wait_cycles(dut, 2)

    assert await slave == payload
    assert await bus_read(dut, DATA_ADDR) == response
    await bus_write(dut, SS_ADDR, 1, strobe=0x1)
    assert int(dut.SS.value) == 1
    assert int(dut.interrupt.value) == 0


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_data_write_byte_strobe_and_unmapped_error(dut):
    await setup_dut(dut)
    await bus_write(dut, DATA_ADDR, 0xDEADBEEF, strobe=0)
    assert await bus_read(dut, DATA_ADDR) == 0

    dut.s_addr.value = 0x10
    dut.s_write.value = 0
    dut.s_valid.value = 1
    await Timer(1, "ns")
    assert int(dut.s_error.value) == 1
    dut.s_valid.value = 0


def run_tests():
    sim = os.getenv("SIM", "verilator")
    test_dir = Path(__file__).resolve().parent
    build_dir = Path("/tmp") / "verilog-SoC" / "spi_reg_top"
    sources = [
        test_dir.parent / "rtl" / "spi_master.v",
        test_dir.parent / "rtl" / "spi_reg_top.v",
    ]
    parameters = {
        "ADDR_WIDTH": 32,
        "DATA_WIDTH": 32,
        "SPI_DATA_WIDTH": SPI_DATA_WIDTH,
    }
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel="spi_reg_top",
        parameters=parameters,
        build_dir=build_dir,
        always=True,
        waves=True,
        build_args=["--timing", "-Wno-SYMRSVDWORD", "-Wno-PINCONNECTEMPTY"],
    )
    results_file = runner.test(
        hdl_toplevel="spi_reg_top",
        test_module=Path(__file__).stem,
        parameters=parameters,
        build_dir=build_dir,
        extra_env={"PARAM_SPI_DATA_WIDTH": str(SPI_DATA_WIDTH)},
        results_xml="results.xml",
        waves=True,
        test_args=["--trace-file", str(build_dir / "spi_reg_top.vcd")],
    )
    test_count, failed_count = get_results(results_file)
    if failed_count:
        raise RuntimeError(f"{failed_count} of {test_count} SPI register tests failed")

    print(f"All {test_count} spi_reg_top tests passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_tests())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"spi_reg_top test failed: {error}", file=sys.stderr)
        sys.exit(1)

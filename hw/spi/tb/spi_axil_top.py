import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import AxiLiteBus, AxiLiteMaster, AxiResp


CLOCK_PERIOD_NS = 10
SPI_DATA_WIDTH = int(os.getenv("PARAM_SPI_DATA_WIDTH", "32"))

CONFIG_ADDR = 0x00
PRESCALE_ADDR = 0x04
DATA_ADDR = 0x08
SS_ADDR = 0x0C


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clock)
        await Timer(1, "ns")


async def setup_dut(dut):
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())
    dut.MISO.value = 0
    dut.reset.value = 1
    await wait_cycles(dut, 2)
    dut.reset.value = 0
    await wait_cycles(dut, 4)
    return AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axi"), dut.clock, dut.reset)


async def axil_write(master, address, value, length=4):
    await master.write(address, value.to_bytes(length, byteorder="little"))


async def axil_read(master, address, length=4):
    response = await master.read(address, length)
    assert response.resp == AxiResp.OKAY
    return int.from_bytes(response.data, byteorder="little")


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


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_spi_axil_registers_and_transfer(dut):
    master = await setup_dut(dut)

    assert await axil_read(master, CONFIG_ADDR) == SPI_DATA_WIDTH << 8
    assert await axil_read(master, PRESCALE_ADDR) == 1
    assert await axil_read(master, DATA_ADDR) == 0
    assert await axil_read(master, SS_ADDR) == 1

    length = min(8, SPI_DATA_WIDTH)
    config = (length << 8) | 0x3
    await axil_write(master, CONFIG_ADDR, config)
    await axil_write(master, PRESCALE_ADDR, 2, length=1)
    assert await axil_read(master, CONFIG_ADDR) == config
    assert await axil_read(master, PRESCALE_ADDR) == 2

    payload = 0xA5 & ((1 << length) - 1)
    response = 0x5A & ((1 << length) - 1)
    slave = cocotb.start_soon(slave_exchange(dut, response, length, 1, 1))
    await axil_write(master, SS_ADDR, 0, length=1)
    await axil_write(master, DATA_ADDR, payload)

    assert int(dut.SS.value) == 0
    while not int(dut.interrupt.value):
        await FallingEdge(dut.clock)
    await wait_cycles(dut, 2)

    assert await slave == payload
    assert await axil_read(master, DATA_ADDR) == response
    await axil_write(master, SS_ADDR, 1, length=1)
    assert int(dut.SS.value) == 1


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_spi_axil_unmapped_address(dut):
    master = await setup_dut(dut)
    response = await master.read(0x10, 4)
    assert response.resp == AxiResp.SLVERR


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    test_dir = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / "spi_axil_top"

    widths = (8, 32) if "PARAM_SPI_DATA_WIDTH" not in os.environ else (SPI_DATA_WIDTH,)
    for width in widths:
        parameters = {
            "ADDR_WIDTH": 32,
            "DATA_WIDTH": 32,
            "SPI_DATA_WIDTH": width,
        }
        build_dir = output_dir / f"spi_data_width-{width}"
        runner = get_runner(sim)
        runner.build(
            sources=[
                test_dir.parents[1] / "axil" / "rtl" / "axil2reg.v",
                test_dir.parent / "rtl" / "spi_master.v",
                test_dir.parent / "rtl" / "spi_reg_top.v",
                test_dir.parent / "rtl" / "spi_axil_top.v",
            ],
            hdl_toplevel="spi_axil_top",
            parameters=parameters,
            build_dir=build_dir,
            always=True,
            waves=True,
            build_args=["--timing", "-Wno-SYMRSVDWORD", "-Wno-PINCONNECTEMPTY"],
        )
        results_file = runner.test(
            hdl_toplevel="spi_axil_top",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={
                "PARAM_SPI_DATA_WIDTH": str(width),
                "PYTHONWARNINGS": "ignore::DeprecationWarning:cocotbext.axi",
            },
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "spi_axil_top.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"SPI_DATA_WIDTH={width}: {failed_count} of {test_count} AXI-Lite tests failed"
            )

    print("All spi_axil_top parameter configurations passed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"spi_axil_top test failed: {error}", file=sys.stderr)
        sys.exit(1)

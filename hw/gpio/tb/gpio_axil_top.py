import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import AxiLiteBus, AxiLiteMaster, AxiResp


CLOCK_PERIOD_NS = 10
IO_NUM = int(os.getenv("PARAM_IO_NUM", "8"))
IO_MASK = (1 << IO_NUM) - 1

INPUT_DATA_ADDR = 0x00
OUTPUT_DATA_ADDR = 0x04
DIRECTION_ADDR = 0x08
INTERRUPT_ENABLE_ADDR = 0x0C
INTERRUPT_TYPE_LOW_ADDR = 0x10
INTERRUPT_TYPE_HIGH_ADDR = 0x14
INTERRUPT_STATUS_ADDR = 0x18
INTERRUPT_CLEAR_ADDR = 0x1C


def bit_mask(width):
    return (1 << width) - 1 if width > 0 else 0


def type_low_mask(io_num):
    return bit_mask(min(io_num, 16) * 2)


def type_high_mask(io_num):
    return bit_mask(max(io_num - 16, 0) * 2)


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")


async def setup_dut(dut):
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())
    dut.gpio_i.value = 0
    master = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axi"), dut.clock, dut.reset)

    dut.reset.value = 1
    await wait_cycles(dut, 2)
    dut.reset.value = 0
    await wait_cycles(dut, 4)
    return master


async def axil_write(master, address, value, length=4):
    await master.write(address, value.to_bytes(length, byteorder="little"))


async def axil_read(master, address, length=4):
    response = await master.read(address, length)
    return int.from_bytes(response.data, byteorder="little")


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_gpio_axil_registers(dut):
    """通过 AXI-Lite 检查复位值、字节访问、地址镜像和 GPIO 数据通路。"""
    master = await setup_dut(dut)

    assert await axil_read(master, OUTPUT_DATA_ADDR) == 0
    assert await axil_read(master, DIRECTION_ADDR) == 0
    assert await axil_read(master, INTERRUPT_ENABLE_ADDR) == 0
    assert await axil_read(master, INTERRUPT_TYPE_LOW_ADDR) == type_low_mask(IO_NUM)
    assert await axil_read(master, INTERRUPT_TYPE_HIGH_ADDR) == type_high_mask(IO_NUM)
    unmapped_response = await master.read(0x20, 4)
    assert unmapped_response.resp == AxiResp.SLVERR, "未映射地址未返回 SLVERR"

    await axil_write(master, OUTPUT_DATA_ADDR, 0xD5, length=1)
    await axil_write(master, OUTPUT_DATA_ADDR + 1, 0xB2, length=1)
    assert await axil_read(master, OUTPUT_DATA_ADDR) == (0x0000B2D5 & IO_MASK)

    output_value = 0xA5A55A5A & IO_MASK
    direction = 0x0F0FF0F0 & IO_MASK
    await axil_write(master, OUTPUT_DATA_ADDR, output_value)
    await axil_write(master, DIRECTION_ADDR, direction)
    await Timer(1, unit="ns")
    assert int(dut.gpio_o.value) == output_value
    assert int(dut.gpio_oe.value) == direction
    assert await axil_read(master, OUTPUT_DATA_ADDR) == output_value

    input_value = 0x5AA53CC3 & IO_MASK
    dut.gpio_i.value = input_value
    await wait_cycles(dut, 2)
    assert await axil_read(master, INPUT_DATA_ADDR) == input_value

    await axil_write(master, INPUT_DATA_ADDR, 0xFFFF_FFFF)
    assert await axil_read(master, INPUT_DATA_ADDR) == input_value


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_gpio_axil_interrupts(dut):
    """通过 AXI-Lite 检查中断类型配置、使能、状态只读保护和清除命令。"""
    master = await setup_dut(dut)

    await axil_write(master, INTERRUPT_TYPE_LOW_ADDR, 0xFFFF_FFFF)
    await axil_write(master, INTERRUPT_TYPE_HIGH_ADDR, 0xFFFF_FFFF)
    await axil_write(master, INTERRUPT_CLEAR_ADDR, 1)
    await axil_write(master, INTERRUPT_ENABLE_ADDR, 1)

    dut.gpio_i.value = 1
    await wait_cycles(dut, 3)
    assert await axil_read(master, INTERRUPT_STATUS_ADDR) == 1
    assert int(dut.interrupt.value) == 1

    await axil_write(master, INTERRUPT_STATUS_ADDR, 0)
    assert await axil_read(master, INTERRUPT_STATUS_ADDR) == 1, "只读状态被写操作修改"

    await axil_write(master, INTERRUPT_CLEAR_ADDR, 0)
    assert await axil_read(master, INTERRUPT_STATUS_ADDR) == 1, "写零错误地清除了状态"

    await axil_write(master, INTERRUPT_CLEAR_ADDR, 1)
    assert await axil_read(master, INTERRUPT_STATUS_ADDR) == 0
    assert int(dut.interrupt.value) == 0


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem

    for io_num in (1, 16, 32):
        parameters = {"IO_NUM": io_num, "ADDR_WIDTH": 32, "DATA_WIDTH": 32}
        build_dir = output_dir / f"io_num-{io_num}"
        runner = get_runner(sim)
        runner.build(
            sources=[
                proj_path.parents[1] / "axil" / "rtl" / "axil2reg.v",
                proj_path.parent / "rtl" / "gpio.v",
                proj_path.parent / "rtl" / "gpio_reg_top.v",
                proj_path.parent / "rtl" / "gpio_axil_top.v",
            ],
            hdl_toplevel="gpio_axil_top",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=["--timing", "-Wno-SYMRSVDWORD"],
        )
        results_file = runner.test(
            hdl_toplevel="gpio_axil_top",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={
                "PARAM_IO_NUM": str(io_num),
                "PYTHONWARNINGS": "ignore::DeprecationWarning:cocotbext.axi",
            },
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "gpio_axil_top.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"IO_NUM={io_num}：{test_count} 个测试中有 {failed_count} 个失败"
            )

    print("所有 gpio_axil_top 参数配置均已通过测试。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"gpio_axil_top 测试失败：{error}", file=sys.stderr)
        sys.exit(1)

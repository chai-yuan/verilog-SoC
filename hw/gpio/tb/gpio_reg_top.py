import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


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

    dut.s_valid.value = 0
    dut.s_addr.value = 0
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0
    dut.gpio_i.value = 0

    dut.reset.value = 1
    await wait_cycles(dut, 2)
    dut.reset.value = 0
    await wait_cycles(dut, 4)


async def bus_write(dut, address, data, strobe=0xF, expect_error=False):
    dut.s_addr.value = address
    dut.s_write.value = 1
    dut.s_wdata.value = data
    dut.s_wstrb.value = strobe
    dut.s_valid.value = 1

    await Timer(1, unit="ns")
    assert int(dut.s_ready.value) == 1, "简单总线写事务未被立即接收"
    expected_error = 1 if expect_error else 0
    assert int(dut.s_error.value) == expected_error, (
        f"简单总线写事务错误响应不匹配：期望 {expected_error}，实际 {int(dut.s_error.value)}"
    )
    await wait_cycles(dut, 1)

    dut.s_valid.value = 0
    dut.s_write.value = 0
    dut.s_wstrb.value = 0


async def bus_read(dut, address, expect_error=False):
    dut.s_addr.value = address
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0
    dut.s_valid.value = 1

    await Timer(1, unit="ns")
    assert int(dut.s_ready.value) == 1, "简单总线读事务未被立即接收"
    expected_error = 1 if expect_error else 0
    assert int(dut.s_error.value) == expected_error, (
        f"简单总线读事务错误响应不匹配：期望 {expected_error}，实际 {int(dut.s_error.value)}"
    )
    value = int(dut.s_rdata.value)
    await wait_cycles(dut, 1)
    dut.s_valid.value = 0
    return value


@cocotb.test(timeout_time=30, timeout_unit="us")
async def test_gpio_reg_registers(dut):
    """检查复位值、寄存器读写、字节选通和地址镜像。"""
    await setup_dut(dut)

    assert await bus_read(dut, OUTPUT_DATA_ADDR) == 0
    assert await bus_read(dut, DIRECTION_ADDR) == 0
    assert await bus_read(dut, INTERRUPT_ENABLE_ADDR) == 0
    assert await bus_read(dut, INTERRUPT_TYPE_LOW_ADDR) == type_low_mask(IO_NUM)
    assert await bus_read(dut, INTERRUPT_TYPE_HIGH_ADDR) == type_high_mask(IO_NUM)
    assert await bus_read(dut, INTERRUPT_CLEAR_ADDR) == 0
    assert await bus_read(dut, 0x20, expect_error=True) == 0

    await bus_write(dut, OUTPUT_DATA_ADDR, 0xA1B2C3D4, strobe=0b0101)
    expected_output = 0x00B200D4 & IO_MASK
    assert await bus_read(dut, OUTPUT_DATA_ADDR) == expected_output

    output_value = 0xA5A55A5A & IO_MASK
    direction = 0x0F0FF0F0 & IO_MASK
    await bus_write(dut, OUTPUT_DATA_ADDR, output_value)
    await bus_write(dut, DIRECTION_ADDR, direction)
    await Timer(1, unit="ns")
    assert int(dut.gpio_o.value) == output_value
    assert int(dut.gpio_oe.value) == direction
    assert await bus_read(dut, OUTPUT_DATA_ADDR) == output_value

    await bus_write(dut, INTERRUPT_TYPE_LOW_ADDR, 0, strobe=0x1)
    assert await bus_read(dut, INTERRUPT_TYPE_LOW_ADDR) == (type_low_mask(IO_NUM) & ~0xFF)
    await bus_write(dut, INTERRUPT_TYPE_LOW_ADDR, 0xFFFF_FFFF)
    await bus_write(dut, INTERRUPT_TYPE_HIGH_ADDR, 0xFFFF_FFFF)

    input_value = 0x5AA5C33C & IO_MASK
    dut.gpio_i.value = input_value
    await wait_cycles(dut, 2)
    assert await bus_read(dut, INPUT_DATA_ADDR) == input_value

    await bus_write(dut, INPUT_DATA_ADDR, 0xFFFF_FFFF)
    assert await bus_read(dut, INPUT_DATA_ADDR) == input_value


@cocotb.test(timeout_time=30, timeout_unit="us")
async def test_gpio_reg_interrupts(dut):
    """检查中断使能、原始状态、只读保护和全局清除命令。"""
    await setup_dut(dut)

    await bus_write(dut, INTERRUPT_TYPE_LOW_ADDR, 0xFFFF_FFFF)
    await bus_write(dut, INTERRUPT_TYPE_HIGH_ADDR, 0xFFFF_FFFF)
    await bus_write(dut, INTERRUPT_CLEAR_ADDR, 1)
    await bus_write(dut, INTERRUPT_ENABLE_ADDR, 1)

    dut.gpio_i.value = 1
    await wait_cycles(dut, 3)
    assert await bus_read(dut, INTERRUPT_STATUS_ADDR) == 1
    assert int(dut.interrupt.value) == 1

    await bus_write(dut, INTERRUPT_STATUS_ADDR, 0)
    assert await bus_read(dut, INTERRUPT_STATUS_ADDR) == 1, "只读状态被写操作修改"

    await bus_write(dut, INTERRUPT_CLEAR_ADDR, 1, strobe=0)
    assert await bus_read(dut, INTERRUPT_STATUS_ADDR) == 1, "未选通字节时错误地清除了状态"

    await bus_write(dut, INTERRUPT_CLEAR_ADDR, 0, strobe=1)
    assert await bus_read(dut, INTERRUPT_STATUS_ADDR) == 1, "写零错误地清除了状态"

    await bus_write(dut, INTERRUPT_CLEAR_ADDR, 1, strobe=1)
    assert await bus_read(dut, INTERRUPT_STATUS_ADDR) == 0
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
                proj_path.parent / "rtl" / "gpio.v",
                proj_path.parent / "rtl" / "gpio_reg_top.v",
            ],
            hdl_toplevel="gpio_reg_top",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=["--timing", "-Wno-SYMRSVDWORD"],
        )
        results_file = runner.test(
            hdl_toplevel="gpio_reg_top",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={"PARAM_IO_NUM": str(io_num)},
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "gpio_reg_top.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"IO_NUM={io_num}：{test_count} 个测试中有 {failed_count} 个失败"
            )

    print("所有 gpio_reg_top 参数配置均已通过测试。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"gpio_reg_top 测试失败：{error}", file=sys.stderr)
        sys.exit(1)

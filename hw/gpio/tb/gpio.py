import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner


CLOCK_PERIOD_NS = 10
IO_NUM = int(os.getenv("PARAM_IO_NUM", "4"))
IO_MASK = (1 << IO_NUM) - 1

INTERRUPT_LOW_LEVEL = 0b00
INTERRUPT_HIGH_LEVEL = 0b01
INTERRUPT_FALLING_EDGE = 0b10
INTERRUPT_RISING_EDGE = 0b11


def encode_interrupt_types(types):
    value = 0
    for index, interrupt_type in enumerate(types):
        if not 0 <= interrupt_type <= 0b11:
            raise ValueError(
                f"interrupt_type[{index}]={interrupt_type} 超出 2-bit 范围"
            )
        value |= interrupt_type << (index * 2)
    return value


async def wait_cycles(dut, count):
    for _ in range(count):
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")


async def setup_dut(dut, gpio_value=0, interrupt_types=None):
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())

    if interrupt_types is None:
        interrupt_types = [INTERRUPT_RISING_EDGE] * IO_NUM

    dut.direction.value = 0
    dut.output_data.value = 0
    dut.interrupt_enable.value = 0
    dut.interrupt_type.value = encode_interrupt_types(interrupt_types)
    dut.interrupt_clear.value = 0
    dut.gpio_i.value = gpio_value & IO_MASK

    dut.reset.value = 1
    await wait_cycles(dut, 2)
    dut.reset.value = 0
    await wait_cycles(dut, 4)


@cocotb.test(timeout_time=20, timeout_unit="us")
async def test_gpio_data_path_and_synchronizer(dut):
    """检查输出控制、两级输入同步和复位后的启动行为。"""
    await setup_dut(dut, gpio_value=IO_MASK)

    assert int(dut.interrupt_status.value) == 0, (
        "复位后的静态高电平输入错误地产生了上升沿中断"
    )
    assert int(dut.gpio_oe.value) == 0

    output_value = 0xC3 & IO_MASK
    direction = 0xA5 & IO_MASK
    dut.output_data.value = output_value
    dut.direction.value = direction
    await Timer(1, unit="ns")

    assert int(dut.gpio_o.value) == output_value
    assert int(dut.gpio_oe.value) == direction

    input_value = 0x5A & IO_MASK
    dut.gpio_i.value = input_value
    await wait_cycles(dut, 1)
    assert int(dut.input_data.value) == IO_MASK, "输入数据未经过完整的两级同步"
    await wait_cycles(dut, 1)
    assert int(dut.input_data.value) == input_value

    dut.reset.value = 1
    await Timer(1, unit="ns")
    assert int(dut.gpio_oe.value) == 0, "复位未关闭引脚输出驱动"
    assert int(dut.interrupt.value) == 0, "复位未关闭中断输出"


@cocotb.test(timeout_time=30, timeout_unit="us")
async def test_gpio_interrupt_modes_and_masks(dut):
    """检查全部触发类型、状态锁存、清除优先级和中断屏蔽，支持任意 IO_NUM。"""
    base_types = [
        INTERRUPT_LOW_LEVEL,
        INTERRUPT_HIGH_LEVEL,
        INTERRUPT_FALLING_EDGE,
        INTERRUPT_RISING_EDGE,
    ]
    pin_types = [base_types[index % 4] for index in range(IO_NUM)]

    level_mask = 0
    edge_mask = 0
    initial_value = 0
    for index, pin_type in enumerate(pin_types):
        if pin_type == INTERRUPT_LOW_LEVEL:
            level_mask |= 1 << index
        elif pin_type == INTERRUPT_HIGH_LEVEL:
            level_mask |= 1 << index
            initial_value |= 1 << index
        elif pin_type == INTERRUPT_FALLING_EDGE:
            edge_mask |= 1 << index
            initial_value |= 1 << index
        elif pin_type == INTERRUPT_RISING_EDGE:
            edge_mask |= 1 << index

    await setup_dut(dut, gpio_value=initial_value, interrupt_types=pin_types)

    assert (int(dut.interrupt_status.value) & IO_MASK) == level_mask, (
        "中断被屏蔽时未能记录原始电平中断状态"
    )
    assert int(dut.interrupt.value) == 0

    if level_mask:
        dut.interrupt_enable.value = level_mask
        await Timer(1, unit="ns")
        assert int(dut.interrupt.value) == 1

        dut.interrupt_clear.value = 1
        await wait_cycles(dut, 1)
        dut.interrupt_clear.value = 0
        assert (int(dut.interrupt_status.value) & IO_MASK) == level_mask, (
            "清除操作错误地覆盖了仍然有效的电平中断条件"
        )

    if edge_mask:
        dut.interrupt_enable.value = edge_mask
        await Timer(1, unit="ns")
        assert int(dut.interrupt.value) == 0, "被屏蔽的状态错误地拉高了中断输出"

        edge_value = 0
        for index, pin_type in enumerate(pin_types):
            if pin_type in (INTERRUPT_LOW_LEVEL, INTERRUPT_RISING_EDGE):
                edge_value |= 1 << index
        edge_value &= IO_MASK

        dut.gpio_i.value = edge_value
        await wait_cycles(dut, 2)
        dut.interrupt_clear.value = 1
        await wait_cycles(dut, 1)
        dut.interrupt_clear.value = 0
        await wait_cycles(dut, 1)

        assert (int(dut.interrupt_status.value) & IO_MASK) == edge_mask, (
            "边沿中断未被正确锁存，或清除操作误删了有效边沿"
        )
        assert int(dut.interrupt.value) == 1

        dut.interrupt_clear.value = 1
        await wait_cycles(dut, 1)
        dut.interrupt_clear.value = 0
        await wait_cycles(dut, 1)

        assert int(dut.interrupt_status.value) == 0
        assert int(dut.interrupt.value) == 0


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem

    for io_num in (1, 4, 16, 32):
        parameters = {"IO_NUM": io_num}
        build_dir = output_dir / f"io_num-{io_num}"
        runner = get_runner(sim)
        runner.build(
            sources=[proj_path.parent / "rtl" / "gpio.v"],
            hdl_toplevel="gpio",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=["--timing", "-Wno-SYMRSVDWORD"],
        )
        results_file = runner.test(
            hdl_toplevel="gpio",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env={"PARAM_IO_NUM": str(io_num)},
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "gpio.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"IO_NUM={io_num}：{test_count} 个 cocotb 测试中有 {failed_count} 个失败"
            )

    print("所有 gpio 参数配置均已通过测试。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"gpio 测试失败：{error}", file=sys.stderr)
        sys.exit(1)

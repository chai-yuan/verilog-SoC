import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.uart import UartSink, UartSource


CLOCK_FREQ = 10_000_000
CLOCK_PERIOD_NS = int(1_000_000_000 / CLOCK_FREQ)
BAUD_RATE = 115200
PRESCALE = CLOCK_FREQ // BAUD_RATE
DATA_WIDTH = int(os.getenv("PARAM_DATA_WIDTH", "32"))
DATA_MASK = (1 << DATA_WIDTH) - 1

RX_FIFO_ADDR = 0x00
TX_FIFO_ADDR = 0x04
STATUS_ADDR = 0x08
CTRL_ADDR = 0x0C


async def setup_dut(dut):
    """启动时钟、初始化总线并复位整个 UART。"""
    cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, "ns").start())

    dut.rx.value = 1
    dut.s_valid.value = 0
    dut.s_addr.value = 0
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0

    dut.reset.value = 1
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut.reset.value = 0
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)


async def bus_write(dut, address, data, strobe=0x1):
    dut.s_addr.value = address
    dut.s_write.value = 1
    dut.s_wdata.value = data & DATA_MASK
    dut.s_wstrb.value = strobe
    dut.s_valid.value = 1

    await Timer(1, "ns")
    assert dut.s_ready.value == 1, "总线写请求未被立即响应"
    assert dut.s_error.value == 0, "总线写请求意外返回错误"
    await RisingEdge(dut.clock)
    dut.s_valid.value = 0
    dut.s_write.value = 0
    dut.s_wstrb.value = 0


async def bus_read(dut, address):
    dut.s_addr.value = address
    dut.s_write.value = 0
    dut.s_wdata.value = 0
    dut.s_wstrb.value = 0
    dut.s_valid.value = 1

    await Timer(1, "ns")
    assert dut.s_ready.value == 1, "总线读请求未被立即响应"
    assert dut.s_error.value == 0, "总线读请求意外返回错误"
    value = int(dut.s_rdata.value)
    await RisingEdge(dut.clock)
    dut.s_valid.value = 0
    return value


async def wait_for_status(dut, mask, expected, timeout_cycles=20_000):
    for _ in range(timeout_cycles):
        status = await bus_read(dut, STATUS_ADDR)
        if status & mask == expected:
            return status
    raise AssertionError(
        f"等待状态超时: mask=0x{mask:02x}, expected=0x{expected:02x}"
    )


async def configure_uart(dut, interrupt_enable=False):
    # Prescale 占用字节 2 和 3，不应依赖字节 0 是否被使能。
    await bus_write(dut, CTRL_ADDR, PRESCALE << 16, strobe=0xC)
    await bus_write(
        dut,
        CTRL_ADDR,
        0x10 if interrupt_enable else 0,
        strobe=0x1,
    )


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def test_uart_top_registers_and_strobes(dut):
    """检查复位状态、字节选通、状态寄存器和中断控制。"""
    await setup_dut(dut)

    status = await bus_read(dut, STATUS_ADDR)
    assert status & 0xFF == 0x04, f"复位状态错误: 0x{status:02x}"
    assert status >> 8 == 0, "读数据高位未清零"
    assert dut.interrupt.value == 0

    await configure_uart(dut, interrupt_enable=True)
    status = await bus_read(dut, STATUS_ADDR)
    assert status & 0x10, "中断使能状态位未置位"
    assert dut.interrupt.value == 1, "TX FIFO 空时未产生已使能的中断"

    await bus_write(dut, CTRL_ADDR, 0, strobe=0x1)
    await Timer(1, "ns")
    assert dut.interrupt.value == 0, "关闭中断后 interrupt 未清零"

    # 未选通字节 0 时不应把数据写入 TX FIFO。
    await bus_write(dut, TX_FIFO_ADDR, 0x5A, strobe=0x0)
    await bus_write(dut, TX_FIFO_ADDR, 0xA5, strobe=0x2)
    for _ in range(5):
        await RisingEdge(dut.clock)
    status = await bus_read(dut, STATUS_ADDR)
    assert status & 0x04, "未选通低字节的写操作错误地写入了 TX FIFO"
    assert dut.tx.value == 1, "无有效 TX 写操作时串口输出不为空闲电平"

    assert await bus_read(dut, 0x10) == 0, "未映射地址应返回零"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_uart_top_transmit(dut):
    """通过总线写入数据并观察串行 UART 输出。"""
    await setup_dut(dut)
    await configure_uart(dut)
    uart_sink = UartSink(dut.tx, baud=BAUD_RATE, bits=8)

    expected = b"Top TX"
    for byte in expected:
        await bus_write(dut, TX_FIFO_ADDR, byte)

    received = b""
    while len(received) < len(expected):
        received += await uart_sink.read()

    assert received == expected, f"发送数据错误: expected={expected!r}, actual={received!r}"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def test_uart_top_receive_status_and_reset(dut):
    """通过 UART 接收、总线读取，并检查中断与 FIFO 复位。"""
    await setup_dut(dut)
    await configure_uart(dut, interrupt_enable=True)
    uart_source = UartSource(dut.rx, baud=BAUD_RATE, bits=8)

    expected = b"Top RX"
    await uart_source.write(expected)

    received = bytearray()
    for _ in expected:
        status = await wait_for_status(dut, 0x01, 0x01)
        assert status & 0x10, "接收期间中断使能状态丢失"
        assert dut.interrupt.value == 1, "RX FIFO 有数据时未产生中断"
        value = await bus_read(dut, RX_FIFO_ADDR)
        assert value >> 8 == 0, "RX 寄存器读数据高位未清零"
        received.append(value & 0xFF)

    assert bytes(received) == expected, (
        f"接收数据错误: expected={expected!r}, actual={bytes(received)!r}"
    )
    await wait_for_status(dut, 0x01, 0x00)

    await uart_source.write(b"R")
    await wait_for_status(dut, 0x01, 0x01)
    await bus_write(dut, CTRL_ADDR, 0x02, strobe=0x1)
    await RisingEdge(dut.clock)
    status = await bus_read(dut, STATUS_ADDR)
    assert status & 0x01 == 0, "RX FIFO 软件复位后仍报告有数据"


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    output_dir = Path("/tmp") / "verilog-SoC" / Path(__file__).stem
    configurations = (
        {"ADDR_WIDTH": 32, "DATA_WIDTH": 32},
        {"ADDR_WIDTH": 40, "DATA_WIDTH": 64},
    )
    sources = [
        proj_path.parents[1] / "axis" / "rtl" / "axis_fifo.v",
        proj_path.parent / "rtl" / "uart_rx.v",
        proj_path.parent / "rtl" / "uart_tx.v",
        proj_path.parent / "rtl" / "uart_reg_top.v",
    ]

    for parameters in configurations:
        name = "_".join(f"{key.lower()}-{value}" for key, value in parameters.items())
        build_dir = output_dir / name
        extra_env = {
            f"PARAM_{key}": str(value) for key, value in parameters.items()
        }
        runner = get_runner(sim)
        runner.build(
            sources=sources,
            hdl_toplevel="uart_reg_top",
            parameters=parameters,
            build_dir=build_dir,
            always=False,
            waves=True,
            build_args=[
                "--timing",
                "-Wno-PINMISSING",
                "-Wno-SELRANGE",
                "-Wno-SYMRSVDWORD",
            ],
        )
        results_file = runner.test(
            hdl_toplevel="uart_reg_top",
            test_module=Path(__file__).stem,
            parameters=parameters,
            build_dir=build_dir,
            extra_env=extra_env,
            results_xml="results.xml",
            waves=True,
            test_args=["--trace-file", str(build_dir / "uart_reg_top.vcd")],
        )
        test_count, failed_count = get_results(results_file)
        if failed_count:
            raise RuntimeError(
                f"{name}: {failed_count} of {test_count} cocotb tests failed"
            )

    print(f"全部 {len(configurations)} 种 uart_reg_top 配置均已通过测试。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run_parameter_matrix())
    except (Exception, SystemExit) as error:
        if isinstance(error, SystemExit):
            raise
        print(f"uart_reg_top 测试失败: {error}", file=sys.stderr)
        sys.exit(1)

# uart_tx.py

import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner
from cocotbext.uart import UartSink

CLOCK_FREQ = 10_000_000
CLK_PERIOD_NS = int(1_000_000_000 / CLOCK_FREQ)
BAUD_RATES = [9600, 115200]


async def setup_dut(dut):
    """启动时钟并复位 DUT，从常用波特率中随机选择一个并配置 prescale"""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, "ns").start())

    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0

    dut.reset.value = 1
    await Timer(100, "ns")
    dut.reset.value = 0

    baud_rate = random.choice(BAUD_RATES)
    prescale_val = int(CLOCK_FREQ / baud_rate)
    dut.prescale.value = prescale_val
    dut._log.info(f"配置波特率: {baud_rate}, prescale: {prescale_val} (clock {CLOCK_FREQ/1e6:.0f} MHz)")

    return baud_rate


async def axis_send_byte(dut, data_byte):
    """通过 AXI-Stream 接口向 DUT 写入一个字节"""
    dut.s_axis_tdata.value = data_byte
    dut.s_axis_tvalid.value = 1

    while True:
        await RisingEdge(dut.clock)
        if dut.s_axis_tready.value == 1:
            break

    dut.s_axis_tvalid.value = 0


@cocotb.test(timeout_time=20000000, timeout_unit="ns")
async def test_uart_tx_basic(dut):
    """测试 UART TX 模块的基本发送功能"""
    baud_rate = await setup_dut(dut)

    uart_sink = UartSink(dut.tx, baud=baud_rate, bits=8)

    test_string = b"Hi uart!"
    dut._log.info(f"准备发送数据: {test_string}")

    for byte in test_string:
        await axis_send_byte(dut, byte)

    received_data = b""
    while len(received_data) < len(test_string):
        chunk = await uart_sink.read()
        received_data += chunk

    assert received_data == test_string, f"数据校验失败！预期 {test_string}, 实际 {received_data}"


if __name__ == "__main__":
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    test_module = Path(__file__).stem
    output_dir = Path("/tmp") / "verilog-SoC" / test_module
    build_dir = output_dir / "sim_build"
    vcd_file = output_dir / "uart_tx.vcd"

    rtl_sources = [proj_path.parent / "rtl" / "uart_tx.v"]

    runner = get_runner(sim)
    runner.build(
        sources=rtl_sources,
        hdl_toplevel="uart_tx",
        build_dir=build_dir,
        always=False,
        waves=True,
        build_args=["--timing"],
    )

    runner.test(
        hdl_toplevel="uart_tx",
        test_module=test_module,
        build_dir=build_dir,
        waves=True,
        test_args=["--trace-file", str(vcd_file)],
    )

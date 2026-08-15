# uart_rx.py

import os
import random
import subprocess
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.uart import UartSource

CLOCK_FREQ = 10_000_000
CLK_PERIOD_NS = int(1_000_000_000 / CLOCK_FREQ)
BAUD_RATES = [9600, 115200]


async def setup_dut(dut):
    """启动时钟并复位 DUT，从常用波特率中随机选择一个并配置 prescale"""
    cocotb.start_soon(Clock(dut.clock, CLK_PERIOD_NS, "ns").start())

    dut.m_axis_tready.value = 0

    dut.reset.value = 1
    await Timer(100, "ns")
    dut.reset.value = 0

    baud_rate = random.choice(BAUD_RATES)
    prescale_val = int(CLOCK_FREQ / baud_rate)
    dut.prescale.value = prescale_val
    dut._log.info(f"配置波特率: {baud_rate}, prescale: {prescale_val} (clock {CLOCK_FREQ/1e6:.0f} MHz)")

    return baud_rate, prescale_val


async def axis_recv_byte(dut):
    """通过 AXI-Stream 接口从 DUT 读取一个字节"""
    dut.m_axis_tready.value = 1

    while True:
        await RisingEdge(dut.clock)
        if dut.m_axis_tvalid.value == 1:
            break

    data_byte = int(dut.m_axis_tdata.value)
    dut.m_axis_tready.value = 0
    return data_byte


async def send_byte_bad_stop(dut, data_byte, prescale_val):
    """手动发送一个字节，但停止位为低电平，用于制造 frame error"""
    bit_time_ns = prescale_val * CLK_PERIOD_NS

    dut.rx.value = 0
    await Timer(bit_time_ns, "ns")

    for i in range(8):
        dut.rx.value = (data_byte >> i) & 1
        await Timer(bit_time_ns, "ns")

    dut.rx.value = 0
    await Timer(bit_time_ns, "ns")

    dut.rx.value = 1


async def wait_for_pulse(signal):
    """等待信号产生一个上升沿脉冲"""
    await RisingEdge(signal)
    return True


@cocotb.test(timeout_time=20000000, timeout_unit="ns")
async def test_uart_rx_basic(dut):
    """测试 UART RX 模块的基本接收功能"""
    baud_rate, _ = await setup_dut(dut)

    uart_source = UartSource(dut.rx, baud=baud_rate, bits=8)

    test_string = b"Hi uart!"
    dut._log.info(f"准备接收数据: {test_string}")

    for byte in test_string:
        await uart_source.write(byte.to_bytes(1, "little"))

    received_data = b""
    while len(received_data) < len(test_string):
        byte = await axis_recv_byte(dut)
        received_data += bytes([byte])

    assert received_data == test_string, f"数据校验失败！预期 {test_string}, 实际 {received_data}"


@cocotb.test(timeout_time=20000000, timeout_unit="ns")
async def test_uart_rx_overrun(dut):
    """测试 UART RX 模块的溢出报错功能"""
    baud_rate, _ = await setup_dut(dut)

    uart_source = UartSource(dut.rx, baud=baud_rate, bits=8)

    dut.m_axis_tready.value = 0

    dut._log.info("发送第一个字节，但不读取")
    await uart_source.write(b"\x41")

    while dut.m_axis_tvalid.value == 0:
        await RisingEdge(dut.clock)

    dut._log.info("发送第二个字节，应触发 overrun_error")
    await uart_source.write(b"\x42")

    await RisingEdge(dut.overrun_error)
    assert dut.overrun_error.value == 1, "overrun_error 未被置起"

    received = await axis_recv_byte(dut)
    assert received == 0x42, f"溢出后读取到的数据错误，预期 0x42，实际 0x{received:02x}"

    dut._log.info("overrun_error 测试通过")


@cocotb.test(timeout_time=20000000, timeout_unit="ns")
async def test_uart_rx_frame_error(dut):
    """测试 UART RX 模块的帧错误报错功能"""
    baud_rate, prescale_val = await setup_dut(dut)
    dut._log.info(f"当前手动发送使用波特率: {baud_rate}")

    frame_monitor = cocotb.start_soon(wait_for_pulse(dut.frame_error))

    dut._log.info("发送一个停止位错误的字节，应触发 frame_error")
    await send_byte_bad_stop(dut, 0x55, prescale_val)

    frame_seen = await frame_monitor
    assert frame_seen, "frame_error 未产生脉冲"

    assert dut.m_axis_tvalid.value == 0, "帧错误时不应产生 m_axis_tvalid"

    dut._log.info("frame_error 测试通过")


if __name__ == "__main__":
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    test_module = Path(__file__).stem
    output_dir = Path("/tmp") / "verilog-SoC" / test_module
    build_dir = output_dir / "sim_build"
    vcd_file = output_dir / "uart_rx.vcd"
    results_file = build_dir / "results.xml"

    rtl_sources = [proj_path.parent / "rtl" / "uart_rx.v"]

    runner = get_runner(sim)
    runner.build(
        sources=rtl_sources,
        hdl_toplevel="uart_rx",
        build_dir=build_dir,
        always=False,
        waves=True,
        build_args=["--timing"],
    )

    try:
        runner.test(
            hdl_toplevel="uart_rx",
            test_module=test_module,
            build_dir=build_dir,
            waves=True,
            results_xml="results.xml",
            test_args=["--trace-file", str(vcd_file)],
        )
    except subprocess.CalledProcessError as exc:
        # Verilator 在 $finish 后偶尔会以非零码（如 -11）退出，但测试用例本身可能已经通过。
        # 这种情况下以 results.xml 中的实际用例结果为准。
        print(f"仿真进程以非零码退出: {exc.returncode}，尝试读取 {results_file} 判断测试结果")

    if not results_file.exists():
        print(f"测试结果文件 {results_file} 不存在", file=sys.stderr)
        sys.exit(1)

    test_count, failed_count = get_results(results_file)
    if failed_count:
        print(f"uart_rx: {failed_count} of {test_count} cocotb tests failed", file=sys.stderr)
        sys.exit(1)

    print(f"uart_rx: 全部 {test_count} 个测试通过")
    sys.exit(0)

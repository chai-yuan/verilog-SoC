import itertools
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb_tools.check_results import get_results
from cocotb_tools.runner import get_runner
from cocotbext.axi import AxiStreamBus, AxiStreamFrame, AxiStreamSink, AxiStreamSource


CLOCK_PERIOD_NS = int(os.getenv("PARAM_CLOCK_PERIOD_NS", "10"))
DATA_WIDTH = int(os.getenv("PARAM_DATA_WIDTH", "32"))
DEPTH = int(os.getenv("PARAM_DEPTH", "8"))
ID_WIDTH = int(os.getenv("PARAM_ID_WIDTH", "4"))
DEST_WIDTH = int(os.getenv("PARAM_DEST_WIDTH", "4"))
USER_WIDTH = int(os.getenv("PARAM_USER_WIDTH", "2"))

PARAMETER_PRESETS = {
    "DATA_WIDTH": (8, 32),
    "DEPTH": (2, 8),
    "ID_WIDTH": (0, 1, 4),
    "DEST_WIDTH": (0, 1, 4),
    "USER_WIDTH": (0, 1, 2),
}


class TB:
    def __init__(self, dut):
        self.dut = dut

        cocotb.start_soon(Clock(dut.clock, CLOCK_PERIOD_NS, unit="ns").start())

        self.source = AxiStreamSource(
            AxiStreamBus.from_prefix(dut, "s_axis"), dut.clock, dut.reset
        )
        self.sink = AxiStreamSink(
            AxiStreamBus.from_prefix(dut, "m_axis"), dut.clock, dut.reset
        )

    async def reset(self):
        self.dut.reset.value = 1
        await RisingEdge(self.dut.clock)
        await RisingEdge(self.dut.clock)
        self.dut.reset.value = 0
        await RisingEdge(self.dut.clock)
        await RisingEdge(self.dut.clock)


def cycle_pause(pattern):
    return itertools.cycle(pattern)


async def assert_frame(sink, payload, tid, tdest, tuser):
    frame = await sink.recv()

    assert bytes(frame.tdata) == bytes(payload)
    assert frame.tid == tid
    assert frame.tdest == tdest
    assert frame.tuser == tuser


def mask(value, width):
    return value & ((1 << width) - 1)


def sideband_values(value, width):
    """返回物理端口输入值和功能使能后的期望输出值。"""
    return mask(value, max(1, width)), mask(value, width)


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_axis_fifo_basic(dut):
    """检查不同长度帧及所有 AXI-Stream sideband 信号。"""
    tb = TB(dut)
    await tb.reset()

    assert dut.status_empty.value == 1
    assert dut.status_full.value == 0

    raw_test_frames = [
        (b"\x12", 1, 2, 0),
        (bytes(range(4)), 2, 3, 1),
        (bytes(range(5)), 3, 4, 2),
        (bytes(range(32)), 4, 5, 3),
    ]
    test_frames = []
    for payload, tid, tdest, tuser in raw_test_frames:
        tx_tid, expected_tid = sideband_values(tid, ID_WIDTH)
        tx_tdest, expected_tdest = sideband_values(tdest, DEST_WIDTH)
        tx_tuser, expected_tuser = sideband_values(tuser, USER_WIDTH)
        test_frames.append(
            (
                payload,
                (tx_tid, tx_tdest, tx_tuser),
                (expected_tid, expected_tdest, expected_tuser),
            )
        )

    for payload, tx_values, _ in test_frames:
        tid, tdest, tuser = tx_values
        await tb.source.send(
            AxiStreamFrame(payload, tid=tid, tdest=tdest, tuser=tuser)
        )

    for payload, _, expected_values in test_frames:
        tid, tdest, tuser = expected_values
        await assert_frame(tb.sink, payload, tid, tdest, tuser)

    await tb.source.wait()
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)

    assert tb.sink.empty()
    assert dut.status_empty.value == 1
    assert dut.status_full.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_axis_fifo_random_backpressure(dut):
    """在输入空闲和输出背压下检查数据、TKEEP 和帧边界。"""
    tb = TB(dut)
    await tb.reset()

    tb.source.set_pause_generator(cycle_pause([0, 0, 1, 0]))
    tb.sink.set_pause_generator(cycle_pause([0, 1, 1, 0, 0]))

    rng = random.Random(0xA51F1F0)
    expected_frames = []

    for index in range(24):
        length = rng.randint(1, DATA_WIDTH // 8 * 5)
        payload = bytes(rng.randrange(256) for _ in range(length))
        tkeep = [rng.randrange(2) for _ in range(length)]
        tkeep[rng.randrange(length)] = 1
        tid, expected_tid = sideband_values(index, ID_WIDTH)
        tdest, expected_tdest = sideband_values(index * 3, DEST_WIDTH)
        tuser, expected_tuser = sideband_values(index, USER_WIDTH)

        await tb.source.send(
            AxiStreamFrame(
                payload,
                tkeep=tkeep,
                tid=tid,
                tdest=tdest,
                tuser=tuser,
            )
        )
        expected_frames.append(
            (
                bytes(value for value, keep in zip(payload, tkeep) if keep),
                expected_tid,
                expected_tdest,
                expected_tuser,
            )
        )

    for payload, tid, tdest, tuser in expected_frames:
        await assert_frame(tb.sink, payload, tid, tdest, tuser)

    await tb.source.wait()
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)

    assert tb.sink.empty()
    assert dut.status_empty.value == 1
    assert dut.status_full.value == 0


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_axis_fifo_full(dut):
    """填满 FIFO，检查反压，并在恢复读取后检查数据完整性。"""
    tb = TB(dut)
    await tb.reset()

    tb.sink.pause = True
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)

    byte_lanes = DATA_WIDTH // 8
    payload = bytes((index * 7) & 0xFF for index in range((DEPTH + 4) * byte_lanes))
    tid, expected_tid = sideband_values(0xA, ID_WIDTH)
    tdest, expected_tdest = sideband_values(0x5, DEST_WIDTH)
    tuser, expected_tuser = sideband_values(0x3, USER_WIDTH)

    await tb.source.send(
        AxiStreamFrame(payload, tid=tid, tdest=tdest, tuser=tuser)
    )

    for _ in range(DEPTH + 16):
        await RisingEdge(dut.clock)
        if dut.status_full.value == 1:
            break

    assert dut.status_full.value == 1, "FIFO 未在输出阻塞时进入满状态"
    assert dut.s_axis_tready.value == 0, "FIFO 满时仍接受输入"
    assert dut.m_axis_tvalid.value == 1

    held_output = (
        int(dut.m_axis_tdata.value),
        int(dut.m_axis_tkeep.value),
        int(dut.m_axis_tlast.value),
        int(dut.m_axis_tid.value),
        int(dut.m_axis_tdest.value),
        int(dut.m_axis_tuser.value),
    )

    for _ in range(3):
        await RisingEdge(dut.clock)
        assert dut.m_axis_tvalid.value == 1
        assert (
            int(dut.m_axis_tdata.value),
            int(dut.m_axis_tkeep.value),
            int(dut.m_axis_tlast.value),
            int(dut.m_axis_tid.value),
            int(dut.m_axis_tdest.value),
            int(dut.m_axis_tuser.value),
        ) == held_output

    tb.sink.pause = False
    await assert_frame(
        tb.sink, payload, expected_tid, expected_tdest, expected_tuser
    )
    await tb.source.wait()
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)

    assert dut.status_empty.value == 1
    assert dut.status_full.value == 0


def format_parameters(parameters):
    return ", ".join(f"{name}={value}" for name, value in parameters.items())


def run_parameter_matrix():
    sim = os.getenv("SIM", "verilator")
    proj_path = Path(__file__).resolve().parent
    test_module = Path(__file__).stem
    output_dir = Path("/tmp") / "mnpu-soc" / test_module
    parameter_names = tuple(PARAMETER_PRESETS)
    combinations = list(
        itertools.product(*(PARAMETER_PRESETS[name] for name in parameter_names))
    )

    for index, values in enumerate(combinations, start=1):
        test_parameters = dict(zip(parameter_names, values))
        hdl_parameters = {
            "DATA_WIDTH": test_parameters["DATA_WIDTH"],
            "DEPTH": test_parameters["DEPTH"],
            "KEEP_ENABLE": 1,
            "LAST_ENABLE": 1,
            "ID_ENABLE": int(test_parameters["ID_WIDTH"] > 0),
            "ID_WIDTH": max(1, test_parameters["ID_WIDTH"]),
            "DEST_ENABLE": int(test_parameters["DEST_WIDTH"] > 0),
            "DEST_WIDTH": max(1, test_parameters["DEST_WIDTH"]),
            "USER_ENABLE": int(test_parameters["USER_WIDTH"] > 0),
            "USER_WIDTH": max(1, test_parameters["USER_WIDTH"]),
        }
        extra_env = {
            f"PARAM_{name}": str(value) for name, value in test_parameters.items()
        }
        extra_env["PYTHONWARNINGS"] = "ignore::DeprecationWarning:cocotbext.axi"
        combination_name = "_".join(
            f"{name.lower()}-{value}" for name, value in test_parameters.items()
        )
        build_dir = output_dir / combination_name
        vcd_file = build_dir / "axis_fifo.vcd"
        parameter_text = format_parameters(test_parameters)

        print(f"[{index}/{len(combinations)}] Testing {parameter_text}", flush=True)

        try:
            runner = get_runner(sim)
            runner.build(
                sources=[proj_path.parent / "rtl" / "axis_fifo.v"],
                hdl_toplevel="axis_fifo",
                parameters=hdl_parameters,
                build_dir=build_dir,
                always=False,
                waves=True,
                build_args=[
                    "--timing",
                    "-Wno-WIDTHTRUNC",
                    "-Wno-SELRANGE",
                ],
            )
            results_file = runner.test(
                hdl_toplevel="axis_fifo",
                test_module=test_module,
                parameters=hdl_parameters,
                build_dir=build_dir,
                extra_env=extra_env,
                results_xml="results.xml",
                waves=True,
                test_args=["--trace-file", str(vcd_file)],
            )

            test_count, failed_count = get_results(results_file)
            if failed_count:
                raise RuntimeError(f"{failed_count} of {test_count} cocotb tests failed")
        except (Exception, SystemExit) as error:
            print("\nParameter combination failed:", file=sys.stderr)
            print(f"  {parameter_text}", file=sys.stderr)
            print(f"  Reason: {error}", file=sys.stderr)
            return 1

    print(f"All {len(combinations)} parameter combinations passed.")
    return 0


if __name__ == "__main__":
    sys.exit(run_parameter_matrix())

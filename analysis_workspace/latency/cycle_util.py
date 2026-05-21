import argparse
import csv
import re
import shutil
import subprocess
import sys
from collections import defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
from enum import IntEnum
import pandas as pd


def find_repo_root(start):
    for path in [start, *start.parents]:
        if (path / 'tools' / 'fsdb_cli').exists():
            return path
    raise RuntimeError('Repository root not found')


REPO_ROOT = find_repo_root(Path(__file__).resolve())
TOOLS_DIR = REPO_ROOT / 'tools'
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import fsdb_cli as fsdb

DEFAULT_FSDB = REPO_ROOT / 'build/logs/fpint_improve_m1_k256_n256/xrtsim_vcs/vcs_cosim.fsdb'
DEFAULT_SIMV_LOG = DEFAULT_FSDB.with_name('simv.log')
DEFAULT_KERNEL_ELF = REPO_ROOT / 'build/tests/regression/fpint_gemm_ffn_hw/kernel.elf'
DEFAULT_CLOCK_PERIOD_PS = 10_000

class SyncRegID(IntEnum):
    T0 = 0
    W0 = 1
    SZ0 = 2
    G0 = 3
    O = 4
    T1 = 5
    W1 = 6
    SZ1 = 7
    G1 = 8

    @classmethod
    def from_int(cls, value):
        value = _parse_sv_int(value)
        if value is None:
            return None
        try:
            return cls(value)
        except ValueError:
            return None

    @classmethod
    def name_from_int(cls, value):
        reg = cls.from_int(value)
        return reg.name if reg is not None else f'UNKNOWN_{value}'


class MpmAccelClass(IntEnum):
    ACCEL_MXU = 3
    ACCEL_DMA = 4
    ACCEL_LDMA_IN = 5
    ACCEL_LDMA_WT = 6
    ACCEL_LDMA_SZ = 7
    ACCEL_LDMA_OUT = 8


@dataclass(frozen=True)
class MpmCounter:
    mpm_class: MpmAccelClass
    csr: str
    name: str
    rtl_path: str | None


@dataclass(frozen=True)
class IntervalSignalSpec:
    section: str
    stream: str
    signal: str
    kind: str = 'fire'
    note: str = ''


@dataclass(frozen=True)
class GemmTracePaths:
    """Centralized FSDB hierarchy paths used by GEMM cycle analysis."""

    repo_root: Path = REPO_ROOT
    fsdb_path: Path = DEFAULT_FSDB
    tb_root: str = '/tb_vcs_xrtsim/dut/vortex_axi/vortex'
    cluster_id: int = 0
    socket_id: int = 0
    core_id: int = 0
    child_count: int = 5
    hbm_channel_count: int = 8

    def sig(self, base, name):
        return f'{base}/{name}'

    def vec(self, base, name, msb, lsb=0):
        return f'{base}/{name}[{msb}:{lsb}]'

    @property
    def core(self):
        return (
            f'{self.tb_root}/g_clusters[{self.cluster_id}]/cluster'
            f'/g_sockets[{self.socket_id}]/socket'
            f'/g_cores[{self.core_id}]/core'
        )

    @property
    def gemm_node(self):
        return f'{self.core}/gemm_node'

    @property
    def cpu_dma_unit(self):
        return f'{self.core}/u_VX_dma_node/u_dma_unit_misal'

    @property
    def gemm_unit(self):
        return f'{self.gemm_node}/u_VX_gemm_unit'

    @property
    def mxu(self):
        return f'{self.gemm_unit}/u_mxu'

    @property
    def gemm_ctrl(self):
        return f'{self.gemm_node}/u_VX_gemm_ctrl'

    @property
    def gemm_fsm(self):
        return f'{self.gemm_ctrl}/u_VX_gemm_fsm'

    @property
    def gemm_sync(self):
        return f'{self.gemm_ctrl}/u_VX_gemm_sync'

    @property
    def parent_cmd_queue(self):
        return f'{self.gemm_ctrl}/u_parent_cmd_queue'

    def child_cmd_queue(self, child_id):
        return f'{self.gemm_ctrl}/gen_child_cmd_queues[{child_id}]/u_child_cmd_queue'

    @property
    def child_cmd_queues(self):
        return [self.child_cmd_queue(i) for i in range(self.child_count)]

    @property
    def gemm_dma_ctrl(self):
        return f'{self.gemm_node}/u_VX_gemm_dma_ctrl_with_dma'

    @property
    def tmem_subsystem(self):
        return f'{self.gemm_node}/u_tmem_subsystem'

    @property
    def hbm_dma_engine(self):
        return f'{self.tmem_subsystem}/u_dma_engine'

    def hbm_dma_channel(self, channel_id):
        return f'{self.hbm_dma_engine}/g_channel[{channel_id}]/u_dma_unit'

    @property
    def input_lmem_dma(self):
        return f'{self.tmem_subsystem}/u_ldma_input'

    @property
    def weight_lmem_dma(self):
        return f'{self.tmem_subsystem}/u_ldma_weight'

    @property
    def quant_param_lmem_dma(self):
        return f'{self.tmem_subsystem}/u_ldma_sz'

    @property
    def output_lmem_dma(self):
        return f'{self.tmem_subsystem}/u_ldma_output'

    @property
    def lmem_dmas(self):
        return {
            'input': self.input_lmem_dma,
            'weight': self.weight_lmem_dma,
            'quant_param': self.quant_param_lmem_dma,
            'output': self.output_lmem_dma,
        }


DEFAULT_GEMM_PATHS = GemmTracePaths()

# Backward-compatible aliases for existing notebooks.
GEMM_NODE = DEFAULT_GEMM_PATHS.gemm_node
GEMM_SYNC = DEFAULT_GEMM_PATHS.gemm_sync

PERF_CTR_MSB = 43

MXU_COUNTER_REGS = {
    'gemm_compute_cycles': ('VX_CSR_MPM_GEMM_COMPUTE_CYC', 'perf_compute_r'),
    'gemm_stall_cycles': ('VX_CSR_MPM_GEMM_STALL_CYC', 'perf_stall_r'),
    'gemm_job_count': ('VX_CSR_MPM_GEMM_JOB_CNT', 'perf_jobs_r'),
    'mxu_mac_count': ('VX_CSR_MPM_MXU_MAC_COUNT', 'perf_mac_count_r'),
    'mxu_input_fire': ('VX_CSR_MPM_MXU_INPUT_FIRE', 'perf_input_fire_r'),
    'mxu_input_stall': ('VX_CSR_MPM_MXU_INPUT_STALL', 'perf_input_stall_r'),
    'mxu_weight_fire': ('VX_CSR_MPM_MXU_WEIGHT_FIRE', 'perf_weight_fire_r'),
    'mxu_weight_stall': ('VX_CSR_MPM_MXU_WEIGHT_STALL', 'perf_weight_stall_r'),
    'mxu_psum_fire': ('VX_CSR_MPM_MXU_PSUM_FIRE', 'perf_psum_fire_r'),
    'mxu_psum_stall': ('VX_CSR_MPM_MXU_PSUM_STALL', 'perf_psum_stall_r'),
    'mxu_output_fire': ('VX_CSR_MPM_MXU_OUTPUT_FIRE', 'perf_output_fire_r'),
    'mxu_output_stall': ('VX_CSR_MPM_MXU_OUTPUT_STALL', 'perf_output_stall_r'),
}

DMA_COUNTER_REGS = {
    'rd_bytes': ('RD_BYTES', 'perf_rd_bytes_r'),
    'wr_bytes': ('WR_BYTES', 'perf_wr_bytes_r'),
    'xfer_count': ('XFER_CNT', 'perf_xfers_r'),
    'active_cycles': ('ACTIVE_CYC', 'perf_active_r'),
    'src_rd_req_fire': ('SRC_RD_REQ_FIRE', 'perf_src_rd_req_fire_r'),
    'src_rd_req_stall': ('SRC_RD_REQ_STALL', 'perf_src_rd_req_stall_r'),
    'src_rd_data_fire': ('SRC_RD_DATA_FIRE', 'perf_src_rd_data_fire_r'),
    'src_rd_data_stall': ('SRC_RD_DATA_STALL', 'perf_src_rd_data_stall_r'),
    'dst_wr_fire': ('DST_WR_FIRE', 'perf_dst_wr_fire_r'),
    'dst_wr_stall': ('DST_WR_STALL', 'perf_dst_wr_stall_r'),
}

CPU_DMA_COUNTER_PREFIX = 'VX_CSR_MPM_CPU_DMA'
HBM_DMA_COUNTER_PREFIX = 'VX_CSR_MPM_HBM_DMA'
LDMA_COUNTER_PREFIX = 'VX_CSR_MPM_LDMA'

LDMA_CLASSES = {
    'input': MpmAccelClass.ACCEL_LDMA_IN,
    'weight': MpmAccelClass.ACCEL_LDMA_WT,
    'sz': MpmAccelClass.ACCEL_LDMA_SZ,
    'output': MpmAccelClass.ACCEL_LDMA_OUT,
}

def _is_one(value):
    return str(value).strip().lower() in {'1', "1'b1", '1h1', "1'h1", 'h1'}


def _parse_sv_int(value):
    text = str(value).strip().lower().replace('_', '')
    if not text or any(ch in text for ch in 'xz?'):
        return None
    if "'h" in text:
        return int(text.split("'h", 1)[1], 16)
    if "'b" in text:
        return int(text.split("'b", 1)[1], 2)
    if text.startswith('h'):
        return int(text[1:], 16)
    if text.startswith('b'):
        return int(text[1:], 2)
    if len(text) > 1 and set(text) <= {'0', '1'}:
        return int(text, 2)
    return int(text, 10)


def _pct(numerator, denominator):
    return 0.0 if denominator == 0 else 100.0 * numerator / denominator


def _ratio(numerator, denominator):
    return 0.0 if denominator == 0 else numerator / denominator


def _perf_vec(base, name):
    return f'{base}/{name}[{PERF_CTR_MSB}:0]'


def _cycle_from_time_ps(time_ps, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    if time_ps is None:
        return None
    return int(time_ps) // int(clock_period_ps)


def _cycles_between(start_time_ps, end_time_ps, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    if start_time_ps is None or end_time_ps is None:
        return None
    return (int(end_time_ps) - int(start_time_ps)) // int(clock_period_ps)


def _first(items):
    return items[0] if items else None


def _last(items):
    return items[-1] if items else None


def _last_int(fsdb_path, signal, bt=None, et=None, default=0, strict=False):
    if signal is None:
        return default
    try:
        report = fsdb.report(str(fsdb_path), [signal], bt=bt, et=et)
        events = report.events()
        if not events:
            return default
        value = events[-1].values.get(signal)
        parsed = _parse_sv_int(value)
        return default if parsed is None else parsed
    except Exception:
        if strict:
            raise
        return default


def _last_ints(fsdb_path, signals, bt=None, et=None, default=0, strict=False):
    unique_signals = [sig for sig in dict.fromkeys(signals) if sig is not None]
    values = {sig: default for sig in unique_signals}
    if not unique_signals:
        return values

    try:
        report = fsdb.report(str(fsdb_path), unique_signals, bt=bt, et=et)
        events = report.events()
        if not events:
            return values
        last_values = events[-1].values
        for sig in unique_signals:
            parsed = _parse_sv_int(last_values.get(sig))
            values[sig] = default if parsed is None else parsed
        return values
    except Exception:
        if strict:
            raise
        for sig in unique_signals:
            values[sig] = _last_int(fsdb_path, sig, bt=bt, et=et, default=default)
        return values


def _percentile(sorted_values, pct):
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    pos = (len(sorted_values) - 1) * (pct / 100.0)
    lo = int(pos)
    hi = min(lo + 1, len(sorted_values) - 1)
    frac = pos - lo
    return float(sorted_values[lo]) * (1.0 - frac) + float(sorted_values[hi]) * frac


def _mean(values):
    return 0.0 if not values else float(sum(values)) / float(len(values))


def _sample_active_cycles(fsdb_path, signal, clk_signal, bt=None, et=None,
                          clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    """Return cycles where signal is high on a rising clock edge."""
    try:
        report = fsdb.report(str(fsdb_path), [clk_signal, signal], bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return [], None

    cycles = []
    prev_clk = '0'
    time_unit = getattr(report, 'time_unit', None)

    for ev in events:
        clk_value = ev.values.get(clk_signal, '0')
        active = _is_one(ev.values.get(signal, '0'))
        if _is_one(clk_value) and not _is_one(prev_clk) and active:
            cycles.append(_cycle_from_time_ps(ev.time, clock_period_ps))
        prev_clk = clk_value

    return cycles, time_unit


def _sample_high_window_cycles(fsdb_path, signal, bt=None, et=None,
                               clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    """Return every cycle covered by high windows of a synchronous signal.

    This avoids reading the clock signal and preserves multi-cycle bursts. It
    assumes signal changes are aligned to the target clock period, which is true
    for these RTL fire/valid signals in the VCS FSDB.
    """
    try:
        report = fsdb.report(str(fsdb_path), [signal], bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return [], None

    cycles = []
    prev_active = False
    high_start_cycle = None
    time_unit = getattr(report, 'time_unit', None)

    for ev in events:
        active = _is_one(ev.values.get(signal, '0'))
        if active and not prev_active:
            high_start_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        elif prev_active and not active and high_start_cycle is not None:
            high_end_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
            if high_end_cycle <= high_start_cycle:
                cycles.append(high_start_cycle)
            else:
                cycles.extend(range(high_start_cycle, high_end_cycle))
            high_start_cycle = None
        prev_active = active

    if prev_active and high_start_cycle is not None:
        # If the report window ends while the signal is still high, count the
        # observed high start as a one-cycle event. Use sample_on_clk=True when
        # exact open-ended window length is needed.
        cycles.append(high_start_cycle)

    return cycles, time_unit


def _sample_predicate_high_window_cycles(fsdb_path, signals, predicate, bt=None, et=None,
                                         clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                         strict=False):
    """Return every cycle covered by high windows of a derived predicate."""
    signals = [sig for sig in dict.fromkeys(signals) if sig is not None]
    if not signals:
        return [], None

    try:
        report = fsdb.report(str(fsdb_path), signals, bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return [], None

    cycles = []
    prev_active = False
    high_start_cycle = None
    time_unit = getattr(report, 'time_unit', None)

    for ev in events:
        active = bool(predicate(ev.values))
        if active and not prev_active:
            high_start_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        elif prev_active and not active and high_start_cycle is not None:
            high_end_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
            if high_end_cycle <= high_start_cycle:
                cycles.append(high_start_cycle)
            else:
                cycles.extend(range(high_start_cycle, high_end_cycle))
            high_start_cycle = None
        prev_active = active

    if prev_active and high_start_cycle is not None:
        cycles.append(high_start_cycle)

    return cycles, time_unit


def _interval_summary_from_cycles(cycles, burst_gap_cycles=1):
    cycles = sorted(c for c in cycles if c is not None)
    intervals = [b - a for a, b in zip(cycles, cycles[1:])]
    sorted_intervals = sorted(intervals)

    bursts = []
    current_len = 0
    prev_cycle = None
    for cycle in cycles:
        if prev_cycle is None or (cycle - prev_cycle) > burst_gap_cycles:
            if current_len:
                bursts.append(current_len)
            current_len = 1
        else:
            current_len += 1
        prev_cycle = cycle
    if current_len:
        bursts.append(current_len)

    multi_burst_events = sum(length for length in bursts if length >= 2)
    bubble_intervals = [value for value in intervals if value > burst_gap_cycles]
    consecutive_intervals = [value for value in intervals if value <= burst_gap_cycles]

    return {
        'event_count': len(cycles),
        'interval_count': len(intervals),
        'first_cycle': cycles[0] if cycles else None,
        'last_cycle': cycles[-1] if cycles else None,
        'min_interval': min(intervals) if intervals else None,
        'max_interval': max(intervals) if intervals else None,
        'mean_interval': _mean(intervals),
        'p50_interval': _percentile(sorted_intervals, 50),
        'p90_interval': _percentile(sorted_intervals, 90),
        'p99_interval': _percentile(sorted_intervals, 99),
        'burst_gap_cycles': burst_gap_cycles,
        'burst_count': len(bursts),
        'max_burst_len': max(bursts) if bursts else 0,
        'mean_burst_len': _mean(bursts),
        'multi_event_burst_count': sum(1 for length in bursts if length >= 2),
        'multi_event_burst_event_pct': _pct(multi_burst_events, len(cycles)),
        'consecutive_interval_pct': _pct(len(consecutive_intervals), len(intervals)),
        'bubble_interval_count': len(bubble_intervals),
        'mean_bubble_cycles': _mean([value - burst_gap_cycles for value in bubble_intervals]),
    }


def build_interval_signal_specs(paths=DEFAULT_GEMM_PATHS, groups=None, kind='fire'):
    """Return preset interval-analysis signals for DMA, LDMA, and MXU streams.

    kind='fire' uses valid&&ready event wires where available.
    kind='valid' uses request/response valid wires for LDMA and MXU bus streams.
    """
    groups = {'dma', 'ldma', 'mxu'} if groups is None else set(groups)
    specs = []

    if 'dma' in groups:
        if kind == 'valid':
            # DMA valid-only preset is not exposed here; keep fire pulse wires.
            dma_note = 'fire signal; valid-only not exposed here'
        else:
            dma_note = 'fire signal'
        for stream, sig in (
            ('src_rd_req', 'perf_src_rd_req_fire'),
            ('src_rd_data', 'perf_src_rd_data_fire'),
            ('dst_wr', 'perf_dst_wr_fire'),
        ):
            specs.append(IntervalSignalSpec('cpu_dma', stream, f'{paths.cpu_dma_unit}/{sig}', 'fire', dma_note))
            for channel_id in range(paths.hbm_channel_count):
                section = f'hbm_dma_ch{channel_id}'
                specs.append(IntervalSignalSpec(
                    section,
                    stream,
                    f'{paths.hbm_dma_channel(channel_id)}/{sig}',
                    'fire',
                    dma_note,
                ))

    if 'ldma' in groups:
        ldma_signals = (
            ('src_rd_req', 'perf_src_req_valid', 'perf_src_rd_req_fire'),
            ('src_rd_data', 'perf_src_rsp_valid', 'perf_src_rd_data_fire'),
            ('dst_wr', 'perf_dst_req_valid', 'perf_dst_wr_fire'),
        )
        for ldma_name, base in paths.lmem_dmas.items():
            section = f'ldma_{ldma_name if ldma_name != "quant_param" else "sz"}'
            for stream, valid_sig, fire_sig in ldma_signals:
                signal_name = valid_sig if kind == 'valid' else fire_sig
                specs.append(IntervalSignalSpec(section, stream, f'{base}/{signal_name}', kind))

    if 'mxu' in groups:
        if kind == 'valid':
            mxu_signals = (
                ('input', 'i_lmem_bus_if.req_valid', 'input request valid'),
                ('weight', 'w_lmem_bus_if.req_valid', 'weight request valid'),
                ('psum', 'acc_mem_rd_data_valid', 'psum read data valid'),
                ('output', 'o_lmem_bus_if.req_valid', 'output request valid'),
            )
            for stream, signal_name, note in mxu_signals:
                specs.append(IntervalSignalSpec('mxu', stream, f'{paths.gemm_unit}/{signal_name}', 'valid', note))
        else:
            for stream in ('input', 'weight', 'psum', 'output'):
                specs.append(IntervalSignalSpec('mxu', stream, f'{paths.gemm_unit}/perf_{stream}_fire', 'fire'))

    return specs


def analyze_signal_intervals(fsdb_path=DEFAULT_FSDB, specs=None, paths=DEFAULT_GEMM_PATHS,
                             groups=None, kind='fire', bt=None, et=None,
                             clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                             burst_gap_cycles=1, sample_on_clk=False, strict=False):
    """Analyze intervals between active samples for DMA/LDMA/MXU signals.

    By default this expands signal high windows into cycles without reading the
    clock. This preserves multi-cycle fire/valid bursts and is much faster than
    clock sampling. Set sample_on_clk=True to count every rising clock edge
    where the signal is high when exact open-ended window handling is needed.

    Intervals are measured in cycles between active samples. With
    burst_gap_cycles=1, a burst means consecutive-cycle activity.
    """
    specs = specs or build_interval_signal_specs(paths=paths, groups=groups, kind=kind)
    clk_signal = f'{paths.core}/clk'
    rows = []

    for spec in specs:
        if sample_on_clk:
            cycles, time_unit = _sample_active_cycles(
                fsdb_path,
                spec.signal,
                clk_signal,
                bt=bt,
                et=et,
                clock_period_ps=clock_period_ps,
                strict=strict,
            )
        else:
            cycles, time_unit = _sample_high_window_cycles(
                fsdb_path,
                spec.signal,
                bt=bt,
                et=et,
                clock_period_ps=clock_period_ps,
                strict=strict,
            )
        summary = _interval_summary_from_cycles(cycles, burst_gap_cycles=burst_gap_cycles)
        row = {
            'section': spec.section,
            'stream': spec.stream,
            'kind': spec.kind,
            'signal': spec.signal,
            'note': spec.note,
            'time_unit': time_unit,
        }
        row.update(summary)
        rows.append(row)

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(['section', 'stream', 'kind']).reset_index(drop=True)

    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}, clock_period_ps={clock_period_ps}, kind={kind}')
    print(f'burst_gap_cycles={burst_gap_cycles}, sample_on_clk={sample_on_clk}')
    return df


def analyze_burst_intervals(*args, **kwargs):
    """Alias for analyze_signal_intervals."""
    return analyze_signal_intervals(*args, **kwargs)


def analyze_hbm_access_intervals(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS,
                                 channels=None, streams=None, bt=None, et=None,
                                 clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                 burst_gap_cycles=1, strict=False):
    """Analyze true HBM-side GEMM DMA access intervals and burstiness."""
    channels = list(range(paths.hbm_channel_count)) if channels is None else list(channels)
    stream_filter = None if streams is None else set(streams)
    rows = []

    for channel_id in channels:
        base = paths.hbm_dma_channel(channel_id)
        active_signal = f'{base}/in_g2l_active'
        src_req_signal = f'{base}/src_req_fire'
        read_rsp_signal = f'{base}/g2l_rd_beat'
        write_req_signal = f'{base}/l2g_wr_beat'

        stream_specs = [
            (
                'read_req',
                src_req_signal,
                'in_g2l_active && src_req_fire',
                [active_signal, src_req_signal],
                lambda values, a=active_signal, r=src_req_signal: _is_one(values.get(a, '0')) and _is_one(values.get(r, '0')),
                'G2L HBM read request accepted.',
            ),
            (
                'read_rsp',
                read_rsp_signal,
                'g2l_rd_beat',
                [read_rsp_signal],
                None,
                'G2L HBM read response beat returned.',
            ),
            (
                'write_req',
                write_req_signal,
                'l2g_wr_beat',
                [write_req_signal],
                None,
                'L2G HBM write request accepted.',
            ),
        ]

        for stream, signal, condition, signals, predicate, note in stream_specs:
            if stream_filter is not None and stream not in stream_filter:
                continue
            if predicate is None:
                cycles, time_unit = _sample_high_window_cycles(
                    fsdb_path,
                    signal,
                    bt=bt,
                    et=et,
                    clock_period_ps=clock_period_ps,
                    strict=strict,
                )
            else:
                cycles, time_unit = _sample_predicate_high_window_cycles(
                    fsdb_path,
                    signals,
                    predicate,
                    bt=bt,
                    et=et,
                    clock_period_ps=clock_period_ps,
                    strict=strict,
                )

            row = {
                'section': f'hbm_dma_ch{channel_id}',
                'channel': channel_id,
                'stream': stream,
                'kind': 'fire',
                'signal': signal,
                'condition': condition,
                'time_unit': time_unit,
                'note': note,
            }
            row.update(_interval_summary_from_cycles(cycles, burst_gap_cycles=burst_gap_cycles))
            rows.append(row)

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(['section', 'stream']).reset_index(drop=True)

    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}, clock_period_ps={clock_period_ps}')
    print(f'burst_gap_cycles={burst_gap_cycles}')
    print('HBM access intervals: read_req/read_rsp/write_req')
    return df


def _latency_samples_from_cycles(req_cycles, rsp_cycles):
    """FIFO-match request cycles to the first later/equal response cycle."""
    req_cycles = sorted(c for c in req_cycles if c is not None)
    rsp_cycles = sorted(c for c in rsp_cycles if c is not None)

    latencies = []
    pending = deque()
    req_idx = 0
    orphan_rsp_count = 0

    for rsp_cycle in rsp_cycles:
        while req_idx < len(req_cycles) and req_cycles[req_idx] <= rsp_cycle:
            pending.append(req_cycles[req_idx])
            req_idx += 1
        if pending:
            req_cycle = pending.popleft()
            latencies.append(rsp_cycle - req_cycle)
        else:
            orphan_rsp_count += 1

    unmatched_req_count = len(pending) + (len(req_cycles) - req_idx)
    return latencies, unmatched_req_count, orphan_rsp_count


def _latency_summary_from_cycles(req_cycles, rsp_cycles, latencies=None,
                                 unmatched_req_count=None, orphan_rsp_count=None):
    req_cycles = sorted(c for c in req_cycles if c is not None)
    rsp_cycles = sorted(c for c in rsp_cycles if c is not None)
    if latencies is None or unmatched_req_count is None or orphan_rsp_count is None:
        latencies, unmatched_req_count, orphan_rsp_count = _latency_samples_from_cycles(
            req_cycles,
            rsp_cycles,
        )

    sorted_latencies = sorted(latencies)
    return {
        'req_count': len(req_cycles),
        'rsp_count': len(rsp_cycles),
        'matched_count': len(latencies),
        'unmatched_req_count': unmatched_req_count,
        'orphan_rsp_count': orphan_rsp_count,
        'first_req_cycle': _first(req_cycles),
        'last_req_cycle': _last(req_cycles),
        'first_rsp_cycle': _first(rsp_cycles),
        'last_rsp_cycle': _last(rsp_cycles),
        'min_latency': min(latencies) if latencies else None,
        'max_latency': max(latencies) if latencies else None,
        'mean_latency': _mean(latencies),
        'p50_latency': _percentile(sorted_latencies, 50),
        'p90_latency': _percentile(sorted_latencies, 90),
        'p99_latency': _percentile(sorted_latencies, 99),
    }


def analyze_hbm_read_latency(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS,
                             channels=None, bt=None, et=None,
                             clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                             include_aggregate=True, strict=False):
    """Analyze HBM read request-to-response latency for GEMM DMA channels.

    The current FSDB dump does not expose the dcache response tag. This uses
    channel-local FIFO matching between G2L source read requests and G2L read
    response beats, which is exact when responses are returned in issue order
    and a useful approximation otherwise.
    """
    channels = list(range(paths.hbm_channel_count)) if channels is None else list(channels)
    rows = []
    aggregate_req_cycles = []
    aggregate_rsp_cycles = []
    aggregate_latencies = []
    aggregate_unmatched = 0
    aggregate_orphan = 0

    for channel_id in channels:
        base = paths.hbm_dma_channel(channel_id)
        active_signal = f'{base}/in_g2l_active'
        req_signal = f'{base}/src_req_fire'
        rsp_signal = f'{base}/g2l_rd_beat'

        req_cycles, req_time_unit = _sample_predicate_high_window_cycles(
            fsdb_path,
            [active_signal, req_signal],
            lambda values, a=active_signal, r=req_signal: _is_one(values.get(a, '0')) and _is_one(values.get(r, '0')),
            bt=bt,
            et=et,
            clock_period_ps=clock_period_ps,
            strict=strict,
        )
        rsp_cycles, rsp_time_unit = _sample_high_window_cycles(
            fsdb_path,
            rsp_signal,
            bt=bt,
            et=et,
            clock_period_ps=clock_period_ps,
            strict=strict,
        )
        latencies, unmatched_req_count, orphan_rsp_count = _latency_samples_from_cycles(
            req_cycles,
            rsp_cycles,
        )
        summary = _latency_summary_from_cycles(
            req_cycles,
            rsp_cycles,
            latencies=latencies,
            unmatched_req_count=unmatched_req_count,
            orphan_rsp_count=orphan_rsp_count,
        )

        row = {
            'section': f'hbm_dma_ch{channel_id}',
            'channel': channel_id,
            'stream': 'read',
            'matching': 'channel_fifo',
            'unit': 'cycles',
            'request_signal': req_signal,
            'request_condition': 'in_g2l_active && src_req_fire',
            'response_signal': rsp_signal,
            'response_condition': 'g2l_rd_beat',
            'time_unit': req_time_unit or rsp_time_unit,
            'note': 'HBM G2L read request to HBM read response; response tag is not dumped.',
        }
        row.update(summary)
        rows.append(row)

        aggregate_req_cycles.extend((channel_id, cycle) for cycle in req_cycles)
        aggregate_rsp_cycles.extend((channel_id, cycle) for cycle in rsp_cycles)
        aggregate_latencies.extend(latencies)
        aggregate_unmatched += unmatched_req_count
        aggregate_orphan += orphan_rsp_count

    if include_aggregate:
        sorted_aggregate_latencies = sorted(aggregate_latencies)
        req_cycles_only = [cycle for _, cycle in aggregate_req_cycles]
        rsp_cycles_only = [cycle for _, cycle in aggregate_rsp_cycles]
        rows.append({
            'section': 'hbm_dma_all',
            'channel': 'all',
            'stream': 'read',
            'matching': 'per_channel_fifo_aggregate',
            'unit': 'cycles',
            'request_signal': '',
            'request_condition': 'per-channel in_g2l_active && src_req_fire',
            'response_signal': '',
            'response_condition': 'per-channel g2l_rd_beat',
            'time_unit': None,
            'note': 'Aggregate of per-channel FIFO latency samples.',
            'req_count': len(aggregate_req_cycles),
            'rsp_count': len(aggregate_rsp_cycles),
            'matched_count': len(aggregate_latencies),
            'unmatched_req_count': aggregate_unmatched,
            'orphan_rsp_count': aggregate_orphan,
            'first_req_cycle': _first(sorted(req_cycles_only)),
            'last_req_cycle': _last(sorted(req_cycles_only)),
            'first_rsp_cycle': _first(sorted(rsp_cycles_only)),
            'last_rsp_cycle': _last(sorted(rsp_cycles_only)),
            'min_latency': min(aggregate_latencies) if aggregate_latencies else None,
            'max_latency': max(aggregate_latencies) if aggregate_latencies else None,
            'mean_latency': _mean(aggregate_latencies),
            'p50_latency': _percentile(sorted_aggregate_latencies, 50),
            'p90_latency': _percentile(sorted_aggregate_latencies, 90),
            'p99_latency': _percentile(sorted_aggregate_latencies, 99),
        })

    df = pd.DataFrame(rows)
    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}, clock_period_ps={clock_period_ps}')
    print('HBM read latency: in_g2l_active && src_req_fire -> g2l_rd_beat')
    return df


def build_mpm_accel_counters(paths=DEFAULT_GEMM_PATHS):
    counters = []

    def add_common(mpm_class):
        counters.extend([
            MpmCounter(
                mpm_class,
                'VX_CSR_MPM_BUSY_CYC',
                'busy_cycles',
                _perf_vec(paths.core, 'perf_busy_r'),
            ),
            MpmCounter(
                mpm_class,
                'VX_CSR_MPM_GEMM_TOTAL_CYC',
                'gemm_total_cycles',
                _perf_vec(paths.gemm_ctrl, 'perf_total_cycles_r'),
            ),
        ])

    add_common(MpmAccelClass.ACCEL_MXU)
    for name, (csr, reg) in MXU_COUNTER_REGS.items():
        counters.append(MpmCounter(MpmAccelClass.ACCEL_MXU, csr, name, _perf_vec(paths.gemm_unit, reg)))
    counters.append(MpmCounter(
        MpmAccelClass.ACCEL_MXU,
        'VX_CSR_MPM_OVERLAP_DMA_MXU',
        'overlap_dma_mxu',
        _perf_vec(paths.core, 'perf_overlap_r'),
    ))

    add_common(MpmAccelClass.ACCEL_DMA)
    for name, (csr_suffix, reg) in DMA_COUNTER_REGS.items():
        counters.append(MpmCounter(
            MpmAccelClass.ACCEL_DMA,
            f'{CPU_DMA_COUNTER_PREFIX}_{csr_suffix}',
            f'cpu_dma_{name}',
            _perf_vec(paths.cpu_dma_unit, reg),
        ))
    for name, (csr_suffix, _) in DMA_COUNTER_REGS.items():
        counters.append(MpmCounter(
            MpmAccelClass.ACCEL_DMA,
            f'{HBM_DMA_COUNTER_PREFIX}_{csr_suffix}',
            f'hbm_dma_{name}',
            _perf_vec(paths.hbm_dma_engine, f'perf.aggregate.{name}'),
        ))
    counters.extend([
        MpmCounter(
            MpmAccelClass.ACCEL_DMA,
            'VX_CSR_MPM_HBM_DMA_ACTIVE_MAX',
            'hbm_dma_active_max',
            _perf_vec(paths.hbm_dma_engine, 'perf.active_cycles_max'),
        ),
        MpmCounter(
            MpmAccelClass.ACCEL_DMA,
            'VX_CSR_MPM_HBM_DMA_ACTIVE_MIN',
            'hbm_dma_active_min',
            _perf_vec(paths.hbm_dma_engine, 'perf.active_cycles_min'),
        ),
    ])

    for ldma_name, mpm_class in LDMA_CLASSES.items():
        add_common(mpm_class)
        base = paths.lmem_dmas[ldma_name if ldma_name != 'sz' else 'quant_param']
        for name, (csr_suffix, reg) in DMA_COUNTER_REGS.items():
            counters.append(MpmCounter(
                mpm_class,
                f'{LDMA_COUNTER_PREFIX}_{csr_suffix}',
                f'ldma_{ldma_name}_{name}',
                _perf_vec(base, reg),
            ))
        counters.extend([
            MpmCounter(
                mpm_class,
                'VX_CSR_MPM_LDMA_WAIT_DCACHE',
                f'ldma_{ldma_name}_wait_dcache',
                None,
            ),
            MpmCounter(
                mpm_class,
                'VX_CSR_MPM_LDMA_WAIT_LMEM',
                f'ldma_{ldma_name}_wait_lmem',
                None,
            ),
        ])

    return counters


def read_mpm_accel_counters(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS, classes=None,
                            bt=None, et=None, strict=False):
    """Read ACCEL_* MPM-equivalent counter values from FSDB RTL counters."""
    class_filter = None if classes is None else {MpmAccelClass(c) for c in classes}
    counters = [
        counter for counter in build_mpm_accel_counters(paths)
        if class_filter is None or counter.mpm_class in class_filter
    ]
    signal_values = _last_ints(
        fsdb_path,
        [counter.rtl_path for counter in counters],
        bt=bt,
        et=et,
        strict=strict,
    )
    rows = []
    for counter in counters:
        rows.append({
            'mpm_class': counter.mpm_class.name,
            'csr': counter.csr,
            'counter': counter.name,
            'value': signal_values.get(counter.rtl_path, 0) if counter.rtl_path is not None else 0,
            'rtl_path': counter.rtl_path,
        })
    return pd.DataFrame(rows)


def analyze_mpm_accel(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS, bt=None, et=None, strict=False):
    """Return runtime-style derived metrics for ACCEL_* MPM counters."""
    counters = read_mpm_accel_counters(fsdb_path, paths, bt=bt, et=et, strict=strict)
    values = dict(zip(counters['counter'], counters['value']))

    rows = []

    def add(section, metric, value, unit='count'):
        rows.append({'section': section, 'metric': metric, 'value': value, 'unit': unit})

    busy = values.get('busy_cycles', 0)
    total = values.get('gemm_total_cycles', 0)
    compute = values.get('gemm_compute_cycles', 0)
    macs = values.get('mxu_mac_count', 0)
    flops = macs * 2

    add('mxu', 'busy_cycles', busy, 'cycles')
    add('mxu', 'gemm_total_cycles', total, 'cycles')
    add('mxu', 'gemm_compute_cycles', compute, 'cycles')
    add('mxu', 'gemm_stall_cycles', values.get('gemm_stall_cycles', 0), 'cycles')
    add('mxu', 'gemm_job_count', values.get('gemm_job_count', 0), 'count')
    add('mxu', 'mxu_mac_count', macs, 'mac')
    add('mxu', 'flops', flops, 'flop')
    add('mxu', 'achieved_flops_per_cycle_total', _ratio(flops, total), 'flop/cycle')
    add('mxu', 'overlap_dma_mxu_pct_total', _pct(values.get('overlap_dma_mxu', 0), total), 'pct')

    for port in ('input', 'weight', 'psum', 'output'):
        fire = values.get(f'mxu_{port}_fire', 0)
        stall = values.get(f'mxu_{port}_stall', 0)
        add('mxu', f'{port}_fire', fire, 'count')
        add('mxu', f'{port}_stall', stall, 'count')
        add('mxu', f'{port}_util_pct_total', _pct(fire, total), 'pct')
        add('mxu', f'{port}_util_pct_compute', _pct(fire, compute), 'pct')
        add('mxu', f'{port}_stall_pct_activity', _pct(stall, fire + stall), 'pct')

    for prefix in ('cpu_dma', 'hbm_dma'):
        rd = values.get(f'{prefix}_rd_bytes', 0)
        wr = values.get(f'{prefix}_wr_bytes', 0)
        active = values.get(f'{prefix}_active_cycles', 0)
        bytes_total = rd + wr
        active_den = values.get('hbm_dma_active_max', 0) if prefix == 'hbm_dma' else active
        section = prefix
        add(section, 'rd_bytes', rd, 'bytes')
        add(section, 'wr_bytes', wr, 'bytes')
        add(section, 'xfer_count', values.get(f'{prefix}_xfer_count', 0), 'count')
        add(section, 'active_cycles', active, 'cycles')
        add(section, 'util_pct_busy', _pct(active_den, busy), 'pct')
        add(section, 'util_pct_total', _pct(active_den, total), 'pct')
        add(section, 'bandwidth_bytes_per_active_cycle', _ratio(bytes_total, active_den), 'B/cycle')
        add(section, 'bandwidth_bytes_per_busy_cycle', _ratio(bytes_total, busy), 'B/cycle')
        for event in ('src_rd_req', 'src_rd_data', 'dst_wr'):
            fire = values.get(f'{prefix}_{event}_fire', 0)
            stall = values.get(f'{prefix}_{event}_stall', 0)
            add(section, f'{event}_fire', fire, 'count')
            add(section, f'{event}_stall', stall, 'count')
            add(section, f'{event}_stall_pct_activity', _pct(stall, fire + stall), 'pct')

    hbm_max = values.get('hbm_dma_active_max', 0)
    hbm_min = values.get('hbm_dma_active_min', 0)
    add('hbm_dma', 'active_max', hbm_max, 'cycles')
    add('hbm_dma', 'active_min', hbm_min, 'cycles')
    add('hbm_dma', 'active_imbalance_pct', _pct(hbm_max - hbm_min, hbm_max), 'pct')

    for ldma_name in LDMA_CLASSES:
        prefix = f'ldma_{ldma_name}'
        rd = values.get(f'{prefix}_rd_bytes', 0)
        wr = values.get(f'{prefix}_wr_bytes', 0)
        active = values.get(f'{prefix}_active_cycles', 0)
        bytes_total = rd + wr
        add(prefix, 'rd_bytes', rd, 'bytes')
        add(prefix, 'wr_bytes', wr, 'bytes')
        add(prefix, 'xfer_count', values.get(f'{prefix}_xfer_count', 0), 'count')
        add(prefix, 'active_cycles', active, 'cycles')
        add(prefix, 'util_pct_busy', _pct(active, busy), 'pct')
        add(prefix, 'util_pct_total', _pct(active, total), 'pct')
        add(prefix, 'bandwidth_bytes_per_active_cycle', _ratio(bytes_total, active), 'B/cycle')
        add(prefix, 'bandwidth_bytes_per_busy_cycle', _ratio(bytes_total, busy), 'B/cycle')
        for event in ('src_rd_req', 'src_rd_data', 'dst_wr'):
            fire = values.get(f'{prefix}_{event}_fire', 0)
            stall = values.get(f'{prefix}_{event}_stall', 0)
            add(prefix, f'{event}_fire', fire, 'count')
            add(prefix, f'{event}_stall', stall, 'count')
            add(prefix, f'{event}_stall_pct_activity', _pct(stall, fire + stall), 'pct')

    df = pd.DataFrame(rows)
    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}')
    return df


_SIMV_TIME_RE = re.compile(r'^\s*(\d+):\s+(.*)$')


def _collect_simv_markers(simv_log=DEFAULT_SIMV_LOG):
    markers = defaultdict(lambda: {
        'first_time_ps': None,
        'last_time_ps': None,
        'count': 0,
        'first_msg': None,
        'last_msg': None,
    })

    simv_log = Path(simv_log)
    if not simv_log.exists():
        return markers

    def record(kind, time_ps, msg):
        item = markers[kind]
        if item['first_time_ps'] is None:
            item['first_time_ps'] = time_ps
            item['first_msg'] = msg
        item['last_time_ps'] = time_ps
        item['last_msg'] = msg
        item['count'] += 1

    with simv_log.open('r', errors='replace') as fp:
        for line in fp:
            match = _SIMV_TIME_RE.match(line)
            if not match:
                continue
            time_ps = int(match.group(1))
            msg = match.group(2).strip()

            if ' tags-init:' in msg:
                record('tag_init', time_ps, msg)
            elif ' tags-flush:' in msg:
                record('tag_flush', time_ps, msg)
            elif ' data-flush:' in msg:
                record('data_flush', time_ps, msg)
            elif msg == 'AFU: Execution completed':
                record('afu_execution_completed', time_ps, msg)
            elif msg == 'AFU: ap_done pending latched':
                record('ap_done_pending', time_ps, msg)
            elif msg == 'AFU: ap_done consumed by host':
                record('ap_done_consumed', time_ps, msg)
            elif msg == 'AFU: Processor idle':
                record('processor_idle', time_ps, msg)

    return markers


def parse_simv_phase_markers(simv_log=DEFAULT_SIMV_LOG, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    """Summarize phase-relevant timestamp markers printed in simv.log."""
    markers = _collect_simv_markers(simv_log)
    rows = []
    for marker, item in sorted(markers.items(), key=lambda kv: (kv[1]['first_time_ps'] or 0, kv[0])):
        first_time = item['first_time_ps']
        last_time = item['last_time_ps']
        rows.append({
            'marker': marker,
            'count': item['count'],
            'first_time_ps': first_time,
            'last_time_ps': last_time,
            'first_cycle': _cycle_from_time_ps(first_time, clock_period_ps),
            'last_cycle': _cycle_from_time_ps(last_time, clock_period_ps),
            'span_cycles_inclusive': None if first_time is None else (
                _cycles_between(first_time, last_time, clock_period_ps) + 1
            ),
            'first_msg': item['first_msg'],
            'last_msg': item['last_msg'],
        })
    return pd.DataFrame(rows)


def _high_windows(events, signal, end_time_ps=None):
    windows = []
    start_time = None
    prev_high = False

    for ev in events:
        high = _is_one(ev.values.get(signal, '0'))
        if high and not prev_high:
            start_time = ev.time
        elif prev_high and not high and start_time is not None:
            windows.append((start_time, ev.time))
            start_time = None
        prev_high = high

    if prev_high and start_time is not None and end_time_ps is not None:
        windows.append((start_time, end_time_ps))
    return windows


def _first_nonzero_time(events, signal):
    for ev in events:
        value = _parse_sv_int(ev.values.get(signal, '0'))
        if value is not None and value > 0:
            return ev.time
    return None


def _last_counter_change_time(events, signal):
    last_time = None
    prev_value = None
    for ev in events:
        value = _parse_sv_int(ev.values.get(signal, '0'))
        if value is None:
            continue
        if prev_value is None:
            prev_value = value
            continue
        if value != prev_value:
            last_time = ev.time
            prev_value = value
    return last_time


def _unique_append_time(items, time_ps):
    if time_ps is None:
        return
    if not items or items[-1] != time_ps:
        items.append(time_ps)


def _find_spawn_active_times(events, active_warps_signal, spawn_events):
    active_times = []
    for spawn in spawn_events:
        expected_mask = spawn.get('active_warps', 0) | spawn.get('wspawn_wmask', 0)
        found_time = None
        for ev in events:
            if ev.time < spawn['time_ps']:
                continue
            active = _parse_sv_int(ev.values.get(active_warps_signal, '0'))
            if active is not None and active == expected_mask:
                found_time = ev.time
                break
        active_times.append(found_time)
    return active_times


_TRACE_EVENT_RE = re.compile(
    r'^\s*(\d+):\s+.*core\d+-(issue\d+-dispatch|commit):\s+.*'
    r'PC=(0x[0-9a-fA-F]+),\s+ex=([^,]+)(?:,\s+op=([^,]+))?'
)

_RUNTIME_BOOTSTRAP_SYMBOLS = {
    '_start',
    'init_regs',
    'init_regs_all',
    'init_tls_all',
    '__init_tls',
    '__libc_init_array',
}

_RUNTIME_EXIT_SYMBOLS = {
    'exit',
    '__funcs_on_exit',
    '__libc_exit_fini',
    'libc_exit_fini',
    '__stdio_exit',
    '_fini',
    'dummy',
}

_LIBRARY_SYMBOLS = {
    'memcpy',
    'memset',
}


def _tool_path(tool_names):
    for name in tool_names:
        path = shutil.which(name)
        if path:
            return path
    return None


def _load_elf_symbols(elf_path=DEFAULT_KERNEL_ELF, strict=False):
    """Return sorted (address, symbol) pairs from a RISC-V kernel ELF."""
    if elf_path is None:
        return []
    elf_path = Path(elf_path)
    if not elf_path.exists():
        if strict:
            raise FileNotFoundError(elf_path)
        return []

    nm = _tool_path([
        'riscv64-unknown-elf-nm',
        'riscv64-elf-nm',
        'llvm-nm',
        'nm',
    ])
    if nm is None:
        if strict:
            raise RuntimeError('No nm tool found')
        return []

    try:
        proc = subprocess.run(
            [nm, '-n', '--demangle', str(elf_path)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except Exception:
        if strict:
            raise
        return []

    symbols = []
    for line in proc.stdout.splitlines():
        parts = line.strip().split(maxsplit=2)
        if len(parts) != 3:
            continue
        addr_text, sym_type, name = parts
        if sym_type.lower() not in {'t', 'w'}:
            continue
        if name.startswith('$'):
            continue
        try:
            addr = int(addr_text, 16)
        except ValueError:
            continue
        symbols.append((addr, name))
    return sorted(symbols)


def _symbol_for_pc(pc, symbols):
    if pc is None or not symbols:
        return None
    selected = None
    for addr, name in symbols:
        if addr > pc:
            break
        selected = name
    return selected


def _symbol_base(symbol):
    if symbol is None:
        return None
    return symbol.split('(', 1)[0]


def _instruction_category(symbol):
    base = _symbol_base(symbol)
    if base is None:
        return 'unknown_instruction'
    if base == '_Exit':
        return 'exit_final'
    if base == 'vx_perf_dump':
        return 'perf_dump'
    if base in _RUNTIME_EXIT_SYMBOLS:
        return 'runtime_exit'
    if base in _RUNTIME_BOOTSTRAP_SYMBOLS:
        return 'runtime_bootstrap'
    if base in _LIBRARY_SYMBOLS:
        return 'library'
    return 'user_kernel'


def _parse_simv_instruction_events(simv_log=DEFAULT_SIMV_LOG, elf_path=DEFAULT_KERNEL_ELF,
                                   start_time_ps=None, end_time_ps=None, strict=False):
    symbols = _load_elf_symbols(elf_path, strict=strict)
    simv_log = Path(simv_log)
    if not simv_log.exists():
        if strict:
            raise FileNotFoundError(simv_log)
        return []

    events = []
    with simv_log.open('r', errors='replace') as fp:
        for line in fp:
            match = _TRACE_EVENT_RE.match(line)
            if not match:
                continue
            time_ps = int(match.group(1))
            if start_time_ps is not None and time_ps < start_time_ps:
                continue
            if end_time_ps is not None and time_ps > end_time_ps:
                continue
            pc = int(match.group(3), 16)
            symbol = _symbol_for_pc(pc, symbols)
            events.append({
                'time_ps': time_ps,
                'cycle': _cycle_from_time_ps(time_ps),
                'event': 'dispatch' if 'dispatch' in match.group(2) else 'commit',
                'pc': pc,
                'pc_hex': f'0x{pc:08x}',
                'ex': match.group(4),
                'op': match.group(5) or '',
                'symbol': symbol,
                'category': _instruction_category(symbol),
            })
    return events


def _event_count(events, category=None, event=None):
    return sum(
        1 for item in events
        if (category is None or item['category'] == category)
        and (event is None or item['event'] == event)
    )


def _first_event_time(events, category=None, after_time_ps=None):
    for item in events:
        if category is not None and item['category'] != category:
            continue
        if after_time_ps is not None and item['time_ps'] <= after_time_ps:
            continue
        return item['time_ps']
    return None


def _last_event_time(events, category=None, before_time_ps=None):
    for item in reversed(events):
        if category is not None and item['category'] != category:
            continue
        if before_time_ps is not None and item['time_ps'] >= before_time_ps:
            continue
        return item['time_ps']
    return None


def _symbols_in_window(events, start_time_ps, end_time_ps):
    if start_time_ps is None:
        return ''
    names = []
    for item in events:
        if item['time_ps'] < start_time_ps:
            continue
        if end_time_ps is not None and item['time_ps'] > end_time_ps:
            continue
        if item['symbol'] and item['symbol'] not in names:
            names.append(item['symbol'])
    return ', '.join(names)


def _collapse_instruction_windows(events, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    windows = []
    current = None
    for item in events:
        category = item['category']
        if current is None or current['phase'] != category:
            if current is not None:
                current['end_time_ps'] = current['last_time_ps'] + clock_period_ps
                current['end_cycle'] = _cycle_from_time_ps(current['end_time_ps'], clock_period_ps)
                current['cycles'] = _cycles_between(current['start_time_ps'], current['end_time_ps'], clock_period_ps)
                windows.append(current)
            current = {
                'phase': category,
                'start_time_ps': item['time_ps'],
                'last_time_ps': item['time_ps'],
                'start_cycle': _cycle_from_time_ps(item['time_ps'], clock_period_ps),
                'dispatch_count': 0,
                'commit_count': 0,
                'symbols': [],
                'source': 'simv.log:dispatch/commit PC + ELF symbols',
            }
        current['last_time_ps'] = item['time_ps']
        if item['event'] == 'dispatch':
            current['dispatch_count'] += 1
        elif item['event'] == 'commit':
            current['commit_count'] += 1
        if item['symbol'] and item['symbol'] not in current['symbols']:
            current['symbols'].append(item['symbol'])

    if current is not None:
        current['end_time_ps'] = current['last_time_ps'] + clock_period_ps
        current['end_cycle'] = _cycle_from_time_ps(current['end_time_ps'], clock_period_ps)
        current['cycles'] = _cycles_between(current['start_time_ps'], current['end_time_ps'], clock_period_ps)
        windows.append(current)

    return windows


def analyze_kernel_agnostic_phases(fsdb_path=DEFAULT_FSDB, simv_log=DEFAULT_SIMV_LOG,
                                   elf_path=DEFAULT_KERNEL_ELF, paths=DEFAULT_GEMM_PATHS,
                                   clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                   bt=None, et=None, include_instruction_windows=False,
                                   strict=False):
    """Return a time-ordered kernel phase table without GEMM-specific counters."""
    fsdb_path = str(fsdb_path)
    markers = _collect_simv_markers(simv_log)

    schedule = f'{paths.core}/schedule'
    wctl = f'{paths.core}/execute/sfu_unit/wctl_unit'
    lsu = f'{paths.core}/execute/lsu_unit/g_blocks[0]/lsu_slice'

    sig = {
        'core_busy': f'{paths.core}/busy',
        'active_warps': f'{schedule}/active_warps[3:0]',
        'active_warps_cnt': f'{schedule}/active_warps_cnt[2:0]',
        'wctl_is_wspawn': f'{wctl}/is_wspawn',
        'wctl_execute_fire': f'{wctl}/execute_fire',
        'wctl_wspawn_wmask': f'{wctl}/wspawn_wmask[3:0]',
        'fence_lock': f'{lsu}/fence_lock',
        'req_is_fence': f'{lsu}/req_is_fence',
        'rsp_is_fence': f'{lsu}/rsp_is_fence',
        'mem_req_fire': f'{lsu}/mem_req_fire',
        'mem_rsp_fire': f'{lsu}/mem_rsp_fire',
    }

    try:
        report = fsdb.report(fsdb_path, list(sig.values()), bt=bt, et=et)
        fsdb_events = report.events()
    except Exception:
        if strict:
            raise
        fsdb_events = []

    core_windows = _high_windows(fsdb_events, sig['core_busy'])
    core_start, core_end = _first(core_windows) if core_windows else (None, None)

    instruction_events = _parse_simv_instruction_events(
        simv_log,
        elf_path,
        start_time_ps=core_start,
        end_time_ps=core_end,
        strict=strict,
    )
    instruction_events.sort(key=lambda item: (item['time_ps'], item['event']))

    spawn_events = []
    fence_req_times = []
    fence_rsp_times = []
    for ev in fsdb_events:
        if _is_one(ev.values.get(sig['wctl_is_wspawn'], '0')) and _is_one(ev.values.get(sig['wctl_execute_fire'], '0')):
            spawn_events.append({
                'time_ps': ev.time,
                'wspawn_wmask': _parse_sv_int(ev.values.get(sig['wctl_wspawn_wmask'], '0')) or 0,
                'active_warps': _parse_sv_int(ev.values.get(sig['active_warps'], '0')) or 0,
                'active_warps_cnt': _parse_sv_int(ev.values.get(sig['active_warps_cnt'], '0')) or 0,
            })
        if _is_one(ev.values.get(sig['req_is_fence'], '0')) and _is_one(ev.values.get(sig['mem_req_fire'], '0')):
            _unique_append_time(fence_req_times, ev.time)
        if _is_one(ev.values.get(sig['rsp_is_fence'], '0')) and _is_one(ev.values.get(sig['mem_rsp_fire'], '0')):
            _unique_append_time(fence_rsp_times, ev.time)

    spawn_active_times = _find_spawn_active_times(fsdb_events, sig['active_warps'], spawn_events)
    fence_req = _first(fence_req_times)
    fence_rsp = _first(fence_rsp_times)

    first_user = _first_event_time(instruction_events, 'user_kernel')
    last_user = _last_event_time(instruction_events, 'user_kernel')
    first_perf = _first_event_time(instruction_events, 'perf_dump')
    last_perf = _last_event_time(instruction_events, 'perf_dump')
    first_after_user = _first_event_time(instruction_events, after_time_ps=last_user)
    first_exit_final = _first_event_time(instruction_events, 'exit_final')

    rows = []

    def add_phase(phase, start_time_ps, end_time_ps, source, note='', count=None,
                  dispatch_count=None, commit_count=None, symbols=''):
        if start_time_ps is None or end_time_ps is None:
            return
        rows.append({
            'phase': phase,
            'start_time_ps': start_time_ps,
            'end_time_ps': end_time_ps,
            'start_cycle': _cycle_from_time_ps(start_time_ps, clock_period_ps),
            'end_cycle': _cycle_from_time_ps(end_time_ps, clock_period_ps),
            'cycles': _cycles_between(start_time_ps, end_time_ps, clock_period_ps),
            'count': count,
            'dispatch_count': dispatch_count,
            'commit_count': commit_count,
            'symbols': symbols,
            'source': source,
            'note': note,
        })

    add_phase('kernel_busy', core_start, core_end, 'fsdb:core/busy', 'envelope; overlaps all device-side phases')

    tag_init = markers.get('tag_init')
    if tag_init and tag_init['first_time_ps'] is not None:
        add_phase(
            'tag_init',
            tag_init['first_time_ps'],
            tag_init['last_time_ps'] + clock_period_ps,
            'simv.log:tags-init',
            'inclusive log stream converted to exclusive end',
            tag_init['count'],
        )

    if spawn_events:
        spawn_start = spawn_events[0]['time_ps']
        spawn_end = _last([t for t in spawn_active_times if t is not None])
        add_phase(
            'warp_spawn',
            spawn_start,
            spawn_end,
            'fsdb:wctl_is_wspawn&&execute_fire -> active_warps',
            f'{len(spawn_events)} WSPAWN fire events',
            len(spawn_events),
        )

    add_phase(
        'runtime_bootstrap_to_user',
        core_start,
        first_user,
        'fsdb:core/busy -> simv.log first non-runtime ELF symbol',
        'includes reset-visible startup, tag init, WSPAWN, TLS/BSS/libc init',
        dispatch_count=_event_count(instruction_events, 'runtime_bootstrap', 'dispatch'),
        commit_count=_event_count(instruction_events, 'runtime_bootstrap', 'commit'),
        symbols=_symbols_in_window(
            instruction_events,
            core_start,
            None if first_user is None else first_user - 1,
        ),
    )

    add_phase(
        'user_kernel_body',
        first_user,
        None if last_user is None else last_user + clock_period_ps,
        'simv.log user/non-runtime ELF symbols',
        'kernel-specific code; no accelerator-specific counter required',
        dispatch_count=_event_count(instruction_events, 'user_kernel', 'dispatch'),
        commit_count=_event_count(instruction_events, 'user_kernel', 'commit'),
        symbols=_symbols_in_window(instruction_events, first_user, last_user),
    )

    exit_start = first_after_user
    exit_end_candidates = [t for t in (first_exit_final, first_perf, fence_req) if t is not None]
    exit_end = min(exit_end_candidates) if exit_end_candidates else None
    add_phase(
        'runtime_exit',
        exit_start,
        exit_end,
        'simv.log runtime ELF symbols after user kernel',
        'exit wrapper, fini hooks, stdio exit before perf dump',
        dispatch_count=_event_count(instruction_events, 'runtime_exit', 'dispatch'),
        commit_count=_event_count(instruction_events, 'runtime_exit', 'commit'),
        symbols=_symbols_in_window(
            instruction_events,
            exit_start,
            None if exit_end is None else exit_end - 1,
        ),
    )

    add_phase(
        'perf_dump',
        first_perf,
        None if last_perf is None else last_perf + clock_period_ps,
        'simv.log:vx_perf_dump + ELF symbols',
        'MPM/perf CSR reads and stores',
        dispatch_count=_event_count(instruction_events, 'perf_dump', 'dispatch'),
        commit_count=_event_count(instruction_events, 'perf_dump', 'commit'),
        symbols='vx_perf_dump',
    )

    exit_final_start = first_exit_final or (None if last_perf is None else last_perf + clock_period_ps)
    add_phase(
        'exit_final_to_fence',
        exit_final_start,
        fence_req,
        'simv.log:_Exit + fsdb:fence request',
        'exitcode store and fence dispatch/setup',
        dispatch_count=_event_count(instruction_events, 'exit_final', 'dispatch'),
        commit_count=_event_count(instruction_events, 'exit_final', 'commit'),
        symbols='_Exit',
    )

    if fence_req is not None and fence_rsp is not None:
        add_phase(
            'fence_wait',
            fence_req,
            fence_rsp,
            'fsdb:req_is_fence/mem_req_fire -> rsp_is_fence/mem_rsp_fire',
        )

    tag_flush = markers.get('tag_flush')
    if tag_flush and tag_flush['first_time_ps'] is not None:
        add_phase(
            'cache_flush_tags',
            tag_flush['first_time_ps'],
            tag_flush['last_time_ps'] + clock_period_ps,
            'simv.log:tags-flush',
            'overlaps fence_wait in this trace',
            tag_flush['count'],
        )

    data_flush = markers.get('data_flush')
    if data_flush and data_flush['first_time_ps'] is not None:
        add_phase(
            'cache_flush_data',
            data_flush['first_time_ps'],
            data_flush['last_time_ps'] + clock_period_ps,
            'simv.log:data-flush',
            'overlaps fence_wait in this trace',
            data_flush['count'],
        )

    ap_done_pending = markers.get('ap_done_pending')
    ap_done_consumed = markers.get('ap_done_consumed')
    if fence_rsp is not None and ap_done_pending and ap_done_pending['first_time_ps'] is not None:
        add_phase(
            'after_fence_to_ap_done',
            fence_rsp,
            ap_done_pending['first_time_ps'],
            'fsdb:fence_rsp -> simv.log:ap_done pending',
        )
    if ap_done_pending and ap_done_consumed and ap_done_pending['first_time_ps'] is not None:
        add_phase(
            'host_done_polling',
            ap_done_pending['first_time_ps'],
            ap_done_consumed['first_time_ps'],
            'simv.log:ap_done pending -> consumed by host',
        )

    if include_instruction_windows:
        for window in _collapse_instruction_windows(instruction_events, clock_period_ps):
            rows.append({
                'phase': f"instr_{window['phase']}",
                'start_time_ps': window['start_time_ps'],
                'end_time_ps': window['end_time_ps'],
                'start_cycle': window['start_cycle'],
                'end_cycle': window['end_cycle'],
                'cycles': window['cycles'],
                'count': None,
                'dispatch_count': window['dispatch_count'],
                'commit_count': window['commit_count'],
                'symbols': ', '.join(window['symbols']),
                'source': window['source'],
                'note': 'collapsed consecutive instruction-symbol category window',
            })

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(['start_time_ps', 'phase'], na_position='last').reset_index(drop=True)

    print(f'FSDB: {fsdb_path}')
    print(f'simv.log: {simv_log}')
    print(f'ELF: {elf_path}')
    print(f'Window: bt={bt}, et={et}, clock_period_ps={clock_period_ps}')
    return df


def analyze_runtime_phases(*args, **kwargs):
    """Alias for analyze_kernel_agnostic_phases."""
    return analyze_kernel_agnostic_phases(*args, **kwargs)


def analyze_kernel_phases(fsdb_path=DEFAULT_FSDB, simv_log=DEFAULT_SIMV_LOG,
                          paths=DEFAULT_GEMM_PATHS, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                          bt=None, et=None, strict=False):
    """Estimate kernel phase cycles using simv.log markers and FSDB RTL signals.

    The returned phase windows use end_time/end_cycle as exclusive boundaries when
    the source is an RTL high-window or a per-cycle log stream. Some rows overlap
    intentionally, e.g. fence wait and cache flush.
    """
    fsdb_path = str(fsdb_path)
    markers = _collect_simv_markers(simv_log)

    schedule = f'{paths.core}/schedule'
    wctl = f'{paths.core}/execute/sfu_unit/wctl_unit'
    lsu = f'{paths.core}/execute/lsu_unit/g_blocks[0]/lsu_slice'

    sig = {
        'core_busy': f'{paths.core}/busy',
        'active_warps': f'{schedule}/active_warps[3:0]',
        'active_warps_cnt': f'{schedule}/active_warps_cnt[2:0]',
        'wctl_is_wspawn': f'{wctl}/is_wspawn',
        'wctl_execute_fire': f'{wctl}/execute_fire',
        'wctl_wspawn_wmask': f'{wctl}/wspawn_wmask[3:0]',
        'fence_lock': f'{lsu}/fence_lock',
        'req_is_fence': f'{lsu}/req_is_fence',
        'rsp_is_fence': f'{lsu}/rsp_is_fence',
        'mem_req_fire': f'{lsu}/mem_req_fire',
        'mem_rsp_fire': f'{lsu}/mem_rsp_fire',
        'gemm_total': _perf_vec(paths.gemm_ctrl, 'perf_total_cycles_r'),
        'gemm_compute': _perf_vec(paths.gemm_unit, 'perf_compute_r'),
    }

    try:
        report = fsdb.report(fsdb_path, list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        events = []

    core_windows = _high_windows(events, sig['core_busy'])
    fence_lock_windows = _high_windows(events, sig['fence_lock'])

    spawn_events = []
    fence_req_times = []
    fence_rsp_times = []
    for ev in events:
        if _is_one(ev.values.get(sig['wctl_is_wspawn'], '0')) and _is_one(ev.values.get(sig['wctl_execute_fire'], '0')):
            spawn_events.append({
                'time_ps': ev.time,
                'wspawn_wmask': _parse_sv_int(ev.values.get(sig['wctl_wspawn_wmask'], '0')) or 0,
                'active_warps': _parse_sv_int(ev.values.get(sig['active_warps'], '0')) or 0,
                'active_warps_cnt': _parse_sv_int(ev.values.get(sig['active_warps_cnt'], '0')) or 0,
            })
        if _is_one(ev.values.get(sig['req_is_fence'], '0')) and _is_one(ev.values.get(sig['mem_req_fire'], '0')):
            _unique_append_time(fence_req_times, ev.time)
        if _is_one(ev.values.get(sig['rsp_is_fence'], '0')) and _is_one(ev.values.get(sig['mem_rsp_fire'], '0')):
            _unique_append_time(fence_rsp_times, ev.time)

    spawn_active_times = _find_spawn_active_times(events, sig['active_warps'], spawn_events)
    gemm_total_first = _first_nonzero_time(events, sig['gemm_total'])
    gemm_total_last = _last_counter_change_time(events, sig['gemm_total'])
    gemm_compute_first = _first_nonzero_time(events, sig['gemm_compute'])
    gemm_compute_last = _last_counter_change_time(events, sig['gemm_compute'])

    rows = []

    def add_phase(phase, start_time_ps, end_time_ps, source, note='', count=None):
        rows.append({
            'phase': phase,
            'start_time_ps': start_time_ps,
            'end_time_ps': end_time_ps,
            'start_cycle': _cycle_from_time_ps(start_time_ps, clock_period_ps),
            'end_cycle': _cycle_from_time_ps(end_time_ps, clock_period_ps),
            'cycles': _cycles_between(start_time_ps, end_time_ps, clock_period_ps),
            'count': count,
            'source': source,
            'note': note,
        })

    core_start, core_end = _first(core_windows) if core_windows else (None, None)
    add_phase('kernel_busy', core_start, core_end, 'fsdb:core/busy')

    tag_init = markers.get('tag_init')
    if tag_init and tag_init['first_time_ps'] is not None:
        add_phase(
            'tag_init',
            tag_init['first_time_ps'],
            tag_init['last_time_ps'] + clock_period_ps,
            'simv.log:tags-init',
            'inclusive log stream converted to exclusive end',
            tag_init['count'],
        )

    if spawn_events:
        first_spawn = spawn_events[0]['time_ps']
        last_active = _last([t for t in spawn_active_times if t is not None])
        add_phase(
            'warp_spawn',
            first_spawn,
            last_active,
            'fsdb:wctl_is_wspawn&&execute_fire -> active_warps',
            f'{len(spawn_events)} WSPAWN fire events',
            len(spawn_events),
        )

    if core_start is not None and gemm_total_first is not None:
        add_phase(
            'front_end_before_gemm',
            core_start,
            gemm_total_first,
            'fsdb:core/busy -> gemm_total first increment',
            'includes tag init, warp spawn, instruction/control overhead',
        )

    if gemm_total_first is not None and gemm_total_last is not None:
        add_phase(
            'kernel_run_gemm_total',
            gemm_total_first,
            gemm_total_last + clock_period_ps,
            'fsdb:gemm_ctrl/perf_total_cycles_r',
        )

    if gemm_compute_first is not None and gemm_compute_last is not None:
        add_phase(
            'kernel_run_gemm_compute',
            gemm_compute_first,
            gemm_compute_last + clock_period_ps,
            'fsdb:gemm_unit/perf_compute_r',
        )

    fence_req = _first(fence_req_times)
    fence_rsp = _first(fence_rsp_times)
    if gemm_total_last is not None and fence_req is not None:
        add_phase(
            'post_gemm_before_fence',
            gemm_total_last + clock_period_ps,
            fence_req,
            'fsdb:gemm_total last increment -> fence request',
        )

    if fence_req is not None and fence_rsp is not None:
        add_phase(
            'fence_wait',
            fence_req,
            fence_rsp,
            'fsdb:req_is_fence/mem_req_fire -> rsp_is_fence/mem_rsp_fire',
        )

    if fence_lock_windows:
        start, end = fence_lock_windows[0]
        add_phase('fence_lock_high', start, end, 'fsdb:lsu/fence_lock')

    tag_flush = markers.get('tag_flush')
    if tag_flush and tag_flush['first_time_ps'] is not None:
        add_phase(
            'cache_flush_tags',
            tag_flush['first_time_ps'],
            tag_flush['last_time_ps'] + clock_period_ps,
            'simv.log:tags-flush',
            'overlaps fence_wait in this trace',
            tag_flush['count'],
        )

    data_flush = markers.get('data_flush')
    if data_flush and data_flush['first_time_ps'] is not None:
        add_phase(
            'cache_flush_data',
            data_flush['first_time_ps'],
            data_flush['last_time_ps'] + clock_period_ps,
            'simv.log:data-flush',
            'overlaps fence_wait in this trace',
            data_flush['count'],
        )

    ap_done_pending = markers.get('ap_done_pending')
    ap_done_consumed = markers.get('ap_done_consumed')
    if fence_rsp is not None and ap_done_pending and ap_done_pending['first_time_ps'] is not None:
        add_phase(
            'after_fence_to_ap_done',
            fence_rsp,
            ap_done_pending['first_time_ps'],
            'fsdb:fence_rsp -> simv.log:ap_done pending',
        )
    if ap_done_pending and ap_done_consumed and ap_done_pending['first_time_ps'] is not None:
        add_phase(
            'done_polling',
            ap_done_pending['first_time_ps'],
            ap_done_consumed['first_time_ps'],
            'simv.log:ap_done pending -> consumed by host',
        )

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(['start_time_ps', 'phase'], na_position='last').reset_index(drop=True)

    print(f'FSDB: {fsdb_path}')
    print(f'simv.log: {simv_log}')
    print(f'Window: bt={bt}, et={et}, clock_period_ps={clock_period_ps}')
    return df


def _resolve_sync_base(paths):
    if isinstance(paths, GemmTracePaths):
        return paths.gemm_sync
    return str(paths)


def analyze_sync_wait(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS, bt=None, et=None, top_n=None):
    """Count cycles spent in dbg_wait_active, grouped by wait_reg_id.

    A cycle is counted on a clk rising edge when dbg_wait_active is 1.
    The wait_reg_id value sampled at the same edge is used as the bucket.
    """
    fsdb_path = str(fsdb_path)
    sync_base = _resolve_sync_base(paths)
    clk = f'{sync_base}/clk'
    wait_active = f'{sync_base}/dbg_wait_active'
    wait_reg_id = f'{sync_base}/wait_reg_id[7:0]'

    report = fsdb.report(fsdb_path, [clk, wait_active, wait_reg_id], bt=bt, et=et)
    events = report.events()

    counts = defaultdict(int)
    first_time = {}
    last_time = {}
    active_windows = defaultdict(int)
    prev_clk = '0'
    prev_active_key = None

    for ev in events:
        clk_value = ev.values.get(clk, '0')
        active = _is_one(ev.values.get(wait_active, '0'))
        reg_id = _parse_sv_int(ev.values.get(wait_reg_id, '0'))

        active_key = reg_id if active and reg_id is not None else None
        if active_key is not None and active_key != prev_active_key:
            active_windows[reg_id] += 1

        if _is_one(clk_value) and not _is_one(prev_clk) and active and reg_id is not None:
            counts[reg_id] += 1
            first_time.setdefault(reg_id, ev.time)
            last_time[reg_id] = ev.time

        prev_clk = clk_value
        prev_active_key = active_key

    total_cycles = sum(counts.values())
    rows = []
    for reg_id, cycles in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        rows.append({
            'wait_reg_id': reg_id,
            'wait_reg_name': SyncRegID.name_from_int(reg_id),
            'cycles': cycles,
            'pct': 0.0 if total_cycles == 0 else cycles / total_cycles * 100.0,
            'active_windows': active_windows.get(reg_id, 0),
            f'first_time_{report.time_unit}': first_time.get(reg_id),
            f'last_time_{report.time_unit}': last_time.get(reg_id),
        })

    df = pd.DataFrame(rows)
    if top_n is not None:
        df = df.head(top_n)

    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}, time_unit={report.time_unit}')
    print(f'total_wait_active_cycles={total_cycles}')
    return df

def analyze_mxu_input(fsdb_path):
    pass

import argparse
import csv
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict, deque
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

DEFAULT_FSDB = REPO_ROOT / 'build/logs/fpint_naive_m1_k256_n256/xrtsim_vcs/vcs_cosim.fsdb'
DEFAULT_SIMV_LOG = DEFAULT_FSDB.with_name('simv.log')
DEFAULT_KERNEL_ELF = REPO_ROOT / 'build/tests/regression/fpint_gemm_ffn_hw/kernel.elf'
DEFAULT_TCU_KERNEL_ELF = REPO_ROOT / 'build/tests/regression/sgemm_tcu/kernel.elf'
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
    """Centralized FSDB hierarchy paths for fpint_naive GEMM cycle analysis."""

    repo_root: Path = REPO_ROOT
    fsdb_path: Path = DEFAULT_FSDB
    tb_root: str = '/tb_vcs_xrtsim/dut/vortex_axi/vortex'
    cluster_id: int = 0
    socket_id: int = 0
    core_id: int = 0
    child_count: int = 5

    def sig(self, base, name):
        return f'{base}/{name}'

    def vec(self, base, name, msb, lsb=0):
        return f'{base}/{name}[{msb}:{lsb}]'

    @property
    def tb(self):
        return '/' + self.tb_root.strip('/').split('/', 1)[0]

    @property
    def cluster(self):
        return f'{self.tb_root}/g_clusters[{self.cluster_id}]/cluster'

    @property
    def socket(self):
        return (
            f'{self.cluster}'
            f'/g_sockets[{self.socket_id}]/socket'
        )

    @property
    def core(self):
        return (
            f'{self.socket}'
            f'/g_cores[{self.core_id}]/core'
        )

    @property
    def gemm_node(self):
        return f'{self.core}/gemm_node'

    @property
    def dcache_dma_unit(self):
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
        return f'{self.gemm_node}/u_VX_gemm_dma_ctrl'

    @property
    def input_lmem_dma(self):
        return f'{self.gemm_node}/u_input_lmem_dma'

    @property
    def weight_lmem_dma(self):
        return f'{self.gemm_node}/u_weight_lmem_dma'

    @property
    def quant_param_lmem_dma(self):
        return f'{self.gemm_node}/u_quant_param_lmem_dma'

    @property
    def output_lmem_dma(self):
        return f'{self.gemm_node}/u_output_lmem_dma'

    @property
    def lmem_dmas(self):
        return {
            'input': self.input_lmem_dma,
            'weight': self.weight_lmem_dma,
            'quant_param': self.quant_param_lmem_dma,
            'output': self.output_lmem_dma,
        }

    @property
    def tcu_unit(self):
        return f'{self.core}/execute/tcu_unit'

    @property
    def local_mem(self):
        return f'{self.core}/mem_unit/local_mem'

    @property
    def l1_icache_perf(self):
        return f'{self.socket}/icache/g_cache_wrap[0]/cache_wrap/g_cache/cache'

    @property
    def l1_dcache_perf(self):
        return f'{self.socket}/dcache/g_cache_wrap[0]/cache_wrap/g_cache/cache'

    @property
    def l2cache_perf(self):
        return f'{self.cluster}/l2cache/g_cache/cache'

    @property
    def hbm_axi(self):
        return self.tb


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
    'wait_dcache': ('WAIT_DCACHE', 'perf_wait_dcache_r'),
    'wait_lmem': ('WAIT_LMEM', 'perf_wait_lmem_r'),
    'src_rd_req_fire': ('SRC_RD_REQ_FIRE', 'perf_src_rd_req_fire_r'),
    'src_rd_req_stall': ('SRC_RD_REQ_STALL', 'perf_src_rd_req_stall_r'),
    'src_rd_data_fire': ('SRC_RD_DATA_FIRE', 'perf_src_rd_data_fire_r'),
    'src_rd_data_stall': ('SRC_RD_DATA_STALL', 'perf_src_rd_data_stall_r'),
    'dst_wr_fire': ('DST_WR_FIRE', 'perf_dst_wr_fire_r'),
    'dst_wr_stall': ('DST_WR_STALL', 'perf_dst_wr_stall_r'),
}

DCACHE_DMA_COUNTER_PREFIX = 'VX_CSR_MPM_DMA'

GEMM_NODE_COUNTER_REGS = {
    'gemm_total_cycles': ('VX_CSR_MPM_GEMM_TOTAL_CYC', 'perf_total_cycles_r', 'gemm_ctrl'),
    'lmem_rd_bytes': ('VX_CSR_MPM_LMEM_RD_BYTES', 'perf_lmem_rd_r', 'gemm_node'),
    'lmem_wr_bytes': ('VX_CSR_MPM_LMEM_WR_BYTES', 'perf_lmem_wr_r', 'gemm_node'),
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


def _mask_sv_int(value, width=None):
    if value is None:
        return 0
    try:
        parsed = _parse_sv_int(value)
    except Exception:
        return 0
    if parsed is None:
        return 0
    if width is not None:
        parsed &= (1 << width) - 1
    return parsed


def _popcount_sv_int(value, width=None):
    return _mask_sv_int(value, width).bit_count()


def _iter_set_bits(mask, width):
    for bit in range(width):
        if mask & (1 << bit):
            yield bit


def _cycle_mask_map(events, signal, width=None, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    """Return {cycle: mask} for every cycle where a vector/scalar signal is nonzero."""
    cycle_masks = defaultdict(int)
    if not events:
        return cycle_masks

    for idx, ev in enumerate(events):
        mask = _mask_sv_int(ev.values.get(signal, '0'), width)
        if mask == 0:
            continue
        start_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        if idx + 1 < len(events):
            end_cycle = _cycle_from_time_ps(events[idx + 1].time, clock_period_ps)
        else:
            end_cycle = start_cycle + 1
        if end_cycle <= start_cycle:
            end_cycle = start_cycle + 1
        for cycle in range(start_cycle, end_cycle):
            cycle_masks[cycle] |= mask
    return cycle_masks


def _cycles_from_mask_map(cycle_masks):
    return sorted(cycle for cycle, mask in cycle_masks.items() if mask)


def _event_count_from_mask_map(cycle_masks):
    return sum(mask.bit_count() for mask in cycle_masks.values())


def _counter_delta_from_events(events, signal):
    values = []
    for ev in events:
        raw = ev.values.get(signal)
        if raw is None:
            continue
        try:
            values.append(_parse_sv_int(raw))
        except Exception:
            continue
    values = [value for value in values if value is not None]
    if not values:
        return 0
    return max(0, values[-1] - values[0])


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
    """Return preset interval-analysis signals for dcache DMA, LDMA, and MXU streams.

    kind='fire' uses valid&&ready event wires where available.
    kind='valid' uses request/response valid wires for LDMA and MXU bus streams.
    """
    groups = {'dcache_dma', 'ldma', 'mxu'} if groups is None else set(groups)
    if 'dma' in groups:
        groups.remove('dma')
        groups.add('dcache_dma')
    specs = []

    if 'dcache_dma' in groups:
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
            specs.append(IntervalSignalSpec('dcache_dma', stream, f'{paths.dcache_dma_unit}/{sig}', 'fire', dma_note))

    if 'ldma' in groups:
        input_side = {
            'src_rd_req': ('lmem_bus_if.req_valid', 'lmem_req_fire'),
            'src_rd_data': ('lmem_bus_if.rsp_valid', 'lmem_rsp_fire'),
            'dst_wr': ('gemm_bus_if.req_valid', 'gemm_req_fire'),
        }
        output_side = {
            'src_rd_req': ('gemm_bus_if.req_valid', 'gemm_req_fire'),
            'src_rd_data': ('gemm_bus_if.rsp_valid', 'gemm_rsp_fire'),
            'dst_wr': ('lmem_bus_if.req_valid', 'lmem_req_fire'),
        }
        for ldma_name, base in paths.lmem_dmas.items():
            section = f'ldma_{ldma_name if ldma_name != "quant_param" else "sz"}'
            stream_map = output_side if ldma_name == 'output' else input_side
            for stream, (valid_sig, fire_sig) in stream_map.items():
                signal_name = valid_sig if kind == 'valid' else fire_sig
                note = 'DIR=1 GEMM->LMEM' if ldma_name == 'output' else 'DIR=0 LMEM->GEMM'
                specs.append(IntervalSignalSpec(section, stream, f'{base}/{signal_name}', kind, note))

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


def build_mpm_accel_counters(paths=DEFAULT_GEMM_PATHS):
    counters = []
    counters.append(MpmCounter(
        MpmAccelClass.ACCEL_MXU,
        'VX_CSR_MPM_BUSY_CYC',
        'busy_cycles',
        _perf_vec(paths.core, 'perf_busy_r'),
    ))
    for name, (csr, reg, owner) in GEMM_NODE_COUNTER_REGS.items():
        base = paths.gemm_ctrl if owner == 'gemm_ctrl' else paths.gemm_node
        counters.append(MpmCounter(MpmAccelClass.ACCEL_MXU, csr, name, _perf_vec(base, reg)))
    for name, (csr, reg) in MXU_COUNTER_REGS.items():
        counters.append(MpmCounter(MpmAccelClass.ACCEL_MXU, csr, name, _perf_vec(paths.gemm_unit, reg)))
    counters.append(MpmCounter(
        MpmAccelClass.ACCEL_MXU,
        'VX_CSR_MPM_OVERLAP_DMA_MXU',
        'overlap_dma_mxu',
        _perf_vec(paths.core, 'perf_overlap_r'),
    ))

    for name, (csr_suffix, reg) in DMA_COUNTER_REGS.items():
        counters.append(MpmCounter(
            MpmAccelClass.ACCEL_DMA,
            f'{DCACHE_DMA_COUNTER_PREFIX}_{csr_suffix}',
            f'dcache_dma_{name}',
            _perf_vec(paths.dcache_dma_unit, reg),
        ))

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
    """Return runtime-style derived metrics for fpint_naive MXU and dcache DMA counters."""
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
    add('mxu', 'lmem_rd_bytes', values.get('lmem_rd_bytes', 0), 'bytes')
    add('mxu', 'lmem_wr_bytes', values.get('lmem_wr_bytes', 0), 'bytes')
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

    prefix = 'dcache_dma'
    rd = values.get(f'{prefix}_rd_bytes', 0)
    wr = values.get(f'{prefix}_wr_bytes', 0)
    active = values.get(f'{prefix}_active_cycles', 0)
    bytes_total = rd + wr
    add(prefix, 'rd_bytes', rd, 'bytes')
    add(prefix, 'wr_bytes', wr, 'bytes')
    add(prefix, 'global_dma_bytes', bytes_total, 'bytes')
    add(prefix, 'xfer_count', values.get(f'{prefix}_xfer_count', 0), 'count')
    add(prefix, 'active_cycles', active, 'cycles')
    add(prefix, 'wait_dcache', values.get(f'{prefix}_wait_dcache', 0), 'cycles')
    add(prefix, 'wait_lmem', values.get(f'{prefix}_wait_lmem', 0), 'cycles')
    add(prefix, 'util_pct_busy', _pct(active, busy), 'pct')
    add(prefix, 'util_pct_total', _pct(active, total), 'pct')
    add(prefix, 'bandwidth_bytes_per_active_cycle', _ratio(bytes_total, active), 'B/cycle')
    add(prefix, 'bandwidth_bytes_per_busy_cycle', _ratio(bytes_total, busy), 'B/cycle')
    for event in ('src_rd_req', 'src_rd_data', 'dst_wr'):
        fire = values.get(f'{prefix}_{event}_fire', 0)
        stall = values.get(f'{prefix}_{event}_stall', 0)
        add(prefix, f'{event}_fire', fire, 'count')
        add(prefix, f'{event}_stall', stall, 'count')
        add(prefix, f'{event}_util_pct_active', _pct(fire, active), 'pct')
        add(prefix, f'{event}_stall_pct_activity', _pct(stall, fire + stall), 'pct')

    lmem_total = values.get('lmem_rd_bytes', 0) + values.get('lmem_wr_bytes', 0)
    add('roofline', 'flops', flops, 'flop')
    add('roofline', 'global_dma_bytes', bytes_total, 'bytes')
    add('roofline', 'lmem_bytes', lmem_total, 'bytes')
    add('roofline', 'operational_intensity_global_dma', _ratio(flops, bytes_total), 'flop/byte')
    add('roofline', 'achieved_flops_per_cycle_total', _ratio(flops, total), 'flop/cycle')
    add('roofline', 'global_dma_bandwidth_bytes_per_cycle', _ratio(bytes_total, total), 'B/cycle')
    add('roofline', 'lmem_bandwidth_bytes_per_cycle', _ratio(lmem_total, total), 'B/cycle')

    df = pd.DataFrame(rows)
    print(f'FSDB: {fsdb_path}')
    print(f'Window: bt={bt}, et={et}')
    return df


def _phase_metric(phases, phase, column, default=0):
    if phases is None or phases.empty or column not in phases.columns:
        return default
    values = phases.loc[phases['phase'] == phase, column]
    if values.empty or pd.isna(values.iloc[0]):
        return default
    return values.iloc[0]


def _phase_time_window(phases, phase='user_kernel_body', clock_period_ps=DEFAULT_CLOCK_PERIOD_PS):
    start = _phase_metric(phases, phase, 'start_time_ps', None)
    end = _phase_metric(phases, phase, 'end_time_ps', None)
    if start is None or end is None:
        start_cycle = _phase_metric(phases, phase, 'start_cycle', None)
        end_cycle = _phase_metric(phases, phase, 'end_cycle', None)
        if start_cycle is not None and end_cycle is not None:
            start = int(start_cycle) * clock_period_ps
            end = int(end_cycle) * clock_period_ps
    if start is None or end is None:
        return None, None
    return f'{int(start)}ps', f'{int(end)}ps'


def _phase_cycles(phases, phase, default=0):
    value = _phase_metric(phases, phase, 'cycles', default)
    return default if value is None else int(value)


def _add_ratio_rows(rows, section, active_cycles, bytes_total, busy_cycles, user_cycles):
    rows.extend([
        {'section': section, 'metric': 'active_cycles', 'value': active_cycles, 'unit': 'cycles'},
        {'section': section, 'metric': 'active_pct_busy', 'value': _pct(active_cycles, busy_cycles), 'unit': 'pct'},
        {'section': section, 'metric': 'active_pct_user_kernel_body', 'value': _pct(active_cycles, user_cycles), 'unit': 'pct'},
        {'section': section, 'metric': 'bandwidth_bytes_per_active_cycle', 'value': _ratio(bytes_total, active_cycles), 'unit': 'B/cycle'},
        {'section': section, 'metric': 'bandwidth_bytes_per_busy_cycle', 'value': _ratio(bytes_total, busy_cycles), 'unit': 'B/cycle'},
        {'section': section, 'metric': 'bandwidth_bytes_per_user_cycle', 'value': _ratio(bytes_total, user_cycles), 'unit': 'B/cycle'},
    ])


def _add_latency_rows(rows, section, prefix, latencies):
    latencies = sorted(value for value in latencies if value is not None)
    rows.extend([
        {'section': section, 'metric': f'{prefix}_latency_count', 'value': len(latencies), 'unit': 'count'},
        {'section': section, 'metric': f'{prefix}_latency_mean', 'value': _mean(latencies), 'unit': 'cycles'},
        {'section': section, 'metric': f'{prefix}_latency_p50', 'value': _percentile(latencies, 50), 'unit': 'cycles'},
        {'section': section, 'metric': f'{prefix}_latency_p90', 'value': _percentile(latencies, 90), 'unit': 'cycles'},
        {'section': section, 'metric': f'{prefix}_latency_p99', 'value': _percentile(latencies, 99), 'unit': 'cycles'},
        {'section': section, 'metric': f'{prefix}_latency_max', 'value': max(latencies) if latencies else 0, 'unit': 'cycles'},
    ])


def _add_interval_rows(rows, section, prefix, cycles):
    summary = _interval_summary_from_cycles(cycles)
    for key in ('event_count', 'mean_interval', 'p50_interval', 'p90_interval',
                'p99_interval', 'max_interval', 'max_burst_len',
                'consecutive_interval_pct'):
        unit = 'cycles' if 'interval' in key else ('pct' if key.endswith('_pct') else 'count')
        value = summary.get(key)
        rows.append({
            'section': section,
            'metric': f'{prefix}_{key}',
            'value': 0 if value is None else value,
            'unit': unit,
        })


def _analyze_hbm_axi_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles,
                             clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    section = 'hbm_axi'
    rows = []
    base = paths.hbm_axi
    sig = {
        'awvalid': f'{base}/m_axi_mem_awvalid[0]',
        'awready': f'{base}/m_axi_mem_awready[0]',
        'awlen': f'{base}/m_axi_mem_awlen[0][7:0]',
        'wvalid': f'{base}/m_axi_mem_wvalid[0]',
        'wready': f'{base}/m_axi_mem_wready[0]',
        'wstrb': f'{base}/m_axi_mem_wstrb[0][63:0]',
        'arvalid': f'{base}/m_axi_mem_arvalid[0]',
        'arready': f'{base}/m_axi_mem_arready[0]',
        'arlen': f'{base}/m_axi_mem_arlen[0][7:0]',
        'rvalid': f'{base}/m_axi_mem_rvalid[0]',
        'rready': f'{base}/m_axi_mem_rready[0]',
        'rlast': f'{base}/m_axi_mem_rlast[0]',
        'bvalid': f'{base}/m_axi_mem_bvalid[0]',
        'bready': f'{base}/m_axi_mem_bready[0]',
    }
    try:
        report = fsdb.report(str(fsdb_path), list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return pd.DataFrame()

    aw_cycles, w_cycles, ar_cycles, r_cycles, b_cycles = [], [], [], [], []
    read_latencies, write_latencies = [], []
    read_bytes = 0
    write_bytes = 0
    pending_reads = deque()
    active_read = None
    pending_writes = deque()
    aw_seen, w_seen, ar_seen, r_seen, b_seen = set(), set(), set(), set(), set()

    for ev in events:
        cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        aw_fire = _is_one(ev.values.get(sig['awvalid'], '0')) and _is_one(ev.values.get(sig['awready'], '0'))
        w_fire = _is_one(ev.values.get(sig['wvalid'], '0')) and _is_one(ev.values.get(sig['wready'], '0'))
        ar_fire = _is_one(ev.values.get(sig['arvalid'], '0')) and _is_one(ev.values.get(sig['arready'], '0'))
        r_fire = _is_one(ev.values.get(sig['rvalid'], '0')) and _is_one(ev.values.get(sig['rready'], '0'))
        b_fire = _is_one(ev.values.get(sig['bvalid'], '0')) and _is_one(ev.values.get(sig['bready'], '0'))

        if aw_fire and cycle not in aw_seen:
            aw_seen.add(cycle)
            aw_cycles.append(cycle)
            pending_writes.append(cycle)
        if w_fire and cycle not in w_seen:
            w_seen.add(cycle)
            w_cycles.append(cycle)
            strobe_bytes = _popcount_sv_int(ev.values.get(sig['wstrb'], '0'), 64)
            write_bytes += strobe_bytes if strobe_bytes else 64
        if ar_fire and cycle not in ar_seen:
            ar_seen.add(cycle)
            ar_cycles.append(cycle)
            pending_reads.append({
                'cycle': cycle,
                'beats_remaining': _mask_sv_int(ev.values.get(sig['arlen'], '0'), 8) + 1,
            })
        if r_fire and cycle not in r_seen:
            r_seen.add(cycle)
            r_cycles.append(cycle)
            read_bytes += 64
            if active_read is None and pending_reads:
                active_read = pending_reads.popleft()
                read_latencies.append(cycle - active_read['cycle'])
            if active_read is not None:
                active_read['beats_remaining'] -= 1
                if _is_one(ev.values.get(sig['rlast'], '0')) or active_read['beats_remaining'] <= 0:
                    active_read = None
        if b_fire and cycle not in b_seen:
            b_seen.add(cycle)
            b_cycles.append(cycle)
            if pending_writes:
                write_latencies.append(cycle - pending_writes.popleft())

    active_cycles = len(set(aw_cycles + w_cycles + ar_cycles + r_cycles + b_cycles))
    total_bytes = read_bytes + write_bytes
    rows.extend([
        {'section': section, 'metric': 'read_bytes', 'value': read_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'write_bytes', 'value': write_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'total_bytes', 'value': total_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'read_req_count', 'value': len(ar_cycles), 'unit': 'count'},
        {'section': section, 'metric': 'read_rsp_count', 'value': len(r_cycles), 'unit': 'count'},
        {'section': section, 'metric': 'write_addr_count', 'value': len(aw_cycles), 'unit': 'count'},
        {'section': section, 'metric': 'write_data_count', 'value': len(w_cycles), 'unit': 'count'},
        {'section': section, 'metric': 'write_rsp_count', 'value': len(b_cycles), 'unit': 'count'},
    ])
    _add_ratio_rows(rows, section, active_cycles, total_bytes, busy_cycles, user_cycles)
    _add_latency_rows(rows, section, 'read', read_latencies)
    _add_latency_rows(rows, section, 'write', write_latencies)
    for prefix, cycles in (
        ('read_req', ar_cycles),
        ('read_rsp', r_cycles),
        ('write_addr', aw_cycles),
        ('write_data', w_cycles),
        ('write_rsp', b_cycles),
    ):
        _add_interval_rows(rows, section, prefix, cycles)
    return pd.DataFrame(rows)


def _analyze_dcache_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles,
                            clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    section = 'dcache'
    rows = []
    sig = {
        'rd_req': f'{paths.core}/perf_dcache_rd_req_fire[7:0]',
        'wr_req': f'{paths.core}/perf_dcache_wr_req_fire[7:0]',
        'rsp': f'{paths.core}/perf_dcache_rsp_fire[7:0]',
        'loads': _perf_vec(paths.core, 'perf_loads'),
        'stores': _perf_vec(paths.core, 'perf_stores'),
        'lat': _perf_vec(paths.core, 'perf_dcache_lat'),
    }
    try:
        report = fsdb.report(str(fsdb_path), list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return pd.DataFrame()

    rd_map = _cycle_mask_map(events, sig['rd_req'], width=8, clock_period_ps=clock_period_ps)
    wr_map = _cycle_mask_map(events, sig['wr_req'], width=8, clock_period_ps=clock_period_ps)
    rsp_map = _cycle_mask_map(events, sig['rsp'], width=8, clock_period_ps=clock_period_ps)
    rd_cycles = _cycles_from_mask_map(rd_map)
    wr_cycles = _cycles_from_mask_map(wr_map)
    rsp_cycles = _cycles_from_mask_map(rsp_map)
    rd_events = _event_count_from_mask_map(rd_map)
    wr_events = _event_count_from_mask_map(wr_map)
    rsp_events = _event_count_from_mask_map(rsp_map)
    read_bytes = rd_events * 8
    write_bytes = wr_events * 8
    total_bytes = read_bytes + write_bytes

    pending = [deque() for _ in range(8)]
    latencies = []
    for cycle in sorted(set(rd_map) | set(rsp_map)):
        for lane in _iter_set_bits(rd_map.get(cycle, 0), 8):
            pending[lane].append(cycle)
        for lane in _iter_set_bits(rsp_map.get(cycle, 0), 8):
            if pending[lane]:
                latencies.append(cycle - pending[lane].popleft())

    loads_delta = _counter_delta_from_events(events, sig['loads'])
    stores_delta = _counter_delta_from_events(events, sig['stores'])
    latency_delta = _counter_delta_from_events(events, sig['lat'])
    active_cycles = len(set(rd_cycles + wr_cycles + rsp_cycles))

    rows.extend([
        {'section': section, 'metric': 'read_bytes', 'value': read_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'write_bytes', 'value': write_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'total_bytes', 'value': total_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'read_req_count', 'value': rd_events, 'unit': 'count'},
        {'section': section, 'metric': 'write_req_count', 'value': wr_events, 'unit': 'count'},
        {'section': section, 'metric': 'rsp_count', 'value': rsp_events, 'unit': 'count'},
        {'section': section, 'metric': 'perf_loads_delta', 'value': loads_delta, 'unit': 'count'},
        {'section': section, 'metric': 'perf_stores_delta', 'value': stores_delta, 'unit': 'count'},
        {'section': section, 'metric': 'perf_avg_load_latency', 'value': _ratio(latency_delta, loads_delta), 'unit': 'cycles'},
    ])
    _add_ratio_rows(rows, section, active_cycles, total_bytes, busy_cycles, user_cycles)
    _add_latency_rows(rows, section, 'read', latencies)
    for prefix, cycles in (
        ('read_req', rd_cycles),
        ('write_req', wr_cycles),
        ('rsp', rsp_cycles),
    ):
        _add_interval_rows(rows, section, prefix, cycles)
    return pd.DataFrame(rows)


def _cache_counter_unavailable_rows(section):
    rows = [
        {'section': section, 'metric': 'cache_enabled', 'value': 0, 'unit': 'bool'},
        {'section': section, 'metric': 'hit_rate_available', 'value': 0, 'unit': 'bool'},
        {'section': section, 'metric': 'read_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'write_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'total_access_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'read_miss_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'write_miss_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'total_miss_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'read_hit_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'write_hit_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'total_hit_count', 'value': 0, 'unit': 'count'},
        {'section': section, 'metric': 'read_hit_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'write_hit_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'overall_hit_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'read_miss_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'write_miss_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'overall_miss_rate_pct', 'value': 0.0, 'unit': 'pct'},
        {'section': section, 'metric': 'mshr_stalls_delta', 'value': 0, 'unit': 'cycles'},
        {'section': section, 'metric': 'mem_stalls_delta', 'value': 0, 'unit': 'cycles'},
        {'section': section, 'metric': 'crsp_stalls_delta', 'value': 0, 'unit': 'cycles'},
    ]
    return pd.DataFrame(rows)


def _analyze_cache_counter_metrics(fsdb_path, section, base, bt, et, strict=False):
    """Measure cache hit/miss counters from VX_cache PERF counters.

    This is intentionally separate from the core-side dcache LSU metric above.
    The dcache metric measures request/response traffic and latency at the core
    interface. This function reads cache-local cumulative counters, so it can
    report hit rate only when a real VX_cache instance exists in the FSDB.
    """
    sig = {
        'reads': _perf_vec(base, 'perf_core_reads'),
        'writes': _perf_vec(base, 'perf_core_writes'),
        'read_misses': _perf_vec(base, 'perf_read_misses'),
        'write_misses': _perf_vec(base, 'perf_write_misses'),
        'mshr_stalls': _perf_vec(base, 'perf_mshr_stalls'),
        'mem_stalls': _perf_vec(base, 'perf_mem_stalls'),
        'crsp_stalls': _perf_vec(base, 'perf_crsp_stalls'),
    }
    try:
        report = fsdb.report(str(fsdb_path), list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return _cache_counter_unavailable_rows(section)

    values = {name: _counter_delta_from_events(events, signal) for name, signal in sig.items()}
    reads = values['reads']
    writes = values['writes']
    read_misses = values['read_misses']
    write_misses = values['write_misses']
    read_hits = max(0, reads - read_misses)
    write_hits = max(0, writes - write_misses)
    total_access = reads + writes
    total_misses = read_misses + write_misses
    total_hits = read_hits + write_hits

    rows = [
        {'section': section, 'metric': 'cache_enabled', 'value': 1, 'unit': 'bool'},
        {'section': section, 'metric': 'hit_rate_available', 'value': 1, 'unit': 'bool'},
        {'section': section, 'metric': 'read_count', 'value': reads, 'unit': 'count'},
        {'section': section, 'metric': 'write_count', 'value': writes, 'unit': 'count'},
        {'section': section, 'metric': 'total_access_count', 'value': total_access, 'unit': 'count'},
        {'section': section, 'metric': 'read_miss_count', 'value': read_misses, 'unit': 'count'},
        {'section': section, 'metric': 'write_miss_count', 'value': write_misses, 'unit': 'count'},
        {'section': section, 'metric': 'total_miss_count', 'value': total_misses, 'unit': 'count'},
        {'section': section, 'metric': 'read_hit_count', 'value': read_hits, 'unit': 'count'},
        {'section': section, 'metric': 'write_hit_count', 'value': write_hits, 'unit': 'count'},
        {'section': section, 'metric': 'total_hit_count', 'value': total_hits, 'unit': 'count'},
        {'section': section, 'metric': 'read_hit_rate_pct', 'value': _pct(read_hits, reads), 'unit': 'pct'},
        {'section': section, 'metric': 'write_hit_rate_pct', 'value': _pct(write_hits, writes), 'unit': 'pct'},
        {'section': section, 'metric': 'overall_hit_rate_pct', 'value': _pct(total_hits, total_access), 'unit': 'pct'},
        {'section': section, 'metric': 'read_miss_rate_pct', 'value': _pct(read_misses, reads), 'unit': 'pct'},
        {'section': section, 'metric': 'write_miss_rate_pct', 'value': _pct(write_misses, writes), 'unit': 'pct'},
        {'section': section, 'metric': 'overall_miss_rate_pct', 'value': _pct(total_misses, total_access), 'unit': 'pct'},
        {'section': section, 'metric': 'mshr_stalls_delta', 'value': values['mshr_stalls'], 'unit': 'cycles'},
        {'section': section, 'metric': 'mem_stalls_delta', 'value': values['mem_stalls'], 'unit': 'cycles'},
        {'section': section, 'metric': 'crsp_stalls_delta', 'value': values['crsp_stalls'], 'unit': 'cycles'},
    ]
    return pd.DataFrame(rows)


def _analyze_lmem_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles,
                          clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    section = 'lmem'
    rows = []
    base = paths.local_mem
    sig = {
        'req_valid': f'{base}/req_valid_in[7:0]',
        'req_ready': f'{base}/req_ready_in[7:0]',
        'req_rw': f'{base}/req_rw[7:0]',
        'rsp_valid': f'{base}/rsp_valid_out[7:0]',
        'rsp_ready': f'{base}/rsp_ready_out[7:0]',
        'perf_reads': f'{base}/perf_reads[43:0]',
        'perf_writes': f'{base}/perf_writes[43:0]',
        'perf_crsp_stalls': f'{base}/perf_crsp_stalls[43:0]',
    }
    try:
        report = fsdb.report(str(fsdb_path), list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return pd.DataFrame()

    rd_map = defaultdict(int)
    wr_map = defaultdict(int)
    rsp_map = defaultdict(int)
    pending = [deque() for _ in range(8)]
    read_latencies = []

    for idx, ev in enumerate(events):
        start_cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        if idx + 1 < len(events):
            end_cycle = _cycle_from_time_ps(events[idx + 1].time, clock_period_ps)
        else:
            end_cycle = start_cycle + 1
        if end_cycle <= start_cycle:
            end_cycle = start_cycle + 1

        req_fire = (
            _mask_sv_int(ev.values.get(sig['req_valid'], '0'), 8)
            & _mask_sv_int(ev.values.get(sig['req_ready'], '0'), 8)
        )
        rsp_fire = (
            _mask_sv_int(ev.values.get(sig['rsp_valid'], '0'), 8)
            & _mask_sv_int(ev.values.get(sig['rsp_ready'], '0'), 8)
        )
        req_rw = _mask_sv_int(ev.values.get(sig['req_rw'], '0'), 8)
        rd_fire = req_fire & ~req_rw & 0xff
        wr_fire = req_fire & req_rw

        for cycle in range(start_cycle, end_cycle):
            if rd_fire:
                rd_map[cycle] |= rd_fire
            if wr_fire:
                wr_map[cycle] |= wr_fire
            if rsp_fire:
                rsp_map[cycle] |= rsp_fire

    for cycle in sorted(set(rd_map) | set(rsp_map)):
        for lane in _iter_set_bits(rd_map.get(cycle, 0), 8):
            pending[lane].append(cycle)
        for lane in _iter_set_bits(rsp_map.get(cycle, 0), 8):
            if pending[lane]:
                read_latencies.append(cycle - pending[lane].popleft())

    rd_cycles = _cycles_from_mask_map(rd_map)
    wr_cycles = _cycles_from_mask_map(wr_map)
    rsp_cycles = _cycles_from_mask_map(rsp_map)
    rd_events = _event_count_from_mask_map(rd_map)
    wr_events = _event_count_from_mask_map(wr_map)
    rsp_events = _event_count_from_mask_map(rsp_map)
    read_bytes = rd_events * 8
    write_bytes = wr_events * 8
    total_bytes = read_bytes + write_bytes
    active_cycles = len(set(rd_cycles + wr_cycles + rsp_cycles))

    rows.extend([
        {'section': section, 'metric': 'read_bytes', 'value': read_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'write_bytes', 'value': write_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'total_bytes', 'value': total_bytes, 'unit': 'bytes'},
        {'section': section, 'metric': 'read_req_count', 'value': rd_events, 'unit': 'count'},
        {'section': section, 'metric': 'write_req_count', 'value': wr_events, 'unit': 'count'},
        {'section': section, 'metric': 'rsp_count', 'value': rsp_events, 'unit': 'count'},
        {'section': section, 'metric': 'perf_reads_delta', 'value': _counter_delta_from_events(events, sig['perf_reads']), 'unit': 'count'},
        {'section': section, 'metric': 'perf_writes_delta', 'value': _counter_delta_from_events(events, sig['perf_writes']), 'unit': 'count'},
        {'section': section, 'metric': 'perf_crsp_stalls_delta', 'value': _counter_delta_from_events(events, sig['perf_crsp_stalls']), 'unit': 'cycles'},
    ])
    _add_ratio_rows(rows, section, active_cycles, total_bytes, busy_cycles, user_cycles)
    _add_latency_rows(rows, section, 'read', read_latencies)
    for prefix, cycles in (
        ('read_req', rd_cycles),
        ('write_req', wr_cycles),
        ('rsp', rsp_cycles),
    ):
        _add_interval_rows(rows, section, prefix, cycles)
    return pd.DataFrame(rows)


def _analyze_tcu_pe_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles,
                            clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    section = 'tcu_pe'
    rows = []
    pe_units = {
        'fp': 0,
        'int': 1,
    }
    pe_count = len(pe_units)
    sig = {}
    for pe in range(pe_count):
        base = f'{paths.tcu_unit}/g_blocks[0]/pe_execute_if[{pe}]'
        sig[f'valid_{pe}'] = f'{base}/valid'
        sig[f'ready_{pe}'] = f'{base}/ready'

    try:
        report = fsdb.report(str(fsdb_path), list(sig.values()), bt=bt, et=et)
        events = report.events()
    except Exception:
        if strict:
            raise
        return pd.DataFrame()

    fire_cycles_by_pe = {pe: [] for pe in range(pe_count)}
    stall_cycles_by_pe = {pe: [] for pe in range(pe_count)}
    for ev in events:
        cycle = _cycle_from_time_ps(ev.time, clock_period_ps)
        for pe in range(pe_count):
            valid = _is_one(ev.values.get(sig[f'valid_{pe}'], '0'))
            ready = _is_one(ev.values.get(sig[f'ready_{pe}'], '0'))
            if valid and ready:
                fire_cycles_by_pe[pe].append(cycle)
            elif valid and not ready:
                stall_cycles_by_pe[pe].append(cycle)

    pe_fire = sum(len(set(cycles)) for cycles in fire_cycles_by_pe.values())
    pe_stall = sum(len(set(cycles)) for cycles in stall_cycles_by_pe.values())
    any_fire_cycles = sorted(set(cycle for cycles in fire_cycles_by_pe.values() for cycle in cycles))
    active_cycles = len(any_fire_cycles)
    capacity_busy = busy_cycles * pe_count
    capacity_user = user_cycles * pe_count

    rows.extend([
        {'section': section, 'metric': 'pe_count', 'value': pe_count, 'unit': 'count'},
        {'section': section, 'metric': 'pe_fire_count', 'value': pe_fire, 'unit': 'count'},
        {'section': section, 'metric': 'pe_stall_count', 'value': pe_stall, 'unit': 'count'},
        {'section': section, 'metric': 'active_cycles_any_pe', 'value': active_cycles, 'unit': 'cycles'},
        {'section': section, 'metric': 'active_pct_busy', 'value': _pct(active_cycles, busy_cycles), 'unit': 'pct'},
        {'section': section, 'metric': 'active_pct_user_kernel_body', 'value': _pct(active_cycles, user_cycles), 'unit': 'pct'},
        {'section': section, 'metric': 'pe_lane_util_pct_busy', 'value': _pct(pe_fire, capacity_busy), 'unit': 'pct'},
        {'section': section, 'metric': 'pe_lane_util_pct_user_kernel_body', 'value': _pct(pe_fire, capacity_user), 'unit': 'pct'},
        {'section': section, 'metric': 'pe_stall_pct_activity', 'value': _pct(pe_stall, pe_fire + pe_stall), 'unit': 'pct'},
    ])
    _add_interval_rows(rows, section, 'pe_fire', any_fire_cycles)

    for unit, pe in pe_units.items():
        unit_section = f'tcu_{unit}'
        unit_fire_cycles = sorted(set(fire_cycles_by_pe[pe]))
        unit_stall_cycles = sorted(set(stall_cycles_by_pe[pe]))
        unit_fire = len(unit_fire_cycles)
        unit_stall = len(unit_stall_cycles)
        rows.extend([
            {'section': unit_section, 'metric': 'pe_index', 'value': pe, 'unit': 'index'},
            {'section': unit_section, 'metric': 'fire_count', 'value': unit_fire, 'unit': 'count'},
            {'section': unit_section, 'metric': 'stall_count', 'value': unit_stall, 'unit': 'count'},
            {'section': unit_section, 'metric': 'active_cycles', 'value': unit_fire, 'unit': 'cycles'},
            {'section': unit_section, 'metric': 'active_pct_busy', 'value': _pct(unit_fire, busy_cycles), 'unit': 'pct'},
            {'section': unit_section, 'metric': 'active_pct_user_kernel_body', 'value': _pct(unit_fire, user_cycles), 'unit': 'pct'},
            {'section': unit_section, 'metric': 'util_pct_busy', 'value': _pct(unit_fire, busy_cycles), 'unit': 'pct'},
            {'section': unit_section, 'metric': 'util_pct_user_kernel_body', 'value': _pct(unit_fire, user_cycles), 'unit': 'pct'},
            {'section': unit_section, 'metric': 'stall_pct_activity', 'value': _pct(unit_stall, unit_fire + unit_stall), 'unit': 'pct'},
        ])
        _add_interval_rows(rows, unit_section, 'fire', unit_fire_cycles)
    return pd.DataFrame(rows)


def analyze_tcu_system_metrics(fsdb_path=DEFAULT_FSDB, phases=None, paths=DEFAULT_GEMM_PATHS,
                               bt=None, et=None, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                               strict=False):
    """Measure TCU compute and memory-system metrics in the user-kernel window.

    Memory sections:
      - hbm_axi: top-level AXI memory interface, 64 bytes per R/W beat
      - dcache: core LSU D-cache fire vectors, 8 bytes per lane
      - lmem: local memory lane valid/ready vectors, 8 bytes per lane
      - l1_icache/l1_dcache/l2cache: cache-local hit/miss counters

    Utilization is reported against both kernel_busy and user_kernel_body cycles.
    """
    if bt is None and et is None and phases is not None and not phases.empty:
        bt, et = _phase_time_window(phases, 'user_kernel_body', clock_period_ps)

    busy_cycles = _phase_cycles(phases, 'kernel_busy', 0)
    user_cycles = _phase_cycles(phases, 'user_kernel_body', 0)
    if user_cycles == 0 and bt is not None and et is not None:
        start = int(str(bt).rstrip('ps'))
        end = int(str(et).rstrip('ps'))
        user_cycles = _cycles_between(start, end, clock_period_ps) or 0
    if busy_cycles == 0:
        busy_cycles = user_cycles

    rows = [
        {'section': 'tcu_window', 'metric': 'busy_cycles_denominator', 'value': busy_cycles, 'unit': 'cycles'},
        {'section': 'tcu_window', 'metric': 'user_kernel_body_cycles_denominator', 'value': user_cycles, 'unit': 'cycles'},
    ]
    tables = [
        pd.DataFrame(rows),
        _analyze_tcu_pe_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_hbm_axi_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_dcache_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_lmem_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l1_icache', paths.l1_icache_perf, bt, et, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l1_dcache', paths.l1_dcache_perf, bt, et, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l2cache', paths.l2cache_perf, bt, et, strict),
    ]
    out = pd.concat([table for table in tables if table is not None and not table.empty], ignore_index=True)
    print(f'FSDB: {fsdb_path}')
    print(f'TCU system metric window: bt={bt}, et={et}, busy_cycles={busy_cycles}, user_cycles={user_cycles}')
    return out


def analyze_memory_system_metrics(fsdb_path=DEFAULT_FSDB, phases=None, paths=DEFAULT_GEMM_PATHS,
                                  bt=None, et=None, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                  strict=False):
    """Measure memory-system metrics in the user-kernel window.

    This is the GEMM-kernel agnostic subset of analyze_tcu_system_metrics. It is
    intended for FPxINT/MXU kernels as well as TCU kernels.
    """
    if bt is None and et is None and phases is not None and not phases.empty:
        bt, et = _phase_time_window(phases, 'user_kernel_body', clock_period_ps)

    busy_cycles = _phase_cycles(phases, 'kernel_busy', 0)
    user_cycles = _phase_cycles(phases, 'user_kernel_body', 0)
    if user_cycles == 0 and bt is not None and et is not None:
        start = int(str(bt).rstrip('ps'))
        end = int(str(et).rstrip('ps'))
        user_cycles = _cycles_between(start, end, clock_period_ps) or 0
    if busy_cycles == 0:
        busy_cycles = user_cycles

    rows = [
        {'section': 'memory_window', 'metric': 'busy_cycles_denominator', 'value': busy_cycles, 'unit': 'cycles'},
        {'section': 'memory_window', 'metric': 'user_kernel_body_cycles_denominator', 'value': user_cycles, 'unit': 'cycles'},
    ]
    tables = [
        pd.DataFrame(rows),
        _analyze_hbm_axi_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_dcache_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_lmem_metrics(fsdb_path, paths, bt, et, busy_cycles, user_cycles, clock_period_ps, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l1_icache', paths.l1_icache_perf, bt, et, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l1_dcache', paths.l1_dcache_perf, bt, et, strict),
        _analyze_cache_counter_metrics(fsdb_path, 'l2cache', paths.l2cache_perf, bt, et, strict),
    ]
    out = pd.concat([table for table in tables if table is not None and not table.empty], ignore_index=True)
    print(f'FSDB: {fsdb_path}')
    print(f'Memory metric window: bt={bt}, et={et}, busy_cycles={busy_cycles}, user_cycles={user_cycles}')
    return out


def analyze_mxu_pipeline_metrics(fsdb_path=DEFAULT_FSDB, phases=None, paths=DEFAULT_GEMM_PATHS,
                                 bt=None, et=None, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                 mxu_row=32, mxu_col=32, strict=False):
    """Measure internal FPxINT MXU pipeline valid/FIFO signals in the user window."""
    if bt is None and et is None and phases is not None and not phases.empty:
        bt, et = _phase_time_window(phases, 'user_kernel_body', clock_period_ps)

    base = paths.gemm_unit
    signals = {
        'in_flight': f'{base}/in_flight',
        'in_pipe_valid': f'{base}/in_pipe_valid_out',
        'prealigner_valid': f'{base}/prealigner_out_valid',
        'merger_in_valid': f'{base}/merger_in_valid',
        'merger_out_valid': f'{base}/merger_out_valid',
        'final_scaler_valid': f'{base}/final_scaler_output_valid',
        'acc_in_valid': f'{base}/acc_in_data_valid[0]',
        'acc_psum_valid': f'{base}/acc_psum_data_valid[0]',
        'acc_output_valid': f'{base}/acc_output_valid[0]',
        'acc_rd_fifo_full': f'{base}/acc_rd_fifo_full',
        'acc_rd_fifo_empty': f'{base}/acc_rd_fifo_empty',
        'acc_rd_fifo_push': f'{base}/acc_rd_fifo_push',
        'acc_rd_fifo_pop': f'{base}/acc_rd_fifo_pop',
        'acc_mem_rd_req': f'{base}/acc_mem_accum_rd_req',
        'acc_mem_wr_req': f'{base}/acc_mem_accum_wr_req',
    }

    rows = []
    try:
        in_flight_cycles, time_unit = _sample_high_window_cycles(
            fsdb_path, signals['in_flight'], bt=bt, et=et,
            clock_period_ps=clock_period_ps, strict=strict,
        )
    except Exception:
        if strict:
            raise
        in_flight_cycles, time_unit = [], None
    compute_cycles = len(in_flight_cycles)
    rows.extend([
        {'section': 'mxu_pipeline', 'metric': 'in_flight_active_cycles', 'value': compute_cycles, 'unit': 'cycles'},
        {'section': 'mxu_pipeline', 'metric': 'time_unit_available', 'value': 0 if time_unit is None else 1, 'unit': 'bool'},
    ])

    stage_cycles = {}
    for stage, signal in signals.items():
        try:
            cycles, stage_time_unit = _sample_high_window_cycles(
                fsdb_path, signal, bt=bt, et=et,
                clock_period_ps=clock_period_ps, strict=strict,
            )
        except Exception:
            if strict:
                raise
            cycles, stage_time_unit = [], None
        stage_cycles[stage] = len(cycles)
        summary = _interval_summary_from_cycles(cycles)
        rows.extend([
            {'section': f'mxu_pipeline_{stage}', 'metric': 'active_cycles', 'value': len(cycles), 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'active_pct_compute', 'value': _pct(len(cycles), compute_cycles), 'unit': 'pct'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'p50_interval', 'value': summary['p50_interval'], 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'p90_interval', 'value': summary['p90_interval'], 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'p99_interval', 'value': summary['p99_interval'], 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'max_interval', 'value': 0 if summary['max_interval'] is None else summary['max_interval'], 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'max_burst_len', 'value': summary['max_burst_len'], 'unit': 'cycles'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'consecutive_interval_pct', 'value': summary['consecutive_interval_pct'], 'unit': 'pct'},
            {'section': f'mxu_pipeline_{stage}', 'metric': 'time_unit_available', 'value': 0 if stage_time_unit is None else 1, 'unit': 'bool'},
        ])

    mxu_macs_per_event = int(mxu_row) * int(mxu_col)
    estimated_macs = stage_cycles.get('merger_in_valid', 0) * mxu_macs_per_event
    estimated_flops = estimated_macs * 2
    rows.extend([
        {'section': 'mxu_pipeline', 'metric': 'mxu_row', 'value': int(mxu_row), 'unit': 'count'},
        {'section': 'mxu_pipeline', 'metric': 'mxu_col', 'value': int(mxu_col), 'unit': 'count'},
        {'section': 'mxu_pipeline', 'metric': 'mxu_macs_per_merger_event', 'value': mxu_macs_per_event, 'unit': 'mac/event'},
        {'section': 'mxu_pipeline', 'metric': 'estimated_mxu_mac_count', 'value': estimated_macs, 'unit': 'mac'},
        {'section': 'mxu_pipeline', 'metric': 'estimated_mxu_flop_count', 'value': estimated_flops, 'unit': 'flop'},
        {'section': 'mxu_pipeline', 'metric': 'estimated_flops_per_compute_cycle', 'value': _ratio(estimated_flops, compute_cycles), 'unit': 'flop/cycle'},
    ])

    out = pd.DataFrame(rows)
    print(f'FSDB: {fsdb_path}')
    print(f'MXU pipeline metric window: bt={bt}, et={et}, compute_cycles={compute_cycles}')
    return out


_TCU_TRACE_RE = re.compile(r'^\s*(\d+):\s+.*?core\d+-(issue\d+-dispatch|commit):.*\bex=TCU\b.*\(#(\d+)\)')
_TCU_OP_RE = re.compile(r'\bop=([^,]+)')


def analyze_tcu_trace(fsdb_path=DEFAULT_FSDB, simv_log=DEFAULT_SIMV_LOG,
                      clock_period_ps=DEFAULT_CLOCK_PERIOD_PS, strict=False):
    """Return TCU dispatch/commit metrics for sgemm_tcu traces.

    The TCU does not drive the GEMM/MXU accel counters. Its most stable current
    signal source is the pipeline trace, keyed by the per-instruction UUID.
    FSDB remains a required trace artifact so batch analysis only reports fully
    captured runs.
    """
    fsdb_path = Path(fsdb_path)
    simv_log = Path(simv_log)
    if not fsdb_path.exists():
        raise FileNotFoundError(f'Missing FSDB: {fsdb_path}')
    if not simv_log.exists():
        if strict:
            raise FileNotFoundError(f'Missing simv.log: {simv_log}')
        return pd.DataFrame()

    dispatch = {}
    commits = {}
    op_counts = defaultdict(int)
    with simv_log.open(errors='ignore') as fh:
        for line in fh:
            match = _TCU_TRACE_RE.search(line)
            if not match:
                continue
            time_ps = int(match.group(1))
            event = match.group(2)
            uuid = int(match.group(3))
            cycle = _cycle_from_time_ps(time_ps, clock_period_ps)
            if event.endswith('dispatch'):
                dispatch[uuid] = cycle
                op_match = _TCU_OP_RE.search(line)
                if op_match:
                    op_counts[op_match.group(1)] += 1
            else:
                commits[uuid] = cycle

    dispatch_cycles = sorted(dispatch.values())
    commit_cycles = sorted(commits.values())
    latencies = sorted([
        commits[uuid] - dispatch_cycle
        for uuid, dispatch_cycle in dispatch.items()
        if uuid in commits and commits[uuid] >= dispatch_cycle
    ])
    unmatched_dispatch = len(set(dispatch) - set(commits))
    orphan_commit = len(set(commits) - set(dispatch))

    rows = []

    def add(metric, value, unit='count', section='tcu'):
        rows.append({'section': section, 'metric': metric, 'value': value, 'unit': unit})

    add('dispatch_count', len(dispatch_cycles))
    add('commit_count', len(commit_cycles))
    add('matched_count', len(latencies))
    add('unmatched_dispatch_count', unmatched_dispatch)
    add('orphan_commit_count', orphan_commit)
    add('first_dispatch_cycle', _first(dispatch_cycles), 'cycle')
    add('last_dispatch_cycle', _last(dispatch_cycles), 'cycle')
    add('first_commit_cycle', _first(commit_cycles), 'cycle')
    add('last_commit_cycle', _last(commit_cycles), 'cycle')
    add('active_dispatch_window_cycles', 0 if not dispatch_cycles else dispatch_cycles[-1] - dispatch_cycles[0] + 1, 'cycles')
    add('active_commit_window_cycles', 0 if not commit_cycles else commit_cycles[-1] - commit_cycles[0] + 1, 'cycles')
    add('latency_mean', _mean(latencies), 'cycles')
    add('latency_p50', _percentile(latencies, 50), 'cycles')
    add('latency_p90', _percentile(latencies, 90), 'cycles')
    add('latency_p99', _percentile(latencies, 99), 'cycles')
    add('latency_max', max(latencies) if latencies else None, 'cycles')

    for prefix, cycles in (('dispatch', dispatch_cycles), ('commit', commit_cycles)):
        summary = _interval_summary_from_cycles(cycles)
        for key in ('event_count', 'mean_interval', 'p50_interval', 'p90_interval',
                    'p99_interval', 'max_interval', 'max_burst_len',
                    'consecutive_interval_pct'):
            add(f'{prefix}_{key}', summary.get(key), 'cycles' if 'interval' in key else 'count')

    for op, count in sorted(op_counts.items()):
        add(f'op_{op}_dispatch_count', count, 'count', section='tcu_op')

    df = pd.DataFrame(rows)
    print(f'FSDB: {fsdb_path}')
    print(f'simv.log: {simv_log}')
    return df


def _counter_top_text(counter, top_n=8):
    if not counter:
        return ''
    return ', '.join(f'{key}:{value}' for key, value in counter.most_common(top_n))


def _kernel_body_dispatches(simv_log=DEFAULT_SIMV_LOG, elf_path=DEFAULT_TCU_KERNEL_ELF,
                            strict=False):
    events = _parse_simv_instruction_events(simv_log, elf_path, strict=strict)
    return [
        item for item in events
        if item['event'] == 'dispatch'
        and _symbol_base(item.get('symbol')) == 'kernel_body'
    ]


def _infer_tcu_store_start_pc(dispatches, tcu_pc, tcu_uops_per_macro=32):
    if tcu_pc is None:
        return None
    tcu_dispatch_count = sum(1 for item in dispatches if item['ex'] == 'TCU')
    macro_count = (
        None if not tcu_uops_per_macro
        else max(1, tcu_dispatch_count // tcu_uops_per_macro)
    )
    pc_counts = Counter(item['pc'] for item in dispatches)
    for pc in sorted(pc for pc in pc_counts if pc > tcu_pc):
        if macro_count is not None and pc_counts[pc] >= macro_count:
            continue
        return pc
    store_pcs = sorted(
        item['pc'] for item in dispatches
        if item['pc'] > tcu_pc and item['op'] in {'FSW', 'FSD', 'SW', 'SD'}
    )
    return store_pcs[0] if store_pcs else None


def analyze_tcu_kernel_breakdown(simv_log=DEFAULT_SIMV_LOG, elf_path=DEFAULT_TCU_KERNEL_ELF,
                                 phases=None, clock_period_ps=DEFAULT_CLOCK_PERIOD_PS,
                                 tcu_uops_per_macro=32, large_gap_threshold=100,
                                 strict=False):
    """Break down an sgemm_tcu kernel into load_sync / compute / store_sync.

    The current TCU kernel does not emit explicit load_sync/store_sync trace
    markers. This function infers them from the kernel PC stream:
      - load_sync: kernel_body dispatches before the TCU custom instruction
      - compute: TCU dispatches
      - compute_loop_overhead: loop update/branch between TCU and store path
      - store_sync: kernel_body dispatches after the K loop exits

    Cycle attribution is based on dispatch-to-dispatch intervals. The interval
    from the previous dispatch to the current dispatch is charged to the current
    dispatch's phase, which makes stalls before the next load/store visible in
    the phase that is waiting to issue. This is an approximation, but it tracks
    the large TCU gaps seen in simv.log without requiring extra RTL markers.
    """
    dispatches = _kernel_body_dispatches(simv_log, elf_path, strict=strict)
    if not dispatches:
        if strict:
            raise RuntimeError(f'No kernel_body dispatches found in {simv_log}')
        return pd.DataFrame()

    dispatches.sort(key=lambda item: (item['time_ps'], item['pc']))
    tcu_pcs = sorted({item['pc'] for item in dispatches if item['ex'] == 'TCU'})
    tcu_pc = tcu_pcs[0] if tcu_pcs else None
    store_start_pc = _infer_tcu_store_start_pc(dispatches, tcu_pc, tcu_uops_per_macro)

    user_cycles = _phase_cycles(phases, 'user_kernel_body', 0)
    user_start_cycle = _phase_metric(phases, 'user_kernel_body', 'start_cycle', None)
    user_end_cycle = _phase_metric(phases, 'user_kernel_body', 'end_cycle', None)
    if user_cycles == 0:
        user_start_cycle = dispatches[0]['cycle']
        user_end_cycle = dispatches[-1]['cycle'] + 1
        user_cycles = max(0, user_end_cycle - user_start_cycle)

    def phase_of(item):
        pc = item['pc']
        if item['ex'] == 'TCU':
            return 'compute'
        if tcu_pc is not None and store_start_pc is not None and pc >= store_start_pc:
            return 'store_sync'
        if tcu_pc is not None and pc < tcu_pc:
            return 'load_sync'
        if tcu_pc is not None and pc > tcu_pc:
            return 'compute_loop_overhead'
        return 'other_user'

    phase_order = {
        'load_sync': 0,
        'compute': 1,
        'compute_loop_overhead': 2,
        'store_sync': 3,
        'other_user': 4,
    }
    data = defaultdict(lambda: {
        'dispatch_count': 0,
        'dispatch_cycles': [],
        'attributed_intervals': [],
        'ex': Counter(),
        'op': Counter(),
        'pc': Counter(),
    })

    prev_cycle = user_start_cycle
    prev_item = None
    tcu_intervals = []
    large_tcu_intervals = []
    prev_tcu = None

    for item in dispatches:
        phase = phase_of(item)
        info = data[phase]
        info['dispatch_count'] += 1
        info['dispatch_cycles'].append(item['cycle'])
        info['ex'][item['ex']] += 1
        info['op'][item['op']] += 1
        info['pc'][f"{item['pc_hex']}:{item['op']}"] += 1

        if prev_cycle is not None:
            interval = max(0, item['cycle'] - prev_cycle)
            info['attributed_intervals'].append(interval)
        prev_cycle = item['cycle']
        prev_item = item

        if item['ex'] == 'TCU':
            if prev_tcu is not None:
                interval = item['cycle'] - prev_tcu['cycle']
                tcu_intervals.append(interval)
                if interval > large_gap_threshold:
                    large_tcu_intervals.append(interval)
            prev_tcu = item

    if prev_item is not None and user_end_cycle is not None:
        tail_interval = max(0, user_end_cycle - prev_item['cycle'])
        data[phase_of(prev_item)]['attributed_intervals'].append(tail_interval)

    rows = []
    total_attributed = sum(
        sum(info['attributed_intervals']) for info in data.values()
    )
    for phase, info in sorted(data.items(), key=lambda item: phase_order.get(item[0], 99)):
        intervals = sorted(info['attributed_intervals'])
        attributed_cycles = sum(intervals)
        dispatch_cycles = sorted(set(info['dispatch_cycles']))
        rows.append({
            'phase': phase,
            'dispatch_count': info['dispatch_count'],
            'issue_cycle_count': len(dispatch_cycles),
            'attributed_cycles': attributed_cycles,
            'stall_or_gap_cycles': max(0, attributed_cycles - len(dispatch_cycles)),
            'pct_user_kernel_body': _pct(attributed_cycles, user_cycles),
            'pct_attributed_cycles': _pct(attributed_cycles, total_attributed),
            'mean_issue_interval': _mean(intervals),
            'p50_issue_interval': _percentile(intervals, 50),
            'p90_issue_interval': _percentile(intervals, 90),
            'p99_issue_interval': _percentile(intervals, 99),
            'max_issue_interval': max(intervals) if intervals else None,
            'ex_top': _counter_top_text(info['ex']),
            'op_top': _counter_top_text(info['op']),
            'pc_top': _counter_top_text(info['pc']),
            'tcu_pc': None if tcu_pc is None else f'0x{tcu_pc:08x}',
            'store_start_pc': None if store_start_pc is None else f'0x{store_start_pc:08x}',
            'source': 'simv.log dispatch PC/op + kernel.elf symbols',
        })

    if tcu_intervals:
        sorted_tcu_intervals = sorted(tcu_intervals)
        large_gap_cycles = sum(large_tcu_intervals)
        rows.append({
            'phase': 'tcu_gap_summary',
            'dispatch_count': len(tcu_intervals),
            'issue_cycle_count': None,
            'attributed_cycles': sum(tcu_intervals),
            'stall_or_gap_cycles': None,
            'pct_user_kernel_body': _pct(sum(tcu_intervals), user_cycles),
            'pct_attributed_cycles': None,
            'mean_issue_interval': _mean(sorted_tcu_intervals),
            'p50_issue_interval': _percentile(sorted_tcu_intervals, 50),
            'p90_issue_interval': _percentile(sorted_tcu_intervals, 90),
            'p99_issue_interval': _percentile(sorted_tcu_intervals, 99),
            'max_issue_interval': max(sorted_tcu_intervals),
            'large_gap_threshold': large_gap_threshold,
            'large_gap_count': len(large_tcu_intervals),
            'large_gap_cycles': large_gap_cycles,
            'large_gap_mean_interval': _mean(large_tcu_intervals),
            'large_gap_pct_user_kernel_body': _pct(large_gap_cycles, user_cycles),
            'ex_top': '',
            'op_top': f'>{large_gap_threshold}_count:{len(large_tcu_intervals)}, '
                      f'>{large_gap_threshold}_cycles:{large_gap_cycles}',
            'pc_top': '',
            'tcu_pc': None if tcu_pc is None else f'0x{tcu_pc:08x}',
            'store_start_pc': None if store_start_pc is None else f'0x{store_start_pc:08x}',
            'source': 'simv.log TCU dispatch intervals',
        })

    df = pd.DataFrame(rows)
    print(f'simv.log: {simv_log}')
    print(f'ELF: {elf_path}')
    print(f'TCU PC: {None if tcu_pc is None else hex(tcu_pc)}, '
          f'store_start_pc: {None if store_start_pc is None else hex(store_start_pc)}, '
          f'user_cycles={user_cycles}')
    return df


_DRAM_STALL_CONFIG_RE = re.compile(
    r'\[TB\]\s+DRAM stall config:\s+'
    r'req_enter=(\d+)%\s+req_exit=(\d+)%\s+'
    r'rsp_enter=(\d+)%\s+rsp_exit=(\d+)%'
)
_RUN_ELAPSED_RE = re.compile(r'Elapsed time:\s+(\d+)\s+ms')
_B_LAYOUT_RE = re.compile(r'matrix B device layout:\s+(\S+)')


def parse_simv_dram_stall_config(simv_log=DEFAULT_SIMV_LOG):
    """Parse the VCS testbench DRAM Markov-stall configuration from simv.log.

    A run is effectively no-stall when the request and response enter
    probabilities are both zero. The exit probabilities are then irrelevant
    because the Markov state never enters a stall state after reset.
    """
    simv_log = Path(simv_log)
    columns = [
        'simv_log', 'dram_req_enter_pct', 'dram_req_exit_pct',
        'dram_rsp_enter_pct', 'dram_rsp_exit_pct', 'dram_no_markov_stall',
    ]
    if not simv_log.exists():
        return pd.DataFrame(columns=columns)

    with simv_log.open('r', errors='replace') as fp:
        for line in fp:
            match = _DRAM_STALL_CONFIG_RE.search(line)
            if not match:
                continue
            req_enter, req_exit, rsp_enter, rsp_exit = map(int, match.groups())
            return pd.DataFrame([{
                'simv_log': str(simv_log),
                'dram_req_enter_pct': req_enter,
                'dram_req_exit_pct': req_exit,
                'dram_rsp_enter_pct': rsp_enter,
                'dram_rsp_exit_pct': rsp_exit,
                'dram_no_markov_stall': req_enter == 0 and rsp_enter == 0,
            }], columns=columns)
    return pd.DataFrame(columns=columns)


def parse_run_metadata(trace_dir=None, run_log=None, simv_log=None):
    """Return run-level metadata useful for comparing generated trace folders."""
    if trace_dir is not None:
        trace_dir = Path(trace_dir)
        run_log = trace_dir / 'run.log' if run_log is None else run_log
        simv_log = trace_dir / 'xrtsim_vcs' / 'simv.log' if simv_log is None else simv_log
        trace = trace_dir.name
    else:
        run_log = Path(run_log) if run_log is not None else None
        simv_log = Path(simv_log) if simv_log is not None else None
        trace = None

    row = {
        'trace': trace,
        'run_log': None if run_log is None else str(run_log),
        'simv_log': None if simv_log is None else str(simv_log),
        'elapsed_time_ms': None,
        'b_device_layout': None,
        'passed': None,
        'b_col_major_config': None,
    }

    if run_log is not None and Path(run_log).exists():
        text = Path(run_log).read_text(errors='replace')
        elapsed = _RUN_ELAPSED_RE.search(text)
        layout = _B_LAYOUT_RE.search(text)
        row['elapsed_time_ms'] = int(elapsed.group(1)) if elapsed else None
        row['b_device_layout'] = layout.group(1) if layout else None
        row['passed'] = 'PASSED' in text
        row['b_col_major_config'] = '-DB_COL_MAJOR=1' in text or '+define+B_COL_MAJOR=1' in text

    dram = parse_simv_dram_stall_config(simv_log) if simv_log is not None else pd.DataFrame()
    if not dram.empty:
        for key, value in dram.iloc[0].items():
            if key != 'simv_log':
                row[key] = value
    return pd.DataFrame([row])


def _trace_names_from_frames(*frames):
    names = set()
    for frame in frames:
        if frame is None or frame.empty or 'trace' not in frame.columns:
            continue
        names.update(str(value) for value in frame['trace'].dropna().unique())
    return sorted(names)


def _summary_metric(summary, trace, section, metric, default=0.0):
    if summary is None or summary.empty:
        return default
    if not {'trace', 'section', 'metric', 'value'} <= set(summary.columns):
        return default
    values = summary.loc[
        (summary['trace'] == trace)
        & (summary['section'] == section)
        & (summary['metric'] == metric),
        'value',
    ]
    if values.empty or pd.isna(values.iloc[0]):
        return default
    return values.iloc[0]


def _phase_cycle_value(phase_summary, trace, phase, default=0.0):
    if phase_summary is None or phase_summary.empty:
        return default
    if not {'trace', 'phase', 'cycles'} <= set(phase_summary.columns):
        return default
    values = phase_summary.loc[
        (phase_summary['trace'] == trace)
        & (phase_summary['phase'] == phase),
        'cycles',
    ]
    if values.empty or pd.isna(values.iloc[0]):
        return default
    return values.iloc[0]


def _memory_metric_specs():
    specs = []
    for section in ('hbm_axi', 'dcache', 'lmem'):
        short = 'hbm' if section == 'hbm_axi' else section
        specs.extend([
            (section, 'read_bytes', f'{short}_read_bytes'),
            (section, 'write_bytes', f'{short}_write_bytes'),
            (section, 'total_bytes', f'{short}_total_bytes'),
            (section, 'active_cycles', f'{short}_active_cycles'),
            (section, 'active_pct_busy', f'{short}_active_pct_busy'),
            (section, 'active_pct_user_kernel_body', f'{short}_active_pct_user_kernel_body'),
            (section, 'bandwidth_bytes_per_active_cycle', f'{short}_bw_active_Bpc'),
            (section, 'bandwidth_bytes_per_user_cycle', f'{short}_bw_user_Bpc'),
            (section, 'read_req_count', f'{short}_read_req_count'),
            (section, 'write_req_count', f'{short}_write_req_count'),
            (section, 'read_latency_count', f'{short}_read_latency_count'),
            (section, 'read_latency_mean', f'{short}_read_latency_mean'),
            (section, 'read_latency_p50', f'{short}_read_latency_p50'),
            (section, 'read_latency_p90', f'{short}_read_latency_p90'),
            (section, 'read_latency_p99', f'{short}_read_latency_p99'),
            (section, 'read_latency_max', f'{short}_read_latency_max'),
            (section, 'read_req_mean_interval', f'{short}_read_req_mean_interval'),
            (section, 'read_req_p90_interval', f'{short}_read_req_p90_interval'),
            (section, 'read_req_max_interval', f'{short}_read_req_max_interval'),
        ])

    for section, short in (
        ('l1_icache', 'l1_icache'),
        ('l1_dcache', 'l1_dcache'),
        ('l2cache', 'l2'),
    ):
        specs.extend([
            (section, 'cache_enabled', f'{short}_cache_enabled'),
            (section, 'hit_rate_available', f'{short}_hit_rate_available'),
            (section, 'read_count', f'{short}_read_count'),
            (section, 'write_count', f'{short}_write_count'),
            (section, 'total_access_count', f'{short}_total_access_count'),
            (section, 'read_miss_count', f'{short}_read_miss_count'),
            (section, 'write_miss_count', f'{short}_write_miss_count'),
            (section, 'total_miss_count', f'{short}_total_miss_count'),
            (section, 'read_hit_count', f'{short}_read_hit_count'),
            (section, 'write_hit_count', f'{short}_write_hit_count'),
            (section, 'total_hit_count', f'{short}_total_hit_count'),
            (section, 'read_hit_rate_pct', f'{short}_read_hit_rate_pct'),
            (section, 'write_hit_rate_pct', f'{short}_write_hit_rate_pct'),
            (section, 'overall_hit_rate_pct', f'{short}_overall_hit_rate_pct'),
            (section, 'read_miss_rate_pct', f'{short}_read_miss_rate_pct'),
            (section, 'write_miss_rate_pct', f'{short}_write_miss_rate_pct'),
            (section, 'overall_miss_rate_pct', f'{short}_overall_miss_rate_pct'),
            (section, 'mshr_stalls_delta', f'{short}_mshr_stalls_delta'),
            (section, 'mem_stalls_delta', f'{short}_mem_stalls_delta'),
            (section, 'crsp_stalls_delta', f'{short}_crsp_stalls_delta'),
        ])
    return specs


def build_memory_system_compact_summary(phase_summary=None, system_summary=None,
                                        metadata_summary=None):
    """Build one row per trace with HBM, D-cache interface, LMEM, and cache hit metrics."""
    traces = _trace_names_from_frames(phase_summary, system_summary, metadata_summary)
    rows = []
    metric_specs = _memory_metric_specs()

    for trace in traces:
        row = {'trace': trace}
        for phase in ('kernel_busy', 'warp_spawn', 'user_kernel_body'):
            row[phase] = _phase_cycle_value(phase_summary, trace, phase)

        if metadata_summary is not None and not metadata_summary.empty and 'trace' in metadata_summary.columns:
            meta = metadata_summary.loc[metadata_summary['trace'] == trace]
            if not meta.empty:
                for key in (
                    'elapsed_time_ms', 'b_device_layout', 'passed',
                    'b_col_major_config', 'dram_req_enter_pct',
                    'dram_req_exit_pct', 'dram_rsp_enter_pct',
                    'dram_rsp_exit_pct', 'dram_no_markov_stall',
                ):
                    if key in meta.columns:
                        row[key] = meta.iloc[0][key]

        for section, metric, name in metric_specs:
            row[name] = _summary_metric(system_summary, trace, section, metric)
        rows.append(row)

    return pd.DataFrame(rows).set_index('trace') if rows else pd.DataFrame()


def build_mxu_pipeline_compact_summary(pipeline_summary=None, phase_summary=None):
    """Build one row per trace from analyze_mxu_pipeline_metrics output."""
    traces = _trace_names_from_frames(pipeline_summary, phase_summary)
    stages = [
        'in_flight',
        'in_pipe_valid',
        'prealigner_valid',
        'merger_in_valid',
        'merger_out_valid',
        'final_scaler_valid',
        'acc_in_valid',
        'acc_psum_valid',
        'acc_output_valid',
        'acc_rd_fifo_full',
        'acc_rd_fifo_empty',
        'acc_rd_fifo_push',
        'acc_rd_fifo_pop',
        'acc_mem_rd_req',
        'acc_mem_wr_req',
    ]
    metrics = [
        'active_cycles',
        'active_pct_compute',
        'p50_interval',
        'p90_interval',
        'p99_interval',
        'max_interval',
        'max_burst_len',
        'consecutive_interval_pct',
    ]
    rows = []
    for trace in traces:
        row = {'trace': trace}
        row['user_kernel_body'] = _phase_cycle_value(phase_summary, trace, 'user_kernel_body')
        row['kernel_busy'] = _phase_cycle_value(phase_summary, trace, 'kernel_busy')
        row['in_flight_active_cycles'] = _summary_metric(
            pipeline_summary, trace, 'mxu_pipeline', 'in_flight_active_cycles',
        )
        for metric in (
            'mxu_row',
            'mxu_col',
            'mxu_macs_per_merger_event',
            'estimated_mxu_mac_count',
            'estimated_mxu_flop_count',
            'estimated_flops_per_compute_cycle',
        ):
            row[metric] = _summary_metric(pipeline_summary, trace, 'mxu_pipeline', metric)
        for stage in stages:
            section = f'mxu_pipeline_{stage}'
            for metric in metrics:
                row[f'{stage}_{metric}'] = _summary_metric(pipeline_summary, trace, section, metric)
        rows.append(row)
    return pd.DataFrame(rows).set_index('trace') if rows else pd.DataFrame()


def build_tcu_compact_summary(phase_summary=None, tcu_summary=None,
                              tcu_system_summary=None, tcu_breakdown=None,
                              metadata_summary=None):
    """Build one row per TCU trace with compute, memory, latency, and breakdown metrics."""
    metric_frames = [
        frame for frame in (tcu_summary, tcu_system_summary)
        if frame is not None and not frame.empty
    ]
    metrics = (
        pd.concat(metric_frames, ignore_index=True)
        if metric_frames else pd.DataFrame()
    )
    traces = _trace_names_from_frames(
        phase_summary, metrics, tcu_breakdown, metadata_summary,
    )
    rows = []

    metric_specs = [
        ('tcu', 'dispatch_count', 'dispatch_count'),
        ('tcu', 'commit_count', 'commit_count'),
        ('tcu', 'latency_mean', 'latency_mean'),
        ('tcu', 'latency_p50', 'latency_p50'),
        ('tcu', 'latency_p90', 'latency_p90'),
        ('tcu', 'latency_p99', 'latency_p99'),
        ('tcu', 'dispatch_mean_interval', 'dispatch_mean_interval'),
        ('tcu', 'dispatch_p50_interval', 'dispatch_p50_interval'),
        ('tcu', 'dispatch_p90_interval', 'dispatch_p90_interval'),
        ('tcu', 'dispatch_p99_interval', 'dispatch_p99_interval'),
        ('tcu', 'dispatch_max_interval', 'dispatch_max_interval'),
        ('tcu_fp', 'fire_count', 'tcu_fp_fire_count'),
        ('tcu_fp', 'util_pct_busy', 'tcu_fp_util_pct_busy'),
        ('tcu_fp', 'util_pct_user_kernel_body', 'tcu_fp_util_pct_user_kernel_body'),
        ('tcu_fp', 'fire_mean_interval', 'tcu_fp_fire_mean_interval'),
        ('tcu_fp', 'fire_p50_interval', 'tcu_fp_fire_p50_interval'),
        ('tcu_int', 'fire_count', 'tcu_int_fire_count'),
        ('tcu_int', 'util_pct_busy', 'tcu_int_util_pct_busy'),
        ('tcu_int', 'util_pct_user_kernel_body', 'tcu_int_util_pct_user_kernel_body'),
        ('tcu_int', 'fire_mean_interval', 'tcu_int_fire_mean_interval'),
        ('tcu_int', 'fire_p50_interval', 'tcu_int_fire_p50_interval'),
    ]
    metric_specs.extend(_memory_metric_specs())

    for trace in traces:
        row = {'trace': trace}
        for phase in ('kernel_busy', 'warp_spawn', 'user_kernel_body'):
            row[phase] = _phase_cycle_value(phase_summary, trace, phase)

        if metadata_summary is not None and not metadata_summary.empty and 'trace' in metadata_summary.columns:
            meta = metadata_summary.loc[metadata_summary['trace'] == trace]
            if not meta.empty:
                for key in (
                    'elapsed_time_ms', 'b_device_layout', 'passed',
                    'b_col_major_config', 'dram_req_enter_pct',
                    'dram_req_exit_pct', 'dram_rsp_enter_pct',
                    'dram_rsp_exit_pct', 'dram_no_markov_stall',
                ):
                    if key in meta.columns:
                        row[key] = meta.iloc[0][key]

        for section, metric, name in metric_specs:
            row[name] = _summary_metric(metrics, trace, section, metric)

        if tcu_breakdown is not None and not tcu_breakdown.empty and 'trace' in tcu_breakdown.columns:
            sub = tcu_breakdown[tcu_breakdown['trace'] == trace]
            for phase in ('load_sync', 'compute', 'compute_loop_overhead', 'store_sync'):
                br = sub[sub['phase'] == phase]
                if br.empty:
                    continue
                item = br.iloc[0]
                prefix = phase
                for col in (
                    'dispatch_count', 'attributed_cycles', 'stall_or_gap_cycles',
                    'pct_user_kernel_body', 'p50_issue_interval',
                    'p90_issue_interval', 'p99_issue_interval', 'max_issue_interval',
                ):
                    row[f'{prefix}_{col}'] = item.get(col, 0)
            gap = sub[sub['phase'] == 'tcu_gap_summary']
            if not gap.empty:
                item = gap.iloc[0]
                for col in (
                    'p50_issue_interval', 'p90_issue_interval',
                    'p99_issue_interval', 'max_issue_interval',
                    'large_gap_threshold', 'large_gap_count',
                    'large_gap_cycles', 'large_gap_mean_interval',
                    'large_gap_pct_user_kernel_body',
                ):
                    row[f'tcu_gap_{col}'] = item.get(col, 0)
        rows.append(row)

    return pd.DataFrame(rows).set_index('trace') if rows else pd.DataFrame()


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

    fence_req = _first(fence_req_times)
    fence_rsp = _first(fence_rsp_times)

    first_user = _first_event_time(instruction_events, 'user_kernel')
    last_user = _last_event_time(instruction_events, 'user_kernel')
    first_perf = _first_event_time(instruction_events, 'perf_dump')
    last_perf = _last_event_time(instruction_events, 'perf_dump')
    first_after_user = (
        None if last_user is None
        else _first_event_time(instruction_events, after_time_ps=last_user)
    )
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
    tag_init_end = None
    if tag_init and tag_init['first_time_ps'] is not None:
        tag_init_end = tag_init['last_time_ps'] + clock_period_ps
        add_phase(
            'tag_init',
            tag_init['first_time_ps'],
            tag_init_end,
            'simv.log:tags-init',
            'inclusive log stream converted to exclusive end',
            tag_init['count'],
        )

    initial_spawn_events = [
        spawn for spawn in spawn_events
        if spawn.get('wspawn_wmask', 0)
        and (first_user is None or spawn['time_ps'] < first_user)
    ]
    initial_spawn_end = None
    if initial_spawn_events:
        spawn_active_times = _find_spawn_active_times(
            fsdb_events,
            sig['active_warps'],
            initial_spawn_events,
        )
        spawn_start = initial_spawn_events[0]['time_ps']
        initial_spawn_end = _last([t for t in spawn_active_times if t is not None])
        add_phase(
            'warp_spawn',
            spawn_start,
            initial_spawn_end,
            'fsdb:wctl_is_wspawn&&execute_fire -> active_warps',
            f'{len(initial_spawn_events)} initial WSPAWN fire events',
            len(initial_spawn_events),
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

    if first_user is None:
        fallback_user_start = initial_spawn_end or tag_init_end or core_start
        add_phase(
            'user_kernel_body',
            fallback_user_start,
            fence_req,
            'fallback:initial_warp_spawn/tag_init -> fence request',
            'ELF symbols unavailable; approximates device-side user kernel body',
        )
    else:
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


def analyze_sync_wait(fsdb_path=DEFAULT_FSDB, paths=DEFAULT_GEMM_PATHS, bt=None, et=None, top_n=None,
                      strict=False):
    """Count cycles spent in dbg_wait_active, grouped by wait_reg_id.

    A cycle is counted on a clk rising edge when dbg_wait_active is 1.
    The wait_reg_id value sampled at the same edge is used as the bucket.
    """
    fsdb_path = str(fsdb_path)
    sync_base = _resolve_sync_base(paths)
    clk = f'{sync_base}/clk'
    dbg_wait_active = f'{sync_base}/dbg_wait_active'
    in_valid = f'{sync_base}/in_valid'
    is_wait = f'{sync_base}/is_wait'
    wait_satisfied = f'{sync_base}/wait_satisfied'
    wait_reg_id = f'{sync_base}/wait_reg_id[7:0]'

    mode = 'dbg_wait_active'
    try:
        report = fsdb.report(fsdb_path, [clk, dbg_wait_active, wait_reg_id], bt=bt, et=et)
        if dbg_wait_active not in report.signal_names:
            raise RuntimeError(f'Missing signal: {dbg_wait_active}')
    except Exception as exc:
        if strict:
            raise
        mode = 'naive_wait_decode'
        report = fsdb.report(fsdb_path, [clk, in_valid, is_wait, wait_satisfied, wait_reg_id],
                             bt=bt, et=et)
    events = report.events()

    counts = defaultdict(int)
    first_time = {}
    last_time = {}
    active_windows = defaultdict(int)
    prev_clk = '0'
    prev_active_key = None

    for ev in events:
        clk_value = ev.values.get(clk, '0')
        if mode == 'dbg_wait_active':
            active = _is_one(ev.values.get(dbg_wait_active, '0'))
        else:
            active = (
                _is_one(ev.values.get(in_valid, '0'))
                and _is_one(ev.values.get(is_wait, '0'))
                and not _is_one(ev.values.get(wait_satisfied, '0'))
            )
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

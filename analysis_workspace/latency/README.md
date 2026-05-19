# Latency Analysis Outputs

This directory contains notebook helpers and CSV outputs for FSDB/simv.log
cycle analysis.

Main entry point:

```python
import cycle_util

result = run("", m1k256n256)
results = run_many_fpint_improve(interval_groups={"ldma", "mxu"})
```

## Common Columns

These columns appear in most `fpint_improve_*_summary.csv` files.

| column | meaning |
| --- | --- |
| `trace` | Log directory name, e.g. `fpint_improve_m256_k256_n256`. |
| `m`, `k`, `n` | Problem dimensions parsed from the trace name. |
| `section` | Hardware block or metric group, e.g. `mxu`, `ldma_input`, `hbm_dma_ch0`. |
| `metric` | Metric name inside the section. |
| `value` | Numeric metric value. |
| `unit` | Unit for `value`, e.g. `cycles`, `pct`, `bytes`, `B/cycle`. |

## Long-Form vs Compact CSVs

The `*_summary.csv` files are long-form tables. They are stable for scripting
because new metrics can be added as new rows without changing the schema.

The `*_compact.csv` files match the tables displayed by
`cycle_analysis.ipynb`. They pivot the most useful metrics into one row per
trace, so they are easier to compare by eye.

Generated compact files:

| file | source |
| --- | --- |
| `fpint_improve_phase_compact.csv` | `_compact_phase_view(phase_summary)` |
| `fpint_improve_sync_wait_compact.csv` | `_compact_sync_view(sync_summary)` |
| `fpint_improve_mpm_compact.csv` | `_compact_mpm_view(mpm_summary)` |
| `fpint_improve_util_compact.csv` | `_compact_util_view(util_summary)` |
| `fpint_improve_fire_interval_compact.csv` | `_compact_fire_interval_view(fire_interval_summary)` |
| `fpint_improve_hbm_access_interval_compact.csv` | `_compact_hbm_access_interval_view(hbm_access_interval_summary)` |
| `fpint_improve_hbm_read_latency_compact.csv` | `_compact_hbm_read_latency_view(hbm_read_latency_summary)` |

## Phase Summary

File: `fpint_improve_phase_summary.csv`

This table is kernel-agnostic. It combines FSDB windows and `simv.log` markers
to describe the runtime timeline.

| column | meaning |
| --- | --- |
| `phase` | Named runtime phase. See phase names below. |
| `start_time_ps`, `end_time_ps` | FSDB/log time window in ps. End is exclusive. |
| `start_cycle`, `end_cycle` | Time converted with `DEFAULT_CLOCK_PERIOD_PS=10000`. End is exclusive. |
| `cycles` | `end_cycle - start_cycle`. |
| `count` | Phase-specific count, e.g. WSPAWN events or cache tag count. May be empty. |
| `dispatch_count` | Number of decoded instruction dispatch events in the phase, when available. |
| `commit_count` | Number of commit events in the phase, when available. |
| `symbols` | ELF symbol names observed in the phase window. |
| `source` | Which source produced the window, e.g. FSDB signal, simv.log marker, or ELF-symbol analysis. |
| `note` | Short interpretation or caveat. |

Important phases:

| phase | meaning |
| --- | --- |
| `kernel_busy` | Device-side envelope from core busy high to low. Overlaps all sub-phases. |
| `runtime_bootstrap_to_user` | Startup work before first user/kernel symbol. Includes tag init, warp spawn, TLS/BSS/libc setup. |
| `tag_init` | Cache/tag initialization phase from simv log markers. |
| `warp_spawn` | Initial WSPAWN execution and active-warp visibility. |
| `user_kernel_body` | Kernel-specific code region, independent of GEMM counters. |
| `runtime_exit` | Runtime exit wrapper and cleanup after user kernel. |
| `perf_dump` | MPM/perf CSR dump section. |
| `exit_final_to_fence` | `_Exit` tail to fence request setup. |
| `fence_wait` | Fence request to fence response. |
| `cache_flush_tags`, `cache_flush_data` | Cache flush windows. Can overlap `fence_wait`. |
| `host_done_polling` | Host-side done polling tail after device completion. |

## Sync Wait Summary

File: `fpint_improve_sync_wait_summary.csv`

This counts cycles where `VX_gemm_sync.dbg_wait_active` is high, grouped by the
current `wait_reg_id`.

| column | meaning |
| --- | --- |
| `wait_reg_id` | Numeric sync register ID sampled while wait is active. |
| `wait_reg_name` | Decoded enum name. |
| `cycles` | Number of clock cycles spent waiting on this register. |
| `pct` | Share of total sync wait cycles in this trace. |
| `active_windows` | Number of separate wait-active windows for this register. |
| `first_time_1ps`, `last_time_1ps` | First/last FSDB timestamp where this wait was observed. |

Sync register names:

| name | meaning |
| --- | --- |
| `T0`, `T1` | Tile preload completion for double-buffered tile buffers. |
| `W0`, `W1` | Weight register/buffer readiness. |
| `SZ0`, `SZ1` | Scale/zero register readiness. |
| `G0`, `G1` | GEMM/MXU compute completion for double-buffered MXU buffers. |
| `O` | Output sequencing. Currently covers accumulator-to-LMEM and LMEM-to-DRAM output stages. |

Interpretation:

- High `G0/G1` means the parent stream is often waiting for MXU compute done.
- High `O` means output drain or output sequencing is visible on the critical path.
- High `W*`/`SZ*` means weight or quant-param preload is not hidden by double buffering.

## MPM Summary

File: `fpint_improve_mpm_summary.csv`

This is a long-form table of raw and derived MPM-style counters read from RTL
perf registers.

Important `section` values:

| section | meaning |
| --- | --- |
| `mxu` | GEMM/MXU counters and MXU port fires/stalls. |
| `cpu_dma` | CPU-side DMA unit counters. |
| `hbm_dma` | Aggregate HBM DMA counters. |
| `ldma_input` | Local DMA path feeding GEMM input. |
| `ldma_weight` | Local DMA path feeding GEMM weight registers. |
| `ldma_sz` | Local DMA path feeding scale/zero registers. |
| `ldma_output` | Local DMA path draining GEMM output/accumulator data. |

Important `mxu` metrics:

| metric | meaning |
| --- | --- |
| `busy_cycles` | Core busy envelope cycles, reused as a denominator. |
| `gemm_total_cycles` | GEMM controller total active cycles. |
| `gemm_compute_cycles` | Cycles classified as GEMM compute active. |
| `gemm_stall_cycles` | GEMM/MXU stall cycles counted by RTL. |
| `gemm_job_count` | Number of GEMM jobs/micro-ops counted. |
| `mxu_mac_count` | MAC operations counted by MXU perf logic. |
| `flops` | `mxu_mac_count * 2`. |
| `achieved_flops_per_cycle_total` | `flops / gemm_total_cycles`. |
| `overlap_dma_mxu_pct_total` | DMA/MXU overlap cycles divided by `gemm_total_cycles`. |
| `{input,weight,psum,output}_fire` | Fire count for each MXU-side stream. |
| `{input,weight,psum,output}_stall` | Stall count for each MXU-side stream. |
| `{input,weight,psum,output}_util_pct_total` | Stream fire count divided by `gemm_total_cycles`. |
| `{input,weight,psum,output}_util_pct_compute` | Stream fire count divided by `gemm_compute_cycles`. |
| `{input,weight,psum,output}_stall_pct_activity` | Stall / (`fire + stall`) for that stream. |

Important DMA/LDMA metrics:

| metric | meaning |
| --- | --- |
| `rd_bytes`, `wr_bytes` | Total read/write bytes counted by the DMA path. |
| `xfer_count` | Completed transfer count. |
| `active_cycles` | Cycles where the DMA/LDMA path is active. |
| `util_pct_busy` | Active cycles divided by `busy_cycles`. |
| `util_pct_total` | Active cycles divided by `gemm_total_cycles`. |
| `bandwidth_bytes_per_active_cycle` | (`rd_bytes + wr_bytes`) / active cycles. |
| `bandwidth_bytes_per_busy_cycle` | (`rd_bytes + wr_bytes`) / core busy cycles. |
| `{src_rd_req,src_rd_data,dst_wr}_fire` | Source read request, source read response/data, or destination write fire count. |
| `{src_rd_req,src_rd_data,dst_wr}_stall` | Corresponding valid-but-not-ready stall count. |
| `{src_rd_req,src_rd_data,dst_wr}_stall_pct_activity` | Stall / (`fire + stall`) for that event. |
| `active_max`, `active_min` | Max/min active cycles across HBM DMA channels. |
| `active_imbalance_pct` | `(active_max - active_min) / active_max`. |

`fpint_improve_mpm_compact.csv` also includes selected HBM access columns:
`hbm_rd_bytes`, `hbm_wr_bytes`, `hbm_active`, `hbm_bw_active_Bpc`,
`hbm_bw_busy_Bpc`, and `hbm_active_imbalance_pct`.

## Util Summary

File: `fpint_improve_util_summary.csv`

This is a compact derived table for the most useful utilization ratios. It is
computed from MPM counters plus phase windows.

| section | metric | meaning |
| --- | --- | --- |
| `mxu` | `active_pct_kernel_busy` | `gemm_total_cycles / kernel_busy`. |
| `mxu` | `active_pct_user_kernel_body` | `gemm_total_cycles / user_kernel_body`. |
| `mxu` | `compute_pct_gemm_total` | `gemm_compute_cycles / gemm_total_cycles`. |
| `mxu` | `stall_pct_gemm_total` | `gemm_stall_cycles / gemm_total_cycles`. |
| `mxu` | `flops_per_gemm_cycle` | `flops / gemm_total_cycles`. |
| `mxu` | `overlap_dma_mxu_pct_total` | DMA/MXU overlap ratio during GEMM total cycles. |
| `mxu_port` | `{input,weight,psum,output}_util_pct_total` | Port fire count / `gemm_total_cycles`. |
| `mxu_port` | `{input,weight,psum,output}_util_pct_compute` | Port fire count / `gemm_compute_cycles`. |
| `mxu_port` | `{input,weight,psum,output}_stall_pct_activity` | Port stall ratio while active. |
| `hbm_dma`, `ldma_*` | `active_pct_gemm_total` | Active cycles / `gemm_total_cycles`. |
| `hbm_dma`, `ldma_*` | `active_pct_user_kernel_body` | Active cycles / `user_kernel_body`. |
| `hbm_dma`, `ldma_*` | `util_pct_busy` | Active cycles / core busy cycles. |
| `hbm_dma`, `ldma_*` | `util_pct_total` | Active cycles / GEMM total cycles. |
| `hbm_dma`, `ldma_*` | `bandwidth_bytes_per_active_cycle` | Effective bandwidth while active. |

Interpretation:

- `mxu.active_pct_user_kernel_body` answers: how much of user-kernel time is GEMM controller active?
- `mxu.compute_pct_gemm_total` answers: inside GEMM time, how much is useful compute?
- `mxu_port.*_util_pct_compute` answers: during compute cycles, how often this port is actually firing.
- `ldma_* active_pct_gemm_total` can exceed 100% if the denominator is narrow or windows overlap conceptually; use it as relative pressure, not exclusive occupancy.

### Util Compact Columns

File: `fpint_improve_util_compact.csv`

These are aliases of selected long-form rows from `fpint_improve_util_summary.csv`.

| compact column | long-form source | meaning |
| --- | --- | --- |
| `mxu_active_user_pct` | `section=mxu`, `metric=active_pct_user_kernel_body` | `gemm_total_cycles / user_kernel_body * 100`. How much of user-kernel time the GEMM controller is active. |
| `mxu_compute_pct` | `section=mxu`, `metric=compute_pct_gemm_total` | `gemm_compute_cycles / gemm_total_cycles * 100`. |
| `mxu_stall_pct` | `section=mxu`, `metric=stall_pct_gemm_total` | `gemm_stall_cycles / gemm_total_cycles * 100`. |
| `flops_per_cycle` | `section=mxu`, `metric=flops_per_gemm_cycle` | Achieved flop/cycle over GEMM total cycles. |
| `mxu_input_util_compute` | `section=mxu_port`, `metric=input_util_pct_compute` | MXU input fire count / GEMM compute cycles * 100. |
| `mxu_weight_util_compute` | `section=mxu_port`, `metric=weight_util_pct_compute` | MXU weight fire count / GEMM compute cycles * 100. |
| `mxu_output_util_compute` | `section=mxu_port`, `metric=output_util_pct_compute` | MXU output fire count / GEMM compute cycles * 100. |
| `hbm_active_user_pct` | `section=hbm_dma`, `metric=active_pct_user_kernel_body` | HBM DMA active cycles / user-kernel body cycles * 100. |
| `hbm_bw_active_Bpc` | `section=hbm_dma`, `metric=bandwidth_bytes_per_active_cycle` | HBM DMA effective bytes/cycle while active. |
| `ldma_input_active_gemm_pct` | `section=ldma_input`, `metric=active_pct_gemm_total` | Input LDMA active cycles / GEMM total cycles * 100. |
| `ldma_weight_active_gemm_pct` | `section=ldma_weight`, `metric=active_pct_gemm_total` | Weight LDMA active cycles / GEMM total cycles * 100. |
| `ldma_sz_active_gemm_pct` | `section=ldma_sz`, `metric=active_pct_gemm_total` | Scale/zero LDMA active cycles / GEMM total cycles * 100. |
| `ldma_output_active_gemm_pct` | `section=ldma_output`, `metric=active_pct_gemm_total` | Output LDMA active cycles / GEMM total cycles * 100. |

## Fire Interval Summary

File: `fpint_improve_fire_interval_summary.csv`

This table measures spacing and burstiness of fire/valid signals. It is useful
for checking whether DMA/LDMA/MXU streams are issuing in bursts.

Important `section` values:

| section | meaning |
| --- | --- |
| `cpu_dma` | CPU DMA unit fire signals. Often zero for GEMM-only traces. |
| `hbm_dma_ch0..7` | Per-channel HBM DMA unit logical perf fire signals. Use the HBM access interval table for physical HBM-side read/write streams. |
| `ldma_input`, `ldma_weight`, `ldma_sz`, `ldma_output` | Local DMA stream fire signals. |
| `mxu` | MXU-side stream fire signals. |

Important `stream` values:

| stream | meaning |
| --- | --- |
| `src_rd_req` | Source-side read request fire. In L2G, source is LMEM, not HBM. |
| `src_rd_data` | Source-side read response/data fire. In L2G, source is LMEM, not HBM. |
| `dst_wr` | Destination-side write request fire. In G2L, destination is LMEM; in L2G, destination is HBM. |
| `input`, `weight`, `psum`, `output` | MXU stream fire signals. |

Columns:

| column | meaning |
| --- | --- |
| `kind` | Signal preset type. Usually `fire`; can be `valid` for custom valid-only specs. |
| `signal` | Full FSDB signal path used. |
| `note` | Short note about the preset. |
| `time_unit` | FSDB report time unit. Usually `1ps`. |
| `event_count` | Number of active cycles after expanding high windows. |
| `interval_count` | Number of intervals, normally `event_count - 1`. |
| `first_cycle`, `last_cycle` | First/last active cycle observed. |
| `min_interval`, `max_interval` | Min/max cycle distance between consecutive active cycles. |
| `mean_interval` | Average cycle distance between consecutive active cycles. |
| `p50_interval`, `p90_interval`, `p99_interval` | Interval percentiles. `p50=1` usually means back-to-back issue dominates. |
| `burst_gap_cycles` | Max interval considered part of the same burst. Default is `1`, so only consecutive cycles form a burst. |
| `burst_count` | Number of bursts after grouping active cycles by `burst_gap_cycles`. |
| `max_burst_len` | Longest burst length in cycles/events. |
| `mean_burst_len` | Average burst length. |
| `multi_event_burst_count` | Number of bursts with length >= 2. |
| `multi_event_burst_event_pct` | Percent of active events that belong to length >= 2 bursts. |
| `consecutive_interval_pct` | Percent of intervals that are <= `burst_gap_cycles`. High value means bursty/back-to-back behavior. |
| `bubble_interval_count` | Number of intervals greater than `burst_gap_cycles`. |
| `mean_bubble_cycles` | Average bubble length beyond `burst_gap_cycles`. For default gap=1, interval 5 contributes 4 bubble cycles. |

Interpretation:

- `max_burst_len=1` means no consecutive-cycle burst was observed for that signal.
- `p50_interval=1` and high `consecutive_interval_pct` mean the stream is mostly issuing back-to-back.
- Large `p90_interval` or `p99_interval` means long bubbles exist even if median behavior is bursty.
- Compare `src_rd_req`, `src_rd_data`, and `dst_wr` for the same LDMA/DMA path to locate where bursts are broken.

## HBM Access Interval Summary

File: `fpint_improve_hbm_access_interval_summary.csv`

Compact file: `fpint_improve_hbm_access_interval_compact.csv`

This table measures physical HBM-side access spacing and burstiness for GEMM
HBM DMA channels. Unlike the generic fire interval table, these streams are
direction-aware.

Important `stream` values:

| stream | meaning |
| --- | --- |
| `read_req` | G2L HBM read request accepted: `in_g2l_active && src_req_fire`. |
| `read_rsp` | G2L HBM read response beat returned: `g2l_rd_beat`. |
| `write_req` | L2G HBM write request accepted: `l2g_wr_beat`. |

Columns are the same interval/burst statistics as `fpint_improve_fire_interval_summary.csv`,
plus `channel` and `condition`.

Compact columns use prefixes `hbm_read_req`, `hbm_read_rsp`, and
`hbm_write_req` with these suffixes:

| suffix | meaning |
| --- | --- |
| `_events` | Sum of active events across HBM DMA channels. |
| `_p50_min` | Best per-channel p50 interval for this stream. |
| `_p90_max` | Worst per-channel p90 interval for this stream. |
| `_max_burst` | Largest burst observed on any HBM DMA channel. |
| `_consec_pct_mean` | Mean consecutive-interval percentage across HBM DMA channels. |

## HBM Read Latency Summary

File: `fpint_improve_hbm_read_latency_summary.csv`

Compact file: `fpint_improve_hbm_read_latency_compact.csv`

This table estimates HBM read request-to-response latency per GEMM HBM DMA
channel. It samples request cycles from `in_g2l_active && src_req_fire` and
response cycles from `g2l_rd_beat`.

Important `section` values:

| section | meaning |
| --- | --- |
| `hbm_dma_ch0..7` | Per-channel HBM DMA read latency. |
| `hbm_dma_all` | Aggregate of all per-channel latency samples. |

Columns:

| column | meaning |
| --- | --- |
| `channel` | HBM DMA channel ID, or `all` for the aggregate row. |
| `stream` | Currently `read`. |
| `matching` | Matching policy. Currently channel-local FIFO aggregation. |
| `unit` | Latency unit, currently `cycles`. |
| `request_signal`, `request_condition` | Source signal and derived condition used for HBM read request cycles. |
| `response_signal`, `response_condition` | Source signal and derived condition used for HBM read response cycles. |
| `req_count`, `rsp_count` | Number of request/response active cycles observed. |
| `matched_count` | Number of request/response pairs used for latency samples. |
| `unmatched_req_count` | Requests with no later matched response in the sampled window. |
| `orphan_rsp_count` | Responses observed before a matchable request in the sampled window. |
| `first_req_cycle`, `last_req_cycle` | First/last request cycle. |
| `first_rsp_cycle`, `last_rsp_cycle` | First/last response cycle. |
| `min_latency`, `mean_latency`, `p50_latency`, `p90_latency`, `p99_latency`, `max_latency` | Request-to-response latency statistics. |

Compact columns:

| compact column | meaning |
| --- | --- |
| `hbm_read_req_count`, `hbm_read_rsp_count`, `hbm_read_matched_count` | Aggregate HBM read request/response/pair counts. |
| `hbm_read_mean_latency`, `hbm_read_p50_latency`, `hbm_read_p90_latency`, `hbm_read_p99_latency`, `hbm_read_max_latency` | Aggregate HBM read latency stats in cycles. |
| `hbm_read_unmatched_req_count`, `hbm_read_orphan_rsp_count` | Aggregate matching quality counters. Non-zero values mean the sampled window cut through live traffic or the matching assumption is weak. |

Interpretation:

- Bandwidth and utilization are not the same metric. Bandwidth is bytes per cycle, e.g. `rd_bytes + wr_bytes` divided by active or busy cycles. Utilization is the fraction of cycles where the path is active.
- A path can have high utilization with low bandwidth if it is active but issuing narrow/sparse transfers, or low utilization with high bandwidth if it bursts efficiently.
- HBM read latency here is not a bandwidth metric. It tells how long accepted G2L HBM read requests take to produce response beats.

## Known Caveats

- Phase windows are not mutually exclusive. `kernel_busy` is an envelope, and cache flush can overlap fence wait.
- HBM model timing in simulation is approximate. Use HBM-related numbers for relative bottleneck detection, not final hardware bandwidth.
- `fire_interval_summary` expands high windows into cycles using `DEFAULT_CLOCK_PERIOD_PS`. If a signal remains high at the end of the report window, the open-ended tail is counted as one observed cycle unless `sample_on_clk=True` is used directly in `cycle_util.analyze_signal_intervals`.
- `hbm_read_latency_summary` uses channel-local FIFO matching because the current FSDB dump does not expose the dcache response tag. It is exact for in-order channel responses and an approximation if responses return out of order.
- Some interface signals are not dumped under their SystemVerilog interface names. Prefer the preset `perf_*_fire` signals unless you have verified the exact FSDB path.

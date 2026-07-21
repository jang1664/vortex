# Performance Monitor Timing Baseline

## Provenance

- Current source revision at task start: `b07d1c24620ee5393e6d12bc1b2f9467a268461e`
- Target configuration: `configs/improve_th32_tcol32_hwexp_dcache.sh`
- Historical checkpoint: `build/hw/syn/xilinx/xrt/improve_th32_tcol32_hwexp_dcache_pack16_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/level0_wrapper_placed.dcp`
- Historical timing report: `build/hw/syn/xilinx/xrt/improve_th32_tcol32_hwexp_dcache_pack16_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/hw_bb_locked_timing_summary_placed.rpt`

The historical checkpoint is source-unmatched candidate-selection evidence. It is not a valid before/after baseline for the current generalized misaligned-DMA source tree.

## Selected Paths

| Group | Endpoints | Historical placed slack | Data path (logic / route) | Levels | CSR class/address | Planned boundary |
|---|---:|---:|---|---:|---|---|
| CPU DMA `perf_xfers_r` | 1,144 | `-2.674 ns` | `12.236 ns` (`3.348 / 8.888 ns`) | 40 | class 4, `B07/B87` | `dma_xfer_done_q` |
| D-cache pending reads feeding load latency | 88 | `+1.736 ns` | `7.446 ns` (`0.878 / 6.568 ns`) | 13 | class 1, `B12/B92` | signed pending-read delta register |
| L3 bypass reads | 352 | `+1.742 ns` | `7.299 ns` (`0.795 / 6.504 ns`) | 10 | class 2, `B12/B92` | L3 read-popcount register |
| Global-memory reads | 88 | `+1.744 ns` | `7.294 ns` (`0.790 / 6.504 ns`) | 10 | class 2, `B18/B98` | global read-popcount register |

## Query Contract

`agent-tasks/perf-monitor-timing/query_perf_paths.tcl` queries only these four groups. Each group produces either a timing report and endpoint count or an explicit `NO_PATH` record containing the attempted pattern.

The script was validated read-only against the historical placed checkpoint on 2026-07-20. The four reports are under `agent-tasks/perf-monitor-timing/historical_query/`; no implementation step was launched.

## Post-Batch Synthesis

Pending. Populate this section only after all functional gates pass and the sole permitted synthesis completes. Record synthesized boundary cells, source-to-stage paths, estimated timing, and hierarchical LUT/FF/control-set utilization. Do not record or claim placed/routed closure.

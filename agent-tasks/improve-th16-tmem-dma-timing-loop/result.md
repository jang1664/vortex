# TH16 TMEM DMA Timing-Loop Result

## Result

The two targeted combinational loops are absent from the freshly synthesized
TH16/TMEM16/DMA8/HBM8/WLOAD8 IMPROVE kernel.

| Check | Before | After | Result |
|---|---:|---:|---|
| Vivado `TIMING-23` combinational loops | 2 | 0 | PASS |
| Vivado `LUTLP-1` checks | 36-cell loop in the failed implementation log | 0 | PASS |
| `check_timing` combinational loops | Not separately preserved | 0 | PASS |

The fresh Vivado 2025.1 `vortex_afu` synthesis completed with zero errors and
zero critical warnings. This was a standalone post-synthesis kernel check, not
a complete U55C placement-and-routing run. It is sufficient to inspect the two
kernel-internal loops that appeared in the earlier post-init methodology report.

## Performance

Workload: `fpint_gemm_ffn_hw -m 4 -n 256 -k 256 -q 32 -t 0`, WLOAD8,
IMPROVE TH16/TMEM16/DMA8/HBM8, XRT-VCS, performance class 3.

| Direction | Before cycles | After cycles | Cycle delta | Before DMA overlap | After DMA overlap | Overlap delta |
|---|---:|---:|---:|---:|---:|---:|
| QCOL | 609 | 599 | -10 (-1.642%) | 64.007% (345/539) | 64.870% (349/538) | +0.863 pp |
| QROW | 607 | 603 | -4 (-0.659%) | 64.595% (343/531) | 64.607% (345/534) | +0.012 pp |

Both runs passed all 1,024 numerical outputs, exact Input/Weight/Output traffic,
zero DMA stalls, zero PSUM underflow/read-write conflict, and clean shutdown.

## RTL Changes

- Global DMA channel `ready` is owned only by registered channel state and the
  old-command completion handshake. Chained `valid` and `ACTIVATE` no longer
  depend on the all-channel ready reduction; only the fire event consumes the
  candidate and updates ownership.
- Output DMA physical `write_done` is registered once at the GEMM-node boundary.
  The controller observes logical completion one cycle later, while physical
  accounting remains on the raw completion pulse.
- Assertions check atomic active-channel acceptance, stable held offers, exact
  direct chained transition, sticky old-command completion, and exact raw-to-
  logical Output completion delay. No per-channel fence was added.

## Evidence

- Old report: `build/hw/syn/xilinx/xrt/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1/post_init_methodology.rpt`
- New methodology: `build/run_logs/improve-th16-tmem-dma-timing-loop/vivado_loop_check/post_synth_methodology.rpt`
- New LUT-loop DRC: `build/run_logs/improve-th16-tmem-dma-timing-loop/vivado_loop_check/post_synth_lutlp.rpt`
- New timing checks: `build/run_logs/improve-th16-tmem-dma-timing-loop/vivado_loop_check/post_synth_check_timing.rpt`
- Vivado log: `build/run_logs/improve-th16-tmem-dma-timing-loop/vivado_loop_check/vivado_synth_retry.log`
- XRT-VCS artifacts: `build/run_logs/improve-th16-tmem-dma-timing-loop/iteration3_blackbox`

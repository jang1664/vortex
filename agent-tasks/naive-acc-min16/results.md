# Naive ACC current vs minimum-16 buffering

TH16, MXU16, K=N512, q32, qdir0, transpose0, repeat1, xrt-vcs-sim. All runs passed numerical checks without source changes during execution.

Current means the three named `_acc.sh` configs, including BUF8 for BW256. It is not the per-workload best point from previous sweeps.

| Profile capacity | Current | Minimum16 |
|---|---:|---:|
| External DMA outstanding | 32 | 32 |
| Splitter depth | 8 | 16 |
| Weight response slots | 8 | 16 |
| ACC output DMA slots | 16 | 16 |
| Input response slots / lane FIFO | 16 / 8 | 16 / 16 |
| Scale and zero response slots / lane FIFO, each | 8 / 4 | 16 / 16 |

BW64 has no cache splitter; its splitter depth affects LMEM only. Cache internals, command queues, skids and ACC capacity are unchanged.

| Topology | M | Current GEMM | Minimum16 GEMM | GEMM change | Current core | Minimum16 core | Core change |
|---|---:|---:|---:|---:|---:|---:|---:|
| l16_bw64 | 4 | 13,502 | 13,322 | -1.33% | 20,079 | 19,929 | -0.75% |
| l16_bw64 | 256 | 304,956 | 300,931 | -1.32% | 311,529 | 307,479 | -1.30% |
| l32_bw64 | 4 | 13,053 | 12,850 | -1.56% | 19,629 | 19,404 | -1.15% |
| l32_bw64 | 256 | 299,334 | 296,071 | -1.09% | 305,904 | 302,679 | -1.05% |
| l32_bw256 | 4 | 14,953 | 12,385 | -17.17% | 21,531 | 18,981 | -11.84% |
| l32_bw256 | 256 | 295,631 | 291,853 | -1.28% | 302,256 | 298,431 | -1.27% |

All 11 final unit checks passed. All six current-profile runs reproduce their prior GEMM/core cycles exactly. Improve M4/M256 also reproduce prior cycles exactly; all1,144 selected-RTL comparisons pass. No synthesis was run.

This is one combined minimum-capacity experiment, not an independent sweep of each parameter. Numerical correctness, unit coverage and final status are recorded in STATUS.yaml and verification/.

## Follow-up: 16 response slots with lane FIFO4

Only input/scale/zero lane response FIFO depth changes from16 to4. These FIFOs precede tag-indexed OOO response RAM; the output holding stage is unchanged. All slot settings retain the minimum16 profile (external DMA32, other scoped slots16). No RTL changes were needed for this follow-up.

| Topology | M | FIFO16 GEMM | FIFO4 GEMM | GEMM change | FIFO16 core | FIFO4 core | Core change |
|---|---:|---:|---:|---:|---:|---:|---:|
| l16_bw64 | 4 | 13,322 | 13,322 | +0.00% | 19,929 | 19,929 | +0.00% |
| l16_bw64 | 256 | 300,931 | 300,931 | +0.00% | 307,479 | 307,479 | +0.00% |
| l32_bw64 | 4 | 12,850 | 12,850 | +0.00% | 19,404 | 19,404 | +0.00% |
| l32_bw64 | 256 | 296,071 | 296,071 | +0.00% | 302,679 | 302,679 | +0.00% |
| l32_bw256 | 4 | 12,385 | 12,385 | +0.00% | 18,981 | 18,981 | +0.00% |
| l32_bw256 | 256 | 291,853 | 291,853 | +0.00% | 298,431 | 298,431 | +0.00% |

All six FIFO4 runs passed numerical verification with no source changes during execution. Config audits verify that only the two lane-FIFO depth defines differ from minimum16. The completed FIFO4 M4 waveforms pass all58 capacity checks, confirming FIFO4 and retained slot capacities. The unit and improve controls above belong to the preceding RTL implementation experiment and were not rerun for this config-only follow-up.

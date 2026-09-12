# Naive external DMA depth 16 baseline

Fresh xrt-vcs-sim waveform baseline, using TH16/MXU16, K=N=512, q=32, t=0, d=0, r=1. Weight response slots remain 8; PSUM read/response slots remain 16. The configured build is `build_dma_slots_naive16_vcs`. The config sources `configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh` and explicitly sets `DMA_NODE_RD_OUTSTANDING_SLOT=16`.

| M | GEMM cycles | Core cycles | Result |
|---|---:|---:|---|
| 4 | 15,867 | 22,404 | PASS |
| 256 | 671,929 | 678,504 | PASS |

Both runs match the previous numeric weight8 baseline exactly. The runner checks wrapper and simulation logs using `tools/verify_rtl.py` helpers, requires one observer completion and one core cycle record, and verifies unchanged source hashes. Both runs have successful process returns, no strict failures, and no source changes during execution.

Closed waveforms and complete manifests are in `../runs/naive/slots16-m4/` and `../runs/naive/slots16-m256/`. `results-slots16.json` contains the structured verification results. Run `python3 agent-tasks/dma-read-slot-saturation/baseline16/run.py --depth 16` to reproduce both shapes; M4 rebuilds the simulator, and M256 reuses it.

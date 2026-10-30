# Unified MMIO verification handoff

Baseline: frozen detached worktree at `12382c8834833204d3bd89e69226efd073737f1d`. Candidate: `build_c4_unified_mmio` from current worktree. Both were configured with XLEN64 and sourced `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`; full-core runs used `ci/run_black.sh xrt-vcs-sim`, identical `-DDISABLE_FSDB`, and no added diagnostic/performance defines. Exact commands, config strings, source/artifact hashes and raw logs are under `baseline/` and `candidate/`.

All five baseline cases and all nine final candidate full-core cases passed. Serializer and integrated GEMM-node FP16/FP32 units passed through `tools/verify_rtl.py`.

| Case | Baseline core cycles | Candidate core cycles | Delta | Baseline attention | Candidate attention | Delta |
|---|---:|---:|---:|---:|---:|---:|
| fp32_multitile | 125242 | 135596 | +8.27% | 118983 | 129386 | +8.74% |
| fp16_multitile | 114571 | 117083 | +2.19% | 108368 | 110929 | +2.36% |
| legacy_single | 97867 | 97024 | -0.86% | 91664 | 90870 | -0.87% |
| fp32_tail | 401558 | 447594 | +11.46% | 395297 | 441379 | +11.66% |
| fp32_mask | 377574 | 425439 | +12.68% | 371313 | 419224 | +12.90% |

The SRAM-resident cases require more cycles after this change. DMA time moved inside GEMM completion, so individual `gemm_wait`/`sram_copy` phases are not directly comparable; total/core cycles are. These numbers do not measure routed Fmax or board wall time.

Additional functionality:

- `mmio_serialization`: 16 lanes, one allocation at the actual C4 one-slot capacity, all response/data checks passed; kernel 4193 cycles, core 10117. The serializer unit separately covers four slots, byte enables, response backpressure, RO hardware status, reset and publication blocking.
- `sram_early_return`: both launches completed and the entire 65536-byte roundtrip matched (`errors=0`). Initial 300-second wall timeout was preserved; the authorized 1200-second retry passed with assertions and polling unchanged. Count this as one final case.
- FP32 `pv-overflow` and `qk-overflow`, M1/KV128: both device/reference comparisons were exact. PV partial reference reached 114688, above FP16 finite range. Each core count was 67079 and attention total 60864.
- Integrated FP32 node unit: 256 values above 65504, FP32 half-row backpressure, switch back to FP16 without reset, no intermediate HBM, invalid descriptors, physical completion and 1920 delayed LMEM commits passed.

Evidence / limits:

- `cycle_comparison.json`, `baseline/results.json`, `candidate/results.json`, and `candidate/functionality_results.json` are machine-readable receipts.
- Unit reports and archived compile/simulation logs are in `verification/`; resolved iterations are recorded in `STATUS.yaml`. Two attempts with invalid zsh config sourcing/cached config are explicitly named `invalid_*` and excluded from results. Valid reruns used explicit bash and a fresh node compile.
- The wrapper rebuilt an unchanged `VX_tmem_wide_read_switch` before focused apps, changing the binary hash. `candidate/setup.json` preserves separate paired-performance and focused-test binary hashes. Parent verified that source byte-identical to baseline; config and captured candidate source hashes remain identical.
- Parent-provided narrow OOC receipt: `mmio-cost/runs/measurement1/comparison.json`, retained MMIO path including serializer: LUT 7912 -> 3134 (-60.39%), FF 11942 -> 3996 (-66.54%). Excludes removed fusion controller/link, new SRAM sequencer, whole-chip totals and routed timing.
- Parent checked `vx_tvm_gemm.h` using C4 host syntax-only compilation; no TVM end-to-end claim.
- No PnR, FPGA hardware run, commit or RTL/software fix was performed by this verification agent. No active owned simulation processes remain.

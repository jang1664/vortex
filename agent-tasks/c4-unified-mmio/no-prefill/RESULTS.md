# Remove per-GEMM output prefill: verified results

Completed on 2026-10-30. Removed the unnecessary output-prefill states from `VX_gemm_sram_io`. FlashAttention initializes TMEM OBUF once using the existing copy-only descriptor, then reuses its initialized padding. Every GEMM overwrites active output elements and copies the completed padded reservation back to LMEM. Old LMEM output is no longer read before GEMM. The scalar MMIO interface, input DMA, publication and physical write-completion safeguards remain in place.

## Functionality

- FP16 and FP32 integrated node tests: PASS through `tools/verify_rtl.py`.
- Tests poison the old LMEM destination, initialize OBUF once for repeated jobs, and check active results and zero padding after every job. A new layout is explicitly initialized for the FP32-to-FP16 switch.
- Actual accepted DMA command counters prove HBM/TMEM input jobs have **0 LMEM-to-TMEM commands and 1 TMEM-to-LMEM command**. LMEM input jobs have **1 input copy and 1 output copy**. There is no automatic output prefill.
- Copy-only command counts, invalid-job/no-traffic checks, FP32 values above 65504, legacy HBM and delayed physical write commits also pass.
- Seven full-core `xrt-vcs-sim` cases: FP16/FP32 multi-tile, legacy HBM, FP32 tail, causal mask, PV-overflow and QK-overflow all PASS with unchanged numerical checks. Both overflow comparisons have max_abs=0.
- The unchanged MMIO serializer and 64-KiB early-return application were validated in the previous revision; they were not rerun for this correction.

## Core cycle comparison

All measurements use the same C4 config, XLEN64 build, wrapper and `-DDISABLE_FSDB`. Original baseline is frozen commit `12382c883`. Prior unified is the first MMIO implementation with the unnecessary prefill. Corrected is this revision. Lower cycles mean lower latency at the same clock; these are not host wall-time or routed-Fmax measurements.

| Workload | Original baseline | Prior unified + prefill | Corrected | vs original | vs prior prefill |
|---|---:|---:|---:|---:|---:|
| FP32 SRAM M4/KV256 | 125,242 | 135,596 | 119,785 | -4.36% | -11.66% |
| FP16 SRAM M4/KV256 | 114,571 | 117,083 | 109,344 | -4.56% | -6.61% |
| Legacy HBM M4/KV128 | 97,867 | 97,024 | 96,742 | -1.15% | -0.29% |
| FP32 SRAM tail M16/KV257 | 401,558 | 447,594 | 392,874 | -2.16% | -12.23% |
| FP32 SRAM causal M16/KV384 | 377,574 | 425,439 | 369,261 | -2.20% | -13.20% |

SRAM attention uses **2.16–4.56% fewer core cycles than the original baseline**, and **6.61–13.20% fewer than the prefill revision** for these four paired resident workloads. Legacy HBM also passes.

## Copy schedule

For T KV tiles, copies are restored from `5*T` to `3*T+1`: one initial OBUF copy, then QK output, PV input and PV output for each tile.

| Workload | Prefill revision copies / bytes | Corrected copies / bytes |
|---|---:|---:|
| FP16 M4/KV256 | 10 / 20,480 | 7 / 14,336 |
| FP32 M4/KV256 | 10 / 36,864 | 7 / 24,576 |
| FP32 M16, three KV tiles | 15 / 110,592 | 10 / 69,632 |

Corrected copy counts/bytes match the original schedule. Full-core software reports descriptor-derived counts; independent RTL command assertions provide the no-prefill evidence. `sram_copy` now times the one-time initialization, while per-GEMM DMA is included in `gemm_wait`. Compare total/core cycles, not individual phase labels across versions.

## Evidence and limits

- [Results](results.json), [three-version comparisons](cycle_comparison.json), [configuration and hashes](setup.json), [iterations](STATUS.yaml), and unit receipts under `verification/`.
- A stale initial full-core executable was detected because the existing Makefile did not depend on the changed child RTL. Those attempts were stopped and preserved under `invalid_stale/`; they are excluded from all results above. The old executable was moved aside, then the ordinary wrapper rebuilt it. The valid build log explicitly records recompilation of `VX_gemm_sram_io`; new binary hash/mtime and unchanged final source hashes are recorded.
- No PnR or new resource synthesis was run. The earlier retained-MMIO resource measurement excludes this sequencer, and its measured modules are unchanged. No routed-Fmax claim is made.
- Output padding belongs to the caller-owned TMEM reservation. Copyback includes that padding; it does not preserve arbitrary old LMEM destination bytes. Reinitialize scratch when a changed shape/format requires different padding.

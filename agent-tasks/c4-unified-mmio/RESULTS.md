# Initial unified C4 MMIO results (with per-GEMM output prefill)

> Historical results for the first implementation. The unnecessary per-GEMM
> output prefill has since been removed and revalidated. Current results are in
> [no-prefill/RESULTS.md](no-prefill/RESULTS.md). Numbers below describe the
> initial implementation, not the current RTL.

Implemented the ordinary GEMM MMIO extension and a source-side LSU lane serializer. The standalone fusion MMIO controller and its vector transport are no longer instantiated. The same GEMM descriptor owns optional LMEM input transfer, GEMM execution, output preservation/copyback and final physical write completion.

## ABI and RTL

- Feature-on descriptor: 46 words. IO_CONTROL (44) selects HBM/TMEM/LMEM input/output and FP32 export; IO_ERROR (45) reports completion errors. Allocation resets both to zero.
- PUBLISH/CAPS share the ordinary MMIO window. No independent DMA register bank remains.
- Every active lane is serviced in ascending order, one scalar register access at a time. Read responses retain the original tag and return one-hot masks; byte enables and backpressure are preserved.
- SIMD continues through the existing LMEM crossbar; TMEM has no new crossbar. Existing core reset is used.
- Software uses the matching descriptor stride, including attention, FFN/eladd helpers and the TVM GEMM header. ABI v3 requires matching RTL/software; old resident r5 binaries use ABI v2.
- C4 without GEMM_SRAM_FUSION has byte-identical preprocessed core/frontend/register bank/node RTL and configuration macros against the baseline. See [identity evidence](feature_off_identity/result.json).

## Cycle comparison

Baseline: commit `12382c883`, frozen in a separate worktree. Candidate and baseline use the same `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`, configured XLEN64 build, and `ci/run_black.sh xrt-vcs-sim` with `-DDISABLE_FSDB`. All five workloads pass the unchanged numerical checks. These are simulated core cycles; positive change means longer execution at the same clock.

| Workload | Baseline core cycles | Candidate core cycles | Change |
|---|---:|---:|---:|
| FP32 SRAM, M4 / KV256 | 125,242 | 135,596 | +8.27% |
| FP16 SRAM, M4 / KV256 | 114,571 | 117,083 | +2.19% |
| Legacy HBM, M4 / KV128 | 97,867 | 97,024 | -0.86% |
| FP32 SRAM tail, M16 / KV257 | 401,558 | 447,594 | +11.46% |
| FP32 SRAM causal, M16 / KV384 | 377,574 | 425,439 | +12.68% |

Full core/attention totals and exact arguments: [cycle_comparison.json](cycle_comparison.json). Source/build records: [baseline](baseline/setup.json), [candidate](candidate/setup.json).

The unified output-LMEM path currently prefills the TMEM output reservation from LMEM for every GEMM to preserve inactive/padded output bytes. The old attention schedule initialized that reservation once and reused it. Thus internal copies change from `3*T+1` to `5*T` for T KV tiles. FP32 M4/KV256 moves 24,576 → 36,864 SRAM bytes; M16/KV257 moves 69,632 → 110,592 bytes. This added transfer work is a primary explanation for the SRAM-path cycle regressions; no isolated prefill ablation was run. GEMM submit cycles for FP32 M4 decrease 8,004 → 6,096, while combined GEMM-wait/copy cycles increase 38,081 → 50,606. Internal DMA now belongs to GEMM-wait, so the old separate copy timing field cannot be compared directly.

## Scoped MMIO resource comparison

Both variants were synthesized with Vivado 2025.1 for U55C, the same 5 ns synthesis target, production C4 parameters (16 LSU lanes, one descriptor entry), and the same existing OOC flow. The measured candidate includes the new serializer and expanded frontend.

| Retained GEMM MMIO path | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Total LUTs, including LUTRAM | 7,912 | 3,134 | -60.39% |
| FFs | 11,942 | 3,996 | -66.54% |

This boundary excludes both the removed fusion controller/link and the new SRAM sequencer. It is not a whole-design utilization result. Exact hierarchy, source snapshots, commands and reports: [MMIO cost report](mmio-cost/README.md). No PnR was run, and routed Fmax or FPGA wall-time speedup is not established.

## Functionality evidence

- Directed serializer unit: PASS, 49 scalar requests; multi-entry allocation, simultaneous lanes, byte enables, deterministic ordering, stalled responses, 20-cycle publication wait, read-only status/HW update, descriptor reuse, and reset.
- Integrated GEMM node: FP16 and FP32 PASS. Includes copy roundtrip, HBM/LMEM/TMEM input, LMEM output, no HBM intermediate writes, rejected commands without traffic, publication, delayed final LMEM commits, values beyond FP16 range, and FP32→FP16 mode switch.
- Five paired full-core attention cases above: PASS.
- Actual 16-lane MMIO full-core app: PASS, errors=0; C4 one-slot allocation and all lane responses verified. The directed unit separately checks four slots.
- 64 KiB early-return roundtrip across two kernel launches: PASS, 65,536 bytes compared with errors=0. The first attempt exceeded a 300-second command budget after reaching the second launch; the unchanged test passed with a 1,200-second budget. No RTL, assertion or in-kernel polling limit changed for this retry.
- FP32 PV-overflow and QK-overflow device probes: PASS, both max_abs=0 against the reference. PV partial reaches 114,688, above FP16's 65,504 limit. See [focused results](candidate/functionality_results.json). In total, nine distinct full-core functionality cases pass; the timed-out first early-return attempt is retained separately.
- TVM header adaptation: C4 host syntax-only compile PASS; no TVM end-to-end execution is claimed.
- Initial unit failures were harness issues: missing XLEN64, missing generated hardware header, and publication sampling off-by-one. The assertions were preserved; corrected runs pass. Full iteration receipts: [STATUS.yaml](STATUS.yaml).

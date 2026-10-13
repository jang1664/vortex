# C4 decoder: batch QK/PV heads within one device launch

The decoder now launches QK once and PV once. Each launch walks an array of original GEMM arguments and calls the existing MMIO driver sequentially. Head shapes, GQA grouping, layouts and arithmetic are unchanged. The default is `--attention-launch batched`; `per-head` retains the previous launch policy for comparison. No RTL, standalone GEMM source/ABI, or latency_on_hw measurement was changed.

## Conditions

- C4 rev7 alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm`, 100 MHz, one core, TH16/MXU16.
- B1 decode, one step, past KV1024 / active KV1025 / capacity1152; full-size Llama2-7B and Llama3-8B decoder layers with the existing random fixtures.
- Fixed boards: Llama2 `0000:2a:00.1`, Llama3 `0000:3d:00.1`. Every runtime log confirms the BDF. Slurm job 5847.
- The original executable was preserved and remeasured (five wall and five profile passes). The new executable ran per-head then batched, followed by batched then per-head (ten wall and ten profile passes per policy). Tables use medians of complete-pass totals, not sums of independent operation medians.
- Wall time brackets `decoder.run(false, {})`. Allocation, uploads, tensor dumps, verification and counter queries are outside it. Device profiles are separate passes; wall minus device is not a direct pure host-overhead measurement.
- Estimate: `th16_20261011_rev7_decoder_semantics/combined/composed.csv`, generation rows divided by 32 layers. All selected rows are measured/pass. Error = `(estimate / measured - 1) * 100`.

## Functionality

| Model | Decode CPU gate | Prefill S32 CPU gate | Bit-identical buffers per mode comparison |
|---|---|---|---:|
| llama2-7b | PASS; 0/4096 violations | PASS; 1464/131072 violations | 342 |
| llama3-8b | PASS; 0/4096 violations | PASS; 1/131072 violations | 102 |

All saved buffers, including scores, probabilities, context, updated K/V caches and final outputs, are bit-identical between per-head and batched runs in both stages. Decode final outputs also match the preserved original executable bit-for-bit. No NaN/Inf occurred and no tolerance changed. The existing final-output gate permits limited finite deviations from the CPU reference; PASS is not a claim of exact CPU equality. Functionality completed before timed runs. Prefill S1024 was not remeasured in this update.

## Complete decoder wall time versus estimate

| Model | Original measured (ms) | Batched measured (ms) | Wall reduction | Estimate (ms) | Original error | Batched error |
|---|---:|---:|---:|---:|---:|---:|
| llama2-7b | 156.581 | 149.752 | 4.36% | 148.235 | -5.33% | -1.01% |
| llama3-8b | 113.706 | 111.962 | 1.53% | 110.334 | -2.97% | -1.45% |

## Device-cycle sums versus estimate

| Model | Original device (ms) | Batched device (ms) | Device reduction | Estimate (ms) | Original error | Batched error |
|---|---:|---:|---:|---:|---:|---:|
| llama2-7b | 152.884 | 147.376 | 3.60% | 148.235 | -3.04% | +0.58% |
| llama3-8b | 112.120 | 110.957 | 1.04% | 110.334 | -1.59% | -0.56% |

## Attention device time and launch counts

| Model | Operation | Launches before / after | Original (ms) | Batched (ms) | Reduction | Standalone estimate (ms) |
|---|---|---:|---:|---:|---:|---:|
| llama2-7b | qk | 32 / 1 | 6.937 | 4.012 | 42.17% | 5.897 |
| llama2-7b | pv | 32 / 1 | 6.290 | 3.362 | 46.56% | 5.312 |
| llama3-8b | qk | 8 / 1 | 1.781 | 1.129 | 36.63% | 1.520 |
| llama3-8b | pv | 8 / 1 | 1.587 | 0.934 | 41.13% | 1.333 |

The number of GEMM jobs is unchanged: Llama2 has 32 per attention phase; Llama3 has eight grouped jobs per phase. Total decoder launches fall from 148 to 86 and from 52 to 38, respectively. Linear GEMMs and vector operations remain separate launches.

## Same-binary control

| Model | Per-head device / wall (ms) | Batched device / wall (ms) | Device / wall reduction |
|---|---:|---:|---:|
| llama2-7b | 153.950 / 157.594 | 147.376 / 149.752 | 4.27% / 4.98% |
| llama3-8b | 112.415 / 113.708 | 110.957 / 111.962 | 1.30% / 1.54% |

The new per-head executable is not the preserved original binary: it also passes through the count-aware wrapper and has a different linked layout. The same-binary control isolates launch grouping more directly; the original-versus-batched table measures the actual implementation change. Full tensor allocation order can also differ after argument-array consolidation, so this is not a proof assigning every saved cycle to a particular startup instruction.

## Interpretation

- Batching improves actual decoder execution, not just the comparison metric. QK/PV device time decreases as well as total wall time; the effect is therefore not explained only by excluded CPU launch time.
- The old standalone estimate multiplies the startup cost of a single-head executable by the head count. After batching, its QK/PV estimate is higher than the measured batched attention time. Closer whole-layer agreement can include cancellation against underestimates in other operations; it is not proof that every estimate is exact.
- Reset/startup/exit repetition and host launch/wait are reduced, but per-job MMIO programming, accelerator execution and completion polling remain. Startup, cache reuse and address effects were not independently attributed.
- Both reversed-order blocks show the QK/PV reduction. Wall-time and Hadamard variation remain visible in the retained samples; no significance claim is made from these small sample counts.

## Reproduction and files

- Source: `tests/regression/llama_decoder_C4/{common.h,decoder.h,decoder.cpp,kernel.cpp,main.cpp,ops/device_gemm.cpp}`. The S32 summary helper recognizes grouped QK/PV profile rows.
- Configured build and commands: `build_decoder_gemm_batch/{run_tests.py,tests.log,build.log}`. Each result has an exact `command.json`; use `ci/run_black.sh hw --fpga-bin <alias> --app llama_decoder_C4` with the recorded arguments from a configured build.
- Raw profiles, wall samples, verification and buffer hashes: `build_decoder_gemm_batch/results/<model>/`.
- Machine-readable comparison: `build_decoder_gemm_batch/summary.json`; regenerated by `summarize_results.py`.
- Original source snapshot, binary hashes and pre-existing diff: `build_decoder_gemm_batch/{baseline_source,baseline_hashes.json,before.patch}`. The original binaries were verified unchanged after all runs.

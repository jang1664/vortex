# C4 decode: correct physical GEMM geometry (2026-10-10)

**Follow-up:** [Operation-level diagnosis and softmax launch fix](C4_DECODE_OP_LATENCY_DEBUG.md) identifies the previously unexplained softmax gap as a 32-block versus 4-block launch mismatch, fixes the decoder host, and reruns Llama3 on the same physical board as its latency estimate. The measurements below are the earlier baseline.

The main estimation error was a GEMM storage mismatch. The connected decoder already described its padded parent matrices correctly; the standalone benchmark measured more compact matrices. The benchmark and workload generator are corrected. No RTL, device kernel, or production decoder code was changed in this follow-up.

## Root cause and correction

| Item | Previous benchmark | Connected decoder / corrected benchmark |
|---|---|---|
| Linear GEMM, one token | `M=1`, target defaults to 1 | `M=8, target_M=1` |
| Llama3 QK | `M=4,N=1056,K=128` | Parent `M=8,N=1152,K=128`; target `M=4,N=1056,K=128` |
| Llama3 PV | `M=4,N=128,K=1056` | Parent `M=8,N=128,K=1152`; target `M=4,N=128,K=1056` |
| Llama2 QK/PV | Compact one-row matrices | Same parent policy, `target_M=1` |
| Llama3 softmax | 32 matrices × 1 row | 8 KV-head matrices × 4 grouped query rows |

The physical M is not just an allocation size. With MXU width 16, one FP16 microtile advances by `M * 16 * 2` bytes: 32 bytes for M=1 versus 256 bytes for M=8. RTL uses physical M for input microtile offsets. More significantly, `target_M < origin_M` selects `S_O_PRELOAD` to preserve inactive output rows before writeback. The old compact benchmark skipped this preservation load. Executed GEMM rows remain 1 or 4; the fix does not compute eight rows.

Evidence: `tests/regression/llama_decoder_C4/decoder.cpp` sets `arg.M=pad_rows(m), arg.target_M=m`; `fpint_gemm_ffn_hw/kernel.cpp` writes separate original and target registers. In `hw/rtl/core/gemm/VX_gemm_fsm.sv`, see `mt_storage_cur`, `lmem_in_mxu`, `output_preserve_cur`, and the transition to `S_O_PRELOAD`.

Changes:

- `fpint_gemm_ffn_hw/bench_main.cpp`: expose the existing correctness-harness `--target-m/n/k` interface, validate bounds/alignment, and pass targets to the existing device ABI. Default execution still covers the full parent matrix.
- `tools/workload/gen_kernel_cfgs.py`: fused GEMM parent M uses the eight-row pitch; decode QK/PV retain fixed capacity in N/K and rounded active extents in target N/K. Logical shape metadata remains logical. Padded-reference arguments update target dimensions without shrinking parent capacity.
- Fused decode softmax now matches the grouped-query matrix geometry. Its measured effect is small; it is not the main explanation for the original gap.
- A generator test covers both models, the 1056→1088 target boundary, canonicalization, distinct execution keys, and unchanged aligned prefill arguments.

## Controlled FPGA experiments

Rev7 C4, one board/allocation, warmup 1 and median of 3 cycle samples. Only the listed geometry changes between rows. The existing correctness harness passes tagged-address tests for linear, QK and PV parent/target cases.

| Experiment | Median cycles |
|---|---:|
| linear_compact | 483,018 |
| linear_parent | 556,310 |
| qk_compact | 16,918 |
| qk_parent_m | 18,886 |
| qk_parent_mn | 18,762 |
| pv_compact | 15,752 |
| pv_parent_m | 16,434 |
| pv_parent_mk | 16,588 |
| softmax_heads32 | 551,393 |
| softmax_heads8_rows4 | 556,691 |

Linear parent-M correction increases cycles by 15.17% in this controlled case. QK parent-M correction adds about 11.6%; extending its parent N from 1056 to 1152 has little extra effect. PV parent-M correction adds about 4.3%; parent K adds about 0.9%. These are measured workload-specific effects, not universal penalties.

## Refreshed estimate versus decoder

B1, past KV=1024, one generated token, active length=1025, capacity=1152. Rev7 C4 at 100 MHz. Both complete decoders were rerun and passed final-output verification before and after three uninstrumented timing passes. Separate profile passes supply device cycles. The following common denominator is the median of the three fresh decoder device-cycle sums; it is not host wall time.

Estimate = per-operation cycle latency × actual call count / 32 layers. Error = `(estimate / decoder - 1) * 100`. C4 has no separate dequant stage.

| Model | Decoder device (ms) | Old estimate (ms) | Old error vs fresh decoder | Corrected estimate (ms) | Corrected error |
|---|---:|---:|---:|---:|---:|
| llama2-7b | 153.072 | 137.393 | -10.24% | 146.807 | -4.09% |
| llama3-8b | 110.093 | 99.956 | -9.21% | 110.283 | +0.17% |

The earlier report used older single-pass decoder profiles and reported -8.41% / -7.18%. The table above recomputes both estimates against the same fresh repeated decoder measurements, rather than mixing denominators.

| Model | Decoder wall median (ms) | Corrected device estimate error vs wall |
|---|---:|---:|
| llama2-7b | 156.353 | -6.11% |
| llama3-8b | 111.550 | -1.14% |

Wall time includes host kernel-launch/wait overhead; uploads, downloads, verification and counter queries are outside the timed decoder.run() region. Do not equate device-cycle agreement with exact wall-time agreement.

## Why a residual remains

A diagnostic host replays five operations per model with the **same live device buffers and identical argument structs**, first through the combined decoder executable, then through the original standalone kernel binary. Every compared output buffer is bit-identical in all 10 comparisons. Median of 3 samples after one warmup:

The three standalone kernel binaries used for replay have matching SHA-256 hashes in the diagnostic build and both pipeline builds, excluding an implementation-version difference from this comparison.

| Model | Operation | Bundled cycles | Direct standalone cycles | Bundle increment |
|---|---|---:|---:|---:|
| llama2-7b | q_proj | 558,341 | 555,676 | +2,665 |
| llama2-7b | qk.0.0 | 21,671 | 18,559 | +3,112 |
| llama2-7b | pv.0.0 | 19,821 | 16,563 | +3,258 |
| llama2-7b | softmax | 615,070 | 609,986 | +5,084 |
| llama2-7b | ffn_hadamard | 3,453,335 | 3,385,928 | +67,407 |
| llama3-8b | q_proj | 558,722 | 555,618 | +3,104 |
| llama3-8b | qk.0.0 | 22,089 | 18,900 | +3,189 |
| llama3-8b | pv.0.0 | 19,829 | 16,686 | +3,143 |
| llama3-8b | softmax | 631,408 | 619,508 | +11,900 |
| llama3-8b | ffn_hadamard | 1,345,884 | 1,329,671 | +16,213 |

QK/PV add roughly 3,000 cycles per call in the combined executable even with identical inputs and geometry. Llama2 invokes each 32 times; Llama3 invokes each 8 times. This accounts for roughly 2 ms versus 0.5 ms of aggregate separation. It is an executable/dispatch cost, not a GEMM target-size error. The experiment does not independently isolate instruction-cache, startup and dispatcher contributions.

Hadamard and softmax also differ between standalone synthetic measurements and replay on real decoder buffers. For example, Llama2 Hadamard is 3,216,252 cycles in the refreshed standalone benchmark versus 3,385,928 in direct replay and 3,453,335 bundled. These two experiments establish separate buffer/workload-condition and executable effects; they do not identify a single data-dependent arithmetic cause. No empirical correction factor was added to the estimator.

One existing numerical-policy difference is retained: the latency suite uses symmetric V quantization while the decoder fixture uses all-asymmetric W/K/V. This is a versioned workload-policy choice, not changed implicitly by a geometry fix. Synthetic values and buffer addresses also differ. The remaining -4.09% (Llama2) is therefore reported, not declared solved or hidden; Llama3 total agreement also includes offsetting per-operation differences.

## Validation and artifacts

- Relevant Python suite: 62 PASS (the same four pre-existing failures documented in the preceding report remain excluded). Invalid target argument checks: 6 rejected as expected.
- FPGA tagged-address functionality: 3 PASS. Fresh complete C4 decoder outputs: both models PASS, 0/4096 violations; Llama2 max absolute error 0.000976562, Llama3 0.0012207.
- Same-input direct/bundled replay: 10/10 bit-identical output comparisons. Diagnostic changes exist only in the ignored build directory; production decoder sources were not changed.
- Workflow generated and measured the filtered C4 decode suite: 16 Llama2 + 19 Llama3 executions, all pass. Power was skipped; pipeline samples retain warmup=0, iterations=1.
- Full corrected suites were generated under the companion `_all` tag. `run_compose.py` combines old unaffected raw rows with new C4 decode rows. All 428 logical rows resolve to measured data; C1/C2/C3 and C4 prefill aggregate values are asserted unchanged.
- New raw: `analysis_workspace/latency_on_hw/outputs_{llama2,llama3}_main.th16_20261010_rev7_c4_decode_geometry/C4/raw_db.csv`.
- Composed result: `analysis_workspace/latency_on_hw/composed_results.th16_20261010_rev7_c4_decode_geometry/{llama2_7b,llama3_8b,combined}/composed.csv`.
- Corrected full suites: `analysis_workspace/latency_on_hw/generated_suites/{llama2_7b,llama3_8b}_main_full.th16_20261010_rev7_c4_decode_geometry_all/`.
- Evidence and reproduction: `build_rev7_c4_decode/{pipeline_command.json,diagnose.py,diagnosis.json,run_decoders.py,decoder_results.json,run_replay.py,replay_results.json,compose.py,summarize_fix.py}`.
- Raw source hashes and merge provenance: `build_rev7_c4_decode/compose_inputs/inventory.json`. Original published raw databases were not overwritten.
- Build note: an initial runtime build used its default simulation target and failed in Verilator elaboration; rebuilding `runtime/xrt TARGET=hw` resolved the setup error. All reported tests ran on real FPGA hardware.

Previous result: [REV7_B1_S1024_LAYOUT_REFRESH.md](REV7_B1_S1024_LAYOUT_REFRESH.md).

## Softmax attention-scale experiment (2026-10-10)

The standalone benchmark defaults to scale=1, while the decoder uses 1/sqrt(head_dim). For head_dim=128 in both models, the matching scale is 0.08838834764831843. This is an argument mismatch, not a memory-address effect.

Remeasured the exact latency_on_hw softmax_layout_fused binary (rev2_shuffle_cursor; SHA-256 a0026b4b885af5bdf0d406951fcc209b51e3d542465719352c21abe09fa12261) through ci/run_black.sh hw --bench --run-only. Its hash matches both previous pipeline manifests. All eight invocations used rev7 C4, 100 MHz, board 0000:2a:00.1, Slurm job 5822. Each invocation had one warmup and five measured iterations. Two rounds reversed the scale order (1 then attention; attention then 1), giving ten samples per model and scale. Input copying was explicitly enabled and the deterministic synthetic input was unchanged. No power or output-correctness checks were run in this latency benchmark.

Geometry: B=1, active KV=1025 after appending one token to past KV=1024, physical stride=1152, mask=0. Llama2 uses heads=32, query rows=1; Llama3 uses heads=8, query rows=4. Only -scale changes within each pair.

| Model | Scale=1 median cycles | Scale=1/sqrt(128) median cycles | Change | Scale=1 range | Attention-scale range |
|---|---:|---:|---:|---:|---:|
| llama2-7b | 551,197.0 | 550,803.5 | -0.071% | 547,895–553,195 | 547,921–552,650 |
| llama3-8b | 557,123.5 | 557,133.5 | +0.002% | 555,376–558,577 | 555,557–557,575 |

The change is within the observed run variation. Matching scale does not explain the previously observed gap between synthetic-input standalone measurements and decoder-input replay. The replay columns below are the previous measurements, not fresh decoder runs.

| Model | Synthetic input, matching scale (ms) | Decoder input, standalone replay (ms) | Decoder input, bundled replay (ms) |
|---|---:|---:|---:|
| llama2-7b | 5.508035 | 6.099860 | 6.150700 |
| llama3-8b | 5.571335 | 6.195080 | 6.314080 |

As a sensitivity calculation, replace only the historical softmax cycle term with the new attention-scale median (one softmax invocation per decoder layer). This mixes the prior single-sample estimate with the new repeated softmax measurement; it is not a fresh whole-pipeline measurement. Published raw databases and composed results were not overwritten.

| Model | Revised estimate (ms/layer) | Previous device-estimate error | Revised device-estimate error |
|---|---:|---:|---:|
| llama2-7b | 146.813665 | -4.093% | -4.089% |
| llama3-8b | 110.287085 | +0.173% | +0.176% |

Reproduction: `srun --gres=fpga:u55c:1 --cpus-per-task=4 --mem=16G --time=00:15:00 python3 build_rev7_c4_decode/softmax_scale_compare.py`. Exact per-case commands, board identities, all cycle samples and logs are in `build_rev7_c4_decode/softmax_scale_compare/{results.json,metadata.json,summary.json,*.log,*.csv}`. The experiment does not change kernel sources or generator defaults.

# C4 decode: operation latency diagnosis and softmax launch fix

Follow-up: [decoder semantics alignment and remeasurement](REV7_DECODER_SEMANTICS_ALIGNMENT.md) fixes the V quantization, softmax scale, RMSNorm epsilon, RoPE theta, and R4 coefficient mismatches recorded below. The historical tables here remain unchanged; use the follow-up for the current comparison. These computation mismatches were defects to correct, not acceptable approximation boundaries.

## Findings

1. **Fixed a real softmax launch mismatch.** The standalone rev2_shuffle_cursor host caps the launch to cores × warps (4 blocks here); the decoder launched one block per row (32). The same kernel supports persistent row iteration. Matching the standalone launch removes about 0.57–0.63 ms per decoder layer while preserving the complete softmax output bit-for-bit.
2. **Corrected a cross-board comparison.** Historical Llama3 latency_on_hw data used 0000:3d:00.1, but the previous decoder measurement used 0000:2a:00.1. The same binary/workload is 2.4–3.9% slower on 3d in the measured GEMM cases. Rerunning the fixed Llama3 decoder on 3d removes the apparent GEMM implementation discrepancy. No cause for the board-level difference is asserted.
3. **Confirmed executable overhead.** With identical arguments and live buffers, QK/PV take about 3,100–3,200 more cycles per launch in the combined decoder executable. Quantization adds roughly 1,100–1,400 cycles per launch. These costs explain much of the remaining sum-versus-decoder gap. This isolates executable composition as a group; startup, dispatch and instruction-cache contributions were not independently separated.
4. **Llama2 FFN Hadamard remains the largest unresolved residual.** Its launch/shape arguments match, and replacing activation data, transform coefficients, or one buffer address does not identify a single cause. Standalone repeated timing varies substantially. Do not label the entire residual as a proven memory-address or arithmetic error.

Only tests/regression/llama_decoder_C4/decoder.cpp was changed in production: the softmax block count now follows the existing standalone cursor launch policy. No RTL or device-kernel implementation changed. The other repository modifications predate this diagnosis.

## Measurement basis

C4 rev7 alias: improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm, 100 MHz. B1, decode one step, past KV=1024, active KV=1025, capacity=1152. Each model uses the same physical board as its existing latency_on_hw data.
The estimate is the existing th16_20261010_rev7_c4_decode_geometry composed result divided by 32 layers. Raw databases and composed results are unchanged. Its softmax scale remains 1; the preceding controlled experiment found less than 0.1% latency impact from matching 1/sqrt(128).
Decoder wall time is the median of three uninstrumented passes. Device time is the median of three separate profile sums. Per-op tables use the single profile pass with the median total, so rows sum exactly to the reported device total. Quantization, QK and PV rows include every head invocation; they are not one-head samples. Error = (estimate / measured - 1) × 100.

| Model | Matched FPGA BDF | Decoder device (ms) | Estimate (ms) | Device error | Decoder wall (ms) | Error vs wall |
|---|---|---:|---:|---:|---:|---:|
| llama2-7b | 2a:00.1 | 152.348 | 146.807 | -3.64% | 155.792 | -5.77% |
| llama3-8b | 3d:00.1 | 111.356 | 110.283 | -0.96% | 112.774 | -2.21% |

Wall includes host launch/wait overhead. Device cycles exclude that host contribution. No dequant correction is needed for C4. These two timing definitions are intentionally reported separately.

## Every operation: fixed decoder versus existing estimate

### llama2-7b

| Operation | Calls/layer | Decoder total (ms) | Estimate total (ms) | Decoder − estimate (ms) | Estimate error |
|---|---:|---:|---:|---:|---:|
| attention_norm | 1 | 0.8030 | 0.7486 | +0.0544 | -6.77% |
| q_proj | 1 | 5.5854 | 5.5610 | +0.0244 | -0.44% |
| k_proj | 1 | 5.5877 | 5.5610 | +0.0267 | -0.48% |
| v_proj | 1 | 5.5817 | 5.5610 | +0.0207 | -0.37% |
| q_rope | 1 | 0.5957 | 0.6312 | -0.0355 | +5.96% |
| k_rope | 1 | 0.5966 | 0.6312 | -0.0346 | +5.81% |
| q_hadamard | 1 | 1.0372 | 1.0419 | -0.0048 | +0.46% |
| k_hadamard | 1 | 1.0434 | 1.0419 | +0.0015 | -0.14% |
| value | 32 | 11.1219 | 10.6032 | +0.5187 | -4.66% |
| key | 32 | 10.7990 | 10.4413 | +0.3577 | -3.31% |
| qk | 32 | 6.9345 | 5.8973 | +1.0372 | -14.96% |
| softmax | 1 | 5.5735 | 5.5011 | +0.0724 | -1.30% |
| pv | 32 | 6.3179 | 5.3123 | +1.0056 | -15.92% |
| concat | 1 | 0.7683 | 0.7937 | -0.0255 | +3.31% |
| o_proj | 1 | 5.5906 | 5.5610 | +0.0295 | -0.53% |
| attention_residual | 1 | 1.5130 | 1.4858 | +0.0271 | -1.79% |
| ffn_norm | 1 | 0.8027 | 0.7486 | +0.0541 | -6.74% |
| gate_proj | 1 | 14.6279 | 14.5995 | +0.0284 | -0.19% |
| up_proj | 1 | 14.6292 | 14.5995 | +0.0297 | -0.20% |
| silu | 1 | 1.2899 | 1.3485 | -0.0586 | +4.55% |
| mlp_product | 1 | 1.1647 | 1.1774 | -0.0127 | +1.09% |
| ffn_hadamard | 1 | 34.5647 | 32.1625 | +2.4022 | -6.95% |
| down_proj | 1 | 14.3372 | 14.3109 | +0.0264 | -0.18% |
| output | 1 | 1.4824 | 1.4858 | -0.0034 | +0.23% |

### llama3-8b

| Operation | Calls/layer | Decoder total (ms) | Estimate total (ms) | Decoder − estimate (ms) | Estimate error |
|---|---:|---:|---:|---:|---:|
| attention_norm | 1 | 0.8040 | 0.7734 | +0.0306 | -3.80% |
| q_proj | 1 | 5.8074 | 5.7791 | +0.0283 | -0.49% |
| k_proj | 1 | 1.5181 | 1.4871 | +0.0310 | -2.04% |
| v_proj | 1 | 1.5154 | 1.4871 | +0.0283 | -1.87% |
| q_rope | 1 | 0.5966 | 0.6271 | -0.0306 | +5.12% |
| k_rope | 1 | 0.4347 | 0.4364 | -0.0017 | +0.39% |
| q_hadamard | 1 | 1.0454 | 1.0374 | +0.0080 | -0.76% |
| k_hadamard | 1 | 0.5493 | 0.5463 | +0.0030 | -0.55% |
| value | 8 | 2.7808 | 2.6430 | +0.1378 | -4.96% |
| key | 8 | 2.6848 | 2.5994 | +0.0854 | -3.18% |
| qk | 8 | 1.7848 | 1.5201 | +0.2647 | -14.83% |
| softmax | 1 | 5.6015 | 5.5676 | +0.0339 | -0.60% |
| pv | 8 | 1.5836 | 1.3329 | +0.2508 | -15.83% |
| concat | 1 | 0.7698 | 0.7758 | -0.0061 | +0.79% |
| o_proj | 1 | 5.8072 | 5.7791 | +0.0281 | -0.48% |
| attention_residual | 1 | 1.4828 | 1.4539 | +0.0289 | -1.95% |
| ffn_norm | 1 | 0.8054 | 0.7734 | +0.0320 | -3.97% |
| gate_proj | 1 | 19.4921 | 19.4885 | +0.0036 | -0.02% |
| up_proj | 1 | 19.5082 | 19.4885 | +0.0197 | -0.10% |
| silu | 1 | 1.6339 | 1.6250 | +0.0089 | -0.54% |
| mlp_product | 1 | 1.4288 | 1.4126 | +0.0162 | -1.13% |
| ffn_hadamard | 1 | 13.2469 | 13.2249 | +0.0220 | -0.17% |
| down_proj | 1 | 18.9790 | 18.9708 | +0.0082 | -0.04% |
| output | 1 | 1.4954 | 1.4539 | +0.0415 | -2.78% |

## Softmax: isolate the launch mismatch

The benchmark Makefile defines SOFTMAX_SAFE_HOST for rev2_shuffle_cursor. bench_main.cpp and main.cpp cap grid_dim[0] to cores × NUM_WARPS. The decoder reused the device kernel but missed this host policy. This test exclusively uses rev2_shuffle_cursor; rev2_shuffle_safe was not executed.
The diagnostic host varied grid_dim[0] from 32 to 4 while holding the binary, input values, input/output addresses, scalar arguments and all other fields fixed. Warmup 1, median of 5 cycles, board 2a. Entire output buffers are bit-identical before and after.

| Model | Bundled, 32 blocks (ms) | Bundled, 4 blocks (ms) | Improvement | Direct, 32 blocks (ms) | Direct, 4 blocks (ms) |
|---|---:|---:|---:|---:|---:|
| llama2-7b | 6.14160 | 5.57218 | -9.27% | 6.10419 | 5.55713 |
| llama3-8b | 6.24392 | 5.60940 | -10.16% | 6.21430 | 5.59081 |

The reverse experiment agrees: copying real decoder scores into the standalone benchmark keeps latency near 5.55–5.60 ms, while also copying decoder arguments (with the original 32-block grid and newly allocated input/output addresses) raises it to about 6.13–6.29 ms. Changing scale alone, power-loop count 0→1, or argument-buffer alignment does not explain the gap.

## Same-buffer executable costs

These paired replay measurements use board 2a, warmup 1 and five iterations per condition. They are diagnostics, not replacement rows in the published estimate. Complete outputs remain bit-identical between standalone and combined executables.

| Model | Operation | Bundled cycles | Standalone cycles | Extra cycles/call | Calls/layer | Extra ms/layer if repeated |
|---|---|---:|---:|---:|---:|---:|
| llama2-7b | qk.0.0 | 21,683 | 18,595 | +3,088 | 32 | 0.9882 |
| llama2-7b | pv.0.0 | 19,744 | 16,514 | +3,230 | 32 | 1.0336 |
| llama2-7b | key.0.0 | 33,760 | 32,649 | +1,111 | 32 | 0.3555 |
| llama2-7b | value.0.0 | 34,975 | 33,700 | +1,275 | 32 | 0.4080 |
| llama2-7b | attention_norm | 80,501 | 76,197 | +4,304 | 2 | 0.0861 |
| llama3-8b | qk.0.0 | 22,140 | 19,023 | +3,117 | 8 | 0.2494 |
| llama3-8b | pv.0.0 | 19,774 | 16,599 | +3,175 | 8 | 0.2540 |
| llama3-8b | key.0.0 | 33,174 | 32,051 | +1,123 | 8 | 0.0898 |
| llama3-8b | value.0.0 | 34,923 | 33,529 | +1,394 | 8 | 0.1115 |
| llama3-8b | attention_norm | 80,577 | 77,416 | +3,161 | 2 | 0.0632 |

The extrapolated column applies the representative-call difference to the actual call count; it is not a measurement of every head pair. V quantization also retains the existing symmetric (suite) versus asymmetric (decoder fixture) policy difference. The same-input replay above removes that policy difference from its executable comparison.

## Board effect: matched standalone GEMM

Both physical boards were allocated together and selected explicitly by BDF. The runtime log confirms the actual opened BDF, not just an index hint. Warmup 1, median of 5 cycles; identical binaries, data and parent/target geometry.

| Workload | 2a:00.1 (ms) | 3d:00.1 (ms) | 3d slowdown |
|---|---:|---:|---:|
| q_proj | 5.56012 | 5.77662 | +3.89% |
| gate_llama3 | 18.96458 | 19.48765 | +2.76% |
| down_llama3 | 18.53367 | 18.97182 | +2.36% |

For example, the historical Llama3 gate estimate is 19.48848 ms, matching the repeated standalone 3d measurement. Comparing it to a roughly 19.00 ms decoder gate on 2a had created an artificial cancellation against underestimated vector/executable costs.

## Hadamard residual and limits

For Llama2, the fixed decoder FFN Hadamard is about 34.56 ms versus the historical single-sample estimate of 32.16 ms. Exact argument comparison finds no used launch/shape mismatch: both use one row, one matrix, 64 threads, base_k=172, width=64 and the same tiled input/output layout. Differences are buffer addresses, ignored third-dimension fields (vx_spawn_threads uses dimension=2), and equivalent power-loop counts 0 versus 1.
In the live decoder, independently substituting synthetic activations, synthetic coefficients, both together, or relocating individual buffers preserves the original output after restoration but does not reliably reproduce the low standalone time. Argument alignment and power-loop count were also tested. A unique memory/cache/stall cause is therefore not established.

| Board | Standalone Hadamard samples | Median (ms) | Min (ms) | Max (ms) |
|---|---:|---:|---:|---:|
| 0000:2a:00.1 | 15 | 32.74879 | 31.95923 | 34.56805 |
| 0000:3d:00.1 | 15 | 33.91407 | 32.49901 | 35.01438 |

A separate five-sample standalone run retired exactly 12,773,351 instructions each time while cycles ranged from 3,191,822 to 3,439,390. This demonstrates execution-time variation without an instruction-count change; it does not identify the responsible stall source. The historical one-sample estimate is close to the low end of the repeated range. No empirical correction factor or speculative kernel change was applied.

## Validation and artifacts

- Decode B1/KV1024: both models pass full final-output verification after the host launch fix, with zero violations and zero nonfinite elements. The matched-board Llama3 rerun also passes.
- Prefill B1/S32: both models pass the existing decoder acceptance policy. Probabilities and final output are bit-identical to the previous saved results. Existing CPU-reference violations are unchanged (Llama2: 1464/131072; Llama3: 1/131072); no tolerance was relaxed in this work.
- Softmax 32→4 blocks: full output buffers bit-identical in both models. All ten representative operations per model compared between combined and standalone binaries pass full-buffer equality.
- The combined kernel SHA-256 is identical in the diagnostic and production builds: 63fd97a357bc18d13ed0b00727709a1f6d9120d62767fd373366208d8a3b0a49. Only host launch arguments changed.
- Complete per-launch latency table, including every KV head and all three profile passes: build_rev7_c4_decode/op_debug_per_launch.csv. Matched summary: op_debug_matched_summary.json.
- Production reruns: decoder_grid_fixed_llama2-7b/, decoder_grid_fixed_board1_llama3-8b/, prefill_grid_fixed_{llama2-7b,llama3-8b}/. Commands: run_decoder_grid_fixed.py and run_decoder_grid_fixed_board1.py.
- Controlled replays: op_probe/, op_probe_args/, op_probe_grid/; scripts decoder_probe*.cpp, run_probe*.py. Argument snapshots: softmax_input_probe/ and hadamard_args_probe/. Board evidence: board_compare_bdf/{results.json,*.log}. All paths in this list are relative to build_rev7_c4_decode/.
- Diagnostic-only failed attempts are excluded: vx_mem_reserve did not support the attempted argument-buffer reservation, so supported aligned allocations were used; a first index-only board experiment opened 2a twice and was replaced by explicit-BDF selection verified in runtime logs.
- Temporary benchmark executables were restored after instrumentation. No published raw_db.csv or composed estimate was overwritten, and no commit was made.

Previous geometry/scale investigation: [C4_DECODE_GEOMETRY_FIX.md](C4_DECODE_GEOMETRY_FIX.md).

## Final reference-direction audit

The connected decoder is the **measured performance reference** for the specified implementation, model, shape, numerical policy and FPGA image/board. The independent CPU/PyTorch logical reference validates its numerical output. The latency_on_hw aggregate is the estimator being assessed; it does not define correctness or replace decoder execution.

| Check | Audit result |
|---|---|
| Real connected execution | Decoder buffers carry actual producer outputs to consumers. Every KV head and every QK/PV group executes on the FPGA; no representative-head multiplication occurs inside the decoder. |
| Independent estimator | Existing standalone measurements are multiplied by logical call counts and divided by the model's 32 layers for this comparison. No fitted correction factor, decoder timing input, or forced equality was introduced. |
| Reference-side changes | The softmax host launch change is an implementation optimization using the existing cursor kernel's persistent-row scheduling. It is valid because decode output and saved prefill S32 probabilities/final output are bit-identical, and measured runs were repeated after the change. Old reference timings were not silently relabeled as new results. |
| Geometry correction direction | The estimator's physical parent sizes, execution targets, cache capacity and grouped softmax geometry were corrected to describe the real decoder. Decoder GEMM work was not padded or skipped merely to reproduce the old estimate. |
| End-to-end timing scope | The performance reference is the timer around decoder.run(false, {}). Fixture loading, initial allocation/uploads, tensor dumps, numerical checks and performance-counter queries are outside that timer. Host scheduling/launch/wait and device execution remain inside it. |
| Device profile scope | Separate profile passes sum device cycles to diagnose kernel costs. This narrower metric must not be labeled complete decoder wall time. |
| Error direction | Both error columns use (estimate - decoder measurement) / decoder measurement. Negative error means the estimator underpredicts actual execution. |
| Numerical gate | The final C4 decode runs have zero nonfinite elements and zero output-tolerance violations. Prefill S32 uses the unchanged existing acceptance policy, including its previously recorded finite-value deviations; it is not an exact-arithmetic proof. |

For the latest matched C4 decode results, **wall-time** estimate errors are -5.77% (Llama2) and -2.21% (Llama3). The -3.64% / -0.96% figures describe device-cycle sums only. Neither set includes model embedding, the LM head, all 32 decoder layers, or 128-token autoregressive generation: the measured workload is one decoder layer and one decode step with B1/past KV1024.

Remaining approximation boundaries must stay visible:

- The suite uses symmetric V quantization while this decoder fixture uses asymmetric V quantization. Matching scale alone was tested to have negligible latency impact, but the suite's scale=1 and decoder's 1/sqrt(128) are still distinct workload arguments. The aggregate is therefore not an exact identical-input/numerical-policy replay.
- Standalone synthetic inputs, executable composition, runtime overhead and timing variation remain estimator limitations. The Hadamard residual is not resolved by an empirical adjustment.
- The older C1/C2/C3 tables retain candidate-to-candidate measurement reuse (especially C2) and cache-capacity differences (decoder 1056 versus suite 1152). They support approximate validation, not a claim that every candidate was measured under fully identical physical conditions.
- Prefill B1/S1024 was not remeasured after the C4 softmax launch fix. The saved historical prefill latency table belongs to the earlier implementation; only S32 functionality/output equivalence was checked for the new launch in this follow-up.

Audit verification: independently recomputed all operation sums and both error formulas from the recorded CSV/JSON evidence; checked the matched C4 decode output gates. No FPGA run, tolerance change, estimate rewrite or further implementation change was made for this final audit.

# TVM Vortex Llama3-8B Synthetic Inference Plan

## 1. Goal

Complete a runnable Llama3-8B-shaped inference path on Vortex before integrating a real model
checkpoint. The first target uses deterministic synthetic parameters but preserves the complete
Llama3-8B geometry and public inference flow:

```text
token IDs
  -> token embedding
  -> 32 decoder layers
  -> final RMSNorm
  -> W4 LM head
  -> logits
  -> token selection
  -> repeated decode with the prefill KV cache
```

The deliverable is a host runner that performs prefill and at least three consecutive decode steps
on the pinned U55C with both C4/alone and C4/fused. The generated token sequence is not expected to
be meaningful until a real checkpoint is integrated.

## 2. Starting point

The following work is already complete and must be reused:

- backend-neutral PyTorch boundaries for token embedding, decoder layers, final RMSNorm, and the W4
  LM head;
- strict meta export of real-geometry 32-layer Llama3-8B prefill and decode graphs;
- two-layer token-to-logits hardware smoke tests in bytecode and compiled VM modes;
- real-geometry 32-layer decoder-core prefill followed by three decode steps;
- one compiled layer reused across 32 global parameter slices;
- one resident KV4 cache per layer, updated in place during decode;
- device-to-device state copies at reusable VM boundaries;
- signed asymmetric W4, K4, and V4 contracts;
- stage-aware FP16 and semantic KV-cache comparison utilities;
- profile-bound prepacked parameter archives with integrity validation.

The 32-layer decoder-core path passes alone and fused. The missing functional boundary is the
real-geometry 32-layer integration of embedding and final norm/LM head around that accepted path.

## 3. Frozen scope

### Included

- Llama3-8B geometry: 32 layers, hidden size 4096, intermediate size 14336, 32 query heads, 8 KV
  heads, head dimension 128, and vocabulary size 128256;
- deterministic synthetic parameters using the production parameter names and shapes;
- C4 `GEMM_IMPROVE` ABI/layout version 2;
- C4/alone and C4/fused policies;
- prefill followed by at least three stateful decode steps;
- device-resident static parameters and per-layer KV cache;
- token-to-logits execution and a minimal host-side token selection loop;
- eager PyTorch versus Vortex numerical and state validation;
- final serialization/reload work after live execution passes.

### Deferred

- Meta/Hugging Face/SpinQuant checkpoint loading and conversion;
- language-quality, perplexity, or benchmark claims;
- production sampling policies and user interface;
- C1, C2, C3, FP TCU, or naive GEMM fallbacks;
- monolithic 32-layer Relax compilation as an acceptance requirement;
- elimination of layer-boundary D2D copies;
- broader RMSNorm, RoPE, Hadamard, and cache-layout fusion;
- RTL, hardware FSM, or xclbin changes.

Checkpoint conversion is deliberately last. Until then, token IDs and logits exercise the correct
interfaces and shapes, but sampled text has no semantic meaning.

## 4. Fixed hardware and quantization contract

- XCLBIN:
  `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin`
- Profile fingerprint:
  `62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256`
- Static decoder and LM-head weights: signed asymmetric INT4, group size 32, FP16 scales, INT16
  zero points;
- K and V cache: signed asymmetric INT4, group size 128, FP16 scales, INT16 zero points;
- Activations, residuals, and logits: FP16 unless an existing operation requires wider internal
  accumulation;
- GQA: 32 query heads, 8 KV heads, and 4 query heads per KV head.

No new hardware behavior is required. A hardware change is considered only if a reduced software
reproducer proves that an already-supported operation is incorrect on the pinned image.

## 5. Execution architecture

Do not compile one monolithic 32-layer Relax graph. The earlier attempt did not finish its first
executable after 76 minutes. Use a partitioned model with explicit device-resident handoff:

```text
Host inference driver
  |
  +-- embedding entry: token_ids -> hidden
  |
  +-- decoder prefill/decode entry
  |     compile one physical layer per phase
  |     invoke it 32 times with layers.0 ... layers.31 parameters
  |     select that layer's KV cache on decode
  |
  +-- final entry: hidden -> final RMSNorm -> W4 LM head -> logits
  |
  +-- host token selector -> next token ID
```

The embedding, decoder, and final entry may be separate VM executables. Hidden states must move
between them with Vortex device-to-device copies. Static parameters are uploaded once and reused.
The prefill-created KV cache remains resident and is passed to every decode step without a host
round trip.

The host owns only small control values and outputs:

- input token IDs and positions;
- scalar cache length;
- selected next-token IDs;
- optional logits or compact diagnostics copied back for validation.

## 6. Parameter strategy

Extend the existing deterministic parameter generator and C4 archive rather than introducing a
second model ABI.

The archive must contain:

- token embedding weight;
- every `layers.N.*` decoder tensor for all 32 layers;
- final RMSNorm weight;
- prepacked asymmetric W4 LM-head payload, scale, and zero point;
- model geometry, quantization policy, layer count, ABI version, target fingerprint, tensor hashes,
  and whole-archive hash.

The runtime must validate the archive before device upload and expose global-to-local layer mapping
without duplicating the 32-layer tensors in compiler IR. Peak host and device memory use must be
recorded before expanding beyond S1.

## 7. Minimal inference runner

Add a reproducible command-line runner or an equivalent directly runnable test utility. It should
support at least:

```text
--layout-policy alone|fused
--prompt-token-ids 1,2,3,...
--decode-steps N
--cache-capacity C
--sampling argmax
--seed SEED
--trace-output PATH
```

The initial runner uses explicit token IDs. Optional tokenizer integration may use the standard
Llama3 tokenizer, but it must stay outside the compiled module. `argmax` is the required initial
selector because it is deterministic; temperature and top-p are later host-only extensions.

For every run, save a compact JSON record containing:

- input and generated token IDs;
- per-step cache length;
- selected-logit/top-k values or hashes;
- archive and target fingerprints;
- policy, shapes, compiler revisions, kernel-launch count, transfers, and latency;
- pass/fail comparison summaries when a reference is enabled.

## 8. Numerical validation

Run the identical synthetic parameters and token IDs through eager PyTorch, C4/alone, and
C4/fused.

### FP16 tensors and logits

- reject every NaN or infinity;
- for small reference magnitudes, judge absolute error;
- for larger reference magnitudes, judge relative error;
- also gate relative-L2, cosine similarity, and the fraction of pointwise violations;
- retain the existing tested helper and stage-specific thresholds instead of replacing it with one
  global `allclose` tolerance;
- compare final-token logits after prefill and after every decode step;
- record top-1 and top-k agreement as diagnostics, but do not let accidental argmax agreement hide
  a failed numerical comparison.

### KV cache

After prefill and every decode step, verify for all 32 layers:

- exact cache length;
- exact untouched suffix;
- preserved prefix;
- payload codes differ by no more than one where the existing cross-backend rule permits it;
- scale and zero-point checks use the existing stage-aware limits;
- dequantized values use `(signed_code - zero_point) * scale`;
- batches remain isolated.

When a full-stack case fails, rerun with first-failure capture and report the earliest layer and
stage rather than comparing only final logits.

## 9. Primary acceptance cases

Use the established four small cases:

| Case | Batch | Prompt length | Decode steps | Cache capacity |
| --- | ---: | ---: | ---: | ---: |
| S1 | 1 | 1 | 3 | 8 |
| S2 | 1 | 7 | 3 | 16 |
| S3 | 2 | 1 | 3 | 8 |
| S4 | 2 | 7 | 3 | 16 |

Each case executes:

```text
state, logits_0 = prefill(prompt_token_ids)
token_1 = argmax(logits_0[:, -1, :])
state, logits_1 = decode(token_1, state)
token_2 = argmax(logits_1[:, -1, :])
state, logits_2 = decode(token_2, state)
token_3 = argmax(logits_2[:, -1, :])
state, logits_3 = decode(token_3, state)
```

Run all cases under both alone and fused. S1/alone is the permanent first gate and debugging oracle.

## 10. Milestones

### Milestone A — partitioned full-model components

1. Export/import real-geometry embedding and final norm/LM-head entries independently.
2. Bind their external parameters through the same archive contract as the decoder.
3. Confirm generated modules use C4 W4A16 for the LM head and contain no naive/TCU fallback.
4. Add focused host tests for shapes, parameter mapping, and logical ABI equality.

Deliverable: embedding and final-logit components compile independently for C4/alone and fused.

### Milestone B — S1/alone live inference

1. Create one real-geometry 32-layer synthetic archive including model-boundary tensors.
2. Upload parameters once.
3. Run embedding, the accepted 32-layer prefill chain, and the final head.
4. Select one token with host argmax.
5. Run three decode steps using all 32 resident layer caches.
6. Compare logits, selected hidden checkpoints, and every cache against eager PyTorch.

Deliverable: S1/alone produces a deterministic token-ID sequence and passes full state validation.

### Milestone C — fused and four-case acceptance

1. Pass S1/fused with the same archive and inputs.
2. Run S2, S3, and S4 under alone and fused.
3. Compare alone versus fused results in addition to the eager reference.
4. Capture latency, launch counts, transfers, archive size, host RSS, and device allocation.

Deliverable: all eight S1-S4 × policy token-to-logits chains pass.

### Milestone D — reusable inference driver

1. Extract the test orchestration into a directly runnable host API/CLI.
2. Accept explicit token IDs and optionally tokenize text outside the compiled module.
3. Keep argmax deterministic and expose logits/top-k diagnostics.
4. Handle cache capacity, batch shape, end-of-sequence, reset, and failures clearly.
5. Add a small visualization-friendly JSON/NumPy trace output.

Deliverable: a user can run prefill plus repeated decode without editing a pytest body.

### Milestone E — serialization and reload

Perform this only after live S1-S4 execution is stable.

1. Save the embedding, prefill-layer, decode-layer, and final-head VM artifacts.
2. Save the external parameter archive and metadata without embedding multi-gigabyte constants in
   compiler IR.
3. Start a fresh process, validate ABI/profile/hashes, upload once, and run inference without
   PyTorch export or TVM compilation.
4. Require bytecode reload for the full matrix and compiled reload for representative S1 cases.
5. Confirm serialization does not change parameter identity, layout metadata, logits, or cache
   behavior.

Deliverable: compile/package and inference/load are separate reproducible workflows.

### Milestone F — real checkpoint integration

This is explicitly the final milestone and is not part of the synthetic inference acceptance gate.

1. Map a real Llama3-8B checkpoint to the frozen parameter names and shapes.
2. Apply the required SpinQuant rotations and signed asymmetric W4 conversion.
3. Package the real archive with provenance and quantization metadata.
4. Re-run S1 first, then the full matrix as appropriate.
5. Only after numerical correctness passes, evaluate generated text or model-quality metrics.

## 11. Acceptance criteria

Synthetic inference is complete when:

1. token IDs enter the real-geometry 32-layer model and final logits are returned;
2. prefill creates 32 valid layer caches and three decode steps reuse them without rebuild or host
   cache round trips;
3. embedding, all decoder projections, and the LM head use their intended C4 path;
4. S1-S4 pass under both alone and fused against eager PyTorch;
5. hybrid FP16/logit and semantic KV-cache checks pass after every phase;
6. the runner emits deterministic token IDs and reproducible diagnostics;
7. no RTL or xclbin modification was required;
8. the final report distinguishes synthetic functional correctness from real-checkpoint model
   quality.

Serialization/reload is a separate completion gate after live inference. Real checkpoint support is
the following milestone, not a prerequisite for declaring the synthetic inference path functional.

## 12. Recommended implementation order

1. Milestone A: partition embedding and final head.
2. Milestone B: complete S1/alone end to end.
3. Diagnose any failure with per-layer captures before enabling fused.
4. Milestone C: pass fused and expand through S4.
5. Milestone D: expose the stable path as a runner.
6. Milestone E: package and reload it.
7. Milestone F: integrate the real checkpoint last.

## 13. Execution status (2026-08-29)

The software deliverables for partitioned components, the deterministic 5.7 GB external archive,
the directly runnable package/reload driver, eager reference generation, and hybrid FP16/KV4
validation are implemented. One physical decoder layer is compiled and reused for all 32 logical
layers, as required by the execution architecture.

S1/alone produced one complete, numerically passing 32-layer prefill trace, including final logits,
but repeated identical runs fail at a variable decoder layer with an entirely non-finite hidden
tensor. A reduced exact-layer loop reproduces the transition failure; only an impractical AP reset
plus 50 ms settle before every low-level launch completed 20 consecutive repetitions. Shorter or
periodic resets and launch-handshake variations were not repeatable.

Therefore Milestone B is **blocked**, not passed. Milestone C and hardware acceptance of Milestone E
remain gated behind it; S1 decode, fused, and S2-S4 are not claimed. The reduced-reproducer condition
in Section 4 is satisfied, so the next task may investigate AFU/core launch completion and AXI write
drain, regenerate the xclbin, and resume from S1/alone. No RTL, production runtime reset workaround,
or xclbin change is included in this execution.

Detailed evidence and the resume order are recorded in
`vortex_tvm_llama3_8b_synthetic_inference_execution_report.md`.

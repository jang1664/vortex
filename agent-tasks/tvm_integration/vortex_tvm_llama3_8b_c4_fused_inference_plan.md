# Vortex TVM Llama3-8B C4/Fused Inference Plan

## 1. Goal

Make C4 `fused` the next accepted Llama3-8B inference configuration, using the already accepted
C4 `alone` implementation as the correctness baseline.

The final target is a deterministic synthetic Llama3-8B run that:

1. compiles with `--layout-policy fused`;
2. executes prefill followed by three consecutive decode steps on the pinned U55C;
3. preserves the asymmetric W4/K4/V4 contracts and the resident KV-cache lifecycle;
4. uses exactly one physical Vortex kernel for each logical Hadamard invocation;
5. passes all four small `(batch, prompt length)` cases S1-S4;
6. records whether fused layout propagation actually removes transforms or launches relative to
   `alone`, without claiming a performance win unless measured.

The work is split into a correctness milestone and an evidence-driven optimization milestone.
`fused` correctness does not require Hadamard and GEMM to become one kernel. It requires the same
logical model to execute correctly while the existing fused layout policy reuses compatible tiled
GEMM activations.

## 2. Accepted baseline

The following state is frozen as the starting point:

- Vortex commit: `3c47d2df` (`feat(pytorch): export Hadamard as one logical Vortex operation`);
- TVM commit: `14745fedd` (`feat(vortex): lower exported Hadamard to one parallel kernel`);
- C4 `alone` S1 full inference passes 32 layers of prefill and three decode phases, for 128 total
  decoder-layer calls;
- all accepted layer outputs are finite, no layer retry is required, and cache length advances
  `1 -> 2 -> 3 -> 4`;
- Hadamard widths 32, 128, and 14336 lower to one physical Vortex kernel per invocation;
- the real-geometry width-14336 kernel passes U55C comparison with observed maximum small-value
  absolute error `2.05636e-05` and maximum large-value relative error `9.57854e-04`;
- the accepted S1 package and trace are:
  - `/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s1_alone_single_kernel_hadamard_v1`;
  - `hardware_parallel_final_trace.json` under that directory;
- the current synthetic generated tokens are diagnostic only. A small numerical change can alter
  decode top-1 and therefore make later autoregressive inputs differ even when both paths remain
  numerically valid.

The earlier single-kernel Hadamard change reduced VM-instrumented calls by 160 per inference phase,
but did not demonstrate a stable end-to-end latency improvement. That result is a measurement
baseline, not a fused speedup claim.

## 3. Frozen hardware and quantization contract

- XCLBIN:
  `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin`
- Profile fingerprint:
  `62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256`
- Configuration:
  `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`
- Model geometry: 32 decoder layers, hidden size 4096, intermediate size 14336, 32 query heads,
  8 KV heads, head dimension 128, vocabulary size 128256;
- W, K, and V: signed asymmetric INT4 using their existing group sizes, FP16 scales, and INT16
  zero points;
- activations, residuals, and logits: FP16 unless an existing kernel uses a wider internal
  accumulator;
- GEMM backend: C4 `GEMM_IMPROVE` ABI/layout version 2;
- execution: the existing partitioned embedding, reusable decoder-layer, and final-head VMs;
- hardware runs: managed U55C/Slurm execution with the pinned image and one persistent process per
  complete prefill/decode run.

No RTL, hardware FSM, driver protocol, or xclbin change is planned. A hardware change may be
proposed only after a reduced reproducer proves different hardware results for identical generated
kernel inputs and runtime state.

## 4. Meaning of `fused` in this plan

The logical PyTorch/Relax model, public tensor ABI, synthetic parameters, and hardware image remain
the same as `alone`.

`alone` materializes row-major tensors at supported standalone boundaries. `fused` allows the TVM
pipeline to retain compatible C4-tiled activations across supported producer/consumer chains,
reuse a tiled GEMM input where legal, and avoid unnecessary tile/detile round trips.

The initial fused contract is deliberately narrow:

- preserve the already implemented fused GEMM layout reuse;
- keep unsupported operations behind explicit and correct row-major boundaries;
- let the current Hadamard `call_tir` remain one physical kernel even if it temporarily requires a
  row-major input/output boundary;
- never infer tiled ownership from shape alone; descriptor/layout provenance must prove it;
- detile at observable outputs, diagnostic captures, or unsupported consumers.

An optional later optimization may teach Hadamard to consume or produce a compatible tiled layout.
That is accepted only when trace evidence identifies its transform as material and source/IR
inspection proves the layout contract. It is not part of the first fused correctness gate.

## 5. Fixed validation cases

Use the four small cases already defined by the Llama3 C4 end-to-end plan:

| Case | Batch | Prompt length | Decode steps | Cache capacity | Primary coverage |
| --- | ---: | ---: | ---: | ---: | --- |
| S1 | 1 | 1 | 3 | 8 | smallest prefill and repeated append path |
| S2 | 1 | 7 | 3 | irregular sequence tail and cache lengths 8/9/10 |
| S3 | 2 | 1 | 3 | batch isolation with minimal sequence work |
| S4 | 2 | 7 | 3 | batching, GQA, tails, and cache reuse together |

S1 is the development gate. Do not start S2-S4 hardware sweeps until S1 passes compile inspection,
focused hardware checks, and full 32-layer inference.

Use deterministic token IDs and the existing seed `20260831`. Record the exact token matrix in
each artifact manifest; do not regenerate different prompts for `alone` and `fused`.

## 6. Numerical and semantic validation

### 6.1 FP16 comparison policy

Every comparison must first reject NaN and infinity.

- For small reference magnitudes, use absolute error because relative error is unstable near zero.
- For larger reference magnitudes, use relative error.
- Retain the existing stage-aware relative-L2, cosine, maximum magnitude, and violation-fraction
  checks; do not replace them with one global `allclose`.
- Use the accepted `alone` thresholds as the initial fused thresholds. If a threshold must change,
  save the first mismatch and justify the change from the error distribution rather than only its
  maximum.
- Report small-value maximum absolute error and large-value maximum relative error separately.

The expected isolated Hadamard error should remain close to the accepted U55C baseline. A material
regression is a failure even if a looser full-layer tolerance would hide it.

### 6.2 Autoregressive top-1 branching

Exact generated-token equality is not a sufficient or always meaningful numerical gate. If fused
and canonical execution choose different top-1 values after a small accepted logit perturbation,
their next decode inputs no longer match.

Use two modes:

1. **Canonical-input comparison:** run with identical recorded decode token/hidden/KV inputs, or
   `--diagnostic-reference-decode-inputs`, to compare the same computation at every phase.
2. **Free-running inference:** allow each path's argmax token to feed its next phase and require
   finite bounded hidden states, valid logits, exact cache semantics, and a recorded token trace.

For the known S1 behavior, canonical equality may initially be enforced through phase index 2 via
`--diagnostic-canonical-phase-limit 2`; decode phase 3 must still pass finite, magnitude, and cache
guards. Any divergence must also be rerun in canonical-input mode before it is classified as an
accepted top-1 branch.

### 6.3 KV-cache checks

After prefill and each decode step, validate all 32 layers:

- exact cache length and expected `+1` transition;
- preserved prefix and untouched suffix;
- K4/V4 payload, scale, and zero-point shapes and dtypes;
- batch isolation for S3 and S4;
- no host reconstruction of resident state between layer calls;
- stable results in the same process with zero diagnostic retries.

## 7. Milestones

### Milestone A: Host compile and source inspection

Package S1 with `--layout-policy fused` without using the FPGA, then inspect the generated Relax,
TIR, C++ source, manifest, and trace metadata.

Required checks:

1. artifact metadata says `fused`, C4 ABI/layout version 2, and the pinned profile fingerprint;
2. asymmetric W4/K4/V4 metadata matches the accepted `alone` package;
3. the one-layer module contains the expected logical Hadamard sites and each site lowers to one
   physical Vortex kernel, not one kernel per butterfly stage;
4. no naive GEMM or FP TCU fallback appears;
5. existing fused GEMM activation reuse remains visible (the accepted one-layer compiler tests
   currently expect three reused A layouts and reduce `gemm_a_tiled` calls from 15 to 12);
6. row-major boundaries around Hadamard are explicit when required and are not silently interpreted
   as tiled storage;
7. serialization/reload reconstructs the same module inventory and metadata without recompiling.

Add focused compiler tests before hardware execution if any of these properties is not already
asserted. Count physical Vortex kernels by generated kernel symbol/launch, separately from Relax VM
builtins and instrumentation callbacks.

**Exit gate:** S1 fused package reloads, source inspection passes, and compiler tests prove the
single-kernel Hadamard plus existing tiled-A reuse.

### Milestone B: Focused U55C correctness

Before a full model run, execute reduced cases on the pinned U55C:

1. isolated rank-3 width-128 Hadamard;
2. isolated rank-4 width-14336 Hadamard;
3. one decoder-layer prefill for S1;
4. one decoder-layer decode using a real prefill-created cache;
5. the same reduced inputs under `alone` and `fused` in one persistent process when practical.

Capture generated source identity, input/output hashes, device addresses, physical launch counts,
latency, and split absolute/relative error summaries.

If `alone` passes and `fused` fails, compare the tensors immediately before and after the first
layout boundary. Do not start from RTL simulation; first determine whether the same logical tensor
has different descriptor, stride, tile ownership, or lifetime.

**Exit gate:** all four reduced paths pass with no non-finite result, exactly one Hadamard launch per
logical invocation, and no unexplained difference from `alone`.

### Milestone C: Full S1 prefill plus decode

Run one complete S1 inference in one process:

```text
embedding
  -> 32-layer prefill
  -> final norm and W4 LM head
  -> argmax
  -> 32-layer decode 1
  -> argmax
  -> 32-layer decode 2
  -> argmax
  -> 32-layer decode 3
```

Use the stable runtime settings established by the `alone` investigation: persistent device and
programming state, fixed hidden-input address where applicable, device-copy state transport, and
the accepted retain-all/preallocated state policy. Start with
`--diagnostic-layer-retries 0`; a retry is a diagnostic observation, never an acceptance mechanism.

Save:

- the fused package and archive manifest;
- a full JSON trace;
- per-phase latency and physical launch counts;
- all layer finite/magnitude summaries;
- cache lengths `1, 2, 3, 4`;
- generated token IDs and top-k/logit diagnostics;
- the first mismatching layer artifact if canonical comparison fails.

**Exit gate:** 128 decoder-layer calls complete, no NaN/inf occurs, no retry is used, cache state is
correct, canonical-input comparison passes, and free-running inference satisfies the stage-aware
guards.

### Milestone D: S2-S4 coverage

Expand only after S1 is accepted:

1. S2 to cover sequence/K tails;
2. S3 to cover batch isolation;
3. S4 to cover batching, GQA, tails, and state reuse together.

For every case, generate matching `alone` and `fused` packages or reuse a package only when its
static shape contract explicitly permits it. Run prefill plus three decode steps and retain the
same validation artifacts as S1.

Do not combine failures from multiple cases. Reduce the first failing case to one phase and one
layer, then to the first mismatching operation/layout boundary.

**Exit gate:** all four cases pass fused prefill/decode with exact cache semantics and the numerical
policy in Section 6.

### Milestone E: Fused performance analysis and targeted optimization

Once correctness is stable, compare `alone` and `fused` using identical packages, prompts, runtime
settings, and FPGA allocation conditions.

Measure separately:

- physical Vortex kernel launches by kernel class;
- `gemm_a_tiled`, `gemm_c_detiled`, and any explicit layout-conversion launches;
- Hadamard launches;
- device-to-device and host-device transfers;
- per-layer, per-phase, and end-to-end host latency;
- compile/package time and artifact size.

Use at least three same-process inference repetitions after one warmup when queue time permits.
Report individual samples, median, and range. A launch reduction is not automatically a latency
improvement.

Prioritize an optimization only when the trace identifies a repeated material boundary. The first
candidate is the boundary between the FFN Hadamard result and its C4 GEMM consumer:

- allow Hadamard to produce the consumer's required tiled-A layout, or
- allow it to consume a proven compatible tiled producer layout,
- while keeping Hadamard as one physical kernel and preserving observable row-major semantics.

Any such change requires descriptor-based layout proof, source assertions, isolated U55C tests,
and rerunning Milestones B-D. Do not broaden this into general arbitrary-op fusion during this
task.

**Exit gate:** the report quantifies transform/launch deltas and latency. A correctness-complete
fused result may be accepted with neutral latency; a performance claim requires a repeatable median
improvement beyond run-to-run noise.

### Milestone F: Regression, documentation, and commits

Run the relevant TVM unit tests and application tests, retain the U55C traces, and update the
execution report with:

- exact Vortex and TVM commits;
- package/archive hashes and profile fingerprint;
- S1-S4 result matrix;
- numerical summaries;
- cache lifecycle;
- physical launch/transform counts;
- latency samples and conclusion;
- explicit deferred work.

Suggested commit split:

1. `test(vortex): validate single-kernel Hadamard in fused Llama3 lowering`
2. `feat(vortex): run fused Llama3 prefill and stateful decode` (only if implementation changes are
   required)
3. `perf(vortex): remove measured fused Hadamard layout boundaries` (optional and evidence-driven)
4. `docs(vortex): record C4 fused Llama3 inference results`

Do not mix an optional layout optimization into the initial correctness commit.

## 8. Debugging order

Use this order for every failure:

1. confirm package, archive, fingerprint, and xclbin identity;
2. inspect generated source and count physical kernels;
3. compare `alone` and `fused` at the earliest explicit layout boundary;
4. rerun one isolated operation with identical host inputs;
5. rerun one layer with recorded inputs and cache state;
6. compare prefill, then decode 1, then later decode phases;
7. force canonical decode inputs if top-1 diverges;
8. inspect buffer lifetime/address stability in the same process;
9. use RTL simulation only if identical generated kernel inputs and descriptors produce an
   operation-level hardware mismatch that software layout/lifetime analysis cannot explain.

This order distinguishes compiler layout mistakes, runtime state lifetime errors, numerical
top-1 branching, and true hardware defects without paying full RTL-simulation cost too early.

## 9. Example execution shape

Package S1 from the TVM repository with the existing runner:

```bash
python apps/vortex_llama3/run_synthetic_inference.py \
  --mode package \
  --layout-policy fused \
  --prompt-token-ids 1 \
  --decode-steps 3 \
  --cache-capacity 8 \
  --artifact-dir build/llama3_synthetic_s1_fused_single_kernel_hadamard_v1 \
  --trace-output build/llama3_synthetic_s1_fused_single_kernel_hadamard_v1/package_trace.json
```

The hardware invocation must additionally use the pinned xclbin, accepted persistent-runtime
options, diagnostic layer checks, and a managed U55C allocation. Preserve the exact final command
in the execution report rather than treating this illustrative package command as the hardware
recipe.

## 10. Final acceptance criteria

The task is complete when all of the following are true:

1. S1-S4 package and reload under C4 `fused` with the pinned profile;
2. each case completes prefill followed by three decode steps on U55C;
3. all layer results are finite and pass the stage-aware small-absolute/large-relative policy;
4. all 32 layer caches have exact lengths, preserved prefixes, untouched suffixes, and batch
   isolation;
5. no diagnostic retry is needed;
6. every logical Hadamard call remains exactly one physical Vortex kernel;
7. existing fused tiled-A reuse is preserved and source/IR tests prevent silent layout regressions;
8. free-running top-1 divergence, if present, is explained by a passing canonical-input rerun;
9. physical launches and conversions are counted separately from VM builtins;
10. `alone` versus `fused` latency and launch deltas are recorded without unsupported speedup
    claims;
11. no RTL, FSM, driver protocol, or xclbin change is required;
12. tests, artifacts, revisions, and conclusions are documented reproducibly.

## 11. Deferred work

- real Llama3-8B checkpoint conversion and language-quality validation;
- C1, C2, C3, FP TCU, and naive GEMM backends;
- first-class additional batching/GQA hardware work beyond the already scoped S1-S4 validation;
- monolithic 32-layer Relax compilation;
- general layout propagation through RMSNorm, RoPE, cache update, and arbitrary custom operations;
- combining Hadamard arithmetic with GEMM arithmetic in one hardware kernel;
- RTL/FSM changes or a new FPGA image;
- production sampling, tokenizer integration, perplexity, and throughput benchmarking.

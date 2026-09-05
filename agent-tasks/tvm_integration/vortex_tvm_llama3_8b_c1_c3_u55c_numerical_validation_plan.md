# Vortex TVM Llama3-8B C1/C3 U55C Numerical Validation Plan

## 1. Goal

Run the already compiled synthetic Llama3-8B C1 and C3 packages on a physical U55C and prove that
Vortex produces numerically similar results to a backend-matched PyTorch GPU reference.
Validate both prefill and three consecutive stateful decode steps for all four existing small shape
cases.

The comparison is per backend:

- C1 Vortex is compared with the C1 PyTorch GPU reference;
- C3 Vortex is compared with the C3 PyTorch GPU reference;
- C1 and C3 are not required to be bit-identical to each other because their dequantization and
  accumulation boundaries intentionally differ.

The PyTorch CUDA execution is the sole normal numerical oracle. CPU execution is optional fallback
diagnosis only: use it when the GPU reference cannot run, appears nondeterministic, or needs an
independent check while localizing a mismatch. CPU evidence is not part of the normal matrix and
cannot replace the required GPU-versus-U55C comparison for final acceptance.

This remains deterministic synthetic Llama3-8B inference with signed asymmetric W4/K4/V4 logical
parameters. Real checkpoint conversion and language-quality evaluation are separate later work.

## 2. Accepted baseline

The host compile milestone is complete:

- all C1/C3 S1-S4 packages compile, serialize, reload, and pass exact profile checks;
- S1 has both bytecode and compiled VM artifacts; S2-S4 have bytecode artifacts;
- every C1 layer routes its seven linear operations plus QK/PV attention through FP16 TCU jobs;
- every C3 layer routes the same logical operations through row-major naive W4A16 jobs;
- batch/GQA expansion, arbitrary tails, padding, slicing, and kernel inventories are compile-tested;
- C4 `alone` and `fused` regressions remain green.

The packages are currently under:

```text
/home/jaeyongjang/project.local/tvm/build/llama3_c1_c3_compile_matrix
```

The source-of-truth baseline is recorded in:

- `agent-tasks/tvm_integration/vortex_tvm_llama3_8b_c1_c2_c3_compile_plan.md`;
- `agent-tasks/tvm_integration/vortex_tvm_llama3_8b_c1_c2_c3_compile_execution_report.md`;
- `agent-tasks/tvm_integration/vortex_tvm_llama3_8b_c1_c2_c3_compile_evidence.json`.

No C1/C3 package has yet run on an FPGA. This plan closes that hardware and numerical gap. It must
reuse the accepted package identities instead of substituting a new config, profile, xclbin, or
parameter materialization without recording a new package and hash.

## 3. Scope and non-goals

### 3.1 In scope

- exact C1 and C3 aliases from `ci/fpga_bin_alias_map.yaml`;
- PyTorch eager reference generation on GPU;
- optional CPU fallback generation only for reference or mismatch diagnosis;
- physical U55C execution through the Vortex XRT runtime;
- token embedding, one reusable decoder layer invoked for all 32 logical layers, final norm, and LM
  head;
- prefill followed by three decode steps in one persistent process;
- canonical-input numerical validation and free-running autoregressive validation;
- hidden states, layer checkpoints, logits, selected tokens, and asymmetric K4/V4 cache semantics;
- S1-S4 batch, sequence-tail, GQA, and cache-capacity coverage;
- bytecode VM for the complete matrix and representative S1 compiled-VM coverage;
- regression tests and machine-readable evidence.

### 3.2 Out of scope

- C2, until its exact mapped binary and sibling manifest are available;
- C4, except as a regression and numerical-method baseline;
- real Llama3-8B checkpoint loading or text-quality evaluation;
- performance optimization or C1-versus-C3 latency ranking;
- new dynamic shapes, longer prompts, more decode steps, or sampling other than argmax;
- RTL/FSM changes, FPGA synthesis, or a replacement xclbin.

Start with software, package, and same-input numerical localization. If a primitive canonical-input
mismatch remains after compiler and runtime causes are excluded, stop and create a separate RTL
debug task with the captured minimal reproducer. Do not broaden this validation plan into an RTL
change automatically.

## 4. Frozen backend and hardware contract

Resolve both aliases at execution time and fail closed against the package metadata.

| Alias | Policy | Config | Xclbin directory | Profile fingerprint |
| --- | --- | --- | --- | --- |
| C1 | `c1_all_fp16_tcu` | `configs/tcu_th32_c1_rev2.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/bin` | `48c79e30...d957` |
| C3 | `c3_all_w4_naive` | `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_9600db3a37/bin` | `5ceb94c3...e74c4` |

Both targets use `rv64imaf/lp64f`. For each hardware run, record and verify:

- alias, config hash, manifest hash, xclbin path and hash, and full profile fingerprint;
- package, logical archive, physical materialization, and every VM artifact hash;
- Vortex and TVM revisions;
- Slurm job/allocation, U55C BDF, XRT device index, and runtime environment;
- bytecode or compiled VM mode and all runtime allocator/state-lifetime controls.

Program only one backend image in a process. C1 and C3 must use separate fresh jobs or processes;
never switch their xclbins inside one Python process. Within one backend run, keep the process,
device, xclbin programming, resident parameters, and cache state alive from prefill through all
decode steps.

## 5. Backend-matched reference contract

The GPU reference must execute the same eager module classes, logical archive, backend physical
materialization, token IDs, positions, and initial cache state used by the packaged Vortex graph.
An unrelated FP32 Llama implementation is not an acceptable reference or fallback.

### 5.1 C1 reference

C1 consumes the profile-bound FP16 materialization:

- W/K/V logical INT4 values are dequantized and rounded to FP16 at materialization time;
- all seven layer projections and the LM head use FP16 weights;
- K/V cache values are dequantized to FP16 before QK/PV attention;
- each logical matmul computes from FP16 operands with FP32 accumulation and returns FP16;
- logical zero-padding and post-TCU slicing must be represented when a focused reference exercises
  the physical padded shape.

### 5.2 C3 reference

C3 consumes the profile-bound row-major W4 materialization:

- all seven layer projections and the LM head dequantize signed asymmetric W4 at the logical GEMM
  boundary;
- QK and PV consume signed asymmetric K4/V4 cache payload, scale, and INT16 zero point through the
  naive W4A16 semantics;
- dequantized values and FP16 activations are accumulated in FP32 and rounded to FP16 at the same
  observable boundaries as the eager custom operations;
- no C4 IMPROVE prepacking or C1 pre-dequantized weight may enter the C3 reference.

### 5.3 GPU determinism

Before generating GPU evidence:

1. require an available CUDA device and record its name, compute capability, driver, CUDA runtime,
   cuBLAS, PyTorch version, and free/total memory;
2. set the same seed (`20260831`) and deterministic token matrix used by Vortex;
3. disable TF32 for CUDA matmul and cuDNN, request the highest float32 matmul precision, and enable
   deterministic algorithms where supported;
4. set and record the deterministic cuBLAS workspace configuration before process startup;
5. synchronize before every measured or serialized checkpoint;
6. fail instead of silently falling back to CPU for an unsupported CUDA custom operation.

GPU reference generation must finish and close before the XRT process opens the U55C. Exchange only
immutable, hash-verified NPZ and JSON artifacts between the GPU and XRT processes.

### 5.4 CPU fallback policy

Do not generate CPU references in the normal S1-S4 matrix. A CPU fallback is permitted only to:

- confirm eager semantics when a required custom operation fails on CUDA;
- distinguish GPU nondeterminism or a GPU-library issue from a Vortex mismatch;
- continue runner/schema development while a GPU node is temporarily unavailable;
- inspect a small first-failing tensor when GPU and Vortex disagree unexpectedly.

The fallback must use the same eager graph and backend materialization, run in its own process, and
be labeled `diagnostic_cpu` in all metadata. It must never be silently selected. A CPU-only pass may
guide debugging but does not satisfy a GPU-versus-Vortex exit gate.

## 6. Fixed validation matrix

Use the same deterministic cases and seed as the accepted C4 work.

| Case | Batch | Prompt length | Decode steps | Cache capacity | Primary coverage |
| --- | ---: | ---: | ---: | ---: | --- |
| S1 | 1 | 1 | 3 | 8 | smallest end-to-end and repeated append path |
| S2 | 1 | 7 | 3 | irregular sequence tail and cache lengths 7-10 |
| S3 | 2 | 1 | 3 | batch isolation with minimal sequence work |
| S4 | 2 | 7 | 3 | batch, GQA, tails, and cache reuse together |

For each C1/C3 case, produce two required executions over identical canonical inputs:

1. PyTorch GPU;
2. Vortex on the alias-matched U55C.

S1 is the development gate. Do not start the S2-S4 U55C sweep until the GPU reference is stable,
focused hardware probes pass, and the complete S1 canonical-input chain passes for that backend.
C1 and C3 may advance independently; a C1 failure must not erase useful C3 evidence, or vice versa.

## 7. Validation modes

### 7.1 Canonical-input comparison

Canonical-input mode is the primary numerical acceptance path. GPU-recorded token IDs, positions,
hidden inputs, and previous-phase KV state are supplied identically to GPU and Vortex at each
comparison boundary. This prevents an accepted earlier rounding difference or argmax branch from
changing the next input.

Record at least:

- embedding output;
- each of 32 layer hidden outputs;
- focused Q/K/V projection, QK score, causal-softmax probability, PV context, attention residual,
  MLP, and final layer output checkpoints for the diagnostic layer build;
- K/V payload, scale, zero point, valid length, preserved prefix, and untouched suffix;
- final normalized hidden state and logits;
- top-k values, indices, and the top-1 margin.

The GPU artifact is the canonical input and output source. Compare U55C directly against it at every
required boundary. A diagnostic CPU artifact, if one exists, must be reported separately and must
not be averaged with or substituted for the GPU reference.

### 7.2 Free-running inference

Free-running mode tests the real autoregressive control path:

```text
embedding
  -> 32-layer prefill -> final head -> argmax
  -> 32-layer decode 1 -> final head -> argmax
  -> 32-layer decode 2 -> final head -> argmax
  -> 32-layer decode 3 -> final head
```

Each device feeds its own selected token and resident KV cache into the next decode phase. Require
finite bounded states, valid logits, exact cache-length transitions, untouched cache suffixes, and
batch isolation. Record generated tokens but do not classify a token difference by itself as a
hardware failure. Any free-running branch must be replayed in canonical-input mode at the first
divergent phase; identical-input logits must pass the numerical gates before the branch can be
accepted as ordinary autoregressive sensitivity.

### 7.3 Persistent-process stability

For final S1 acceptance, repeat the complete free-running inference twice in one process with one
device open, one xclbin programming event, and one parameter upload. Both repetitions must finish
with zero retry, zero timeout, and identical per-step Vortex hashes. Run S2-S4 once after S1 proves
the persistent lifetime contract. A retry may capture diagnostics but never converts a failure into
accepted evidence.

## 8. Numerical acceptance policy

Every floating-point comparison must reject NaN and infinity first. Preserve tensors as FP16 where
that is the observable ABI, convert to FP32/FP64 only for metric calculation, and report all metrics
per tensor, layer, phase, case, backend, and reference device.

### 8.1 Hybrid pointwise metrics

Use `abs(reference) < 0.25` as the initial small-value region:

- small values: maximum absolute error and absolute-error violation fraction;
- larger values: maximum relative error and relative-error violation fraction;
- all values: relative-L2, cosine similarity, maximum magnitude, and non-finite count.

The initial local-operation pointwise limits are `2e-3` absolute and `2e-3` relative, matching the
accepted materialization policy. Milestone C may define stricter or stage-specific limits from the
repeated GPU and focused U55C distributions. Any relaxed stage-specific limit must be frozen in a
versioned threshold JSON before the 32-layer S1 run, include its empirical justification, and stay
within these hard ceilings:

| Comparison boundary | Maximum relative-L2 | Minimum cosine | Maximum violation fraction |
| --- | ---: | ---: | ---: |
| U55C versus GPU local operation/layer | `1e-2` | `0.999` | `0.02` |
| accumulated 32-layer normalized hidden/logits | `5e-2` | `0.995` | `0.08` |

The hard ceilings prevent a broadly wrong tensor from passing because a few aggregate statistics
look good. Do not change a threshold after seeing an S2-S4 failure merely to make the matrix pass;
first save the mismatch, localize its first divergent boundary, and justify any proposed policy
change separately.

For canonical-input final logits, require top-1 agreement with the GPU reference. Record the GPU
top-1 margin so a free-running branch can be distinguished from a same-input numerical failure.

### 8.2 KV-cache semantics

After prefill and every decode phase, validate all 32 layers:

- exact cache lengths `prompt`, `prompt+1`, `prompt+2`, and `prompt+3`;
- exact shape, dtype, capacity, and batch/head ownership;
- byte-identical untouched suffix and preserved prefix where no requantization is expected;
- signed INT4 payload differences no greater than two codes with mismatch rate no greater than
  20 percent in valid regions;
- zero-point differences no greater than one code with mismatch rate no greater than 20 percent;
- hybrid scale metrics plus dequantized-cache relative-L2/cosine metrics using the accepted C4
  semantic checker as the starting policy;
- no host reconstruction of Vortex resident state between phases.

Integer semantic fields should match the GPU reference exactly where the operation contract is
exact. If GPU and Vortex quantization select adjacent codes near a rounding tie, store the
pre-quantized value and prove that both decode to values inside the frozen numerical bound instead
of hiding the difference. Use CPU only as an explicitly labeled diagnostic if the GPU result itself
is in doubt.

## 9. Implementation architecture

The current `run_synthetic_inference.py` package/loader is C4-specific, while
`compile_backend_matrix.py` owns the accepted C1/C3 package format. Introduce a backend-neutral
execution layer rather than copying the C4 runner wholesale.

Required responsibilities:

1. load `vortex-llama3-backend-compile-package` with all existing fail-closed alias, profile,
   archive, materialization, and VM hash checks;
2. select bytecode or compiled artifact keys without recompilation;
3. upload the correct C1 FP16 or C3 row-major W4 materialization and preserve one resident slice per
   logical layer;
4. construct backend-matched eager GPU modules directly from package policy metadata, with an
   explicitly requested CPU diagnostic fallback using the same code path;
5. serialize GPU references with model, prompt, seed, backend policy, archive hashes,
   device metadata, deterministic flags, tensor inventory, and per-tensor hashes;
6. reject missing, extra, stale, cross-backend, cross-shape, or cross-prompt reference arrays before
   opening XRT;
7. reuse the accepted C4 runtime lifetime controls: persistent process, device-copy state transport,
   fixed hidden input where appropriate, retained/preallocated state, and zero diagnostic retries;
8. emit a compact JSON trace and a detailed first-mismatch artifact without embedding multi-GB
   tensors in repository files.

Prefer extracting common archive upload, hybrid metrics, cache checks, reference schema, and trace
helpers shared with the C4 runner. Keep the existing C4 CLI and package format backward compatible,
and add unit tests before changing its behavior.

## 10. Milestones

### Milestone A: Generalize reference and runtime loading

1. Add a strict C1/C3 execution-package loader around the accepted compile packages.
2. Add a GPU reference generator that selects `linear_compute` and `attention_compute` from package
   policy rather than command-line guesses; expose CPU only through an explicit diagnostic flag.
3. Add reference metadata, hashes, deterministic replay, and CPU-fallback labeling.
4. Extract or reuse C4 numerical and cache semantic checkers.
5. Add negative tests for wrong alias, xclbin, profile, policy, materialization, case, prompt, seed,
   device label, and tensor inventory.
6. Prove that reference generation does not import or open XRT and that the U55C run path does not
   initialize CUDA.

**Exit gate:** C1 and C3 S1 packages reload, GPU reference artifacts validate against package
identity, deliberate cross-package substitutions fail before device open, CPU cannot be selected
silently, and C4 application tests remain green.

### Milestone B: Establish the GPU oracle

Generate C1 and C3 S1 GPU references without FPGA access.

1. Record and replay embedding, one prefill layer, one decode layer with a prefill-created cache,
   final head, and full 32-layer phase outputs.
2. Record every eager checkpoint rather than only final logits.
3. Confirm finite outputs, valid cache lengths, and valid top-1/logit-margin records.
4. Freeze the initial threshold JSON and reference artifact schema.
5. Repeat GPU reference generation to prove deterministic hashes or document bounded CUDA
   reduction-order variation before using the artifact as an oracle.
6. Invoke the CPU fallback only if a GPU issue needs diagnosis; keep it outside acceptance evidence.

**Exit gate:** both backends have stable, hash-verified GPU S1 reference artifacts, deterministic
settings are recorded, and no silent CPU fallback occurred.

### Milestone C: Focused U55C backend probes

Run small same-input probes before a complete model chain.

For C1:

1. one tail-padded FP16 TCU linear projection;
2. one batched/GQA QK job and one PV job with logical slicing;
3. one S1 prefill layer;
4. one S1 decode layer using a real prefill-created K4/V4 cache;
5. one final-head invocation.

For C3:

1. one row-major W4A16 linear projection;
2. one batched/GQA W4 QK job with transposed RHS and one W4 PV job;
3. one S1 prefill layer;
4. one S1 decode layer using a real prefill-created K4/V4 cache;
5. one final-head invocation.

Capture input/output hashes, logical and physical shapes, padding/slicing, kernel launch inventory,
device addresses, and comparison metrics against the GPU reference. Freeze any justified
stage-specific thresholds now, before full-chain testing.

**Exit gate:** all ten probes pass with zero non-finite result, zero retry, exact backend routing,
and no unexplained GPU/U55C mismatch.

### Milestone D: Complete S1 canonical-input validation

Run all 32 layers for prefill and three decode phases on each backend, using the GPU-recorded input
and previous-phase state independently at every comparison boundary.

1. compare every layer hidden output and cache state against the GPU reference;
2. compare normalized hidden, logits, top-k, top-1, and top-1 margin;
3. stop and save the first failing layer/operation while the U55C process is still healthy;
4. rerun the minimal failing canonical input once in a fresh process to distinguish reproducible
   calculation error from runtime/device state corruption;
5. run S1 bytecode for both backends and representative compiled-VM S1 coverage.

**Exit gate:** C1 and C3 complete all four S1 phases within the frozen numerical and cache limits,
with zero timeout/retry and exact canonical-input top-1 agreement against the GPU reference.

### Milestone E: Free-running S1 and S2-S4 expansion

1. Run two persistent-process S1 repetitions for C1, then C3.
2. Run canonical-input and free-running S2, S3, and S4 in bytecode mode.
3. For any token branch, replay the first differing phase with canonical inputs and record the
   margin-based explanation.
4. Verify batch isolation explicitly for S3/S4 and irregular tail/cache behavior for S2/S4.
5. Record phase and total latency for observability only; do not optimize in this milestone.

**Exit gate:** all eight backend/case combinations finish prefill plus three decode steps; canonical
comparisons pass against the GPU reference, free-running states remain finite and semantically valid,
and all token branches have same-input evidence.

### Milestone F: Regression and evidence publication

1. Run package, archive, backend-policy, TCU padding, naive W4, batched/GQA, serialization, reference,
   and runner tests.
2. Rerun C4 `alone`/`fused` host tests and a representative accepted C4 U55C smoke test when FPGA
   time permits.
3. Write an execution report and machine-readable evidence JSON.
4. Record exact commands, environments, artifacts, hashes, device identities, metrics, failures,
   and reruns.
5. Keep large NPZ/package artifacts in the build artifact directory; commit only compact plans,
   reports, schemas, tests, and evidence summaries.

**Exit gate:** the full result is reproducible from exact immutable artifacts, regressions pass,
and the report states separately whether C1 and C3 passed.

## 11. Failure triage order

Use the first failing canonical-input boundary and investigate in this order:

1. package, alias, config, manifest, xclbin, profile, archive, and materialization identity;
2. GPU reference determinism, accidental TF32, unsupported CUDA operation, or silent CPU fallback;
3. input token, position, hidden, parameter-slice, and cache hashes;
4. C1 FP16 versus C3 W4 backend policy and generated kernel inventory;
5. batch/GQA job ownership, TCU padding/slicing, or naive row-major/transpose contract;
6. first differing layer checkpoint: projection, RoPE/Hadamard, cache quantization, QK, softmax, PV,
   residual, MLP, final norm, or head;
7. VM allocator, tensor lifetime, fixed-address behavior, state transport, and repeated-call state;
8. XRT/device health, timeout, or stale programming state;
9. minimal native hardware reproducer;
10. RTL simulation only after the failure is reduced to a deterministic primitive input.

Do not debug a free-running token branch before replaying identical inputs. Do not use looser
full-chain thresholds to hide a failing local operation.

## 12. Deliverables

- backend-neutral C1/C3 synthetic inference runner;
- GPU reference generator with deterministic, hash-verified artifacts and explicit CPU diagnostic
  fallback;
- shared hybrid FP16 and asymmetric KV-cache comparison helpers;
- focused C1 TCU and C3 naive W4 hardware probes;
- C1/C3 S1-S4 canonical and free-running U55C traces;
- versioned threshold and reference schemas;
- regression tests and exact run commands;
- `vortex_tvm_llama3_8b_c1_c3_u55c_numerical_validation_execution_report.md`;
- `vortex_tvm_llama3_8b_c1_c3_u55c_numerical_validation_evidence.json`.

## 13. Final acceptance criteria

The milestone is complete only when:

1. exact C1 and C3 alias/profile/xclbin identities match their packages at runtime;
2. GPU executes backend-matched eager semantics over identical archive content and inputs;
3. GPU reference replay is stable before it is used to judge U55C;
4. focused C1 TCU and C3 naive W4 probes pass against the GPU reference;
5. C1 and C3 each complete S1-S4 prefill plus three decode steps on a physical U55C;
6. every canonical-input phase passes the frozen hybrid numerical limits against the GPU reference;
7. canonical-input final logits and top-1 agree with the GPU reference;
8. every layer has exact cache lengths and valid asymmetric K4/V4 payload/scale/zero semantics;
9. free-running inference has no NaN, infinity, runaway magnitude, invalid cache state, timeout, or
   accepted retry;
10. every free-running token branch is explained by a passing same-input replay;
11. S1 is stable across two complete repetitions in one persistent U55C process per backend;
12. C4 and common compiler/runtime regressions remain green;
13. reports distinguish numerical correctness, semantic cache correctness, runtime stability, and
   non-gating latency observations;
14. no RTL/FSM/xclbin change is required or silently introduced by this task.

## 14. Deferred work

- C2 hardware validation after its exact mapped binary and manifest are installed;
- C1-C4 performance, throughput, power, and memory comparison;
- longer contexts, larger batches, additional decode steps, and dynamic shapes;
- real Llama3-8B checkpoint conversion and meaningful text generation;
- accuracy evaluation on language datasets;
- automatic backend selection;
- RTL changes for any deterministic primitive failure isolated by this plan.

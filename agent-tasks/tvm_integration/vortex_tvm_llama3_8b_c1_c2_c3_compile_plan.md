# Vortex TVM Llama3-8B C1/C2/C3 Compile Plan

## 1. Goal

Compile, package, serialize, and reload the existing backend-neutral synthetic Llama3-8B graph for
the exact C1, C2, and C3 aliases in `ci/fpga_bin_alias_map.yaml`.

This milestone is host-compile acceptance. It proves backend selection, physical parameter format,
generated kernel inventory, package identity, and reloadability for all four small S1-S4 shapes.
U55C execution for C1/C2/C3 is a later milestone and is not required by this plan.

The S2 device-poison task in
`agent-tasks/tvm_integration/vortex_tvm_llama3_s2_device_poison_debug_plan.md` is a required
stability prerequisite before the final cross-backend package sweep begins. Host-only compiler
unit work may proceed independently, but do not declare this plan accepted until that prerequisite
passes.

## 2. Source-of-truth aliases

Resolve aliases from `ci/fpga_bin_alias_map.yaml`; do not duplicate capability assumptions in the
runner.

| Alias | Config | Image directory | Normalized capability |
| --- | --- | --- | --- |
| C1 | `configs/tcu_th32_c1_rev2.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_tcu_94c5b39919/bin` | FP16 TCU, no GEMM accelerator |
| C2 | `configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_d953b60098/bin` | FP16 TCU plus naive FPINT GEMM |
| C3 | `configs/naive_gemm_th32_tcol32_hwexp_dcache.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_9600db3a37/bin` | naive FPINT GEMM, no TCU |

For each alias, load the sibling xclbin manifest through
`load_vortex_accelerator_profile`. Store the exact resolved alias, xclbin path, manifest hash,
normalized target attributes, and profile fingerprint in the package. A config-only approximation
or the C4 fingerprint is not acceptable.

## 3. Backend computation contract

Use the existing `gen_kernel_cfgs.py` workload variants as the semantic oracle for operation
assignment, not as physical compiler IR.

| Backend | Workload policy | Linear projections | QK/PV attention |
| --- | --- | --- | --- |
| C1 | `all_sgemm_tcu` | FP16 x FP16 TCU | FP16 x FP16 TCU |
| C2 | `attn_sgemm_tcu_fpint_gemm_naive` | asymmetric W4 x FP16 naive GEMM | FP16 x FP16 TCU |
| C3 | `all_fpint_gemm_naive` | asymmetric W4 x FP16 naive GEMM | asymmetric K4/V4 x FP16 naive GEMM |

W, K, and V originate from the same signed asymmetric 4-bit logical model. Backend selection may
change the physical compute operands:

- C1 dequantizes W/K/V to FP16 before TCU compute;
- C2 retains W4 for linear projections but dequantizes K/V for FP16 attention compute;
- C3 consumes row-major packed W4/K4/V4 plus FP16 scales and INT16 zero points directly;
- no backend may silently use C4 IMPROVE tiling or prepacked layout.

The eager reference must follow each backend's actual dequantization boundary and FP16 rounding,
rather than comparing every backend to an unobservable FP32 ideal.

## 4. Current blockers

The current synthetic runner is C4-specific in several ways:

1. it imports `C4ParameterArchive` and prepares IMPROVE-prepacked parameters;
2. decoder/head modules are constructed with `prepacked_weights=True`;
3. package format and CLI describe only C4 `alone`/`fused` layout policy;
4. C1 leaves logical W4A16 calls unresolved because it has no FPINT GEMM mode;
5. C2 needs different backend assignment for linear and attention GEMMs;
6. current FP16 TCU tensorization recognizes only eligible static rank-2 matmul;
7. S1-S4 have logical M/Q extents 1 or 7 and attention capacity 8 or 16, while the current TCU
   physical contract requires M/N multiples of 16 and K multiples of 32;
8. C3 requires canonical row-major packed parameters, not C4 tile-major buffers.

Changing only `XRT_XCLBIN_PATH` or `--layout-policy` cannot satisfy this plan.

## 5. Architecture

### 5.1 Backend-neutral logical archive

Introduce a versioned logical Llama3 parameter archive containing canonical tensors:

- packed signed asymmetric W4 payloads;
- FP16 scales and INT16 zero points;
- norm and embedding tensors;
- logical shapes, group sizes, axes, model metadata, and content hashes.

Do not bind this logical archive to one accelerator fingerprint. Derive and cache backend-specific
materializations separately:

- C1 FP16 dequantized projection weights;
- C2/C3 canonical row-major W4 projection buffers;
- C4 IMPROVE-prepacked buffers remain supported by the existing C4 path.

Each derived cache must record the logical archive hash, backend policy, profile fingerprint,
physical descriptor version, and tensor hashes. A cache created for one profile must fail closed
when loaded under another incompatible profile.

For host compile, materialize only the reusable compiled-layer slice and head tensors required by
the compiler. Do not embed or duplicate the complete 8B parameter set in Relax IR.

### 5.2 Explicit backend policy

Add a compiler/package policy independent of the C4 layout option, with initial values:

```text
c1_all_fp16_tcu
c2_linear_w4_naive_attention_fp16_tcu
c3_all_w4_naive
c4_all_w4_improve
```

Validate the policy against normalized target capabilities before export or build. Reject C1
policy on a target without FP16 TCU, C2 without both TCU and naive GEMM, and C3 without naive GEMM.
Do not silently substitute a generic matmul when an accelerated backend is required by policy.

`alone`/`fused` remains a C4 IMPROVE physical-layout policy. C1/C2/C3 packages should record
`layout_policy: not_applicable` or an explicit row-major policy rather than pretending to be C4.

### 5.3 Backend-neutral model boundaries

Keep PyTorch export free of physical C1/C2/C3/C4 operations. Logical operations must carry enough
semantics for target selection:

- linear W4A16 projection;
- FP16 dense projection after explicit logical dequantization;
- K/V cache quantize, update, and dequantize;
- QK-transpose and PV attention roles;
- Hadamard and causal-softmax operations.

Use explicit operation role or provenance for C2 routing. Shape alone must not decide whether a
matmul is a linear projection or attention operation.

### 5.4 TCU padding and batched/GQA lowering

C1/C2 must support the small S1-S4 logical shapes without changing observable semantics.

- pad logical M and N to multiples of 16;
- pad physical K to a multiple of 32;
- zero-fill padded activations/weights/probabilities;
- slice the physical output back to the exact logical shape;
- preserve causal masking so padded keys never receive probability mass;
- preserve batch, query-head, KV-head, and GQA-group ownership explicitly.

Implement attention as a checked batched/GQA TCU lowering or as a statically enumerated set of
rank-2 TCU jobs with equivalent descriptors. Do not silently flatten batch/head dimensions into M
unless the compiler proves isolation and reconstructs the exact logical layout. This compiler work
does not require an RTL/FSM change because all physical TCU jobs use already supported padded
rank-2 shapes.

## 6. Fixed compile matrix

Compile the same four shapes used by C4:

| Case | Batch | Prompt | Decode steps represented | Capacity |
| --- | ---: | ---: | ---: | ---: |
| S1 | 1 | 1 | prefill and decode | 8 |
| S2 | 1 | 7 | prefill and decode | 16 |
| S3 | 2 | 1 | prefill and decode | 8 |
| S4 | 2 | 7 | prefill and decode | 16 |

For every backend/case, compile and package:

- token embedding for prefill and decode;
- one reusable decoder layer for prefill;
- one reusable decoder layer for decode with seven cache outputs;
- final norm and LM head for prefill and decode;
- bytecode VM export/reload;
- compiled VM export/reload for at least S1, then expand if no backend-specific issue appears.

This produces 12 backend/shape package combinations. Reuse logical parameter content where hashes
match, but never reuse an incompatible physical materialization.

## 7. Milestones

### Milestone A: Alias resolver and target contracts

1. Add a reusable YAML alias resolver with clear errors for missing alias, config, manifest, or
   xclbin.
2. Load C1/C2/C3 manifests and snapshot normalized capabilities in host tests.
3. Assert exact policy/capability acceptance and rejection combinations.
4. Record alias and manifest identity in package metadata.

**Exit gate:** C1/C2/C3 resolve to the intended profiles, invalid cross-policy combinations fail
before compilation, and no ambient config or xclbin path overrides the selected alias silently.

### Milestone B: Logical archive and package generalization

1. Split canonical logical parameters from C4 physical prepacking.
2. Add C1 FP16 and C2/C3 row-major materialization caches.
3. Generalize package schema and loader while retaining backward compatibility with accepted C4
   packages.
4. Remove C4-specific naming from common runner paths without changing C4 results.

**Exit gate:** one logical archive can produce verified, profile-bound C1/C2/C3 materializations;
package reload detects any alias, fingerprint, descriptor, or tensor-hash mismatch.

### Milestone C: C3 all-naive compile

Start with C3 because the existing logical W4A16 naive lowering is closest to its contract.

1. Compile S1 prefill/decode with non-prepacked row-major W4 parameters.
2. Inspect generated source for naive GEMM and absence of TCU/IMPROVE symbols.
3. Verify linear and QK/PV logical operations all resolve; no logical `call_pure_packed` remains.
4. Package/reload S1, then expand to S2-S4.

**Exit gate:** four C3 packages compile/reload and contain only the intended naive FPINT GEMM path.

### Milestone D: C1 all-TCU compile

1. Add explicit W/K/V dequantization materialization and FP16 rounding reference.
2. Lower projection and attention roles to padded FP16 TCU jobs.
3. Verify logical slicing, causal padded-key behavior, and GQA batch/head isolation.
4. Package/reload S1, then S2-S4.

**Exit gate:** four C1 packages compile/reload, all required GEMMs use FP16 TCU jobs, and no
naive/IMPROVE W4A16 or unresolved logical GEMM remains.

### Milestone E: C2 mixed compile

1. Route nine linear projections/head operations to naive W4A16 as specified.
2. Route QK/PV roles to padded FP16 TCU jobs after K/V dequantization.
3. Prove routing by operation role and generated symbol inventory.
4. Package/reload S1, then S2-S4.

**Exit gate:** four C2 packages compile/reload with naive FPINT linear kernels and FP16 TCU
attention kernels only in their intended roles.

### Milestone F: Regression and documentation

1. Rerun C4 `alone`/`fused` compiler tests to prevent archive/policy generalization regressions.
2. Run profile, target, archive, importer, lowering, serialization, and application tests.
3. Save package manifests and compact kernel-inventory summaries for all 12 combinations.
4. Write an execution report with compile time, artifact size, physical parameter bytes, and
   backend-symbol counts.

**Exit gate:** C1/C2/C3 compile matrix and C4 regression tests pass, and the result is reproducible
without FPGA access.

## 8. Required compiler assertions

For each prefill and decode layer module, assert:

- every logical projection and attention GEMM is consumed exactly once;
- no user-exported physical backend operation appears before target selection;
- no unresolved `relax.vortex.mm_w4a16*` or backend-selection placeholder remains;
- C1 has TCU symbols and zero naive/IMPROVE GEMM symbols;
- C2 has both TCU-attention and naive-linear symbols, with role counts recorded;
- C3 has naive GEMM symbols and zero TCU/IMPROVE symbols;
- Hadamard and causal softmax each retain their accepted single-kernel lowering;
- parameter physical descriptors match the selected backend and profile;
- observable tensors retain exact logical shapes after padding/slicing;
- package export/reload preserves target requirements and kernel inventory.

## 9. Numerical policy for host references

Even though this milestone does not run the FPGA, add reference tests for backend materialization
and padding:

- reject NaN/inf before comparison;
- use absolute error for small reference magnitudes and relative error for larger values;
- compare FP16-dequantized C1/C2 operands against the stored W4/K4/V4 logical values;
- verify padded regions are exactly zero and sliced outputs exclude them;
- verify K/V cache payload, scales, zero points, capacity, and batch isolation;
- retain relative-L2 and cosine summaries in addition to pointwise checks.

Do not require C1/C2/C3 to be bit-identical to each other; they have intentionally different
dequantization and accumulation boundaries.

## 10. Failure triage order

1. alias, xclbin manifest, normalized target, and policy identity;
2. logical operation role and backend-selection decision;
3. canonical versus derived parameter descriptor/hash;
4. TCU padding/slicing or naive row-major shape contract;
5. unresolved logical operation after the lowering pipeline;
6. generated C++ symbol and target feature inspection;
7. vxbin device-compiler error;
8. serialization/reload mismatch.

Do not begin hardware or RTL debugging for a host compile failure.

## 11. Deliverables

- backend-neutral logical archive and derived-materialization schema;
- alias resolver tied to `ci/fpga_bin_alias_map.yaml`;
- explicit C1/C2/C3 compiler policies;
- padded FP16 TCU lowering for C1/C2 projection and attention roles;
- row-major naive W4A16 packaging for C2/C3;
- generalized Llama package/runner metadata and loader;
- host compiler and serialization tests;
- 12 package manifests plus compact kernel inventories;
- C1/C2/C3 compile execution report;
- unchanged C4 compiler regression evidence.

## 12. Final acceptance criteria

The task is complete only when:

1. the S2 device-poison prerequisite is accepted;
2. all 12 C1/C2/C3 S1-S4 packages compile, serialize, and reload;
3. C1/C2/C3 use the exact alias manifests and record their fingerprints;
4. backend routing matches `all_sgemm_tcu`, mixed TCU/naive, and all-naive contracts;
5. TCU padding preserves logical shape, causal masking, batch isolation, and GQA ownership;
6. logical W4/K4/V4 parameters and backend physical materializations are separately hashed;
7. no C4 IMPROVE layout leaks into C1/C2/C3;
8. no required logical GEMM remains unresolved and no required accelerator silently falls back;
9. bytecode package/reload passes for all cases and compiled-mode reload passes for representative
   coverage;
10. C4 `alone`/`fused` compiler regression tests remain green;
11. no RTL, FSM, xclbin synthesis, or FPGA execution is required by this compile-only milestone;
12. exact artifacts, tests, revisions, limitations, and next hardware milestone are documented.

## 13. Deferred work

- physical U55C execution and numerical acceptance for C1/C2/C3;
- latency, throughput, and energy comparison across C1-C4;
- cost-based automatic backend selection;
- dynamic-shape packages beyond the four static S1-S4 cases;
- monolithic 32-layer compilation;
- real Llama3-8B checkpoint conversion and language-quality evaluation;
- new RTL/FSM or FPGA image changes.

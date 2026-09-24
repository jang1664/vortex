# Vortex TVM Llama3-8B C1/C2/C3 Compile Execution Report

## Result

The current C1/C3 host-compile milestone passed on 2026-09-02. All eight S1-S4 packages compiled,
serialized, and reloaded. S1 was accepted in both bytecode and compiled VM modes for each backend;
S2-S4 were accepted in bytecode mode. C2 remains deliberately deferred until the exact mapped
binary and sibling manifest are available.

No FPGA was opened or programmed, and no RTL, FSM, or xclbin change was made. Machine-readable
evidence is in `vortex_tvm_llama3_8b_c1_c2_c3_compile_evidence.json`. Generated packages are under
`/home/jaeyongjang/project.local/tvm/build/llama3_c1_c3_compile_matrix` and are build artifacts, not
repository inputs.

## Implemented path

- Added a strict alias resolver that binds config, sibling manifest, and xclbin and fails closed on
  missing or substituted artifacts.
- Added explicit C1, C2, C3, and C4 backend policies with capability validation and role-based C2
  routing.
- Kept one profile-neutral signed asymmetric W4/K4/V4 logical archive and derived separately hashed
  C1 FP16 and C3 row-major W4 materializations.
- Added backend-neutral FP16 matmul roles for linear projections and QK/PV attention.
- Added padded FP16 TCU lowering for arbitrary M/N/K tails and statically enumerated batch/GQA jobs.
- Legalized the batched/GQA slices introduced by late naive W4 lowering before VM code generation.
- Added exact package identity, kernel inventory, artifact hashes, serialization, and reload checks.
- Retained the existing C4 `alone`/`fused` path and its physical IMPROVE layout behavior.

Two compile-only defects were found and fixed during execution. First, target normalization treated
the absence of `EXT_D_DISABLE` as D-extension support. The C1/C3 manifests explicitly select
`FPU_DSP`, and `VX_config.vh` suppresses `EXT_D_ENABLE` in that mode, so the correct compiler target
is `rv64imaf/lp64f`, not `rv64imafd/lp64d`. Second, C3's target-selected batched W4 expansion ran
after the main `LegalizeOps` pass and left `relax.strided_slice` for VM codegen; a post-selection
legalization pass now consumes it.

## Exact backend identities

| Alias | Policy | Profile fingerprint | ISA/ABI | Physical parameters |
| --- | --- | --- | --- | ---: |
| C1 | `c1_all_fp16_tcu` | `48c79e30...d957` | `rv64imaf/lp64f` | 2,537,578,496 B |
| C3 | `c3_all_w4_naive` | `5ceb94c3...e74c4` | `rv64imaf/lp64f` | 1,515,347,968 B |

The shared logical archive is 1,515,347,968 bytes with content hash
`c8fe2cd16bc469837ea8ba84667b7308f81f262a02425639e04ab6f02d997fa0`. Exact config,
manifest, xclbin, materialization, matrix, and package hashes are recorded in the JSON evidence.

## Package matrix

The tuple in the Shape column is `(batch, prompt, cache capacity)`. Compile time is the sum of the
six module pipeline/build times, plus the second six compiled-mode builds for S1.

| Alias | Case | Shape | Modes | Artifacts | Size | Compile time | Reload |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| C1 | S1 | `(1,1,8)` | bytecode + compiled | 12 | 8,182,096 B | 116.140 s | pass |
| C1 | S2 | `(1,7,16)` | bytecode | 6 | 4,486,056 B | 58.470 s | pass |
| C1 | S3 | `(2,1,8)` | bytecode | 6 | 7,806,176 B | 127.937 s | pass |
| C1 | S4 | `(2,7,16)` | bytecode | 6 | 8,261,704 B | 133.643 s | pass |
| C3 | S1 | `(1,1,8)` | bytecode + compiled | 12 | 7,369,288 B | 82.931 s | pass |
| C3 | S2 | `(1,7,16)` | bytecode | 6 | 4,026,192 B | 33.873 s | pass |
| C3 | S3 | `(2,1,8)` | bytecode | 6 | 7,238,584 B | 49.769 s | pass |
| C3 | S4 | `(2,7,16)` | bytecode | 6 | 7,594,192 B | 54.333 s | pass |

## Kernel inventory

Each C1 prefill/decode layer consumes nine logical FP16 matmuls: seven linear roles plus one QK and
one PV role. Batch-1 cases enumerate 71 physical TCU jobs (7 linear + 32 QK + 32 PV); batch-2 cases
enumerate 135 jobs. Every job uses padding where required, and the output is sliced back to the
logical shape before causal softmax or downstream use. C1 layer/head artifacts contain TCU helpers
and zero naive or IMPROVE helpers.

Each C3 prefill/decode layer lowers to 71 batch-1 or 135 batch-2 row-major naive W4 jobs. C3
layer/head artifacts contain naive helpers and zero TCU or IMPROVE helpers. Every layer artifact for
both backends has zero unresolved W4/FP16 logical calls, three accepted Hadamard kernels, and one
causal-softmax kernel. Final heads use one backend-appropriate accelerated GEMM; embeddings use
none.

The reduced-shape tests additionally prove exact tail padding/slicing and eight isolated jobs for a
`(batch=2, KV-head=2, GQA-group=2)` tensor. Role attributes prove QK/PV are selected by provenance,
not by matrix shape. C1 materialization comparison rejects non-finite values and applies absolute
error below magnitude 0.25 and relative error above it, both with a `2e-3` limit.

## C2 deferred closure

The alias currently maps to:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_d953b60098/bin
```

That directory is absent. Strict resolution therefore reports exactly:

```text
FPGA bin alias 'C2' image directory is unavailable: /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_d953b60098/bin
```

No substitute config, manifest, or xclbin was used. C2 capability validation, role routing (W4
naive linear plus FP16 TCU QK/PV), lowering, and row-major materialization pass under an explicitly
synthetic fixture. The four profile-bound C2 packages must be created only after the intended
binary and manifest are installed.

## Verification

- Vortex alias resolver: 10 passed.
- TVM policy/archive/TCU/profile/Llama routing: 58 passed, 1 hardware-only skipped.
- C4 `alone`/`fused`, C4 archive, host end-to-end, and app regressions: 38 passed, 75 hardware-only
  skipped.
- Vortex target/codegen/Relax VM/importer/IMPROVE layout/runtime: 166 passed, 7 hardware-only
  skipped.
- Eight package manifests and all 60 shared-library artifacts passed hash checks and
  `tvm.runtime.load_module` reload. (`12 + 6 + 6 + 6` per backend.)
- `git diff --check` passed in both repositories.

The C4 suite was run with the existing `py310` environment. The separate `vortex` environment's
PyTorch 2.11 installation has an internal `LeafSpec.type` incompatibility for single-Tensor
`torch.export`; this occurs before TVM import and is not a compiler regression.

## Acceptance audit

All twelve current C1/C3 criteria are satisfied: the S2 stability baseline remains unchanged; eight
packages compile/reload; exact C1/C3 profiles are bound; routing matches the workload contracts;
tail, logical shape, batch, and GQA ownership are checked; logical and physical parameter hashes
are separate; IMPROVE leakage and unresolved/fallback GEMMs are absent; bytecode and representative
compiled-mode reload pass; C4 regressions are green; no hardware/RTL work was performed; and exact
artifacts, tests, revisions, and the C2 dependency are documented.

Recorded source bases are Vortex `88ab098bf788689b8ceff08475c2de59cb516473` and TVM
`101aa65e034459df96be4cf0054ef31854dac1b7`; the implementation and this report are present in the
corresponding worktrees and should be committed together in their respective repositories.

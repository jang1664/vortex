# TVM Vortex GEMM_IMPROVE Arbitrary-Shape Extension Plan

## Goals

Extend the existing TVM `GEMM_IMPROVE` path so that every positive, compile-time-known logical
`M`, `N`, and `K` is accepted without an arbitrary backend policy cap such as 128. Acceptance is
still bounded by the selected accelerator profile: the logical and execution dimensions must be
representable by its command ABI and RTL counters, every address must fit its hardware address
width, its fixed TMEM and accumulator scratch must fit, and the aggregate peak live allocation must
fit available DRAM.

The implementation must:

- preserve the logical operation `C[M, N] = A[M, K] x dequant(W_effective[K, N])`;
- derive aligned execution/storage extents internally instead of rejecting logical tails;
- generate the hierarchical tile-major layouts required by `GEMM_IMPROVE` across any
  selected-profile-representable number of outer DMA tiles;
- crop or mask padded output elements so padding is never observable at the Relax/PyTorch API;
- support both `WTRANS=0` and on-the-fly `WTRANS=1`, and both supported quantization directions;
- retain tile-major tensors across compatible fused operators and consecutive GEMMs;
- reject only genuine hardware/profile representability, integer-overflow, scratch-capacity, or
  aggregate memory-capacity violations, with the violated field and limit in the diagnostic.

In this plan, **arbitrary shape** means any positive static logical shape. Runtime-symbolic shape
polymorphism is a follow-up: a dynamic PyTorch dimension may be handled by compiling and caching a
specialization for each concrete shape, but this plan does not require one binary to accept all
runtime values.

The initial backend milestone is a dense, compact, rank-2 matrix contract. Arbitrary batch rank,
broadcasting, non-compact PyTorch strides, and a single batched-GEMM hardware command are out of
scope. Attention and KV-cache acceptance must explicitly reshape or select dense rank-2 per-head
matrices before `mm_w4a16`; it must not silently flatten a higher-rank tensor. A later extension may
add a first-class batched contract without changing the rank-2 physical layout ABI.

This plan has two independently reviewable milestones:

- **Milestone A — arbitrary static rank-2 GEMM:** Phases 0–4 remove the current M/N/K policy caps,
  define profile/resource limits, generalize layouts, and run irregular multi-tile GEMM.
- **Milestone B — layout-preserving graph execution:** Phases 5–6 add graph-level layout
  propagation, constant prepacking, vector fusion, attention, and KV-cache acceptance.

Milestone A must be shippable and testable without waiting for the complete Milestone B operator
family.

## Source-derived current behavior

### Active native reference

The active IMPROVE regression is `tests/regression/fpint_gemm_ffn_hw/`. The older path named
`tests/regression/deprecated/fpint_gemm_ffn_hw_improve/` is retained only as historical reference.
Use the active test as the executable layout oracle.

The active implementation already demonstrates several required mechanisms:

- `M` is logically arbitrary. Each `(mt, kt)` input slot reserves `align_up(cur_m, 8)` rows while
  DMA and compute use the real `cur_m`.
- DMA tiles are runtime-programmed power-of-two values, currently `MT=NT=KT=128`.
- MXU micro-tiles are currently `MXU_KT=32` and `MXU_NT=32`.
- input, weight, scale, zero-point, and output layouts iterate over multiple outer tiles;
- each `(kt, nt_dma)` scale/zero-point slot is independently aligned to 512 bytes, and unused bytes
  are zero-initialized;
- work is partitioned across cores in 128x128 output-tile units;
- the physical tensor-memory scratch allocation is tile-sized and therefore does not grow with the
  complete matrix dimensions.

The active native test still rejects `N % MXU_NT != 0` and `K % MXU_KT != 0`. Therefore it is a
reference for outer tiling and slot alignment, but it must also be extended with padded execution
extents before it can serve as the complete arbitrary-logical-shape oracle.

### Current TVM limitation

`python/tvm/relax/backend/vortex/pipeline.py` currently accepts IMPROVE only when:

- `M <= 128` and `M % 8 == 0`;
- `N <= 128` and `N % 32 == 0`;
- `K == 128`;
- the packed INT4 axis is axis 1.

Its A/W/qparam/C layout functions encode only the initial single-DMA-tile subset. In particular,
qparam storage is aligned once as a whole instead of planning one 512-byte slot per `(kt, nt_dma)`,
and fused GEMM-C to GEMM-A reuse checks only logical shape rather than a complete physical-layout
descriptor.

## Logical and physical shape contract

### Logical tensors

The frontend contract is:

- `A`: FP16 logical matrix `[M, K]`;
- for `WTRANS=0`, the source RHS is signed INT4 `[K, N]` and the effective RHS is `[K, N]`;
- for `WTRANS=1`, the source RHS is signed INT4 `[N, K]` and the effective RHS is its on-the-fly
  transpose `[K, N]`; the source tensor itself is not materialized as `[K, N]`;
- packed RHS storage contains two signed two's-complement INT4 nibbles per `uint8`, with the first
  logical element in the low nibble, according to `pack_axis` in the source-RHS coordinate system;
- `scale`: FP16 logical quantization parameters;
- `zero_point`: INT16 logical quantization parameters;
- `C`: FP16 logical matrix `[M, N]`.

`quant_axis` and `pack_axis` are interpreted against the source RHS before `WTRANS`. The source K
axis maps to `QDIR_COL`, and the source N axis maps to `QDIR_ROW`. The logical qparam shape uses ceil
division on `quant_axis`; execution-only qparam records created for padding are backend-private.

No padding appears in the PyTorch custom-op schema, Relax tensor type, or returned tensor.

### Execution extents

Introduce one checked layout planner that derives execution extents from the selected accelerator
profile rather than embedding `8`, `32`, or `128` independently in multiple lowering functions.
For the current image the initial rules are:

```text
M_slot = align_up(M-tail-within-MT, NUM_DMA_CHANNELS)   # currently 8
N_exec = align_up(N, MXU_NT)                           # currently 32
K_exec = align_up(K, MXU_KT)                           # currently 32
```

For every outer DMA tile, define all four tail quantities explicitly:

```text
cur_m_logical
cur_n_logical, cur_n_exec = align_up(cur_n_logical, MXU_NT)
cur_k_logical, cur_k_exec = align_up(cur_k_logical, MXU_KT and the QBLK requirement)
```

Storage allocation, DMA/MXU bounds, and physical strides use the execution tails. Source copies,
reference computation, externally visible shapes, and crop predicates use the logical tails. The
ABI contract must state separately which logical or execution value is written to every MMIO
dimension, target, and start register.

Where quantization groups require a larger alignment, use the least common multiple of the MXU
micro-tile and the supported group boundary. For example, QDIR_COL may require
`K_exec = align_up(K, lcm(MXU_KT, QBLK))`. Keep existing hardware restrictions on `QBLK` until a
native characterization proves a wider contract; do not confuse a quantization-group restriction
with a logical `M/N/K` restriction.

The initial supported quantization profile is `QBLK=32`. A new QBLK value becomes supported only
after native U55C characterization freezes, for each QDIR, its power-of-two encoding, DMA_KT and
MXU_KT relationship, logical ceil-group rule, tail-group semantics, and physical qparam indexing.
The phrase "every hardware-supported QBLK" always refers to this versioned profile set; it must not
be inferred from values that merely pass a loose software predicate.

The planner must expose both logical and execution extents, outer-tile counts, tail sizes, byte
sizes, per-slot offsets, and the aggregate peak-live allocation for the compiled graph. All
products, alignments, byte conversions, and address additions must use checked 64-bit arithmetic,
followed by checked narrowing into the profiled MMIO, launch-packet, RTL tile-counter, and address
fields.

### Accelerator representability and scratch contract

The selected profile must carry and validate at least:

- MMIO dimension/start/target widths and device address width;
- `MM_MAX_LOG_DIM`, `MM_MAX_LOG_TILEDIM`, and any 32-bit tile/sync sequence limit used by the FSM;
- DMA MT/NT/KT and MXU KT/NT, including power-of-two and divisibility relationships;
- `NUM_DMA_CHANNELS`, `TMEM_BANK_SIZE`, qparam slot alignment, and HBM/interleave alignment;
- `GEMM_ACC_MEM_DEPTH` and the accumulator double-buffer capacity;
- `JOB_MMIO_NUM_ENTRIES`, the maximum simultaneous jobs, and the number of participating cores;
- the GEMM layout ABI and native helper ABI versions.

The current helper's `TMEM_BANK_SIZE * 32` capacity estimate must be removed. IMPROVE scratch is
TMEM, not per-thread LMEM, and its usable capacity is the profiled
`TMEM_BANK_SIZE * NUM_DMA_CHANNELS` after applying the interleaved address contract. The profile
validator must prove that all input/weight/qparam/output double buffers and the hardware accumulator
fit before code generation.

A DRAM-capacity check covers the aggregate peak live set, not each buffer independently. It includes
prepacked constants, tiled dynamic operands, branch-local row-major materializations, output,
runtime status/argument buffers, load-time staging that overlaps device storage, and any scratch
allocated from DRAM. If the allocator cannot provide the planned live set, execution fails with an
allocation diagnostic rather than silently selecting another backend.

### Padding values

- Pad A along K with FP16 zero. M slot padding is also zero-initialized.
- Pad packed W bytes/nibbles deterministically. K-padding contributes zero because padded A is zero.
  N-padding is cropped at row-major or externally visible boundaries, but must be neutral when the
  tiled result is preserved for a later consumer.
- Initialize all padded scale and zero-point storage to zero before writing logical qparams. A zero
  scale makes unused quantization records inert and avoids stale-data dependence.
- Compute padded N columns if required by the MXU, but never expose them outside the backend.
- Preserve real M as the compute bound when hardware supports the existing M-tail behavior; reserve
  aligned M storage slots without computing padded rows.

Zero initialization is a representation invariant, not a requirement to launch a standalone memset
before every operation. A standalone layout transform may initialize padding while it writes the
physical buffer. A fused producer or tile-aware epilogue must instead produce or preserve neutral
padding directly. If a padded region is provably never read, it may remain unspecified; if it later
becomes a reduction axis, the producer must guarantee that it is zero before the consumer runs.

## Physical IMPROVE layout contract

### A input

Layout A by `(mt, kt, kb, m, k_inner)`. Each `(mt, kt)` slot reserves
`align_up(cur_m_logical, NUM_DMA_CHANNELS) * cur_k_exec` FP16 elements, while only logical rows and
`cur_k_logical` elements are copied from the source. All remaining elements read by DMA/MXU are
zero. The planner must support multiple `mt` and `kt` values and record every slot base explicitly.

### Packed W

Layout packed W by `(kt, nt, kb, micro-tile-body)`. For `WTRANS=0`, each micro-tile is organized as
K rows by pairs of N nibbles. For `WTRANS=1`, it is organized as N rows by pairs of K nibbles so the
hardware performs RHS transpose on the fly. The transform must pad the final K/N micro-tile instead
of assuming the source extent is divisible.

### Scale and zero-point

Plan one independent slot for each `(kt, nt_dma)` pair:

- compute logical qparam counts with ceil division, then compute the physical payload size from the
  QDIR-specific execution-tail record footprint;
- reserve `align_up(actual_bytes, 512)` bytes;
- preserve the DMA-channel address invariant for every slot, not just the first slot;
- zero-fill the complete slot before copying logical FP16 scale or INT16 zero-point values.

Scale and zero-point have the same shape but separate buffers and byte accounting. They must never
be treated as packed INT4 data.

### C output

Store C by `(mt, nt, m, n_inner)` with an aligned M-row slot. Detiling reads only `m < M` and
`n < N`; padded columns and rows remain backend-private. When a compatible consumer accepts tiled
GEMM A input, pass the tiled producer directly and omit both detile and retile.

## Key design decisions

### 1. Keep logical shape separate from execution shape

The logical custom op remains stable. Padding, layout conversion, and crop are backend decisions.
Do not rewrite the logical model to padded tensor shapes and do not require users to pre-pad model
weights or activations.

### 2. Centralize layout math

Create one immutable IMPROVE layout-plan object used by:

- Relax validation and buffer type construction;
- generated A/W/qparam/C TIRx transforms;
- native helper ABI validation;
- layout-fusion compatibility checks;
- tests and module inspection metadata.

Do not duplicate offset formulas in each transform. Every offset function must be testable against
an independent host reference.

### 3. Remove numeric caps, retain intrinsic constraints

Delete `M<=128`, `N<=128`, and `K==128`. Replace divisibility failures with internal padding. Keep
only constraints that cannot be represented safely, such as zero dimensions, unsupported QBLK,
unsupported pack axis, address/size or counter overflow, incompatible accelerator profile, TMEM or
accumulator overflow, insufficient job entries, or aggregate allocation larger than available DRAM.

### 4. Version the native ABI

Bump the Vortex TVM GEMM ABI. Pass enough information to distinguish logical extents, programmed
execution extents, and layout ABI. The helper must validate the relationship before MMIO submission.
The runtime module must serialize the new ABI/profile and reject old or mismatched artifacts before
upload. The ABI also includes a host-visible status record so helper validation and per-partition
MMIO failures cannot be discarded inside the generated device kernel.

### 5. Match native multi-tile and multi-core submission

Move the active native regression's output-tile partition calculation into the versioned Vortex TVM
GEMM helper, or share a common header. A large matrix must be partitioned into non-overlapping
`M/N` regions, with each MMIO job receiving `M_START`, `N_START`, `M_TARGET`, and `N_TARGET`.
Correctness must not depend on the test image having only one core. The scheduler must respect the
profiled job-entry count, issue excess partitions in waves, and aggregate failure from every core or
partition rather than relying only on core 0.

### 6. Preserve layout only when descriptors match

Replace the current logical-shape-only fusion check with a descriptor containing dtype, logical and
execution extents, tile sizes, slot alignment, quantization direction where relevant, transpose
mode, layout ABI version, and a padding state such as `neutral` or `unspecified`. GEMM-C may feed
GEMM-A directly only when these descriptors are compatible and padding that becomes a reduction
axis is proven neutral; otherwise generate a sanitizing layout boundary or detile/retile boundary.

### 7. Make fusion responsible for preserving the padding invariant

Use the following logical Relax graph as the primary fusion example:

```text
x[M,K] -> mm_w4a16(W1[K,N]) -> ReLU -> mm_w4a16(W2[N,P]) -> y[M,P]
```

Without layout fusion, the physical flow is:

```text
x row-major
  -> A tile transform
  -> GEMM1 tiled C
  -> detile/crop to row-major [M,N]
  -> row-major ReLU
  -> A tile transform
  -> GEMM2 tiled C
  -> final detile/crop to y[M,P]
```

With layout fusion, the intended physical flow is:

```text
x row-major
  -> A tile transform
  -> GEMM1 tiled C
  -> tile-aware ReLU preserving tiled layout
  -> GEMM2 consumes the same tiled representation as A
  -> final detile/crop to y[M,P]
```

The fused flow has no intermediate CPU operation, row-major materialization, crop, full-buffer
zero-fill, or retile. W1/W2 and their qparams should be prepacked once at compile/load time when they
are constants. GEMM1's padded N columns must be neutral, normally by zero-initialized padded scales;
the tile-aware ReLU visits only logical `[M,N]` coordinates and preserves padding. GEMM2 may consume
GEMM1's physical output directly only when GEMM1-C and GEMM2-A descriptors are compatible, including
the relationship between GEMM1 `N_exec` and GEMM2 `K_exec`.

Fusion is branch-sensitive rather than all-or-nothing. If a tiled value also feeds a row-major-only
operator or is returned from the graph, insert detile/crop only on that branch. Bias, residual add,
activation, quantize, and dequantize implementations may stay fused only when they mask logical
coordinates and preserve neutral padding; otherwise they form an explicit layout boundary.

## Files to inspect and modify

### Vortex

- `tests/regression/fpint_gemm_ffn_hw/main.cpp`
- `tests/regression/fpint_gemm_ffn_hw/bench_main.cpp`
- `tests/regression/fpint_gemm_ffn_hw/kernel.cpp`
- `tests/regression/fpint_gemm_ffn_hw/common.h`
- `tests/regression/fpint_gemm_ffn_hw/test.sh.in`
- `kernel/include/vx_tvm_gemm.h`
- `hw/rtl/VX_config.vh`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/VX_job_desc_mmio_regs.sv`
- `agent-tasks/port-scale/fpint-gemm-spec.md` (update stale path and shape constraints after the
  executable contract is verified)
- `ci/fpga_bin_alias_map.yaml`

### TVM

- `python/tvm/relax/backend/vortex/pipeline.py`
- `python/tvm/relax/frontend/torch/exported_program_translator.py`
- `python/tvm/support/vortex.py`
- `src/backend/vortex/codegen/target_kind.cc`
- `src/backend/vortex/codegen/build_vortex.cc`
- `src/backend/vortex/runtime/vortex_module.cc`
- `tests/python/relax/test_torch_export_vortex_int4.py`
- `tests/python/support/test_vortex.py`
- `tests/python/target/test_target_vortex.py`
- `tests/python/runtime/test_runtime_vortex.py`
- `pytorch/spinquant/spinquant_inference/vortex_export_ops.py` in the Vortex tree, which owns the
  logical PyTorch transpose, packing, qparam, and rank contract used by `torch.export` tests

Prefer splitting the growing Python backend into focused modules such as `layout.py`, `w4a16.py`,
and `pipeline.py` instead of adding all planner and transform code to the existing single file.

## Implementation plan

### Phase 0: Characterize and freeze the active native contract

1. Add native shape cases that cross every important boundary: 1, 7/8/9, 31/32/33,
   127/128/129, and dimensions larger than one DMA tile.
2. Separate host logical M/N/K from execution N/K in the test vector and kernel arguments.
3. Pad N/K internally, retain logical reference computation, and crop output during verification.
4. Validate both WTRANS values and both supported QDIR modes.
5. Freeze `QBLK=32` as the initial contract and characterize any proposed additional QBLK separately
   for QDIR_COL and QDIR_ROW before adding it to the supported profile.
6. Record exact logical/execution-tail formulas, nibble order, qparam group indexing, every physical
   buffer, and every MMIO logical-versus-execution dimension in the FPINT GEMM spec.
7. Characterize the profiled dimension, outer-tile, sync-sequence, TMEM, accumulator, address-width,
   job-entry, and core-count limits. Confirm that a DRAM-fit but hardware-unrepresentable case is
   rejected rather than truncated.
8. Treat a native hardware failure as a contract/RTL investigation; do not hide it with a TVM-only
   workaround.

Exit criterion: irregular logical shapes pass the active native regression on the pinned IMPROVE
image, including at least one case with M, N, and K all spanning or tailing different tile levels.

### Phase 1: Add accelerator-profile tile metadata

1. Add the complete representability and scratch fields listed above: ABI/address/counter widths,
   DMA and MXU tiles, DMA channels, TMEM bank size, accumulator depth, qparam/interleave alignment,
   job entries, core count, supported QBLK set, and ABI versions.
2. Parse them from the authoritative manifest/config contract or provide versioned defaults tied to
   the image profile.
3. Validate power-of-two DMA tiles, tile-log widths, KT/MXU_KT and NT/MXU_NT divisibility, TMEM
   double-buffer placement, accumulator capacity, and job/core scheduling relationships.
4. Serialize the fields into the Vortex module and validate them against the selected xclbin before
   kernel upload.
5. Add round-trip, corruption, missing-field, checked-narrowing, and profile-mismatch tests.

Exit criterion: no IMPROVE layout transform uses an unexplained numeric tile constant.

### Phase 2: Implement the checked IMPROVE layout planner

1. Add logical/execution shapes, per-tile logical/execution tails, outer-tile counts, slot offsets,
   buffer sizes, and peak-live lifetime accounting.
2. Use checked `uint64`-equivalent arithmetic, checked profile-field narrowing, and report the exact
   overflowing or unrepresentable expression.
3. Model the source-RHS versus effective-RHS distinction for WTRANS and the QDIR-specific logical
   group and physical qparam layouts.
4. Track each tiled value's padding state and require neutral padding before it becomes a reduction
   axis.
5. Add an inspection API that exposes the plan for tests without compiling a kernel.
6. Unit-test the planner against an independent Python implementation and native fixtures.

Exit criterion: the planner produces exact byte sizes and offsets for tiny, aligned, irregular,
multi-tile, and near-overflow inputs.

### Phase 3: Generalize standalone layout transforms

1. Rewrite A tiling to handle all `(mt, kt)` slots and zero-fill padding.
2. Rewrite packed-W tiling for all `(kt, nt)` tiles, WTRANS modes, odd logical nibble tails, and
   padded micro-tiles.
3. Rewrite scale/ZP tiling for independently aligned 512-byte `(kt, nt_dma)` slots.
4. Rewrite C detiling/cropping for all `(mt, nt)` tiles.
5. Generate int64 index arithmetic in TIRx and prove all buffer accesses are within planned bounds.

Exit criterion: transform round trips and canary tests pass for the full boundary matrix without
invoking GEMM hardware.

### Phase 4: Generalize GEMM submission

1. Introduce the versioned native helper ABI and pass logical plus programmed execution dimensions,
   explicit physical strides/offsets, and the profiled resource contract.
2. Remove the initial TVM shape guard and construct buffers from the layout plan.
3. Submit multiple output partitions/jobs where required, matching the active native kernel. Limit
   concurrently participating cores to available MMIO job entries or submit jobs in explicit waves;
   aggregate every job's completion and error status.
4. Reject work whose per-job tile/sync counters cannot represent the plan. Do not split K across jobs
   unless a separately verified accumulation contract preserves the required FP32 accumulation and
   final FP16 rounding semantics.
5. Add a host-visible ABI status record. Generated device code writes the helper result and failing
   partition ID; the synchronous Vortex runtime checks it before returning from the Relax VM call.
6. Verify no scalar/dequantized fallback appears in generated source for supported irregular shapes.

Exit criterion: normal `torch.export -> Relax -> relax.build -> Relax VM` compiles and executes
irregular multi-tile W4A16 GEMMs through `GEMM_IMPROVE`.

### Phase 5: Restore and expand layout fusion

1. Add a Relax layout-propagation/region pass before `LegalizeOps`, `FuseOps`, and `FuseTIR`; the
   current late W4A16 lowerer cannot recover intervening ReLU/bias/residual graph structure after
   those passes.
2. Use the two-GEMM Relax graph above as a test-first baseline and capture its unfused transform
   sequence before changing fusion.
3. Compare physical descriptors and padding state rather than logical shapes.
4. Fuse GEMM-C to GEMM-A across arbitrary outer-tile counts when compatible.
5. Teach tile-aware quantize, dequantize, ReLU, bias, residual add, and other vector kernels to visit
   logical coordinates while preserving neutral padded storage.
6. Fold required padding initialization into the producer or tile-aware epilogue instead of adding a
   separate full-buffer zero kernel between fused stages.
7. Insert standalone transforms only at incompatible layout boundaries, row-major side branches, or
   externally visible outputs.
8. Add a concrete constant-prepacking stage before constant folding loses the logical opportunity,
   or a module-load cache that serializes prepacked W/scale/ZP with its descriptor. Immutable model
   parameters must not run layout kernels on every VM invocation.
9. Count layout transforms in the compiled module and assert that eligible attention/FFN chains do
   not detile and retile between accelerated stages.

Exit criterion: fused and unfused paths are numerically identical, and the fused path has fewer
layout kernels, no intermediate crop/zero-fill/retile, and no hidden row-major materialization
between compatible operators.

### Phase 6: Attention, KV-cache, and large-model acceptance

1. Test QK^T using rank-2 `lhs=Q`, source `rhs=K[N,K]`, and `WTRANS=1` without materializing
   `[K,N]`. Batched/head dimensions must be handled by an explicit per-head reshape/select contract.
2. Test PV with `WTRANS=0` and the applicable row-directed quantization parameters.
3. Exercise fixed-capacity INT4 KV caches at irregular sequence lengths and heads whose logical
   extents require N/K padding.
4. Run repeated bytecode and compiled Relax VM calls, feed updated caches back, export/load the
   executable, and compare both outputs and cache tuples.
5. Add at least one model-sized case whose matrices occupy multiple DRAM/DMA tiles.

Exit criterion: repeated cached decode remains correct, padded values never leak into attention,
and memory usage scales with planned physical bytes rather than an artificial compiler cap.

## Verification plan

### Host-only tests

- Logical shapes: `(1,1,1)`, `(7,31,33)`, `(9,33,31)`, `(127,129,65)`,
  `(129,257,193)`, and aligned controls such as `(128,128,128)`.
- Assert the initial API boundary: dense compact rank-2 is accepted; higher-rank, broadcasted, and
  non-compact-stride inputs are either explicitly materialized before the custom op or rejected with
  the documented diagnostic.
- Independently vary M, N, and K around 8, 32, and 128 boundaries.
- Test odd N/K logical extents and final packed-nibble handling.
- Test WTRANS=0 with source RHS `[K,N]` and WTRANS=1 with source RHS `[N,K]`; independently verify
  low/high nibble order, source-axis pack/quant mapping, and the effective `[K,N]` operand.
- Test WTRANS=0/1 and the versioned supported QDIR/QBLK matrix, initially QBLK=32 only. Values outside
  that set must fail even if they happen to pass a generic power-of-two check.
- Compare every layout offset and buffer size with an independent reference implementation.
- Fill guard regions with canaries and confirm transforms do not overwrite them.
- Check zero padding explicitly, including qparam slot slack.
- Compile `mm_w4a16 -> ReLU -> mm_w4a16` in fused and deliberately unfused forms; verify identical
  logical results and inspect the module to prove the fused form has no intermediate detile, crop,
  full-buffer zero-fill, or A-retile kernel.
- Add a branched graph where the first GEMM result feeds both a fused tiled consumer and a row-major
  consumer; verify that detile/crop is inserted only on the row-major branch.
- Poison padded storage in negative tests to prove every consumer either masks it or requires the
  neutral-padding invariant explicitly.
- Verify that padding-state metadata propagates through tile-aware operators and forces a sanitizing
  boundary before an unspecified padded region becomes a reduction axis.
- Check module serialization, export/load, ABI mismatch, and exact accelerator-profile mismatch.
- Check constant models contain prepacked physical W/scale/ZP or a one-time load cache and launch no
  repeated layout kernels for those constants on the second VM invocation.
- Negative tests: zero extent, unsupported QBLK, checked arithmetic overflow, checked narrowing,
  RTL tile/sync counter overflow, TMEM or accumulator overflow, insufficient MMIO entries,
  impossible aggregate DRAM allocation, incompatible/unsanitized fused layout, helper status error,
  and corrupt metadata.
- Freeze numerical behavior against finite inputs, signed INT4 decoding, FP16 scale storage, INT16
  zero-point, hardware FP32 accumulation, and final FP16 rounding. Use explicit tolerances where
  operation-order differences prevent bit equality; reject NaN/Inf quantization inputs according to
  the logical custom-op contract.
- Regression-test NAIVE, TCU, generic Vortex, CUDA, and generic GPU pipelines.

### Physical U55C tests

Use the exact IMPROVE image selected through `ci/fpga_bin_alias_map.yaml` and verify its manifest
CONFIGS before execution:

```text
/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin
```

Run native characterization through the configured Vortex build tree and
`build/ci/blackbox.sh`; `ci/blackbox.sh.in` is only the source template. Run TVM tests through Slurm
on physical U55C hardware with `VORTEX_DRIVER=xrt`, the exact xclbin, manifest CONFIGS, and explicit
XRT/Vortex runtime library paths. Use simx only when debugging a confirmed hardware failure.

Required physical cases:

- tiny/tail shapes below one MXU tile;
- M tail around 8 and 128;
- N and K tails around 32 and 128;
- all of M/N/K greater than 128 in one case;
- at least one practical large multi-DMA-tile case, plus host-only near-limit planner cases for
  profile representability and available DRAM;
- WTRANS=1 QK^T and WTRANS=0 PV/FFN;
- fused and standalone layout paths;
- the two-GEMM tile-aware ReLU graph, with launch/module inspection proving that fusion removed the
  intermediate detile, zero-fill, and retile work;
- a mixed-consumer branch proving crop is branch-local;
- bytecode, compiled VM, and export/load replay;
- mismatch test proving the wrong xclbin is rejected before kernel upload.

The large physical case must be large enough to exercise several outer DMA tiles but bounded enough
to finish under the hardware timeout. Near-address-width and near-DRAM-capacity arithmetic is tested
with the host planner and allocation-failure tests rather than requiring an impractically long GEMM.
The pinned IMPROVE image has one core, so it cannot by itself prove multi-core scheduling. Verify
partition/wave logic with host tests and require a separate compatible multi-core hardware image
before claiming physical multi-core acceptance; do not substitute simx for the authoritative
single-core U55C correctness run.

Every hardware command must have an outer timeout and leave no Slurm allocation or Vortex process.
Record XRT index, BDF, xclbin path/hash, manifest CONFIGS, logical/execution shapes, physical buffer
bytes, kernel launch count, cycles, instructions, and IPC.

## Build and environment settings

- Vortex source: `/home/jaeyongjang/project.local/vortex_base`
- Vortex build: `/home/jaeyongjang/project.local/vortex_base/build`
- TVM source: `/home/jaeyongjang/project.local/tvm`
- TVM build: `/home/jaeyongjang/project.local/tvm/build`
- Set `TVM_VORTEX_BUILD_DIR` explicitly to the Vortex build directory.
- Rebuild `build/kernel/libvortex.a` with the exact IMPROVE manifest CONFIGS before compiling TVM
  device binaries; do not rely on a library built for the TCU or NAIVE ABI.
- Do not generate Vortex build products in the source root.
- Use host LLVM for TVM and the Vortex LLVM toolchain only for Vortex device code.

## Completion criteria

### Milestone A — arbitrary static rank-2 GEMM

Milestone A is complete when:

1. The TVM compiler contains no `M<=128`, `N<=128`, or `K==128` IMPROVE restriction.
2. Any positive static dense rank-2 logical M/N/K that fits checked aggregate allocation and every
   selected-profile ABI/address/counter/scratch limit can be lowered using internal padding and
   multi-tile layout planning; violations are rejected before launch without narrowing.
3. The returned Relax/PyTorch tensor has exactly logical shape `[M, N]` and matches an independent
   dequantized reference.
4. Native and TVM physical U55C tests pass for irregular, multi-tile, transposed, and both supported
   quantization-direction cases using the frozen QBLK profile.
5. Generated code contains `vx_tvm_gemm_w4a16` IMPROVE submission and does not silently fall back to
   scalar GEMM/dequantization.
6. Layout descriptors, padding state, resource limits, and accelerator ABI survive module
   serialization/export/load; mismatch and device-helper failure are host-visible before returning a
   successful VM result.
7. Host regressions, formatting, `git diff --check`, out-of-tree build checks, timeout cleanup, and
   exact-image audit all pass.

### Milestone B — layout-preserving graph execution

Milestone B is complete when:

1. The pre-legalization Relax layout pass preserves compatible tiled values across the required
   vector operators and inserts branch-local boundaries for incompatible consumers.
2. Constant W/scale/ZP are prepacked at compile/load time and are not retransformed on repeated VM
   calls.
3. Fused and unfused FFN/attention paths match numerically, preserve neutral padding, and prove by
   module inspection that eligible intermediate detile/zero-fill/retile kernels were removed.
4. Rank-2 per-head QK^T, PV, KV-cache update, bytecode/compiled VM, and export/load replay pass on the
   pinned physical image; first-class batched GEMM remains a separately documented follow-up.

## Milestone B execution record

Milestone B was completed on 2026-08-28 against the pinned
`xrt_hw_u55c_c_f100_fpint_64300e5119` image.

- A pre-legalization Vortex pass now creates descriptor-checked IMPROVE layout regions before
  generic legalization and fusion. Compatible GEMM-C values remain tiled across ReLU, bias add,
  residual add, and the next GEMM. Row-major consumers retain branch-local detile boundaries.
- IMPROVE physical kernels are opaque to generic `FuseTIR`; quantize, dequantize, and KV-cache
  tuple lowering remains after generic fusion so scheduled non-root bodies are never re-fused.
- Immutable packed W, scale, and zero-point Relax constants are prepacked for all WTRANS/QDIR
  combinations. Their full logical/execution/quantization/ABI descriptor is retained in module
  metadata, and exported VM artifacts replay without runtime W/qparam layout kernels.
- Module inspection proves the fused FFN has one initial A transform and one final C detile, while
  the unfused reference has two of each. Fused and unfused FFN and attention paths match on U55C.
- Rank-2 per-head QK^T and PV, capacity-129 INT4 KV caches, repeated cache feedback, bytecode and
  compiled VM modes, export/load replay, and matrices crossing the 128-element DMA boundary pass.
- Validation passed 206 Vortex-focused host tests (72 hardware skips) and all 37 improved-image
  physical tests. First-class batched GEMM remains a follow-up; heads/batches use the explicit
  rank-2 per-head selection contract in this milestone.

# C4 Layout-Fused Vector Optimization Plan

Last updated: 2026-07-23

## Objective

Remove the vector and layout overheads that currently make the C4 fused
configuration slower than C3 despite C4's faster GEMM kernels.

This plan covers four workstreams:

1. Measure generation KV-cache quantization as a persistent single-token update.
2. Remove the two MLP detile operations by keeping SiLU and elementwise multiply tile-native.
3. Make fused Hadamard consume tiled input and avoid executing padded output rows.
4. Reduce tiled address-generation overhead in softmax and the remaining fused vector kernels.

The work is complete only when correctness passes and the reconstructed
end-to-end C4 result improves. A standalone kernel speedup is not sufficient if
it introduces another layout conversion elsewhere in the graph.

## Current Evidence

The current figures use FPGA cycles multiplied by `calls_per_forward`. Standard
and fused vector cases selected for the comparison come from the same C4 FPGA
binary, so the differences below isolate software kernel and layout behavior
rather than different FPGA bitstreams.

### End-to-end C4/C3 ratios

| Model | Stage | Shapes slower than C3 | Mean C4/C3 | Range |
| --- | --- | ---: | ---: | ---: |
| Llama2-7B | Generation | 18/18 | 2.824x | 1.503x-4.660x |
| Llama2-7B | Prefill | 6/6 | 1.464x | 1.402x-1.509x |
| Llama3-8B | Generation | 18/18 | 1.500x | 1.089x-2.200x |
| Llama3-8B | Prefill | 6/6 | 1.621x | 1.472x-1.729x |

### Representative kernel deltas

For Llama2 generation B1/S1K:

| Component | C3 | C4 | C4-C3 |
| --- | ---: | ---: | ---: |
| Two KV quantization operations | 166.3M cycles | 2,078.1M cycles | +1,911.9M |
| Three Hadamard operations | 107.9M cycles | 233.7M cycles | +125.7M |
| Two MLP detile operations | 0 | 95.8M cycles | +95.8M |
| Total | 973.8M cycles | 2,851.6M cycles | +1,877.8M |

For prefill B1/S1K:

| Model | Two MLP detiles | Total C4-C3 gap | Detile share of gap |
| --- | ---: | ---: | ---: |
| Llama2-7B | 93.1G cycles | 96.5G cycles | 96% |
| Llama3-8B | 121.0G cycles | 105.2G cycles | 115%, with other C4 savings offsetting it |

The fused pipeline is already much faster than the standalone-layout C4
pipeline. At prefill B1/S1K, fusion reduces Llama2 from 577.2G to 286.0G
cycles and Llama3 from 527.2G to 249.5G cycles. The problem is therefore not
the idea of fusion itself; it is the remaining unfused layout seams and
inefficient small-shape fused paths.

## Design Principles

- Preserve a selectable baseline for every device-kernel change.
- Do not change mathematical semantics while optimizing layout.
- Keep benchmark-only modeling fixes separate from production runtime changes.
- Exclude allocation, cache initialization, and one-time packing from the
  measured latency window.
- Use the same FPGA binary, input values, iteration count, and correctness
  tolerance for baseline/candidate comparisons.
- Record the effective kernel variant in logs and result metadata.
- Regenerate workload suites after changing application arguments. Do not allow
  `--skip-existing` to select rows produced by the old argument contract.
- Evaluate both raw per-call cycles and weighted end-to-end contribution.

## Workstream 1: Persistent Generation KV-Cache Quantization

### Problem

Generation workload metadata describes an append into a fixed-capacity
persistent KV cache, but `kv_cache_quant_layout_fused_w4a16/bench_main.cpp`
does not accept or upload cache capacity and cache position. The measured
kernel therefore uses the non-persistent full-layout path.

For a generation input with logical `K=1, N=128`, the non-persistent path pads
the output K dimension to the GEMM tile minimum of 32. It processes roughly
2 KiB of packed-layout storage instead of the logical 64-byte update and
executes quantization loops for padded rows. The measured per-call latency is
about 12x the C3 row-major quantizer, and the result is then multiplied by
layer and head call counts.

### Target behavior

Measure exactly one token update into an already allocated tiled cache:

- The cache is allocated for `cache_capacity`.
- The update is written at `cache_position`.
- Only the new token and its qparams are computed.
- Existing cache entries remain unchanged.
- Key and value paths preserve their required transposed/non-transposed tiled layouts.
- Prefill continues to use the full-cache construction path.

### Planned changes

1. Extend the benchmark CLI with an explicit mode and cache parameters:

   ```text
   --cache-update full|append
   --cache-capacity N
   --cache-position N
   ```

2. Refactor the persistent setup currently exercised by
   `kv_cache_quant_layout_fused_w4a16/main.cpp` into shared host helpers so the
   correctness binary and benchmark cannot drift.
3. In append mode:

   - Allocate packed weights and qparams using `cache_capacity`.
   - Initialize the cache before the latency window.
   - Set `persistent_mode`, `cache_capacity`, and `cache_position`.
   - Launch work only for the logical one-token update.
   - Keep repeated power iterations idempotent by updating the same slot.

4. Update the generation workload arguments in
   `tools/workload/gen_kernel_cfgs.py`. The existing shape metadata already
   contains `cache_capacity`, `cache_position`, and `cache_update`; the CLI
   arguments must carry the same values.
5. Leave prefill arguments unchanged and add workload tests that distinguish
   `full` from `append`.
6. Ensure the changed arguments produce new execution keys so old
   non-persistent measurements cannot be reused.

### Primary files

- `tests/regression/kv_cache_quant_layout_fused_w4a16/bench_main.cpp`
- `tests/regression/kv_cache_quant_layout_fused_w4a16/main.cpp`
- `tests/regression/kv_cache_quant_layout_fused_w4a16/host_common.h`
- `tests/regression/kv_cache_quant_layout_fused_w4a16/common.h`
- `tests/regression/kv_cache_quant_layout_fused_w4a16/kernel.cpp`
- `tools/workload/gen_kernel_cfgs.py`
- `tools/workload/test_kernel_variants.py`
- `tools/latency_bench/test_workload_variants.py`

### Correctness checks

- Key cache append with `SOURCE_TRANSPOSED=1`, `WTRANS=1`.
- Value cache append with `SOURCE_TRANSPOSED=0`, `WTRANS=0`.
- Llama2 and Llama3 head counts.
- Positions at 0, an interior tile boundary, and `capacity - 1`.
- Capacities equal to and larger than the logical cache length.
- Sentinel validation proving that all cache slots except the update position
  remain unchanged.
- Scale/zero validation for asymmetric key and symmetric value quantization.
- Repeated power-kernel execution at the same position.

### Performance checks and acceptance criteria

- Compare the current full-layout measurement and the new append measurement
  using the same C4 FPGA binary.
- Confirm that device work no longer scales with the 32-row tile padding for
  `K=1`.
- Provisional per-call target: append latency no more than 2x the C3
  quantizer at B1.
- Required end-to-end target: reduce the generation quantization contribution
  by at least 80% for both models.
- No prefill latency regression above 2%.

### Risks

- Packed weight and qparam offsets differ for key and value caches.
- The benchmark must not accidentally include cache initialization.
- Updating one slot repeatedly is suitable for latency/power measurement only
  if the kernel is deterministic and idempotent at that slot.
- A benchmark-only append path must remain consistent with the executable
  runtime cache contract.

## Workstream 2: Remove the MLP Detile Operations

### Problem

The C4 fused graph currently performs:

```text
gate_proj (GEMM-C tiled) -> detile -> SiLU row-major
up_proj   (GEMM-C tiled) -> detile -> elementwise multiply row-major
```

The two full-tensor detile copies dominate prefill regression. The repository
already has promoted tile-native kernels:

- `silu_layout_fused` with the `linear_tiled` variant.
- `elmul_layout_fused` with the `linear_same_layout` variant.

The missing link is R4 Hadamard: the current fused Hadamard reads row-major
input, while tile-native elmul produces the GEMM-A tiled input expected by the
down projection.

### Target graph

```text
gate_proj (GEMM-C tiled)
  -> silu_layout_fused (GEMM-C tiled)
                                     \
up_proj (GEMM-C tiled) ----------------> elmul_layout_fused (GEMM-A tiled)
                                          -> hadamard_layout_fused (GEMM-A tiled)
                                          -> down_proj
```

No intermediate row-major MLP activation is materialized.

### Dependency

Workstream 3 must first add tiled-input support to
`hadamard_layout_fused`. The workload graph must not switch to the tile-native
MLP chain until that input contract passes correctness tests.

### Planned changes

1. Reuse the existing promoted SiLU and elmul applications; do not create new
   duplicate kernels.
2. Update the C4 fused workload graph in `tools/workload/gen_kernel_cfgs.py`:

   - Replace `layout_gate_proj_to_mlp_silu_detile` plus plain `silu` with
     `silu_layout_fused`.
   - Remove `layout_up_proj_to_mlp_elmul_detile`.
   - Replace plain `elmul` with `elmul_layout_fused`.
   - Mark the elmul output as `gemm_a_tiled`.
   - Pass `--layout-from gemm_a_tiled` to R4 Hadamard.

3. Preserve the current graph behind an opt-in workload variant until the new
   graph is correct and measured.
4. Update producer/consumer and layout metadata so the model-structure dump
   verifies a continuous tiled path.
5. Add generator assertions that no `detile_output` case appears between
   gate/up projection and R4 Hadamard in the candidate graph.
6. Keep standalone C4 and non-SpinQuant variants unchanged.

### Primary files

- `tools/workload/gen_kernel_cfgs.py`
- `tools/workload/test_kernel_variants.py`
- `tools/latency_bench/test_workload_variants.py`
- `tests/regression/silu_layout_fused/`
- `tests/regression/elmul_layout_fused/`
- `tests/regression/hadamard_layout_fused/`
- `pytorch/spinquant/spinquant_inference/layer_accuracy/generator_conformance.py`

### Correctness checks

- Compare the tile-native chain against the current row-major chain after each
  semantic operation: SiLU, multiply, Hadamard, and down projection.
- Test Llama2 intermediate size 11008 and Llama3 intermediate size 14336.
- Test generation rows 1, 2, and 4 and prefill rows spanning multiple M tiles.
- Test partial M tiles and exact M-tile boundaries.
- Verify that padded rows cannot affect any real down-projection row.
- Run generator conformance for standalone and fused plans.

### Performance checks and acceptance criteria

- Required structural gate: both MLP detile cases are absent from generated C4
  fused suites.
- Required traffic gate: no full row-major gate/up intermediate is allocated
  by the candidate path.
- Required latency gate: the combined
  `silu_layout_fused + elmul_layout_fused + hadamard_layout_fused` latency is
  lower than the old
  `2*detile + silu + elmul + hadamard_layout_fused` latency for every target
  shape.
- Prefill target: remove at least 90% of the current `layout` contribution.
- Generation target: no regression above 5% after the Hadamard changes are
  included.

### Risks

- GEMM-C and GEMM-A have identical physical order only under the configured
  tile dimensions used by `linear_same_layout`; retain a generic fallback or
  validate the equality explicitly.
- Skipping initialization of padded rows is safe only if downstream GEMM does
  not mix padded M rows into real M rows.
- The graph change couples three applications, so per-operation reference
  checks are necessary to locate any mismatch.

## Workstream 3: Tile-Native, Real-Row-Only Fused Hadamard

### Problem

The current launch uses `grid_dim = matrix_count * m_pad`. When the logical
row count is 1 and `m_pad` is 8, seven blocks execute only to zero-write a full
Hadamard output row. This is especially expensive for R4 dimensions 11008 and
14336.

The current kernel also assumes row-major input. That prevents the tile-native
MLP chain in Workstream 2.

### Target behavior

- Launch exactly `matrix_count * rows` blocks.
- Use `m_pad` only in tiled output address calculation.
- Never execute Hadamard math or output stores for padded rows.
- Accept both `row_major_fp16` and `gemm_a_tiled` input.
- Preserve both Hadamard algorithms:

  - Default zero-padding fast butterfly.
  - Exact factorized butterfly followed by base transform.

### Planned changes

1. Introduce a selectable Hadamard fused variant:

   ```text
   HADAMARD_LAYOUT_FUSED_VARIANT=baseline|real_rows_tiled_input
   ```

2. Extend the kernel arguments with an input-layout enum.
3. Change block mapping from physical padded rows to logical rows:

   ```text
   matrix_idx = blockIdx.x / rows
   row        = blockIdx.x % rows
   grid_dim   = matrix_count * rows
   ```

4. Remove the padded-row zero-write branch from the candidate kernel.
5. Implement tiled input loading:

   - Compute the row/tile prefix once per block.
   - Traverse contiguous 32-element microtiles.
   - Avoid calling a generic element-offset helper for every value.

6. Retain row-major loading for R3 and compatibility experiments.
7. Keep tiled output, but similarly hoist output row/tile prefixes and process
   columns in microtile chunks.
8. Zero-initialize output buffers outside the measured window only in tests
   that require deterministic padded storage. Do not charge that initialization
   to the Hadamard kernel.
9. Extend benchmark CLI with `--layout-from row_major_fp16|gemm_a_tiled`.

### Primary files

- `tests/regression/hadamard_layout_fused/Makefile`
- `tests/regression/hadamard_layout_fused/common.h`
- `tests/regression/hadamard_layout_fused/kernel.cpp`
- `tests/regression/hadamard_layout_fused/bench_main.cpp`
- `tests/regression/hadamard_layout_fused/main.cpp`
- `tests/regression/layout_fused_common/layout_fused_layouts.h`
- `tools/workload/gen_kernel_cfgs.py`

### Correctness checks

- Rows 1, 2, 4, 7, 8, and 9.
- Multiple matrices and Llama3 grouped-query attention matrix grouping.
- Dimensions 128, 11008, and 14336.
- A small mixed-radix test dimension for the factorized path.
- Row-major and tiled inputs generated from the same logical values.
- Zero-padding and factorized algorithms.
- Sentinel checks on real output rows and padded output slots.
- Down-projection integration proving padded rows are irrelevant.

### Performance checks and acceptance criteria

- Device instruction count must scale with `rows`, not `m_pad`.
- Generation R4 target at B1: C4/C3 Hadamard ratio no more than 1.25x.
- Generation R3 target: no regression relative to the current fused kernel.
- Prefill target: no regression above 5%.
- Workstream 2 integration must be faster than converting tiled elmul output
  back to row-major.

### Risks

- Some tests may currently assume padded output rows are explicitly zero.
- A generic tiled offset helper inside the load loop could erase the benefit of
  removing detile.
- Local-memory occupancy must be rechecked for the 16384-element zero-padded
  scratch used by Llama2/Llama3 R4.

## Workstream 4: Remaining Fused Address-Generation Overhead

### Problem

After the first three workstreams, the main residual overheads are:

- `softmax_layout_fused`, currently about 1.3x C3 softmax.
- Fused RMSNorm, rope, and eladd, often 1.7x-2.3x their row-major counterparts
  but with smaller total contribution.

The common pattern is repeated flattened-index decode and tiled offset
calculation inside element loops. Some applications already have promoted
optimized variants, so the first task is to verify that the latency flow is
actually selecting those variants before creating new implementations.

### Planned changes

#### 4A. Freeze and verify effective variants

1. Print the selected variant in every affected benchmark log.
2. Record it in raw result metadata.
3. Verify the current latency flow selects:

   - `silu_layout_fused=linear_tiled`
   - `elmul_layout_fused=linear_same_layout`
   - `rope_layout_fused=task_chunk16`
   - `eladd_layout_fused=tile_chunk32`
   - `rms_norm_layout_fused=shuffle_warp`
   - the intended `softmax_layout_fused` variant

4. Remeasure any case whose effective variant cannot be proven.

#### 4B. Optimize softmax tiled access

1. Benchmark the existing `rev2`, `rev2_addrgen`, and `opt_warp` paths on the
   current C4 binary before adding another variant.
2. If external address generation is supported and correct, compare
   `rev2_addrgen` against the portable baseline.
3. Otherwise add a portable chunked accessor:

   - Own one contiguous 32-element tile segment per inner-loop chunk.
   - Compute input and output segment bases once.
   - Increment pointers within the segment.
   - Preserve the cached SIMT reduction and mask behavior.

4. Avoid a per-element multiply for `input_group_stride` and
   `output_group_stride`.
5. Preserve a generic tail for sequence lengths not divisible by the microtile
   width.

#### 4C. Optimize remaining kernels by weighted impact

1. Rebuild the end-to-end breakdown after 4B.
2. Rank remaining operations by weighted cycle delta, not standalone ratio.
3. For each selected kernel, use the established chunking pattern:

   - Decode matrix, row, and microtile once.
   - Process aligned FP16 pairs or RV64 packed groups.
   - Use shifts/masks for power-of-two tile sizes.
   - Keep scalar tails for partial tiles.

4. Stop when the residual vector work is below the GEMM savings margin; do not
   optimize low-contribution kernels solely because their ratio looks large.

### Primary files

- `tests/regression/softmax_layout_fused/Makefile`
- `tests/regression/softmax_layout_fused/kernel.rev2.cpp`
- `tests/regression/softmax_layout_fused/kernel.rev2_addrgen.cpp`
- `tests/regression/softmax_layout_fused/kernel.opt.cpp`
- `tests/regression/softmax_layout_fused/bench_main.cpp`
- `tests/regression/rope_layout_fused/`
- `tests/regression/eladd_layout_fused/`
- `tests/regression/rms_norm_layout_fused/`
- `analysis_workspace/latency_on_hw/docs/vector_kernel_optimization.md`

### Correctness checks

- Softmax decode and masked prefill.
- Sequence lengths below, equal to, and above a 32-element tile.
- Non-multiple-of-32 sequence length and fixed capacity stride larger than the
  logical sequence length.
- Multiple attention matrices and Llama3 grouped-query attention.
- Existing edge cases for rope, eladd, and RMSNorm.
- Baseline/candidate comparison with identical random inputs.

### Performance checks and acceptance criteria

- Softmax target: C4/C3 per-call ratio no more than 1.10x on representative
  decode and prefill shapes.
- No candidate may regress its primary shape by more than 2%.
- End-to-end target: reduce the residual non-GEMM, non-quantization,
  non-Hadamard vector delta by at least 50%.
- Do not promote an external-address-generator path unless the required FPGA
  configuration is available in every target C4 experiment.

### Risks

- Existing variant names and actual host launch geometry have diverged before;
  log verification is mandatory.
- External address generation may bind the kernel to a subset of FPGA builds.
- Larger chunks can reduce parallelism for small decode shapes.
- Packed accesses require alignment and tail handling.

## Implementation Order

The workstream numbers describe the four optimization goals. The recommended
execution order accounts for dependencies:

1. Freeze the current per-kernel and end-to-end baseline.
2. Implement Workstream 1, because it is independent and fixes the largest
   generation measurement error.
3. Implement the tiled-input portion of Workstream 3.
4. Implement Workstream 2 and switch the MLP graph to the existing tile-native
   SiLU/elmul kernels.
5. Finish the real-row-only and chunked-output portions of Workstream 3.
6. Rebuild the breakdown and execute Workstream 4 in weighted-impact order.
7. Promote defaults only after all target shapes pass together.

Each workstream should be committed separately so a regression can be bisected
and each result can be attributed to one change.

## Verification Matrix

### Python and workload generation

- `tools.workload.test_kernel_variants`
- `tools.latency_bench.test_workload_variants`
- `tools.latency_bench.test_generate_suites`
- SpinQuant generator conformance
- Model-structure layout-chain inspection for both models and stages

### Device correctness

- Build from a configured build directory after sourcing the matching config.
- Run each application correctness test in SimX.
- Run focused hardware blackbox correctness for changed application contracts.
- Test both normal latency execution and repeated power-kernel execution.

### Hardware latency

Use the same C4 FPGA binary for baseline and candidate. Collect:

- FPGA cycles
- Instructions and IPC
- Per-call cycles
- `calls_per_forward`
- Weighted cycles
- Effective kernel variant
- Source commit and xclbin hash

Measure at minimum:

| Stage | Model | Batch | Sequence/cache lengths |
| --- | --- | ---: | --- |
| Generation | Llama2 and Llama3 | 1, 2, 4 | 1024, 8192, 32768 |
| Prefill | Llama2 and Llama3 | 1 | 1024, 8192, 32768 |

After changing an application contract, regenerate suites and remove only the
affected applications from the active raw DB or use a new output directory.

## Promotion Gates

All of the following are required:

1. No functional mismatch in application and composed-chain tests.
2. No missing or estimated rows in the target end-to-end comparison.
3. No stale raw result selected through an old execution key.
4. C4 is no slower than C3 on every required prefill and generation shape, or
   every remaining regression has a documented kernel-level explanation and
   approved exception.
5. C4 remains faster than C4 standalone-layout.
6. Power measurement remains stable and power-kernel repetition preserves
   semantics.
7. Baseline variants remain selectable after promotion.

## Expected Outcome

Based on the current breakdown:

- Fixing persistent generation quantization should remove most of the
  generation gap.
- Removing the two MLP detiles should remove most of the prefill gap.
- Real-row-only Hadamard should address the remaining small-batch generation
  penalty.
- Address-generation work should provide the final margin needed for C4 to
  stay below C3 across all measured shapes.

The projected result should be validated from newly generated suites and fresh
raw measurements rather than calculated by subtracting old component values.

## Implementation Status (2026-07-23)

| Workstream | Implemented result | Local verification |
| --- | --- | --- |
| Persistent generation KV quant | Generation-only fused K/V quant cases now pass `append`, fixed capacity, and cache position to the benchmark. The benchmark allocates persistent cache geometry and updates one token. | K and V persistent correctness pass. Representative SimX cycles: full K update 643,267; append K 290,625; append V 286,725. |
| Tile-native MLP chain | C4 SpinQuant keeps gate/up in GEMM-C layout, uses fused SiLU and elmul, and sends GEMM-A output directly to R4 Hadamard. Both MLP detile cases are removed. | Workload graph unit tests pass and explicitly reject both detile case names. |
| Hadamard input and launch | Fused Hadamard accepts row/head-major or GEMM-A tiled input. Real-row launch is the default; `--launch-rows padded` preserves the comparison baseline. | Row and tiled inputs both produce zero errors. At M=1, K=128, tiled input takes 43,067 cycles with real-row launch versus 59,708 with padded-row launch. Llama2 R4 M=1, K=11008 runs in 3,324,131 cycles. |
| Remaining softmax address work | Added selectable `rev2_chunked`, which replaces per-element tiled offset multiplication with lane-local element-offset cursors when the warp and microtile widths match. The default remains `rev2`. | Decode and masked prefill correctness pass. The candidate is not promoted because it regresses SimX cycles by 5.4% and 4.6%, respectively. |

Fresh FPGA end-to-end latency and power measurements remain required before
promoting the graph and benchmark changes into the active raw result set.

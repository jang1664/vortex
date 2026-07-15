# Vector Kernel Optimization Tracker

Last updated: 2026-07-12

## Purpose

This is the living design and experiment log for optimizing regression vector kernels that provide a `bench_main.cpp` harness.

Update this file while implementing each optimization. Preserve the original implementation as a selectable variant, record the exact benchmark shape and FPGA binary, and do not promote a new default until correctness and latency comparisons are complete.

## Scope

Included:

- Active vector, elementwise, reduction, layout, quantization, and reference TCU applications under `tests/regression/` with a `bench_main.cpp` harness.
- Kernel source, launch geometry, local-memory use, and variant selection.
- Unit/regression correctness and latency-on-hardware comparisons.

Excluded:

- `tests/regression/fpint_gemm_ffn_hw/`
- `tests/regression/fpint_gemm_ffn_hw_naive/`
- `tests/regression/deprecated/`
- RTL GEMM optimization work

The current inventory contains 30 applications: 5 use local memory and 25 do not. `sgemm_tcu` is included as the reference software-managed TCU path even though it is not an elementwise vector kernel.

## Status Legend

| Status | Meaning |
| --- | --- |
| `proposed` | Static review found an optimization candidate. |
| `implementing` | A new variant is being developed. |
| `correct` | Functional tests match the baseline. |
| `measured` | Hardware latency has been collected for baseline and candidate. |
| `promoted` | The candidate is the selected default. |
| `rejected` | The candidate was incorrect or did not improve the target metric. |

## Variant Policy

Every optimization must preserve a comparable baseline. Follow the existing softmax-style build selection, with stricter naming and consistency rules.

### File naming

Use explicit source files instead of changing one implementation in place:

- `kernel.baseline.cpp`: preserved reference implementation.
- `kernel.<variant>.cpp`: candidate implementation, such as `kernel.lmem.cpp`, `kernel.shuffle.cpp`, or `kernel.groupwise.cpp`.
- `bench_main.cpp`: shared benchmark harness when arguments and validation are identical.
- `bench_main_<variant>.cpp`: only when a variant requires a materially different host contract.

Do not use `kernel.cpp` symlinks together with a Makefile variant selector. The softmax directory currently demonstrates why the two sources of truth are confusing: `kernel.cpp` points to an optimized file while the Makefile default selects `kernel.rev1.cpp` directly.

### Makefile selection

Each application should define one singular selector and validate it against a plural list. The conceptual pattern is:

```make
APP_VARIANT ?= baseline
APP_VARIANTS := baseline candidate

ifneq ($(filter $(APP_VARIANT),$(APP_VARIANTS)),$(APP_VARIANT))
  $(error Unsupported APP_VARIANT=$(APP_VARIANT); expected one of: $(APP_VARIANTS))
endif

VX_SRCS := $(SRC_DIR)/kernel.$(APP_VARIANT).cpp
```

Use an application-specific prefix such as `ELREDUCE_VARIANT` or `KV_CACHE_QUANT_VARIANT`; do not introduce a generic global `KERNEL_VARIANT` shared by unrelated applications.

### Host and device macro consistency

When host launch geometry depends on the variant:

- Define the same singular selector semantics for host and device compilation.
- Use distinct host/device macro names only when required by the build system, and derive both from the same Make variable.
- Define numeric constants in `common.h`.
- Print the selected variant in `main.cpp` and `bench_main.cpp` output.
- Upload variant-specific launch parameters explicitly; do not infer the device variant from a symlink.

Avoid singular/plural macro drift. The current `softmax_layout_fused` host code checks `SOFTMAX_LAYOUT_FUSED_VARIANTS` while the Makefile defines `SOFTMAX_LAYOUT_FUSED_VARIANT`. Because an undefined preprocessor identifier evaluates to zero and the rev1 constant is zero, the rev1 launch branch is selected even for the optimized build.

Affected locations:

- `tests/regression/softmax_layout_fused/bench_main.cpp`
- `tests/regression/softmax_layout_fused/main.cpp`
- `tests/regression/softmax_layout_fused/Makefile`

### Baseline and promotion rules

1. The first variant conversion must preserve the currently selected implementation byte-for-byte as `baseline` or its existing stable name such as `rev1`.
2. A new candidate starts as an opt-in variant.
3. Baseline and candidate must use identical inputs, correctness tolerances, warmup count, measured iterations, and FPGA binary.
4. Record both cycle/latency and LMEM footprint. A faster kernel that reduces usable occupancy must be evaluated at representative shapes.
5. Promote a variant only after functional checks and the required hardware shapes pass.
6. Keep at least one stable baseline selectable after promotion.

### Latency flow selection

Variant selection used for latency experiments must be explicit in the run environment or suite-generation flow. The current latency script selects:

- `SOFTMAX_VARIANT=opt_align`
- `SOFTMAX_LAYOUT_FUSED_VARIANT=opt`

See `analysis_workspace/latency_on_hw/_run.sh`.

The effective variant must be included in the result log so results remain reproducible after defaults change.

## Local-Memory Classification

### Kernels using local memory

| Application | Default or latency-flow implementation | LMEM footprint | Purpose | Current assessment |
| --- | --- | ---: | --- | --- |
| `hadamard` | `tests/regression/hadamard/kernel.cpp` | `padded_dim * sizeof(float)` | Stage a complete row for repeated butterfly passes. | Appropriate and close to algorithmically necessary. Retain LMEM; investigate occupancy and large-dimension fallback. |
| `rmsnorm` | `tests/regression/rmsnorm/kernel.cpp` | `blockDim.x * sizeof(float)` | Block-wide sum-of-squares reduction. | Appropriate footprint. Shuffle reduction, redundant-barrier removal, and single-thread normalization-factor calculation are candidates. |
| `rms_norm_layout_fused` | default: `kernel.shuffle_warp.cpp`; baseline: `kernel.baseline.cpp` | default: 0; baseline: `blockDim.x * sizeof(float)` | Warp shuffle reduction before fused tile-layout output. | The promoted path removes LMEM and block barriers and computes the normalization factor once per warp. |
| `softmax` | Makefile default: `kernel.rev1.cpp`; latency flow: `kernel.opt_align.cpp` | Rev1: `blockDim.x * sizeof(float)`; opt-align: row I/O caches plus FP32 input/exp caches | Reduction only in rev1; row staging, cached exponentials, and DMA in opt-align. | The latency variant is highly optimized but uses blocking DMA without compute overlap. |
| `softmax_layout_fused` | Makefile default: `kernel.rev1.cpp`; latency flow: `kernel.opt.cpp` | Rev1: `blockDim.x * sizeof(float)`; opt: cached row plus reduction, with a bounded fallback | Reduction and optional tiled DMA staging. | The optimized variant has the most explicit LMEM cap/fallback design. Fix host variant selection before trusting occupancy comparisons. |

### Kernels not using local memory

LMEM is not automatically beneficial for these kernels. Most consume each input once, so staging would add copies and barriers without adding reuse.

| Application | Static optimization level | LMEM decision | Main remaining opportunity |
| --- | --- | --- | --- |
| `detile_output` | Medium | Correct to avoid LMEM. | Pack adjacent FP16 copies into wider transactions. |
| `dropout` | Medium-low | Correct to avoid LMEM. | Replace one-thread blocks with capped grid-stride launch; evaluate RNG cost/divergence. |
| `eladd` | Medium | Correct to avoid LMEM. | Reduce software FP16 conversion overhead. |
| `eladd_layout_fused` | Medium-high | Correct to avoid LMEM. | Use tile-native traversal to reduce per-element division and 64-bit address arithmetic. |
| `eldiv` | High | Correct to avoid LMEM. | Reciprocal approximation only if relaxed precision is acceptable. |
| `elmul` | Medium | Correct to avoid LMEM. | Reduce software FP16 conversion overhead. |
| `elmul_layout_fused` | Medium-low | Correct to avoid LMEM. | Compute shared tiled offsets once and use tile-native traversal. |
| `elreduce` | Low | Current lack of cooperative storage is a performance problem. | One row per block, register partial sums, and shuffle/LMEM reduction. |
| `elscalar` | Medium-high | Correct to avoid LMEM. | Extend uniform fast paths where accuracy permits. |
| `elsub` | High | Correct to avoid LMEM. | Already a bandwidth-oriented streaming loop. |
| `elunary` | Medium-high | Correct to avoid LMEM. | Native/approximate reciprocal-square-root path where supported. |
| `head_concat` | Medium | Correct to avoid LMEM. | Remove repeated runtime division/modulo from index decode. |
| `head_concat_layout_fused` | Medium-high | Correct to avoid LMEM. | Preserve fusion and simplify tile-address decode. |
| `kv_cache_dequant_w4a16` | Medium-high | Correct to avoid LMEM. | Pack input/output operations and reduce qparam index arithmetic. |
| `kv_cache_quant_w4a16` | Low | Group-level register or LMEM reuse is warranted. | Compute scale/zero once per quantization group instead of once per output pair. |
| `kv_cache_quant_layout_fused_w4a16` | Mixed | Fast special paths do not need LMEM; fallback may benefit after restructuring. | Extend group-wise parameter reuse to fallback paths and avoid a second group scan for qparam output. |
| `rope` | Medium-low | LMEM is optional and shape-dependent. | Remove pair-level division/modulo; consider staging reused sin/cos rows. |
| `rope_layout_fused` | Medium-low | LMEM is optional and shape-dependent. | Specialize output layout outside the hot loop and stage reused sin/cos rows. |
| `sgemm_tcu` | High | Baseline correctly avoids LMEM. A measured 2x2-warp LMEM supertile with all-thread interleaved staging was functionally correct but at least 2.95x slower because staging and two barriers per K tile outweighed A/B reuse. | Use col-major prepacked B (`b_colmajor`); retain LMEM variants only as experimental references. |
| `silu` | Medium-low | LMEM would not add data reuse. | Make adjacent lanes process adjacent elements while retaining chunk-level address amortization. |
| `silu_layout_fused` | Medium | LMEM would not add data reuse. | Preserve fusion and make the 32-element traversal lane-coalesced. |
| `tile_input_a` | High | Correct to avoid LMEM. | Already uses paired FP16 32-bit copies; measure wider packing only if alignment permits. |
| `tile_scale_zp_w4a16` | Medium-high | Correct to avoid LMEM. | Reduce division/modulo on partial tiles. |
| `tile_weight_w4a16` | High | Correct to avoid LMEM. | Preserve the aligned 16-byte fast path; optimize only boundary handling if material. |
| `vecadd` | Medium | Correct to avoid LMEM. | Adopt capped grid-stride launch used by newer kernels. |

## Optimization Backlog

Update the status, chosen variant name, and result link in this table as work proceeds.

| ID | Priority | Application | Baseline | Candidate variant | Planned change | Status | Result |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| VK-01 | 0 | `softmax_layout_fused` | `rev1`, `opt` | `opt_warp` | Fix singular/plural variant macro selection and verify intended block size. | `promoted` | 26.1% decode and 35.5% prefill cycle reduction. |
| VK-02 | 1 | `elreduce` | `baseline` | `lmem_reduce` | Parallel row reduction using register partials and shuffle/LMEM final reduction. | `proposed` | - |
| VK-03 | 1 | `kv_cache_quant_w4a16` | `baseline` | `groupwise` | Assign work per quant group; compute scale/zero once and quantize the group with shared parameters. | `promoted` | 96.9% cycle reduction; QDIR0/QDIR1 partial groups pass. |
| VK-04 | 2 | `rmsnorm` | `baseline` | `shuffle` | Replace most LMEM tree stages with shuffle reduction; compute and broadcast the normalization factor once. | `proposed` | - |
| VK-05 | 2 | `rms_norm_layout_fused` | `baseline` | `shuffle_warp` | Apply the same reduction strategy while preserving fused tile output. | `promoted` | 11.7% cycle reduction; plain and fused correctness pass. |
| VK-06 | 2 | `softmax` | `rev1`, `opt_align` | `dma_serial` | Preserve four-warp row compute while serializing unsafe concurrent DMA descriptor MMIO. | `promoted` | 24.3% decode and 20.8% prefill cycle reduction. |
| VK-07 | 2 | `softmax_layout_fused` | `opt` | `dma_overlap` | Overlap cached tiled DMA and compute while retaining LMEM cap/fallback behavior. | `proposed` | - |
| VK-08 | 3 | `silu` | `v2` | `lane_coalesced` | Distribute each 32-element chunk across adjacent lanes. | `proposed` | - |
| VK-09 | 3 | `silu_layout_fused` | `baseline` | `linear_tiled` | Process the layout-preserving GEMM-C slot linearly. | `promoted` | 12.8% primary-shape cycle reduction; padded-row edge passes. |
| VK-10 | 3 | `rope` | `baseline` | `task_inner_pair` | Make `(batch, sequence, head)` the task and traverse pairs incrementally; optionally stage sin/cos. | `proposed` | - |
| VK-11 | 3 | `rope_layout_fused` | `baseline` | `task_chunk16` | Hoist layout dispatch and flattened decode across 16 rotary pairs. | `promoted` | 39.3% generation and 45.7% prefill reduction; full GEMM-W shape passes. |
| VK-12 | 3 | `elmul_layout_fused` | `baseline` | `linear_same_layout` | Reuse the identical GEMM-C/GEMM-A physical slot order. | `promoted` | 56.0% primary-shape cycle reduction; padded-row edge passes. |
| VK-13 | 4 | `detile_output` | `baseline` | `packed_pair` | Copy adjacent FP16 values with aligned 32-bit transactions. | `promoted` | 50.6% primary-shape cycle reduction; odd-N edge passes. |
| VK-14 | 4 | `vecadd`, `dropout` | `baseline` | `grid_stride` | Replace one-thread-block launch with capped grid-stride processing. | `proposed` | - |
| VK-15 | 4 | FP16 elementwise family | existing | `native_fp16` | Evaluate native conversion/intrinsic support before changing software conversion paths. | `proposed` | - |
| VK-16 | 1 | `sgemm_tcu` | `baseline` | `b_colmajor`, `lmem`, `lmem_b_colmajor` | Compare direct aligned col-major B loads and generalized 2x2-warp LMEM reuse of both A and B. | `promoted` | `b_colmajor` is the default; see VK-16 work log below. |
| VK-17 | 1 | `kv_cache_dequant_w4a16` | `baseline` | `packed_pair` | Decode both nibbles together, reuse qparams, and use a paired FP16 store. | `promoted` | 4.2% primary-shape cycle reduction; QDIR0 partial shape passes. |
| VK-18 | 2 | `kv_cache_quant_layout_fused_w4a16` | `baseline` | `qparam_warp` | Parallelize qparam group scans across a warp. | `rejected` | Correct but 2.04x slower due replicated layout/control work. |
| VK-19 | 1 | `head_concat_layout_fused` | `baseline` | `chunk16_packed` | Hoist tiled decode per 16-element chunk and use paired FP16 copies. | `promoted` | 91.9% primary prefill cycle reduction. |
| VK-20 | 2 | `eladd_layout_fused` | `baseline` | `tile_chunk32` | Traverse one GEMM-C microtile per task and amortize tiled address decode. | `promoted` | 35.0% primary-shape cycle reduction. |
| VK-21 | 2 | `tile_input_a` | `packed2` | `packed4` | Use native RV64 64-bit transfers for four FP16 values with scalar tail fallback. | `promoted` | 51.0% primary-shape cycle reduction; odd-K edge passes. |

### VK-06: softmax / opt_align and DMA control overhead

- Status: `promoted`
- Date started: 2026-07-12
- Baseline source: `tests/regression/softmax/kernel.rev1.cpp`
- First candidate: `tests/regression/softmax/kernel.opt_align.cpp`
- Selector: `SOFTMAX_VARIANT=<rev1|opt|opt_align|dma_row|dma_serial>`
- Metric: FPGA cycles printed by `main.cpp`
- FPGA binary: `naive_gemm_simd_th16_tcol32_hwexp_dcache`
- Primary decode shape: `-batch 1 -heads 32 -seqq 1 -seqk 2048 -mask 0`
- Primary prefill shape: `-batch 1 -heads 1 -seqq 2048 -seqk 2048 -mask 1`

The hardware wrapper rebuilds the application with the Makefile default inside
the Slurm job. A locally prebuilt variant is therefore not sufficient evidence;
the runtime output must print the intended variant name.

Latency results:

| FPGA bin | App | Variant | Arguments | FPGA cycles | Instructions | IPC | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `rev1` | decode B1/H32/Q1/K2048 | 3,325,181 | 12,864,893 | 3.868930 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `opt_align` | decode B1/H32/Q1/K2048 | 145,363 | 418,126 | 2.876427 | reject: 58,539 errors |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `dma_row` | decode B1/H32/Q1/K2048 | 7,033,445 | 9,317,975 | 1.324810 | pass, reject: 2.12x slower |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `dma_serial` | decode B1/H32/Q1/K2048 | 2,515,641 | 9,687,083 | 3.850741 | pass, current best: 24.3% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `dma_serial` | edge B1/H1/Q3/K130, mask | 90,285 | 86,948 | 0.963039 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `dma_serial` | prefill B1/H1/Q2048/K2048, mask | 123,181,677 | 499,531,337 | 4.055241 | pass; 20.8% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax` | `rev1` | prefill B1/H1/Q2048/K2048, mask | 155,536,936 | 517,735,804 | 3.328700 | pass |

The existing `opt_align` result is not a speedup because it fails the
correctness gate. Corruption begins at row 1, so the next variant will retain
the cached-exp and shuffle concepts but first restrict execution to one row per
block. Multi-row DMA/LMEM sharing will only be restored after that path passes.

`dma_row` passed, which isolates the failure to the multi-warp DMA/staging path
rather than the softmax math. Its one-warp launch underutilizes the four-warp
core and pays 64 DMA commands for 32 rows, making it slower than `rev1`. The
next variant restores four-warp compute but makes thread 0 program each row DMA
sequentially so descriptor MMIO is never issued concurrently by multiple warps.

`dma_serial` validates that hypothesis. It removes the corruption and reduces
the primary decode shape by 809,540 cycles (24.3%) relative to `rev1`. Prefill
also improves by 32,355,259 cycles (20.8%), and the masked partial-row edge
shape passes. `dma_serial` is therefore the promoted Makefile default.

### VK-01: softmax_layout_fused / host variant selection

- Status: `promoted`
- Date started: 2026-07-12
- Baseline source: `tests/regression/softmax_layout_fused/kernel.opt.cpp`
- Candidate: same kernel with corrected host launch selection
- Selector: `SOFTMAX_LAYOUT_FUSED_VARIANT=<rev1|opt|opt_warp>`
- Hypothesis: the singular/plural macro typo forces `opt` to use a 64-thread,
  four-warp block even though the kernel and comments intend one 16-thread warp
  per row. Correcting it permits four independent row blocks to reside on the
  core and overlap DMA wait with other rows.

Latency results:

| FPGA bin | App | Variant | Arguments | FPGA cycles | Instructions | IPC | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax_layout_fused` | `opt` | decode B1/H32/Q1/K2048 | 3,196,292 | 9,503,548 | 2.973304 | pass; 64-thread baseline |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax_layout_fused` | `opt_warp` | decode B1/H32/Q1/K2048 | 2,363,601 | 8,881,265 | 3.757514 | pass; 26.1% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax_layout_fused` | `opt` | prefill B1/H1/Q2048/K2048, mask | 139,200,932 | 425,897,573 | 3.059588 | pass; 64-thread baseline |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `softmax_layout_fused` | `opt_warp` | prefill B1/H1/Q2048/K2048, mask | 89,824,199 | 385,833,298 | 4.295427 | pass; 35.5% faster |

### VK-03: kv_cache_quant_w4a16 / group-wise parameter reuse

- Status: `promoted`
- Date started: 2026-07-12
- Baseline source: `tests/regression/kv_cache_quant_w4a16/kernel.cpp`
- Candidate: `tests/regression/kv_cache_quant_w4a16/kernel.groupwise.cpp`
- Selector: `KV_CACHE_QUANT_VARIANT=<baseline|groupwise>`
- Hypothesis: compute min/max, scale, and zero once per quantization group
  instead of scanning the same group twice for every packed output byte.
- Launch: one warp per group task, with shuffle min/max reduction and up to
  four co-resident groups on the configured four-warp core.

Latency results:

| FPGA bin | App | Variant | Arguments | FPGA cycles | Instructions | IPC | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_quant_w4a16` | `baseline` | K2048/N128/Q128/D1 | 289,624,222 | 1,549,343,548 | 5.349496 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_quant_w4a16` | `groupwise` | K2048/N128/Q128/D1 | 8,918,465 | 34,199,992 | 3.834740 | pass; 96.9% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_quant_w4a16` | `groupwise` | K130/N34/Q32/D0 | 387,820 | 1,134,071 | 2.924220 | pass; partial K group |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_quant_w4a16` | `groupwise` | K7/N130/Q32/D1 | 150,189 | 271,881 | 1.810259 | pass; partial N group |

### VK-17: kv_cache_dequant_w4a16 / packed pair

- Status: `promoted`
- Date started: 2026-07-12
- Selector: `KV_CACHE_DEQUANT_VARIANT=<baseline|packed_pair>`
- Candidate: `tests/regression/kv_cache_dequant_w4a16/kernel.packed_pair.cpp`
- Change: one thread consumes one packed byte, decodes both nibbles, avoids a
  duplicate qparam load when both values share a group, and stores two FP16
  outputs through one aligned 32-bit transaction.

| FPGA bin | App | Variant | Arguments | FPGA cycles | Instructions | IPC | Result |
| --- | --- | --- | --- | ---: | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_dequant_w4a16` | `baseline` | K2048/N128/Q128/D1 | 7,811,805 | 28,522,301 | 3.651179 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_dequant_w4a16` | `packed_pair` | K2048/N128/Q128/D1 | 7,486,701 | 23,820,604 | 3.181722 | pass; 4.2% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kv_cache_dequant_w4a16` | `packed_pair` | K130/N34/Q32/D0 | 223,003 | 505,703 | 2.267696 | pass; partial K group |

### VK-18: kv_cache_quant_layout_fused_w4a16 / qparam warp

- Status: `rejected`
- Selector: `KV_CACHE_QUANT_LAYOUT_FUSED_VARIANT=<baseline|qparam_warp>`
- Result: the warp-parallel qparam scan remained correct but replicated the
  non-trivial tiled-slot decode and control path on all 16 lanes. That overhead
  outweighed the shorter min/max scan, so the original implementation remains
  the default.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | K2048/N128/Q128/D1/GEMM-D1/tiled | 23,447,919 | 96,995,644 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `qparam_warp` | same | 47,905,399 | 135,503,932 | pass; reject, 2.04x slower |

### VK-11: rope_layout_fused / task chunking

- Status: `promoted`
- Selector: `ROPE_LAYOUT_FUSED_VARIANT=<baseline|task_chunk16>`
- Change: one work item owns 16 adjacent rotary pairs for a fixed
  `(batch, sequence, head)`, amortizing division/modulo and hoisting output
  layout selection outside the pair loop.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | B4/S1/H32/D128 row-major | 1,214,806 | 2,651,644 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `task_chunk16` | same | 737,174 | 2,033,020 | pass; 39.3% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | B1/S2048/H32/D128 row-major | 560,571,693 | 1,325,267,260 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `task_chunk16` | same | 304,349,499 | 1,008,588,604 | pass; 45.7% faster |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `task_chunk16` | B1/S128/H4/D128 GEMM-W | 4,122,896 | 10,340,830 | pass |

### VK-19: head_concat_layout_fused / packed chunks

- Status: `promoted`
- Selector: `HEAD_CONCAT_LAYOUT_FUSED_VARIANT=<baseline|chunk16_packed>`
- Change: decode a 16-element `(batch, sequence, head)` chunk once, compute
  input/output tiled bases once, then copy eight aligned 32-bit FP16 pairs.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | B1/S2048/H32/D128 | 430,014,135 | 738,246,460 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `chunk16_packed` | same | 34,656,292 | 101,758,780 | pass; 91.9% faster |

### VK-20: eladd_layout_fused / tile-native chunks

- Status: `promoted`
- Selector: `ELADD_LAYOUT_FUSED_VARIANT=<baseline|tile_chunk32>`
- Change: one task owns a 32-element GEMM-C microtile, so tiled and row-major
  bases are decoded once before the FP16 add loop.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | M2048/K4096 | 305,897,032 | 1,148,434,236 | pass |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `tile_chunk32` | same | 198,749,359 | 865,454,140 | pass; 35.0% faster |

### VK-05: rms_norm_layout_fused / warp shuffle reduction

- Status: `promoted`
- Selector: `RMS_NORM_LAYOUT_FUSED_VARIANT=<baseline|shuffle_warp>`
- Change: use one 16-lane warp per row, reduce sum-of-squares with register
  shuffles, compute reciprocal square root in lane 0, and broadcast it. The
  standalone tiling comparison keeps its original 64-thread launch.
- LMEM: baseline 256 bytes per row block; candidate 0 bytes.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | M2048/K4096/I1, fused path | 264,929,539 | 1,247,501,752 | pass |
| same | `shuffle_warp` | same | 233,893,271 | 1,219,101,495 | pass; 11.7% faster |

### VK-12: elmul_layout_fused / identical-slot linear traversal

- Status: `promoted`
- Selector: `ELMUL_LAYOUT_FUSED_VARIANT=<baseline|linear_same_layout>`
- Change: when GEMM-C input width and GEMM-A output width match, traverse the
  entire physical tiled slot linearly. A generic decoded fallback remains for
  future configurations with different microtile widths.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | M2048/K11008 | 1,155,876,972 | 3,429,260,860 | pass |
| same | `linear_same_layout` | same | 508,495,338 | 2,328,722,236 | pass; 56.0% faster |
| same | `linear_same_layout` | M3/K32, M_pad=8 | 74,422 | 53,988 | pass padded-row edge |

### VK-09: silu_layout_fused / physical-slot linear traversal

- Status: `promoted`
- Selector: `SILU_LAYOUT_FUSED_VARIANT=<baseline|linear_tiled>`
- Change: the fused path reads and writes GEMM-C layout, so it applies SiLU to
  the physical slot directly. Plain and row-matched paths retain their prior
  traversal. Processing zero-filled pad rows avoids per-element layout decode.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | M2048/K11008/I1, fused path | 584,739,293 | 1,908,967,932 | pass |
| same | `linear_tiled` | same | 509,626,917 | 1,937,354,524 | pass; 12.8% faster |
| same | `linear_tiled` | M3/K32/I1, M_pad=8 | 59,183 | 43,019 | pass padded-row edge |

### VK-13: detile_output / packed FP16 pairs

- Status: `promoted`
- Selector: `DETILE_OUTPUT_VARIANT=<baseline|packed_pair>`
- Change: one thread copies two adjacent FP16 values with an aligned 32-bit
  load/store. Odd-width or unaligned destination rows use a scalar tail.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | M2048/N4096 | 954,026,773 | 1,040,204,353 | pass |
| same | `packed_pair` | same | 470,857,739 | 566,248,001 | pass; 50.6% faster |
| same | `packed_pair` | M3/N33 | 51,155 | 27,786 | pass odd-N edge |

### VK-21: tile_input_a / RV64 packed-four copy

- Status: `promoted`
- Selector: `TILE_INPUT_A_VARIANT=<packed2|packed4>`
- Change: widen the existing aligned two-FP16 transaction to a native 64-bit
  four-FP16 transaction. Unaligned source rows and partial K tails are packed
  safely with 16-bit loads; pad rows remain zero-filled.

| FPGA bin | Variant | Arguments | FPGA cycles | Instructions | Result |
| --- | --- | --- | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `packed2` | M2048/K4096 | 459,805,632 | 620,773,953 | pass |
| same | `packed4` | same | 225,502,668 | 316,686,913 | pass; 51.0% faster |
| same | `packed4` | M3/K35 | 62,232 | 45,392 | pass odd-K/pad edge |

## Per-Variant Work Log Template

Copy this section for each implementation attempt.

### VK-XX: Application / Variant

- Status: `implementing`
- Owner:
- Date started:
- Baseline source:
- Candidate source:
- Selector:
- Hypothesis:
- Expected benefit:
- Correctness risk:
- LMEM formula:
- Expected occupancy impact:

Implementation notes:

- 

Verification:

| Check | Baseline | Candidate | Result |
| --- | --- | --- | --- |
| Build | - | - | - |
| Regression correctness | - | - | - |
| Representative edge shape | - | - | - |
| xrt-vcs-sim | - | - | - |
| Hardware latency | - | - | - |

Latency results:

| FPGA bin | App | Variant | Arguments | Warmup | Iterations | Cycle/latency | Relative to baseline |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| - | - | baseline | - | - | - | - | 1.00x |
| - | - | candidate | - | - | - | - | - |

Decision:

- Promotion/rejection decision:
- Evidence:
- Follow-up:

### VK-16: sgemm_tcu / B layout and multi-warp LMEM reuse

- Status: `measured`
- Date started: 2026-07-12
- Baseline source: `tests/regression/sgemm_tcu/kernel.baseline.cpp`
- Candidate sources: one `kernel.<tag>.cpp` per row in the result tables below, backed by shared direct, LMEM, or tutorial implementation headers.
- Selector: `SGEMM_TCU_VARIANT=<tag>`; the Makefile validates every supported tag and passes matching numeric parameters to host and device builds.
- Host path: `main.cpp`; benchmark/prepack-inclusive timing is intentionally not used.
- Hypothesis: col-major B avoids FP16 row packing in every WMMA fragment load; a 2x2-warp supertile can load each A tile once per warp row and each B tile once per warp column.
- LMEM formula: `(WARPS_M * tileM * tileK + WARPS_N * tileK * tileN) * sizeof(input_t)`. For FP16, 2x2 warps, and 16x8x16 tiles this is 1,536 bytes per workgroup.
- Launch geometry: baseline/col-major use one warp per output tile; LMEM variants use four warps per workgroup and one 32x16 output supertile.

Implementation notes:

- Generic byte-addressable B is prepacked to column-major on the host only for col-major variants. The original row-major `h_B` remains the CPU reference input.
- LMEM staging uses aligned 32-bit transfers distributed across every thread in the four-warp workgroup. Thread `t` copies flattened tile words `t`, `t + blockDim.x`, and so on, so adjacent threads access adjacent words while preserving tile-major LMEM layout.
- All warps, including inactive boundary warps, participate in both K-tile barriers. Out-of-range supertile inputs are zero-filled.
- The Makefile default is `b_colmajor`; `baseline` remains explicitly selectable for comparison.

Verification:

| Check | Baseline | Candidates | Result |
| --- | --- | --- | --- |
| Host/device build | pass | all three pass | Four distinct source selections and matching host/device macros compiled. |
| Hardware correctness, `-m 32 -k 1024 -n 128` | pass | all three pass | All runs ended in `PASSED!`. |
| Representative edge shape | - | pass | `lmem_b_colmajor -m 33 -k 17 -n 17` pads to 48x32x24, exercises inactive M/N warps, and passes. |
| xrt-vcs-sim | not run | not run | Current experiment is restricted to the requested hardware flow. |

Hardware command (run from `build/`):

```sh
env SGEMM_TCU_VARIANT=<variant> ./ci/run_black.sh hw --fpga-bin naive_gemm_simd_th16_tcol32_hwexp_dcache --app sgemm_tcu --args "-m 32 -k 1024 -n 128"
```

Latency results:

| FPGA bin | Variant | Arguments | Instructions | Cycles | Relative cycles | Decision |
| --- | --- | --- | ---: | ---: | ---: | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `baseline` | `-m 32 -k 1024 -n 128` | 2,889,645 | 787,982 | 1.000x | Reference |
| same | `b_colmajor` | same | 2,064,813 | 557,470 | 0.707x | Best; 29.3% fewer cycles |
| same | `lmem` | same | 9,565,616 | 2,397,304 | 3.042x | Reject for this configuration |
| same | `lmem_b_colmajor` | same | 8,976,816 | 2,322,703 | 2.948x | Reject for this configuration |

Decision:

- `b_colmajor` is promoted as the default based on the fixed-shape correctness and 29.3% cycle reduction.
- The generalized LMEM implementation is correct for the measured shape, but per-K-tile staging plus two four-warp barriers dominates the saved global reads on this FPGA configuration.
- Replacing dedicated producer warps with all-thread interleaved staging reduced `lmem` cycles by 19.8% and `lmem_b_colmajor` cycles by 21.2% relative to the first packed-staging implementation.
- Keep all variants selectable so later shapes or RTL configurations can re-evaluate the tradeoff without replacing the baseline.

#### Tutorial-derived cumulative variants

The transferable concepts from Cedric Nugteren's SGEMM tutorial were implemented as tagged variants without using OpenCL:

| Tag | Added concept | Warp fragments MxN | K stage | Transfer | LMEM/workgroup |
| --- | --- | ---: | ---: | ---: | ---: |
| `kstage4` | Stage four WMMA K tiles per barrier pair | 1x1 | 64 FP16 | 32-bit | 6,144 bytes |
| `kstage4_n2` | N-direction register blocking | 1x2 | 64 FP16 | 32-bit | 8,192 bytes |
| `kstage4_m2n2` | 2D register blocking | 2x2 | 64 FP16 | 32-bit | 12,288 bytes |
| `kstage4_m2n2_wide64` | Cumulative 2D blocking plus wider staging | 2x2 | 64 FP16 | 64-bit | 12,288 bytes |
| `kstage4_wide64` | Isolate wider staging from the failing multi-fragment step | 1x1 | 64 FP16 | 64-bit | 6,144 bytes |

For `K=1024`, K-stage blocking reduces four-warp barriers from 128 to 32. The host pads K to a multiple of the selected panel size. All variants preserve globally and locally column-major B.

Fixed-shape hardware results:

| FPGA bin | Variant | Arguments | Instructions | Cycles | Correctness | Interpretation |
| --- | --- | --- | ---: | ---: | --- | --- |
| `naive_gemm_simd_th16_tcol32_hwexp_dcache` | `kstage4` | `-m 32 -k 1024 -n 128` | 7,568,816 | 2,219,460 | PASS | 4.4% faster than `lmem_b_colmajor` |
| same | `kstage4_n2` | same | 6,255,554 | 3,559,648 | FAIL: 1,894/4,096 | Multiple live accumulator fragments introduce 1-ULP FP16 differences |
| same | `kstage4_m2n2` | same | 7,615,042 | 4,385,892 | FAIL: 1,894/4,096 | Diagnostic cycle only; rejected |
| same | `kstage4_m2n2_wide64` | same | 5,152,706 | 3,819,118 | FAIL: 1,894/4,096 | 64-bit staging helps, but does not fix accumulator mismatch |
| same | `kstage4_wide64` | same | 4,653,488 | 1,402,739 | PASS | Best LMEM variant; 36.8% faster than `kstage4` |

Additional validation:

- `kstage4_n2 -m 16 -k 64 -n 16`: 117/256 values differ by one FP16 ULP. Adding `vx_fence()` after each MMA produced exactly the same failures, so the fence was removed.
- `kstage4_m2n2 -m 64 -k 1024 -n 128`: 3,905/8,192 mismatches and 7,524,208 diagnostic cycles with the 64x32 supertile fully utilized.
- `kstage4_m2n2_wide64` at the same fully utilized shape: the same 3,905 mismatches and 6,754,517 diagnostic cycles.
- At the same fully utilized `-m 64 -k 1024 -n 128` shape, `b_colmajor` takes 1,048,408 cycles (IPC 3.923) and `kstage4_wide64` takes 2,739,199 cycles (IPC 3.392). Both have only 2/8,192 one-ULP FP16 differences. Thus the 2D variants remain 6.44-7.18x slower than direct col-major even when their supertile is fully occupied.
- `kstage4_wide64 -m 33 -k 17 -n 17`: PASS with M/N/K padded to 48/24/64, exercising inactive warp tiles and the wider-load boundary path.

Tutorial-step decision:

- Larger K panels are correct and modestly reduce cycles by amortizing barriers.
- Native RV64 64-bit staging is correct and materially reduces staging instructions. A native 128-bit scalar load was not attempted because RV64 has no corresponding scalar load instruction.
- Warp-level register blocking is not promotable with the current `mma_sync` interface: alternating multiple live accumulator fragments changes strict FP16 results by one ULP, and 2D blocking also causes extensive register spills.
- Even the best correct LMEM result, `kstage4_wide64` at 1,402,739 cycles, remains slower than direct `b_colmajor` at 557,470 cycles. `b_colmajor` is the selected default.

## Verification Requirements

Every candidate variant must satisfy all applicable checks before promotion.

### Functional checks

- Build the baseline and candidate from the same configured build directory.
- Run the application's existing regression test for both variants.
- Compare candidate output against the same reference and tolerance used by the baseline.
- Exercise boundary shapes relevant to the optimization: partial tiles, non-multiple lengths, minimum dimensions, mask boundaries, and quantization tails.
- Verify that power-kernel iteration mode does not change output or variant selection.

### Simulation checks

- Run `xrt-vcs-sim` for changes that affect LMEM, barriers, DMA, launch geometry, or memory ordering.
- Compare baseline and candidate cycles for at least one small shape that is practical in RTL simulation.
- Treat an X-propagation, timeout, or mismatch as a correctness failure, not as a performance result.

### Hardware checks

- Source the FPGA alias configuration used by the suite.
- Use the same FPGA binary for baseline and candidate unless the experiment explicitly studies an RTL dependency.
- Record the effective application variant in the output.
- Measure representative prefill and generation shapes rather than a single synthetic shape.
- For LMEM variants, include at least one shape near the largest supported footprint and record occupancy or maximum-per-group LMEM when available.

## Initial Findings and Evidence

### Highest-impact issues

1. `elreduce` assigns a complete row reduction to one thread, leaving row-internal parallelism unused. See `tests/regression/elreduce/kernel.cpp`.
2. `kv_cache_quant_w4a16` scans the same quantization group for every packed output pair. See `tests/regression/kv_cache_quant_w4a16/kernel.cpp`.
3. RMSNorm uses a full LMEM tree and computes the same square root/reciprocal in every participating thread. See `tests/regression/rmsnorm/kernel.cpp` and `tests/regression/rms_norm_layout_fused/kernel.cpp`.
4. The optimized softmax variants cache exponentials and use DMA, but DMA is blocking and not double-buffered.
5. SiLU v2 assigns a complete 32-element chunk to one thread, so adjacent lanes begin 32 elements apart.
6. RoPE repeatedly decodes flattened pair indices using runtime division/modulo and reloads reusable sin/cos entries across heads and batches.
7. Several FP16 kernels spend substantial work in software FP16/FP32 conversion; native ISA support must be checked before introducing a replacement variant.

### What is already well optimized

- Layout-fused kernels remove complete detile/retile memory passes.
- `tile_input_a` performs aligned paired-FP16 copies.
- `tile_weight_w4a16` has a 16-byte aligned fast path and scalar boundary fallback.
- `tile_scale_zp_w4a16` uses a 3D launch and power-of-two decode for full tiles.
- `sgemm_tcu` uses WMMA fragments and `load_matrix_sync`/`mma_sync`/`store_matrix_sync` directly, with padded execution dimensions and one output tile per block.
- Optimized softmax variants use shuffle reduction, LMEM staging, exponent caching, and DMA.
- Hadamard uses LMEM for true iterative data reuse rather than as an unnecessary streaming cache.

## Deferred Questions

- Does the configured device ISA expose native FP16 conversion or packed FP16 arithmetic suitable for these kernels?
- What is the measured LMEM bank-conflict behavior for FP32 reduction buffers?
- Can the DMA command path safely support two outstanding row transfers per block for double buffering?
- Which benchmark shapes dominate total LLaMA latency after GEMM optimization, and should that reorder the backlog?
- For RoPE, does dcache already capture enough sin/cos reuse to make LMEM staging unhelpful?
- Should a promoted variant become the Makefile default immediately, or only after the full latency suite is regenerated?

## Change Log

| Date | Change |
| --- | --- |
| 2026-07-12 | Created the tracker from the static review of 29 active vector applications. Added LMEM classification, variant policy, prioritized backlog, and experiment templates. |
| 2026-07-12 | Added `sgemm_tcu` as the 30th tracked application and added a fragment-prefetch variant candidate. |
| 2026-07-12 | Added four `sgemm_tcu` variants and hardware results. Col-major B reduced cycles by 29.3%; the generalized 2x2-warp LMEM variants were correct but slower. |
| 2026-07-12 | Changed LMEM staging from dedicated producer warps to all-thread interleaved 32-bit transfers. Hardware cycles improved by about 20%, and the padded inactive-warp edge shape remained correct. |
| 2026-07-12 | Added tutorial-derived `kstage4`, warp register-blocking, and 64-bit staging tags. K-stage and isolated wide64 variants pass; multi-fragment variants show strict 1-ULP mismatches and are retained as rejected experiments. |
| 2026-07-12 | Promoted `sgemm_tcu` `b_colmajor` to the Makefile default; retained `baseline` and all experimental LMEM tags for explicit comparison. |
| 2026-07-12 | Started the ordered vector-kernel optimization loop. The active order is softmax, KV-cache quantize, dequantize, then remaining layout-fused kernels; `main.cpp` FPGA cycles are the comparison metric. |
| 2026-07-12 | Completed the ordered pass. Promoted shuffle RMSNorm, linear same-layout SiLU/ELMUL, packed detile, and RV64 packed-four tile-input variants; retained the slower quant-layout warp experiment as rejected. |

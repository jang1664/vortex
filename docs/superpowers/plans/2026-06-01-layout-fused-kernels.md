# Layout Fused Kernels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the missing layout-fused regression apps used by the `all_fpint_gemm_fused_layout` workload variant.

**Architecture:** Keep each fused kernel as a standalone regression app whose app name matches the workload backend name. The host test creates both the producer layout and CPU reference output, while the device kernel consumes the producer layout and writes the consumer layout directly. Use log2 tile arguments for all power-of-two tile constants so kernel address math uses shifts and masks instead of divisions.

**Tech Stack:** Vortex regression apps in `tests/regression`, C++ host code, Vortex device C++ kernels, `tools/workload/gen_kernel_cfgs.py`, Python unittest suites, `ci/run_black.sh` in xrt-vcs-sim mode.

---

## Files

- Create: `tests/regression/layout_fused_common/layout_fused_layouts.h`
- Create: `tests/regression/eladd_layout_fused/Makefile`
- Create: `tests/regression/eladd_layout_fused/common.h`
- Create: `tests/regression/eladd_layout_fused/kernel.cpp`
- Create: `tests/regression/eladd_layout_fused/main.cpp`
- Create: `tests/regression/eladd_layout_fused/bench_main.cpp`
- Create: `tests/regression/elmul_layout_fused/Makefile`
- Create: `tests/regression/elmul_layout_fused/common.h`
- Create: `tests/regression/elmul_layout_fused/kernel.cpp`
- Create: `tests/regression/elmul_layout_fused/main.cpp`
- Create: `tests/regression/elmul_layout_fused/bench_main.cpp`
- Create: `tests/regression/softmax_layout_fused/Makefile`
- Create: `tests/regression/softmax_layout_fused/common.h`
- Create: `tests/regression/softmax_layout_fused/kernel.cpp`
- Create: `tests/regression/softmax_layout_fused/main.cpp`
- Create: `tests/regression/softmax_layout_fused/bench_main.cpp`
- Create: `tests/regression/rope_layout_fused/Makefile`
- Create: `tests/regression/rope_layout_fused/common.h`
- Create: `tests/regression/rope_layout_fused/kernel.cpp`
- Create: `tests/regression/rope_layout_fused/main.cpp`
- Create: `tests/regression/rope_layout_fused/bench_main.cpp`
- Modify: `tools/workload/gen_kernel_cfgs.py`
- Modify: `tools/workload/test_kernel_variants.py`
- Modify: `tools/latency_bench/test_workload_variants.py`
- Modify: `docs/layout_transform/README.md`
- Modify: `docs/layout_transform/layout.md`

## Scope Decisions

- `rms_norm_layout_fused` and `silu_layout_fused` already exist, so keep them unless shared helpers make small cleanup worthwhile.
- `layout_fused_intermediate` should be documented as the same 2-D GEMM-A tiled address formula used by `tile_input_a`, with `float` elements in the current regression apps.
- `eladd_layout_fused` consumes GEMM-C tiled producer output and a row-major residual, then writes row-major output.
- `elmul_layout_fused` consumes `layout_fused_intermediate` and GEMM-C tiled `up_proj` output, then writes GEMM-A tiled output for `down_proj`.
- `softmax_layout_fused` consumes GEMM-C tiled attention scores and writes GEMM-A tiled probabilities for `attn_pv`.
- `rope_layout_fused` needs an explicit output mode because `rope_q` writes GEMM-A tiled data while `rope_k` is modeled as the B/W operand of `attn_qkT`.
- `rope_k` has a semantic risk: the current metadata says `gemm_w_tiled`, but RoPE naturally produces activation data, not packed int4 weight data. Implement the latency-model path as a W-like tiled fp32 buffer only if the goal is layout-fusion timing; do not claim it is the same packed int4 `tile_weight_w4a16` format unless quantization and qparams are added.

## Task 1: Add Generator Tests For Missing Fused Apps

**Files:**
- Modify: `tools/workload/test_kernel_variants.py`
- Modify: `tools/latency_bench/test_workload_variants.py`

- [ ] Add a test that every backend in the fused-layout variant maps to an existing `tests/regression/<app>/Makefile`.
- [ ] Add assertions that `rope_q` fused args include `--layout-to gemm_a_tiled`.
- [ ] Add assertions that `rope_k` fused args include `--layout-to gemm_w_tiled`.
- [ ] Run `python -m unittest tools.workload.test_kernel_variants tools.latency_bench.test_workload_variants`.
- [ ] Expected red result before implementation: missing app directories for `rope_layout_fused`, `softmax_layout_fused`, `eladd_layout_fused`, and `elmul_layout_fused`, plus missing `rope_layout_fused` mode args.

## Task 2: Make Fused Layout Metadata Explicit

**Files:**
- Modify: `tools/workload/gen_kernel_cfgs.py`

- [ ] Update `_apply_fused_layout_variant()` so `rope_q` calls `rope_layout_fused` with `--layout-to gemm_a_tiled`.
- [ ] Update `_apply_fused_layout_variant()` so `rope_k` calls `rope_layout_fused` with `--layout-to gemm_w_tiled`.
- [ ] Keep `eladd_layout_fused`, `elmul_layout_fused`, and `softmax_layout_fused` args shape-compatible with their standalone kernels.
- [ ] Run `python -m unittest tools.workload.test_kernel_variants tools.latency_bench.test_workload_variants`.
- [ ] Expected result after only this task: mode-arg tests pass, app-existence tests still fail.

## Task 3: Add Shared Layout Offset Helpers

**Files:**
- Create: `tests/regression/layout_fused_common/layout_fused_layouts.h`

- [ ] Define `align_up_pow2_u32(x, log2_align)`.
- [ ] Define `gemm_a_tiled_elem_offset(m, k, m_pad, k_dim, log2_mt, log2_mxu_kt)`.
- [ ] Define `gemm_c_tiled_elem_offset(m, n, m_pad, n_dim, log2_mt, log2_mxu_nt)`.
- [ ] Define `batched_matrix_base(batch_matrix, matrix_elems)` for fused kernels that process per-head matrices.
- [ ] Keep the helpers header-only, `static inline`, and usable from both host and device code.

## Task 4: Implement `eladd_layout_fused`

**Files:**
- Create: `tests/regression/eladd_layout_fused/*`

- [ ] Kernel args: `input_a_addr`, `input_b_addr`, `output_addr`, `M_real`, `M_pad`, `K`, `log2_mt`, `log2_mxu_nt`.
- [ ] Device logic: for each logical `[m, k]`, read `input_a` from GEMM-C tiled offset, read `input_b[m*K+k]`, write row-major `output[m*K+k]`.
- [ ] Host test: generate row-major producer data, pack it into GEMM-C tiled input, run the kernel, compare against row-major CPU `a + b`.
- [ ] Bench binary: reuse the same allocation and launch path, run warmup and iteration loops through the existing benchmark utility pattern.
- [ ] Build: `make -C build/tests/regression/eladd_layout_fused -j4`.
- [ ] xrt-vcs-sim smoke: from `build`, source `../configs/naive_simd.sh`, then run `./ci/run_black.sh xrt-vcs-sim --app eladd_layout_fused --args '-m 8 -k 32'`.

## Task 5: Implement `elmul_layout_fused`

**Files:**
- Create: `tests/regression/elmul_layout_fused/*`

- [ ] Kernel args: `input_a_addr`, `input_b_addr`, `output_addr`, `M_real`, `M_pad`, `K`, `log2_mt`, `log2_mxu_kt`, `log2_mxu_nt`.
- [ ] Device logic: read `input_a` from GEMM-A tiled offset, read `input_b` from GEMM-C tiled offset, write `output` to GEMM-A tiled offset.
- [ ] Host test: generate row-major `silu_gate` and `up_proj`, pack `silu_gate` into GEMM-A layout, pack `up_proj` into GEMM-C layout, compare tiled output against CPU `silu_gate * up_proj`.
- [ ] Build: `make -C build/tests/regression/elmul_layout_fused -j4`.
- [ ] xrt-vcs-sim smoke: `./ci/run_black.sh xrt-vcs-sim --app elmul_layout_fused --args '-m 8 -k 32'`.

## Task 6: Implement `softmax_layout_fused`

**Files:**
- Create: `tests/regression/softmax_layout_fused/*`

- [ ] Kernel args: base softmax args plus `M_pad`, `log2_mt`, `log2_mxu_kt`, `log2_mxu_nt`.
- [ ] Device logic: one block per `(batch, head, query)` row, read scores from GEMM-C tiled offset, compute scaled/masked softmax over `seq_len_k`, write probabilities to GEMM-A tiled offset.
- [ ] Host test: generate row-major scores, pack them into per-head GEMM-C tiled matrices, compare GEMM-A tiled output against CPU softmax.
- [ ] Build: `make -C build/tests/regression/softmax_layout_fused -j4`.
- [ ] xrt-vcs-sim smoke: `./ci/run_black.sh xrt-vcs-sim --app softmax_layout_fused --args '-batch 1 -heads 1 -seqq 4 -seqk 32 -mask 1'`.

## Task 7: Implement `rope_layout_fused`

**Files:**
- Create: `tests/regression/rope_layout_fused/*`

- [ ] CLI args: base RoPE args plus `--layout-to gemm_a_tiled|gemm_w_tiled`.
- [ ] Device logic for `gemm_a_tiled`: read q-projection output from GEMM-C tiled offsets over logical `N=heads*head_dim`, apply RoPE, write one GEMM-A tiled matrix per `(batch, head)`.
- [ ] Device logic for `gemm_w_tiled`: read k-projection output from GEMM-C tiled offsets over logical `N=heads*head_dim`, apply RoPE, write one W-like tiled matrix per `(batch, head)` with logical `[K=head_dim, N=max_seq_len]` and active columns at `pos_offset + s`.
- [ ] Host test for Q mode: pack row-major Q projection output into GEMM-C layout, run, compare GEMM-A tiled output against CPU RoPE.
- [ ] Host test for K mode: pack row-major K projection output into GEMM-C layout, run, compare W-like tiled output against CPU RoPE placed at cache columns.
- [ ] Build: `make -C build/tests/regression/rope_layout_fused -j4`.
- [ ] xrt-vcs-sim Q smoke: `./ci/run_black.sh xrt-vcs-sim --app rope_layout_fused --args '-batch 1 -seq 4 -heads 1 -headdim 32 -maxseq 8 -offset 0 --layout-to gemm_a_tiled'`.
- [ ] xrt-vcs-sim K smoke: `./ci/run_black.sh xrt-vcs-sim --app rope_layout_fused --args '-batch 1 -seq 4 -heads 1 -headdim 32 -maxseq 8 -offset 0 --layout-to gemm_w_tiled'`.

## Task 8: Update Documentation

**Files:**
- Modify: `docs/layout_transform/README.md`
- Modify: `docs/layout_transform/layout.md`

- [ ] Document that `layout_fused_intermediate` currently aliases GEMM-A tiled layout for fp32 regression buffers.
- [ ] Document the batched per-head layout convention used by `rope_layout_fused` and `softmax_layout_fused`.
- [ ] Document that `rope_k`'s `gemm_w_tiled` fused path is a latency-model W-like layout unless quantized packed K-cache support is added.
- [ ] Update the Reference section in `layout.md` with the new source files.

## Task 9: Full Verification

**Files:**
- All created and modified files above.

- [ ] Rerun configure from `build` if new regression dirs are not present there: `../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex`.
- [ ] Build all new apps: `make -C build/tests/regression/eladd_layout_fused -j4`, `make -C build/tests/regression/elmul_layout_fused -j4`, `make -C build/tests/regression/softmax_layout_fused -j4`, `make -C build/tests/regression/rope_layout_fused -j4`.
- [ ] Run generator tests: `python -m unittest tools.workload.test_kernel_variants tools.latency_bench.test_workload_variants`.
- [ ] Run syntax check: `git diff --check`.
- [ ] Run xrt-vcs-sim smoke tests listed in Tasks 4 through 7 with small matrices and without `--debug`.
- [ ] Regenerate one fused-layout workload suite and confirm no case references a missing app.

## Open Risk

The only material design risk is `rope_k -> attn_qkT`: the existing workload metadata models K-cache preparation as `gemm_w_tiled`, while RoPE produces activation values. If latency modeling is enough, implement W-like tiled fp32 storage and document it. If correctness against a real fpint attention GEMM is required, add a separate activation-B/K-cache layout and quantization/qparam path before implementing `rope_k` as a packed int4 weight layout.

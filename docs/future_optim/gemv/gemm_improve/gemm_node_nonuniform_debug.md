# GEMM Node Nonuniform QDIR Debug Plan

## Overview

Validate `hw/unittest/gemm_node_improve` with deterministic nonuniform vectors
that exactly match `tests/regression/fpint_gemm_ffn_hw/main.cpp` for both
QDIR=0 (QCOL) and QDIR=1 (QROW). If the directed RTL tests pass, run the same
QDIR matrix through XRT-VCS. Locate any bug encountered, fix it only when it is
a simple coding error, and stop with a root-cause report before modifying an
architectural problem.

This is a separate correctness task from `dma_optim.md`. Its result may unblock
the DMA optimization verification matrix, but it must not silently change the
confirmed DMA look-ahead architecture.

## Confirmed Current State

- `gemm_node_improve` does not compile or execute
  `tests/regression/fpint_gemm_ffn_hw/main.cpp`. It uses the independent
  SystemVerilog testbench `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`.
- The testbench defaults its input, weight, scale, and zero-point selector
  variables to type 3. Those formulas are not the application formulas:
  input, weight, and scale vary, but type-3 zero-point is constant zero.
- The existing testbench first builds a one-dimensional `scale_vec` and
  `zp_vec`, then replicates them across QCOL K-groups or QROW K rows. That
  cannot reproduce the application's full `(kg,n)` or `(k,ng)` dependence.
- `ci/run_target_gemm.sh` defaults to QDIR=1. The previously passing fixed
  XRT-VCS workloads therefore prove the application's nonuniform QROW path,
  not the QDIR=0/QCOL node path.

## Authoritative Nonuniform Profile

Add a named testbench profile, for example `+MAIN_CPP_NONUNIFORM`, whose values
match `fpint_gemm_ffn_hw/main.cpp` exactly. Do not replace an existing selector
meaning or weaken other tests.

For every real matrix coordinate:

```text
A[m,k]       = fp16(1.0 + ((m + k) % 3) / 100.0)
W[k,n]       = ((k * N + n) % 7) - 3

QDIR=0:
  scale[kg,n] = fp16(1.0 + ((n + kg) % 3) / 100.0)
  zero[kg,n]  = ((n + kg) % 7) - 3
  kg          = k / QBLK

QDIR=1:
  scale[k,ng] = fp16(1.0 + ((ng + k) % 3) / 100.0)
  zero[k,ng]  = ((ng + k) % 7) - 3
  ng          = n / QBLK
```

The SystemVerilog reference must preserve the application arithmetic boundary:

```text
QDIR=0: sum += a * (w - zero) * scale
QDIR=1: sum += fp16_rne(a * scale) * (w - zero)
```

Before RTL execution, emit a parseable profile marker and compare sentinel
values from multiple M, K, N, K-group, and N-group positions against the C++
formulas. The test must fail if the requested profile is not active.

## Phase 0: Reproduce and Lock the Baseline

1. Use a configured `build/` directory and source
   `configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`.
2. Record the current source revision, relevant RTL/testbench hashes, compiler
   configuration, and `VX_dma_unit_misal.sv` hash.
3. Run the existing default type-3 node test separately for QDIR=0 and QDIR=1
   at `M=4,N=256,K=256,QBLK=32,WTRANS=0`.
4. Preserve each log, first mismatch, mismatch count/pattern, job completion
   time, and output footprint. Do not combine the two QDIR results.
5. Run the existing `test.sh qcol` and `test.sh qrow` suites to distinguish a
   single-shape defect from a general regression.

## Phase 1: Add the Application-Matching Profile

1. Extend only the test-vector generation path needed to express the full
   profile. Populate `ref_scale` and `ref_zero` directly in their full QDIR
   layouts rather than replicating a one-dimensional vector.
2. Reuse the existing tiled input, weight, scale, zero-point, and output
   writers after confirming their byte order against the C++ conversion
   routines.
3. Add assertions for:
   - profile activation;
   - FP16 bit patterns at selected coordinates;
   - signed INT4 packing order;
   - QCOL `(kg,n)` and QROW `(k,ng)` scale/zero indexing;
   - total tiled footprints and 512-byte slot boundaries.
4. Keep the existing exact/reference comparison and tolerance unchanged. Never
   fall back to uniform data to obtain a passing result.

## Phase 2: Directed VCS Verification

Run through `tools/verify_rtl.py` from the configured repository. The intended
command shapes are:

```bash
source configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh
export CC=/usr/bin/gcc
export CXX=/usr/bin/g++

/usr/bin/python3 tools/verify_rtl.py unittest \
  --path build/hw/unittest/gemm_node_improve --sim vcs --timeout 1200 \
  --params "TEST=MAINCPP_NONUNIFORM_QCOL M=4 N=256 K=256 QBLK=32" \
  --extra-sim-args "+WTRANS=0 +QDIR=0 +MAIN_CPP_NONUNIFORM +NO_WAVE"

/usr/bin/python3 tools/verify_rtl.py unittest \
  --path build/hw/unittest/gemm_node_improve --sim vcs --timeout 1200 \
  --params "TEST=MAINCPP_NONUNIFORM_QROW M=4 N=256 K=256 QBLK=32" \
  --extra-sim-args "+WTRANS=0 +QDIR=1 +MAIN_CPP_NONUNIFORM +NO_WAVE"
```

For each QDIR, require:

- the explicit `MAIN_CPP_NONUNIFORM` profile marker;
- exact tiled input/weight/scale/zero sentinel checks;
- job completion and final drain;
- all `M*N=1024` real outputs checked;
- zero mismatches and no assertion/fatal error.

After both focused cases pass, rerun the existing QCOL and QROW regression
suites. A pass from one QDIR cannot substitute for the other.

## Phase 3: Locate the First Divergence

If either directed case fails, do not immediately modify RTL. Trace one failing
output coordinate and its K contributions through these checkpoints:

1. row-major C++-formula source values;
2. testbench reference arrays;
3. tiled DRAM bytes and slot offsets;
4. DMA/TMEM destination bank and address;
5. QCOL/QROW scale and zero-point read address/data;
6. GEMM lane input, weight nibble, scale, and zero-point operands;
7. FP16 multiplication boundary and accumulator contribution;
8. output lane, tiled DRAM byte position, and `(m,n)` checker coordinate.

Use distinguishable sentinel coordinates spanning lane, group, and tile
boundaries. Identify the earliest checkpoint whose actual value differs from
the expected value. Preserve waveform/trace evidence; instrumentation must be
simulation-only and must not change scheduling or backpressure.

Investigate in this order:

1. mismatch between the C++ and SystemVerilog vector/reference formulas;
2. input/weight INT4 packing or tiled byte order;
3. QCOL/QROW scale/zero slot indexing or offset calculation;
4. TMEM bank/lane selection;
5. QDIR-specific arithmetic/rounding;
6. output lane/tile reconstruction.

## Phase 4: Classification and Fix Gate

### Simple coding error

Examples include an incorrect loop bound, index, bit slice, signed cast,
stride, offset, padding term, packing order, or condition. For a proven simple
coding error:

1. apply the smallest correction at the first-divergence source;
2. add a directed regression that fails before and passes after the fix;
3. rerun both focused QDIR cases, the QCOL/QROW suites, and affected lower-level
   tests;
4. continue to XRT-VCS only after all directed tests pass.

### Architectural problem

An architectural problem includes incompatible producer/consumer layout
contracts, insufficient command metadata, a bank/lane protocol that cannot
represent the required mapping, or a correction requiring protocol/state
redesign across modules.

If the first divergence is architectural, do not change production RTL or
reinterpret the test. Stop immediately and report:

- expected and actual contracts;
- first-divergence evidence;
- affected modules/interfaces;
- why a local coding correction is insufficient;
- possible design directions and their trade-offs.

If classification is uncertain, treat it as architectural and report before
editing production RTL.

## Phase 5: XRT-VCS Verification

After both directed QDIR cases and existing suites pass, run the application
that actually compiles `tests/regression/fpint_gemm_ffn_hw/main.cpp`. Use the
configured wrapper without extra compile defines:

```bash
ci/run_target_gemm.sh run --wload 8 --m 4   --n 256 --k 256 --qdir 0
ci/run_target_gemm.sh run --wload 8 --m 4   --n 256 --k 256 --qdir 1
ci/run_target_gemm.sh run --wload 8 --m 256 --n 256 --k 256 --qdir 0
ci/run_target_gemm.sh run --wload 8 --m 256 --n 256 --k 256 --qdir 1
```

For every workload, preserve the manifest and logs and require:

- the expected QDIR in application arguments;
- nonuniform reference sentinel values;
- complete host comparison with zero mismatches;
- final `PASSED` and exit status zero;
- total cycles and relevant GEMM/DMA command counts recorded.

Do not use `simx` or Verilator RTL simulation as a substitute for XRT-VCS.

## Phase 6: Report

Write a durable report under `agent-tasks/gemm-node-nonuniform-debug/` with:

- exact reproduction commands and environment;
- QDIR=0/QDIR=1 baseline and final result tables;
- vector-profile sentinel evidence;
- first-divergence trace and root cause;
- classification as simple coding error or architectural problem;
- changed files and rationale, if a simple fix was applied;
- all directed, regression, and XRT-VCS results;
- reusable lessons and remaining risks.

For a simple coding error, summarize the correction and why it preserves the
architecture. For an architectural problem, explicitly state that no
production fix was applied.

## Acceptance Criteria

- `gemm_node_improve` demonstrably uses the application-matching nonuniform
  profile for both QDIR=0 and QDIR=1.
- Both focused VCS cases check every real output and pass with zero mismatches.
- Existing QCOL and QROW suites pass without weaker or uniform vectors.
- All four fixed XRT-VCS workloads pass the application's host reference.
- Any simple coding fix has a focused regression and a complete process report.
- Any architectural problem is reported before production RTL modification.

## Hard Rule

Do not fix an architectural problem during this task. Report its cause and
evidence first. Do not weaken comparisons, increase tolerance, change expected
values to match RTL, or substitute uniform vectors for a failing nonuniform
case.

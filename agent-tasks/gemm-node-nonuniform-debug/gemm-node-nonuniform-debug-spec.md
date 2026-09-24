# GEMM Node Application-Matching Nonuniform Debug Specification

Status: confirmed
Source: `docs/future_optim/gemv/gemm_improve/gemm_node_nonuniform_debug.md`
Confirmed: 2026-08-08

## Goal

Prove `hw/unittest/gemm_node_improve` against the deterministic nonuniform
input, weight, scale, and zero-point formulas used by
`tests/regression/fpint_gemm_ffn_hw/main.cpp` for both QDIR=0 and QDIR=1,
locate the earliest divergence, and validate passing behavior in XRT-VCS.

## Scope

- Preserve the current type-3 node tests as an independent baseline.
- Add an explicit `MAIN_CPP_NONUNIFORM` testbench profile capable of expressing
  the application's full QCOL `(kg,n)` and QROW `(k,ng)` scale/zero layouts.
- Check profile activation, representative source/tiled values, all real
  outputs, and final completion independently for QDIR=0 and QDIR=1.
- Diagnose a failure from source formula through tiled storage, TMEM, GEMM
  operands, arithmetic, and output reconstruction until the first divergence.
- Run existing QCOL/QROW suites and four fixed XRT-VCS application workloads
  only after the focused node cases pass.

## Authoritative Data and Arithmetic

```text
A[m,k] = fp16(1 + ((m+k)%3)/100)
W[k,n] = ((k*N+n)%7)-3

QDIR=0:
  scale[kg,n] = fp16(1 + ((n+kg)%3)/100)
  zero[kg,n]  = ((n+kg)%7)-3
  sum += A * (W-zero) * scale

QDIR=1:
  scale[k,ng] = fp16(1 + ((ng+k)%3)/100)
  zero[k,ng]  = ((ng+k)%7)-3
  sum += fp16_rne(A*scale) * (W-zero)
```

These formulas and rounding boundaries must match `main.cpp`; a uniform
substitute or weakened comparison is not acceptable.

## Classification Gate

- A proven local coding error such as a wrong loop bound, index, stride,
  offset, bit slice, signed cast, or packing order may receive the smallest
  correction and a focused regression.
- An incompatible layout/protocol contract, missing metadata, or any solution
  requiring architectural redesign must not be fixed in this task. Stop and
  report the expected/actual contracts, first-divergence evidence, affected
  interfaces, and why a local fix is insufficient.
- If classification is uncertain, treat it as architectural and report before
  changing production RTL.

## Acceptance

- Both focused `M=4,N=256,K=256,QBLK=32,WTRANS=0` node tests explicitly prove
  the application-matching profile is active, check all 1024 outputs, and pass
  with zero mismatches for QDIR=0 and QDIR=1.
- Existing QCOL and QROW node suites pass without replacing their vectors or
  relaxing their checker.
- XRT-VCS passes the application reference for QDIR 0/1 at M=4 and M=256,
  with N=K=256 and WLOAD=8.
- The final report records exact commands, environment, baseline/final
  results, sentinel evidence, root cause/classification, changed files, and
  remaining risks.

## Isolation

This is a separate correctness task from `agent-tasks/dma-optim`. Existing DMA
changes and `VX_dma_unit_misal.sv` must be preserved. This task must not alter
the confirmed DMA look-ahead architecture or silently absorb its status.

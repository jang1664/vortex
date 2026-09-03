# Vortex TVM Llama3-8B C1/C3 U55C Numerical Validation Report

## Acceptance oracle

The acceptance comparison is GPU versus Vortex only. References are generated on CUDA with TF32
disabled, deterministic algorithms enabled, and `CUBLAS_WORKSPACE_CONFIG=:4096:8`. A CPU run is an
explicitly labelled diagnostic fallback only and cannot satisfy an acceptance gate. The physical
runner rejects a reference whose metadata is not labelled `gpu` before opening XRT.

## Frozen workload

- Model topology: synthetic Llama3-8B, 32 decoder layers, GQA, asymmetric INT4 K/V cache.
- Backends: C1 (`fp16_tcu`) and C3 (`naive_gemm`, row-major W4A16).
- Sequence: one prefill followed by three decode steps in one process.
- Cases: S1 `(batch=1, prompt=1)`, S2 `(1, 7)`, S3 `(2, 1)`, S4 `(2, 7)`.
- Execution: bytecode VM for S1-S4 and compiled VM representative coverage for S1.

## Compiler/runtime fixes found by physical validation

### C1 rank-5 cache dequantization lifetime

The first C1 full-layer attempt exposed host heap corruption after redundant reshape
materialization around rank-5 cache dequantization. The compiler now emits direct rank-5 INT4 to
FP16 dequantization and skips rank-2 no-op dequant reshapes. Focused dequant, QK/PV, context,
prefill-layer, and decode-layer probes then passed, followed by a complete S1 canonical run.

### C3 quant-direction-N descriptor width

The first C3 attention-context failure had exactly columns 32-127 equal to zero for every head. The
same signature reproduced in the native `fpint_gemm_ffn_hw_naive` blackbox for
`M=1,N=128,K=8,QBLK=128,QDIR=N`; `N=32` passed repeatedly. Process restart, xclbin reprogramming,
and a managed user reset did not change the result. The compiler therefore compacts the C3 payload
and qparams into 32-column tiles and submits one row by one tile at a time into the logical output.
Standalone PV, softmax-to-PV, complete-layer checkpoints, and full S1 execution passed afterward.
No RTL, FSM, or xclbin was changed.

### C1 long-run batch-2 stability investigation

Two complete S3 attempts exposed an intermittent single-element zero in decode: the naive-allocator
run first failed at phase 1/layer 10, while the pooled-allocator run passed that boundary and first
failed at phase 1/layer 4 at a different coordinate. Each exact failing layer/input passed bit-exact
when replayed in a fresh process. An S4 pooled attempt similarly passed prefill layers 0-6 before a
layer-7 timeout, while the exact layer-7 input passed in a fresh process.

The scalar residual kernel first completed 512/512 fixed-buffer repetitions exactly. More strongly, the
entire S4 prefill layer 7 completed 16/16 repetitions in one VM/device process with one stable input
address, identical output-hash vectors, hidden relative-L2 zero, and no timeout. These results rule
out a deterministic residual or layer-7 arithmetic defect.

Fixed canonical hidden/KV buffers and exact pre-invoke readback did not remove the S3 symptom: a
third run passed prefill and decode-1 layers 0-20, then returned one zero instead of `-18.09375` at
batch 1/hidden 2591. The previous coordinates were hidden 2719 and 3935. A fourth address-recording
run failed at layer 3/hidden 3647 with the same single zero. Across all four failures the logical
hidden index is lane `mod 32 = 31`, while the failing layer and physical allocation move; all seven
KV outputs remain exact.

The fourth run's output address was `0xdd528000` (4 KiB aligned and disjoint from the fixed input).
Two immediate rereads of the resident device output were byte-identical to the first read, including
the same zero. This excludes an output-address alignment/overlap issue and a transient D2H
observation error. A longer production residual probe separately passed 100,000/100,000
alternating-input calls with exact input readback and two stable output hashes in 1525.51 seconds.
Input staging, the standalone residual arithmetic, and simple repeated DMA/launch are therefore
excluded. The first stage-localization reproducer passed 32/32 production-prefill warmups followed
by 32/32 decode iterations in one process. Every iteration compared 15 float checkpoints and seven
cache states with the GPU reference. All checkpoint hash vectors were identical across 32 changing
output-address vectors; the only non-bit-exact metric was the intentional masked-score calculation
at `9.84e-8` maximum relative error. Thus the reduced checkpoint graph does not expose a fixed
primitive defect. A closer follow-up uploads the full parameter archive and replays all 32 distinct
GPU canonical prefill inputs before repeating decode checkpoints, preserving more of the production
memory pressure and data sequence. Numerical thresholds remain unchanged, and failed attempts are
diagnostic evidence rather than accepted traces.

## Physical U55C results

All completed canonical rows below use GPU-recorded inputs at every comparison boundary. A trace is
written only after numerical, cache, finite-state, package/profile, and top-1 checks pass.

| Backend | Case | VM | Mode | Result | Notes |
|---|---|---|---|---|---|
| C1 | S1 | bytecode | canonical | PASS | 32 layers x 4 phases; every reported hidden relative-L2 was 0 |
| C3 | S1 | bytecode | canonical | PASS | 32 layers x 4 phases after N=32 tiling repair |
| C3 | S1 | compiled | canonical | PASS | representative compiled-VM coverage; hidden relative-L2 0 |
| C3 | S1 | bytecode | free-running x2 | PASS | one device open/process; identical phase logits hashes and tokens |
| C1 | S1 | compiled | canonical | PASS | representative compiled-VM coverage; hidden relative-L2 0 |
| C1 | S1 | bytecode | free-running x2 | PASS | one device open/process; identical phase hashes and tokens, zero retry/timeout |
| C3 | S2 | bytecode | canonical + free-running | PASS | irregular prompt/cache tail; phase-3 layer-0 relative-L2 8.64e-4, all other hidden checkpoints exact |
| C3 | S3 | bytecode | canonical + free-running | PASS | explicit batch-2 metrics and hashes; all canonical hidden checkpoints exact |
| C3 | S4 | bytecode | canonical + free-running | PASS | pooled VM allocation; batch-2 prompt/cache tails; old layer-21 poison did not recur |
| C1 | S2 | bytecode | canonical + free-running | PASS | all four phases in both modes; token 0; zero retry/timeout |
| C1 | S3 | bytecode | canonical + free-running | FAIL | four canonical attempts each lost one resident output element; fresh reduced probes pass |
| C1 | S4 | bytecode | free-running | FAIL | first attempt timed out in prefill layer 0; a fresh diagnostic rerun completed but does not erase the zero-timeout gate failure |
| C1 | S4 | bytecode | canonical | PASS | fixed inputs plus exact readback; all 128 layer hidden comparisons exact; top-1 `[0,0]` in all phases |

Completed S1 traces record one device open, one parameter upload, no CUDA initialization in the XRT
process, and `VX_READY_TIMEOUT_MS=300000`. C1 bytecode canonical phase latencies were approximately
2419, 2193, 2192, and 2189 seconds. C3 bytecode canonical phase latencies were approximately 26.3,
29.8, 29.9, and 30.4 seconds. Latency is observational and is not an acceptance criterion.

The final C1 S4 canonical job 4773 completed normally on BDF `0000:2a:00.1` with phase latencies
2875.14, 3072.41, 3075.90, and 3077.13 seconds. It used one device open, one parameter upload, 136
VM invocations, fixed device inputs, and exact pre-invoke readback. Fresh-process free-running
diagnostic job 4779 also completed normally on BDF `0000:3d:00.1`; cache lengths advanced exactly
7/8/9/10 and both batch rows generated `[0,0,0]`. This counterexample shows the earlier job 4766
timeout is intermittent, but the plan's zero-timeout/no-accepted-retry policy keeps the S4
free-running acceptance row failed.

## Regression status

- Focused C3/batched lowering tests: `8 passed, 2 skipped`.
- Full touched Llama application/compiler/evidence test set: `65 passed, 43 skipped`.
- Existing C4 PyTorch export/model host regressions: `27 passed`.
- Pinned C4_v3 S1/fused one-layer U55C smoke: `1 passed` (`run=1.97 s`).
- Evidence collector without the completeness gate: completed and reported `C1=FAIL`, `C3=PASS`.
- Evidence collector with `--require-complete`: expected exit `2`, with three explicit missing C1 rows.
- `git diff --check`: pass at the recorded checkpoint.

The C4 smoke retains its existing eager CPU comparison and is a non-gating regression only. No CPU
result is included in the C1/C3 numerical acceptance evidence.

## Artifacts

Large packages, parameter archives, GPU reference NPZ files, mismatch captures, and raw traces stay
under TVM `build/`. The companion compact evidence JSON records immutable identities, hashes, device
metadata, coverage, numerical maxima, exact trace paths, and hash-verified failed attempts. Missing
successful rows remain explicit rather than being synthesized from diagnostic counterexamples.

## Current conclusion

C3 passed the full S1-S4 canonical/free-running GPU-versus-Vortex matrix, persistent S1, and
representative compiled VM. C1 S1, S2, and S4 canonical pass, but C1 fails the backend-level gate
because S3 has four failed canonical attempts and the first S4 free run had a real device timeout.
Reduced and full-resident checkpoint probes pass, and fresh S4 canonical/free processes also pass,
so the remaining defect is sensitive to the production graph's allocation, lifetime, device state,
or launch sequence rather than a deterministic checkpoint primitive. The result is therefore
`C3=PASS`, `C1=FAIL`; no CPU evidence contributes to either verdict.

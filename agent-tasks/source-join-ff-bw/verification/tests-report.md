# Source-join and metadata verification

Status: PASS. All 58 VCS cases completed on 2026-09-17. All 16 standalone FSM oracle checks and all 16 integrated transcript comparisons passed.

## Changes

- `naive_source_join`: one-cycle input event latency; pending-event quiescence; reset with pending closure or all four read completions; consecutive and simultaneous engine completions; simultaneous closure/completion; both closure/read arrival orders; interleaved two-buffer ownership; minimum and maximum descriptor counts; no-reset invocation reuse.
- Expected-fatal cases: duplicate completion, foreign generation, duplicate closure, zero work ID, zero/too-large/high-bit count, zero closure generation, mismatched simultaneous closure/read generation, completion outside closure count, early restart with ownership and with a pending event. A negative case passes only with the specific DUT assertion, never a generic failure or the testbench timeout.
- `naive_meta_fsm`: geometry-derived width assertions (MXU16: 4/4/7/3/3; MXU32: 3/3/5/2/2). The frozen independent `p3-fsm-check.py` and `p0-contract.py` remain unchanged.
- `naive_meta_control`: optional read completion at executor retirement; assertions preventing idle/done with source events pending. Compare complete CMD/CLOSE transcript against the independently verified standalone FSM for matching shapes.

## Executed matrix

For each MXU16 and MXU32 geometry: 13 source-join cases, eight FSM cases, eight integrated-control cases (29 per geometry; 58 total). FSM shapes include M=1/K=MXU/N=1, full 128x128, N=127/129 tails, K=128+MXU, M=K=N=256, K=N=512, and QROW=WTRANS=1. Integrated cases repeat minimum/full/tail/layout with source completion at acceptance and retirement.

Runs use the existing configured XLEN64 build, VCS, `tools/verify_rtl.py`, and `/usr/bin/gcc`/`/usr/bin/g++`. MXU16 sources the exact target TCU base PnR config; MXU32 sources the existing naive TH16/b32/tcol32 config. Results and full config defines are retained under `verification/unittests`.

The obsolete `gemm_naive_meta_fsm` suite references a missing testbench; no infrastructure was added or changed. Existing `naive_meta_fsm` plus its frozen task oracle provides the independent command-stream validation.

## Results

| Geometry | Join positive | Expected DUT fatal | FSM + independent oracle | Integrated control + transcript | Total |
|---|---:|---:|---:|---:|---:|
| MXU16 (target ACC/TCU config) | 1 | 12 | 8 | 8 | 29 |
| MXU32 (existing TH16/b32 config) | 1 | 12 | 8 | 8 | 29 |

All 24 negative runs returned `sim_fail` from `verify_rtl.py` and contained the
required DUT assertion. No generic timeout, missing-assertion sentinel, or
compile failure was accepted. All 34 positive VCS runs passed. Width messages
confirm 4/4/7/3/3 and 3/3/5/2/2 as specified. Both geometries covered count 1,
maximum 64/16, N tails, K tails, and both index rollovers through independently
checked command sequences.

The integrated CMD/CLOSE transcripts matched the corresponding oracle-verified
standalone transcripts exactly in both source-completion modes. Endpoint
checks in the integrated fixture also passed with its default five-cycle
notification backpressure.

## Initial oracle failure and correction

The first MXU16 minimum case passed VCS but failed the frozen `p3-fsm-check.py`
assertion at line 64. That oracle assumes the legacy LMEM PSUM/final addresses;
the exact target config already selects `GEMM_NAIVE_USE_ACC_MEM`, which uses
ACC offsets and a different final stride. This predates the requested RTL
change and was a reference scope mismatch, not a DUT failure.

`check_acc_stream.py` retains the frozen oracle and contract unchanged. For
ACC runs it independently computes Input offsets from each frozen microtile's
column index and geometry, validates both ACC addresses and final stride,
then translates only a1/final/final_stride into the legacy representation for
the unchanged oracle. Raw `sim.log` and translated `oracle-adapted.log` are
retained separately. All ordering, work IDs, loads/stores, source identities,
closure counts, and other command fields pass through unchanged. MXU32 uses
the original oracle directly without translation.

## Reproduction and retained evidence

Run `python3 agent-tasks/source-join-ff-bw/verification/run_unittests.py` from a
configured workspace. It sources each config and invokes `tools/verify_rtl.py`
for every case. `--reuse-existing` is only for resuming the same unchanged
RTL/test run; normal execution recompiles/reruns all cases.

- `unittests/results.json`: 58 case statuses, arguments and required diagnostics.
- `unittests/source-sha256.json`: tested RTL, testbench, runner and oracle identity.
- `unittests/mxu*/config.txt`: exact sourced config and compiler defines.
- Per-case `compile.log`, `sim.log`, and `verify.json`: original VCS evidence.
- FSM/integrated `oracle.json`: all 32 independent/transcript check receipts.

`git diff --check` passed for test changes. No blackbox runs, shared build
configuration changes, or RTL edits were performed by this verification task.

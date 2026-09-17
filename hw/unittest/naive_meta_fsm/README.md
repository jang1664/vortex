# Metadata-only naive FSM command-stream test

Use a configured XLEN64 build, source the naive TH16 configuration, and invoke
`tools/verify_rtl.py unittest --path ABSOLUTE_BUILD_PATH --sim vcs`. Optional
`--extra-sim-args` selects `+M`, `+K`, `+N`, `+QROW`, and `+WTRANS`. Repeat with
the matching MXU16/MXU32 configuration. This is a VCS `new_tb` request.

The actual staged `VX_gemm_fsm_naive_meta` generates all commands. The fixture
holds invocation readiness low initially, backpressures command emission on a
fixed 6-of-13-cycle schedule, checks stable held commands, verifies real opcode
and total command/closure counts, and delays controller completion before
allowing invocation reuse. Host and LMEM addresses intentionally exceed 4 GiB.

Run `agent-tasks/gemm-naive-improve-baseline/p3-fsm-check.py` on the retained
simulation log with matching shape/geometry/layout arguments. It compares the
actual transcript with the frozen `p0-contract.py` N-fast microtile stream and
separately checks external LOAD/STORE addresses and byte counts, quant mapping,
source generation, register-install and writer-consume targets, Input O owner,
terminal G1 versus ordinary G0, STORE O notification, SRC_FREE refill waits,
and producer-closure counts. A VCS PASS alone is not an oracle PASS.

Iteration 1 failed compilation because the new Makefile referenced a wrongly
named source file. Iteration 2 corrects the file list; production FSM logic was
not changed. Seven geometry/workload cases pass both VCS and the transcript
oracle, with evidence under `p3-verification/fsm-iteration2` in the task folder.
The primary agent ran deterministic verification after subagents hit their
usage limit; this does not claim a separate independent RTL review.

Scope limitations: this fixture tests the producer, not executor eligibility,
installed payload, actual memory visibility, source-read completion, or
integrated numerical/latency behavior. Producer closure is explicitly not a
SRC_FREE event. The staged FSM remains disconnected from the legacy node until
the metadata executors and owned source/physical completion joins are wired.

The geometry-width regression asserts knum/nnum/product/index widths of
4/4/7/3/3 for MXU16 and 3/3/5/2/2 for MXU32. Run minimum-count shapes
(M=1, K=MXU, N=1), a full macro tile (M=4, K=N=128), N=129 tails,
and multi-macro-tile K/N=256 or 512 cases through the independent oracle.
These exercise count extrema, ceiling division and both index rollovers
without changing the frozen command-stream reference.

For `GEMM_NAIVE_USE_ACC_MEM`, use
`agent-tasks/source-join-ff-bw/verification/check_acc_stream.py --acc` with the
same arguments. It validates ACC Input offsets and final stride against the
frozen microtile geometry, then translates those three fields to the legacy
LMEM representation for the unchanged oracle. The raw transcript is retained;
all other fields pass through unchanged.

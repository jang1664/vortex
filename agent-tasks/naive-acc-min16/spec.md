# Naive ACC minimum-16 buffering — confirmed

Compare the three current ACC configurations (LMEM16/BW64, LMEM32/BW64,
LMEM32/BW256) against configurations with every scoped response slot/FIFO
capacity at least 16. User explicitly includes per-lane input/scale/zero
response FIFOs. Keep capacities already above16 unchanged. Do not tune
cache internals, command queues, transport skids, ACC capacity or topology.

Reuse existing DMA modules and their parameters. Expose currently fixed naive
input/qparam response slots and lane FIFO depths with naive-only defines.
Preserve current defaults exactly: input16/8, qparam8/4. Keep unused generic
I/SZ knobs unchanged because their defaults do not match the actual executors.
Use existing W/O and external DMA/splitter knobs. Allow FIFO16 in the existing
qparam transport and derive occupancy widths from response slots.

Profile: external DMA OUT32; splitter BUF16; W16; O16; input16/16;
scale16/16; zero16/16. Response reorder remains enabled only for BW256.
Default ACC configs stay unchanged. No improve RTL changes or synthesis.

Verification: existing unit fixtures with capacity, reorder, backpressure and
slot reuse coverage; current/min16 numerical VCS comparisons for M4/M256,
K=N512, q32, qdir0, transpose0, repeat1; improve RTL identity and unchanged
M4/M256 cycles. Reuse existing configured-build run.py/ci/run_black.sh flow.
Keep raw evidence in distinct run labels. Compare GEMM/core cycles and update
the latency document with a separate controlled current/min16 table.

## Follow-up decisions

The user subsequently requested input/scale/zero lane FIFO4 with the minimum16
slot profile retained. All six M4/M256 runs matched FIFO16 GEMM/core cycles.
The user then requested promoting this validated profile into all three named
`_acc.sh` configs. Historical experiment wrappers retain their original settings.

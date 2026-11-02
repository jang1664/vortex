# CMD_PERF ordered inflight ledger repair

## Root cause and scope

The original failure report and failed trace are preserved in
`cmd-perf-failure-report.md` and `logs/simv_perf_fp32_m4_n256_fail.log`.
At 217515000 ps, a second input-child command was accepted before the previous
command completed. This is valid: `g_inorder_child` permits concurrent commands
for input, weight, scale, and zero-point children and stores their completion
metadata in ordered depth-4 FIFOs. The simulation ledger instead stored one UID
per child and incorrectly rejected that legal dispatch.

Only the `ifndef SYNTHESIS` / `ifdef DBG_TRACE_GEMM_CMD_PERF` lifecycle ledger in
`hw/rtl/core/gemm/VX_gemm_ctrl.sv` changed. Per-child UID FIFOs now mirror actual
inflight capacities and completion order. Retirement removes the old head before
issue appends a new tail, including when both events occur on one edge. Children
outside input/weight/scale/zero-point retain the original single-active assertion;
the output metadata FIFO's physical capacity of two does not authorize a second
active output command. Tagged DMA tracking is unchanged.

The ledger checks underflow, capacity, pre-edge empty/full agreement with the real
FIFOs, completion UID/child/notify/work-sequence agreement, duplicate completion,
and complete drain at both invocation completion and the next configuration.
Existing emitted/issued/completed equality, timestamp ordering, overlap bounds,
and incomplete-command assertions remain. DMA tag drain checks are explicit.
No command timing, functional datapath, workload, or tolerance changed.

## Verification request

- test_type: blackbox
- test_path: tests/regression/flash_attn (configured build `build_c4_sram_perf`)
- test_params: unchanged `-r -f -m 4 -n 256`
- sim_tool: vcs, xrt-vcs-sim
- changed_files: `hw/rtl/core/gemm/VX_gemm_ctrl.sv`
- orchestration: main agent dispatches verification; implementation agent ran no simulations.

Use the exact config, compiler paths, selective trace defines, DEBUG=3, wrapper
command, and kernel preservation checks in `cmd-perf-failure-report.md`. Preserve
the failed trace and wrapper log before writing new artifacts. Keep all assertions
enabled and do not add PIPELINE trace or change the application workload.

Require:

1. Full application PASSED and exit 0 with unchanged numerical and DMA/AFU traffic
   audits. All four GEMM invocations in this application must complete without a
   reset between them.
2. Exactly one `GEMM_CMD_PERF_SUMMARY` per invocation, with
   emitted = issued = completed, incomplete = 0. Cross-check each summary against
   its unique `GEMM_CMD_TIMELINE` UIDs and class counts; every UID must satisfy
   emit <= issue <= done and have one completion.
3. Reconstruct per-child active intervals from timeline issue/done values using
   half-open intervals [issue, done). Require observed child-0 concurrency > 1 to
   prove the originally failing case was exercised. Check maximum local inflight
   counts <= 4 for children 0--3 and <= 1 for output child 4, and that local
   completions retain issue order. Report maxima per job and child.
4. Report observed same-edge issue/completion per child from timeline timestamps;
   do not claim dynamic coverage if this workload does not exercise a boundary.
   The implementation handles simultaneous events by retiring before enqueueing;
   pre-edge occupancy checks compare against the physical FIFO before either update.
5. Keep `compute_pipeline_cycles` separate from command service, overlap, and
   software GEMM wait cycles. The repaired ledger can have multiple simultaneous
   compute-arm command intervals, so summing service times is not pipeline time.

## Synthesis-selected identity evidence

`logs/cmd_perf_ledger_identity/VX_gemm_ctrl.before.sv` is the exact pre-edit source
snapshot (SHA256 d05776a39eafc79c2559fba748141138a6e7fbf30b2a6c633ac0b103839e06d8).
`logs/cmd_perf_ledger_identity/manifest.json` records the full reproducible
`verilator -E -P` invocation, source hashes, and selected-output hashes.
The C4 fusion config includes XLEN64, SYNTHESIS, and DBG_TRACE_GEMM_CMD_PERF.
Before/after selected output is byte-identical, SHA256
`e86fee39d84dcbe6c521bb2bf4bfb2c4d100bcd5fc015f2be7ab70502a50939e`.
`-P` removes preprocessor line/whitespace markers; no postprocessing was applied.
This proves the changed controller's synthesis-selected RTL is unchanged under
this config. It is not a new synthesis result or a broad structural comparison.
The running FPGA r2 build and its captured source manifest were not modified.

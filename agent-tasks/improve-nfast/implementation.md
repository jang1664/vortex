# Improve microtile N-fast implementation

Only `hw/rtl/core/gemm/VX_gemm_fsm.sv` was changed for this experiment. Existing uncommitted naive and configuration edits are preserved.

## Traversal

For a macro tile with eight N slices and eight K slices, the old `(nb, kb)` sequence was `(0,0), (0,1), ..., (0,7), (1,0), ...`. The new sequence is `(0,0), (1,0), ..., (7,0), (0,1), ...`, matching the naive FSM's microtile increment at `VX_gemm_fsm_naive_meta.sv:337`. Each Input ARM still streams all effective M rows.

The command construction block now increments `nb` first and advances `kb` when N wraps. The last microtile is detected by the next K coordinate reaching the K extent. Linear work identifiers are `kb * N_microtiles + nb`, preserving monotonically increasing issue-order tokens for source scheduling, W/S/Z notifications, and Input version matching. The separate scheduler-only pending-work block uses the same formulas. Debug next-command coordinates also follow the new order.

## Preserved behavior

- Macro tile traversal remains K-fast, then N, then M for improve. Naive's macro traversal is different and was not copied.
- TMEM physical tile-major layout remains `[nb][kb]`. Addresses use explicit coordinates, not linear issue identifiers, so changing traversal does not require software repacking.
- Accumulator slices remain disjoint per N microtile. Each slice receives increasing K contributions, retaining arithmetic accumulation order for that output.
- Global K still controls first-contribution initialization. Final writeback notification still belongs to the final microtile of the final K macro tile, before output copies.
- W/S/Z register double buffering, exact dependency versions, command queues, pipelines, and arithmetic widths are unchanged.

`git diff --check` passed. No simulation or synthesis was run by the implementation agent. Blackbox verification is delegated through the parent.

## Test request

- test_type: blackbox
- test_path: tests/regression/fpint_gemm_ffn_hw
- test_params: TH16/MXU16, M=4 and M=256, K=N=512, QBLK=32, qdir=0, wtrans=0, repeat=1; same improve configuration and app arguments as the retained baseline captures.
- sim_tool: vcs, via `ci/run_black.sh xrt-vcs-sim` from a configured build directory after sourcing the improve config.
- changed_files: [hw/rtl/core/gemm/VX_gemm_fsm.sv]
- notes: retain FSDB, require deterministic application PASS, extract GEMM/core cycles, and compare each shape against the matching existing improve K-fast baseline. Confirm N-fast command coordinates from the captured waveform or command debug events. Do not add reset microtests or synthesis.

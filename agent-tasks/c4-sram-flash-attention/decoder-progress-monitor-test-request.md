# Sparse full-decoder progress monitor handoff

- test_type: new_tb (passive include), then blackbox smoke
- test_path: sim/xrtsim_vcs and configured llama_decoder_C4 build
- sim_tool: xrt-vcs-sim through configured `ci/run_black.sh`
- author execution: none; source hierarchy and inactive-guard text inspected
- production RTL/floorplan/kernel edits: none
- shared simulation TB/Makefile edits: not applied; wait for root after C160 terminal

Frozen candidate files are `monitor_candidate/decoder_progress_monitor.svh`
and `monitor_candidate/install.patch`. Root must copy the include into
`sim/xrtsim_vcs/decoder_progress_monitor.svh` and apply the two small installation
hunks after the active C160 source snapshot is no longer in use. Original
TB/Makefile snapshots, candidate files, and hashes are under
`logs/decoder_progress_author/`. Do not edit or rebuild any live simulation.

Enable `-DC4_DECODER_PROGRESS`, default interval50000 simulated clocks. Optional
`-DC4_DECODER_PROGRESS_INTERVAL=N` must be positive. The monitor emits direct
`$display` lines and requires no debug trace level or broad TRACE flags. It
rejects `DBG_TRACE_GEMM_CMD_PERF`: that bounded4096-record/per-record-loop ledger
is inappropriate for the full FFN workload. Keep all existing DUT assertions.

## Actual hierarchy and meanings

Core root:
`dut.vortex_axi.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core`.
This is the same current C4 hierarchy used by existing publication/early-return
TB includes. Source declarations inspected:

- `VX_core.sv:69,74`: `sched_csr_if.cycles`, `commit_csr_if.instret`, and core busy/reset.
- `VX_gemm_node.sv:1691`: `u_VX_gemm_ctrl`; production child issue/completion vectors,
  invocation_active and active_entry_id are sampled without debug counters.
- `VX_gemm_ctrl.sv:308`: `u_VX_gemm_fsm`; state, current tile/MT/NT/KT and microtile indices.
- `VX_gemm_node.sv:1401`: `u_tmem_dma_ctrl`; pending count, state, actual cmd_enqueue
  and logical_complete events.
- `VX_gemm_node.sv:34`: four `dma_axi_m` interfaces; actual AR/AW/R/W/B handshakes.
- `VX_gemm_node.sv:389`: `u_sram_dma.state_q`; physical fusion TMEM request/response
  handshakes and LMEM write-commit input.
- `VX_afu_wrap`: ap_idle/ap_start acceptance, state, done_raw, pending-write-empty
  and cache-drain flags. No signal is driven or forced.

Global cycle and launch serial persist across kernel resets. All observed-event
counters reset with the real core reset, matching the CSR epoch. The monitor
counts child issue/completion handshakes, HBM DMA enqueue/completion events,
physical bridge requests/responses/LMEM commits, and per-channel AXI
handshakes. It allocates only fixed64-bit counters: no per-command records,
growing queues, scan over command history or4096-command cap.

The printed DMA `accepted` field specifically counts `cmd_enqueue`, which
excludes `prepared_release_accept`; `completed` counts `logical_complete`,
including prepared releases. They are different event populations, not a
balanced command scoreboard. A full GEMM can legitimately show more completions
than enqueues. Compare their changes over time, with retirement/tile observations,
without diagnosing a failure from their difference. The running monitor binary
is unchanged; this qualification comes from the current DMA controller source.

Each snapshot prints one core/controller line, one DMA/drain line, one unknown-observation line and four AXI
counter lines. Reasons are accepted launch, core-reset release, first AFU done,
or the periodic global-cycle interval. Values are pre-NBA at a shared edge;
there can be a one-edge difference from counters updated on that same edge.
No monitor pass/fail watchdog diagnoses hangs. Busy alone is not progress;
counter/retirement/tile changes provide observations, and a stationary sample
does not by itself establish deadlock. Host BEGIN/DONE lines remain the authority
for operation names and final workload/numerical success.

A fixed sticky counter records cycles with X/Z on any monitored handshake bit,
plus first/last observed global cycles, and survives kernel resets. Sampling
is disabled during asserted core reset; unknown reset/control after external
reset release is itself recorded. `counts_qualified=1` means unknowns occurred
and event totals may be incomplete; it does not declare a DUT failure or hang.
This includes idle handshake bits, so it is deliberately conservative. The
snapshot calls `$fflush()` to make sparse evidence visible during a live run.
Prior source/request/identity are preserved under `logs/decoder_progress_author/v1/`.

## Required independent checks

1. Confirm the installed patch is only the guarded include and Makefile dependency;
   production files retain their frozen hashes. `source_identity.json` proves
   only literal text identity after removing the new inactive block. Independently
   preprocess macro-off before/after and require identical selected SV; do not
   describe the author's text check as elaboration evidence.
2. Configure a fresh isolated C4 fusion build, source the proper config in bash,
   use `/usr/bin/gcc` and `/usr/bin/g++`, omit `--debug` and all broad tracing,
   set `-DDISABLE_FSDB -DDEBUG_LEVEL=0 -DC4_DECODER_PROGRESS`, and unique SHM.
   Do not add CMD_PERF. Compile the actual VCS hierarchy; compilation must reject
   unsupported netlist/selftest/naive modes rather than accidentally observe a
   different design.
3. Run a finite small resident attention smoke (such as existing M4/KV256) through
   configured `ci/run_black.sh xrt-vcs-sim`. Require existing application numerical
   success, launch/reset/sample/done snapshots, increasing retirement and real
   DMA/bridge counters, and no DUT assertion failures. Compare the existing
   workload's core/GEMM cycle results with its matching macro-off baseline or a
   fresh same-source baseline. Report any differences and distinguish simulator
   host scheduling effects from changed device behavior; root permits qualified
   differences from asynchronous host scheduling. Numerical gates are unchanged.
   Confirm live sparse output visibility and report the unknown witness. A
   testbench-only synthetic unknown-signal probe may verify sticky counter
   semantics independently; never force X into a real DUT run merely to test
   this observer. Keep unknown counts visible in final smoke/full-run reports.
4. Review output size/cadence and fixed monitor state. Ensure no force, deposit,
   DPI DUT write, altered ready/valid, or disabled DUT assertion is introduced.
   Numeric validation still comes from the original test, not these counters.

Only after prerequisites pass may the independent verifier start the separately
authorized new full resident regression with predeclared21600000ms per-operation
and86400s outer bounds. Use a fresh build/result directory and preserve the old
resident48879 timeout unchanged. This is a new bounded experiment; it does not
retroactively extend that run or prove its timeout was a hang. Full36-operation
resident scope (legacy has38), all model dimensions and final independent CPU numerical gates remain
required. Full legacy session5987 continues unchanged with its original bounds.

# Existing progress register and controller trace boundaries

Read-only archived RTL audit, 2026-09-08. All paths below refer to the archived
files selected by `archived-document-guarded-add/rtl-library`, not current RTL.

`VX_gemm_node.sv:23` sets `OUTPUT_PROGRESS_REG_IDX=43`; line745 selects it as
the descriptor register bank's hardware-write target. `VX_gemm_ctrl.sv:802`
drives update-valid directly from `output_store_done_i`; line805 supplies the
previous count plus1. Count resets on configuration acceptance. Node line734
connects the signal to `VX_gemm_tmem_dma_ctrl.store_done`.

Therefore this existing register reports output-store completions, not input
load progress, K-tile progress, compute occupancy or a timestamp. Reading it
more often cannot directly split input DMA and computation. Additional MMIO
polling would itself perturb software timing. No hardware polling change was
made based on this inspection.

For VCS only, `reference_work_observer.sv` binds the archived controller and
records configuration/done/output-store events and per-child issue/retire
vectors. Child mapping from the controller's explicit indices and connections:
0=input read,1=weight,2=scale,3=zero point,4=output,5=DMA. These are controller
queues, not six independent physical HBM ports. Busy means an inflight queue is
nonempty; queued means a command queue is nonempty. Neither proves CPU stalls
or memory-controller contention. Event trace cap16384 must be checked before
treating the log as complete.

Separate `archived-document-work-trace` stage uses the three guarded vendor
exceptions and approved repo RAMs, with otherwise archived DUT and current HBM
backend. Build76622 completed normally. Build log:
`build_hbm_reference/sim/xrtsim_vcs/work_trace_build.log`.
The observer is non-driving; matching output/cycles to the observer-free run
must still be checked. Acceptance executables and original Makefiles untouched.

The standard long-K benchmark replay completed successfully:11394 cycles,
6577 instructions, all outputs PASS, matching the observer-free guarded-add
run. Within-run executable/manifest/program hashes match. Session92833 is
terminal and launch links restored.

Trace contains1287 records, below the16384 cap. Configuration accepted at
96055000ps; the single observed output-store completion occurs at138995000ps;
controller done handshake at139025000ps. Configuration-to-done is4297 kernel
cycles at100MHz. For this case the progress register has only one output event
near completion, confirming its limited ability to localize the earlier wait.
Do not equate this hardware-controller boundary to the separately instrumented
software wait snapshots; those came from a different binary.

Raw evidence: `build_hbm_reference_document/work_trace_longk_1{,_simv}.log`
and `work_trace_longk_1_before.sha256`. Next parse per-child issue/retire pairing,
check balanced counts, and quantify overlap from this event sequence before
attributing any interval to memory. No corresponding hardware internal trace
exists in the current evidence.

## Balanced outstanding-time analysis, 23:59 KST

`inspect_work_trace.py` validates a single complete invocation, binary-only
vectors, monotonic100MHz event timestamps, uncapped record count, nonnegative
outstanding counts and balanced final issue/retire counts. At every event it
cross-checks reconstructed outstanding bits against the actual pre-edge busy
vector. It integrates post-event counts to the next event; it does not assume
individual DMA completions are FIFO ordered or pair individual transactions.
Five synthetic tests cover overlap/simultaneous issue-retire and rejection of
incorrect busy state, unknown bits, missing completion and reversed time.

All checks pass for the1287-record captured invocation:

| Child | Issued = retired | Peak outstanding | Cycles with any outstanding |
| --- | ---: | ---: | ---: |
| Input read | 256 | 3 | 4119 |
| Weight | 256 | 2 | 3990 |
| Scale | 256 | 2 | 4085 |
| Zero point | 256 | 2 | 3990 |
| Output | 1 | 1 | 36 |
| DMA | 129 | 7 | 3419 |

Input-read and DMA outstanding intervals overlap3286 of4297 invocation cycles.
These child durations overlap and must not be summed as independent costs.
Counts include controller waits, and archived controller source permits DMA
prepare before logical issue, so even “no outstanding DMA command” does not
prove no memory activity. No critical-path attribution follows from occupancy
alone. Machine evidence: `work-trace-results.json`, including exact mask-time
distribution and input-log hash.

Next correlate actual AXI accepted bytes/response timing with source readiness
and input-consumption events. Compare the observed hardware wait gap only at
boundaries that existing hardware can report; do not equate this VCS occupancy
trace with unmeasured hardware occupancy or add switch contention by assumption.

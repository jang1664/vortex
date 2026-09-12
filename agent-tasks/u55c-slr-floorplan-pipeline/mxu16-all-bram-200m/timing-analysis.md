# Critical paths in the completed 200 MHz target experiment

## Scope and clock interpretation

This is a read-only analysis of `spread_v1`, completed 2026-09-11, using
`level0_wrapper_postroute_physopt.dcp`. No synthesis, placement, routing, or RTL
changes were performed for this analysis. All current RTL hashes match the
run's source manifest.

Vitis reports an achieved kernel clock of 103.2 MHz. The archived timing report
uses a **10.000 ns reference period** for `clk_kernel_00_unbuffered_net`; its
worst kernel setup slack is **+0.312 ns**. The period less that slack is
9.688 ns (approximately 103.22 MHz), consistent with Vitis's frequency result.
This calculation explains the reported result; it is not an independent
physical signoff at an arbitrarily changed clock.

The whole-design WNS of +0.003 ns is from the fixed-platform
`dma_ip_axi_aclk_1` clock, including a hidden RAMB36E2 path. It is **not the
kernel path that limits GEMM frequency**, and should not drive changes to our
DMA RTL. The archived report contains only ten same-clock kernel setup paths,
so a separate DCP extraction requests 200 global paths and up to thirty paths
per source block. Extraction completed successfully: 200 global paths plus
330 paths across eleven source groups, 530 samples including overlap. Such
samples are not an exhaustive list of all timing paths. FSM paths are included
under `ctrl.rpt`; an initial optional `u_fsm` filter matched no cells because the
actual instance is `u_VX_gemm_fsm`, and that redundant filter was removed from
the reproduction script.

## Primary issue A: operand destination selector fanout

Original timing report: `hw_bb_locked_timing_summary_postroute_physopted.rpt:2045`.

`VX_opc_unit.pipe_reg2[172]` -> `gpr_rd_opd_st2` -> operand update mux ->
`opd_buffer_st2[0][462]`.

- Slack +0.312 ns; data delay 9.005 ns.
- Logic 0.201 ns; routing 8.804 ns (97.768%); one LUT5 level.
- The selector net has fanout 2563 and contributes 8.732 ns by itself.
- Launch register location `SLICE_X32Y293`; destination `SLICE_X85Y388`.
  Coordinates alone are not used here to assert a particular SLR crossing.
- Other nearby endpoints include operand bits463,467,476,481,511 and
  `opd_buffer_st2[1][451]`: these are instances of the same problem, not seven
  independent fixes.

RTL in `hw/rtl/core/VX_opc_unit.sv`:

- Line206: `pipe_reg2` width; lines213-214: registered read-valid/operand selector.
- Line220: start from the saved partial operand vector.
- Lines221-224: each GPR physical read-array result uses a variable index to
  choose which architectural source-operand vector it overwrites.
- Lines229-232: clear on reset/completed output; otherwise capture the merged vector.
- Lines279-298: synchronous GPR RAM read stage whose data must stay aligned
  with any selector change.

**Preferred fix:** predecode the selected source operand into one-hot write
enables before `pipe_reg2`, and register lane-group-local copies using the same
stage advance/reset conditions. Use static per-operand/per-lane assignments
instead of a single wide variable-index update. This need not add a pipeline
cycle. Verify that synthesis does not merge the local copies back into a global
high-fanout control; use narrowly scoped preservation only if required by evidence.

Preserve the original loop's overwrite precedence if two GPR read arrays select
the same operand, collision accumulation, and output backpressure behavior.
Merely inserting an FF on the existing global selector does not solve its
fanout and can misalign it with the RAM data.

## Primary issue B: scheduler priority computation to request launch

Original report lines2429 and2633:

`u_microtile_readiness_scheduler.head_r[1]`
-> scoreboard match/age selection -> descriptor progress selection
-> remaining-beat/ETA arithmetic -> deadline/priority classification
-> LDMA priority/urgency hold-or-live mux
-> `u_weight_req_reservation.u_slr.u_request.u_launch` payload capture.

- Representative slack +0.334 ns, delay9.060 ns, logic2.519 ns, routing6.541 ns.
- 28 levels, including9 CARRY8 cells; alternate launch-buffer endpoint has27 levels.
- This is a priority/urgency sideband path, not a new weight-address multiplier
  or a combinational traversal through the SLR TX/RX registers.
- Synthesis moves/renames logic across hierarchy. A name containing
  `source_priority_hold_r` is not proof of a register boundary in the path;
  many such nodes in this report are LUT/CARRY logic.

RTL correspondence:

1. `hw/rtl/core/gemm/VX_microtile_readiness_scheduler.sv:169`: rotate search
   order using `head_r + offset`; lines170-178: first matching live work sequence.
2. Same file:183: select matched entry fields; :206: request/response progress
   predicates; :297: matched input-admission state.
3. `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv:428`: select total/request/response
   counters by the current fetch descriptor. These counters feed the scheduler.
4. Scheduler:305-315: 34-bit subtractions, additions, install latency and wait horizon.
5. Scheduler:322-341: distance and ETA comparisons; :355 and:388: Input/Weight priorities.
6. `hw/rtl/core/gemm/VX_gemm_ctrl.sv:250`: forward priorities to the subsystem.
7. `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:2100`: Weight priority hold/live mux;
   :2104: urgency filtering. Input has the analogous mux at:769; side operands at:1432.
8. `hw/rtl/mem/VX_tmem_subsystem.sv:554`: Weight reservation instance;
   :1375: pack priority, urgency, and work sequence as request sideband.
9. `hw/rtl/mem/VX_slr_mem_bus.sv:33`: combine sideband and request;
   `hw/rtl/libs/VX_stream_transport.sv:33`: capture in the local launch EB2.

**Preferred changes, in order:**

- Algebraically collapse `(total-requested)+(requested-responded)` into
  `total-responded`, retaining the pending/not-pending semantics and arithmetic
  width. The existing progress invariant is asserted in
  `VX_gemm_stream_dma_queue.sv:822` (`responded <= requested <= total`).
- Compute residual progress independently of scoreboard matching. Use static
  per-entry work-sequence comparisons and a balanced selection/age network
  instead of rotating a wide record before comparing it.
- Because ETA is compared with a four-bit occupancy, consider an equivalently
  saturated small-domain comparison, not an unjustified truncation of the real
  descriptor counters. `BANK_WAIT_BOUND` is30 in the default configuration
  (six requesters times five accepted-grant intervals), larger than the eight
  Input slots; prove which guard terms are constant under valid-state invariants.
- If a cut is still needed, register the priority decision with its request/work
  identity before presenting a new request. Preserve first-presentation urgency
  guarantees and stall stability. Do not register only priority while letting a
  different descriptor's valid/address advance, and do not add a register after
  the existing launch EB2: that leaves the reported long cone unchanged.

Priority changes can affect performance even when memory contents remain correct.
Compare exact-config xrt-vcs-sim GEMM cycles with `--perf 3`, plus request
backpressure, descriptor overlap, starvation, and stalled-priority assertions.

## Broader path inventory

All slack values below use the archived kernel clock's10ns reference period.
Rank by slack, not data delay alone: clock skew, uncertainty, and endpoint setup
time differ. Rows taken from source-block reports expose secondary bottlenecks
that are not all in the global top200. Similar bits and the two EB2 storage
registers are grouped rather than treated as independent fixes.

| ID | Representative path | Slack ns | Data / logic / route ns | Levels | Evidence file:line |
| --- | --- | ---: | --- | ---: | --- |
| A | Operand selector -> saved operand vector | 0.312 | 9.005 / 0.201 / 8.804 | 1 | kernel_top200.rpt:16 |
| B | Scheduler head -> Weight request priority capture | 0.334 | 9.060 / 2.519 / 6.541 | 28 | kernel_top200.rpt:464 |
| C | FSM mt_dim -> Input tile address -> command rs2 | 0.398 | 9.311 / 4.126 / 5.185 | 26 | ctrl.rpt:558 |
| D | TMEM DMA decode -> chunk-beat capture | 0.467 | 9.120 / 2.296 / 6.824 | 23 | kernel_top200.rpt:6242 |
| E | FSM kt_dim -> Scale microtile address -> command rs2 | 0.499 | 9.087 / 4.052 / 5.035 | 31 | ctrl.rpt:1874 |
| F | HBM LSU AXI R spill-buffer full -> skid data CE | 0.523 | 8.645 / 0.794 / 7.851 | 7 | kernel_top200.rpt:9400 |
| G | FSM kt_dim -> QROW parameter byte count -> command instr | 0.562 | 9.051 / 5.217 / 3.834 | 26 | ctrl.rpt:4400 |
| A2 | Operand selector -> outgoing operand EB2 payload | 0.617 | 8.869 / 0.268 / 8.601 | 2 | kernel_top200.rpt:18642 |
| B2 | Scheduler head -> Input request priority capture | 0.647 | 8.824 / 2.508 / 6.316 | 26 | scheduler.rpt:558 |
| H | HBM DMA out_off -> AXI readiness -> response RAM enable | 0.701 | 8.648 / 1.817 / 6.831 | 18 | hbm_dma.rpt:16 |
| B3 | Weight descriptor metadata -> priority -> Weight request | 0.750 | 8.869 / 2.232 / 6.637 | 26 | weight_dma.rpt:16 |
| I | Weight install pointer -> writer wait -> slot recycle/allocation | 0.900 | 8.697 / 2.169 / 6.528 | 22 | weight_dma.rpt:534 |
| J | Wide Weight issue context -> physical TMEM arbiter -> RAM enable | 0.958 | 8.362 / 1.807 / 6.555 | 17 | tmem.rpt:2038 |
| K | Compute result count -> ACC/scale readiness -> Input DMA RAM enable | 1.029 | 8.214 / 2.105 / 6.109 | 24 | compute.rpt:16 |
| L | Hidden compute/ACC datapath | 1.111 | 8.453 / 2.638 / 5.815 | 28 | compute.rpt:516 |
| M | Core GEMM-MMIO request -> job descriptor request capture | 2.087 | 7.085 / 0.441 / 6.644 | 3 | memory.rpt:16 |
| B4 | Scheduler head -> Scale / Zero-point request priority | 2.256 / 2.416 | 7.247 / 7.153 total | 16 | scheduler.rpt:4124 / :4528 |
| K2 | Input DMA drain slot -> next response RAM enable | 2.521 | 6.570 / 1.789 / 4.781 | 18 | input_dma.rpt:16 |
| N | Output DMA request -> ACC physical RAM address | 2.542 | 6.681 / 0.302 / 6.379 | 2 | output_dma.rpt:16 |
| O | Output DMA valid-byte mask -> response RAM data | 2.584 | 6.666 / 0.537 / 6.129 | 4 | output_dma.rpt:134 |

### C / E / G: command arithmetic is still before the existing command FF

These are three related but distinct arithmetic cones in
`hw/rtl/core/gemm/VX_gemm_fsm.sv`, all ending at the command staging register in
`hw/rtl/core/gemm/VX_gemm_ctrl.sv:358`.

- **C:** `mt_dim_q[17]` -> tile index/last-tile choice -> `input_tile_addr` DSP
  chain -> address addition -> `cmd_stage_cmd_q.rs2_data[61]`.
  FSM:757 defines the function, :763 adds the M base index, :765 chooses full
  versus tail K stride, :767-769 performs base plus two64-bit-cast products.
  Representative call sites are:1831 and:2464.
- **E:** `kt_dim_q[10]` -> last-K/effective-K selection -> ceil-div-by-power-of-two
  and Scale stride -> `lmem_sc_mxu` multiplier/addition -> `rs2_data[55]`.
  FSM:1459 selects effective K; :1521-1525 computes group count and strides;
  :1552-1565 computes Scale/ZP addresses; :2020 packages Scale source address.
- **G:** `kt_dim_q[18]` -> effective tile extent -> two cascaded multipliers in
  `qrow_qparam_tile_bytes` -> byte-count/instruction mux -> `instr[26]`.
  FSM:727-735 defines the product, :531 packs byte count into the instruction,
  with calls at:1753, :1881, :2529 and the corresponding Zero-point commands.

**Fix direction:** precompute full/tail tile strides, QROW byte counts, and
next-tile addresses while the current tile executes. Register the result in a
tile/command preparation stage before the final command selection. Cache job
invariants during existing initialization states, use incrementing address
state where applicable, and use proven-minimum-width products before widening
the final address. Retain unsigned address semantics; do not mechanically
sign-extend address arithmetic. Do not assume dynamic effective extents or
strides are powers of two merely because MXU dimensions are.

Putting another FF **after** `cmd_stage_cmd_q` would not shorten these cones.
Precomputation must cover first-tile startup, tail M/K/N cases, preload-next,
QROW/QCOL and transposed weights. The existing FF is real; its *input* is long.

### D: registered decode still feeds a large combinational chunk builder

`hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:697-701` decodes operation, address,
and segment size from `decode_cmd_q`. The builder selects current/shadow/candidate
inputs around:842-889. Lines905-937 derive max-chunk budget, shift remaining
beats by BND0 log2, choose the smaller row count, and shift back into beat count.
Capture is at:1260 (`issued_chunk_beats_per_bank_q`) and:1315
(`shadow_chunk_beats_q`). The second endpoint has slack+0.517ns.

The path traverses `load_desc`, remaining/budget selection and `chunk_bnd1`
logic: registering `decode_cmd` has removed an earlier boundary but has not
registered this downstream arithmetic. **Fix:** calculate/store per-candidate
chunk metadata before it becomes eligible, or split descriptor construction and
chunk sizing across preparation stages. Keep completion/chain selection on
already-prepared data so same-cycle command done/chain behavior is preserved.
Constant-power-of-two division is already represented as shifts; remaining
delay includes variable shifts, min comparisons, decode and selection.

### F: HBM response spill-buffer ready round trip

`hw/rtl/Vortex_axi.sv:769-784` instantiates `u_lsu_mux_cut` for each HBM port.
For port2 the path starts at its AXI R spill buffer's `a_full_q`, passes through
the LSU response demux/mux readiness network, and returns to `b_data_q.CE`.
It is mostly routing, not seven levels of arithmetic.

Storage behavior is in
`third_party/axi/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b/src/spill_register_flushable.sv`:
:65-66 captures B data on `b_fill`; :79 computes A drain; :84 includes downstream
`ready_i`; :90 computes upstream ready. The third-party checkout is a source
reference, not the preferred place for an untracked local fix.

**Fix:** introduce locally generated space/credit for the response capture
boundary or a properly registered-ready response transport at the demux boundary,
with enough skid capacity to absorb accepted beats. Preserve AXI ID, LAST,
ordering, and response backpressure. Additional generic cut instances do not
automatically remove a local buffer's downstream-ready-to-wide-CE cone. Inspect
and limit lane-local enable fanout as well.

### H: general HBM DMA same-cycle drain/refill cone

`hw/rtl/core/VX_dma_unit_align.sv:1506-1514` computes remaining/valid write bytes
from `out_off`. Request generation around:2130 and:2229 feeds the HBM arbiter's
ready network. :1639-1643 derives slot drain from destination request acceptance;
:1226 immediately uses that drain to permit the next response RAM read.
The report explicitly traverses `u_axi_mux`, `hbm_req_ready`, and RAM `read`.

**Fix:** make a local, credit-backed payload staging boundary so RAM prefetch
depends on registered local space, not current HBM arbitration. A two-entry
prefetch/output queue can preserve sustained one beat/cycle. Maintain transport
pending counts and physical completion semantics; adding an unbuffered ready
FF can overrun or lose data. Review the same read-enable structure on all four
HBM DMA channels, not just channel0, which happens to be worst here.

### I / K / K2: DMA ordered-response selection coupled to downstream readiness

These share `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`:

- :215 direct sink handoff depends on downstream readiness and writer release.
- :239 allows staging on current handoff; :242-249 selects current/next command
  and computes next beat.
- :264-274 searches slot state, owner command, sequence, and beat before RAM read.
- :297 releases the slot; :303-325 may reuse that slot for a new request;
  :335 defines source request acceptance; :381 drives RAM read from the search.
- :609 onward captures new owner metadata on request acceptance.

**I** starts at Weight install-pointer selection and traverses the writer wait
comparison in `VX_lmem_dma_misal.sv:2083-2092`, then stage selection, slot release,
and request allocation. The reported endpoint is a synthesis-generated retimed
owner-sequence FF; do not invent a source register named `fret` in the RTL.

**K** starts at `VX_gemm_compute_core.sv:1916` result-empty detection, then
:825 ACC RAW stall checks and :1930-1936 result/scaler acceptance. It passes
through Scale lifetime/release (:664, :1269) to Input DMA readiness and then
the same ordered-slot RAM search. This is a real consumer-to-producer
backpressure chain, not a BRAM data-output timing problem.

**Fix:** decouple ordered-slot selection from live consumer readiness using
registered selected-slot/beat metadata and local credits. Use static per-slot
parallel comparisons plus a balanced encoder, or ring-head metadata where
ordering permits. Evaluate the existing sink-elastic option and registered-free
allocation before adding a new mechanism. A one-cycle-delayed recycle may reduce
effective outstanding capacity; test eight-slot overlap and performance. Do not
remove ACC RAW checks to improve timing; isolate readiness with sufficient local
buffering and retain the hazard guarantee.

### J: wide Weight issue selection plus physical TMEM arbitration

`hw/rtl/mem/VX_tmem_wide_read_switch.sv:111` selects the issue FIFO head context;
:167-184 forms per-physical-array request validity and priority. The path then
enters `hw/rtl/mem/VX_tensor_mem_bank.sv:102-130`, computing priority and rotating
winner selection. It continues through `mem_arb` at:151-163 to SRAM read/write
acceptance at:185 and:221, and BRAM enable.

**Fix:** hold predecoded issue-context/lane request metadata in per-lane request
reservations before the physical SRAM arbiters. Balance six-requester priority
selection and avoid redundant arbitration after the winner is already one-hot.
Do not add cycle-dependent priority changes to stalled requests or weaken the
fairness escape. This is a separate boundary from the upstream wide-request EB2.

### L / M / N / O: secondary paths and limits of attribution

- **L:** the extracted compute path has hidden endpoints and DSP/adder-style
  arithmetic. Nearby paths terminate at ACC RAM DIN, but the hidden path cannot
  be reliably mapped to a specific RTL source from this report alone. Keep it
  as a follow-up measurement target; do not apply a guessed fix.
- **M:** `hw/rtl/mem/VX_lmem_switch.sv:149` GEMM request buffer to
  `hw/rtl/core/VX_job_desc_mmio_regs.sv:199` request address/data registers.
  Mostly routing. Localize address decode/request capture or provide a narrow
  registered MMIO request boundary if this becomes limiting. It is not presently
  the first kernel-frequency limiter.
- **N:** output DMA launch to ACC SRAM address selection.
  `hw/rtl/core/gemm/VX_gemm_acc_internal.sv:210-230` decodes output read address,
  group conflict and per-array request; :253 onward selects physical RAM access.
  Consider local registered read requests/address replicas while preserving ACC
  ownership and read latency. This is **not** the former output-DMA multiplier
  bottleneck: only two LUT levels, 95.48% routing.
- **O:** output DMA's `slot_valid_bytes_r` controls the response write mask in
  `hw/rtl/core/VX_dma_unit_align.sv:1455-1461` before `response_payload_ram` data capture.
  It is below the primary cones. Only remove the mask if this particular instance
  is proven padding-free; do not globally disable padding for generic/local DMA.

## Suggested implementation batches and verification

1. **No-extra-cycle transformations:** A/A2 local one-hot operand control;
   B/B2/B3/B4 ETA simplification and parallel match; C/E/G invariant precompute
   and narrow products. These remove large cones rather than move them.
2. **Prepared command metadata:** D, plus any remaining C/E/G precompute stages.
   Preserve same-cycle done and select only registered candidate data.
3. **Credit-backed response boundaries:** F/H/I/J/K. These can be changed together
   architecturally, but verify each interface separately before combining them.
   Extra FFs without buffering/ownership are not safe ready cuts.
4. Re-measure L/M/N/O after the dominant cones change; avoid speculative changes
   to hidden or currently secondary paths.

For each batch, run the exact all-BRAM config through xrt-vcs-sim and compare
GEMM cycles with `--perf 3`, not total host/runtime cycles. Include QROW/QCOL,
partial tiles, small and large matrices, W overlap, response reordering and
destination backpressure. Preserve existing data/ownership assertions and
same-cycle command completion. Compare source snapshots for every run.

Only after functional/performance verification should another user-authorized
fresh PnR measure frequency and congestion. No RTL changes or simulation were
performed as part of this analysis.

## Evidence roots

Original implementation directory:
`build_timing_cuts_pnr_th16_tcol16_m16_t8_bigmem_all_bram_200m_spread_v1/hw/syn/xilinx/xrt/improve_th16_tcol16_m16_t8_bigmem_all_bram_200m_spread_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/_x/link/vivado/vpl/prj/prj.runs/impl_1`

Additional read-only reports:
`build_timing_cuts_pnr_artifacts/mxu16_200m_timing_analysis/`.

Reproduction scripts: `inspect-timing.tcl` and `extract_paths.py` in this task.

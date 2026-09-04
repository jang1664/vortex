# GEMV RTL Architecture Presentation Plan

- P1 — **GEMV RTL Architecture Evolution**
  - Scope: RTL changes from the `fpint` baseline to `feat/gemv`.
  - Narrative: bottleneck → architectural solution → resulting hardware.
  - Main body order: IMPROVE first, then NAIVE; shared modules are an appendix.

- P2 — **IMPROVE Baseline: Tile-Major GEMM on TMEM**
  - Show only the original IMPROVE node at a high level: controller, TMEM/DMA, compute/ACC, and output drain.
  - Establish the presentation boundary: command progress, operand movement, compute/ACC, and output drain.
  - Defer NAIVE and implementation-sharing details until their dedicated sections.

- P3 — **IMPROVE: Why the Original Structure Left Throughput on the Table**
  - ACC read/write counts were managed centrally across microtiles.
  - Different `Input → ACC memory` latencies were therefore exposed between otherwise independent microtiles.
  - A delayed earlier microtile could block later work, creating bubbles and broad pipeline-empty restrictions.
  - Use a before timing diagram showing latency propagation through the shared counters.

- P4 — **IMPROVE Solution 1: Carry ACC Control with the Datapath**
  - Replace the centralized ACC RD/WR tracker with packet-local address, R/W intent, sequence, generation, and final markers.
  - Carry the control token across the same register boundaries as its data.
  - Resolve forwarding and physical bank access at the local ACC backend.
  - Diagram: centralized counter fan-out before; parallel data/control pipelines after.

- P5 — **IMPROVE Solution 2: Hide Operand-Ready Latency with Local Backpressure**
  - Before ready/backpressure support, Input admission had to wait for W/S/Z readiness before entering the GEMM unit.
  - This exposed the frontend-to-GEMM-tree latency and delayed reuse/loading of the next W/S/Z generation.
  - Let Input advance through an elastic pre-process region and check exact bank/generation readiness immediately before each real consumer.
  - Keep the five-cycle MXU/correction region fixed-latency; protect it with a depth-six merged-result FIFO and registered credit return.
  - Diagram: before/after hardware plus a timing comparison showing operand load overlap with PRE latency.

- P6 — **IMPROVE Solution 3: Make ACC Hazards Local and Pipeline-Safe**
  - Replace central read/write-count dependency tracking with transaction- and microtile-local ACC state.
  - Schedule accumulator reads early and forward short RAW dependencies instead of waiting for stale SRAM data.
  - Use local credits, bank/group ownership, and backpressure contracts to contain variable latency within the affected flow.
  - Diagram: local request tracking, early-read, forwarding, writeback, and bank-conflict paths.

- P7 — **IMPROVE Solution 4: Overlap Compute and Output with ACC Double Buffering**
  - Divide the physical ACC banks into two execution groups.
  - Drain completed output from one group while computation continues in the other group.
  - Gate output reads only on same-group conflicts, not global `pipeline_empty`.
  - Show a two-group timeline: Compute A / Drain B, then swap.

- P8 — **IMPROVE Solution 5: Remove WAIT/NOTIFY from the FSM**
  - Previously, separate `WAIT` and `NOTIFY` opcodes serialized dependency checks and completion signaling in the FSM.
  - Embed writer-wait, completion-notify, generation, and work-sequence metadata directly in DMA and compute commands.
  - Each execution block now checks its own dependency metadata and reports completion without separate synchronization commands.
  - Result: dependency-ready commands can issue continuously and overlap across command boundaries.

- P9 — **IMPROVE Solution 6: Overlap DMA Work Across Commands**
  - Previously, broad command-level completion serialized commands N/N+1, and Scale/ZP shared one qparam Local DMA.
  - Add tagged multi-command HBM DMA queues and aligned look-ahead chaining so the next command can start before the current command fully retires.
  - Split the shared qparam engine into independent Scale and ZP Local DMAs, with resource-specific fences, bounded queues, and exact generations.
  - Show a before/after timeline of HBM DMA, Local DMA, and compute overlap across two commands.

- P10 — **IMPROVE Solution 7: Schedule TMEM by Earliest Runnable Microtile**
  - Replace local urgency with `VX_microtile_readiness_scheduler`, which prioritizes traffic that enables the earliest runnable tile.
  - Add partial-width, multi-outstanding Weight wide reads and parameter prefetch credits to sustain operand delivery.
  - Register consumer-block feedback and preserve exact generation/fence checks under early issue.
  - Decouple TMEM-bank, DMA-channel, and HBM-port counts; retain a restricted channel-to-bank mapping instead of a full crossbar.

- P11 — **IMPROVE Guardrails: What Overlap Must Not Change**
  - Source responses may return out of order, but admission, destination writes, notifications, and retirement remain command-ordered; completion is the final actual write.
  - Prefetch is bounded and cannot expose unreleased data or overwrite live state; Scale/ZP same-cycle write-to-snapshot remains blocked.
  - Valid/payload/priority remain stable under stall; scheduler priority is only a non-starving hint, while local ready/backpressure remains authoritative.
  - Preserve 64-byte interleaving with no full crossbar; ACC double buffering does not imply output-LMEM double buffering.

- P12 — **IMPROVE Resulting Architecture and Execution Flow**
  - Consolidate P4–P10 into one final IMPROVE block diagram.
  - Sequence: metadata-driven command admission → overlapped operand movement → elastic compute/ACC → concurrent output drain.
  - Mark the key concurrency boundaries and their correctness fences.
  - Use this as the transition from problems/solutions to the final structure.

- P13 — **NAIVE Baseline: Row-Major GEMM on LMEM**
  - Introduce the original NAIVE node separately: its FSM, LMEM/DMA operand path, compute/ACC, and output path.
  - Contrast its local-memory data movement and row-major execution style with the completed IMPROVE architecture.
  - Keep this section focused on NAIVE's own hardware structure, not code reuse.

- P14 — **NAIVE: Why Its Compute Path Needed to Change**
  - Fixed timing assumptions made backpressure, ACC latency, and command completion difficult to handle robustly.
  - Packet control and completion were coupled to implementation-specific timing rather than actual data movement.
  - Preserve row-major address equations, LMEM mapping, and output DMA; do not import the IMPROVE TMEM scheduler.
  - Show the old NAIVE node with its dedicated compute/ACC path.

- P15 — **NAIVE Resulting Architecture and Execution Flow**
  - Convert each accepted Input packet into a stable control record and keep it aligned with its data through the pipeline.
  - Use exact W/S/Z load generations, tagged final completion, and physical LMEM request drain instead of fixed-delay completion.
  - Retain the original row-major LMEM/DMA and external-output structure while strengthening compute/ACC flow control.
  - Diagram: NAIVE FSM/LMEM DMA → packet control + compute/ACC path → existing output path.

- P16 — **Final Comparison: IMPROVE and NAIVE Hardware Architectures**
  - Compare the final hardware structures side by side, by controller, operand memory system, compute/ACC, and output path.
  - IMPROVE: TMEM scheduling, wide reads, bank/DMA/HBM topology, and internal ACC double buffering.
  - NAIVE: row-major controller, LMEM operand/ACC path, and unchanged external DMA/address topology.
  - Focus on architectural choices and their throughput/correctness consequences.

- P17 — **Takeaway and Evidence**
  - Summarize the architectural principle: separate compute flow control from backend-specific memory systems.
  - Map each major change to focused RTL tests and final IMPROVE/NAIVE XRT-VCS runs that explicitly prove WLOAD8.
  - Leave one placeholder for measured performance/utilization results, to be filled from the selected benchmark configuration.

- P18 — **Appendix: Shared Compute-Path Implementation**
  - Explain that `VX_gemm_compute_core` provides the common elastic arithmetic and packet-control contract.
  - `VX_gemm_unit_v2`/`VX_gemm_acc_internal` implement the IMPROVE-side ACC backend; `VX_gemm_acc_lmem` implements the NAIVE-side LMEM adaptation.
  - Use this slide only for implementation discussion or questions; it is not required for the architecture narrative.

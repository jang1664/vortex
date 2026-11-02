# C4 FlashAttention physical-boundary repair

Status: requirements confirmed by the active implementation plan. The isolated
tree contains the initial LMEM-local transport repair; its three pure Tcl
topology fixtures pass. Complete consumer placement and the remaining
MMIO/publication/busy/reset changes are under design review. RTL simulation
and physical acceptance of the repair remain pending.

## Goal and evidence

Complete the physical-connectivity requirement of
`docs/future_optim/c4_flash_attention_tmem_lmem_dma_plan.md` while retaining
the implemented SRAM attention behavior. This repair is within the existing
goal; it is not a new performance-optimization project.

The completed R5 metadata-corrected audit (session 62797) exited 1 on the
placed checkpoint with SHA256
`a42dec7ca507c135b1a316cbc7e6933d63323a7b9d8943ca2775c48486f2abed`.
All 32,681 endpoint tuples and nonclassification fields match the original
audit; unresolved placement is now zero. Root independently verified the
artifact hashes and categorized all 328 physical violations:

| Boundary | Rows | Required outcome |
|---|---:|---|
| LMEM cut endpoint versus existing LMEM consumer | 307 | Align complete transport endpoints with their consumer placement; remove unintended combinational return crossings. |
| MMIO/publication/control | 13 | Preserve ordering and publication semantics across registered physical boundaries. |
| Reset distribution into local logic | 7 | Establish valid reset infrastructure or provide safe local distribution, with actual structural evidence. |
| DMA/core busy to AFU | 1 | Register the physical boundary without premature kernel completion. |

The LMEM cut's external side is currently assigned SLR0, while the existing
LMEM adapter/arbiter is placed in SLR1: 236 outward and 71 return rows.
The control category includes four request-valid, two request-ready and
seven publication-level fanouts. Synthesis moved some controller expressions
under LSU/memory hierarchy names, so hierarchy spelling alone cannot identify
their semantics.

The completed publication-input probe (21794, exit 0) additionally inventories
1,169 counter-fanin cells and 3,711 direct input-driver edges. All 32 pending
counter FFs are in SLR0; 62 fanin cells are in SLR1. Its 68 nonconstant
SLR1-to-SLR0 pairs include 67 absent from the original external frontier.
These upstream paths require semantic attribution, not automatic classification
as feature-introduced violations. Named CPU/DMA commit ports were optimized
away, so bank-specific producer identification remains pending in probe 14758.
Publication repair must cover its inputs as well as its final output.

The twelve separate zero-leaf topology errors are hierarchy-only remnants,
established by a complete reverse inventory of 1,128,310 primitives and
8,630,603 pins, exact positive-control hits, 96 hierarchy-pin owner checks,
zero ports and zero global blackboxes. Their checker correction is separate
from these 328 actual physical paths. No physical failure may be hidden by
that correction.

Evidence: `logs/fpga_r5_physical_metadata_corrected/root_violation_review.json`,
`actual_violations.tsv`, `violation_map.json`, and the reverse/hierarchy
`root_terminal_review.json` files under `logs/`.

## Isolation and compatibility

Implement only in
`/home/jaeyongjang/project.local/vortex_fpint-feat-gemv-c4-physical-repair`.
The configured build is `build_c4_physical_repair` inside that worktree.
`logs/physical_repair_worktree/` binds its baseline to the original source.
The original tree, running FPGA build, full decoder simulations and prefill
capture remain frozen. Do not attribute their results to later repair RTL.

Preserve the no-TMEM-crossbar architecture, existing LMEM crossbar dimensions,
one 32-byte staging word with four 8-byte LMEM accesses, FP32 online state,
resident GEMM modes and the 44-word legacy descriptor. Feature-off selected
RTL, interfaces, pipeline/queue capacity and legacy cycles must remain intact.
Do not run improve GEMM-node synthesis. New whole-design implementation is
required after the repair.

## Ordering and liveness invariants

- Reuse existing transport abstractions where appropriate. Place complete
  endpoints coherently; do not move individual LUTs merely to hide the first
  edge of a crossing or broadly relocate the CPU/LMEM banks.
- A delayed MMIO request can outlive CPU retirement. Doorbells in flight,
  accepted commands and bridge destination commits must all keep the kernel
  alive until completion is safe.
- Preserve the controller's same-edge bridge-busy guard against GEMM dispatch.
  A pipeline added only for exported AFU busy must not delay that internal
  ownership decision.
- Do not pipeline the publication level without a freshness protocol. A
  previously true level must not acknowledge stores that arrived afterward.
  Publication must correspond to the requesting operation and include all
  earlier accepted SIMD stores, LMEM arbitration/queues and physical commits.
- Completion still means destination data committed and visible. No later
  reset, unrelated kernel or cache flush may supply missing ordering.
- Preserve reset/start behavior across local transport endpoints. Retain
  actual reset-source and sink evidence; net names alone are not an exception
  to physical checking.
- Do not reintroduce the publication-to-ready combinational loop fixed by
  `publish_pending_q`.

## Implementation review and verification

The RTL author supplies exact affected files and a design addressing all four
boundary categories before mutation. The root reviews ordering/liveness and
scope. Implementation and independent verification follow the existing
`rtl-improve` author/verifier procedure. A new module requires a testbench;
existing test infrastructure is not rewritten to accommodate a failure.

Required verification must cover the final changes: both DMA directions and
backpressure, publication after newer stores, request/response transport and
route ownership, back-to-back commands, reset with work pending, early CPU
return with a delayed doorbell/copy, and final readback after physical commit.
Reuse the existing publication, node, boundary, early-return and full-core
attention tests where they exercise the repaired paths. Verify feature-off
RTL/cycles independently. Use configured builds, sourced C4 configuration,
system host compilers, deterministic RTL verification and `xrt-vcs-sim`
blackbox execution as required by repository instructions.

Physical acceptance requires a new checkpoint and complete internal/external
connectivity evidence, loop/DRC checks and final routed timing. The structural
checker must recompute hierarchy-only evidence for each checkpoint and retain
real topology failures. A new image/alias and the required hardware backend
matrix must bind to the accepted repair revision. The old R5 image, if one is
produced, cannot serve as evidence for repaired RTL.

Record each iteration, actual exits, source/image identities, measured cycles
and remaining limitations. Integrate the verified repair into the primary
worktree without invalidating the original frozen runs; no commit or
publication is requested.

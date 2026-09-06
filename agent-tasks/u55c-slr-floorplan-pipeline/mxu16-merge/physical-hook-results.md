# Shared transport physical-hook checks

Verified: 2026-09-06 22:50 KST. Tcl fixtures only; no Vivado synthesis,
implementation, checkpoint loading, placement or timing analysis was run.

## Hierarchy contract

The node now owns one `u_gemm_dma_transport`. Its `u_commands/u_launch` and
`g_source` ownership state belong to SLR1. Forward crossing endpoints below
`u_commands/g_slr/u_link/{u_tx,u_rx}` belong to SLR1/SLR0. Completion and sync
endpoints use the same helper nesting with the reverse ownership. The remote
idle pair is below `g_slr_status/g_slr{0,1}`.

TMEM requests and responses retain their resource-specific parents, with
the crossing below `u_{request,response}/g_slr/u_link`. Request launch EB2
storage belongs to SLR1; output pending completion FFs under
`g_output_slr_completion` also belong to SLR1. Mixed transport parents and
their new `g_slr/u_link` containers remain forbidden as homogeneous anchors.

Tests explicitly check launch storage, tag ownership, command receiver,
request launch, output completion, missing marked endpoint pairs and unknown
ownership. A generic lifted `u_link` that loses its resource identity is
rejected rather than guessed into an SLR. Eight-channel geometry checks remain.

## Evidence

The command hierarchy fixture was changed before the hook implementation.
It failed with `SLR floorplan missing required group: DMA commands tx`,
demonstrating that the old hierarchy contract did not silently accept the
refactor. After the hook changes, all commands below returned exit code zero:

| Command under `hw/syn/xilinx/xrt/` | Result |
|---|---|
| `tclsh test_slr_floorplan.tcl` | PASS: ownership, profiles, exact FF pairs, Laguna fixture checks |
| `tclsh tests/test_homogeneous_anchors.tcl` | PASS: 63 checks, including a 10,000-leaf fixture |
| `tclsh tests/test_post_opt_hook.tcl` | PASS: 59 lifecycle/hook checks |
| `tclsh tests/test_post_place_hook.tcl` | PASS: 24 checks |
| `tclsh tests/test_post_place_slr_objects.tcl` | PASS: 22 typed-object checks |
| `tclsh tests/test_post_place_slr_snapshot.tcl` | PASS: 13 snapshot checks |

Expected negative-fixture errors are caught by these suites; they are not
implementation failures. The post-opt hook remains enabled.

## Physical limitations

These fixtures prove classifier and hook behavior on the modeled hierarchy,
not preservation of hierarchy through actual synthesis. A future separately
authorized synthesis must check lifted logic, complete marked FF pairs,
direct TX Q-to-RX D connectivity, and resource deltas. Actual Laguna placement,
SLR utilization, congestion, and routed frequency remain unverified. The
previous weight-selection high-fanout critical path is outside this merge.

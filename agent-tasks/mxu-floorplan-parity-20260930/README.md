# MXU floorplan parity with feat/gemv

Reference: `f4db8ea4e4616054e567dda26b594464cf4bde18`.

## Preserved reference techniques

- Full-SLR hard pblocks, exclusive cell ownership, typed Vivado object resolution,
  bulk property queries and grouped post-place SLR queries (DSP48E2 macros can
  return no SLR when queried alone).
- Hierarchy anchors retain MXU descendants through implementation.
- Boundary net collection uses hierarchical-group top nets, deduplicates nets,
  and inspects leaf driver/destination pins across all net segments.
- Clock/reset exceptions use the exact destination REF_PIN_NAME allowlist from
  `slr_floorplan_report.tcl::validate_boundary_nets`, never signal spelling.
- Assigned cross-SLR data edges must be marked USER_SLL_REG Q->D edges. The
  separate exact-link checker also enforces stream/unit identity and exclusive
  TX->RX fanout.
- Per-phase boundary TSVs identify offending nets, pins, ownership and legality.
- Existing post-place failure hook saves a diagnostic DCP before propagating errors.

## Required MXU-only differences

- Target MXU and six transport banks, plus local block-index alignment, in SLR1/2.
  DMA/TMEM/ACC are not assigned. The full-node SLR0/1/2 mapping, DMA geometry and
  naive lifted-leaf recovery rules do not apply to this RTL hierarchy.
- Follow the reference ownership boundary: edges with an unassigned endpoint
  are audited separately, not rejected as cross-SLR violations. This matters
  because real C2/C3/C4 synthesis netlists fold one external reset branch into
  an owned LUT input. The original broad `clk_i/resetn_i` exemption hid that
  case; a new blanket external-edge failure would incorrectly block all three.
  Payload/control pin rules remain enforced between assigned partitions, and
  exact transport FF links remain enforced independently.
- Always emit an external-edge TSV (the reference emits it for naive only).
  Top-level inputs with no leaf driver are audited with an empty source pin;
  multiple leaf drivers are rejected. Literal GND/VCC drivers remain allowed.
- Set IS_SOFT last because the EXCLUDE_PLACEMENT setter resets it in Vivado 2025.1,
  as proven by the earlier pblock-property diagnosis.
- Boundary report handles are closed on error.

## Verification

See `verification.json` for final results and artifacts. Source RTL kernels were
not modified. The placement probe is test-only.

An initial stricter ownership experiment rejected one synthesized external
reset-to-LUT edge in each kernel; `synth-*.log` and their boundary TSVs retain
that evidence. Final verification uses `final-synth-*`.

The first reset-probe variant folded a conditional product reset into a payload
LUT. Its rejection exposed the stricter experimental ownership rule; `placement.log`
and `placement/post_init_mxu_slr_boundary_nets.tsv` preserve that evidence. The
revised probe explicitly instantiates a reset sink on FDRE.R, shared with an
outside reset sink, to exercise the actual C4 alias failure condition.

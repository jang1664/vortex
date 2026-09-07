# Robust SLR boundary matching and checkpoint regression

Status: confirmed by the user on 2026-09-07.

## Goal

Fix the TH32/t4 and TH32/t8 post-init failures without changing RTL or
weakening physical safety checks. The failing synthesized names use
`u_commands/g_slr.u_link/u_rx/...`, while the hook assumed `g_slr/u_link`.

## Implementation contract

- Share interpretation of known generate-boundary spelling between ownership,
  inventory, marked-group checks, link grouping and hierarchy-anchor barriers.
- Normalize only documented/observed architectural boundary spellings for
  matching. Keep original cell names/objects for every Vivado query/assignment.
- Assign ordinary descendants by validated architectural endpoint rather than
  generated leaf/FSM names; reject lost/ambiguous transport identity.
- For the observed root-lifted receiver LUT1 helpers, permit recovery only
  when actual pins prove an exclusive feedback loop through the same
  unmarked state FF with retained, known receiver identity in the same node.
  Require direct FF Q-to-I0 and O-to-FF D, no additional output sinks/drivers
  or top-level ports. Record the original-name proof; never infer a missing
  stream from the LUT leaf name. This is a Tcl-only extension supported by
  identical connectivity evidence in both source checkpoints.
- Retain exact geometry/index, complete marked pair, direct Q-to-D, partition
  boundary and pblock ownership checks. Never add a catch-all SLR assignment
  or blanket DONT_TOUCH/KEEP_HIERARCHY preservation.
- Collect unclassified leaves into a diagnostic report where practical, then
  fail before applying constraints instead of silently ignoring them.

## Verification

- Extend fast Tcl regression for dot/slash, mixed spelling, replicas,
  misleading names, malformed/lost identity, ownership and mixed-SLR barriers.
- Load the existing TH32/t4 and TH32/t8 synthesized kernel DCPs and reproduce
  the original failure from the preserved build hook snapshots.
- With updated source hooks, run read-only inventory/marked/link/boundary
  checks and apply full-SLR pblocks in memory only. Do not save DCPs, call
  synthesis/optimization/placement/routing, or relaunch source P&R.
- Preserve raw evidence in an ignored build directory and summarize results,
  including limitations of kernel-only DCP versus platform-linked netlists.
- No RTL simulation rerun is needed unless RTL changes become necessary;
  such scope expansion must be reported before implementation.

## Out of scope

RTL changes, new latency/resources, new synthesis/P&R, DCP-based P&R retry,
commit and push. Historical failed physical builds remain failed artifacts.

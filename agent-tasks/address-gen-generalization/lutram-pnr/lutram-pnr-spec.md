# Address Generator Queue PnR Spec

Status: confirmed

## Goal

Keep the shallow per-thread address queues in `VX_agen_unit` synthesis-friendly
and let Vivado choose registers or distributed RAM from the target and access
pattern. The queues are only four entries deep, so an explicit memory wrapper
is not justified before measuring the post-synthesis implementation.

## Scope

- Retain the existing shallow RTL array for address queue payload storage.
- Avoid an explicit `VX_dp_ram` instance or LUTRAM/BRAM selection parameter.
- Preserve the existing queue depth, read/write timing, simultaneous
  enqueue/POP behavior, descriptor state, ISA, and software behavior.
- Update directly relevant RTL documentation or focused tests only if needed.

## Constraints

- Vivado is allowed to select registers or distributed memory for the queue.
- Feature-disabled builds must remain unchanged.
- No redesign of descriptor storage or producer scheduling is in scope.
- Focused VCS verification must pass with the existing W2/T8/SIMD4 suite.
- The existing end-to-end xrt-vcs-sim PASS remains the integration reference;
  a synthesis-only storage hint must not change simulation behavior.

## Final Agreed Design

Retain the original shallow queue array and inspect hierarchical utilization
after the first PnR run. Add an explicit implementation hint only if the report
shows an undesirable mapping or material area/timing cost. This avoids changing
queue read/write semantics before there is synthesis evidence that it is needed.

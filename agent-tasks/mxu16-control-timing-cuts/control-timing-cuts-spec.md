# Control timing cuts — confirmed implementation specification

Confirmed by the user's request to execute `plan.md` on 2026-09-05.

## Goal and scope

Execute the complete staged plan, including independent ablations, functional
verification, cycle/overlap/bubble attribution, and final routed 100 MHz checks.
The plan remains the authoritative requirements document; this specification
does not narrow its success criteria.

Affected modules are the GEMM controller/node, local stream DMA queue and
operand wrappers, HBM DMA destination transport, and their focused tests.
Keep MXU16, 32-byte local banks, 64-byte HBM transport, fixed paired-bank
topology, tile-major layout, kernel scheduling, and quantization unchanged.

## Decisions and invariants

User clarification on 2026-09-05: decreasing SET notifications are not required
by the real workload and may be removed to enable registered dependency views.
Within an invocation, counters must therefore remain monotonic in the timing-cut
configuration. Evaluate clamping stale/lower SET values to the current value,
including simultaneous notifications; reset/new-configuration still starts a new
epoch. Update directed tests to verify the new contract, rather than silently
assuming all existing generic controller tests were monotonic. Preserve an
unchanged experimental B0 for attribution.

- Reuse registered architectural state for visibility cuts before adding FFs.
- Measure independent cuts before accumulating pipeline latency.
- Use SIZE=2, OUT_REG=1, LUTRAM=0 elastic buffers for reverse-ready isolation.
- Preserve complete transaction identity and physical-write completion.
- Keep implementation directives/floorplan fixed for apples-to-apples timing.
- Baseline and final candidate require the 20-case matrix in `plan.md`.
- Test in configured builds with the sourced MXU configuration and xrt-vcs-sim.
- Do not claim completion without routed setup/hold closure and measured costs.

## Execution

Start from HEAD `5d8fc73fbaae62cb5cebbd3320b5e8dc5ef0836e`.
Preserve unrelated untracked task artifacts and other users' running jobs.
Implementation/verification roles follow the rtl-improve skill. No commit or
push is included in this execution request.

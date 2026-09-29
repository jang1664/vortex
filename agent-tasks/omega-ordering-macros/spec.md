# Omega ordering compile-time controls

Confirmed by user request on 2026-09-29: inspect historical/current Omega differences and make ordering selectable at compile time.

- VX_stream_omega itself is unchanged from 93f4ae97d.
- Preserve existing fabric selectors and default guarded behavior.
- LMEM_REQ_OMEGA_ORDER_DISABLE bypasses outstanding-store CAM/RAW admission.
- LMEM_RSP_OMEGA_ORDER_DISABLE bypasses per-requester response queues/admission.
- Both are presence macros: defining even =0 disables that guard.
- Either switch only affects its Omega direction; stream xbar is unchanged.
- Both switches select historical unguarded transport, not a rollback of the entire LMEM/GEMM design.
- Bypassing guards removes their ordering guarantees; callers must tolerate response reordering and prevent dependent RAW overlap.
- Product scope: VX_config.vh, VX_local_mem.sv; adapt local_mem_top scoreboard to selected guarantees.

Validation: local_mem_top routing/data/tag/backpressure tests across fabric/guard combinations, default ordering checks, and isolated xrt-vcs-sim C3 M256 internal-ACC guard-bypass check. No agents in this side conversation.

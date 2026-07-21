# Layout-Fused Address Generator Specification

Status: confirmed

## Goal

Reduce residual address-generation overhead in optimized layout-fused kernels
by moving affine loop traversal into an optional hardware execution unit. A
thread dispatches three address streams, performs computation itself, pops
addresses into integer registers, and uses ordinary load/store instructions.

## Scope

- TH32, XLEN=64 configuration only.
- Dedicated `EX_AGEN` core execution unit and complete decode, dispatch,
  commit, trace, performance, and simulator integration.
- Three architectural streams per thread: `LD0`, `LD1`, and `ST`.
- Three-dimensional affine descriptors and blocking address pops.
- `eladd_layout_fused` as the only v1 feature kernel.
- Focused address-generator RTL tests plus simx and xrt-vcs integration.

## Confirmed Design Decisions

- Physical state is vector-banked per warp/lane while remaining exclusive per
  architectural thread.
- LD0, LD1, and ST use three parallel vector producers and independent queues,
  arbitration, counters, and backpressure.
- Custom instruction stream selection is compile-time encoded. Public pops are
  `pop_ld_addr(0|1)` and `pop_st_addr()`.
- Pop is atomic across active lanes and blocks until all active queues are
  non-empty. It uses normal execution-unit backpressure and scoreboard
  writeback, not warp-stall or WAIT semantics.
- Configuration uses shadow state followed by atomic `START`; `RESET` flushes
  a stream and is accepted in every state.
- The feature is optional and default configurations remain unchanged.

## Constraints and Assumptions

- Base addresses and strides are byte-addressed. Arithmetic wraps at 64 bits.
- Bounds are unsigned 32-bit values. A zero bound generates no address.
- Software issues exactly the product of the configured bounds in pops.
- State is reset and fully drained at kernel entry, segment boundaries, task
  reuse, and repeated power-kernel iterations.
- Current `eladd_layout_fused` keeps its `K % 32 == 0` precondition and handles
  final partial-M layout segments by reconfiguration.
- RTL work is gated on measured residual overhead and projected speedup.

## Final Agreed Specification

The authoritative implementation and acceptance details are in
`docs/future_optim/address_gen_for_layout_transform_fused/plan.md`. This
specification is confirmed for implementation.

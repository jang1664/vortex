# Core Pipeline HW Debug Spec

Status: confirmed

## Goal

Extend `ENABLE_HW_DEBUG_MODULE` so hardware deadlocks can be localized in the core pipeline and cache-facing paths when the exact stuck hierarchy is unknown.

## Scope

- Track core pipeline and core-visible cache/LSU valid-ready boundaries.
- Exclude GEMM-specific internals for this pass.
- Use packed structs similar to perf wiring.
- Register debug outputs at module boundaries before routing them upward.
- Keep macro-off RTL unchanged.

## Design Decisions

- Define common debug channel structs in `VX_gpu_pkg.sv`.
- Add a small reusable valid-ready probe module.
- Route a per-core `core_pipeline_debug_t` upward alongside existing `hw_debug_pc_*`.
- Let leaf/core modules expose current state only; central counters, watchdog, sticky flags, and MMIO readout live in `VX_hw_debug`.
- Reuse `debug_select[15:8]` as core id and `debug_select[23:16]` as core pipeline channel id for new core metrics.

## Constraints

- No ILA dependency for this feature.
- Avoid pulling large payloads to the AFU; route only `valid`, `ready`, `fire`, `stall`, `payload_changed`, `wid`, and a compact tag.
- The implementation must compile with and without `ENABLE_HW_DEBUG_MODULE`.

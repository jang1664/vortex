# Vortex GEMM Accelerator

## Build & Test
- GEMM node test: `cd hw/unittest/gemm_node_improve && make SIM_EXEC=vcs run M=32 N=32 K=128 QBLK=32`
- Regression: `cd hw/unittest/gemm_node_improve && bash test.sh vcs qcol`
- Success: look for `OUTPUT CHECK PASSED` in sim log

## Architecture (branch-specific — read when working on GEMM)
- @harness/docs/arch-gemm-pipeline.md — module hierarchy, data flow
- @harness/docs/isa-opcodes.md — opcode encoding, word packing, field mapping
- @harness/docs/tiling-strategy.md — SW/HW split, tile parameters, quantization modes

## Existing Project Docs
- @docs/coding_guidelines_verilog.md — RTL coding conventions
- @docs/microarchitecture.md — Vortex pipeline overview
- @docs/rtl/ — RTL module docs (mirrors hw/rtl/ structure)
- @docs/rtl/features/ — cross-cutting feature docs (pipeline stages, GBAR, perf monitoring, etc.)

## Required External Tools
Before using an external binary (e.g., `fst2vcd`, `vcs`, `gtkwave`), run `which <tool>` to verify it exists.
If missing, tell the user which tool is needed and stop — do not attempt workarounds or proceed without it.

## Critical Invariants
- Interface *_if.sv master/slave modports must always be symmetric
- `gemm_unified_cmd_t` is the single command struct for all opcodes
- SW computes all addresses, strides, and bounds; HW only routes and executes

## Harness Structure
- `harness/rules/*-common.md` — rules shared across all branches (merge-safe)
- `harness/rules/*-arch.md` — rules specific to current branch architecture
- `harness/docs/` — branch-specific architecture documentation
- `harness/hooks/` — validation scripts (common + branch-specific)
- `harness/skills/` — reusable procedures

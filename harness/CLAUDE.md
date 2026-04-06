# Vortex GEMM Accelerator

## Source Tree
- `hw/` — hardware
  - `rtl/` — RTL source (core/, cache/, mem/, tcu/, fpu/, libs/, interfaces/)
  - `unittest/` — unit tests (each dir has its own Makefile)
  - `syn/` — synthesis scripts
  - `dpi/` — DPI-C for simulation
- `kernel/` — device-side kernels (GEMM, etc.)
- `runtime/` — host-side runtime library
- `sim/` — simulator backends (simx, rtlsim, etc.)
- `tools/` — utilities (hw_draw, etc.)
- `docs/` — project documentation
- `harness/` — Claude harness (rules, docs, hooks, skills)
- `hw_arch_draw/` — architecture design JSON files
- `third_party/` — external dependencies

## Rules
- Before using an external binary (e.g., `fst2vcd`, `vcs`, `gtkwave`), run `which <tool>` to verify it exists. If missing, tell the user and stop.
- Always use `python tools/hw_draw/hw_tool.py` to read/modify hw_design_json files — do NOT edit JSON directly.

## Reference Map
- RTL work → @docs/coding_guidelines_verilog.md, @docs/microarchitecture.md
- RTL module docs → @docs/rtl/
- HW design JSON → @.claude/rules/hw-design-json.md
- GEMM architecture → @harness/docs/ (arch, ISA, tiling)
- Common rules → @harness/rules/*-common.md
- Branch-specific rules → @harness/rules/*-arch.md

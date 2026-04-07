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
  - `axi/` - AXI related library

## Rules
- The main agent must control the entire flow. When there is a specific task, first check if <subagent>.md exists, and if it does, use it. If a suitable subagent does not exist, specify which subagent is required in STATUS.md, and the main agent generates and uses <subagent>.md. Subsequently, the user will refine <subagent>.md.
- **The main agent must NOT directly modify RTL files (*.sv, *.vh, *.v).** RTL modifications must be performed through the RTL Implementation subagent (`subagent_type: "RTL Implementation"`). The main agent only diagnoses issues and delegates modification instructions to the subagent.
- **The main agent must NOT directly run tests.** Unit tests (`make run` in unittest dirs), blackbox tests (`blackbox.sh`), RTL simulations (`simv`), and verifications (`verify_rtl.py`) must be run through the Verification subagent (`subagent_type: "Verification"`). The main agent receives test results and decides the next action.
- Before using an external binary (e.g., `fst2vcd`, `vcs`, `gtkwave`), run `which <tool>` to verify it exists. If missing, tell the user and stop.
- Always use `python tools/hw_draw/hw_tool.py` to read/modify hw_design_json files — do NOT edit JSON directly.
- When starting a non-trivial task, create `docs/<task_name>/STATUS.md` and maintain it throughout the work. Log entries must include timestamps (`YYYY-MM-DD HH:MM` format, use `date` command) and cover: what was attempted, what failed and why, and what was learned. This log helps improve the harness over time.
- Context recovery is handled automatically via PreCompact hook — when compaction occurs, the hook injects instructions to re-read `docs/<task_name>/STATUS.md` for context recovery. After compaction, always follow the injected instructions to restore working context. For manual handoff (e.g., ending a session), use the `/handoff` skill.

## Reference Map
- RTL work → @docs/coding_guidelines_verilog.md, @docs/microarchitecture.md
- RTL module docs → @docs/rtl/
- HW design JSON → @.claude/rules/hw-design-json.md
- FPINT GEMM → @docs/fpint-gemm/ (arch, address space, SW stack, performance, dev notes)
- Common rules → @harness/rules/*-common.md
- Branch-specific rules → @harness/rules/*-arch.md

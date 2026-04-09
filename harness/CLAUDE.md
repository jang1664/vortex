# Vortex GEMM Accelerator

## Source Tree (Common)
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

## Rules — Common
- Before using an external binary (e.g., `fst2vcd`, `vcs`, `gtkwave`), run `which <tool>` to verify it exists. If missing, tell the user and stop.
- Always use `python tools/hw_draw/hw_tool.py` to read/modify hw_design_json files — do NOT edit JSON directly.

## Rules — Main Agent Only
- The main agent must control the entire flow. When there is a specific task, first check if <subagent>.md exists, and if it does, use it. If a suitable subagent does not exist, specify which subagent is required in STATUS.yaml, and the main agent generates and uses <subagent>.md. Subsequently, the user will refine <subagent>.md.
- **The main agent must NOT directly modify RTL files (*.sv, *.vh, *.v).** RTL modifications must be performed through the RTL Implementation subagent (`subagent_type: "RTL Implementation"`). The main agent only diagnoses issues and delegates modification instructions to the subagent.
- **The main agent must NOT directly run tests.** Unit tests (`make run` in unittest dirs), blackbox tests (`blackbox.sh`), RTL simulations (`simv`), and verifications (`verify_rtl.py`) must be run through the Verification subagent (`subagent_type: "Verification"`). The main agent receives test results and decides the next action.
- When starting a non-trivial task, create `docs/<task_name>/STATUS.yaml` and maintain it throughout the work. Log entries must include timestamps (`YYYY-MM-DD HH:MM` format, use `date` command) and cover: what was attempted, what failed and why, and what was learned. Maintain a `pitfalls` list in STATUS.yaml to record failures, confusing behaviors, and gotchas. This section serves as a persistent reference so the same mistakes are not repeated.
- **Subtask management**: Tasks can be nested recursively. Use `/create-fsm --parent <parent_path> <child_name>` to create subtasks. Each subtask has its own FSM and STATUS.yaml. When a subtask reaches DONE, update the parent's `children[].state`. `/run-fsm` accepts slash-separated paths: `/run-fsm port-scale/dma-debug`. Hooks automatically find the deepest active (non-DONE) subtask.
- Context recovery is handled automatically via PreCompact hook — when compaction occurs, the hook injects instructions to re-read `docs/<task_name>/STATUS.yaml` for context recovery. After compaction, always follow the injected instructions to restore working context. For manual handoff (e.g., ending a session), use the `/handoff` skill.

## Rules — Subagent Only
- Read the Reference Map below to find relevant docs before starting work.
- Follow your agent-specific rules defined in your agent definition file (`harness/agents/<name>.md`).
- Report results back to the main agent clearly: what was done, what succeeded, what failed.

## Reference Map (Common)
- RTL work → @docs/coding_guidelines_verilog.md, @docs/microarchitecture.md
- RTL module docs → @docs/rtl/
- HW design JSON → @.claude/rules/hw-design-json.md
- FPINT GEMM → @docs/fpint-gemm/ (arch, address space, SW stack, performance, dev notes)
- HBM / memory interleaving → @docs/hbm-bank-interleaving.md
- Task FSM schema → @docs/fsm-schema.md
- Common rules → @harness/rules/*-common.md
- Branch-specific rules → @harness/rules/*-arch.md

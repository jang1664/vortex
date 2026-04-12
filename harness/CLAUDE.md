# Vortex GEMM Accelerator

## Source Tree (Common)

```
hw/
  rtl/                             # RTL source
    core/                          #   core pipeline (fetch, issue, execute, commit)
      gemm/                        #     GEMM accelerator (node, unit, DMA ctrl, sync, local DMA)
    cache/                         #   cache hierarchy (bank, tags, data, MSHR, replacement)
    mem/                           #   memory subsystem (tensor mem, local mem, DMA engine, bus IFs)
    tcu/                           #   tensor compute unit (int/fp datapaths, BHF)
      bhf/                         #     branch history filter
    fpu/                           #   floating-point unit
      patched_cvfpu/               #     patched CVFPU library
    libs/                          #   reusable IP (arbiters, FIFOs, RAMs, multipliers, stream xbar)
    interfaces/                    #   interface definitions (pipeline IFs, bus IFs, CSR IFs)
    afu/                           #   accelerator function unit (OPAE, XRT shims)
      opae/                        #     OPAE shim
      xrt/                         #     XRT shim
    verification/                  #   verification IPs (SRAM model, FP emulator)
  unittest/                        # unit tests (each dir has its own Makefile + tb_*.sv)
    common/                        #   shared test infrastructure
    lmem_dma_misal/                #   local DMA (byte-misaligned) tests
    gemm_node*/                    #   GEMM node / node_improve / node_tmem tests
    gemm_unit/                     #   GEMM unit tests
    tmem_subsystem/                #   tensor memory subsystem tests
    tensor_mem_bank/               #   tensor memory bank tests
    cache_top/                     #   cache tests
    local_mem_top/                 #   local memory tests
    core_top/ / core_tmem/         #   core-level tests
    dma*/                          #   DMA / dma_engine / dma_node / dma_mem_unit* tests
    gemm_ctrl*/                    #   GEMM controller tests
    gemm_fsm/                      #   GEMM FSM tests
    mem_streamer/ / mem_unit_top/  #   memory streamer / unit tests
    issue_top/ / VX_job_frontend/  #   pipeline frontend tests
    fp*/                           #   FP16/FP32 add/mul, fpint_emul tests
    generic_queue/ / adder_tree*/  #   library component tests
    reformatter/ / prealigner/     #   data format tests
  syn/                             # synthesis scripts
  dpi/                             # DPI-C modules for simulation

kernel/                            # device-side kernels (run on Vortex RISC-V core)
  include/                         #   public headers (intrinsics, tensor, spawn, math)
  src/                             #   GEMM kernel, spawn, syscall, tinyprintf
  scripts/                         #   linker scripts, vxbin.py

runtime/                           # host-side runtime library (C++)
  include/                         #   public API headers
  common/                          #   shared code (scope, callbacks, JSON)
  simx/                            #   functional simulator backend
  rtlsim/                          #   Verilator RTL sim backend
  xrt/                             #   XRT (Xilinx) backend
  opae/                            #   OPAE (Intel FPGA) backend

sim/                               # simulator implementations (C++)
  common/                          #   shared (memory model, DRAM sim, softfloat, tensor config)
  simx/                            #   cycle-approximate functional simulator
  rtlsim/                          #   Verilator RTL sim wrapper
  xrtsim/                          #   XRT + Verilator integration
  xrtsim_vcs/                      #   XRT + VCS (Synopsys) RTL sim

tools/                             # utilities
  fsdb_cli/                        #   FSDB waveform analyzer (Python CLI)
  hw_draw/                         #   HW architecture visualizer (JSON + web)
  verify_rtl.py                    #   automated RTL verification

docs/                              # project documentation
  rtl/                             #   per-module RTL docs
  simulation/                      #   simulation guides (VCS, Blackbox flow)
  software/                        #   software docs (runtime, ISA, kernels)

agent-tasks/                      # Claude task FSMs, STATUS.yaml, logs
harness/                           # Claude harness
  agents/                          #   subagent definitions
  rules/                           #   *-common.md, *-arch.md
  hooks/                           #   event hooks
  skills/                          #   slash commands
hw_arch_draw/                      # architecture design JSON files
third_party/                       # external dependencies (axi/)
ci/                                # CI scripts (run_black.sh, etc.)
build/                             # build output (gitignored)
```

## Rules — Common
- All files created by the agent must be written in English. Korean is only used in conversation with the user.
- Before using an external binary (e.g., `fst2vcd`, `vcs`, `gtkwave`), run `which <tool>` to verify it exists. If missing, tell the user and stop.
- Always use `python tools/hw_draw/hw_tool.py` to read/modify hw_design_json files — do NOT edit JSON directly.

## Rules — Main Agent Only
- The main agent may edit RTL files, run tests, and perform any task directly by default. No subagent delegation is required unless the user explicitly invokes a skill (`/run-fsm`, `/rtl-improve`, etc.) that triggers FSM-driven execution.
- **When the user invokes an FSM skill:** The main agent must delegate RTL modifications to the RTL Implementation subagent and test execution to the Verification subagent. Hooks enforce this automatically while the FSM is active.
- **When no FSM skill is active:** The main agent works directly — edit code, run tests, debug — without spawning subagents.
- When starting a non-trivial task, create `agent-tasks/<task_name>/STATUS.yaml` and maintain it throughout the work. Log entries must include timestamps (`YYYY-MM-DD HH:MM` format, use `date` command) and cover: what was attempted, what failed and why, and what was learned. Maintain a `pitfalls` list in STATUS.yaml to record failures, confusing behaviors, and gotchas. This section serves as a persistent reference so the same mistakes are not repeated.
- **Subtask management**: Tasks can be nested recursively. Use `/create-fsm --parent <parent_path> <child_name>` to create subtasks. Each subtask has its own FSM and STATUS.yaml. When a subtask reaches DONE, update the parent's `children[].state`. `/run-fsm` accepts slash-separated paths: `/run-fsm port-scale/dma-debug`. Hooks automatically find the deepest active (non-DONE) subtask.
- Context recovery is handled automatically via PreCompact hook — when compaction occurs, the hook injects instructions to re-read `agent-tasks/<task_name>/STATUS.yaml` for context recovery. After compaction, always follow the injected instructions to restore working context. For manual handoff (e.g., ending a session), use the `/handoff` skill.

## Rules — Subagent Only
- Read the Reference Map below to find relevant docs before starting work.
- Follow your agent-specific rules defined in your agent definition file (`harness/agents/<name>.md`).
- Report results back to the main agent clearly: what was done, what succeeded, what failed.

## Reference Map (Common)
- RTL work → @docs/coding_guidelines_verilog.md, @docs/microarchitecture.md
- RTL module docs → @docs/rtl/
- HW design JSON → @.claude/rules/hw-design-json.md
- FPINT GEMM → @agent-tasks/port-scale/fpint-gemm-spec.md (arch, address space, SW stack, performance)
- HBM / memory interleaving → @docs/hbm-bank-interleaving.md
- Task FSM schema → @docs/fsm-schema.md
- Common rules → @harness/rules/*-common.md
- Branch-specific rules → @harness/rules/*-arch.md

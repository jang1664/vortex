# Port Scale Handoff — 2026-04-08

## Current Progress

TMEM + DMA data feeding: 8 phases of RTL implementation complete, all unit tests pass. Blackbox compile verified (Phase 9, iteration 10).

- **Phase 1-8**: All pass. New modules: VX_tensor_mem_bank, VX_dma_engine, VX_tmem_subsystem, VX_tmem_switch, VX_gemm_tmem_dma_ctrl. Modified: VX_gemm_node, VX_core, VX_mem_unit, VX_socket, VX_cluster, Vortex, Vortex_axi, VX_afu_wrap, vortex_afu.
- **Phase 9 (blackbox vecadd xrt_vcs)**: 10 iterations. Compile PASS with all DBG_TRACE defines. Sim FAIL — pre-existing X propagation bug (original codebase also fails). Previous iteration may have stopped too early (PC is normally `x` during reset).
- **Harness improvements this session**:
  - bash-guard.sh: checks `agent_type` field — Verification subagent passes through, main agent blocked
  - rtl-edit-guard.sh: new script, checks `agent_type` — RTL Implementation subagent passes through
  - debug-xrt-vcs SKILL: two-level debugging guide (log-based → waveform/pywellen)
  - Verification agent: `skills: [debug-xrt-vcs, run-bb-common]` preloaded
  - RTL impl agent: `docs/fpint-gemm/` index table added for selective doc reading
  - rtl-improve SKILL: "Announce & Proceed" autonomous flow + blocking rule (no skipping failures)
  - Task renamed: `docs/rtl-improve/` → `docs/port-scale/`

## Key Decisions Made

1. Hook-based agent type checking: `agent_type` field in PreToolUse hook input distinguishes main agent from subagents
2. "Announce & Proceed" pattern instead of asking user — auto-decide next task and proceed immediately
3. Blocking rule: never skip a failing task to the next one — must resolve or user explicitly defers
4. Two-level debugging: log-based (`simv.log`) first, waveform (`FSDB→FST→pywellen`) second
5. If log traces insufficient, request RTL impl agent to add `DBG_TRACE_*` statements, then re-run
6. Task rename: `rtl-improve` → `port-scale` to avoid confusion with the skill name

## Remaining Work

1. **Blackbox vecadd xrt_vcs sim failure**: Pre-existing bug. The previous Verification run may have misdiagnosed — PC is normally `x` during reset. Re-run and analyze `simv.log` more carefully (check PC after reset period). Use the `debug-xrt-vcs` skill's Level 1 approach. Delegate to Verification subagent:
   ```
   cd build
   CONFIGS=""
   CONFIGS+=" -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
   CONFIGS+=" -DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8"
   CONFIGS+=" -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=8585740288"
   CONFIGS+=" -DDBG_TRACE_PIPELINE -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_AFU -DDBG_TRACE_SCOPE -DDBG_TRACE_GBAR -DDBG_TRACE_TCU -DDBG_TRACE_GEMM"
   CONFIGS+=" -DAFU_DONE_WAIT_CACHE_DRAIN"
   PATH=/usr/bin:$PATH CONFIGS="$CONFIGS" timeout 300 ./ci/blackbox.sh --driver=xrt_vcs --app=vecadd --args="-n64" --cores=1 --threads=8 --debug=3
   ```
2. **fpint_gemm_ffn_hw blackbox**: Update kernel for MMIO → cmd store flow, then run blackbox (blocked by #1)
3. **Re-enable DMA AXI mux**: DMA ports may be tied off in Vortex_axi.sv for bring-up (blocked by #1)
4. **Re-enable LSU interleaved routing**: Restore `lsu_aw_select = addr[8:6]` (blocked by #1)

## Gotchas

- Conda linker conflict: use `PATH=/usr/bin:$PATH` workaround for VCS builds
- `ASSERTS_OFF` define required to avoid macro conflict between Vortex and common_cells
- DBG_TRACE blocks are NOT compiled in unit tests — bugs there only surface in blackbox with full CONFIGS
- PC is `x` during reset — this is normal. Only flag X propagation if PC stays `x` after reset completes
- Always use `/run-bb-common` skill CONFIGS for blackbox — never run with empty CONFIGS
- Main agent must NOT edit RTL files or run tests directly — hooks enforce this via `agent_type` check
- Hooks apply to ALL agents (main + sub) — use `agent_type` field to allow subagents through

## Reference Files

- `docs/port-scale/STATUS.md` — iteration log (all phases)
- `docs/port-scale/tmem-dma-spec.md` — TMEM+DMA spec document
- `docs/fpint-gemm/` — FPINT GEMM architecture docs (architecture, address-space, sw-stack, etc.)
- `harness/skills/rtl-improve/SKILL.md` — rtl-improve loop skill (with Announce & Proceed + blocking rule)
- `harness/skills/run-bb-common/SKILL.md` — blackbox test configs and commands
- `harness/skills/debug-xrt-vcs/SKILL.md` — xrt_vcs debugging guide (log-based + waveform)
- `harness/skills/handoff/SKILL.md` — handoff skill
- `harness/agents/verification.md` — Verification agent definition (preloads debug-xrt-vcs, run-bb-common)
- `harness/agents/rtl-impl.md` — RTL Implementation agent definition (fpint-gemm doc index)
- `harness/settings.json` — hooks config
- `harness/hooks/bash-guard.sh` — Bash PreToolUse hook (agent_type aware)
- `harness/hooks/rtl-edit-guard.sh` — RTL edit PreToolUse hook (agent_type aware)
- `CLAUDE.md` — project rules

# RTL Improve Handoff — 2026-04-07

## Current Progress

TMEM + DMA data feeding: 8 phases of RTL implementation complete, all unit tests pass.

- **Phase 1-8**: All pass. New modules: VX_tensor_mem_bank, VX_dma_engine, VX_tmem_subsystem, VX_tmem_switch, VX_gemm_tmem_dma_ctrl. Modified: VX_gemm_node, VX_core, VX_mem_unit, VX_socket, VX_cluster, Vortex, Vortex_axi, VX_afu_wrap, vortex_afu.
- **Phase 9 (blackbox vecadd xrt_vcs)**: 9 iterations. Compile errors fixed (AXI includes, cf_math_pkg, ASSERT macro, DBG_TRACE `req_ready_mux`). Sim failures hit pre-existing xrt_vcs bug (original codebase also fails). DBG_TRACE fix (iteration 9) not yet re-tested with correct CONFIGS.
- **Harness improvements this session**:
  - CLAUDE.md: Added rules — main agent must not edit RTL or run tests directly
  - PreToolUse hooks: RTL edit guard (Edit|Write), test execution guard (merged into `bash-guard.sh`)
  - PreCompact hook: auto-injects STATUS.md recovery instructions after compaction
  - Created `/handoff` skill, iteration log consolidated into STATUS.md

## Key Decisions Made

1. Main agent delegates RTL edits to RTL Implementation subagent — enforced by PreToolUse hook on Edit|Write
2. Main agent delegates test execution to Verification subagent — enforced by bash-guard.sh (merged with conda-inject)
3. Two Bash hooks merged into `harness/hooks/bash-guard.sh` — stdin can only be consumed once per hook entry
4. Iteration logs consolidated into `docs/rtl-improve/STATUS.md` (not separate `*-log.md`)
5. Context recovery via PreCompact hook instead of manual "60% → handoff → /clear" flow
6. vecadd xrt_vcs failure (iterations 5-8) confirmed as pre-existing bug — not caused by TMEM/DMA changes

## Remaining Work

1. **Blackbox vecadd xrt_vcs**: Re-run with correct CONFIGS (use `/run-bb-common` skill). The DBG_TRACE fix from iteration 9 needs verification. Delegate to Verification subagent:
   ```
   cd build
   CONFIGS=""
   CONFIGS+=" -DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE"
   CONFIGS+=" -DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8"
   CONFIGS+=" -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=8585740288"
   CONFIGS+=" -DDBG_TRACE_PIPELINE -DDBG_TRACE_MEM -DDBG_TRACE_CACHE -DDBG_TRACE_AFU -DDBG_TRACE_SCOPE -DDBG_TRACE_GBAR -DDBG_TRACE_TCU -DDBG_TRACE_GEMM"
   CONFIGS+=" -DAFU_DONE_WAIT_CACHE_DRAIN"
   CONFIGS="$CONFIGS" ./ci/blackbox.sh --driver=xrt_vcs --app=vecadd --args="-n64" --cores=1 --threads=8 --debug=3
   ```
2. **fpint_gemm_ffn_hw blackbox**: Update kernel for MMIO → cmd store flow, then run blackbox
3. **Re-enable DMA AXI mux**: DMA ports may be tied off in Vortex_axi.sv for bring-up
4. **Re-enable LSU interleaved routing**: Restore `lsu_aw_select = addr[8:6]`

## Gotchas

- Conda linker conflict: use `PATH=/usr/bin:$PATH` workaround for VCS builds
- `ASSERTS_OFF` define required to avoid macro conflict between Vortex and common_cells
- DBG_TRACE blocks are NOT compiled in unit tests — bugs there only surface in blackbox with full CONFIGS
- Two Bash PreToolUse hooks cannot coexist as separate matcher entries — first `cat` consumes stdin
- Always use `/run-bb-common` skill CONFIGS for blackbox — never run with empty CONFIGS
- Main agent must NOT edit RTL files or run tests directly — hooks enforce this

## Reference Files

- `docs/rtl-improve/STATUS.md` — iteration log (all phases)
- `docs/rtl-improve/tmem-dma-spec.md` — TMEM+DMA spec document
- `harness/skills/rtl-improve/SKILL.md` — rtl-improve loop skill
- `harness/skills/run-bb-common/SKILL.md` — blackbox test configs and commands
- `harness/skills/handoff/SKILL.md` — handoff skill
- `harness/settings.json` — hooks config (RTL guard, test guard, conda inject, PreCompact)
- `harness/hooks/bash-guard.sh` — merged Bash PreToolUse hook
- `harness/hooks/pre-compact.sh` — PreCompact context recovery hook
- `CLAUDE.md` — project rules (RTL/test delegation, context recovery)

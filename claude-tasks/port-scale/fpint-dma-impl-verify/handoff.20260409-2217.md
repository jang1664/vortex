# FPINT DMA Implementation & Verification Handoff — 2026-04-09

## Current Progress

FSM state: **ANALYZE** (blackbox test failed → returned to analyze HBM address mapping)

### Completed RTL changes (uncommitted):
1. **VX_tmem_subsystem.sv**: Removed DMA switch (u_switch_dma). DMA ch b → bank b direct 1:1 wiring with tag width adaptation (zero-pad req, truncate rsp).
2. **VX_gemm_tmem_dma_ctrl.sv**: Bus-word (64B) granularity decomposition. Per-channel seg_size via quotient/remainder. Inactive channels get seg_size=0. `done_if.ready` extended to S_WAIT_DONE || S_DONE (deadlock fix).
3. **Testbench** (`hw/unittest/gemm_node_improve/`): Updated for new AXI DMA interface — removed old VX_dma_node/LMEM path, added behavioral AXI slave memory model with address translation.
4. **Spec** (`claude-tasks/port-scale/fpint-gemm-spec.md`): Major update — INTERLEAVE mode, HMSS constraint, naming (NUM_HBM_MAS_PORTS), simulation memory model.

### Test results:
- tensor_mem_bank unit test: **PASS**
- gemm_node_improve M=32 N=32 K=128: **PASS** (all 1024 elements correct)
- fpint_gemm_ffn_hw_improve blackbox (xrt_vcs): **FAIL** — no deadlock, but 64 data mismatches

## Key Decisions Made

1. **DMA decomposition at bus-word granularity (64B)**, not byte-level (>>3). Fixes sub-bus-word partial writes for small transfers (scale 256B).
2. **INTERLEAVE=1 mode only** for DMA implementation. INTERLEAVE=0 (contiguous for HMSS) is documented as hard constraint but not implemented yet.
3. **HBM side: original SW interleaved address** on AXI output (identity in INTERLEAVE=1). AXI mux routes by addr[8:6].
4. **TMEM side: bank-local address** = `(dst_base >> 9) << 6`, stride=64 contiguous.
5. **xrt_sim_vcs**: `to_software_addr` should be removed. Pass AXI addr through to RAM directly.
6. **Naming**: `NUM_HBM_MAS_PORTS`(=8) replaces `C_M_AXI_MEM_NUM_BANKS`/`NUM_BANKS` in AXI context. `NUM_TMEM_BANKS`(=8) for TMEM. `PLATFORM_MEMORY_NUM_BANKS`(=32) stays.

## Remaining Work

1. **Fix HBM address mismatch in blackbox** — Root cause: `xrt_sim_vcs.cpp::to_software_addr` uses PLATFORM_MEMORY_NUM_BANKS=32, but DMA sends INTERLEAVE=1 identity addresses. The sim should pass AXI addr through directly (no conversion). Need to:
   - Modify `sim/xrtsim_vcs/xrt_sim_vcs.cpp`: replace `to_software_addr(bank_id, addr)` with direct `addr` usage for AXI read/write events
   - Verify host-side mem_write/mem_read (DCR path) still works correctly
   - Re-run blackbox test

2. **DMA decomposition: HBM side addressing** — Current implementation uses `ch_src_base = src_base + ch*64, stride=512` which produces original interleaved addresses. Verify this is correct with the xrt_sim_vcs fix above.

3. **Re-run blackbox**: After xrt_sim_vcs fix:
   ```bash
   cd build
   rm -rf sim/xrtsim_vcs/simv sim/xrtsim_vcs/simv.daidir sim/xrtsim_vcs/csrc
   CONFIGS="-DMEM_ADDR_WIDTH=34 -DPLATFORM_MEMORY_ADDR_WIDTH=34 -DPLATFORM_MEMORY_NUM_BANKS=32 -DPLATFORM_MERGED_MEMORY_INTERFACE -DDCACHE_DISABLE -DL2_ENABLE -DNUM_THREADS=8 -DLMEM_LOG_SIZE=22 -DSTACK_BASE_ADDR=8585740288 -DDBG_TRACE_GEMM -DAFU_DONE_WAIT_CACHE_DRAIN"
   PATH=/usr/bin:$PATH timeout 1800 bash -c "CONFIGS=\"$CONFIGS\" ./ci/blackbox.sh --driver=xrt_vcs --app=fpint_gemm_ffn_hw_improve --cores=1 --threads=8 --debug=3"
   ```

4. **Rename** `C_M_AXI_MEM_NUM_BANKS` → `NUM_HBM_MAS_PORTS` in RTL and TB files (non-blocking, can do after functional verification).

## Gotchas

- **>>3 byte-level decomposition is WRONG** for sub-bus-word transfers. Must use bus-word (64B) granularity.
- **done_if.ready race**: must assert during BOTH S_WAIT_DONE and S_DONE states. Otherwise DMA channels deadlock on second command.
- **VCS simv caches RTL**: always `rm -rf simv simv.daidir csrc` after RTL changes before blackbox test.
- **Build from source tree for unit tests**: `make -C hw/unittest/<test>` from source tree (not build tree) — TB .sv files aren't copied to build.
- **PLATFORM_MEMORY_NUM_BANKS=32 vs NUM_HBM_MAS_PORTS=8 vs NUM_TMEM_BANKS=8**: three different "8" or "32" values. Don't confuse.
- **dma_engine test**: missing `hw/unittest/common/AXI_BUS_if.sv` — can't run until created.

## Reference Files

- **Spec**: `claude-tasks/port-scale/fpint-gemm-spec.md` (sections 4.4, 4.7, 4.8 most relevant)
- **STATUS**: `claude-tasks/port-scale/fpint-dma-impl-verify/STATUS.yaml`
- **FSM**: `claude-tasks/port-scale/fpint-dma-impl-verify/fsm.json`
- **Modified RTL**: `hw/rtl/mem/VX_tmem_subsystem.sv`, `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- **Modified TB**: `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`, `Makefile`
- **Sim to fix**: `sim/xrtsim_vcs/xrt_sim_vcs.cpp` (to_software_addr removal)
- **Test plan**: `harness/rules/testing-tmem-dma.md`
- **AXI adapter reference**: `hw/rtl/libs/VX_axi_adapter.sv` (INTERLEAVE mode, lines 124-140, 255-256)

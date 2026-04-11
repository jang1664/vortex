# Port Scale Handoff — 2026-04-08

## Current Progress

TMEM + DMA data feeding: 10 phases of RTL implementation complete, all unit tests pass. Blackbox vecadd passes with xrt_vcs. fpint_gemm_ffn_hw_improve blackbox blocked on BANK_INTERLEAVE mismatch.

- **Phase 1-8**: All pass. New modules: VX_tensor_mem_bank, VX_dma_engine, VX_tmem_subsystem, VX_tmem_switch, VX_gemm_tmem_dma_ctrl. Modified: VX_gemm_node, VX_core, VX_mem_unit, VX_socket, VX_cluster, Vortex, Vortex_axi, VX_afu_wrap, vortex_afu.
- **Phase 9 (blackbox vecadd xrt_vcs)**: 11 iterations. Final: PASS (10118 insn, IPC=0.817). Root cause was `xrt_sim_vcs.cpp` using wrong bank count (`PLATFORM_MEMORY_NUM_BANKS` instead of `NUM_DMA_CHANNELS`) and wrong allocator base.
- **Phase 10 (DMA mux + LSU routing)**: PASS. Re-enabled DMA AXI connections via `AXI_ASSIGN_TO_REQ`/`AXI_ASSIGN_FROM_RESP` macros and address-based LSU interleaved routing.
- **Phase 11 (merged-interface DMA mux + kernel rewrite)**: BLOCKED. Merged-interface mux correctly connects all 8 DMA channels. fpint_gemm_ffn_hw kernel rewritten from 40-reg MMIO to command-stream flow. Blackbox test fails — DMA AXI read hangs. **Blocked on BANK_INTERLEAVE mismatch.**
- **Merge cleanup**: unittest Makefiles fixed for build-dir execution (absolute paths via MAKEFILE_LIST). Regression test renamed to `fpint_gemm_ffn_hw_improve`.
- **Uncommitted**: `docs/port-scale/STATUS.md` only.

## Key Decisions Made

1. `xrt_sim_vcs.cpp` uses `NUM_DMA_CHANNELS` (=8) for bank count, matching runtime's dev_caps. Linear mapping `bank_id * mem_bank_size_ + addr` for non-interleave mode.
2. Merged-interface (NUM_HBM_PORTS=1): all 8 DMA channels feed into single axi_mux. `NUM_DMA_PER_MUX` localparam + generate-if distinguishes merged vs non-merged.
3. `SpillAr` set to `1'b0` (diagnostic) to rule out AR channel starvation in axi_mux.
4. BANK_INTERLEAVE mismatch must be resolved BEFORE DMA debugging. RTL assumes interleaved addressing but runtime has `BANK_INTERLEAVE` commented out.
5. Regression test is `fpint_gemm_ffn_hw_improve` (not `fpint_gemm_ffn_hw`).
6. Unittest Makefiles use `MAKEFILE_LIST`-based absolute paths — run from build dir via `make -C`.

## Remaining Work

1. **BANK_INTERLEAVE fix** (blocker): Uncomment `#define BANK_INTERLEAVE` in `runtime/xrt/vortex.cpp` line 50. Then fix `xrt_sim_vcs.cpp` to use interleaved address mapping (need `interleaved_addr()` function). Run vecadd:
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
2. **fpint_gemm_ffn_hw_improve blackbox**: After BANK_INTERLEAVE fix. DMA AXI read hang may resolve once address mapping is consistent.
3. **TMEM/DMA unittest Makefiles**: 7 test folders (`hw/unittest/{dma_engine,core_tmem,tensor_mem_bank,tmem_subsystem,gemm_node_tmem,vortex_afu,vortex_axi_tmem}`) have only build artifacts, no Makefile/tb source.

## Gotchas

- Conda linker conflict: always use `PATH=/usr/bin:$PATH` for VCS builds
- `ASSERTS_OFF` define required for common_cells compatibility
- `GEMM_REG_BASE_ADDR` in `VX_config.h` uses Verilog underscore hex (`0x0000_0000_0000_1080`) — invalid in C++. Kernel uses hardcoded C-compatible constant.
- PC is `x` during reset — normal. Only flag X propagation if PC stays `x` after reset.
- Main agent must NOT edit RTL or run tests — hooks enforce via `agent_type` check.
- `runtime/xrt/vortex.cpp` (NOT `vortex_v2.cpp`) is the active runtime. `BANK_INTERLEAVE` on line 50 is commented out.
- `docs/hbm-bank-interleaving.md` has reference material for the interleaving scheme.
- Unittest: run from build dir with `make -C ../hw/unittest/<name> run`. Do NOT create `hw/config.mk` symlink.

## Reference Files

- `docs/port-scale/STATUS.md` — full iteration log (all phases)
- `docs/port-scale/tmem-dma-spec.md` — TMEM+DMA spec
- `docs/hbm-bank-interleaving.md` — HBM bank interleaving reference
- `docs/fpint-gemm/` — FPINT GEMM architecture docs
- `runtime/xrt/vortex.cpp` — active XRT runtime (line 50: BANK_INTERLEAVE)
- `sim/xrtsim_vcs/xrt_sim_vcs.cpp` — VCS sim backend (address mapping)
- `sim/xrtsim/xrt_sim.cpp` — Verilator sim backend (reference)
- `hw/rtl/Vortex_axi.sv` — AXI mux/demux with merged-interface support
- `tests/regression/fpint_gemm_ffn_hw_improve/` — target regression test
- `harness/rules/testing-tmem-dma.md` — test plan and commands
- `harness/skills/run-bb-common/SKILL.md` — blackbox test configs
- `harness/skills/debug-xrt-vcs/SKILL.md` — xrt_vcs debugging guide

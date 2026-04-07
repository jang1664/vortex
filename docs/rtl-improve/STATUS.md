# RTL Improve — STATUS

## TMEM + DMA Data Feeding

### Phase 1: VX_tensor_mem_bank — Iteration 1
- **Status**: pass
- **Tests**: basic write/read, cross-port write/read, byte-enable partial write, concurrent multi-port requests, backpressure handling (7/7 pass)
- **Lesson**: `TAG_WIDTH` must be >= `UUID_WIDTH` (44 in debug builds)
- **Files created**: `hw/rtl/mem/VX_tensor_mem_bank.sv`, `hw/unittest/tensor_mem_bank/`

### Phase 2: VX_dma_engine — Iteration 1
- **Status**: pass
- **Tests**: compile + 200-cycle idle smoke (NUM_CHANNELS=2)
- **Lesson**: VX_axi_adapter outputs 2-bit lock, AXI_BUS uses 1-bit — take bit [0]
- **Files created**: `hw/rtl/mem/VX_dma_engine.sv`, `hw/unittest/dma_engine/`

### Phase 3: VX_tmem_subsystem — Iteration 1
- **Status**: compile_error
- **Error summary**: `VX_tmem_switch.sv:78` — non-constant interface array index
- **Fix applied**: genvar + wire array extraction pattern

### Phase 3: VX_tmem_subsystem — Iteration 2
- **Status**: pass
- **Lesson**: Never index interface arrays with runtime variables in VCS.
- **Files created**: `hw/rtl/mem/VX_tmem_subsystem.sv`, `hw/rtl/mem/VX_tmem_switch.sv`, `hw/unittest/tmem_subsystem/`

### Phase 4: VX_gemm_node modification — Iteration 1
- **Status**: pass
- **Tests**: compile + 200-cycle idle smoke (54 modules elaborated)
- **Files modified**: `hw/rtl/core/gemm/VX_gemm_node.sv`

### Phase 5: VX_core + VX_mem_unit — Iterations 1-3
- **Status**: pass (compile), after 2 param fixes
- **Lesson**: VX_config_reg_if DW parameter must be set at interface instantiation site.
- **Files modified**: `hw/rtl/core/VX_core.sv`, `hw/rtl/core/VX_mem_unit.sv`, `hw/rtl/VX_gpu_pkg.sv`, `hw/rtl/VX_socket.sv`, `hw/rtl/core/VX_core_top.sv`

### Phase 6: DMA config controller — Iteration 1
- **Status**: pass
- **Tests**: 118 modules compiled, compile check passed
- **Files created**: `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- **Files modified**: `hw/rtl/core/gemm/VX_gemm_node.sv` (integrated controller, removed cfg/done ports), `hw/rtl/core/VX_core.sv`, `hw/rtl/VX_socket.sv`, `hw/rtl/core/VX_core_top.sv`

### Phase 7: Upper hierarchy AXI routing — Iteration 1
- **Status**: pass
- **Tests**: 136 modules compiled, full Vortex_axi elaboration succeeded
- **Architecture**: 
  - DMA AXI ports threaded: VX_core → VX_socket → VX_cluster → Vortex → Vortex_axi
  - LSU path: VX_axi_adapter → axi_demux (1:8 by address)
  - Per HBM port: axi_mux merges LSU demux output + DMA channels from all cores
  - Output: 8 HBM AXI master ports
- **Lesson**: ASSERTS_OFF define needed to avoid macro conflict between Vortex and common_cells assert macros
- **Files modified**: `hw/rtl/VX_config.vh`, `hw/rtl/VX_socket.sv`, `hw/rtl/VX_cluster.sv`, `hw/rtl/Vortex.sv`, `hw/rtl/Vortex_axi.sv`
- **Files created**: `hw/unittest/vortex_axi_tmem/`

### Phase 8: VX_afu_wrap + vortex_afu — Iteration 1
- **Status**: pass
- **Tests**: 138 modules compiled, vortex_afu simulation passed
- **Fix applied**: Updated VX_afu_wrap.sv and vortex_afu.v for 8 HBM ports (C_M_AXI_MEM_NUM_BANKS → NUM_DMA_CHANNELS)
- **Lesson**: Conda linker conflict required `PATH=/usr/bin:$PATH` workaround
- **Files modified**: `hw/rtl/afu/xrt/VX_afu_wrap.sv`, `hw/rtl/afu/xrt/vortex_afu.v`
- **Files created**: `hw/syn/unittest/vortex_afu/`

### Phase 9: Blackbox vecadd (xrt_vcs) — Iteration 1
- **Status**: compile_error
- **Error summary**: `axi/typedef.svh` not found — xrtsim_vcs Makefile missing AXI include paths
- **Fix applied**: Added AXI_DIR, AXI_COMMON_CELLS_DIR, RTL_INCLUDE, RTL_PKGS to sim/xrtsim_vcs/Makefile

### Phase 9: Blackbox vecadd (xrt_vcs) — Iteration 2
- **Status**: compile_error
- **Error summary**: `cf_math_pkg::idx_width` not found — cf_math_pkg in cvfpu is inside `ifdef FPU_FPNEW`
- **Fix applied**: Added conditional cf_math_pkg compilation (only when FPU_FPNEW not defined)

### Phase 9: Blackbox vecadd (xrt_vcs) — Iteration 3
- **Status**: compile_error
- **Error summary**: `ASSERT` macro conflict (2-arg Vortex vs 5-arg common_cells)
- **Fix applied**: Added `+define+ASSERTS_OFF` to VCS_FLAGS

### Phase 9: Blackbox vecadd (xrt_vcs) — Iteration 4
- **Status**: sim_fail
- **Error summary**: `REG_READ: offset=0x00 value=0x0000000x` — X propagation in AFU status register, simv aborts
- **Root cause**: Bank count mismatch. DUT has 8 HBM AXI ports, but tb_vcs_xrtsim + runtime expect PLATFORM_MEMORY_NUM_BANKS=2. AXI requests on banks 2-7 have no memory model, causing X.
- **Files modified**: `sim/xrtsim_vcs/Makefile` (AXI deps), `sim/xrtsim_vcs/tb_vcs_xrtsim.sv` (bank count)

### Phase 9: Blackbox vecadd (xrt_vcs) — Iterations 5-8
- Fixed: TB AXI port count (REPEAT NUM_DMA_CHANNELS for TB_AXI_MEM_CONNECT)
- Fixed: VX_afu_ctrl dev_caps bank count (NUM_HBM_PORTS instead of PLATFORM_MEMORY_NUM_BANKS)
- Fixed: Runtime BANK_INTERLEAVE mode enabled + interleaved_addr() in DPI memory model
- Fixed: GEMM_ARB_ROUTE_TAG_BITS = 0 (GEMM no longer accesses LMEM)
- Fixed: LSU routed to bank 0 only (simplified for bring-up)
- **Status**: sim_fail — X propagation on `mem_req_valid[0]` (Vortex output). Processor starts but immediately goes to undefined state. No AXI memory traffic appears at all.
- **Root cause (suspected)**: DMA AXI interface initialization — X on valid/ready signals from inactive DMA ports may propagate through axi_mux into the LSU path, or there's a structural connectivity issue in the Vortex → Vortex_axi interface chain.
- **Resolution**: Tested with `git stash` (all TMEM changes reverted) — **original codebase also fails with same error**. This is a pre-existing xrt_vcs bug, not caused by TMEM/DMA changes. Blackbox vecadd was already broken before our work.

### Phase 9: Blackbox vecadd (xrt_vcs) — Iteration 9
- **Status**: compile_error
- **Error summary**: `VX_tmem_switch.sv:137` — `req_ready_mux` identifier not declared (only triggered with `-DDBG_TRACE_MEM`)
- **Fix applied**: Changed `req_ready_mux` to `bus_in_if.req_ready` in DBG_TRACE_MEM block
- **Lesson**: DBG_TRACE blocks are not compiled in unittest (no trace defines), so bugs there only appear in blackbox runs with full CONFIGS

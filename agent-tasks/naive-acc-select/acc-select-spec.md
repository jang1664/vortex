# Naive ACC selection — confirmed

2026-09-15 confirmed extension: measure ACC ON with (LMEM ports=banks, DMA B/cycle) = (16,64) and (32,64), M4/M256 K=N512 q32 qdir=0 transpose=0 repeat=1. Reuse existing all_bram configs and VCS runner; no RTL changes. Add validated results and naive/improve ratios to the latency document so measured ON/OFF topology rows are symmetric.

Implement GEMM_NAIVE_USE_ACC_MEM: absent preserves current LMEM naive; present reuses VX_gemm_acc_internal unchanged with existing common compute. No duplicate SRAM, conversion, or hazard backend. ACC stores intermediate and final FP32; existing VX_lmem_dma_misal DIR=1 copies converted output into existing final_raw_bus_if and physical-commit tracking, before existing HBM STORE.

ACC address: n0*MT*4 + row*MXU_COL*4, base zero. Set existing final command address/stride to ACC equivalents. Output DMA uses FP16 virtual source addresses (ACC byte address / 2): segment MXU_COL*2; row bound mt_eff, source stride MXU_COL*2, destination stride NT*2; column-block bound ceil(nt_eff/MXU_COL), source stride MT*MXU_COL*2, destination stride MXU_COL*2. Copy full padded microtile rows, external STORE only valid columns. Preserve ABI and allocated LMEM buffers.

Node selects backend and excludes LMEM PSUM-only logic under ACC mode while keeping final-write path. DMA executor adds guarded local-output DMA control and drain input, pre-STORE start/wait; LOAD unchanged. Preserve terminal/writeback identity and existing next-owner STORE fence. Wait for local DMA lifecycle completion AND physical write drain. Reuse O_LMEM DMA settings and GEMM_ACC memory settings. Keep improve selected RTL and cycles identical; no synthesis.

Tests: existing ACC and backpressure unit tests; ACC ON/OFF blackbox M4/M256 K=N512 q32; supported small M1/M3, single/multiple K tiles, N tail, sequential tiles and output stalls. Compare numeric results, GEMM/core cycles, ACC copy duration and PSUM traffic. Baseline L32 D256 all_bram, append define for ON without editing original config. Source config and configure build before tests. Use ci/run_black.sh xrt-vcs-sim only. Review final diff and preserve user AGENTS.md edits.

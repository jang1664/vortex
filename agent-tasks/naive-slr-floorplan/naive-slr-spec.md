# Confirmed naive SLR plan

User approved implementation and requires build/hw/syn/xilinx/xrt/run_hw.sh for PnR.
Target: naive_th16_tcol16_m16_L16_bigmem_all_bram, 100 MHz, first physical result (no timing optimization loop).
SLR0: complete DMA node. SLR1: mem_unit, naive node except MXU, local transport endpoints. SLR2: MXU and input RX/weight RX/output TX.
Use existing GEMM_SLR_PIPELINE for MXU. Add naive-only MMIO per-master and memory per-lane/global credit transports (depth 4, no launch buffer), bank commit two-FF return and completion drain gating. Guard new RTL from improve and preserve SLR-off behavior. PERF snapshot transport if enabled.
Preserve improve preprocessed RTL and zero GEMM/core cycle delta without improve synthesis.
Tests: transport/backpressure/reset/commit/drain; naive integration SLR on/off; blackbox M/N/K 4/16/64,16/16/64,4/512/512,256/512/512 both modes; SLR-on tagged 16/64/64 four WTRANS/QDIR combinations repeated twice. QBLK32.
Floorplan: backend-specific ownership/geometry/root/required groups; retain improve rules; direct marked FF pairs and actual SLR checks; zero Laguna pair warning only.
PnR: configured build, fresh postfix, wrapper --config naive_th16_tcol16_m16_L16_bigmem_all_bram --postfix naive_slr_100m_v1 --slr-floorplan 1 --no-early-fail FAST_MODE=0. No PERF/debug for PnR.

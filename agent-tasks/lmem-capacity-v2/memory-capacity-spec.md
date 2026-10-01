# Memory capacity correction — confirmed

User approved implementation of the plan on 2026-10-01.

## Configuration targets
- C1: clone configs/tcu_th16_c1.sh to tcu_th16_c1_v2.sh; LMEM_LOG_SIZE=21, LMEM 2 MiB; alias tcu_th16_c1_mem_v2.
- C2/C3: recreate the existing *_base_pnr_v2.sh from the corresponding original *_base_pnr.sh, preserving DCACHE_NUM_BANKS=4 and L1_MEM_PORTS=2. LMEM_SIZE=1572864, LMEM_LOG_SIZE=21, GEMM_ACC_MEM_DEPTH=2048 (512 KiB at MXU_COL=16, four FP32 banks).
- C4: clone the mapped configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh to improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.sh; keep LMEM 1 MiB and TMEM 8x65536 bytes; ACC depth 2048. Preserve the existing all_bram_v2 DMA variant. Alias improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v2.
- Keep all non-memory settings and historical aliases/binaries unchanged.

## RTL and software contract
- Add LMEM_SIZE in bytes with legacy default (1 << LMEM_LOG_SIZE). LMEM_LOG_SIZE remains ceiling log2 address envelope, explicitly configured for fractional capacities.
- Use actual size for SRAM depth, CPU address classification, software allocation bounds, softmax capacity, and simulation shadow storage. Use ceiling widths for addresses; keep transaction tags and ready/valid architecture unchanged.
- Require positive/aligned size, power-of-two bank count, and envelope consistency. Simulation must detect out-of-range bank accesses.
- At XLEN64 and 16 banks, 1.5 MiB means bank depth 12288 words, bank address width 14 bits.
- XRT exact-size capability: bit 7 of DEV_CAPS LMEM byte marks exact-size MMIO support, lower bits retain address log size. Read-only exact LMEM byte-size register at 0xD0, emitted only for explicit LMEM_SIZE override. IP packaging must declare it and reject collisions. Default power-of-two configs select the legacy RTL branch, preserving improve.
- Updated XRT runtime supports old bitstreams and reads the exact register only when marked. Public vx_dev_caps API stays unchanged. New fractional-capacity hardware requires the updated runtime.

## Verification
- Use fresh configured builds: ../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex.
- VCS unit tests: LMEM 1/1.5/2 MiB, first/last word per bank, 1 MiB boundary, byte masks, conflicts, response backpressure, tags, negative range access. ACC bank depth 2047 accesses for 512 KiB profiles.
- Full-system functionality through ci/run_black.sh xrt-vcs-sim only. CPU capacity test for all configs; sgemm_tcu for C1/C2; fpint_gemm_ffn_hw_naive for C2/C3; fpint_gemm_ffn_hw for C4; qrow/qcol, wtrans, small and >128 tile shapes, repeat/lifecycle.
- Add --lmem-offset to existing naive host scratch allocator, default zero; exercise offset 1 MiB and reject out-of-capacity placement.
- Compare baseline and changed RTL under original C4 config: selected RTL identity, capacities, ready/valid, and zero GEMM/core-cycle delta. No improve GEMM-node synthesis/resource matching.
- Capture deterministic verify_rtl.py reports, command/config hashes, logs and failures; don't proceed to PnR before verification/preservation gate passes.

## PnR
Run full U55C 100 MHz builds C1,C2,C3,C4 sequentially in isolated build outputs using configured run_hw.sh. FAST_MODE=0, PERF/DEBUG off, inherited directives, fresh synthesis after capacity changes. Archive config/RTL fingerprints, RAM inference, routed timing/DRC/utilization, xclbin and command logs. Add aliases pointing at completed binary directories only after success. No hardware measurements or latency/energy regeneration in this task.

## Scope update — confirmed
User explicitly requested no PnR on 2026-10-01. Complete implementation, VCS unit/full-system tests and original C4 preservation only. Do not launch PnR, synthesis, or hardware measurements. Do not create aliases pointing to nonexistent corrected binaries.

# Candidate SRAM capacity and BRAM accounting

분석 대상: `candidate_fpga_bins.yaml`의 현재 C1–C4. 계산은 각 FPGA build의 `manifest.json`에 저장된 CONFIGS와 해당 build의 `src/` RTL snapshot을 기준으로 한다. 현재 작업 트리의 다른 config 또는 v2 후보에는 적용하지 않는다.

## 1. 주요 데이터 SRAM의 논리 용량

단위: KiB = 1,024 bytes, MiB = 1,048,576 bytes. 모든 후보는 cluster 1개, core 1개, I/D-cache instance 각각 1개다. cache data, LMEM, TMEM, accumulator를 합산한다. cache tag/valid/MSHR, DMA 및 controller FIFO, register file 등의 저장 공간은 이 합계에 포함하지 않는다. 따라서 이 값은 모든 RTL RAM bit를 더한 총량이 아니다.

| Candidate | I-cache | D-cache | L2 data | LMEM | TMEM | ACC | 합계 (KiB) | 합계 (MiB) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| C1 | 16 | 16 | 1,024 | 1,024 | 0 | 0 | 2,080 | 2.03125 |
| C2 | 32 | 32 | 0 | 1,024 | 0 | 256 | 1,344 | 1.31250 |
| C3 | 32 | 32 | 0 | 1,024 | 0 | 256 | 1,344 | 1.31250 |
| C4 | 32 | 32 | 0 | 1,024 | 512 | 256 | 1,856 | 1.81250 |

계산식:

- LMEM: `2^LMEM_LOG_SIZE = 2^20 = 1,048,576 bytes = 1 MiB`. `LMEM_NUM_BANKS=16`은 이 용량을 16 bank로 분할하며, 총량을 16배로 늘리지 않는다. 각 bank는 64 KiB다.
- C1 L2: `L2_ENABLE`, `L2_CACHE_SIZE` 기본값 `1,048,576 bytes = 1 MiB`. C2–C4는 L2가 활성화되지 않아 0이다.
- C1 I/D-cache: 각 기본값 `16,384 bytes = 16 KiB`. C2–C4: 각 `32,768 bytes = 32 KiB`. cache 설정은 bank/way를 합친 전체 data 용량이다.
- C4 TMEM: `NUM_TMEM_BANKS × TMEM_BANK_SIZE = 8 × 65,536 = 524,288 bytes = 512 KiB`. C1–C3에는 활성 TMEM subsystem이 없다.
- C2–C4 ACC: `GEMM_ACC_MEM_BANK_NUM × GEMM_ACC_MEM_DEPTH × MXU_COL × sizeof(FP32) = 4 × 1,024 × 16 × 4 = 262,144 bytes = 256 KiB`. bank당 `1,024 × 512 bits = 64 KiB`이다. C1에는 GEMM accelerator/ACC가 없어 0이다.
- Cache/LMEM/TMEM만 합산하면 C1=2,080 KiB, C2=C3=1,088 KiB, C4=1,600 KiB이다. ACC 256 KiB는 `breakdown.csv`에서 MXU에 포함된다.

## 2. 실제 BRAM 사용량

아래 값은 logical KiB가 아니라 BRAM36-equivalent tile 수다: `RAMB36 + RAMB18 / 2`. `hier_utilization.rpt`는 pre_opt 단계이므로 routed 결과와 구분한다. ACC는 `u_acc_internal`만 세어 상위 MXU wrapper와 중복 합산하지 않는다. TMEM은 8개 physical bank만 세며 DMA를 포함하지 않는다.

| BRAM 위치 / 단계 | C1 | C2 | C3 | C4 |
| --- | ---: | ---: | ---: | ---: |
| LMEM | 256 | 256 | 256 | 256 |
| I-cache | 35.5 | 35.5 | 35.5 | 35.5 |
| D-cache | 117 | 219 | 219 | 118 |
| L2 | 314 | 0 | 0 | 0 |
| TMEM | 0 | 0 | 0 | 128 |
| ACC | 0 | 58 | 58 | 58 |
| Other Vortex | 84 | 208 | 207 | 197 |
| Total Vortex_axi | 806.5 | 776.5 | 775.5 | 792.5 |
| Outside Vortex_axi | 200 | 200 | 200 | 200 |
| Full FPGA (pre_opt) | 1006.5 | 976.5 | 975.5 | 992.5 |
| Full FPGA (routed) | 1005.5 | 975.5 | 974.5 | 991.5 |

`Other Vortex`는 SIMT, DMA 및 Misc의 BRAM을 합친 값이다. D-cache 등의 행은 cache subtree 전체이므로 tag/MSHR/queue를 포함한다. 모든 후보의 URAM 사용량은 0이다.

## 3. 용량은 다른데 BRAM 수가 비슷한 이유

1. **공통 LMEM 1 MiB가 모든 후보에서 BRAM 256개를 사용한다.** FPGA shell 및 Vortex 외부 논리도 같은 pre_opt report에서 BRAM 200개를 사용한다. 두 공통 영역만으로 이미 BRAM 456개다.
2. **C1은 TMEM/ACC 대신 큰 L2를 갖는다.** C1의 L2 1 MiB는 BRAM 314개를 사용한다. 용량을 LMEM만 보거나 TMEM만 보고 비교하면 C1의 이 저장 공간을 놓친다.
3. **C2/C3의 4-bank D-cache는 C4의 2-bank D-cache보다 BRAM 101개를 더 사용한다.** D-cache의 logical data 용량은 세 후보 모두 32 KiB지만 실제 사용량은 C2/C3=219, C4=118이다. 보고서에는 C2/C3의 bank 4개가 각각 51개, C4의 bank 2개가 각각 51.5개를 사용하며, 공통 memory-response queue 2개가 각각 7.5개를 사용한다. bank마다 cache data RAM뿐 아니라 MSHR/request queue 등의 RAM이 생기고, 작고 넓은 RAM은 BRAM 폭/깊이 단위로 할당되므로 logical bytes와 tile 수가 비례하지 않는다.
4. **C4의 TMEM +128개가 D-cache -101개와 일부 상쇄된다.** C3 대비 memory subtree 증가분은 `128 - 101 = 27`개다. ACC는 양쪽 모두 58개다. 나머지 SIMT/DMA/Misc는 C3=207, C4=197로 10개 감소한다. 따라서 Vortex 전체 차이는 `27 - 10 = 17`개이며, routed Full FPGA도 `991.5 - 974.5 = 17`개 차이다.
5. **BRAM 수에 4.5 KiB를 곱하면 할당된 primitive의 raw bit 용량이지 유효 data SRAM 용량이 아니다.** parity bit, 폭/깊이 rounding, byte-write 구성, FIFO/MSHR/metadata 등을 포함하기 때문이다. 논문에서 SRAM capacity와 FPGA BRAM resource cost는 별도 수치로 제시해야 한다.

pre_opt 전체 FPGA BRAM은 routed 값보다 후보마다 1개 많다. 이 단계 차이를 shell 면적 차이로 해석하지 않는다.

## 4. 근거 파일

- Alias map: `ci/fpga_bin_alias_map.yaml`
- Candidate selection: `analysis_workspace/candidates_fpga_utils/candidate_fpga_bins.yaml`
- Defaults 및 capacity 식: 각 build `src/VX_config.vh`
- 실제 cache 설정: 각 build `src/VX_socket.sv`, `src/VX_cluster.sv`
- LMEM 총량: 각 build `src/VX_mem_unit.sv`의 `.SIZE(1 << 20)`
- TMEM: C4 build `src/VX_gemm_node.sv`의 `.NUM_BANKS(NUM_TMEM_BANKS)`, `.BANK_SIZE(65536)`
- ACC: C2–C4 build `src/VX_gemm_acc_internal.sv`의 4-bank loop, `.DATAW(16 * FP32_WIDTH)`, `.SIZE(1024)`
- 자원 사용량: 각 build `bin/hier_utilization.rpt`, `bin/impl_1_full_util_routed.rpt`

| Candidate | Alias | 현재 alias의 config 파일 | Build root |
| --- | --- | --- | --- |
| C1 | `tcu_th16_c1_v2` | `configs/tcu_th16_c1.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_L2cache_296f1c41bb` |
| C2 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_tcu_3051772acc` |
| C3 | `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr` | `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_c26f196986` |
| C4 | `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread` | `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_051cabe511` |

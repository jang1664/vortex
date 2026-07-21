# Selective-PnR Candidate Hierarchy

이 문서는 `candidates.yaml`에 등록된 coarse-grained candidate가
`Vortex_axi` hierarchy의 어느 instance에 해당하는지 정리한다.

## 근거와 정확도

현재 두 목표 run의 top catalog는 아직 생성되지 않았다.

```text
build/hw/syn/synopsys/top_analysis/Vortex_axi_naive_gemm_th16_tcol32_hwexp_dcache_hbw/top/results/design_catalog.tsv
build/hw/syn/synopsys/top_analysis/Vortex_axi_improve_th16_tcol32_hwexp_dcache/top/results/design_catalog.tsv
```

아래의 "관측" 경로와 개수는 다음 기존 DC elaboration catalog에서 직접
읽었다.

```text
build/hw/syn/synopsys/Vortex_axi_C4_xbar_test/catalog.lpp/results/design_catalog.tsv
```

이 catalog는 `NUM_THREADS=16`, merged platform memory, GEMM accelerator,
TMEM, `MXU_COL_TILE=32`를 사용하므로
`improve_th16_tcol32_hwexp_dcache.sh`와 구조적으로 가깝다. 기존 catalog의
`FEXP_PE_RATIO=4`와 현재 config의 값 차이는 아래 interconnect/GEMM instance
경로를 바꾸지 않는다. 최종 authoritative 목록은 각 목표 config의 top
stage가 만든 `design_catalog.tsv`, area cutoff을 적용한
`candidate_plan.json`, block synthesis가 만든 `hierarchical_manifest.json`
순서로 확인한다.

## 선택 및 deduplication 규칙

1. `candidates.yaml`의 `modules[].pattern`은 catalog의 `template_name`과
   일치시킨다.
2. 같은 `design_name`은 같은 parameter specialization이다. 여러 instance가
   같은 `design_name`을 공유하면 subdesign 합성과 PnR은 한 번만 실행하고
   `instance_count`로 multiplicity를 보존한다.
3. specialization의 모든 occurrence hierarchy area 합이
   `minimum_total_area_um2`인 `1000 um^2`보다 작으면 PnR 대상에서 빠진다.
4. parent candidate 내부의 작은 `VX_stream_arb`, `VX_demux`,
   `VX_*_arbiter` primitive는 의도적으로 match하지 않는다. parent와 child를
   함께 보정하는 hierarchy double counting을 막기 위해서다.

따라서 아래의 catalog occurrence 수는 최종 PnR job 수와 같지 않다.

## 관측 요약

| Candidate template | Parameter specializations | Occurrences | 대표 hierarchy 영역 |
|---|---:|---:|---|
| `axi_demux` | 1 | 1 | AXI top LSU demux |
| `axi_mux` | 1 | 8 | AXI top HBM mux array |
| `VX_stream_xbar` | 13 | 14 | AXI adapter, cache, LMEM, issue |
| `VX_mem_switch` | 3 | 3 | L3/L2/DCACHE bypass |
| `VX_mem_arb` | 13 | 38 | cache, memory bus, LMEM/DMA, TMEM bank |
| `VX_lmem_switch` | 1 | 1 | core memory-unit address switch |
| `VX_lsu_mem_arb` | 2 | 3 | core, DMA frontend, GEMM frontend |
| `VX_tmem_switch` | 4 | 4 | GEMM TMEM input/weight/SZ/output |
| `VX_gemm_tree_v1` | 1 | 1 | GEMM MXU compute tree |
| `axi_xbar` | 0 | 0 | 현재 관측 catalog에는 없음 |
| `axi_interleaved_xbar` | 0 | 0 | 현재 관측 catalog에는 없음 |
| `VX_tmem_wide_read_switch` | 0 | 0 | 현재 관측 catalog에는 없음 |

마지막 세 candidate는 config-dependent optional match다. 해당 RTL이
elaboration에 나타날 때만 PnR 대상이 된다.

## Hierarchy 개요

`g_clusters[0]`, `g_sockets[0]`, `g_cores[0]`은 현재 1-cluster,
1-socket, 1-core config 기준이다.

```text
Vortex_axi
├── u_lsu_demux                                      [axi_demux]
├── g_hbm_mux[0..7].u_axi_mux                       [axi_mux]
├── axi_adapter
│   ├── req_xbar                                    [VX_stream_xbar]
│   └── rsp_xbar                                    [VX_stream_xbar]
└── vortex
    ├── l3cache
    │   └── g_bypass.cache_bypass
    │       ├── core_bus_nc_switch                  [VX_mem_switch]
    │       ├── core_bus_nc_arb                     [VX_mem_arb]
    │       └── mem_bus_out_arb                     [VX_mem_arb]
    └── g_clusters[0].cluster
        ├── l2cache
        │   ├── g_bypass.cache_bypass/{switch,arb}  [VX_mem_switch/VX_mem_arb]
        │   └── g_cache.cache/{req,rsp}_xbar        [VX_stream_xbar]
        └── g_sockets[0].socket
            ├── {icache,dcache}                     [cache xbar/arb/switch]
            ├── g_mem_bus_if[0]                     [VX_mem_arb]
            └── g_cores[0].core
                ├── mem_unit                        [LMEM switch/arb/xbar]
                ├── issue                           [VX_stream_xbar]
                ├── u_VX_dma_node                   [VX_lsu_mem_arb]
                └── gemm_node                       [TMEM switches/arbs/MXU]
```

## 상세 instance 경로

### Top AXI mux/demux

```text
u_lsu_demux                                             [axi_demux]
g_hbm_mux[0..7].u_axi_mux                              [axi_mux]
```

관측 catalog에서 여덟 `axi_mux` occurrence는 같은 `design_name`을 공유한다.
따라서 합성과 PnR은 한 번 실행되고 최종 보정에는 `instance_count=8`이
사용된다. naive config의 memory-port 구조에 따라 이 범위는 목표 catalog에서
다시 확인해야 한다.

### Stream XBAR

```text
axi_adapter/req_xbar
axi_adapter/rsp_xbar

vortex/g_clusters[0].cluster/l2cache/g_cache.cache/core_req_xbar
vortex/g_clusters[0].cluster/l2cache/g_cache.cache/core_rsp_xbar
vortex/g_clusters[0].cluster/l2cache/g_cache.cache/mem_rsp_xbar/g_fallback.xbar_switch

vortex/g_clusters[0].cluster/g_sockets[0].socket/icache/
  g_cache_wrap[0].cache_wrap/g_cache.cache/core_req_xbar
  g_cache_wrap[0].cache_wrap/g_cache.cache/core_rsp_xbar
  g_cache_wrap[0].cache_wrap/g_cache.cache/mem_rsp_xbar/g_fallback.xbar_switch

vortex/g_clusters[0].cluster/g_sockets[0].socket/dcache/
  g_cache_wrap[0].cache_wrap/g_cache.cache/core_req_xbar
  g_cache_wrap[0].cache_wrap/g_cache.cache/core_rsp_xbar
  g_cache_wrap[0].cache_wrap/g_cache.cache/mem_rsp_xbar/g_fallback.xbar_switch

vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/
  mem_unit/local_mem/req_xbar
  mem_unit/local_mem/rsp_xbar
  issue/g_slices[0].issue_slice/operands/g_collectors[0].opc_unit/req_xbar
```

L2와 DCACHE fallback xbar는 관측 catalog에서 같은 parameter
specialization을 공유하므로 하나의 PnR 결과가 두 occurrence를 대표한다.

### Cache 및 memory-bus arbiter/switch

```text
vortex/l3cache/g_bypass.cache_bypass/
  core_bus_nc_switch                                   [VX_mem_switch]
  core_bus_nc_arb                                      [VX_mem_arb]
  mem_bus_out_arb                                      [VX_mem_arb]

vortex/g_clusters[0].cluster/l2cache/g_bypass.cache_bypass/
  core_bus_nc_switch                                   [VX_mem_switch]
  core_bus_nc_arb                                      [VX_mem_arb]
  mem_bus_out_arb                                      [VX_mem_arb]

vortex/g_clusters[0].cluster/g_sockets[0].socket/
  g_mem_bus_if[0].g_i0.mem_arb                         [VX_mem_arb]
  icache/g_core_arb[0].core_arb                        [VX_mem_arb]
  icache/g_mem_bus_if[0].mem_arb                       [VX_mem_arb]
  dcache/g_core_arb[0..1].core_arb                     [VX_mem_arb]
  dcache/g_mem_bus_if[0..1].mem_arb                    [VX_mem_arb]
  dcache/g_cache_wrap[0].cache_wrap/g_bypass.cache_bypass/
    core_bus_nc_switch                                 [VX_mem_switch]
    core_bus_nc_arb                                    [VX_mem_arb]
    mem_bus_out_arb                                    [VX_mem_arb]
```

Cache bank/port 수에 의해 array 범위와 parameter specialization은 두 목표
config 사이에서 달라질 수 있다.

### Core memory unit 및 DMA

공통/개선형 구조에서 관측된 경로는 다음과 같다.

```text
vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/
  mem_unit/g_lmem_switches[0].lmem_switch              [VX_lmem_switch]
  mem_unit/lmem_arb                                    [VX_lsu_mem_arb]
  mem_unit/g_lmem_lane_dma_arb[0..15].
    lmem_membus_dma_arbiter                            [VX_mem_arb]
  mem_unit/g_dcache_adapters[0].dcache_dma_arbiter     [VX_mem_arb]
  u_VX_dma_node/u_job_frontend/lmem_arb                [VX_lsu_mem_arb]
```

`g_lmem_lane_dma_arb[0..15]`는 관측 catalog에서 같은 specialization을
공유하므로 PnR 한 번과 `instance_count=16`으로 처리된다. naive config의
`LMEM_NUM_PORTS=64`와 DMA/DCACHE 설정은 이 범위와 specialization을 바꿀 수
있으므로 naive top catalog가 최종 기준이다.

### Issue interconnect

```text
vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/
  issue/g_slices[0].issue_slice/operands/
    g_collectors[0].opc_unit/req_xbar                  [VX_stream_xbar]
```

### Improve GEMM/TMEM hierarchy

관측 catalog와 `improve_th16_tcol32_hwexp_dcache.sh`의 구조는 다음과 같다.

```text
vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/gemm_node/
  u_job_frontend/lmem_arb                              [VX_lsu_mem_arb]
  u_VX_gemm_unit/u_mxu                                [VX_gemm_tree_v1]
  u_tmem_subsystem/
    u_switch_input                                     [VX_tmem_switch]
    u_switch_weight                                    [VX_tmem_switch]
    u_switch_sz                                        [VX_tmem_switch]
    u_switch_output                                    [VX_tmem_switch]
    g_bank[0..7].u_bank/mem_arb                        [VX_mem_arb]
```

여덟 TMEM-bank arbiter는 같은 specialization을 공유한다. 네 TMEM switch는
interface width/parameter signature 차이 때문에 관측 catalog에서 서로 다른
네 specialization으로 elaboration되었다.

### Naive GEMM hierarchy

`GEMM_NAIVE`에서는 core instance 이름과 memory 구조가 달라진다. RTL에서
확인되는 목표 경로는 다음과 같다.

```text
vortex/g_clusters[0].cluster/g_sockets[0].socket/g_cores[0].core/
  gemm_node_naive/u_VX_gemm_unit/u_mxu                 [VX_gemm_tree_v1]
  gemm_node_naive/g_lmem_lane_arb[0..63].lane_arb      [VX_mem_arb]
```

naive 구조는 `u_tmem_subsystem`을 사용하지 않으므로 improve 구조의
`VX_tmem_switch` 및 TMEM-bank `VX_mem_arb` 경로는 나타나지 않을 것으로
예상한다. `g_lmem_lane_arb`의 정확한 elaborated 범위와 specialization
grouping은 naive top stage가 만든 catalog에서 확정한다.

## Run 후 확인할 파일

각 config에 대해 다음 순서로 확인한다.

1. `top/results/design_catalog.tsv`: 모든 elaborated occurrence와 parameter
   specialization.
2. `candidate_plan.json`: match 결과, unmatched optional candidate,
   `1000 um^2` cutoff으로 제거된 specialization.
3. `blocks/hierarchical_manifest.json`: 실제 합성/PnR job, 각 job의
   `instance_paths`와 `instance_count`.
4. `reports/selective_pnr_blocks.csv`: clean/failed 상태와 최종 선택된 PnR
   결과.

특히 exact PnR 대상은 catalog 자체가 아니라
`blocks/hierarchical_manifest.json`의 `synthesis_jobs`가 최종 기준이다.

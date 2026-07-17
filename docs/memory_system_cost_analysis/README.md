# C3/C4 Memory-System Implementation-Cost Analysis

이 문서는 C3 shared-LMEM system과 C4 interleaved-TMEM system의 post-route
implementation cost를 비교하는 방법을 정리한다. 측정에는 다음 Tcl script를
사용한다.

```text
hw/syn/xilinx/xrt/report_memory_system_cost.tcl
```

핵심 비교 대상은 memory capacity나 GEMM compute logic이 아니라, memory
system의 switch, crossbar, arbiter, adapter로 구성된 `fabric` scope이다.

## 1. PIP와 wire-segment cost의 의미

### 1.1 FPGA routing model

Vivado가 보는 FPGA routing fabric은 다음과 같이 단순화할 수 있다.

```text
source pin -> wire/node -> PIP -> wire/node -> ... -> sink pin
```

- `wire`는 FPGA device database에 정의된 개별 routing wire object이다.
- `node`는 programmable switch 없이 전기적으로 연결된 wire들의 집합이다.
- `PIP`는 두 routing resource를 연결하는 programmable switch이다.
- 하나의 routed net은 여러 wire, node, PIP를 통과할 수 있다.

### 1.2 PIP cost

PIP는 *Programmable Interconnect Point*의 약자이다. FPGA configuration bit로
연결 여부가 정해지는 routing switch이며, Vivado의 `get_pips -of_objects
<nets>`로 사용된 PIP object를 얻을 수 있다.

이 문서에서 `PIP cost`는 선택한 routed net들이 사용하는 **unique PIP
개수**를 뜻한다. 실제 면적, 에너지 또는 지연을 직접 측정한 값은 아니다.

PIP count가 작다는 것은 일반적으로 다음 가능성을 시사한다.

- 같은 연결을 구현하는 데 필요한 programmable switch traversal이 적다.
- scarce routing resource에 대한 요구량이 작다.
- routing detour나 복잡한 many-to-many connection이 줄었을 가능성이 있다.
- 다른 조건이 같다면 routing delay와 congestion을 줄이기 쉬울 수 있다.

하지만 PIP마다 위치, 종류, delay가 다르므로 PIP count만으로 timing이나
congestion이 반드시 개선됐다고 결론 내리면 안 된다.

### 1.3 Wire-segment cost

Vivado의 `get_wires -of_objects <nets>`는 net route에 포함된 device `WIRE`
object들을 반환한다. 이 문서에서 `wire-segment cost`는 이 **unique WIRE
object 개수**를 뜻한다.

Wire-segment count가 작으면 routing fabric에서 점유하는 wire object 수가
적다는 의미이므로, 연결의 공간적 확산과 routing-resource demand를 나타내는
proxy로 사용할 수 있다.

다만 이 값은 다음과 같은 `total wire length`가 아니다.

- 물리적 길이를 micrometer나 millimeter로 합산한 값이 아니다.
- short local wire와 long interconnect wire에 동일하게 1을 부여한다.
- 하나의 긴 물리 resource가 device database에서 여러 WIRE object로 표현될
  수도 있다.

따라서 논문에서는 `wire length`보다 `routed wire-segment count` 또는
`routing wire-object count`라고 표현하는 것이 안전하다.

### 1.4 두 지표의 역할

| Metric | 직접 세는 것 | 유용한 해석 | 직접 주장하면 안 되는 것 |
|---|---|---|---|
| PIP count | 사용된 programmable switches | switch traversal 및 routing-resource demand | 실제 switch area, energy, congestion |
| Wire-segment count | 사용된 WIRE objects | routing footprint와 spatial spread의 proxy | 물리적 total wire length |
| Node count | 사용된 routing nodes | electrical routing-resource footprint의 보조 지표 | 독립적인 배선 길이 |

PIP와 wire-segment count가 함께 감소하면 단순히 net 수가 줄어든 것보다
routing topology 자체가 간단해졌다는 근거가 강해진다. 그래도 congestion은
별도의 congestion report로 확인해야 한다.

## 2. 현재 script가 측정하는 범위

### 2.1 Primary `fabric` scope

Script는 C3와 C4에 서로 다른 anchored hierarchy-name pattern을 적용하고,
예상 개수와 실제 match 개수가 다르면 실행을 중단한다.

| Profile | Fabric roots | 구성 |
|---|---:|---|
| C3 | 33 | 8 GEMM lane arbiters, input/output/SZ lane splits, weight adapter, 16 LMEM DMA arbiters, LMEM switch/arbiter/adapter, request/response crossbars |
| C4 | 12 | input/weight/SZ/output switches와 8 TMEM bank arbiters |

다음 logic은 primary fabric에서 분리하여 별도 scope로 보고한다.

| Group | C3 roots | C4 roots | 용도 |
|---|---:|---:|---|
| `dma_local` | 4 | 4 | GEMM과 local memory 사이의 local DMA |
| `dma_hbm` | 1 | 1 | HBM-facing DMA unit/engine |
| `control` | 1 | 1 | DMA controller |
| `storage` | 16 | 8 | LMEM/TMEM storage arrays |

논문의 interconnect 비교에는 `summary.csv`의 `fabric` row를 primary result로
사용한다. `fabric_dma_local`과 `fabric_dma_full`은 DMA를 포함했을 때의
sensitivity analysis로만 사용하는 것이 좋다.

### 2.2 Routing scope

현재 routing scope는 다음 set으로 정의된다.

```text
boundary_pins = hierarchy pins of the selected fabric roots
upper_segments = parent-level net segments connected to boundary_pins
measured_segments = upper_segments
                    AND TYPE == SIGNAL
                    AND ROUTE_STATUS == ROUTED
                    AND not a clock net
```

Tcl command 관점에서는 다음 순서이다.

```tcl
set boundary_pins [get_pins -of_objects $roots]
set upper_segments [get_nets -of_objects $boundary_pins]
set measured_segments [filter $upper_segments {
    TYPE == SIGNAL && ROUTE_STATUS == ROUTED
}]
```

여기서 `get_pins -of_objects $roots`는 root 아래의 모든 primitive pin을
재귀적으로 가져오는 명령이 아니다. 선택한 hierarchy instance 자체의
input/output boundary pin만 가져온다.

더 중요한 점은 `get_nets -of_objects <hierarchical_pin>`의 기본값이
`-boundary_type upper`라는 것이다. Vivado hierarchy net은 boundary를
기준으로 upper(parent-level) segment와 lower(child-level) segment로 나뉠 수
있다. 현재 script는 `-segments`나 `-boundary_type both`를 사용하지 않으므로
boundary 바깥쪽의 upper segment만 가져온다.

따라서 포함 여부를 결정하는 질문은 다음과 같다.

> 이 routed net segment가 선택된 root의 boundary pin과 같은 parent
> hierarchy level에 연결되어 있는가?

### 2.3 Crossbar 예시

C3의 `local_mem/req_xbar`가 선택된 fabric root이고, 합성 후 내부가 다음과
같다고 가정한다. `req_xbar` 내부의 실제 instance 이름과 개수는 다를 수
있지만 scope 판정 원리는 동일하다.

```text
outside producer
      |
      | net_A_upper: INCLUDED
      v
+---------------------------------------------------+
| req_xbar hierarchy                               |
|                                                   |
|  input boundary pin                              |
|      |                                            |
|      | net_A_lower: EXCLUDED                      |
|      v                                            |
|  input register -- net_B --> mux stage 1          |
|                                  |                |
|                                net_C              |
|                                  |                |
|                                  v                |
|                             mux stage 2            |
|                                  |                |
|                        net_D_lower: EXCLUDED       |
|                                  |                |
|                                  v                |
|                         output boundary pin        |
+---------------------------------------------------+
                                   |
                                   | net_D_upper: INCLUDED
                                   v
                             outside consumer
```

이 예시에서 현재 script의 판정은 다음과 같다.

| Net segment | 연결 | 포함 여부 | 이유 |
|---|---|---|---|
| `net_A_upper` | 외부 producer에서 `req_xbar` input boundary pin까지 연결 | 포함 | boundary pin과 같은 parent level의 upper segment |
| `net_A_lower` | input boundary pin 아래에서 첫 internal primitive로 연결 | 제외 | child level의 lower segment이며 script가 `-segments`/`both`를 사용하지 않음 |
| `net_B` | input register에서 mux stage 1로 연결 | 제외 | 두 endpoint가 모두 `req_xbar` 내부이고 boundary pin에 닿지 않음 |
| `net_C` | mux stage 1에서 mux stage 2로 연결 | 제외 | 순수 internal primitive-to-primitive net |
| `net_D_lower` | 마지막 mux에서 output boundary pin 아래까지 연결 | 제외 | child level의 lower segment |
| `net_D_upper` | output boundary pin에서 외부 consumer로 연결 | 포함 | parent level의 upper segment |

따라서 질문의 예처럼 crossbar 내부에 mux와 demux가 많이 있더라도, 그들
사이의 internal net은 포함되지 않는다. 현재 구현에서는 boundary input에서
첫 internal primitive까지 이어지는 lower segment와 마지막 internal
primitive에서 boundary output까지 이어지는 lower segment도 제외된다. 오직
boundary 바깥쪽 parent level에서 연결되는 upper segment가 포함된다.

### 2.4 포함되는 net과 제외되는 net

| 상황 | 예시 | 현재 scope |
|---|---|---|
| 선택된 root와 외부 block 사이의 parent-level segment | 외부 producer에서 `req_xbar` input pin까지 | 포함 |
| 선택된 두 sibling root 사이의 parent-level segment | `lmem_switch` boundary에서 `req_xbar` boundary로 가는 segment | 포함 |
| 선택된 root와 제외된 storage 사이의 parent-level segment | `req_xbar` boundary에서 `lmem_store` boundary로 가는 segment | 포함 |
| 선택된 root boundary 아래의 lower segment | input pin에서 첫 mux/register로 가는 segment | 제외 |
| 선택된 root 내부의 중간 net | mux stage 1에서 mux stage 2로 가는 net | 제외 |
| 제외된 block 내부의 net | `lmem_store` 내부 address/data/control net | 제외 |
| 선택되지 않은 두 block 사이의 net | DMA 내부 primitive-to-primitive connection | 제외 |
| Clock net segment | 선택된 root의 `clk` port에 연결된 upper segment | 제외 |
| Unrouted 또는 power/ground 등 non-signal net | route가 없거나 `TYPE != SIGNAL`인 net | 제외 |

Reset, enable, valid/ready와 같은 control signal은 clock이 아니고 routed
`SIGNAL`이면 boundary pin에 닿는 경우 포함된다. Data net만 측정하는 것은
아니다.

### 2.5 “Internal net을 제외한다”의 정확한 의미

`internal net을 제외한다`의 정확한 의미는 다음과 같다.

- **포함:** 선택된 root boundary pin의 parent-level upper net segment
- **제외:** 같은 hierarchical connection의 child-level lower segment
- **제외:** 선택된 root 내부에 완전히 갇힌 primitive-to-primitive net

각 upper segment가 실제 route에서 사용하는 PIP/node/WIRE object가 집계된다.
`get_nets -segments`를 호출하지 않기 때문에 동일한 hierarchical net의 모든
level segment를 합쳐 세지 않는다.

따라서 현재 측정값은 다음을 나타낸다.

```text
selected roots 바깥의 parent hierarchy level에서 interface 및 inter-root
connectivity를 구현하는 데 사용된 routing resources
```

반면 다음 값은 아니다.

```text
selected roots 내부의 mux/demux 및 boundary-lower segments를 포함한
모든 routing resources
```

모든 internal mux/demux connection까지 포함하려면 각 root 아래의 primitive
cell과 internal net을 재귀적으로 수집해야 한다. Boundary를 통과하는
hierarchical net의 모든 segment만 추가하려면 `get_nets -segments` 또는
`-boundary_type both`를 별도로 검토할 수 있지만, 이것만으로 root 내부의
모든 primitive-to-primitive net이 포함되는 것은 아니다. 현재 script는 대형
routed design에서 internal-net 전수 열거의 실행 시간이 지나치게 커져
primary metric에서 제외했다.

결과는 `selected-fabric interface/inter-root routing cost`로 표현해야 하며,
전체 crossbar 내부 routing cost나 memory-system 영역 내부의 정확한 물리
배선 길이라고 표현하면 안 된다.

이 구분은 LUT/FF와 routing metric을 함께 볼 때 특히 중요하다.

- Scoped LUT/FF/BRAM은 선택된 root 아래의 primitive cell 전체를 포함한다.
- PIP/node/WIRE count는 선택된 root의 parent-level upper net segment만
  포함한다.

즉 두 종류의 metric은 동일한 hierarchy 내부 범위를 세는 것이 아니다. 현재
PIP/wire 결과는 C3 crossbar 내부 mux/demux routing이 얼마나 복잡한지를 직접
측정하지 못하며, selected roots가 바깥쪽 fabric과 연결되는 interface 및
inter-root connection burden을 비교한다.

## 3. Experimental setup

### 3.1 비교 대상

현재 `ci/fpga_bin_alias_map.yaml`의 alias는 다음 설정을 가리킨다.

| Profile | Architecture | Config | Reference XPR |
|---|---|---|---|
| C3 | shared LMEM | `configs/naive_gemm_th16_tcol32_hwexp_dcache.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_5d4264c38f/_x/link/vivado/vpl/prj/prj.xpr` |
| C4 | interleaved TMEM | `configs/improve_th16_tcol32_hwexp_dcache.sh` | `/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/_x/link/vivado/vpl/prj/prj.xpr` |

두 configuration은 모두 1 cluster, 1 core, 16 threads, 100 MHz target을
사용한다. FPGA part는 `xcu55c-fsvh2892-2L-e`이다.

이 비교는 C3와 C4라는 두 **system architecture**의 비교이지, interleaving
bit 하나만 바꾼 single-variable ablation은 아니다. 두 design은 local-memory
organization, DMA structure, fabric hierarchy가 함께 다르다. 따라서 결과는
`shared-LMEM system 대비 interleaved-TMEM system의 implementation cost`로
기술한다. Interleaving만의 인과 효과를 주장하려면 memory capacity, datapath
width, DMA structure를 고정한 별도의 matched ablation이 필요하다.

또한 C3/C4의 local-memory capacity 설정이 다르더라도 primary `fabric`
비교에서는 `storage` group을 제외한다. Storage를 포함한 full-system 수치를
비교할 때는 capacity 차이를 별도로 보고하거나 capacity normalization을
추가해야 한다.

### 3.2 반드시 고정할 조건

C3/C4 차이 외의 변수가 routing 결과에 섞이지 않도록 다음 조건을 맞춘다.

| Category | 고정할 항목 |
|---|---|
| Tool | Vivado version과 device database |
| Device | FPGA part, platform shell, pblock/floorplan |
| Timing | target clock와 clock uncertainty |
| Implementation | synthesis/opt/place/route directives와 seed |
| Core configuration | cluster/core/thread 수, MXU parameters, cache configuration |
| Reporting | 동일한 Tcl script revision과 hierarchy manifest |

현재 검증에는 Vivado 2025.1과 100 MHz clock을 사용했다.

Routing 결과는 seed와 placer/router 결정에 영향을 받는다. 논문용 최종
결과는 가능하면 C3/C4 각각에 대해 동일한 paired seed 3-5개를 사용하고,
median과 min-max 또는 interquartile range를 함께 보고한다. XPR 하나씩만
사용하면 `one representative placed-and-routed implementation`으로 기술한다.

### 3.3 Peak-bandwidth normalization

현재 script는 C3/C4 config에 대응하는 theoretical peak를 사용한다.

| Profile | Peak bytes/cycle | Clock | Peak bandwidth |
|---|---:|---:|---:|
| C3 | 64 B/cycle | 100 MHz | 6.4 GB/s |
| C4 | 256 B/cycle | 100 MHz | 25.6 GB/s |

계산식은 다음과 같다. 여기서 GB는 decimal GB이다.

```text
Peak_BW [GB/s] = bytes_per_cycle * clock_MHz / 1000
Normalized_cost = implementation_cost / Peak_BW
```

예를 들어 C3의 PIP count가 1,437,032이면 다음과 같다.

```text
1,437,032 PIPs / 6.4 GB/s = 224,536.25 PIPs/(GB/s)
```

이 normalization은 sustained application bandwidth가 아니라, 제공 가능한
theoretical bandwidth 한 단위당 implementation cost를 비교한다. Config가
바뀌면 `profile_peak_bytes_per_cycle`의 64/256 B/cycle 값도 반드시 다시
검증해야 한다.

## 4. 실행 방법

Repository root에서 다음과 같이 실행한다.

```bash
SCRIPT=hw/syn/xilinx/xrt/report_memory_system_cost.tcl

C3_XPR=/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_5d4264c38f/_x/link/vivado/vpl/prj/prj.xpr
C4_XPR=/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_L2cache_8d9b4939d1/_x/link/vivado/vpl/prj/prj.xpr

vivado -mode batch -nojournal -nolog \
  -source "$SCRIPT" \
  -tclargs "$C3_XPR" \
  -profile c3 \
  -out /tmp/vortex_memory_system_cost_c3

vivado -mode batch -nojournal -nolog \
  -source "$SCRIPT" \
  -tclargs "$C4_XPR" \
  -profile c4 \
  -out /tmp/vortex_memory_system_cost_c4
```

Whole-design congestion report가 필요 없거나 빠른 반복 검증을 할 때는
`-skip-congestion`을 추가한다. `-profile auto`를 사용하면 hierarchy를 보고
C3/C4를 자동 판별한다.

Clock 자동 추론이 실패하거나 여러 clock이 검출되면 다음처럼 분석할 clock을
명시한다.

```bash
-clock clk_kernel_00_unbuffered_net
```

### 4.1 출력 파일

| Output | 내용 | 분석 용도 |
|---|---|---|
| `summary.csv` | scope별 resources, routing, normalization, timing | primary numeric result |
| `roots.csv` | rule, pattern, matched hierarchy, primitive count | measurement-boundary audit |
| `routing.csv` | interface/inter-root upper net-segment, PIP, node, wire counts | raw routing-cost audit |
| `utilization_<scope>.rpt` | Vivado scoped utilization report | LUT/FF/BRAM/URAM/DSP 검증 |
| `timing_<scope>.rpt` | scope를 통과하는 worst timing paths | timing feasibility와 route-delay 보조 분석 |
| `complexity_<scope>.rpt` | Rent/average-fanout report | report에 실제 row가 있을 때만 보조 분석 |
| `congestion_global.rpt` | whole-design congestion | global supporting evidence |
| `run_metadata.txt` | XPR, part, clock, Vivado version, normalization | reproducibility record |

`complexity_<scope>.rpt`에 `No complexity report generated`가 있으면 해당
Rent/average-fanout 결과는 사용하지 않는다. 여러 disjoint hierarchy root를
한 번에 지정하면 Vivado가 유효한 complexity row를 만들지 않을 수 있다.

## 5. 결과 검증 순서

### Step 1: Run validity

`run_metadata.txt`에서 다음을 확인한다.

- C3/C4 모두 같은 Vivado version과 FPGA part를 사용했는가?
- 두 설계 모두 같은 clock frequency인가?
- `peak_bytes_per_cycle`이 의도한 config와 일치하는가?
- 입력 XPR의 implementation run이 100% 완료된 run인가?

### Step 2: Hierarchy manifest

`roots.csv`에서 다음을 확인한다.

- C3 fabric root가 33개, C4 fabric root가 12개인가?
- `REF_NAME`과 hierarchy name이 의도한 module인가?
- storage나 GEMM compute hierarchy가 fabric group에 들어가지 않았는가?
- 각 root 아래 primitive cell count가 0보다 큰가?

Script는 root cardinality mismatch나 base-group primitive overlap이 있으면
실패하도록 구현되어 있다.

### Step 3: Resource leakage

Primary `fabric` row에서 다음을 확인한다.

- URAM과 DSP가 0이어야 한다.
- BRAM이 있으면 storage leakage인지 pipeline/FIFO inference인지 RTL과
  hierarchy를 확인한다.

현재 C3 fabric의 BRAM 16 tiles는 wide interconnect pipeline/FIFO에서 추론된
것으로 확인되어 fabric implementation cost에 유지했다. C4 fabric BRAM은
0이다.

### Step 4: Routing sanity

`summary.csv` 또는 `routing.csv`에서 다음 관계를 확인한다.

```text
interface_nets > 0
interface_pips > 0
interface_nodes > 0
interface_wire_segments > 0
```

`excluded_non_signal`, `excluded_unrouted`, `excluded_clock`도 함께 보관한다.
이 값이 예상보다 크면 net filtering이나 route completion을 재검토한다.

### Step 5: Normalization arithmetic

다음 값을 독립적으로 다시 계산하여 CSV와 비교한다.

```text
k_lut_per_gb_s = LUT / 1000 / peak_gb_s
k_ff_per_gb_s = FF / 1000 / peak_gb_s
interface_pips_per_gb_s = interface_pips / peak_gb_s
interface_wire_segments_per_gb_s = interface_wire_segments / peak_gb_s
```

### Step 6: Timing and congestion

- 두 design 모두 target frequency에서 non-negative slack인지 확인한다.
- `logic_delay_ns + route_delay_ns`가 `datapath_delay_ns`와 일치하는지
  확인한다.
- route-delay fraction은 보조 지표로 사용한다.
- `congestion_global.rpt`는 whole-design 결과이므로 memory fabric의 local
  congestion이라고 표현하지 않는다.

Scoped timing path는 선택한 scope를 통과하는 end-to-end timing path이다.
따라서 `route_delay_ns`를 memory fabric만의 독립적인 latency로 해석하면 안
된다.

## 6. 현재 C3/C4 결과

다음 값은 위 reference XPR을 Vivado 2025.1에서 분석한 결과이다.

| Metric | C3 shared LMEM | C4 interleaved TMEM | C4 reduction |
|---|---:|---:|---:|
| Peak bandwidth | 6.4 GB/s | 25.6 GB/s | -- |
| Fabric LUT | 38,838 | 8,312 | 78.60% |
| Fabric FF | 45,965 | 72 | 99.84% |
| Fabric BRAM tiles | 16 | 0 | 100% |
| Interface/inter-root upper net segments | 48,471 | 20,507 | 57.69% |
| Interface PIPs | 1,437,032 | 853,494 | 40.61% |
| Interface nodes | 1,154,110 | 525,213 | 54.49% |
| Interface wire segments | 6,765,654 | 5,145,846 | 23.94% |
| kLUT/(GB/s) | 6.068437 | 0.324687 | 94.65% |
| kFF/(GB/s) | 7.182031 | 0.002813 | 99.96% |
| PIPs/(GB/s) | 224,536.250 | 33,339.609 | 85.15% |
| Wire segments/(GB/s) | 1,057,133.438 | 201,009.609 | 80.99% |
| Worst slack | 0.032 ns | 0.170 ns | both met timing |
| Datapath delay | 9.626 ns | 9.297 ns | 3.42% |
| Logic/route delay | 0.132 / 9.494 ns | 1.584 / 7.713 ns | supporting metric |

`C4 reduction`은 다음 식으로 계산했다.

```text
Reduction [%] = (1 - C4 / C3) * 100
```

### 6.1 Raw-cost 해석

C4는 C3보다 theoretical bandwidth가 4배인데도 raw interface routing cost가
작다.

- PIP count는 40.61% 감소했다.
- wire-segment count는 23.94% 감소했다.
- interface/inter-root upper net-segment count는 57.69% 감소했다.

이는 C4의 interleaved-TMEM connection이 C3 shared-LMEM fabric보다 적은
programmable switch와 routing wire object로 구현되었다는 post-route
evidence이다.

### 6.2 Bandwidth-normalized 해석

C4의 peak bandwidth가 4배이므로 cost per peak bandwidth의 차이는 더 크다.

- PIP cost per GB/s는 85.15% 감소했으며, C4가 C3보다 6.73배 작다.
- wire-segment cost per GB/s는 80.99% 감소했으며, C4가 C3보다 5.26배 작다.
- LUT cost per GB/s는 94.65% 감소했으며, C4가 C3보다 18.69배 작다.

따라서 결과의 가장 안전한 핵심 주장은 다음과 같다.

> Under the same FPGA, tool, and clock conditions, the interleaved-TMEM
> design uses fewer interface routing resources despite providing a 4x higher
> theoretical peak bandwidth. After bandwidth normalization, it reduces PIP
> and routed wire-object counts by 85.2% and 81.0%, respectively, indicating a
> substantially lower memory-fabric implementation cost per unit bandwidth.

### 6.3 이 결과만으로 주장하지 말아야 할 것

현재 결과만으로 다음을 직접 주장하면 안 된다.

- 실제 wire length가 80.99% 감소했다.
- local congestion이 정확히 같은 비율로 감소했다.
- routing energy 또는 interconnect area가 같은 비율로 감소했다.
- workload의 sustained bandwidth가 4배 향상됐다.
- scoped timing path의 route delay가 memory fabric만의 latency이다.

보다 강한 physical-design 주장을 하려면 congestion map, multiple-seed 결과,
wire-type/geometry-weighted length, placement bounding box 또는 clock-region별
routing utilization을 추가로 분석해야 한다.

## 7. 논문용 reporting 권장안

Main table에는 다음 네 종류를 함께 싣는 것이 좋다.

1. Raw logic cost: LUT, FF, BRAM
2. Raw routing cost: PIP and routed wire-object counts
3. Bandwidth-normalized cost: kLUT/GB/s, PIPs/GB/s, wire objects/GB/s
4. Feasibility: achieved frequency 또는 worst slack

Congestion과 timing breakdown은 supporting result로 두고, primary claim은
raw cost와 bandwidth-normalized cost가 같은 방향을 보인다는 점에 둔다.

최종 결과를 갱신할 때는 다음 artifact를 함께 보관한다.

- C3/C4 `summary.csv`, `routing.csv`, `roots.csv`
- `run_metadata.txt`
- config scripts와 git commit hash
- Vivado version 및 implementation directives/seed
- global congestion report와 timing reports

이렇게 하면 hierarchy naming, normalization assumption 또는 PnR setting이
바뀌었을 때 결과가 섞이는 것을 방지할 수 있다.

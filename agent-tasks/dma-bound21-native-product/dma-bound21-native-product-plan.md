# DMA 21-bit Bound, Native-width 곱셈 및 Dimension 특화 계획

## 목표

1. DMA의 `BND0/BND1/BND2` 내부 표현을 unsigned 21-bit로 축소한다.
2. 곱셈 전에 피연산자를 64-bit로 확장하지 않는다. 각 피연산자의 실제 폭으로 곱한 뒤, 필요한 결과만 64-bit 주소/byte counter에 zero-extension한다.
3. descriptor/register ABI, DMA handshake, pipeline latency 및 완료 cycle은 유지한다.
4. 현재 output DMA의 `descriptor_write_bytes -> write_bytes_remaining_r` 조합 경로와 generic DMA의 `stride * (bound - 1)` 자원/지연을 줄인다.
5. DMA별 최대 지원 차원을 `MAX_DIMS=1..3` compile-time parameter로 지정하고, 지원하지 않는 상위 dimension의 counter, stride/bound storage, rollover logic 및 multiplier를 합성에서 제거한다.

## 타입 계약

- `bound`, `seg_size`, `stride`, byte count는 현재 RTL에서 모두 **unsigned**이다.
- 따라서 “최종 64-bit sign-extension”은 적용하지 않는다. 21-bit bound의 bit 20을 부호로 해석하면 `21'h10_0000` 이상이 음수가 되어 기존 의미가 깨진다.
- 이 변경에서 필요한 확장은 **zero-extension**이다.
- 21-bit bound의 유효 범위는 `0 .. 2,097,151`이다.
- ``MM_MAX_LOG_DIM=20``이 허용하는 dimension `2^20 = 1,048,576`과 `VX_gpu_pkg.sv:1018`의 21-bit `eff_mt`를 손실 없이 표현할 수 있다.
- 외부 DMA configuration register의 word 폭과 register index는 32-bit 그대로 유지한다. `regs[11:13]`을 받을 때 `[20:0]`만 내부에 저장하고, descriptor 수락 시 `[31:21] == 0`을 simulation assertion으로 검사한다.
- synthesis 동작에는 별도 오류 응답을 추가하지 않는다. 21-bit를 넘는 descriptor는 upstream contract 위반이며 simulation에서 즉시 실패시킨다.
- descriptor ABI는 항상 3D 필드(`BND0..2`, source/destination `STRIDE0..2`)를 유지한다. `MAX_DIMS`는 이 ABI를 줄이는 parameter가 아니라 내부에서 실제 구현할 nested-loop 깊이를 정하는 parameter이다.
- `MAX_DIMS=1`이면 dimension 0만 사용하고 `BND1=BND2=1`이어야 한다. stride1/2는 무시한다.
- `MAX_DIMS=2`이면 dimension 0/1을 사용하고 `BND2=1`이어야 한다. stride2는 무시한다.
- `MAX_DIMS=3`은 기존 3D 동작을 그대로 유지한다.
- parameter 범위는 elaboration 시 `1 <= MAX_DIMS <= 3`으로 검사하고, inactive bound가 1인지 descriptor 수락 시 simulation assertion으로 검사한다.

## 현재 문제 지점

### 1. 공통 인터페이스와 descriptor 경계

| 파일/현재 line | 현재 상태 | 문제 |
|---|---|---|
| `hw/rtl/core/gemm/VX_lmem_dma_ctrl_if.sv:10-23` | local/GEMM DMA의 `bounds[NDIM]`가 32-bit | 모든 producer, executor 및 command metadata에 bound당 불필요한 11 bit가 전파됨 |
| `hw/rtl/core/VX_dma_lookahead_if.sv:3-10` | 두 lookahead bound가 각각 32-bit | aligned DMA의 두 prepare slot까지 32-bit bound가 복제됨 |
| `hw/rtl/core/VX_dma_if.sv:10-21` | 미사용 legacy interface의 bound가 32-bit | 향후 재사용 시 새 계약과 불일치 |
| `hw/rtl/core/VX_dma_unit_align.sv:684-688` | config `regs[11+d]` 전체 32-bit를 latch | 21-bit 제한 검사 없이 내부 32-bit 상태로 전달 |
| `hw/rtl/core/VX_dma_unit_misal.sv:238-243` | 같은 32-bit latch | misaligned 경로도 동일 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:160-167` | 21-bit가 될 local bound를 32-bit config word로 그대로 전달 | ABI는 유지해야 하지만 명시적 zero-extension이 없음 |
| `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:979-982` | 32-bit descriptor register를 lookahead bound에 그대로 연결 | 인터페이스 축소 시 암묵적 truncation 위험 |

### 2. Generic aligned/misaligned DMA 내부

| 파일/현재 line | 현재 상태 | 수정 필요성 |
|---|---|---|
| `hw/rtl/core/VX_dma_unit_align.sv:430` | `bound_r[NDIM]` 32-bit | 21-bit로 축소 |
| `hw/rtl/core/VX_dma_unit_align.sv:451-458` | lookahead slot의 `prep_bound_r` 32-bit | slot마다 22 bit, 총 44 bit 불필요 |
| `hw/rtl/core/VX_dma_unit_align.sv:516-540` | `multiplier_bound` 32-bit | `stride * (bound-1)`가 32x32로 유지됨 |
| `hw/rtl/core/VX_dma_unit_align.sv:619-658` | 네 개 `VX_mul_u32_pipe`가 32x32 -> 64 | 실제 필요한 곱은 32x21 -> 53 |
| `hw/rtl/core/VX_dma_unit_align.sv:809-810,1393` | read/write dimension counter가 32-bit | bound와 같은 21-bit면 충분 |
| `hw/rtl/core/VX_dma_unit_align.sv:1107-1228,1498-1506,2110-2153` | 비교/증가 상수가 `32'd1/0` | 21-bit 타입에 맞춰 명시적으로 변경 필요 |
| `hw/rtl/core/VX_dma_unit_misal.sv:167,267,273` | bound 및 read/write dimension counter가 32-bit | aligned와 같은 문제 |
| `hw/rtl/core/VX_dma_unit_misal.sv:188-215` | 여섯 개 32x32 correction multiplier | 32x21 -> 53으로 축소 가능 |
| `hw/rtl/core/VX_dma_unit_misal.sv:298-319,848-897` | 32-bit counter 비교/증가 | 21-bit로 통일 필요 |
| `hw/rtl/libs/VX_mul_u32_pipe.sv:4-73` | 입력/partial product/result가 32x32 전용 | bound 폭을 줄여도 multiplier 내부 자원은 줄지 않음 |

`stride_bound_r`는 주소 보정값이므로 64-bit를 유지한다. multiplier의 native 53-bit 결과를 여기에서만 64-bit로 zero-extension한다. 기존 4-cycle valid latency도 유지한다.

### 3. Local/GEMM DMA executor 및 queue metadata

#### 공통 misaligned wrapper

| 파일/현재 line | 현재 상태 | 문제 |
|---|---|---|
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:110` | `prepared_bounds_r` 32-bit | prepared descriptor 상태 폭 낭비 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:142-146` | `seg_size`와 세 bound를 각각 64-bit로 만든 뒤 곱함 | output DMA의 실제 timing 경로. 작은 operand가 64-bit multiplier 입력으로 확장됨 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:229` | 위 조합 결과를 `write_bytes_remaining_r`에 same-cycle capture | cycle은 유지해야 하므로 곱셈 폭 자체를 줄여야 함 |

#### input/qparam/weight overlap DMA

| 파일/현재 line | 현재 상태 | 문제 |
|---|---|---|
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:577,1059,1069,1673` | source/destination command metadata의 bound가 32-bit | command FIFO와 request payload까지 불필요한 bit가 이동 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:651-653,1142-1144,1748-1750` | total beats 식의 중간 폭이 명시되지 않음 | SystemVerilog context에 의존하며 overflow/truncation 위치가 불명확 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:660,1152,1154,1756` | dimension counter가 32-bit | 21-bit bound에 비해 큼 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:662-665,1156-1164,1758-1761` | `64'(index * stride)` | cast가 곱셈 바깥에 있어 32-bit 곱셈 결과가 먼저 잘릴 수 있음. 21-bit counter 적용 후에는 21x32 -> 53을 명시해야 함 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:809-819,1321-1354,1944-1953` | 32-bit 증가/비교 | 21-bit 타입 상수로 변경 필요 |

#### legacy/simple local DMA와 weight gather

| 파일/현재 line | 현재 상태 | 문제 |
|---|---|---|
| `hw/rtl/core/gemm/VX_lmem_dma.sv:82,127-162` | bound/counter 32-bit, `index * stride` 폭 불명확 | legacy unittest 경로도 새 interface 계약과 맞춰야 함 |
| `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv:37-70` | `COUNT_BITS=32`, bound0에서 group count 계산 | 실제 group count는 21-bit 이내지만 queue count/payload가 32-bit |
| `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv:82-87` | `fetch_beat * ROWS_PER_GROUP * stride` 폭이 암묵적 | group index와 32-bit stride의 native product 폭을 명시해야 함 |

### 4. Bound producer와 descriptor generator

| 파일/현재 line | 현재 상태 | 계획상 처리 |
|---|---|---|
| `hw/rtl/core/gemm/VX_gemm_node.sv:658-660,697-699,847-850,890-893,1017-1019` | 대부분 16-bit command bound 또는 상수 1을 32-bit interface에 연결 | 21-bit로 명시적 zero-extension/상수화 |
| `hw/rtl/core/gemm/VX_gemm_node_naive.sv:302-304,397-399,484-488,594-596` | 일부 source가 32-bit derived value | 21-bit slice 전에 upper-bit assertion 추가 |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl.sv:170-191,231-233` | 내부 bnd0/1/2가 32-bit, bnd0 source는 16-bit | 내부 21-bit로 축소하고 config write에서 32-bit zero-extension |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv:268-347,384-398` | `dram_b*`, `bnd*`가 32-bit derived value | 값 생성부에서 fit assertion 후 21-bit descriptor field 사용 |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv:431-433,467-469` | queued descriptor bnd가 32-bit | queue 내부는 21-bit, MMIO/config programming 시 32-bit zero-extension |
| `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:700-765` | `ch_words/total_bpb`로 32-bit descriptor bound 생성 | 계산은 필요한 기존 폭으로 하고 저장 경계에서 21-bit fit 검사 및 zero-extension |
| `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv:811-925` | store chunk의 `orig_bnd0/chunk_bnd0/chunk_bnd1`이 32-bit | bound 성격의 값만 21-bit로 축소; remaining beat counter는 32-bit 유지 |
| `hw/rtl/mem/VX_dma_engine.sv:365-385,437` | 32-bit config bound를 검증하고 BND0 일부만 burst counter에 저장 | 기존 descriptor shape assertion에 `[31:21]==0` 추가, AXI burst counter 폭은 그대로 유지 |

### 5. 64-bit 선확장이 있는 관련 곱셈

| 파일/현재 line | 식 | 수정 방향 |
|---|---|---|
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:142-146` | `64'(seg_size) * 64'(b0) * 64'(b1) * 64'(b2)` | 32x21, 53x21, 74x21의 명시적 unsigned stage로 계산하고 최종 64-bit 값으로 정규화 |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv:407` | `64'(seg_size) * 64'(bnd0)` | 32x21 -> 53 결과를 만든 후 64-bit zero-extension |
| `hw/rtl/core/gemm/VX_gemm_node.sv:224-238` | 16-bit command bound와 compile-time byte constant를 모두 64-bit로 확장 | 16-bit x constant-width native product 후 64-bit counter에 zero-extension |

`VX_gemm_fsm.sv`와 `VX_gemm_fsm_naive.sv`의 64-bit matrix/tile address 계산은 DMA bound 곱셈이 아니며, 주소 범위가 실제로 64-bit이므로 이번 변경에서 제외한다. MMIO entry address의 `entry_id * ENTRY_STRIDE_BYTES`도 별도 주소 계산이라 제외한다.

### 6. 항상 3D로 합성되는 현재 구조

| 파일/현재 line | 현재 구조 | 낮은 차원에서 남는 불필요한 logic |
|---|---|---|
| `hw/rtl/core/VX_dma_unit_align.sv:63-65,429-458` | descriptor dimension을 localparam 3으로 고정 | inactive bound/stride register, read/write counter 및 lookahead metadata가 남음 |
| `hw/rtl/core/VX_dma_unit_align.sv:1107-1230,1498-1506,2110-2153` | 항상 3단 last/rollover/select chain | 1D local DMA도 BND1/BND2 비교와 dimension mux를 통과함 |
| `hw/rtl/core/VX_dma_unit_align.sv:619-658` | D0/D1 correction multiplier 네 개 | 1D에는 correction이 전혀 필요 없고 2D에는 D0 두 개만 필요함 |
| `hw/rtl/core/VX_dma_unit_misal.sv:166-215` | D0/D1/D2 correction multiplier 여섯 개 | D2 correction은 3D에서도 다음 상위 dimension이 없어 사용되지 않음. 1D/2D에서는 더 많이 제거 가능 |
| `hw/rtl/core/VX_dma_unit_misal.sv:298-319,848-897` | 항상 3D next-base/counter logic | inactive dimension이 상수라는 사실을 module 내부가 보장하지 못함 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:142-146` | total bytes에 세 bound를 항상 곱함 | production output DMA는 1D인데 3단 product cone이 존재 |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv:577-665,1059-1164,1673-1761` | overlap queue가 세 bound/stride와 3D address generator를 저장 | production input/weight/qparam은 모두 1D라 command/request payload와 address adder chain이 과도함 |
| `hw/rtl/core/gemm/VX_lmem_dma.sv:82-162` | legacy local DMA도 `NDIM=3` 구조 | parameter가 있지만 production specialization과 inactive-dimension contract가 없음 |

차원별 필요한 correction product 수는 source/destination을 합쳐 다음과 같다.

| `MAX_DIMS` | 사용 dimension | 필요한 correction | multiplier 수 |
|---:|---|---|---:|
| 1 | D0 | 없음 | 0 |
| 2 | D0, D1 | `stride0 * (bound0-1)` | 2 |
| 3 | D0, D1, D2 | D0 및 D1 correction | 4 |

D2 correction은 D2에서 더 상위 dimension으로 rollover할 때만 필요하지만 최대 차원이 3이므로 어떤 설정에서도 필요하지 않다. 따라서 misaligned core의 현재 D2 source/destination multiplier 두 개는 `MAX_DIMS=3`에서도 제거 대상이다.

## 구현 설계

### 단계 1: 단일 bound 폭 정의와 ABI 경계 확립

1. `VX_config.vh`에 override 가능한 ``DMA_BOUND_WIDTH``를 추가하고 기본값을 21로 둔다.
2. `VX_lmem_dma_ctrl_if`, `VX_dma_lookahead_if`, legacy `VX_dma_if`가 이 폭을 사용하도록 한다.
3. `VX_dma_unit`, `VX_dma_engine` 및 aligned/misaligned 구현에 `BOUND_WIDTH` parameter를 전달한다. 기본값은 ``DMA_BOUND_WIDTH``이다.
4. 32-bit config/MMIO word layout은 바꾸지 않는다.
5. config descriptor 수락 시 세 bound의 `[31:BOUND_WIDTH] == 0`을 검사한다. local interface에 32-bit derived 값을 넣는 producer는 interface에 넣기 전 source 값의 upper bit를 검사한다.

이렇게 하면 software ABI와 command memory layout은 그대로이고, descriptor 경계 안쪽의 배선/FF/queue payload만 줄어든다.

### 단계 2: bound 상태와 dimension counter 축소

다음을 모두 `BOUND_WIDTH`로 통일한다.

- aligned/misaligned generic DMA의 `bound_r`, `rd_i_dim`, `wr_i_dim`, `wr_i_dim_next`
- aligned lookahead의 `prep_bound_r`, `multiplier_bound`
- local DMA의 `prepared_bounds_r`, 모든 overlap metadata의 `bounds`
- local/overlap/legacy DMA의 dimension counter
- GEMM controller의 내부/queued descriptor bound field

비교와 increment는 `BOUND_WIDTH'(1)` 및 `'0`을 사용한다. `seg_size`, stride, total-beat counter, base address는 각각 기존 32/32/32/64-bit 계약을 유지한다.

### 단계 2A: `MAX_DIMS` compile-time specialization

`VX_dma_unit`, `VX_dma_unit_align`, `VX_dma_unit_misal`, `VX_dma_engine`, `VX_dma_node`, `VX_lmem_dma_misal` 및 범용 overlap/local DMA module에 다음 parameter를 추가한다.

```systemverilog
parameter int MAX_DIMS = 3;
```

구현 원칙:

1. descriptor/config interface는 계속 세 dimension을 전달한다. software register map과 producer wiring은 바꾸지 않는다.
2. module 내부에는 `DESC_DIMS=3`과 `MAX_DIMS`를 구분한다. storage, counter, metadata와 generate loop는 `MAX_DIMS`까지만 만든다.
3. inactive dimension은 hardware datapath에 연결하지 않는다. descriptor 수락 시에만 다음 simulation contract를 검사한다.
   - `MAX_DIMS=1`: `BND1==1 && BND2==1`
   - `MAX_DIMS=2`: `BND2==1`
4. inactive stride 값에는 기능적 제약을 두지 않고 완전히 무시한다. production producer는 가독성을 위해 계속 0을 기록한다.
5. last-segment, counter increment 및 next-base는 `generate if`로 1D/2D/3D 식을 별도로 만든다. runtime `for` loop나 `MAX_DIMS` 비교 mux를 critical datapath에 추가하지 않는다.
6. 1D address progression은 `base + stride0`, 2D rollover는 `stride1 - stride0*(bound0-1)`, 3D rollover는 기존 D2 식까지 지원한다.
7. 1D/2D specialization에서도 기존 state/handshake latency를 보존한다. misaligned 1D처럼 correction multiplier가 0개인 경우에는 기존 4-cycle precalc latency를 작은 valid-delay로 유지하고, 이번 변경에서 command cycle을 당기지 않는다.

aligned core의 `cmd_precalc_needed`, `prep_cmd_needed`, `result_ready`, read/write rollover dependency mask도 `MAX_DIMS`별 correction mask를 사용한다. 단순히 multiplier instance만 제거하고 기존 4-bit dependency mask를 남기면 1D/2D가 존재하지 않는 결과를 기다릴 수 있으므로, issue/ready/capture를 같은 compile-time mask로 함께 줄인다.

aligned lookahead interface는 ABI 단순화를 위해 현재 두 correction-dimension field를 유지한다. `MAX_DIMS=1`에서는 두 field를 모두 무시하고, `MAX_DIMS=2`에서는 D0 field만 사용하며, synthesis가 unused path를 제거하도록 한다.

OOC 비교가 같은 RTL parameter를 사용하도록 `VX_dma_unit_ooc.sv`, `VX_dma_engine_ooc.sv`와 `ci/run_dma_ooc.sh`에도 `MAX_DIMS`를 전달한다. script에는 `--max-dims 1|2|3` 옵션을 추가하고 선택값을 top generic과 manifest에 기록한다.

### 단계 3: 32x21 pipelined correction multiplier

`VX_mul_u32_pipe`를 폭 parameter화하되 기본 32x32 동작과 4-cycle latency를 보존한다.

- `A_WIDTH=32`, `B_WIDTH=BOUND_WIDTH`
- native result width는 `A_WIDTH+B_WIDTH`, 현재 설정에서는 53-bit
- 16-bit limb 구조는 유지하되 B의 upper limb는 5-bit로 축소한다.
- aligned/misaligned DMA의 `precalc_result`와 lookahead result slot은 53-bit로 저장한다.
- 주소 correction에 연결할 때만 `{{(64-53){1'b0}}, result}`로 확장한다.
- multiplier generate 수는 `2 * (MAX_DIMS - 1)`로 제한한다. 1D는 0개, 2D는 source/destination D0 두 개, 3D는 D0/D1 네 개이다.
- misaligned core의 현재 D2 multiplier와 `stride_bound_r[*][2]`는 default 3D에서도 제거한다.

기존 valid/tag pipeline 깊이는 변경하지 않으므로 prepare, activate 및 command start cycle은 바뀌지 않는다.

### 단계 4: total byte/beat 계산의 중간 폭 명시

SystemVerilog의 assignment context나 unsized constant에 폭 결정을 맡기지 않고 intermediate net을 선언한다.

`descriptor_write_bytes`는 각 단계의 정확한 최소 폭을 유지하면서 다음처럼 계산한다.

```systemverilog
logic [52:0] bytes_d0;       // 32 x 21
logic [73:0] bytes_d01_full; // 53 x 21
logic [94:0] bytes_all_full; // 74 x 21
logic [63:0] descriptor_write_bytes;

assign bytes_d0       = ctrl_if.seg_size * ctrl_if.bounds[0];
assign bytes_d01_full = bytes_d0 * ctrl_if.bounds[1];
assign bytes_all_full = bytes_d01_full * ctrl_if.bounds[2];
assign descriptor_write_bytes = bytes_all_full[63:0];
```

- 첫 곱셈 전에는 어느 operand도 64-bit로 확장되지 않는다.
- 중간 결과도 53-bit, 74-bit의 수학적으로 필요한 폭을 유지하며 중간 truncation을 하지 않는다.
- 정상 descriptor는 총 byte 수가 64-bit에 들어와야 하므로 simulation에서는 `bytes_all_full[94:64] == 0`을 검사한다.
- overflow 검사는 simulation-only로 두어 hardware critical cone에 추가하지 않는다.
- `write_bytes_remaining_r` capture는 기존과 같은 cycle에 수행한다.

`command_total_beats`도 `(seg_size / BUS_BYTES)`와 21-bit bounds의 stage width를 명시하고, 최종 32-bit count에 들어가는지 simulation assertion을 추가한다. queue interface의 32-bit count 자체는 바꾸지 않는다.

`MAX_DIMS`에 따라 product stage 자체도 generate로 줄인다.

- 1D: `seg_size * b0`만 계산, exact width 53-bit
- 2D: 위 결과에 `b1`을 곱함, exact width 74-bit
- 3D: 위 결과에 `b2`를 곱함, exact width 95-bit

각 설정에서 최종 count 폭을 넘는 upper bit assertion은 해당 exact-width 결과에만 적용한다. 이 구조로 1D output/local DMA에서 BND1/BND2 multiplier cone이 합성되는 것을 구조적으로 막는다.

### 단계 5: 주소 곱셈을 native width로 수정

overlap/local DMA의 각 active dimension에 대해 아래 형태의 53-bit intermediate를 만든다.

```systemverilog
logic [52:0] rd_dim_stride[MAX_DIMS];
for (genvar d = 0; d < MAX_DIMS; ++d)
    assign rd_dim_stride[d] = rd_i_dim_r[d] * fetch_source_meta.strides[d];

assign rd_src_byte_addr = fetch_source_meta.base_addr
    + 64'(rd_dim_stride[0])
    + 64'(rd_seg_offset_r);
```

2D/3D generate branch에서만 D1/D2 term을 추가한다. qparam write address에도 같은 구조를 적용한다. legacy `VX_lmem_dma.sv`는 output address가 32-bit이므로 53-bit native product의 upper bit가 0인지 simulation에서 검사한 뒤 low 32-bit를 더해 기존 주소 폭을 유지한다.

overlap queue metadata도 `MAX_DIMS`개의 bound/stride만 저장한다. 1D production specialization의 command payload 감소량은 대략 다음과 같다.

- source metadata 하나당: bound 42 bit + stride 64 bit = 106 bit 감소
- qparam source+destination metadata: command당 212 bit 감소
- dimension read/write counter: counter 하나당 42 bit 감소

### 단계 6: producer 정리

- `gemm_unified_cmd_t.bound`는 이미 `VX_gpu_pkg.sv:1013`에서 16-bit이므로 변경하지 않는다.
- improve `VX_gemm_node`의 command bound는 21-bit interface로 zero-extension한다.
- naive 경로의 `mt_eff`, `nt_eff`, `kt_eff`, `groups_eff`, `output_mt_eff`는 계산 폭을 유지하되 DMA descriptor로 내보낼 때 21-bit fit을 검사한다.
- TMEM DMA의 `ch_words`, `total_bpb`, store chunk budget/remaining 계산은 32-bit를 유지한다. BND register에 들어가는 `sub_burst_size`, `total_bpb >> ...`, `chunk_bnd0`, `chunk_bnd1`, `NUM_BURST_GROUPS`만 21-bit fit을 검사하고 32-bit config word로 zero-extension한다.
- `VX_lmem_weight_gather_dma`는 bound-derived group count의 최소 폭을 사용하되, 공통 fetch/sink queue count protocol을 바꾸지 않기 위해 command count port에는 zero-extension한다.

### Production instance별 `MAX_DIMS`

| hierarchy / RTL 위치 | 지정값 | 근거 |
|---|---:|---|
| `VX_core.u_VX_dma_node` (`hw/rtl/core/VX_core.sv:314-323`) | 3 | CPU/software가 programming하는 generic DMA이다. 세 BND/stride register의 일반 기능을 보존해야 함 |
| `VX_tmem_subsystem.u_dma_engine` (`hw/rtl/mem/VX_tmem_subsystem.sv:193-216`) | 3 | target은 32 HBM 영역 / 8 DMA channel이라 `NUM_BURST_GROUPS=4`. burst descriptor가 `VX_gemm_tmem_dma_ctrl.sv:742-745`에서 실제 `BND2=4`를 사용함 |
| `VX_gemm_dma_ctrl_with_dma.dma_node` (`hw/rtl/core/VX_gemm_dma_ctrl_with_dma.sv:54-67`) | 1 | 전용 producer `VX_gemm_dma_ctrl.sv:183-191`은 BND0만 변경하고 BND1/BND2는 항상 1. 현재 main hierarchy에서는 사용되지 않지만 standalone 구성은 특화 가능 |
| improve input `u_ldma_input` (`VX_tmem_subsystem.sv:724-766`) | 1 | `VX_gemm_node.sv:658-660`에서 BND1/BND2=1 |
| improve weight `u_ldma_weight` (`VX_tmem_subsystem.sv:768-811`) | 1 | `VX_gemm_node.sv:697-699`에서 BND1/BND2=1 |
| improve scale `u_ldma_scale` (`VX_tmem_subsystem.sv:813-851`) | 1 | `VX_gemm_node.sv:847-850`에서 BND1/BND2=1 |
| improve zero-point `u_ldma_zero_point` (`VX_tmem_subsystem.sv:853-891`) | 1 | `VX_gemm_node.sv:890-893`에서 BND1/BND2=1 |
| improve output `u_ldma_output` (`VX_tmem_subsystem.sv:893-916`) | 1 | `VX_gemm_node.sv:1017-1021`에서 모든 bound=1이고 전체 row byte 수가 seg_size에 들어감 |
| naive input `u_input_lmem_dma` (`VX_gemm_node_naive.sv:1232-1251`) | 1 | `VX_gemm_node_naive.sv:302-304`에서 BND1/BND2=1 |
| naive quant-param `u_quant_param_lmem_dma` (`VX_gemm_node_naive.sv:1267-1286`) | 1 | `VX_gemm_node_naive.sv:484-488`에서 BND1/BND2=1 |
| naive output `u_output_lmem_dma` (`VX_gemm_node_naive.sv:1288-1307`) | 1 | `VX_gemm_node_naive.sv:594-596`에서 BND1/BND2=1 |
| naive `u_weight_gather_dma` (`VX_gemm_node_naive.sv:1253-1265`) | fixed 1D | module 자체가 bound0만 사용하고 `VX_lmem_weight_gather_dma.sv:295-300`에서 BND1/BND2=1을 이미 검사함. 범용 dimension parameter는 추가하지 않음 |
| legacy `VX_lmem_dma` 및 standalone generic unittest | 기본 3 | 기존 3D 회귀 검증용. production opt-in 근거가 없으므로 축소하지 않음 |

현재 production hierarchy에는 항상 BND2=1이면서 BND1을 실제 사용하는 것으로 확정된 별도 2D-only instance가 없다. 따라서 2D 기능은 구현하고 focused unittest로 검증하되 production에 추측으로 적용하지 않는다.

향후 물리 HBM memory region 수(`PLATFORM_MEMORY_NUM_BANKS`)와 DMA channel 수가 같아 channel당 순회할 region group이 하나뿐인 구성에서는 `NUM_BURST_GROUPS=1`이므로 engine을 2D로 제한할 수 있다. 다만 현재 U55C target은 channel당 네 region group(`NUM_BURST_GROUPS=4`)을 순회하므로 해당되지 않는다.

## 구현 순서

1. 현재 software/test workload에서 실제 생성되는 BND 최대값을 로그/정적 범위로 확인하고 21-bit 범위 안인지 검증한다.
2. bound 폭 macro/parameter와 세 interface를 변경한다.
3. `MAX_DIMS`를 wrapper/core에 전달하고 parameter range 및 inactive-bound assertion을 먼저 추가한다.
4. producer의 명시적 cast와 upper-bit assertion을 추가해 모든 interface 연결의 compile warning을 없앤다.
5. aligned/misaligned generic DMA를 1D/2D/3D generate branch로 나누고 bound state/counter/correction multiplier를 축소한다.
6. local misaligned wrapper의 prepared state 및 dimension별 `descriptor_write_bytes`를 수정한다.
7. input/qparam/weight overlap metadata, counter, total-beat/address 곱셈을 `MAX_DIMS`에 맞게 수정한다.
8. production local DMA instance에 `MAX_DIMS=1`을 명시하고 generic DMA/engine은 표의 값대로 유지한다.
9. legacy local DMA와 weight gather를 같은 bound 계약으로 맞춘다.
10. controller/engine의 queued bound 및 config 경계 assertion을 정리한다.
11. 1D/2D/3D unit simulation, xrt-vcs-sim, 동일 조건 OOC 순서로 검증한다.

각 단계는 기능 변경과 폭 변경을 섞지 않고 compile 가능한 단위로 진행한다. 현재 worktree의 response-DPRAM 관련 미커밋 변경은 별도 작업이므로 이 최적화에서 되돌리거나 재작성하지 않는다.

## 검증 계획

### 1. 정적/컴파일 검증

- 모든 32-bit config bound -> 21-bit 내부 경계에 명시적 slice와 assertion이 있는지 `rg`로 확인한다.
- `bound_r`, `prep_bound_r`, overlap metadata 및 dimension counter에 남은 `[31:0]` 선언을 전수 확인한다.
- bound/seg_size 관련 `64'(...) * 64'(...)`가 제거됐는지 확인한다.
- `64'(index * stride)`가 남지 않고 53-bit intermediate를 사용하는지 확인한다.
- 기존 descriptor register 수, index 및 software-visible word width가 바뀌지 않았는지 확인한다.
- 모든 `MAX_DIMS` parameter에 `1..3` elaboration check가 있고 wrapper에서 child까지 동일 값이 전달되는지 확인한다.
- `MAX_DIMS=1` netlist에 D1/D2 counter, stride storage, rollover mux 및 correction multiplier가 없고, `MAX_DIMS=2`에는 D2 logic과 D1 correction multiplier가 없는지 확인한다.
- generic `MAX_DIMS=3` config/register behavior가 기존 descriptor ABI와 동일한지 확인한다.

### 2. RTL unittest

설정된 build directory에서 다음 VCS unittest를 실행한다.

- generic: `dma_engine`, `dma_node`, `dma_mem_unit`, `dma_mem_unit_misal`, `dma_padding_optional`
- local: `lmem_dma`, `lmem_dma_misal`, `lmem_weight_gather_dma`
- overlap: `lmem_dma_input_overlap`, `lmem_dma_qparam_overlap`, `lmem_dma_weight_overlap`
- controller: `gemm_dma_ctrl`, `gemm_dma_ctrl_naive_pipeline`, `gemm_tmem_dma_ctrl`
- integration: `gemm_node_improve`

추가 directed case:

- bound `0`, `1`, `21'h1f_ffff`
- 기존 maximum matrix dimension인 `21'h10_0000` (`2^20`)
- 32-bit config에 `32'h0020_0000`을 넣어 upper-bit assertion이 발생하는 negative test
- 32x21 stride correction의 최대값과 random reference 비교
- 3D total bytes/total beats가 32/64-bit에 정확히 들어가는 경계값
- 32/64-bit count overflow descriptor가 simulation assertion을 발생시키는 negative test
- address product가 32-bit를 넘지만 53-bit에는 들어가는 case로 기존 암묵적 truncation 제거 확인
- lookahead prepare/activate 결과와 non-lookahead 결과의 bit/cycle 일치
- focused dual-DUT dimension test를 추가한다.
  - `MAX_DIMS=1`과 baseline `MAX_DIMS=3`에 BND1/BND2=1인 동일 1D descriptor를 넣고 request address/data/byteen, handshake 및 done cycle 비교
  - `MAX_DIMS=2`와 baseline `MAX_DIMS=3`에 BND2=1인 동일 2D descriptor를 넣고 D0 rollover 및 D1 stride address 비교
  - aligned/misaligned, G2L/L2G, backpressure 및 outstanding overlap을 모두 포함
  - inactive stride에 nonzero random 값을 넣어도 1D/2D specialized 결과가 변하지 않는지 확인
- negative dimension contract test를 추가한다.
  - `MAX_DIMS=1`에서 BND1 또는 BND2가 1이 아니면 assertion
  - `MAX_DIMS=2`에서 BND2가 1이 아니면 assertion
  - `MAX_DIMS=0/4`는 elaboration failure
- 기존 3D test의 BND0/BND1/BND2 rollover case를 유지해 default mode 회귀를 막는다.
- target TMEM DMA test에서 burst mode의 BND2가 4이고 `MAX_DIMS=3` engine이 이를 그대로 실행하는지 확인한다.

### 3. xrt-vcs-sim

적절한 `configs/` 파일을 source한 configured build에서 `ci/run_black.sh xrt-vcs-sim`으로 FPINT GEMM을 실행한다.

- qdir 0/1과 load/store/output DMA를 모두 포함한다.
- 결과 bit 정확성을 확인한다.
- 기존 baseline 대비 실행 cycle 변화가 2% 이내인지 확인한다. 이 변경은 pipeline stage나 handshake를 추가하지 않으므로 목표는 cycle-identical이다.

### 4. GEMM node OOC timing/resource

기존과 동일한 U55C part, improve TH16/WLOAD8 설정 및 Vivado option으로 7 ns clock OOC 합성을 실행한다.

먼저 `ci/run_dma_ooc.sh --max-dims 1|2|3`으로 동일 bus width의 aligned/misaligned unit을 비교해 dimension parameter가 실제 netlist를 줄이는지 분리 측정한 뒤 GEMM node 전체 OOC를 실행한다.

- setup violation 없음: `WNS >= 0 ns`
- `descriptor_write_bytes -> write_bytes_remaining_r` 경로에서 64-bit 선확장 multiplier chain이 사라졌는지 schematic/timing report로 확인
- 1D local DMA의 `descriptor_write_bytes`가 32x21 단일 product 이하이고 BND1/BND2 product가 없는지 확인
- 1D local DMA에 `stride * (bound-1)` correction multiplier가 0개인지 확인
- 3D HBM/TMEM DMA에는 32x21 D0/D1 correction만 남고 사용되지 않는 D2 correction이 없는지 확인
- overlap command/request metadata payload가 `MAX_DIMS=1` 폭으로 줄었는지 hierarchy report에서 확인
- LUT/FF/DSP/BRAM을 변경 전과 비교하고 BRAM 증가는 허용하지 않음
- command accept, prepare/activate, DMA done latency가 RTL simulation과 동일한지 확인

7 ns를 만족하지 못하면 먼저 실제 worst path가 여전히 이 두 곱셈 계열인지 확인한다. 다른 경로가 worst로 올라온 경우에는 이번 변경의 기능/cycle 회귀 여부와 자원 감소를 별도로 판정하고, 새 timing 문제는 별도 최적화로 분리한다.

## 완료 기준

- 모든 DMA bound 저장/전송 경로가 21-bit 내부 계약을 사용한다.
- 32-bit config/MMIO ABI는 그대로 유지된다.
- bound 상위 11-bit 사용은 simulation에서 즉시 검출된다.
- bound/seg_size 및 dimension/stride 곱셈은 operand native width로 수행되고, 64-bit destination에서만 zero-extension된다.
- `MAX_DIMS=1/2/3`이 각각 inactive dimension logic을 합성에서 제거하며, 잘못된 inactive bound는 simulation에서 즉시 검출된다.
- production GEMM local DMA는 모두 1D로 특화되고, generic CPU DMA와 target HBM/TMEM DMA는 3D 기능을 유지한다.
- 유효 descriptor에서 기존 RTL과 주소, byte count, request, completion cycle이 동일하다.
- FPINT GEMM 결과가 동일하고 성능 변화가 2% 이내이다.
- 동일 OOC 조건에서 7 ns setup violation이 없다.

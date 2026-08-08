# TMEM Weight Multi-Outstanding 구현 계획

## 목표

`VX_tmem_wide_read_switch`가 한 weight tile을 구성하는 모든 wide read를
연속으로 받을 수 있도록 multi-outstanding 구조로 변경한다.

Weight 경로의 outstanding 수는 다음 관계를 만족해야 한다.

```text
MXU_WLOAD_NUM * WEIGHT_OUTSTANDING = MXU_ROW
WEIGHT_OUTSTANDING = MXU_ROW / MXU_WLOAD_NUM
```

지원하는 설정별 목표값은 다음과 같다.

| MXU_ROW | MXU_WLOAD_NUM | GEMM weight beat | WEIGHT_OUTSTANDING |
|---:|---:|---:|---:|
| 32 | 4  | 64 B  | 8 |
| 32 | 8  | 128 B | 4 |
| 32 | 16 | 256 B | 2 |
| 32 | 32 | 512 B | 1 |

현재 분석한 설정은 `MXU_ROW=32`, `MXU_WLOAD_NUM=8`이므로 목표
`WEIGHT_OUTSTANDING`은 4이다. 이 설정에서는 128-byte request 네 개가
각각 TMEM bank pair `0/1`, `2/3`, `4/5`, `6/7`을 사용하여 한 weight
tile을 완성한다.

## 문제점

### 1. Wide switch가 effective outstanding을 1로 제한한다

Weight local DMA는 여러 read slot을 지원하지만, 그 다음 단계인
`VX_tmem_wide_read_switch`는 하나의 request/response context만 가진다.

```systemverilog
wire can_accept = !req_pending_r && !rsp_active_r && !rsp_valid_r;
assign bus_in_if.req_ready = can_accept;
```

따라서 한 wide request가 다음 단계를 모두 마칠 때까지 다음 request를
받지 않는다.

1. wide request 저장
2. 선택한 TMEM bank들로 request fan-out
3. 모든 bank response 수집
4. 조립한 wide response를 local DMA로 전달

### 2. FSDB에서 요청 간격이 4클럭으로 관측된다

`build/sim/xrtsim_vcs/vcs_cosim.fsdb`를 `tools/fsdb_cli`로 분석한 결과,
첫 weight DMA의 wide request accept 시점은 다음과 같다.

```text
57.105 us
57.145 us
57.185 us
57.225 us
```

`gemm_unit_v2`의 weight request도 57.155, 57.195, 57.235, 57.275 us로
동일하게 4클럭 간격이다. 해당 구간에서 `gemm_unit_v2`의
`w_lmem_bus_if.req_ready`는 계속 1이므로 GEMM-side backpressure는 원인이
아니다.

전체 파형에서는 weight request 256개가 정상 완료됐지만 TMEM source
request stall이 576클럭 발생했고, GEMM destination write stall은
0클럭이었다. 병목은 wide switch의 `req_ready`이다.

### 3. 기존 local-DMA outstanding 설정이 switch 처리량으로 이어지지 않는다

`VX_lmem_dma_misal`/`VX_dma_unit_align`는 tagged read slot을 지원한다.
하지만 wide switch가 한 transaction의 `req_data_r`, `req_issued_r`,
`rsp_seen_r`, `rsp_data_r`, `rsp_tag_r`만 보관하므로 local DMA가 가진
outstanding capacity가 switch 경계에서 직렬화된다.

### 4. 단순히 `can_accept`만 완화할 수 없다

기존 단일 context 레지스터를 유지한 채 다음 request를 받으면 다음
문제가 생긴다.

- 이전 request의 bank mask와 request metadata가 덮어써진다.
- 서로 다른 transaction의 bank response가 같은 `rsp_data_r`에 섞인다.
- response tag가 마지막 request의 tag로 바뀔 수 있다.
- response backpressure 중 context를 재사용하면 데이터 안정성이 깨진다.

따라서 request, bank issue 상태, response 수집 상태를 outstanding
transaction별로 분리해야 한다.

### 5. 기존 unittest가 single-outstanding 동작을 요구한다

`hw/unittest/tmem_wide_read_switch/tb_VX_tmem_wide_read_switch.sv`는 첫
request를 받은 다음 `req_ready==0`이어야 한다고 검사한다. 이 검사는
새 목표와 반대이므로 back-to-back accept와 multi-context correctness를
검증하도록 변경해야 한다.

## 해결책

### 1. Weight outstanding 값을 tile 구조에서 유도한다

Weight 전용 outstanding 기본값을 다음 식으로 정의한다.

```text
WEIGHT_OUTSTANDING = MXU_ROW / MXU_WLOAD_NUM
```

구현 시 다음 원칙을 적용한다.

- `W_LMEM_DMA_RD_OUTSTANDING_SLOTS`의 기본값을 global
  `LMEM_DMA_RD_OUTSTANDING_SLOTS`의 단순 alias가 아닌 위 식으로 만든다.
- `VX_tmem_subsystem.W_RD_OUTSTANDING`을 weight local DMA와
  `VX_tmem_wide_read_switch`에 동일하게 전달한다.
- input, scale/zero, output DMA의 outstanding 설정은 변경하지 않는다.
- 설정 파일이 global `LMEM_DMA_RD_OUTSTANDING_SLOTS=8`을 지정하더라도
  WLOAD8 weight 경로는 별도 기본값 4를 사용하게 한다.
- 실험을 위한 weight 전용 override를 유지하더라도 아래 관계를 어기는
  값은 elaboration에서 실패시킨다.

필수 정적 검사는 다음과 같다.

```text
MXU_WLOAD_NUM > 0
MXU_ROW % MXU_WLOAD_NUM == 0
W_RD_OUTSTANDING > 0
W_RD_OUTSTANDING is power of two
MXU_WLOAD_NUM * W_RD_OUTSTANDING == MXU_ROW
TAG_VALUE_WIDTH >= clog2(W_RD_OUTSTANDING)
```

### 2. Wide switch에 transaction context 배열을 추가한다

`VX_tmem_wide_read_switch`에 `OUTSTANDING` parameter를 추가하고 기존
단일 상태를 context 배열로 바꾼다.

각 context는 최소한 다음 정보를 가진다.

- context valid/state
- 원본 request tag
- bank group mask
- 아직 issue되지 않은 bank mask
- request address, byte enable, flags
- 이미 받은 response bank mask
- bank lane별 response data
- assembled response complete 상태

Weight switch는 read 전용 경로로 확정한다. context에는 wide write
payload를 저장하지 않고 bank request의 `data`는 0으로 구동한다. 입력
request의 `rw != 0`은 simulation assertion으로 즉시 실패시킨다. 현재
유일한 인스턴스인 `VX_tmem_subsystem.u_switch_weight`는 LMEM-to-GEMM
`DIR=0` read 경로이므로 wide write 호환성은 이번 변경 범위에 포함하지
않는다.

Context index는 weight local DMA가 생성하는 read-slot tag의 하위 비트를
사용한다. local DMA와 switch에 동일한 outstanding 값을 전달하므로,
동시에 살아 있는 request는 서로 다른 slot tag를 가진다. Bank tag는
기존처럼 `{bank_id, original_tag}`를 유지하며 tag width를 추가로 늘리지
않는다.

### 3. Request accept와 bank issue를 분리한다

입력 request는 빈 context가 있으면 매 클럭 accept한다. Bank request
발행은 별도 issue queue에서 처리한다.

- request accept 시 context를 채우고 context ID를 issue queue와 response
  order queue에 넣는다.
- issue queue의 head context가 선택한 bank group으로 request를 fan-out한다.
- 일부 bank만 ready인 경우 accepted bank bit만 기록하고 나머지 bank의
  valid를 유지한다.
- 현재 context의 모든 bank가 request를 받으면 issue queue에서 pop한다.
- bank들이 ready인 정상 경우에는 한 context를 매 클럭 issue하여 입력의
  back-to-back request를 따라간다.
- 같은 bank group을 사용하는 request가 겹치거나 일부 bank가 stall하면
  현재 context를 완료할 때까지 issue ownership을 유지해 중복 발행을
  방지한다.

현재 WLOAD8 tile의 네 request는 서로 다른 bank pair를 사용하므로 정상
상태에서는 다음 형태가 목표이다.

```text
cycle N+0: accept context 0
cycle N+1: accept context 1, issue banks 0/1
cycle N+2: accept context 2, issue banks 2/3
cycle N+3: accept context 3, issue banks 4/5
cycle N+4:                   issue banks 6/7
```

### 4. Bank response를 tag 기반으로 context별 수집한다

각 bank response에서 original tag의 slot bits를 추출해 대상 context를
결정한다.

- response가 해당 context의 선택 bank에 속하는지 검사한다.
- 이미 수집한 bank의 중복 response를 금지한다.
- `bank_id % BANKS_PER_BEAT` 위치에 data lane을 기록한다.
- context의 선택 bank response가 모두 모이면 complete로 표시한다.
- 서로 다른 bank에서 같은 클럭에 돌아오는 response와 서로 다른
  context로 동시에 돌아오는 response를 모두 처리한다.

총 response payload 저장량은 다음과 같이 한 weight tile 크기로
일정하다.

```text
OUTSTANDING * GEMM_WEIGHT_DATA_SIZE
= (MXU_ROW / MXU_WLOAD_NUM)
  * (MXU_COL * MXU_WLOAD_NUM * W_BIT_WIDTH / 8)
= MXU_ROW * MXU_COL * W_BIT_WIDTH / 8
```

현재 32x32 INT4 설정에서는 WLOAD4/8/16/32 모두 총 4096bit이다. 이번
변경은 context별 packed response array 구조로 고정한다. Synthesis QoR
비교와 그 결과에 따른 저장 구조 변경은 이번 계획의 검증 범위에서
제외한다.

### 5. Response는 accept 순서를 보존한다

기존 single-outstanding switch는 자연스럽게 in-order response를
제공한다. 동작 변화를 최소화하기 위해 response order queue의 head
context가 complete일 때만 upstream response를 보낸다.

- `rsp_valid`가 올라간 뒤 `rsp_ready`가 내려가면 data/tag/context 선택을
  안정적으로 유지한다.
- response handshake가 발생할 때만 context를 free하고 order queue를
  pop한다.
- 뒤 transaction이 먼저 complete돼도 앞 transaction이 완료될 때까지
  보관한다.
- local DMA는 tagged out-of-order response도 처리할 수 있지만, 이번
  변경에서는 불필요한 ordering 변화를 만들지 않는다.

### 6. Assertion과 관측 신호를 추가한다

simulation assertion으로 다음 오류를 즉시 검출한다.

- 이미 사용 중인 tag/context로 새 request accept
- 선택되지 않은 bank의 response
- free context 또는 request-wait 상태가 아닌 context로 response 도착
- 동일 bank response 중복 수집
- issue 완료 전에 같은 bank request 재발행
- response handshake 전 context 해제
- context/order/issue queue occupancy overflow 또는 underflow

`DBG_TRACE_MEM`에는 context ID, tag, bank mask, issue mask, response mask,
complete/pop 이벤트를 추가한다. FSDB에서는 최소한 context valid/state,
queue occupancy, bank issue mask, response complete mask를 확인할 수 있어야
한다.

## 구현 계획 및 변경 scope

### 1. 설정값과 parameter 전달

`hw/rtl/VX_config.vh`의 weight outstanding 정의를 MXU 설정이 정의된
위치로 옮기고 다음 파생 기본값을 사용한다.

```systemverilog
`ifndef W_LMEM_DMA_RD_OUTSTANDING_SLOTS
`define W_LMEM_DMA_RD_OUTSTANDING_SLOTS \
    (`MXU_ROW / `MXU_WLOAD_NUM)
`endif
```

기존 위치에는 input/scale-zero/output의 global alias만 남긴다. config별
`W_LMEM_DMA_RD_OUTSTANDING_SLOTS=4` 하드코딩은 추가하지 않는다. 명시적인
weight override가 이미 주어진 경우는 허용하되 아래 정적 검사를 모두
통과해야 한다.

`VX_tmem_subsystem`은 `u_switch_weight`에 다음 parameter를 전달한다.

```systemverilog
.OUTSTANDING (W_RD_OUTSTANDING)
```

따라서 `u_ldma_weight.RD_OUTSTANDING`과
`u_switch_weight.OUTSTANDING`은 항상 같은 값을 사용한다.

### 2. Context ID와 tag contract

새 context ID를 tag에 추가하지 않는다. `VX_dma_unit_align`이 read
request를 만들 때 `tag.value` 하위 `clog2(RD_OUTSTANDING)` 비트에
`rd_issue_slot_r`을 기록하고, 동시에 사용 중인 slot ID를 재발행하지 않는
기존 contract를 그대로 사용한다.

```text
CTX_BITS_CAP = (OUTSTANDING > 1) ? clog2(OUTSTANDING) : 0
CTX_BITS     = max(1, CTX_BITS_CAP)
ctx_id       = request/response original_tag.value[CTX_BITS-1:0]
```

`OUTSTANDING=1`에서는 `ctx_id=0`으로 고정한다. 입력 request를 accept할
때 해당 context가 free인지 검사하고, bank response를 받을 때 저장된 전체
original tag와 response tag가 일치하는지도 검사한다. 따라서 slot ID가
같지만 UUID 또는 나머지 tag 비트가 다른 response가 잘못된 context에
합쳐지지 않는다.

Bank 쪽 tag 폭과 packing은 변경하지 않는다.

```text
bank request tag = {bank_id, original_tag}
bank response:
  bank_id      = tag[TAG_WIDTH + BANK_SEL_BITS - 1 : TAG_WIDTH]
  original_tag = tag[TAG_WIDTH - 1 : 0]
  ctx_id       = original_tag.value low bits
```

즉 `SWITCH_TAG_WIDTH = TAG_WIDTH + BANK_SEL_BITS`를 유지하고 context ID를
위한 추가 tag bit는 만들지 않는다.

### 3. `VX_tmem_wide_read_switch` context 저장 구조

`VX_tmem_wide_read_switch`에 다음 parameter와 폭 계산을 추가한다.

```systemverilog
parameter int OUTSTANDING = 1;

localparam int CTX_BITS_CAP = (OUTSTANDING > 1)
                            ? $clog2(OUTSTANDING) : 0;
localparam int CTX_BITS     = (CTX_BITS_CAP > 0) ? CTX_BITS_CAP : 1;
localparam int FIFO_CNT_W   = $clog2(OUTSTANDING + 1);
```

기존 단일 transaction 레지스터는 다음 context 배열로 교체한다.

| Context field | 폭 | 용도 |
|---|---:|---|
| `ctx_valid_r` | `OUTSTANDING` | context 할당 여부 |
| `ctx_tag_r` | `OUTSTANDING x TAG_WIDTH` | upstream original tag |
| `ctx_addr_r` | `OUTSTANDING x IN_ADDR_WIDTH` | bank-local address 생성 |
| `ctx_byteen_r` | `OUTSTANDING x WIDE_DATA_SIZE` | bank lane별 read byte enable |
| `ctx_flags_r` | `OUTSTANDING x MEM_FLAGS_WIDTH` | bank request flags |
| `ctx_bank_mask_r` | `OUTSTANDING x NUM_BANKS` | 정렬된 대상 bank group |
| `ctx_issued_r` | `OUTSTANDING x NUM_BANKS` | 이미 handshake한 bank request |
| `ctx_rsp_seen_r` | `OUTSTANDING x NUM_BANKS` | 이미 받은 bank response |
| `ctx_rsp_data_r` | `OUTSTANDING x BANKS_PER_BEAT x DATA_WIDTH` | 조립 중인 wide response |

별도 enum state는 두지 않는다. `valid`, `issued mask`, `response mask`의
조합으로 상태를 표현해 단일 source of truth를 유지한다. read-only이므로
`rw`와 request `data`는 context에 저장하지 않는다.

총 response data 저장량은 모든 WLOAD 설정에서 한 tile인 4096bit이고,
그 외 metadata만 outstanding 수만큼 추가된다.

### 4. Request accept와 issue FIFO

두 개의 depth-`OUTSTANDING` circular FIFO를 둔다.

- `issue_fifo`: 아직 모든 대상 bank로 request를 발행하지 않은 context ID
- `order_fifo`: upstream accept 순서를 보존하는 context ID

각 FIFO는 storage, read pointer, write pointer, occupancy counter를 독립적으로
가진다. pointer 폭은 `max(1, clog2(OUTSTANDING))`로 정의하고 마지막 entry
다음에는 명시적으로 0으로 wrap한다.

`bus_in_if.req_ready`는 request payload와 무관하게 다음 두 capacity 조건을
모두 만족할 때만 1이다.

```text
order FIFO에 빈 entry가 있음
issue FIFO에 빈 entry가 있음
```

`req_valid && req_ready`인 accept 시점에 request가 read인지와 incoming
tag가 가리키는 context가 free인지 assertion으로 검사한다. 정상 DMA
contract에서는 두 조건이 항상 참이다. `req_valid=0`일 때 X일 수 있는
tag/rw가 `req_ready`로 전파되지 않도록 payload를 ready 생성에 사용하지
않는다.

Full 상태에서 response pop과 새 request accept를 같은 클럭에 처리하는
fall-through 최적화는 이번 범위에 넣지 않는다. 먼저 pop된 다음 클럭에
`req_ready`를 다시 올려 동시 free/allocate 우선순위 문제를 피한다. Tile
시작 시 필요한 모든 context가 비어 있으므로 WLOAD8의 4-cycle 연속 accept
목표에는 영향이 없다.

Accept handshake 시 context metadata를 기록하고 같은 context ID를 두 FIFO
tail에 push한다. 다음 클럭부터 `issue_fifo` head 하나가 선택한 bank
group을 소유한다. 대상 bank별 동작은 다음과 같다.

```text
req_valid[b] = head_valid
            && ctx_bank_mask[head][b]
            && !ctx_issued[head][b]
```

Handshake한 bank bit만 `ctx_issued`에 set한다. 모든 대상 bank bit가 set된
클럭에 `issue_fifo`만 pop하고 context는 response retire까지 유지한다.
따라서 일부 bank의 `req_ready`가 낮아도 이미 handshake한 bank에는
request를 재발행하지 않는다. 한 context를 issue하는 동안 다른 context가
bank를 우회 발행하는 기능은 이번 범위에 넣지 않는다.

기존 주소 디코딩은 그대로 유지한다. WLOAD8에서는 시작 bank가 항상
`group_sel * 2`이므로 `{0,1}`, `{2,3}`, `{4,5}`, `{6,7}`만 가능하며
`{1,2}` 같은 비정렬 group은 만들지 않는다.

### 5. Bank response 수집과 in-order retire

각 bank의 response tag에서 `bank_id`, `original_tag`, `ctx_id`를 조합
디코딩한다. `rsp_ready[b]`는 다음 조건에서만 올라간다.

```text
decoded bank_id == b
context가 valid임
stored original tag == decoded original tag
해당 bank가 context의 target이고 request handshake가 끝났음
해당 bank response를 아직 받지 않았음
```

한 클럭에 여러 bank response가 들어올 수 있으므로 response update는
하나의 next-state 조합 블록에서 모든 bank의 handshake를 먼저 merge한 뒤,
하나의 sequential block에서 context 배열에 기록한다. 서로 다른 context
또는 같은 context의 서로 다른 lane에 대한 동시 update를 모두 보존하고,
동일 `(context, lane)`에 둘 이상의 response가 기록되는 경우 assertion으로
실패시킨다.

모든 target bank response가 수집된 context를 complete로 본다.
`order_fifo` head context가 complete일 때만 upstream `rsp_valid`를 올리고,
data/tag는 head context에서 직접 선택한다. `rsp_valid && !rsp_ready` 동안
complete context를 수정하지 않으므로 data와 tag가 안정적으로 유지된다.
Upstream response handshake 시에만 해당 context를 clear하고
`order_fifo`를 pop한다. 뒤 context가 먼저 complete되어도 retire 순서는
바뀌지 않는다.

### 6. 정적 검사와 simulation assertion

`VX_tmem_wide_read_switch` 자체에 다음 generic 검사를 둔다.

```text
OUTSTANDING > 0
OUTSTANDING is power of two
TAG_WIDTH - UP(UUID_WIDTH) >= CTX_BITS_CAP
BANKS_PER_BEAT is power of two and divides NUM_BANKS
```

`VX_tmem_subsystem`에는 weight 구성에 대한 다음 검사를 추가한다.

```text
MXU_ROW % MXU_WLOAD_NUM == 0
MXU_WLOAD_NUM * W_RD_OUTSTANDING == MXU_ROW
W_RD_OUTSTANDING == NUM_BANKS / BANKS_PER_BEAT
```

Simulation assertion은 duplicate context allocation, FIFO overflow/underflow,
write request, 잘못된 bank/tag/context response, response 중복, 미발행 bank의
response, response retire 전 context clear를 검출한다. Assertion은
`ifndef SYNTHESIS` 아래에 두고 합성 datapath에는 영향을 주지 않는다.

### 7. RTL 수정 순서

1. `VX_config.vh`의 weight default 정의를 MXU 설정 뒤로 이동하고 파생식을
   적용한다.
2. `VX_tmem_wide_read_switch`에 `OUTSTANDING`과 정적 검사를 추가한다.
3. 단일 context를 context array, issue FIFO, order FIFO로 교체한다.
4. tag 기반 bank response decode와 next-state merge를 구현한다.
5. `VX_tmem_subsystem`에서 동일한 weight outstanding을 switch에 전달하고
   구성 관계를 검사한다.
6. focused unittest를 multi-outstanding scoreboard 방식으로 변경한다.
7. focused test가 통과한 뒤에만 통합 xrt-vcs 검증으로 진행한다.

### 8. Focused unittest 확장

`hw/unittest/tmem_wide_read_switch/tb_VX_tmem_wide_read_switch.sv`를 다음
시나리오로 확장한다.

1. WLOAD4/8/16/32 각각에서 계산된 outstanding 수만큼 request를 매
   클럭 연속 accept한다.
2. WLOAD8에서 네 request가 bank mask `03`, `0c`, `30`, `c0`으로
   순차 issue되는지 확인한다.
3. bank request ready를 개별 stall시켜 partial acceptance와 중복 방지를
   확인한다.
4. response를 순서대로, 역순으로, 임의 skew로 반환한다.
5. 여러 context의 bank response가 같은 클럭에 도착하는 경우를 검사한다.
6. upstream response backpressure 중 data/tag가 안정적인지 확인한다.
7. 모든 context가 찼을 때만 `req_ready`가 내려가고 response pop 후 다시
   올라오는지 확인한다.
8. tag 재사용, duplicate response, unexpected bank response assertion을
   negative test로 확인한다.

기존의 “첫 request 후 두 번째 request는 거절해야 한다” 검사는 제거하고
“OUTSTANDING개까지 연속 accept, 그 이상은 backpressure” 검사로 바꾼다.

### 9. 통합 검증

저장소 지침에 따라 configure된 build directory에서 적절한 `configs/`
설정을 source한 뒤 실행한다.

- `tmem_wide_read_switch` focused VCS unittest
- `gemm_node_improve` 및 관련 local-DMA/GEMM unittest
- 기존 FSDB를 만든 동일 workload의 `ci/run_black.sh xrt-vcs-sim`
- 필요 시 `FSDB_DUMP=1` 재실행 후 `tools/fsdb_cli`로 전후 비교
- `ci/run_target_gemm.sh run --wload 8 --m 4 --k 256 --n 256` 로 test
- `ci/run_target_gemm.sh run --wload 8 --m 256 --k 256 --n 256`로 test

현재 WLOAD8 설정의 파형 acceptance 기준은 다음과 같다.

- 한 weight DMA의 source request 네 개가 4클럭 간격이 아니라 연속
  4클럭에 accept될 것
- 충분한 bank/GEMM ready 조건에서 `gemm_unit_v2` weight request도
  고정 latency 후 연속 4클럭에 전달될 것
- weight request 총수 256은 유지될 것
- 기존 576클럭의 switch-induced source request stall이 제거될 것
- destination write stall 0과 수치 결과가 유지될 것

### 10. 변경 파일 scope

RTL과 module 문서의 직접 수정 범위는 다음 파일로 제한한다.

| 파일 | 확정 변경 내용 |
|---|---|
| `hw/rtl/VX_config.vh` | weight outstanding 정의를 MXU 설정 뒤로 이동하고 `MXU_ROW / MXU_WLOAD_NUM` 기본값 적용 |
| `hw/rtl/mem/VX_tmem_wide_read_switch.sv` | `OUTSTANDING` parameter, context array, issue/order FIFO, tag 기반 response 수집, assertion 구현 |
| `hw/rtl/mem/VX_tmem_subsystem.sv` | `W_RD_OUTSTANDING`을 weight switch에 전달하고 tile/bank-group 관계 정적 검사 추가 |
| `docs/rtl/VX_tmem_subsystem.md` | 정렬된 weight bank-group mapping, derived outstanding, in-order response 동작 문서화 |

이 계획 문서는 설계 및 검증 결과를 기록하면서 함께 갱신한다.

검증만을 위한 다음 파일은 **기본 변경 scope에 포함한다**.

- `hw/unittest/tmem_wide_read_switch/**`
  - `tb_*.sv`
  - unittest `Makefile`
  - simulator별 `*.mk`
  - test 실행과 expected-failure 선택에 필요한 검증 전용 script
- configure가 생성한 `build/hw/unittest/tmem_wide_read_switch/**` 복사본과
  log/report 같은 검증 artifact
- `agent-tasks/tmem-weight-multi-outstanding/**`의 spec과 상태 기록

검증용 파일은 stimulus, scoreboard, simulator argument 전달, test 실행과
result 판정만 바꿀 수 있다. Product RTL parameter나 workload 의미를
우회해서 결과를 맞추는 용도로 사용하지 않는다.

다음 파일은 **수정하지 않는다**.

- `hw/rtl/core/VX_dma_unit_align.sv`: 기존 slot tag 생성/회수 contract 사용
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`: 기존 `RD_OUTSTANDING` 전달 구조 사용
- `hw/rtl/core/gemm/VX_gemm_node.sv`: subsystem 기본 parameter 사용
- `hw/rtl/mem/VX_tmem_switch.sv`: input/scale-zero/output 경로 변경 없음
- `configs/*.sh`: weight outstanding 값을 config별로 하드코딩하지 않음
- application/runtime workload source인 `main.cpp`, `kernel.cpp` 및 이에
  준하는 host application/kernel 구현 파일

## Hard rule

이 section은 권고가 아니라 구현 중단 조건이다. 다음 중 하나라도 발견되면
계획 밖의 우회 수정이나 추가 RTL 변경을 하지 말고 즉시 작업을 멈춘다.

- DMA request의 `tag.value` 하위 비트가 unique live slot ID라는 전제가
  실제 경로 또는 설정에서 성립하지 않는다.
- context ID를 전달하기 위해 bank tag 폭, TMEM bank interface 또는 bank
  arbiter를 변경해야 한다.
- 정렬된 bank-group mapping을 유지하면서 목표 outstanding을 구현할 수
  없거나 `{1,2}` 같은 비정렬 bank 조합이 발생한다.
- 여러 bank response의 동시 context update가 lint/elaboration에서
  multi-driver/multi-write 구조가 된다.
- in-order retire, upstream backpressure 안정성, partial bank acceptance 중
  하나라도 context 재사용 또는 데이터 오염 없이 만족시킬 수 없다.
- `WLOAD_NUM * OUTSTANDING = MXU_ROW` 또는
  `OUTSTANDING = NUM_BANK_GROUPS` 관계를 완화해야만 compile/elaboration이
  가능하다.
- 위 RTL/module 문서와 검증 전용 scope 밖의 RTL/config/인터페이스 또는
  application/kernel source 수정이 필요하다.
- focused unittest에서 tag/data 손실, duplicate request/response, X 전파,
  timeout이 발생하고 원인이 계획한 구조 자체에 있다.
- 통합 검증에서 기존 GEMM 수치 결과나 비-weight 경로의 동작이 바뀐다.

중단 시 다음 내용을 바로 report한다.

1. 실패한 명령 또는 관측 시나리오와 최소 재현 방법
2. 위반된 설계 전제 또는 hard rule 항목
3. 로그, assertion, waveform signal과 cycle을 포함한 근거
4. 영향을 받는 파일과 현재까지 통과한 검증
5. 가능한 설계 대안과 각각의 scope/성능/면적 영향

Report 전에는 hard rule을 완화하거나, assertion을 제거하거나, config에
예외 값을 하드코딩하거나, 다른 DMA/TMEM 경로까지 수정해서 문제를 숨기지
않는다. 사용자와 설계 변경 방향을 합의한 뒤에만 구현을 재개한다.

## 완료 조건

- `MXU_WLOAD_NUM * W_RD_OUTSTANDING == MXU_ROW`가 elaboration에서 강제된다.
- 현재 WLOAD8 설정의 weight outstanding이 4로 elaboration된다.
- WLOAD4/8/16/32 focused unittest가 모두 통과한다.
- WLOAD8에서 네 source request와 네 GEMM weight request가 각각 연속
  클럭으로 관측된다.
- bank response skew와 upstream backpressure에서 data/tag 손실, 중복,
  오염이 없다.
- 기존 GEMM 수치 결과와 weight fire count가 유지된다.
- xrt-vcs-sim에서 fatal, X propagation, timeout이 없다.
- protocol violation negative test가 각각 의도한 assertion에서 실패한다.
- RTL 변경 전후 성능 counter와 FSDB request 간격 비교가 기록된다.

## 수행 결과

구현과 계획된 검증을 완료했다. 사용자 지시에 따라 synthesis QoR은
실행하지 않았다.

### 구현 결과

- `W_LMEM_DMA_RD_OUTSTANDING_SLOTS` 기본값을
  `MXU_ROW / MXU_WLOAD_NUM`으로 변경했다.
- WLOAD4/8/16/32에서 outstanding은 각각 8/4/2/1이다.
- Weight wide switch는 DMA slot tag 기반 context array, issue FIFO,
  accept-order FIFO로 동작한다.
- WLOAD8의 정렬된 bank pair `03/0c/30/c0` mapping과 in-order upstream
  response를 유지한다.
- 검증 전용 `vcs.mk`가 `EXTRA_SIM_ARGS`를 simv에 전달하도록 변경했다.
- `main.cpp`, `kernel.cpp` 또는 이에 준하는 application/kernel source는
  변경하지 않았다.

### 검증 결과

| 검증 | 결과 |
|---|---|
| Focused VCS WLOAD4/8/16/32 | PASS, outstanding 8/4/2/1 |
| `lmem_dma_misal`, outstanding 4 + reordered response/backpressure | PASS |
| `gemm_node_improve`, M4/N256/K256/Q32 WLOAD8 | PASS, 1024 outputs compared |
| xrt-vcs-sim M4/N256/K256 | PASS, weight fire=256, stall=0 |
| xrt-vcs-sim M256/N256/K256 | PASS, weight fire=512, stall=0 |
| FSDB WLOAD8 M4/N256/K256 | PASS |

Negative test는 모두 `tools/verify_rtl.py`를 통해 독립 실행했으며 다음 첫
fatal을 확인했다.

| Mode | 확인한 fatal |
|---|---|
| `write` | `wide switch received a write request` |
| `duplicate_context` | `duplicate live context allocation` |
| `free_context_response` | `response for free context` |
| `unissued_response` | `response from unissued bank` |
| `duplicate_response` | `duplicate bank response` |

### FSDB 전후 비교

기존 single-outstanding FSDB에서 첫 네 source accept는
57.105/57.145/57.185/57.225 us로 4클럭 간격이었다. 변경 후 첫 네 accept는
57.435/57.445/57.455/57.465 us로 매 클럭 연속 발생했고 mask는 각각
`03/0c/30/c0`이었다. 첫 GEMM weight fire도 57.485 us부터 4클럭 연속으로
발생했다.

변경 후 전체 waveform count는 다음과 같다.

```text
wide accept             = 256
source request fire     = 256
source request stall    = 0
narrow bank request fire= 512
GEMM weight fire        = 256
wide response retire    = 256
```

FSDB artifact:
`build/run_logs/target_gemm/20260808-220112_fsdb-gemm_wload8_m4_n256_k256_q32_t0_d1_pid3900783/target_gemm.fsdb`

## 범위 제외

- input, scale/zero, output TMEM switch의 multi-outstanding 변경
- HBM DMA outstanding 정책 변경
- GEMM compute pipeline 또는 `wreg_busy` 정책 변경
- weight command scheduling 자체의 overlap 확대
- WLOAD4/8/16/32 이외의 비 power-of-two WLOAD 지원
- synthesis QoR 측정 또는 QoR 결과에 따른 구조 변경
- host application과 kernel workload의 `main.cpp`, `kernel.cpp` 변경

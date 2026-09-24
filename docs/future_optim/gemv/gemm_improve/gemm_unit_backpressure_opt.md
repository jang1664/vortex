# 문제점

현재 `VX_gemm_unit_v2`는 Input admission부터 ACC memory write까지 대부분을
fixed-latency pipeline으로 취급한다. Data path의 여러 module에 ready port가 있거나
내부적으로 elastic buffer를 사용하지만, GEMM unit에서는 ready를 연결하지 않고
`ready_out=1`로 묶거나 `ready_in`을 무시한다. `ctrl_pipe`와 qparam snapshot pipe도
매 cycle 무조건 이동한다.

따라서 중간 stage가 기다려야 하는 경우 data만 멈출 수 없다. Data를 멈추고
control을 계속 이동시키면 QDIR, W/S/Z bank index, ACC address, `last`, forwarding
metadata가 서로 어긋난다. 반대로 전체 pipeline을 한꺼번에 멈추면 이미
post-process에 들어간 transaction과 ACC response까지 불필요하게 정지한다.

현재 Input admission은 W/S/Z LOAD completion을 GEMM unit 밖에서 먼저 확인한다.
이 방식에서는 Input이 GEMM unit에 들어온 뒤 GEMM tree에 도달하기까지의 latency를
다음 Weight를 준비하는 시간으로 활용하지 못한다. Weight의 lifetime은 마지막 Input이
실제로 GEMM tree에서 Weight를 읽을 때까지 이어지므로, 현재는 이 latency를 숨기기 위해
WREG를 4 group으로 늘렸다. 그러나 근본 원인은 WREG 수가 아니라 GEMM unit 내부에
operand-aware backpressure가 없다는 점이다.

## 긴 combinational ready path

Input부터 ACC memory까지 ready를 단순히 combinational하게 연결하면 다음 경로가 생긴다.

```text
ACC memory / post-process ready
  -> GEMM tree
  -> pre-process
  -> i_lmem_bus.req_ready
```

GEMM tree는 datapath가 크고 pipeline latency도 길기 때문에 이 경로를 그대로 통과시키면
timing-critical combinational path가 된다. 또한 현재 `VX_gemm_tree_v1`은 Input ready를
받아 내부 pipeline을 멈추는 구조가 아니다. GEMM tree 내부까지 ready를 추가하는 것은
이번 계획의 범위가 아니다.

## Ready feedback 1-cycle 지연과 Tree output buffering

GEMM tree를 backpressure하지 않고 post-process ready를 FF로 한 번 받아 pre-process에
전달하면, ready가 내려간 사실을 pre-process가 알기 전에 한 transaction을 추가로
GEMM tree에 넣을 수 있다. 여기에 ready가 내려간 시점에 이미 GEMM tree 내부에 있던
모든 transaction도 계속 출력된다는 점을 포함해야 한다.

현재 target configuration은 다음과 같다.

```text
MXU_ROW               = 32
MXU_COL               = 32
MXU_COL_TILE          = 32
MXU_PIPE_MUL_EN       = 1
MXU_PIPE_ALIGN_EN     = 1
MXU_PIPE_ADD_INTV     = 2
Tree initiation rate  = 1 transaction/cycle
```

논리적인 GEMM tree latency는 현재 RTL의 `MXU_OUT_DLY`와 같다.

```text
L_tree
  = MXU_PIPE_MUL_EN
  + MXU_PIPE_ALIGN_EN
  + output register
  + get_pipe_stage_num(MXU_ROW, MXU_PIPE_ADD_INTV)
  + (MXU_COL / MXU_COL_TILE - 1)
  = 1 + 1 + 1 + 2 + 0
  = 5 cycles
```

Ready feedback latency가 1 cycle이고 최대 입력률이 1 transaction/cycle이므로,
post-process가 임의의 cycle에 멈췄을 때 보존해야 하는 최대 결과 수는 다음과 같다.

```text
D_min = input_rate * (L_tree + L_ready_feedback)
      = 1 * (5 + 1)
      = 6 transactions
```

따라서 FIFO depth 1은 충분하지 않다. Depth 1로 arbitrary backpressure를 안전하게
지원하려면 tree에 동시에 하나의 transaction만 허용해야 하므로 initiation interval이
최소 tree latency만큼 늘어난다. Full throughput과 arbitrary post-process stall을 모두
지원하려면 현재 설정에서는 최소 6개의 보장된 결과 저장 공간이 필요하다.

GEMM tree와 병렬로 실행되는 ZP multiplication/activation sum 경로도 현재 5-cycle로
정렬되어 있다.

```text
QCOL correction = act_sum 2 + zp_mul register 1 + alignment 2 = 5 cycles
QROW correction = zp_mul register 1 + act_sum 2 + alignment 2 = 5 cycles
```

두 경로는 하나의 `compute_fire`에서 동시에 시작하고 같은 cycle에 끝나므로 별도의
depth-6 FIFO를 두 개 만들지 않는다. GEMM tree 결과와 correction 결과를 combinational
merge한 뒤, merged transaction 하나를 depth-6 FIFO에 저장한다. FIFO entry에는 merged
data뿐 아니라 `max_exp`, QDIR, QCOL Scale bank/version, ACC address, `last`, forwarding
정보 등 post-process에서 필요한 metadata를 함께 저장한다. Scale/ZP value 자체는
FIFO entry에 넣지 않는다.

기존 depth-1 merger output register를 그대로 두고 그 뒤에 FIFO를 추가하면 fixed
latency가 6 cycle이 되어 최소 FIFO depth가 7로 증가한다. 따라서 기존 merger output
register를 제거하고 **그 위치를 depth-6 merged-result FIFO로 대체**한다. Depth 6을
지원하지 않는 기존 FIFO primitive를 재사용하지 말고, 필요하면 modulo-6 pointer를
갖는 전용 FIFO를 구현한다.

# 해결책

## 세 개의 pipeline region

GEMM unit을 다음 세 region으로 나눈다.

```text
I-LDMA
  -> [Pre-process: elastic ready/valid]
  -> [GEMM tree || ZP/act-sum: fixed-latency, no ready propagation]
  -> [Combinational merge]
  -> [Depth-6 merged-result FIFO]
  -> [Post-process: elastic ready/valid]
  -> ACC memory commit
```

### Pre-process region

Input pipe, QROW input scaler, QCOL alignment, prealigner 및 common compute fork
직전까지를 포함한다. Region 내부에서는 ready를 combinational하게 역전파한다.
모든 data와 metadata는 동일 handshake에서만 이동한다.

### GEMM tree region

GEMM tree 내부에는 ready를 추가하지 않는다. 이 region에는 GEMM tree와 병렬
ZP multiplication/activation sum correction path를 함께 포함한다. 두 경로는 하나의
`compute_fire`를 사용하며 각각 정확히 5 cycle 뒤에 결과를 만든다.

```text
compute_fire
  -> GEMM tree result ---------+
                               +-> combinational merge -> depth-6 FIFO
  -> ZP/act-sum correction ----+
```

GEMM tree valid와 correction valid는 항상 같아야 한다. 두 valid가 다른 경우 FIFO에서
기다려 맞추지 않고 pipeline alignment 오류로 처리한다. `compute_fire`마다 merged-result
FIFO entry 하나를 미리 예약한다.

### Post-process region

Depth-6 merged-result FIFO의 output부터 integer-to-FP conversion, QCOL output scaling,
ACC read/add/write 및 ACC memory commit까지 포함한다. Region 내부에서는 ready를
combinational하게 역전파한다. `last_write`와 Input의 architectural writeback completion은
최종 ACC write의 `valid && ready`에서만 발생한다.

## Tree boundary credit와 registered ready

Post-process ready 자체를 단순히 한 cycle 늦춰 사용하는 대신, FIFO capacity를
포함하는 credit을 pre-process launch 조건으로 사용한다.

```text
tree_credit 초기값 = MERGED_RESULT_FIFO_DEPTH

compute_fire               -> credit - 1
merged-result FIFO pop     -> registered credit return(+1)
credit가 남아 있을 때만   -> 다음 compute_fire 허용
```

Tree 내부에 있는 transaction과 FIFO에 저장된 transaction은 이미 credit을 소비한
상태다. 두 fixed-latency branch의 output을 merge하여 FIFO로 이동할 때는 ownership만
이동하고 credit 수는 바뀌지 않는다. FIFO에서 post-process로 실제 handshake될 때
반환한 credit을 FF로 한 번 등록하여 pre-process에 전달한다. 이 구조는
post-process에서 pre-process까지의
combinational ready path를 제거하면서 FIFO overflow를 방지한다.

현재 설정에서는 다음 parameter를 기본값으로 한다.

```text
TREE_PIPELINE_CAPACITY      = MXU_OUT_DLY = 5
READY_FEEDBACK_LATENCY      = 1
MERGED_RESULT_FIFO_DEPTH    = 6
```

Assertion으로 다음 invariant를 항상 검사한다.

```text
0 <= credit <= FIFO_DEPTH
tree_inflight + fifo_occupancy <= FIFO_DEPTH
compute_fire가 발생하면 반드시 예약된 output slot이 존재
두 branch의 aligned output valid가 발생하면 반드시 merged FIFO push가 가능
```

## 1단계: 순수 GEMM-unit backpressure 구현

첫 번째 단계에서는 Weight/Scale/Zero-point LOAD latency와 dependency 위치를
최적화하지 않는다. 기존 W/S/Z readiness와 register 구성을 유지하고, operand가
항상 준비된 조건에서 다음 항목만 구현한다.

현재 Scale/ZP snapshot pipeline은 Phase 1의 backpressure 검증 동안에만 임시로
유지한다. 이는 backpressure 변경과 operand lifetime 변경을 한 번에 섞지 않기
위함이며 최종 구조가 아니다. Phase-1 unittest가 통과하면 Phase 2에서 snapshot
value pipeline을 제거한다.

- Pre-process의 모든 pipeline stage를 elastic ready/valid로 변환
- Post-process의 모든 pipeline stage를 elastic ready/valid로 변환
- Data와 `gemm_input_ctrl_t`, 기존 qparam snapshot, exponent, block index, ACC
  metadata를 동일 transaction으로 이동
- GEMM tree와 ZP/act-sum correction launch를 하나의 `compute_fire`로 통일
- 두 5-cycle branch의 output-valid equality assertion 추가
- Combinational merge 뒤 기존 merger register를 depth-6 merged-result FIFO로 대체
- Merged-result FIFO와 registered credit feedback 추가
- 기존 ACC immediate/history forwarding과 early/nominal SRAM read scheduling 유지
- ACC read request는 대응 transaction의 read-stage handshake에서만 발행하고, 이미
  발행된 response는 기존 hold state가 accumulator handshake할 때까지 유지
- ACC response, forwarding data 및 compute result의 기존 선택 우선순위를 유지한 채
  valid/ready handshake로 결합
- `pipeline_empty`에 pre-process, tree inflight, result FIFO, post-process의 모든
  valid state를 포함

기존 fixed index 기반 `ctrl_pipe`를 data와 독립적으로 계속 shift하지 않는다.
각 region의 metadata는 대응하는 transaction handshake에서만 이동한다. Fixed-latency가
필요한 GEMM tree 내부 구간만 valid shift를 유지하고, tree 입출력에서 metadata를
명시적으로 맞춘다.

이 단계의 성공 조건은 성능 개선이 아니다. 임의의 backpressure에서도 data loss,
duplicate, reorder, metadata misalignment 및 FIFO overflow 없이 동일한 수치 결과가
나오는 것이 목표다.

### ACC forwarding 보존

ACC datapath의 hazard 처리 방식은 변경하지 않는다. 현재 선택 우선순위를 그대로
유지한다.

```text
1. immediate forwarding       : 같은 cycle의 writeback_result_data
2. history forwarding         : writeback_history_data
3. one-cycle-early read hold  : early_hold_data
4. nominal SRAM response      : acc_mem_out_data
```

새로운 reservation-based ACC scheduler로 교체하지 않는다. `forward_pipe`,
`history_forward_pipe`, `early_pipe`, `early_rsp_pending`, `early_hold_valid/data`가
표현하는 의미도 유지한다. 다만 post-process가 stall할 수 있으므로 다음 handshake
조건을 추가한다.

- ACC read-stage transaction이 실제 fire할 때만 early/nominal read request 발행
- 이미 발행된 early response의 `early_hold_valid/data`는 대응 accumulator input이
  fire할 때까지 유지하고 stall 중에 pulse처럼 자동 소거하지 않음
- Nominal response를 소비할 stage가 stall하면 같은 bank의 다음 memory access로
  response가 덮이지 않도록 해당 read stage의 ready를 내림
- Forwarding/history/early 판정 metadata는 대응 transaction과 함께 elastic하게 이동
- ACC add 결과와 address/control이 모두 ready일 때만 final ACC write fire 발생

즉 "response 저장 공간"은 새로운 FIFO나 별도 scheduling concept이 아니라, 이미
존재하는 ACC response/early-hold state가 현재 transaction에 의해 점유 중인지 나타낸다.
Backpressure는 이 state가 덮이지 않도록 다음 read request를 멈추는 용도로만 사용한다.

## 2단계: W/S/Z load-ready와 consumer stage 결합

Backpressure가 검증된 뒤 W/S/Z LOAD completion dependency를 GEMM unit 내부의 실제
consumer 직전으로 이동한다. Input transaction에는 다음 metadata를 함께 전달한다.

```text
W:  bank index + expected LOAD target/version
S:  bank index + expected LOAD target/version
ZP: bank index + expected LOAD target/version
```

단순한 `loaded[bank]` bit는 사용하지 않는다. 동일 physical bank가 반복 재사용되므로
현재 LOAD completion counter가 transaction의 exact target과 일치하는지 비교해야 한다.
`>=` 비교는 counter wraparound와 stale/미래 generation을 구분하지 못하므로 사용하지 않는다.
Load completion level은 consumer가 register write와 같은 edge에서 새 값을 읽지 않도록
registered view를 사용한다.

Resource별 consumer gate는 다음 위치에 둔다.

- Weight: common compute fork에서 GEMM tree로 들어가기 직전
- QROW Scale: input scaler 입력 직전
- QCOL Scale: output scaler 입력 직전
- QROW Zero-point: common compute fork의 QROW ZP multiplication 입력
- QCOL Zero-point: readiness는 common compute fork에서 확인하고, 실제 register read는
  QCOL activation-reduce 결과의 ZP multiplication stage에서 수행

GEMM tree와 ZP/act-sum correction path는 `compute_fire` 이후에는 stall할 수 없는
하나의 fixed-latency island다. 따라서 QCOL ZP readiness를 correction path 내부에서
늦게 검사하여 island를 stall시키지 않는다. 두 QDIR 모두 common fork에서 exact ZP
version이 준비됐는지 먼저 확인한다. Weight와 ZP가 모두 준비되고 merged FIFO credit이
있을 때만 하나의 `compute_fire`로 두 branch를 동시에 시작한다.

QCOL에서는 ZP value가 아니라 `zreg_idx`와 expected version metadata만 act-sum latency에
맞춰 이동한다. ZP register는 실제 multiply stage에서 직접 읽는다. Common fork부터
실제 QCOL ZP read까지는 해당 bank의 consume이 아직 발생하지 않았으므로 writer fence가
같은 ZREG의 overwrite를 차단한다.

각 stage에서 `valid=1`인데 exact W/S/Z version이 준비되지 않았으면 해당 stage의
ready를 0으로 내린다. 준비된 경우에만 `valid && ready`로 resource를 읽는다.

최종 구조에서는 Weight뿐 아니라 Scale/ZP value도 pipeline에 복사하지 않는다.
Input transaction에는 bank index와 exact LOAD target/version metadata만 전달한다.
각 consumer는 handshake cycle에 선택된 WREG/SREG/ZREG를 직접 읽는다. 따라서 원본
register의 lifetime은 snapshot 시점이 아니라 실제 resource read가 끝나는 consume
event까지 유지된다.

W/S/Z 모두 마지막 old-version consumer가 register 값을 읽는 cycle에 다음 generation의
write를 허용할 수 있다. Consumer의 combinational read 값은 clock edge에서 downstream
stage가 capture하고, writer의 nonblocking register update는 같은 edge 뒤에 반영되므로
old-read/new-write handoff가 가능하다. 단, 같은 bank를 아직 읽지 않은 더 이른
transaction이 없어야 한다.

단, 다음 generation Weight를 기다리던 Input은 그 Weight의 마지막 register write와
같은 edge에 tree로 들어가면 안 된다. Writer의 actual write completion이 register된
다음 cycle부터 새 version을 ready로 본다.

Consume event는 실제 consumer handshake에서 발생시킨다.

```text
W consume  = last Input의 compute_fire
S consume  = last Input의 QDIR별 Scale consumer fire
ZP consume = last Input의 QDIR별 ZP register-read fire
```

QROW와 QCOL의 마지막 consumer가 같은 cycle에 같은 종류의 단일 consume event port를
요구할 수 있다. 이 경우 QCOL의 이미 진행 중인 transaction을 우선 retire하고 QROW
consumer를 한 cycle stall한다. Non-final direct read는 동시에 허용한다. Future-version을
기다리는 transaction은 bank ownership을 획득하지 않으며, 실제 read lifetime만 writer
overwrite를 막는다.

W/S/Z LOAD command의 source read overlap과 slot buffering은 유지한다. Destination
register write는 해당 physical bank의 consume target이 만족된 뒤에만 허용하고,
LOAD command completion은 마지막 actual register write에서 발생시킨다.

## 2-group double buffering

Operand-aware backpressure가 동작한 뒤 W/S/Z를 모두 독립적인 2-group double
buffering으로 정리한다.

- WREG: 4 group에서 2 group으로 축소
- SREG: 2 group 유지
- ZREG: 2 group 유지
- W/S/Z bank pointer는 서로 독립적인 1-bit pointer로 유지
- Input metadata가 각 resource의 bank와 version을 독립적으로 지정
- W2/W3 storage, selector, LOAD/consume routing 및 사용하지 않는 assertion 제거

M=4에서 이상적인 동작은 다음과 같다.

```text
Tree C0-C3    : Input command N, W0 사용
Tree C4-C7    : Input command N+1, W1 사용
               동시에 다음 W0 generation write
Tree C8-C11   : Input command N+2, 새 W0 사용
```

GEMM unit frontend는 새 W0가 준비되기 전에도 N+2 Input을 받을 수 있고, transaction은
Weight consumer stage에서만 기다린다. 따라서 GEMM-unit-to-tree latency를 Weight load
시간을 숨기는 window로 사용할 수 있다.

다만 backpressure는 correctness와 buffering을 제공할 뿐 Weight bandwidth를 새로
만들지는 않는다. W0 overwrite가 W1 사용 window 안에 완료되지 않으면 tree에서
bubble이 생긴다. Phase 2 성능 검증에서는 기존 Weight command overlap과 8 response
slot이 이 조건을 만족하는지 별도로 확인한다.

# 구현 계획

## 1. Region transaction과 handshake contract 정의

- Pre-process, common compute fork, merged-result FIFO, post-process transaction payload를 명시
- Data와 control/sideband가 항상 같은 handshake에서 이동하도록 packed metadata 정의
- `valid && !ready` 동안 payload 안정성 규칙 정의
- 각 stage의 accept/fire와 completion endpoint 정의

## 2. Tree latency와 output credit parameter화

- `TREE_PIPELINE_CAPACITY`를 GEMM tree와 correction path의 공통 logical latency에서 계산
- 두 branch latency가 모두 5인지 static assertion 추가
- `MERGED_RESULT_FIFO_DEPTH >= TREE_PIPELINE_CAPACITY + 1` static assertion 추가
- Modulo-6 pointer를 포함하여 정확한 depth-6 FIFO 구현
- Compute fire, branch output arrival, merge, FIFO push/pop 및 registered credit-return counter 구현

## 3. Pre-process elastic 변환

- 기존에 무시하던 `VX_pipe_buffer`와 prealigner ready 연결
- QROW input scaler의 모든 lane이 하나의 transaction으로 accept되도록 collective ready 구성
- ready port가 외부로 노출되지 않은 reduction/conversion module은 ready를 추가하거나
  입력 credit과 output holding buffer로 감쌈
- Pre-process data, qparam snapshot 및 control metadata를 lockstep으로 이동

Phase 1의 qparam snapshot 이동은 backpressure 검증을 위한 임시 호환 경로다. Phase 2에서
snapshot value pipeline을 제거하므로 이 경로를 최종 datapath로 최적화하지 않는다.

## 4. Compute join과 Post-process elastic 변환

- GEMM tree와 ZP/act-sum correction을 combinational merge하고 기존 merger register 제거
- Merged data, max-exp 및 control metadata를 하나의 depth-6 FIFO entry로 저장
- GEMM-tree/correction valid equality와 FIFO reserved-slot assertion 추가
- Merged-result FIFO output부터 ACC commit까지 ready를 combinational하게 연결
- Int-to-FP는 initiation interval 1, 고정 latency 2이며 output ready가 없으므로, QCOL
  Scale stall을 흡수하는 depth-2 elastic result FIFO와 예약 credit을 output scaler 앞에 배치
- 두 cycle 연속 launch 뒤 arbitrary QCOL Scale stall이 시작되어도 두 in-flight result가
  모두 저장되는지 credit/count invariant로 검사
- Int-to-FP, output scaler, ACC read/add/write의 valid/data/control을 lockstep 처리
- 기존 immediate/history/early/nominal ACC forwarding 선택과 우선순위 유지
- 기존 forwarding metadata를 대응 transaction과 함께 elastic stage로 전달
- Read-stage fire에만 SRAM request를 발행하고 기존 early/response hold state를
  accumulator-stage fire까지 유지
- Stall 중 같은 bank의 후속 access가 보존 중인 response를 덮지 않도록 ready로 차단
- 최종 `acc_write_fire`에서만 writeback completion 발생

## 5. Phase-1 unittest 완료

- W/S/Z load/use timing은 변경하지 않은 상태에서 backpressure correctness를 먼저 확정
- Phase-1 unittest가 통과하기 전에는 WREG 2-bank 축소와 consumer-ready 이동을 시작하지 않음

## 6. Exact W/S/Z readiness metadata 전달

- Input command의 W/S/Z bank와 LOAD target을 GEMM unit transaction에 포함
- Controller의 registered LOAD completion level을 GEMM unit까지 전달
- QDIR별 실제 consumer 앞에 exact-version compare와 ready gate 추가
- `qrow_scale_snapshot_q`, `qcol_scale_snapshot_pipe`, `qrow_zero_snapshot_pipe`,
  `qcol_zero_snapshot_pipe` value datapath 제거
- Scale/ZP value 대신 bank/version metadata만 해당 consumer까지 전달
- Consumer fire에서 선택된 W/S/Z register를 직접 읽고 consume event 생성

## 7. W/S/Z 2-bank 전환

- Weight storage와 selector를 2-bank로 축소
- FSM의 Weight pointer를 modulo-2 toggle로 변경
- W2/W3 command/RID/interface 경로 제거 또는 명시적으로 비활성화
- Scale/ZP 2-bank와 independent pointer 유지
- Same-cycle final-consume/overwrite 및 next-cycle new-version visibility assertion 추가
- Future-version waiter가 그 generation의 register write를 막지 않는다는 assertion 추가
- QROW/QCOL final consume 충돌 시 실제 retire event만 선택하고 다른 consumer를 stall

## 8. Integration과 성능 확인

- Input/Weight/Scale/ZP overlap executor와 새 consumer gate 연결
- `pipeline_empty`, invocation completion, Input completion 및 debug probe 갱신
- Unit-level correctness가 끝난 뒤에만 Input burst gap과 tree utilization을 FSDB로 측정

# 검증 계획

## 1. Phase-1 `gemm_unit_v2` backpressure unittest

다음 directed case를 QCOL/QROW 모두 실행한다.

- ready가 항상 1일 때 매 cycle Input accept 및 기존 수치 결과 유지
- Post-process ready를 1, 2, 6, 7 cycle 동안 정지
- Tree가 full-rate로 동작하는 중 첫 output cycle에 ready를 내리는 worst-case 시험
- Depth-6 merged-result FIFO가 비어 있지 않은 상태에서 반복적인 stop/resume
- deterministic pattern과 random backpressure
- `valid && !ready` 동안 data/metadata 안정성
- Input accepted count, compute fire count, 두 branch output count, merge/FIFO push/pop count,
  ACC commit count 일치
- GEMM tree valid와 correction valid가 모든 transaction에서 같은 cycle에 발생
- data loss, duplicate, reorder 및 QDIR/control/ACC-address misalignment 없음
- tree inflight/FIFO credit invariant와 overflow/underflow 없음
- Immediate/history/early/nominal ACC forwarding case가 기존과 동일한 source를 선택
- ACC response를 기다리거나 hold한 상태의 stall에서도 response overwrite 없음
- pipeline에 data가 남아 있는 상태의 reset과 stale output 없음

Phase 1에서는 W/S/Z LOAD latency와 Input burst gap을 pass/fail 기준으로 사용하지 않는다.

## 2. Phase-2 operand-ready unittest

- W, S, ZP LOAD completion을 각각 독립적으로 지연
- Input이 해당 resource의 consumer 직전까지 진행한 뒤 정확히 그 stage에서 stall
- 다른 bank 또는 stale generation completion으로 release되지 않음
- exact target completion 뒤 next cycle에 진행
- QROW/QCOL의 서로 다른 Scale/ZP consumer 위치 검증
- 마지막 consumer 전 overwrite 차단, consume cycle의 old-read/new-write 허용
- W/S/Z 각 2-bank alternating sequence와 wraparound 검증
- Scale/ZP value가 pipeline/FIFO payload에 존재하지 않고 bank/version metadata만 이동
- QCOL ZREG가 common fork부터 실제 ZP multiply까지 overwrite되지 않음
- QCOL SREG가 output scaler의 실제 read/consume까지 overwrite되지 않음
- Same-cycle old S/Z read와 next-generation write에도 consumer가 old value를 capture
- LOAD command completion이 final actual register write와 일치

## 3. Node 및 XRT-VCS integration

- `gemm_node_improve`에서 M=4, M=256
- QDIR=QCOL, QROW
- QBLK=32, N=K=256, WTRANS=0, WLOAD=8
- `ci/run_target_gemm.sh`의 xrt-vcs-sim flow로 numerical regression
- 기존 Input/Weight/Scale/ZP overlap executor unittest 재실행

## 4. FSDB 성능 검증

Phase 2까지 통과한 뒤 M=4 QCOL/QROW FSDB에서 다음을 확인한다.

- pre-process accept, compute fire, GEMM-tree/correction output, merge, depth-6 FIFO push/pop,
  ACC commit timeline
- ready feedback이 한 cycle만 등록되고 combinational tree-crossing path가 없음
- FIFO max occupancy가 설정 depth 이하이고 credit invariant 유지
- W/S/Z exact-version stall 원인과 duration
- WREG0/WREG1 alternating load/use/consume/overwrite
- operand가 제때 준비된 경우 tree input과 4-beat Input burst가 back-to-back
- operand가 늦은 경우 loss 없이 해당 consumer stage에서만 stall

# Hard Rule

구현 중 현재 계획의 핵심 구조가 성립하지 않는 문제가 발견되면 즉시 중단하고
문제와 근거를 보고한다. 예를 들어 tree output의 bounded FIFO/credit으로 arbitrary
backpressure를 수용할 수 없거나, ACC memory protocol 때문에 transaction ordering을
보존할 수 없거나, exact W/S/Z version을 consumer까지 전달할 수 없는 경우가 이에
해당한다.

Makefile, bash script, unittest testbench의 명백한 오류, interface drift, simulator
compatibility 수정처럼 설계 concept을 바꾸지 않는 사소한 사항은 중단 사유가 아니며
필요한 범위에서 수정할 수 있다.

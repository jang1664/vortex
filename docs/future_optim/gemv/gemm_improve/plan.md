# `VX_gemm_unit_v2` 무정지 고정 지연 파이프라인 구현 계획

## 1. 목표

`GEMM_IMPROVE` 구성을 위한 새 module `VX_gemm_unit_v2`를 만들고, command 단위 FSM과 선행 PSUM prefetch가 없는 packet 단위 고정 지연 파이프라인으로 구현한다.

기존 `VX_gemm_unit.sv`와 `VX_gemm_unit`은 구조 및 동작을 그대로 유지한다. 새 구조는 `VX_gemm_unit_v2.sv`에 독립적으로 작성하고, `GEMM_IMPROVE`의 상위 instantiation이 v2를 선택하도록 한다. 두 구조를 하나의 module 안에서 큰 `` `ifdef`` block으로 나누지 않는다.

핵심 목표는 다음과 같다.

- input packet의 admission을 중단시키는 back-pressure를 제거한다.
- ACC memory의 read/write address와 enable을 `VX_gemm_unit_v2` 외부에서 생성한다.
- input data와 packet별 control을 같은 순서로 파이프라이닝한다.
- input packet이 들어오면 정해진 cycle 뒤에 반드시 ACC memory write가 발생하도록 한다.
- accumulation read는 `one_cycle_early_acc_read_scheduling_derivation.md`의 규칙으로 스케줄한다.
- v2 compute 경로에는 main/read/write FSM, address counter, credit counter, round-robin scheduler를 포함하지 않는다.

이 단계의 검증 범위는 새 `hw/unittest/gemm_unit_v2`까지로 제한한다. 기존 `hw/unittest/gemm_unit`은 v1 regression reference로 보존한다. Core/top-level/blackbox simulation과 FPGA 검증은 후속 통합 단계에서 수행한다.

## 2. 범위와 전제

### 포함 범위

- `GEMM_IMPROVE`가 사용하는 internal ACC memory 경로
- `VX_gemm_node`의 packet control 생성
- 새 `VX_gemm_unit_v2_if`의 packet side-band 정의
- `VX_gemm_unit_v2`의 fixed-latency data/control pipeline
- one-cycle-early ACC read scheduling
- 새 `hw/unittest/gemm_unit_v2`의 directed/random unittest

### 제외 범위

- 기존 `VX_gemm_unit` 및 `GEMM_NAIVE`의 external PSUM LMEM 경로
- `VX_gemm_fsm`의 command 재배치 또는 queue 구조 변경
- output LDMA 및 TMEM subsystem의 성능 최적화
- top-level simulation, blackbox test, synthesis

`VX_gemm_node`는 internal ACC memory용 v2를 instantiate하고, `VX_gemm_node_naive`는 기존 v1을 계속 instantiate한다. 이에 따라 compute unit 내부에는 v1/v2 선택용 compile-time 분기가 필요 없다. 필요한 선택은 이미 상위 `VX_core`에 존재하는 node-level `GEMM_NAIVE` 분기에서 끝낸다.

## 3. 현재 구조에서 v2로 이식하지 않을 항목

현재 `VX_gemm_unit.sv`에는 compute datapath 외에 다음 상태 기반 제어가 들어 있다. 이는 v2에서 재사용하지 않을 항목이며, 기존 v1 RTL에서 삭제하지는 않는다.

1. `IDLE/COMPUTE` main FSM
2. `ACCUM_RD_IDLE/ACCUM_RD_READ` read FSM
3. `ACCUM_WR_IDLE/ACCUM_WR_WRITE` write FSM
4. command 단위로 latch되는 `gemm_unit_ctrl`
5. ACC read/write address 및 count register
6. bank별 read credit, round-robin 선택, eligibility 계산
7. PSUM 선행 prefetch를 위한 bank별 depth-4 FIFO
8. FSM transition에 의존하는 `idle/done/in_flight`

이 구조는 input 도착 시점과 무관하게 command 시작 직후 PSUM을 먼저 읽기 때문에, 다음 micro-GEMM을 연속 투입하려면 command 상태와 FIFO 여유를 함께 관리해야 한다. 목표 구조에서는 각 input packet이 자신의 address와 mode를 직접 들고 이동하므로 위 제어를 v2에 이식하지 않는다.

## 4. 목표 구조

```text
VX_gemm_node
  ├─ input data ----------------------------------------------┐
  └─ packet control                                           │
       {rd_en, wr_en, rd_addr, wr_addr, mode, reg_idx, last}   │
                                                              v
                 +--------------- VX_gemm_unit_v2 ---------------------+
input accept --> | data pipeline                                    |
                 | side-band pipeline ----------------------------+  |
                 |                                                |  |
                 | packet history -- early-read decision          |  |
                 |        |                                       |  |
                 |        +--> nominal/early read issue pipes     |  |
                 |                    |                            |  |
                 |              per-bank ACC read                 |  |
                 |                    |                            |  |
                 |        direct/bank-local 1-entry hold buffer   |  |
                 |                    |                            |  |
                 | scaler result + PSUM --> FP32 accumulator      |  |
                 |                    |                            |  |
                 | load/accum result alignment <------------------+  |
                 |                    |                               |
                 |              per-bank ACC write                  |
                 +---------------------------------------------------+
```

FSM 대신 valid가 포함된 shift register와 현재 cycle의 조합 논리만 사용한다. Bubble은 `valid=0`인 packet으로 전달되며, 유효 packet의 상대 순서는 바뀌지 않는다.

## 5. 외부 packet control interface

### 5.1 제안하는 packet control

`VX_gpu_pkg.sv`에 packet별 packed type을 추가하고 새 `VX_gemm_unit_v2_if`를 통해 전달한다. 기존 `VX_gemm_unit_if`는 v1 전용으로 유지한다.

```systemverilog
typedef struct packed {
    logic                                      valid;
    logic                                      acc_rd_en;
    logic                                      acc_wr_en;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]       acc_rd_addr;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]       acc_wr_addr;
    logic                                      quant_dir;
    logic                                      wreg_use_idx;
    logic                                      sreg_use_idx;
    logic                                      zreg_use_idx;
    logic                                      last;
} gemm_input_ctrl_t;
```

필드 이름은 구현 시 repository naming에 맞춰 확정하되 의미는 다음과 같이 고정한다.

| 필드 | 의미 |
|---|---|
| `valid` | 같은 cycle의 input data가 유효함 |
| `acc_rd_en` | 이 packet이 기존 PSUM을 읽어 accumulation함 |
| `acc_wr_en` | 계산 결과를 ACC memory에 저장함 |
| `acc_rd_addr` | PSUM read byte address |
| `acc_wr_addr` | 결과 write byte address |
| `quant_dir` | packet이 사용하는 QCOL/QROW 경로 |
| register index | weight/scale/zero double-buffer 선택 |
| `last` | command의 마지막 input packet |

현재 load packet은 `acc_rd_en=0, acc_wr_en=1`, accumulation packet은 `acc_rd_en=1, acc_wr_en=1`로 생성한다. 현재 주소 규칙에서는 read/write address가 같지만, interface에서는 두 주소를 분리해 scheduler와 writeback의 의미를 명확히 한다.

### 5.2 `VX_gemm_node`의 생성 규칙

`VX_gemm_node`가 command 정보를 latch하고, input LDMA가 GEMM input request를 내는 cycle마다 packet control을 만든다.

- `acc_rd_addr = acc_mem_base_addr + packet_idx * GEMM_PSUM_DATA_SIZE`
- `acc_wr_addr = acc_mem_base_addr + packet_idx * GEMM_PSUM_DATA_SIZE`
- `acc_rd_en = !is_load`
- `acc_wr_en = 1`
- `last = (packet_idx == acc_cnt - 1)`
- `packet_idx`는 실제 input request admission에서만 증가한다.

가능하면 input LDMA의 destination base/stride도 같은 ACC address sequence로 설정하여 `i_gemm_bus_if.req_data.addr`와 side-band address가 일치하게 한다. Unit test와 simulation assertion에서 두 값의 일치를 검사한다.

v2의 command-level `idle/done`은 기존 `VX_gemm_unit`의 FSM 상태를 뜻하지 않는다.

- `idle`: node의 input command/address generator가 새 command를 받을 수 있음
- `done`: `last` packet의 ACC write가 실제 발생함

`VX_gemm_unit_v2`는 이를 위해 `last_write` pulse와 `pipeline_empty` 상태만 제공하고, command 상태는 상위 node가 소유한다.

## 6. 고정 지연 정의

cycle 정의를 input admission cycle (T_i)로 통일한다.

```systemverilog
input_fire = i_lmem_bus_if.req_valid;
assign i_lmem_bus_if.req_ready = 1'b1;
```

다음 localparam을 named pipeline stage의 합으로 정의한다.

- `L_PRE`: input admission부터 FP32 accumulator 입력까지
- `L_R`: ACC SRAM read request부터 read data 사용 가능 시점까지
- `L_A`: FP32 accumulator 입력부터 결과까지
- `L_P`: accumulator 결과부터 ACC SRAM write edge까지의 추가 register 수

현재 internal ACC memory는 `VX_sp_ram(OUT_REG=1)`이므로 구현 기준 `L_R=1`이다. FP wrapper latency는 simulation/backend에 따라 혼동하기 쉬우므로 숫자를 여러 곳에 직접 쓰지 않고 한 곳의 localparam 및 valid-pulse unittest로 확정한다.

QCOL과 QROW는 input scaler 경로가 다르다. 두 경로의 latency가 다르면 짧은 경로에 fixed delay를 추가하여 모든 packet에 대해 하나의 `L_PRE`가 성립하게 한다. load 결과도 accumulation 결과와 동일한 write offset을 갖도록 필요한 만큼 delay하여, mode가 바뀌어도 write latency가 변하지 않게 한다. 이 정렬은 latency를 늘릴 수 있지만 initiation interval은 1 cycle을 유지한다.

필수 elaboration 조건은 다음과 같다.

```text
L_PRE >= L_R + 1
K = L_A + L_P + L_R
NOMINAL_READ_DLY = L_PRE - L_R
EARLY_READ_DLY   = NOMINAL_READ_DLY - 1
WRITE_DLY        = L_PRE + L_A + L_P
```

각 delay 값에는 static assertion을 두어 parameter/config 변경 시 음수 depth나 잘못된 schedule이 조용히 생성되지 않게 한다.

## 7. Side-band pipeline 구성

하나의 큰 magic-number shift register 대신 datapath의 의미 있는 경계에 control register를 둔다.

1. input admission
2. input scaler/QCOL bypass 정렬
3. prealigner output
4. MXU output
5. merger output
6. int-to-FP output
7. output scaler/bypass output, 즉 accumulator 입력
8. accumulator output
9. ACC SRAM write input

각 stage는 data valid와 동일한 조건으로 side-band valid를 이동시킨다. `quant_dir`과 register index도 packet별로 전달하여 앞 command의 packet이 pipeline에 남아 있는 동안 다음 command의 control이 바뀌어도 기존 packet이 영향을 받지 않게 한다.

weight/scale/zero register write hazard는 main FSM의 `in_flight` 대신 pipeline에 남아 있는 packet의 register index를 OR-reduction한 busy vector로 판단한다. input data path만 no-backpressure이며, weight/scale/output interface의 기존 protocol은 별도 보장이 없는 한 유지한다.

## 8. One-cycle-early ACC read scheduling

### 8.1 적용 공식

유도 문서의 규칙을 RTL에 그대로 대응시킨다.

\[
K=L_A+L_P+L_R
\]

현재 packet (i)의 nominal read와 충돌하는 과거 packet은 정확히 (K) cycle 전에 들어온 write packet이다.

\[
early_i = current.acc\_rd\_en
          \land history_K.valid
          \land history_K.acc\_wr\_en
          \land (history_K.wr\_bank=current.rd\_bank)
\]

\[
R_i=T_i+L_{PRE}-L_R-early_i
\]

history index는 다음처럼 명시하여 off-by-one을 방지한다.

```text
history[0]   = 1 cycle 전 packet
history[K-1] = K cycle 전 packet
```

따라서 실제 history array의 최소 depth는 `K`이다.

### 8.2 4 physical bank에 대한 적용

현재 ACC memory는 4 physical bank이지만 주소 stream은 선택된 group 안에서 ping-pong한다. conflict 비교는 parity bit 하나가 아니라 `get_acc_mem_idx()`가 반환하는 full physical bank ID로 수행한다.

외부 address generator는 다음 전제를 지켜야 한다.

- 한 cycle에 최대 한 packet admission
- packet 순서 유지
- packet address는 `GEMM_PSUM_DATA_SIZE` 간격
- 동일 stream에서 bank가 strict alternating
- 모든 packet의 write latency가 동일

이 전제가 깨지면 one-cycle-early 보장이 성립하지 않으므로 simulation assertion으로 즉시 검출한다.

### 8.3 nominal/early issue pipe

read request는 두 fixed-delay 경로로 만든다.

- `early=0`: metadata를 `NOMINAL_READ_DLY`만큼 지연
- `early=1`: metadata를 `EARLY_READ_DLY`만큼 지연

인접 packet의 nominal request와 early request가 같은 cycle에 도착할 수 있으므로 단일 scalar request mux로 합치면 안 된다. physical bank별로 request enable/address를 만들고 서로 다른 bank에 대한 최대 두 read를 같은 cycle에 허용한다.

같은 bank에 두 read가 모이는 경우는 유도상의 금지 조건이며 assertion failure로 처리한다. 같은 bank의 read/write 동시 issue도 허용하지 않는다.

### 8.4 read result 정렬

nominal read result는 accumulator 입력 cycle에 바로 도착한다. early read result는 한 cycle 먼저 도착하므로 physical bank별 1-entry hold register에 저장한다.

- nominal result: response-to-accumulator bypass
- early result: 1-entry hold 후 다음 cycle consume
- 같은 cycle enqueue/dequeue: bypass 또는 명시적인 next-state 논리로 처리
- accumulator stage의 side-band bank ID로 올바른 PSUM을 선택

v1의 bank별 depth-4 FIFO, credit counter, prefetch count는 v2에 이식하지 않는다. 새 1-entry buffer는 scheduling 결과의 1-cycle 차이만 흡수하며 임의의 input 지연을 보상하는 queue로 사용하지 않는다.

## 9. ACC write 및 completion

write metadata는 input에서 `WRITE_DLY`만큼 지연한다. write data도 같은 stage에 도착하도록 load/accum 경로를 정렬한다.

```text
acc_mem_wr_en[bank]   = write_meta.valid && write_meta.acc_wr_en
acc_mem_wr_addr[bank] = write_meta.acc_wr_addr
acc_mem_wr_data[bank] = aligned_result
```

한 cycle에 최대 한 input만 들어오고 write latency가 고정이므로 compute write는 한 cycle에 최대 하나다. `last_write`는 다음 조건에서 한 cycle pulse로 발생시킨다.

```text
last_write = write_meta.valid && write_meta.acc_wr_en && write_meta.last
```

`done`은 예측한 latency가 아니라 실제 `last_write`에 연결한다. `pipeline_empty`는 side-band valid vector와 early-read hold valid의 OR-reduction으로 계산한다.

Output read (`o_lmem_bus_if`)은 compute scheduler와 섞지 않는다. 이번 단계에서는 `pipeline_empty` 이후에만 허용하고, unit test도 마지막 write 이후 output을 읽는다. 이후 top-level overlap이 필요하면 output read를 별도 memory-port requester로 확장한다.

## 10. 파일별 수정 계획

### `hw/rtl/VX_gpu_pkg.sv`

- packet side-band packed type 추가
- 기존 v1 debug/perf type은 유지
- 필요하면 early-read, fixed-latency write 관찰용 v2 debug type을 별도로 추가

### `hw/rtl/core/gemm/VX_gemm_unit_if.sv`

- 수정하지 않고 기존 `VX_gemm_unit` 전용 interface로 유지

### `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv` — 신규

- packet control input 정의
- node가 사용할 `last_write`와 `pipeline_empty` 상태 정의
- v1의 command FSM 중심 `start/idle/done` 계약을 가져오지 않음

### `hw/rtl/core/gemm/VX_gemm_node.sv`

- `VX_gemm_unit` 대신 `VX_gemm_unit_v2` instantiate
- `VX_gemm_unit_v2_if` 생성 및 연결
- command별 ACC base/count/mode/register index capture
- input admission과 동기화된 packet index/address/enable/last 생성
- input LDMA destination address sequence와 side-band address 정렬
- command `idle/done`을 external generator readiness와 `last_write`로 재정의

### `hw/rtl/core/gemm/VX_gemm_unit.sv`

- 수정하지 않음
- `VX_gemm_node_naive`와 기존 v1 unittest가 계속 사용

### `hw/rtl/core/gemm/VX_gemm_unit_v2.sv` — 신규

- 기존 v1 datapath에서 필요한 arithmetic/register block만 명시적으로 이식
- main/read/write FSM 및 관련 counter/scheduler를 처음부터 포함하지 않음
- input `req_ready=1'b1` 고정
- packet control history 및 stage-aligned side-band pipeline 추가
- QCOL/QROW 및 load/accum fixed-latency 정렬
- nominal/early per-bank read issue 생성
- bank별 1-entry early-result buffer 추가
- delayed metadata 기반 ACC write 및 completion 생성
- output read를 pipeline empty 이후로 제한
- v2 전용 assertion/debug/perf 추가

### `hw/rtl/core/gemm/VX_gemm_unit_top.sv`

- 수정하지 않고 v1 synthesis wrapper로 유지

### `hw/rtl/core/gemm/VX_gemm_unit_v2_top.sv` — 후속 단계

- 이번 unittest-only 단계에서는 만들지 않음
- 후속 synthesis 단계에서 v2 전용 wrapper가 필요할 때 별도 파일로 추가

### `hw/unittest/gemm_unit` 기존 unittest

- 수정하지 않고 v1 regression으로 유지

### `hw/unittest/gemm_unit_v2` — 신규 unittest directory

- `tb_VX_gemm_unit_v2.sv`, `Makefile`, `vcs.mk`, `vlt.mk`, waveform 설정 추가
- 기존 numerical reference/stimulus helper는 필요한 부분만 복사 또는 공용화
- stimulus를 packet side-band 중심으로 작성
- cycle-accurate address/read/write scoreboard 추가
- ready, fixed latency, early-read schedule assertion 추가

### explicit RTL source list

- 새 v2 unittest `Makefile`에 `VX_gemm_unit_v2.sv`와 `VX_gemm_unit_v2_if.sv` 추가
- `VX_gemm_node`를 compile하는 `hw/unittest/gemm_node_improve/Makefile`은 node 통합 단계에서 v1 source를 v2 source로 교체
- source discovery를 사용하는 top-level flow는 `hw/scripts/gen_sources.sh` 결과에 신규 파일이 포함되는지 후속 compile에서 확인

`hw/rtl/patch`와 `third_party/component_database`의 복사본은 이번 canonical RTL/unittest 변경에 포함하지 않는다. 후속 synthesis packaging 단계에서 canonical RTL과 동기화 여부를 별도로 결정한다.

## 11. 구현 순서

1. 기존 v1을 reference로 사용해 현재 config의 input-to-stage valid pulse를 측정하고 `L_PRE`, `L_A`, `L_P`, `L_R` 기준을 확정한다.
2. `VX_gemm_unit_v2_if.sv`와 `hw/unittest/gemm_unit_v2`의 최소 compile skeleton을 만든다.
3. `VX_gemm_unit_v2.sv`에 arithmetic datapath를 이식하고 QCOL/QROW 및 load/accum latency를 하나의 fixed write latency로 정렬한다.
4. packet control side-band pipeline과 external address/enable 기반 write path를 구현한다.
5. 동일 input에 대해 v1 numerical result와 v2 result를 비교하여 arithmetic datapath 이식 오류를 먼저 제거한다.
6. packet history, `K`-lookback, nominal/early per-bank read issue를 구현한다.
7. bank별 1-entry result buffer를 연결하고 accumulation numerical test를 통과시킨다.
8. v2에 main/read/write FSM, prefetch FIFO, credit/round-robin logic이 포함되지 않았는지 구조 검토한다.
9. `VX_gemm_node`의 packet generator, v2 instantiation, completion 경로를 연결한다.
10. directed test, bubble test, full-rate test, random test 순으로 v2 unittest를 통과시킨다.

중간 단계마다 v2가 compile 가능한 상태를 유지한다. 기존 v1을 단계적으로 변형하지 않고, v1은 numerical 및 latency reference로만 사용한다.

## 12. Assertion 계획

다음 항목을 non-synthesis assertion으로 둔다.

1. `i_lmem_bus_if.req_ready`는 reset 여부와 관계없이 항상 1이다.
2. `packet_ctrl.valid == i_lmem_bus_if.req_valid`이다.
3. 유효 input마다 `WRITE_DLY` 뒤 정확히 한 번의 write가 발생한다.
4. write address/enable/last가 input packet의 side-band와 일치한다.
5. accumulation packet의 PSUM이 accumulator 입력 cycle에 반드시 존재한다.
6. 같은 physical bank에 read/read 또는 read/write가 동시에 issue되지 않는다.
7. early-result 1-entry buffer가 full인 상태에서 overwrite되지 않는다.
8. strict ping-pong address 규칙과 한-cycle 한-packet 전제가 유지된다.
9. `last_write` 이전에 `done`이 발생하지 않고, 이후 중복 pulse가 없다.
10. reset 후 stale valid, stale read response, ghost write가 발생하지 않는다.
11. forwarding side-band가 유효하면 바로 앞 packet의 write enable과 writeback valid가 존재하고, 그 write address가 현재 read address와 같다.
12. stream address는 strict progression이거나 위 조건을 만족하는 immediate same-address dependency여야 한다.

## 13. Unittest 계획

기존 numerical test coverage를 유지하면서 다음 cycle-level test를 추가한다.

### 기본 기능

- single/multi input load
- single/multi input accumulation
- QCOL/QROW
- weight/scale/zero register index 0/1
- 여러 ACC base address와 bank group boundary
- load 후 동일 address에 accumulate
- 여러 K iteration에 대한 반복 accumulation

### fixed-latency/no-backpressure

- 1 cycle 간격의 연속 input에서 모든 cycle `ready==1`
- input bubble을 1~여러 cycle 삽입해도 이후 packet write cycle이 각자의 admission 기준으로 고정됨
- command 경계에서 mode/register index가 바뀌어도 이전 packet metadata가 보존됨
- 마지막 packet의 실제 write와 `done`이 같은 cycle에 발생함

### early-read scheduler

- nominal cycle에 conflict가 없는 경우 `early=0`
- 정확히 `K` cycle 전 same-bank write가 있는 경우 `early=1`
- `K` cycle 전 packet이 invalid bubble이면 nominal read
- `K` cycle 전 packet이 다른 bank이면 nominal read
- nominal과 early request가 같은 cycle에 서로 다른 bank로 issue되는 경우
- group boundary를 넘는 address sequence에서 full physical bank 비교가 맞는 경우
- early 결과가 1-entry buffer에서 한 cycle 유지된 뒤 올바른 packet에 소비되는 경우

### immediate same-address forwarding

- admission 직전 cycle의 packet이 현재 `acc_rd_addr`와 같은 주소에 write하는 경우 forwarding side-band를 설정
- forwarding packet은 nominal/early ACC SRAM read를 모두 생략
- accumulator 입력에서 직전 packet의 같은-cycle writeback data를 PSUM으로 선택
- 직전 packet이 load 또는 accumulation인 두 경우 모두 writeback valid/address를 확인
- 두 개의 연속 same-address accumulation이 최초 SRAM read 한 번만 사용하고 누적 결과를 생성하는 numerical test

### randomized scoreboard

- valid/bubble, load/accum, base address를 제약 랜덤으로 생성
- reference FP 계산과 ACC memory image 비교
- packet별 예상 read issue cycle, write cycle, bank, address를 queue로 추적
- admission history에서 immediate forwarding을 독립 판정하고 forwarding packet의 read expectation을 생성하지 않음
- drop, duplicate, reorder, unexpected stall을 별도 오류로 보고

## 14. Unittest 실행 방법

프로젝트 규칙에 따라 config를 먼저 source하고 configured build directory에서 실행한다.

```bash
cd <configured-build-dir>
source ../configs/improve_th32_tcol32_hwexp_dcache.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
make -C hw/unittest/gemm_unit_v2 SIM_EXEC=vcs run
```

v1 reference 비교가 필요하면 별도로 `make -C hw/unittest/gemm_unit SIM_EXEC=vcs run`을 실행한다. v2 검증 완료 조건은 compile 성공, 이식한 numerical case 통과, 새 cycle-level assertion 0건, `input_ready_stall_cycles=0`이다. 이 단계에서는 `ci/run_black.sh`를 실행하지 않는다.

## 15. 완료 기준

- 새 `VX_gemm_unit_v2.sv`가 존재하고 기존 `VX_gemm_unit.sv`는 구조적으로 변경되지 않는다.
- `GEMM_IMPROVE`의 `VX_gemm_node`가 `VX_gemm_unit_v2`를 사용한다.
- v2 compute 경로에 main/read/write FSM이 없다.
- input request가 유효한 모든 cycle에 `req_ready=1`이다.
- 모든 유효 packet은 `WRITE_DLY` 뒤 지정 address에 정확히 한 번 저장된다.
- accumulation read는 `K`-lookback 규칙에 따라 nominal 또는 정확히 1 cycle early로 issue된다.
- immediate same-address dependency는 직전 aligned writeback을 forwarding하고 별도 ACC SRAM read를 issue하지 않는다.
- 서로 다른 bank의 동시 read는 허용하고 same-bank read/read 및 read/write conflict는 발생하지 않는다.
- deep prefetch FIFO와 read credit/round-robin logic이 제거된다.
- command 경계에서도 packet별 mode/address/register index가 손상되지 않는다.
- `hw/unittest/gemm_unit_v2`의 신규 test가 모두 통과한다.
- 기존 `hw/unittest/gemm_unit`은 v1 regression으로 유지된다.

## 16. 주요 위험과 대응

| 위험 | 대응 |
|---|---|
| FP wrapper/backend별 실제 latency 차이 | named localparam, static assertion, valid-pulse unittest로 단일 기준 확정 |
| QCOL/QROW latency 차이 | 짧은 경로에 fixed alignment stage 추가 |
| load/accum write latency 차이 | load result를 accumulator write offset에 맞춰 지연 |
| command가 pipeline drain 전에 바뀜 | mode와 register index를 packet side-band로 전달 |
| nominal/early read가 같은 cycle에 겹침 | scalar mux 대신 physical bank별 request vector 사용 |
| early PSUM과 nominal PSUM 혼동 | bank별 1-entry hold와 accumulator-stage bank metadata 사용 |
| output read가 compute access와 충돌 | 이번 단계에서는 `pipeline_empty` 이후에만 output read 허용 |
| strict ping-pong 전제 위반 | node address generator를 단일 source of truth로 두고 assertion 추가 |
| consecutive same-address RAW dependency | admission 직전 writer를 exact address로 비교하고 writeback-aligned forwarding 및 read suppression 적용 |
| v1 또는 `GEMM_NAIVE` 회귀 | v1 파일/interface/unittest를 수정하지 않고 node별 module instantiation으로 완전히 분리 |
| v1/v2 중복 코드 증가 | 공용 arithmetic submodule은 재사용하되 top-level control/datapath wiring은 가독성을 위해 독립 유지 |

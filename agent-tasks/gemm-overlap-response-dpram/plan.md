# GEMM Overlap DMA and Wide-Read Response DPRAM Plan

## 목표

GEMM overlap DMA의 response slot payload와 Weight wide-read assembly
payload를 compile-time parameter로 선택할 수 있게 한다.

- FF mode: 명시적 `RESPONSE_DATA_RAM=0` override에서 기존
  `slot_data_r[RESPONSE_SLOTS]` 구현을 그대로 보존한다.
- RAM mode: payload만 synchronous 1R1W dual-port `VX_dp_ram`에 저장한다.
- `VX_tmem_wide_read_switch.ctx_rsp_data_r`도 FF/RAM mode를 지원하고 RAM
  mode에서는 logical lane별 `VX_dp_ram`으로 bank response를 조립한다.
- Generic queue와 production parameter layer는 RAM mode를 기본값으로 하고,
  IMPROVE production의 Input, Weight, Scale, Zero-point overlap DMA와 Weight
  wide switch도 별도 override 없이 RAM mode를 사용한다.
- GEMM Output DMA는 이미 `VX_dma_unit_align`의 `VX_dp_ram`을 사용하므로
  변경하지 않는다.
- external handshake, command ordering, out-of-order response 수용, writer
  fence 및 steady-state 1 beat/cycle drain 성능을 보존한다.

최종 목적은 wide payload FF와 variable-index mux를 제거하여 TMEM 주변의
register 밀도, high-fanout select net 및 routing congestion을 줄이는 것이다.

## 현재 RTL과 문제점

### Overlap DMA response payload

공통 queue는 slot의 상태와 owner metadata뿐 아니라 전체 response data도
FF 배열로 선언한다.

- payload 선언: [`VX_gemm_stream_dma_queue.sv:101-105`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L101-L105)
- variable-index sink read: [`VX_gemm_stream_dma_queue.sv:142-160`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L142-L160)
- payload 전체 reset: [`VX_gemm_stream_dma_queue.sv:351-356`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L351-L356)
- response-tag 기반 random write: [`VX_gemm_stream_dma_queue.sv:368-372`](../../hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv#L368-L372)

`slot_data_r[sink_slot]`의 asynchronous variable-index read와 전체 payload
reset 때문에 Vivado는 이를 BRAM으로 추론하지 않고 FF와 wide mux로
구현한다. 기존 실패 checkpoint에서 확인된 stream queue 비용은 다음과
같다.

| Queue | LUT | Register |
|---|---:|---:|
| Input | 2,904 | 5,763 |
| Weight | 6,422 | 10,562 |
| Scale | 3,229 | 5,943 |
| Zero-point | 3,636 | 5,943 |

특히 Weight queue의 `drain_stage_slot_r[1]`은 fanout 1,332, slack
-2.287 ns로 관찰되었다. 근거와 report 위치는
[`diagnosis.md:405`](../diagnose-th16-bigmem-congestion/diagnosis.md#L405)에
정리되어 있다.

현재 production 구성에서 payload 폭과 slot 수가 각각 `DATAW`와
`RESPONSE_SLOTS`이므로, RAM mode가 제거할 수 있는 payload FF의 이론값은
queue마다 다음과 같다.

```text
payload_ff_bits = DATAW * RESPONSE_SLOTS
```

다음 수치는 **historical WLOAD8 baseline evidence**다. 현재 production/OOC
검증 기준은 WLOAD4이며 아래 WLOAD8 측정값을 WLOAD4 결과로 해석하지 않는다.
TH16/TCOL32/F16/bigmem/WLOAD8, 8-slot 구성에서는 Input/Scale/Zero-point가
각 512 x 8 bit, Weight가 1024 x 8 bit이므로 총 20,480 payload bit이다.
실제 FF 감소량은 synthesis 최적화와 packing 때문에 이 값과 정확히 같지
않을 수 있다.

### Weight wide-read assembly payload

Weight overlap DMA의 logical read 폭이 TMEM physical bank 폭보다 크면
`VX_tmem_wide_read_switch`가 한 logical request를 여러 bank read로 나누고,
돌아온 조각을 `ctx_rsp_data_r`에 모아 다시 하나의 response로 만든다.

- context payload 선언: [`VX_tmem_wide_read_switch.sv:90-92`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L90-L92)
- original tag의 slot bits를 context ID로 사용: [`VX_tmem_wide_read_switch.sv:108-110`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L108-L110)
- physical bank response를 logical lane에 기록: [`VX_tmem_wide_read_switch.sv:232-240`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L232-L240)
- complete context의 wide variable-index read: [`VX_tmem_wide_read_switch.sv:133-148`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L133-L148)
- retire/accept/reset 시 payload 전체 clear: [`VX_tmem_wide_read_switch.sv:244-274`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L244-L274), [`VX_tmem_wide_read_switch.sv:305-327`](../../hw/rtl/mem/VX_tmem_wide_read_switch.sv#L305-L327)

이 배열도 next-state copy, variable-index read, 전체 clear 때문에 FF로
합성된다. 다음은 **historical WLOAD8/8-context 측정**이다.

```text
ctx_rsp_data_r bits
  = OUTSTANDING * WIDE_DATA_SIZE * 8
  = 8 * 128 bytes * 8
  = 8,192 bits
```

historical WLOAD8 OOC 결과의 `u_switch_weight` 전체 register는 8,552개이며 그중
8,192개가 이 payload에 해당한다. 네 stream queue의 20,480 payload bit와
합치면 이번 변경이 RAM으로 옮길 수 있는 wide payload의 이론값은 총
28,672 bit다.

Weight 경로에는 두 저장 단계가 있으며 역할이 다르므로 둘 다 유지하되
각 payload 구현만 RAM으로 바꾼다.

```text
TMEM bank responses
  -> wide switch ctx_rsp_data   // bank fragment assembly
  -> Weight stream slot_data    // complete beat + writer-fence buffering
  -> GEMM Weight register
```

### 기존 aligned DMA와의 차이

`VX_dma_unit_align`은 source response를 이미 registered-read
`VX_dp_ram`에 저장한다.

- payload assemble/mask: [`VX_dma_unit_align.sv:1141-1159`](../../hw/rtl/core/VX_dma_unit_align.sv#L1141-L1159)
- response RAM: [`VX_dma_unit_align.sv:1162-1180`](../../hw/rtl/core/VX_dma_unit_align.sv#L1162-L1180)
- registered drain state: [`VX_dma_unit_align.sv:920-935`](../../hw/rtl/core/VX_dma_unit_align.sv#L920-L935)

동일하게 response write port와 ordered drain read port를 분리하면 overlap
DMA도 wide payload FF를 BRAM으로 옮길 수 있다. Slot state, command owner,
sequence, beat index처럼 검색에 필요한 작은 metadata는 FF로 유지한다.

## 제안 RTL 구조

### 1. Storage mode parameter

`VX_gemm_stream_dma_queue`에 다음 parameter를 추가한다.

```systemverilog
parameter bit RESPONSE_DATA_RAM = 1'b1
```

- `0`: 명시적 fallback으로 기존 `slot_data_r` FF 배열을 elaboration한다.
- `1`: 기본값이며 `slot_data_r`를 제거하고 `VX_dp_ram`을 elaboration한다.
- generic queue와 모든 production wrapper의 기본값을 `1`로 통일하고,
  directed A/B 검증은 명시적 `0` override로 FF mode를 선택한다.
- 두 storage를 동시에 elaboration하지 않도록 generate branch로 분리한다.

RAM mode에서는 다음과 같이 설정한다.

```systemverilog
VX_dp_ram #(
    .DATAW     (DATAW),
    .SIZE      (RESPONSE_SLOTS),
    .WRENW     (1),
    .OUT_REG   (1),
    .LUTRAM    (0),
    .RDW_MODE  ("R"),
    .RADDR_REG (1),
    .RESET_RAM (0)
)
```

- write: `source_response_fire`, address `response_slot`, data
  `fetch_if.rsp_payload`;
- read: ordered drain-stage load, address `stage_slot`;
- RAM payload는 reset하지 않는다. Reset된 `slot_state_r`만 payload validity를
  결정한다.
- Xilinx에서 wide/shallow memory는 여러 RAMB primitive가 폭 방향으로
  병렬 배치될 수 있다. 정확한 RAMB18/RAMB36 수는 synthesis report로
  판단하며 RTL에서 primitive 수를 가정하지 않는다.

### 2. Synchronous read와 drain stage 결합

RAM mode는 synchronous read latency가 필요하다. 새로운 별도 pipeline을
추가하는 대신 현재의 `drain_stage_valid_r`/`drain_stage_slot_r`을 RAM read
launch와 output ownership stage로 사용한다.

내부적으로 다음 localparam을 둔다.

```systemverilog
localparam bit USE_SINK_STAGE = SINK_PIPELINE || RESPONSE_DATA_RAM;
```

기존 `SINK_PIPELINE` 조건부 select/search/ready-ahead 로직은
`USE_SINK_STAGE`를 사용하도록 정리한다. 따라서 RAM mode는 항상 sink
stage를 사용하고, FF mode는 기존 `SINK_PIPELINE` 동작을 그대로 따른다.

동작 예시는 다음과 같다.

```text
cycle N:
  ordered READY slot K를 stage_found가 선택
  VX_dp_ram read(K) 요청

posedge N -> N+1:
  drain_stage_valid_r <= 1
  drain_stage_slot_r  <= K
  RAM output          <= payload[K]
  slot_state[K]       <= SLOT_DRAINING

cycle N+1:
  sink write_valid/tag/metadata/payload가 모두 slot K를 가리킴
```

현재 Input/Weight/Scale/Zero-point overlap instance는 모두
`SINK_PIPELINE=1`이므로 RAM mode가 추가 pipeline cycle을 만들지 않는다.
Sink가 매 cycle ready이고 다음 ordered slot이 READY이면, 현재 slot을
consume하는 edge에서 다음 slot RAM read를 동시에 실행한다. 따라서 최초
fill 이후에는 계속 1 beat/cycle로 drain한다.

### 3. Backpressure와 collision contract

- `sink_if.write_valid && !sink_if.write_ready` 동안에는 RAM read를 새로
  실행하지 않고 RAM output, `drain_stage_slot_r`, tag, metadata, `write_last`
  를 모두 안정적으로 유지한다.
- response write port는 drain read port와 독립적으로 매 cycle 한 response를
  받을 수 있다.
- `SLOT_WAIT_RSP`만 response write를 허용하고 `SLOT_READY`만 drain read를
  허용하므로 같은 slot의 read/write collision은 정상 동작에서 발생하지
  않는다.
- same-cycle slot recycle은 destination consume과 새 source request allocation
  사이에서만 허용한다. 새 request는 그 cycle에 payload를 쓰지 않으므로
  RAM read/write collision 의미를 바꾸지 않는다.
- RAM mode에서는 read/write address가 같을 때 fatal assertion을 추가하여
  state-machine contract 위반을 조기에 검출한다.
- stalled sink payload/tag/last 안정성 assertion도 storage mode 공통으로
  추가한다.

### 4. FF mode 호환성

FF generate branch에서는 다음을 그대로 유지한다.

- `slot_data_r[RESPONSE_SLOTS]` declaration;
- reset 시 payload zeroing;
- response 수락 시 `slot_data_r[response_slot]` write;
- `slot_data_r[sink_slot]` direct read;
- 현재 `SINK_PIPELINE`과 `SAME_CYCLE_SLOT_RECYCLE` timing.

따라서 parameter 기본값을 사용하는 기존 OOC, unittest, NAIVE gather는
bit/cycle compatible해야 한다.

### 5. Weight wide-switch lane-banked response RAM

`VX_tmem_wide_read_switch`에도 독립적인 parameter를 추가한다.

```systemverilog
parameter bit RESPONSE_DATA_RAM = 1'b1
```

- `0`: 현재 `ctx_rsp_data_r` FF/next-state 구현을 그대로 유지한다.
- `1`: `BANKS_PER_BEAT`개의 logical-lane RAM을 생성한다.
- 각 RAM은 `DATAW=DATA_WIDTH`, `SIZE=OUTSTANDING`, `OUT_REG=1`,
  `LUTRAM=0`, `RDW_MODE="R"`, `RESET_RAM=0`인 `VX_dp_ram`이다.
- RAM address는 context ID이고 한 context의 모든 lane RAM을 같은 address로
  읽어 wide response를 구성한다.
- `ctx_rsp_seen_r`, `ctx_valid_r`, tag, bank mask, issue/order FIFO 같은 control
  metadata만 FF로 남긴다.

한 physical bank당 response가 하나씩 있으므로 같은 cycle에 여러 response가
도착할 수 있다. 그러나 WLOAD8처럼 `NUM_BANK_GROUPS > 1`이면 서로 다른
physical bank가 같은 logical lane 번호를 공유할 수 있어, 단순히
`BANKS_PER_BEAT`개 RAM으로 연결하면 한 lane RAM에 여러 write가 충돌할 수
있다.

RAM mode에서는 logical lane마다 legal bank response를 하나 선택하는 작은
arbiter를 둔다.

```text
lane L candidates = bank L, L+BANKS_PER_BEAT, ...
lane L grant      = 그 cycle에 선택된 legal response 하나
RAM[L].write      = granted response
RAM[L].waddr      = granted response context ID
```

- grant를 받은 bank만 `rsp_ready=1`로 응답을 소비한다.
- 같은 lane의 다른 legal response는 `rsp_ready=0`으로 유지하여 다음 cycle에
  수용한다. Bank-side ready/valid contract에 따라 payload/tag는 안정적으로
  유지되어야 한다.
- 서로 다른 logical lane은 각각 독립 RAM이므로 같은 cycle에 최대
  `BANKS_PER_BEAT`개 fragment를 수용할 수 있다.
- 실제 TMEM bank는 accepted read를 고정 latency로 반환하고 wide switch는
  context별 bank request를 순서대로 issue하므로 정상 production traffic에서
  같은-lane 충돌은 드물어야 한다. 그래도 generic interface의 arbitrary
  response timing을 보존하기 위해 backpressure arbitration을 구조적으로
  지원한다.
- lane별 작은 round-robin pointer를 사용해 같은 logical lane을 공유하는
  physical bank 사이의 starvation을 구조적으로 방지한다. 추가 FF는
  `BANKS_PER_BEAT * clog2(NUM_BANK_GROUPS)` 정도로 payload FF 감소량에 비해
  매우 작다.

### 6. Weight wide-switch synchronous output stage

RAM mode에서는 order FIFO head context가 complete된 뒤 모든 logical lane
RAM에 같은 context address로 read를 실행한다. 다음 cycle에 payload와
tag/context ownership을 `wide_rsp_stage`가 소유한다.

```text
cycle N:
  order-head context K complete
  lane_ram[*].read(K)

posedge N -> N+1:
  wide_rsp_stage_valid <= 1
  wide_rsp_stage_ctx   <= K
  lane RAM outputs     <= payload fragments for K

cycle N+1:
  bus_in_if.rsp_valid/data/tag presents context K
```

- upstream backpressure 동안 새 RAM read를 하지 않아 assembled data/tag를
  안정적으로 유지한다.
- current response retire edge에 다음 complete order-head context의 RAM read를
  동시에 실행하여 fill 이후 1 logical beat/cycle을 유지한다.
- context는 `wide_rsp_stage` response handshake 때만 free한다. RAM read를
  launch한 시점에는 context ID 재사용을 허용하지 않는다.
- complete context read와 response fragment write가 같은 context/lane에서
  동시에 발생하지 않아야 하며 이를 assertion으로 검사한다.
- FF mode는 현재 final-fragment capture 다음 cycle에 combinational response가
  보이지만, RAM mode는 explicit synchronous read 때문에 최초 response에
  최대 1 cycle이 추가될 수 있다. 이 latency는 functional test에서 허용하되
  steady-state throughput과 application 2% 성능 기준은 반드시 지킨다.
- RAM output을 다시 wide FF register로 복제하지 않는다. Stage에는
  valid/context/tag 같은 scalar metadata만 저장하고 data는 RAM registered
  output을 직접 사용한다.

## Parameter 전달과 production 선택

다음 module chain에 `RESPONSE_DATA_RAM`을 전달한다.

```text
VX_tmem_subsystem
  +-- VX_tmem_wide_read_switch (Weight bank-fragment assembly)
  +-- VX_lmem_dma_input_overlap
  |     `-- VX_gemm_stream_dma_queue
  +-- VX_lmem_dma_weight_overlap
  |     `-- VX_gemm_stream_dma_queue
  +-- VX_lmem_dma_qparam_overlap (Scale)
  |     `-- VX_lmem_dma_qparam_queue
  |           `-- VX_gemm_stream_dma_queue
  `-- VX_lmem_dma_qparam_overlap (Zero-point)
        `-- VX_lmem_dma_qparam_queue
              `-- VX_gemm_stream_dma_queue
```

`VX_tmem_subsystem`에는 선택적인 실험과 BRAM 배치 비교를 위해 다음 네
parameter를 둔다.

```systemverilog
parameter bit I_RESPONSE_DATA_RAM        = 1'b1,
parameter bit W_RESPONSE_DATA_RAM        = 1'b1,
parameter bit SZ_RESPONSE_DATA_RAM       = 1'b1,
parameter bit W_SWITCH_RESPONSE_DATA_RAM = 1'b1
```

Scale과 Zero-point는 같은 `SZ_RESPONSE_DATA_RAM` 값을 사용한다. 필요하면
두 경로를 나중에 분리할 수 있지만 첫 변경에서는 불필요한 parameter를
늘리지 않는다.

`VX_config.vh`의 `I_LMEM_DMA_RESPONSE_DATA_RAM`,
`W_LMEM_DMA_RESPONSE_DATA_RAM`, `SZ_LMEM_DMA_RESPONSE_DATA_RAM`,
`W_TMEM_WIDE_RESPONSE_DATA_RAM` macro도 기본 `1`로 둔다. Queue, wrapper,
subsystem, config macro의 모든 production parameter layer가 RAM-on을 기본으로
상속하며, 각 저장소의 directed A/B와 긴급 fallback만 명시적 `0` override를
사용한다.

`VX_lmem_weight_gather_dma`도 공통 queue를 사용하므로 queue의 RAM-on 기본값을
상속한다. `SINK_PIPELINE=0`인 NAIVE 전용 경로도 필요하면 queue-level
`RESPONSE_DATA_RAM=0`을 명시해 기존 FF fallback을 선택할 수 있다.

다음 경로는 변경하지 않는다.

- `u_ldma_output`: `VX_lmem_dma_misal` wrapper 아래의
  `VX_dma_unit_align`, 기존 response `VX_dp_ram` 사용;
- HBM<->TMEM `VX_dma_engine`의 8개 aligned DMA channel;
- misaligned DMA;
- response slot 수, command FIFO depth 및 external interface width.

## 구현 순서

1. `VX_gemm_stream_dma_queue`에 storage parameter와 FF/RAM generate branch를
   추가한다.
2. 기존 sink pipeline을 `USE_SINK_STAGE`로 일반화하고 RAM read enable,
   address, registered output 연결을 추가한다.
3. collision 및 stalled-output stability assertion을 추가한다.
4. Input, Weight, QParam wrapper에 parameter를 전달한다.
5. `VX_tmem_wide_read_switch`에 FF/lane-banked RAM generate branch와 lane별
   response arbiter를 추가한다.
6. Wide-switch RAM mode에 synchronous assembled-response stage와 one-beat
   turnover lookahead를 추가한다.
7. `VX_tmem_subsystem`에 I/W/SZ stream queue와 Weight wide-switch를 각각
   선택하는 parameter를 추가한다.
8. generic queue, wrapper, subsystem macro의 기본값을 RAM-on으로 통일하고,
   FF 비교/복구 구성만 `RESPONSE_DATA_RAM=0`을 명시한다.
9. focused queue test, wide-read switch test, overlap DMA unit tests,
   xrt-vcs-sim을 통과한 후에만 OOC synthesis를 실행한다.
10. Queue-only, wide-switch-only, combined OOC 결과를 비교한다. 현재
    production 기본값은 RAM-on으로 유지하고, 실패 시 명시적 FF override로
    원인을 분리한 뒤 정책 변경 여부를 별도로 결정한다.

## 검증 계획

### 1. Focused dual-DUT queue test

`hw/unittest/gemm_stream_dma_queue`에 동일 stimulus를 받는 두 DUT를 둔다.

- baseline: `RESPONSE_DATA_RAM=0`, `SINK_PIPELINE=1`;
- candidate: `RESPONSE_DATA_RAM=1`, `SINK_PIPELINE=1`.

다음을 포함한다.

- command FIFO depth 1/2/4;
- response slots 4/8;
- 512-bit payload와 Weight용 wide payload;
- lowest-free와 ring slot allocation;
- out-of-order response;
- response write와 다른 slot drain read의 same-cycle overlap;
- destination backpressure와 writer fence hold;
- consecutive ready slots의 1 beat/cycle drain;
- `SAME_CYCLE_SLOT_RECYCLE=0/1`;
- command pop/enqueue 및 slot drain/reallocate 동시 수행;
- sequence wrap, stale response rejection, occupied reset.

두 DUT의 외부 request, response-ready, sink valid/tag/payload/last,
completion pulse, occupancy 및 ready-ahead를 cycle-by-cycle 비교한다. Overlap
production처럼 두 DUT 모두 sink stage를 사용하는 구성에서는 완료 cycle도
같아야 한다.

### 2. Focused Weight wide-read switch test

기존 `hw/unittest/tmem_wide_read_switch`를 FF/RAM mode로 parameterize한다.

- WLOAD4: `WIDE_DATA_SIZE=64`, `OUTSTANDING=8`;
- WLOAD8: `WIDE_DATA_SIZE=128`, `OUTSTANDING=8`;
- WLOAD16: `WIDE_DATA_SIZE=256`, `OUTSTANDING=2`;
- WLOAD32: `WIDE_DATA_SIZE=512`, `OUTSTANDING=1`.

기존 coverage인 consecutive request acceptance, partial bank readiness,
fragment skew, reverse context completion, ordered retirement, upstream
backpressure, stale/free/unissued/duplicate response rejection을 두 mode에서
모두 실행한다. 다음 RAM-specific coverage를 추가한다.

- 서로 다른 physical bank group/context에서 같은 logical lane response가
  같은 cycle에 도착하는 경우;
- lane arbiter winner만 handshake하고 loser는 다음 cycle까지 안정적으로
  hold되는지 확인;
- 서로 다른 logical lane의 RAM write 동시 수행;
- final fragment write와 context-complete 전환;
- assembled-response RAM read와 다른 context fragment write 동시 수행;
- output stage stall 동안 data/tag/context 안정성;
- retire와 다음 complete context RAM read 동시 수행;
- pipeline fill 이후 연속 1 logical beat/cycle retire;
- live context reset 시 metadata만 flush되고 stale RAM data가 노출되지 않음.

FF/RAM dual-DUT는 request fanout, accepted fragment set, logical response
data/tag/order를 비교한다. RAM mode의 same-lane collision backpressure와 최초
synchronous read 1 cycle은 허용하되 데이터 유실/중복은 허용하지 않는다.
충분한 complete context가 대기 중일 때 retire throughput은 두 mode 모두
1 beat/cycle이어야 한다.

### 3. Overlap DMA unit tests

기존 test를 storage mode별로 실행한다.

- `hw/unittest/lmem_dma_input_overlap`;
- `hw/unittest/lmem_dma_weight_overlap`;
- `hw/unittest/lmem_dma_qparam_overlap`의 Scale/Zero-point modes.

각 test는 FF/RAM mode에서 동일한 destination address/data 순서와
`write_done`/`done` cycle을 확인한다. Weight는 writer consume fence와
`SAME_CYCLE_SLOT_RECYCLE=0`, Input은 urgency/source gating, QParam은 두
consume-counter fence를 반드시 포함한다.

Weight overlap test에서는 stream queue RAM만 켠 경우, wide switch RAM만 켠
경우, 둘 다 켠 경우를 분리해 실행하여 latency나 데이터 오류의 원인을
구분한다.

### 4. XRT VCS simulation

저장소 변경 전후에 동일한 configured build와 workload를 사용하고
`ci/run_black.sh xrt-vcs-sim`으로 FPINT GEMM을 실행한다. 최소 matrix는
기존 GEMM control 검증과 동일하게 다음을 포함한다.

- `M=4, 256`;
- `N=K=256`, `QBLK=32`;
- `QDIR=0/1`, `WTRANS=0`, `WLOAD=4`.

모든 numerical check가 통과해야 한다. End-to-end kernel cycle 변화는 각
case에서 2% 이하여야 하며, RAM/FF dual-DUT와 overlap unit test가 cycle
동일성을 보장하는 경우에도 실제 application cycle을 별도로 기록한다.

### 5. Structural/OOC synthesis comparison

기존 [`gemm_node_ooc`](../../hw/syn/xilinx/gemm_node_ooc/README.md) flow로
다음 네 variant를 동일 조건에서 합성한다.

| Variant | Stream queue payload | Weight wide-switch payload |
|---|---|---|
| FF baseline | FF | FF |
| Queue RAM | RAM | FF |
| Wide-switch RAM | FF | RAM |
| Combined RAM | RAM | RAM |

- part: `xcu55c-fsvh2892-2L-e`;
- config: TH16/TCOL32/F16/bigmem/WLOAD4 (non-`_w8` config);
- clock: 7.000 ns;
- Vivado version, source manifest, IP directory, jobs 및 synthesis option 동일;
- FF/RAM 선택 define만 변경.

다음 hierarchy를 각각 report한다.

- `u_ldma_input/u_stream_queue`;
- `u_ldma_weight/u_stream_queue`;
- `u_ldma_scale/u_overlap/u_stream_queue`;
- `u_ldma_zero_point/u_overlap/u_stream_queue`;
- `u_switch_weight`와 그 lane response RAM hierarchy;
- 네 queue 합계와 전체 `u_tmem_subsystem`.

비교 항목은 LUT, FF, RAMB18, RAMB36, URAM, DSP, inferred memory 이름,
`drain_stage_slot_r`, `order_fifo_r`, `wide_rsp_stage` 관련 fanout 및 worst
setup path다. Combined RAM candidate에서는 stream payload array가
`response_payload_ram` hierarchy의 block RAM으로 나타나고 wide
`slot_data_r[*]` FDRE가 없어야 한다. `u_switch_weight`에서는
`ctx_rsp_data_r[*]` FDRE가 없어지고 logical-lane RAM이 RAMB primitive로
나타나야 한다.

OOC setup gate는 다음과 같다.

```text
WNS >= 0.000 ns
TNS == 0.000 ns
setup failing endpoints == 0
```

OOC synthesis가 BRAM 추론만 확인하고 실제 routing congestion을 충분히
보여주지 못하면, 마지막으로 동일 XRT build의 placed/route congestion
report를 baseline과 비교한다. 새 floorplan constraint는 이 변경에 추가하지
않는다.

## 성공 기준

### 기능과 cycle

- FF mode는 기존 test 결과와 bit/cycle compatible하다.
- stream queue RAM-only mode의 request/write/completion cycle이 FF dual-DUT와
  동일하다.
- Weight wide-switch RAM mode는 logical response data/tag/order를 보존하고,
  같은-lane response collision을 backpressure로 손실 없이 처리한다.
- Wide-switch synchronous read의 최초 최대 1-cycle latency는 허용하지만
  complete context가 연속으로 대기할 때 1 logical beat/cycle retire를
  유지한다. Combined mode의 전체 Weight stream은 이 fill latency 외에
  반복적인 bubble을 추가하지 않는다.
- out-of-order response, writer fence, backpressure, reset 및 same-cycle
  recycle assertion이 모두 통과한다.
- FPINT GEMM numerical test가 모두 통과하고 각 workload의 kernel cycle
  변화가 2% 이하다.

### 구조와 resource

- 두 RAM mode에서 payload가 RAMB primitive로 추론된다.
- enabled queue에서 `DATAW * RESPONSE_SLOTS`에 대응하는 wide payload FDRE가
  제거된다. Metadata FF는 남아 있어야 한다.
- `u_switch_weight`의 `ctx_rsp_data_r` payload FDRE가 제거되고 logical-lane
  response RAM으로 대체된다. WLOAD4의 정확한 bit/primitive 수는 새 OOC
  report에 기록한다.
- historical WLOAD8 combined candidate에서 제거 대상 wide payload의 이론값은
  총 28,672 bit였다. 이는 과거 비교용 수치이며 WLOAD4 resource 목표로
  재사용하지 않는다. 현재 WLOAD4 queue 합계와 `u_switch_weight`의 LUT/FF가
  명시적 FF baseline보다 감소해야 한다.
- `drain_stage_slot_r`가 더 이상 전체 wide FF mux를 직접 선택하지 않으며,
  `order_head_ctx`도 더 이상 전체 `ctx_rsp_data_r` FF mux를 직접 선택하지
  않는다. 관련 fanout과 negative slack이 감소한다.
- DSP와 URAM은 증가하지 않는다. BRAM 증가는 payload storage 이동에 필요한
  범위에서 허용하며 정확한 수는 report에 기록한다.
- 7 ns GEMM-node OOC setup violation이 없다.

### Production default와 fallback 판단

현재 확정 정책은 production RAM-on 기본값이다. 다음 중 하나가 발생하면
결과를 문서화하고 명시적 `RESPONSE_DATA_RAM=0` FF fallback으로 A/B 원인을
분리한다. Production 기본값 자체를 되돌리는 결정은 새 검증 결과와 별도
승인을 필요로 한다.

- RAMB가 추론되지 않고 FF/LUT로 남음;
- 기능 오류, 데이터 유실/중복 또는 steady-state throughput regression 발생;
- 2%를 넘는 application performance regression;
- LUT/FF 또는 high-fanout 개선이 없음;
- BRAM column 집중으로 OOC/full-design timing이나 congestion이 더 악화됨;
- 7 ns OOC setup gate 실패.

## 비범위

- `VX_tmem_wide_read_switch`의 request issue/order FIFO 구조 자체 변경;
- Output local DMA 또는 HBM DMA 구조 변경;
- response slot 수 추가 축소;
- command scheduler, TMEM arbiter 또는 GEMM compute pipeline 변경;
- manual BRAM/URAM/DSP/HBM floorplan constraint 추가;
- RAM mode 검증 전에 full XRT P&R 실행.

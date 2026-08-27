# GEMM_NAIVE compute/control/DMA parity 구현 계획

> 실행 상태 갱신: 2026-08-27
>
> Phase 0~5는 구현과 필수 검증을 통과했다. Phase 5의 4-slot PSUM lane-response
> OOO join과 2-entry tagged FIFO는 focused/integration VCS를 통과했고, M4 QCOL
> XRT/FSDB는 4738 cycle로 legacy WLOAD8 기준 4900 이하를 만족했다. 같은
> waveform에서 cross-set live outstanding, 224 logical/3584 lane request-response,
> tag/data 복원 및 terminal drain이 모두 확인됐다. 지원 범위
> `QBLK={32,64,128}`의 NAIVE node/XRT와 matched IMPROVE matrix도 통과했다.
> Phase 6 is complete. The fetch/sink contracts and bounded stream queue are
> shared by IMPROVE Input/Weight/Scale/Zero-point and the NAIVE row-major
> Weight gather, with exact focused/node/XRT acceptance through iteration 125.
> Phase 7 bounded cleanup and the final focused/node/XRT regression are
> complete. The final performance report is recorded at
> `build/naive_compute_pipeline_parity_final_report.md`. QBLK16 and the
> larger-than-M4 WTRANS1 matrix remain explicit exclusions.

## 1. 목표

`GEMM_NAIVE`와 `GEMM_IMPROVE`의 차이를 가능한 한 memory system으로 제한한다.

두 backend가 공통으로 가져야 할 항목은 다음과 같다.

- 동일한 GEMM arithmetic datapath
- 동일한 data/control elastic pipeline
- 동일한 `valid/ready` backpressure contract
- 동일한 Input transaction 단위 control metadata
- 동일한 Weight/Scale/Zero-point generation 및 consumer-readiness contract
- 동일한 transaction admission, pending, retire 및 completion 의미
- 동일한 공용 DMA primitive의 correctness/throughput 최적화

의도적으로 다르게 유지할 항목은 다음과 같다.

| 구분 | GEMM_NAIVE | GEMM_IMPROVE |
|---|---|---|
| DRAM layout | row-major | tile-major |
| global DMA topology | `VX_dma_node`, shared DCache path | `VX_dma_engine`, multi-channel AXI/HBM path |
| on-chip operand storage | LMEM | TMEM |
| operand memory arbitration | LMEM port/bank arbitration | TMEM bank arbitration와 readiness scheduler |
| Weight source formation | row-major LMEM gather | tile-major TMEM wide read |
| accumulation/result storage | 기존 external PSUM/final-result LMEM 경로 | internal banked ACC SRAM과 TMEM output path |
| FSM address generation | row-major DRAM/LMEM/PSUM/output 주소 | tile-major DRAM/TMEM slot/internal-ACC 주소 |

이 계획은 현재 구현된 NAIVE row-major/LMEM/DMA-node 연결을 제거하지 않는다. 공통 compute core 앞뒤에 memory adapter를 두어, memory latency와 topology 차이만 backpressure로 관찰되게 한다.

NAIVE와 IMPROVE의 FSM 및 address generator는 공통화하지 않는다. 공통화하는 것은 address 계산식이 아니라, 각 FSM이 계산한 address/control을 Input transaction과 함께 전달하고 stall 시 보존하는 protocol이다.

### 1.1 비교 검증 고정 조건

NAIVE와 IMPROVE의 기능 및 성능 비교에서는 **두 backend 모두 `MXU_WLOAD_NUM=8`로 고정**한다. WLOAD 차이가 memory-system 차이로 잘못 해석되지 않도록 WLOAD4 결과를 최종 비교에 섞지 않는다.

- NAIVE: row-major Weight layout, LMEM 및 `VX_dma_node`를 유지한 채 `MXU_WLOAD_NUM=8`
- IMPROVE: tile-major Weight layout, TMEM 및 multi-channel DMA를 유지한 채 `MXU_WLOAD_NUM=8`
- target MXU32/INT4 configuration에서 한 logical Weight beat는 128 bytes이고 `LSU_WORD_SIZE=8` 기준 LMEM logical lane은 16개이다.
- `W_LMEM_DMA_CMD_BEATS = MXU_ROW / MXU_WLOAD_NUM = 32 / 8 = 4`여야 한다.
- build manifest와 simulation log에서 양쪽 모두 실제 elaborated value가 8인지 확인한다. config 이름만으로 추정하지 않는다.

IMPROVE는 `improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`를
사용한다. NAIVE에는 explicit WLOAD8 config인
`naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16_w8.sh`를 추가했다. 기존
suffix 없는 NAIVE config는 여전히 WLOAD4 compatibility/diagnostic 용도이며
최종 비교에는 사용하지 않는다.

### 1.2 지원 범위와 QBLK 제한

이 계획의 acceptance 범위는 **`QBLK={32,64,128}`**이다. `QBLK=16` 및
그보다 작은 값은 구현하거나 검증하지 않는다.

- MXU32 QROW에서 QBLK32는 K lane마다 Scale/ZP 한 값을 사용하며 현재
  resource bank당 32×16-bit storage와 일치한다.
- QBLK64/128 QROW은 하나의 32-column microtile 안에서 quant group이
  나뉘지 않는다. 따라서 현재 한-group S/Z datapath와 storage contract 안에
  있다. group boundary가 여러 microtile에 걸치는 address progression은
  backend별 reference로 검증한다.
- QBLK32/64/128 QCOL은 K 방향 group 수와 command count가 달라진다.
  Scale/ZP command bytes, register-write count, generation advance가 각 QBLK의
  실제 descriptor와 일치해야 한다.
- QBLK16 QROW은 한 microtile 안에 output-column group이 2개라서 별도
  storage/arithmetic 구조가 필요하지만, 사용자가 지원하지 않기로 확정했다.
  관련 numerical PASS, optimization 및 architecture 확장은 모두 범위 밖이다.

## 2. 핵심 결론

현재 `VX_gemm_unit_v2`를 `VX_gemm_node_naive`에 그대로 인스턴스화하면 목표를 달성할 수 없다.

이유는 `VX_gemm_unit_v2` 안에 다음 IMPROVE 전용 memory 가정이 함께 들어 있기 때문이다.

- 4-bank internal ACC SRAM
- fixed-latency ACC read scheduling
- immediate/history/early/nominal ACC forwarding
- ACC write와 output read port arbitration
- internal ACC address decode

반면 현재 NAIVE는 PSUM read/write와 final output을 LMEM port로 내보내며, LMEM response latency와 bank arbitration을 외부에서 경험한다.

따라서 목표 구조는 `VX_gemm_unit_v2`를 단순 복사하거나 NAIVE에 직접 연결하는 것이 아니라 다음과 같이 분리하는 것이다.

1. v2의 arithmetic 및 elastic transaction pipeline을 공통 compute core로 추출한다.
2. accumulator access를 backend-independent logical interface로 분리한다.
3. IMPROVE는 기존 fixed-latency timing을 그대로 보존하는 internal ACC
   fast-path adapter를 연결한다.
4. NAIVE는 variable-latency ready/valid를 지원하는 external
   PSUM/final-result LMEM adapter를 연결한다.
5. 두 node는 같은 packet-control generator와 같은 compute-core interface를 사용한다.

`VX_gemm_compute_core`는 첫 번째 근사로는 “`VX_gemm_unit_v2`에서 ACC MEM을 밖으로 뺀 것”이라고 이해할 수 있다. 다만 정확히는 물리 SRAM array만 이동하는 것이 아니다.

- 공통 core에 남김: pre-process, GEMM tree, correction, post-process arithmetic, elastic data/control movement, tree credit/result FIFO, generic W/S/Z consumer gate, transaction pending/retire
- ACC backend로 이동: physical SRAM/LMEM instance, bank/address decode, physical read/write arbitration, output-memory connection, backend 고유 response latency 처리
- interface 경계로 변경: logical channel은 read request/read response/write
  request로 분리하되, handshake 구현은 backend latency contract에 따라
  specialize한다.
- 위치를 설계 검토로 확정: immediate/history forwarding 중 backend와 무관한 transaction forwarding은 common core에 남기고, internal SRAM의 one-cycle-early/nominal scheduling처럼 physical latency에 의존하는 부분은 internal ACC adapter로 이동

### 2.1 IMPROVE fixed-latency fast path는 Hard Requirement

ACC interface 추출 때문에 IMPROVE에 추가 latency, throughput 저하, critical
path 증가 또는 불필요한 variable-latency queue/control이 생기면 안 된다.

- IMPROVE internal ACC는 기존처럼 request를 fixed schedule에 발행하고 정해진
  cycle에 response를 받는다.
- IMPROVE의 request `ready`는 compile-time constant 1로 제거하거나 interface에서
  생략할 수 있다. response도 fixed latency valid schedule을 사용한다.
- internal adapter에서는 variable response tag search, reorder queue, arbitrary
  response hold 및 LMEM용 RAW-order queue가 synthesized timing path에 남지 않아야
  한다.
- common core가 하나의 source file을 유지하더라도 `FIXED_LATENCY_ACC` 같은
  parameter/generate specialization으로 fixed path와 variable path를 elaboration
  단계에서 분리할 수 있다.
- IMPROVE fixed path는 refactor 전과 deterministic unit/node cycle 및 count가
  exact match해야 한다. XRT는 외부 DRAM stall noise 범위 외의 성능 하락을
  허용하지 않는다.

NAIVE LMEM adapter에서만 다음 기능을 활성화한다.

- read/write `ready` backpressure
- tagged variable-latency response join과 reorder
- bounded outstanding slots 및 response hold
- LMEM pending-write/read ordering fence

즉 공통화 대상은 arithmetic, packet metadata와 admission/retire 의미다. 서로
다른 physical memory latency를 억지로 동일한 runtime control에 태우는 것은
목표가 아니다. unified ready/valid 구현이 IMPROVE의 복잡도나 성능을 높이면
IMPROVE는 `valid(request) + fixed-latency response`, NAIVE는 full ready/valid를
사용하는 backend-specialized interface를 선택한다.

arithmetic/control pipeline은 동일하게 유지하되 external LMEM의 variable
latency만 bounded handshake/join 경로로 수용한다.

## 3. 용어와 경계

- **Compute core**: Input scaling, prealignment, GEMM tree, correction, integer-to-FP, output scaling 및 FP accumulation을 수행하는 공통 pipeline이다.
- **Packet control**: Input 한 transaction과 함께 이동하는 `gemm_input_ctrl_t` 계열 metadata이다.
- **Memory adapter**: 공통 compute core의 operand 및 accumulator request를 실제 LMEM, TMEM 또는 internal SRAM protocol로 변환하는 module이다.
- **ACC backend**: 이전 PSUM read, 새 PSUM/result write 및 필요 시 final-result 저장을 담당하는 memory-side 구현이다.
- **Generation**: W/S/Z physical bank에 설치된 logical LOAD 버전을 나타내는 monotonic counter이다.
- **Consumer event**: transaction이 실제 W/S/Z register 값을 읽은 handshake이다. 단순 command issue나 source fetch completion이 아니다.
- **Retire**: transaction의 최종 destination write가 실제 handshake되어 더 이상 pipeline/memory ownership을 갖지 않는 시점이다.
- **DMA primitive parity**: aligned/misaligned handling, response slot, reorder, request hold 및 backpressure 규칙을 공통 RTL 또는 공통 contract로 유지하는 것이다. DMA channel 수와 memory endpoint까지 같게 만드는 것은 아니다.

## 4. 현재 구조에서 확인된 사실

### 4.1 GEMM unit은 현재 서로 다름

```text
GEMM_NAIVE   -> VX_gemm_node_naive -> VX_gemm_unit
GEMM_IMPROVE -> VX_gemm_node       -> VX_gemm_unit_v2
```

NAIVE의 `VX_gemm_unit`은 command 시작 시 `gemm_unit_ctrl`을 한 번 latch하고, Input을 수락한 뒤에는 약 30-row compute burst를 내부에서 backpressure할 수 없다. PSUM startup watermark와 node의 output elastic queue가 이를 보완한다.

IMPROVE의 `VX_gemm_unit_v2`는 Input handshake마다 data와 `packet_ctrl`을 함께 받고, pre/tree/post region의 transaction state, FIFO credit 및 최종 write handshake로 pending/retire를 관리한다.

`2f950b12`의 elastic-backpressure 핵심 datapath 변경은 `VX_gemm_node.sv`와 `VX_gemm_unit_v2.sv`에 들어갔고 legacy NAIVE unit에는 들어가지 않았다.

### 4.2 global DMA 공용화는 상당 부분 이미 완료됨

다음 두 global DMA frontend는 topology가 다르지만 내부 worker로 모두 `VX_dma_unit`을 사용한다.

```text
NAIVE:   VX_dma_node   -> one aggregate VX_dma_unit -> DCache/LMEM
IMPROVE: VX_dma_engine -> per-channel VX_dma_unit    -> AXI/TMEM
```

따라서 `VX_dma_unit`, `VX_dma_unit_align`, `VX_dma_unit_misal`에 들어가는 generic 최적화는 이미 양쪽에 전파된다. 이 계층을 다시 복제하지 않는다.

### 4.3 NAIVE local DMA도 공용 core를 사용함

NAIVE Input/Scale-ZP/Output local DMA의 `VX_lmem_dma_misal`은 이미 `VX_dma_unit` policy wrapper이다.

- fixed transfer direction
- configurable outstanding response slots와 tag allocation
- tagged out-of-order response 수용
- destination backpressure
- zero-size no-op
- aligned/misaligned handling

기본 RTL contract는 8 slot이지만 현재 비교용 NAIVE th32 config는 `LMEM_DMA_RD_OUTSTANDING_SLOTS=16`을 사용한다. 구현과 test는 값을 8로 고정하지 않고 실제 parameter/tag-width contract를 따라야 한다.

다만 NAIVE Weight는 row-major gather 때문에 `VX_lmem_weight_gather_dma`를 사용한다. IMPROVE Input/Weight/Qparam은 multi-command overlap과 writer-fence를 가진 specialized local DMA를 사용한다. 이 차이는 layout/storage adapter의 차이로 남기되, queue/slot/backpressure invariant는 공통 primitive로 추출하거나 동일한 contract test로 묶어야 한다.

현재 NAIVE Weight path는 WLOAD8을 바로 수용하지 못한다.

- `VX_gemm_node_naive.sv`는 Input/Weight/SZ/Output tensor path가 모두 64 bytes, 8 lanes라고 assertion한다.
- `VX_lmem_weight_gather_dma.sv`도 `NUM_LANES==8`, `GEMM_BYTES==64`를 요구한다.
- WLOAD8에서는 Weight만 128 bytes/16 lanes가 되므로 이 assertion과 gather assembly를 parameter화해야 한다.
- 이 변경은 NAIVE의 row-major address 생성이나 LMEM mapping을 tile-major로 바꾸는 작업이 아니다. 동일 row-major data를 한 logical Weight transaction에 16개 LMEM word로 조립하는 width 일반화이다.

### 4.4 NAIVE PSUM prefetch 문제는 compute backpressure 부재의 결과

기존 NAIVE debug 결과에서는 PSUM response watermark를 약 30개보다 낮추면 LMEM response가 compute burst를 따라가지 못해 underflow가 발생했다. 이는 LMEM bandwidth만의 문제가 아니라, 이미 수락된 compute transaction을 PSUM availability에 맞춰 멈출 수 없기 때문이다.

공통 elastic core 전환 후에는 고정 30-response startup watermark가 correctness 조건이어서는 안 된다. 실제 ACC response reservation/availability가 transaction ready를 결정해야 한다.

### 4.5 cross-set PSUM response 조립이 남은 Phase 5 병목

LMEM ACC early prefetch와 same-set batching 뒤에는 224개 PSUM read의 request,
response, core response 및 write count가 모두 일치하고, RAW, slot 부족,
post-process full 및 request hold stall도 0 cycle이다. 그러나 현재
`VX_mem_bus_split`은 lane별 response FIFO 선두를 tag 비교 없이 하나의 wide
response로 합친다. 서로 다른 PSUM set의 lane response가 다른 순서로 돌아오면
두 transaction의 lane data가 섞일 수 있으므로 node는 기존 set의 response를
전부 drain한 뒤 다음 set을 발행한다.

해결 구조는 다음으로 고정한다.

- wide PSUM read를 받을 때 bounded physical response slot을 할당한다.
- LMEM lane request tag에는 physical slot ID를 넣는다. set bit를 별도로 tag에
  넣지 않고 slot metadata에 set, 원래 ACC tag 및 request ownership을 저장한다.
- lane response는 `slot_id`로 직접 `slot_data[slot][lane]`과 lane-valid bitmap에
  기록한다. associative tag search는 사용하지 않는다.
- 16개 lane이 모두 도착한 slot만 complete로 만든다.
- complete slot은 작은 tagged FIFO로 이동하고, 저장한 원래 ACC tag를 복원해
  `VX_gemm_acc_lmem`에 전달한다.
- completion 순서는 request 순서와 달라도 된다. common core의 tagged response
  join과 LMEM ACC logical slot이 transaction 결합을 담당한다.
- slot/FIFO가 가득 차면 새 wide request만 backpressure한다. 이미 수락한 lane
  request와 response는 drop하거나 재발행하지 않는다.
- pending/current PSUM write와 같은 address/set의 RAW fence는 유지한다. 제거하는
  것은 read-read cross-set drain fence뿐이다.

초기 parameter는 `PHYS_RESPONSE_SLOTS=4`, `RESPONSE_FIFO_DEPTH=2`로 한다. 한
accumulate command의 네 PSUM packet을 동시에 수용하는 최소 bounded 구성이다.
slot saturation이 실제 병목이면 동일 interface에서 8-slot A/B를 수행하되,
unbounded storage나 workload별 동적 크기는 허용하지 않는다.

## 5. 목표 구조

```text
                         common logical command metadata
                                      |
                       +--------------+--------------+
                       |                             |
                NAIVE packetizer              IMPROVE packetizer
                row-major address              tile-major address
                       |                             |
                       +---------- same packet_ctrl-+
                                      |
                                      v
                    +---------------------------------------+
                    | VX_gemm_compute_core                  |
                    |                                       |
Input stream ------>| elastic pre-process                   |
W/S/Z streams ----->| exact generation consumer gates      |
                    | fixed tree + reserved output slots    |
                    | elastic post-process                  |
                    | ACC request/response join             |
                    | transaction retire                    |
                    +------------------+--------------------+
                                       |
                              common ACC interface
                           req/rsp/write ready-valid
                                       |
                 +---------------------+---------------------+
                 |                                           |
       NAIVE LMEM ACC adapter                     IMPROVE internal ACC adapter
       logical prefetch/tag/RAW                     4-bank internal SRAM
                 |                                  fixed local latency
       PSUM OOO lane-response join
       4 response slots -> 2-entry tagged FIFO
       PSUM/final LMEM lanes
                 |                                           |
              LMEM arbiter                                  ACC SRAM
```

Operand ingress는 다음처럼 유지한다.

```text
NAIVE:
row-major DRAM -> VX_dma_node -> LMEM
  -> LMEM Input/Weight-gather/S/Z adapters -> common compute core

IMPROVE:
tile-major DRAM -> multi-channel VX_dma_engine -> TMEM
  -> TMEM overlap/wide-read adapters -> common compute core
```

### 5.1 FSM과 address generation은 서로 다르게 유지

두 backend의 FSM은 같은 logical GEMM 작업을 서로 다른 memory layout과 storage topology로 변환하므로 계산하는 주소가 의도적으로 다르다.

#### GEMM_NAIVE FSM/address generator

- row-major DRAM Input/Weight/Scale/ZP/Output 주소
- `VX_dma_node`가 사용할 DRAM↔LMEM descriptor 주소
- LMEM input/weight/qparam/output buffer 주소
- external PSUM LMEM read/write 주소
- final-result LMEM 주소
- row-major Weight gather의 base/stride/bound

#### GEMM_IMPROVE FSM/address generator

- tile-major DRAM Input/Weight/Scale/ZP/Output 주소
- DMA-channel/HBM stripe를 반영한 descriptor 주소
- TMEM slot/bank 주소
- internal ACC SRAM logical address
- tile-major partial-width Weight read 주소

따라서 `VX_gemm_fsm_naive`와 `VX_gemm_fsm`을 하나의 FSM으로 합치지 않는다. address 수식도 common compute core나 common packetizer로 이동하지 않는다.

공통 packetizer의 입력은 각 backend가 이미 계산한 normalized packet metadata이다.

```text
NAIVE FSM/address generator ----+
                                +--> normalized packet context
IMPROVE FSM/address generator --+      {acc_rd_addr, acc_wr_addr,
                                        final_output_addr, count,
                                        QDIR, W/S/Z bank+generation}
                                               |
                                               v
                                      common packetizer/core
```

공통 계층에서 address는 계산 대상이 아니라 transaction과 함께 보존해야 할 opaque metadata다. 공통 계층은 다음만 수행한다.

- 실제 Input handshake에서 packet index 진행
- data와 address/control lockstep 이동
- stall 중 address/control 안정성 보장
- 해당 address를 선택된 ACC backend request에 전달
- actual final write handshake로 completion 결정

두 backend의 address 값이 같은지를 검사하면 안 된다. 대신 각 backend 내부에서 다음을 검증한다.

- FSM/adapter가 생성한 address가 해당 backend의 layout reference와 일치
- packetizer 입력 address와 ACC request/write address가 transaction별로 일치
- stall 전후 address가 바뀌지 않음
- command의 packet 순서와 address progression이 각 backend 규칙에 맞음

## 6. 공통화할 contract

### 6.1 Input packet contract

모든 Input transaction은 실제 `valid && ready`에서 data와 다음 metadata를 동시에 수락한다.

```systemverilog
typedef struct packed {
    logic valid;
    logic acc_rd_en;
    logic acc_wr_en;
    logic final_output;
    logic [ACC_ADDR_W-1:0] acc_rd_addr;
    logic [ACC_ADDR_W-1:0] acc_wr_addr;
    logic [OUT_ADDR_W-1:0] final_output_addr;
    logic quant_dir;
    gemm_wreg_idx_t wreg_use_idx;
    gemm_qreg_idx_t sreg_use_idx;
    gemm_qreg_idx_t zreg_use_idx;
    logic [31:0] w_load_target;
    logic [31:0] s_load_target;
    logic [31:0] z_load_target;
    logic [31:0] work_seq;
    logic last;
    logic notify_on_writeback;
} gemm_compute_ctrl_t;
```

정확한 type 이름과 address 폭은 구현 시 정하되 의미는 두 backend에서 동일해야 한다.

### 6.2 Elastic movement contract

- `valid && !ready` 동안 data와 모든 metadata가 안정적이어야 한다.
- stage state는 해당 stage의 fire에서만 이동한다.
- fixed-latency tree 내부만 valid shift를 허용한다.
- tree 진입 전에 bounded output slot을 예약해야 한다.
- post-process가 멈추면 pre-process도 bounded credit을 통해 멈춰야 한다.
- data와 control을 서로 독립적으로 shift하지 않는다.
- reset 뒤 stale valid, stale response 및 ghost write가 없어야 한다.

### 6.3 ACC backend contract

새 ready/valid interface는 최소한 다음 channel을 제공한다.

```text
read request : valid, ready, tag, address
read response: valid, ready, tag, data
write request: valid, ready, tag, address, data, final_output, last
```

필수 규칙은 다음과 같다.

- read request를 수락하지 않았으면 response가 오면 안 된다.
- response는 tag로 원 transaction과 결합한다.
- response backpressure 중 tag/data가 안정적이어야 한다.
- write completion은 실제 destination handshake에서만 발생한다.
- 같은 address의 pending write/read hazard는 공통 forwarding 또는 adapter ordering으로 해결한다.
- adapter가 임의 latency를 가질 수 있으므로 core는 fixed response latency를 correctness 전제로 삼지 않는다.
- 한 transaction이 ACC response 또는 result slot을 예약하지 못하면 Input 또는 해당 elastic stage를 backpressure한다.
- physical LMEM lane response는 slot ID로 조립하고 모든 active lane이 도착하기
  전에는 wide response를 만들지 않는다.
- physical response slot은 FIFO push 뒤에만 재사용한다. 같은 slot의 duplicate
  lane response, free-slot response 및 reuse-before-complete는 assertion failure다.
- tagged FIFO가 `valid && !ready`이면 tag/data를 유지한다. FIFO가 full이면
  completed slot을 보존하고 새 physical request를 bounded하게 backpressure한다.

### 6.4 W/S/Z readiness contract

두 backend 모두 bank별 exact generation counter를 compute core에 제공한다.

- source fetch completion과 register install completion을 구분한다.
- consumer는 `loaded_generation == expected_generation`의 registered view에서만 진행한다.
- W/S/Z register overwrite는 이전 generation의 마지막 actual consumer까지 차단한다.
- old-version read와 next-generation write의 same-cycle handoff 규칙은 양쪽에서 동일하다.
- consume event는 실제 QDIR별 resource-read handshake에서 발생한다.

NAIVE에는 TMEM readiness scheduler를 복사하지 않는다. Scheduler는 TMEM arbitration 정책이므로 memory-system 차이로 유지한다. 단, scheduler 유무와 관계없이 compute core가 보는 exact generation/consumer contract는 동일해야 한다.

## 7. DMA parity 정책

### 7.1 동일 RTL로 유지할 부분

다음 최적화는 `VX_dma_unit` 계층에만 구현하고 양쪽 frontend가 그대로 재사용한다.

- aligned/misaligned path 선택
- request enqueue와 held-valid stability
- outstanding slot/tag allocation
- response reordering과 in-order retirement
- response-to-write buffering
- destination backpressure
- zero-size command completion
- padding/byte-enable correctness
- lookahead prepare/activate protocol 중 topology 독립 부분

### 7.2 topology별로 다르게 유지할 부분

- `VX_dma_node` job frontend와 shared DCache routing
- `VX_dma_engine` channel replication과 AXI routing
- channel/bank address remap
- LMEM/TMEM physical arbitration
- row-major Weight gather
- tile-major partial-width wide read
- TMEM readiness priority
- NAIVE LMEM은 기존 ready/valid arbiter만 사용하며 TMEM과 같은 readiness,
  deadline 또는 urgency scheduler를 추가하지 않음
- Output DMA와 final-result write는 operand ingress와 방향, completion authority가
  다르므로 첫 local operand DMA 공통화 범위에서 제외

### 7.3 local operand DMA 공통 primitive

현재 IMPROVE overlap DMA의 descriptor FIFO/response-slot logic과 NAIVE local
DMA/gather logic이 분리되어 있다. 그러나 모든 local DMA를 하나의 거대한
universal module로 합치지 않는다. 이미 검증된 contiguous transfer는 기존
`VX_dma_unit` 계층을 재사용하고, 특수 operand stream에서 반복되는 command,
logical-beat 및 ordered-install control만 별도 primitive로 추출한다.

#### 7.3.1 목표 DMA hierarchy

```text
GEMM DMA hierarchy
|
+-- Common generic DMA library
|   |
|   +-- VX_dma_unit                         [existing]
|   |   +-- VX_dma_unit_align
|   |   `-- VX_dma_unit_misal
|   |
|   +-- VX_gemm_stream_dma_queue            [new]
|   |   +-- descriptor FIFO
|   |   +-- logical response-slot table
|   |   +-- independent fetch/install heads
|   |   +-- fetch/install progress counters
|   |   +-- ordered destination drain
|   |   `-- writer-release gate
|   |
|   +-- VX_gemm_dma_fetch_if                [new]
|   `-- VX_gemm_dma_sink_if                 [new]
|
+-- GEMM_NAIVE
|   |
|   +-- Global DMA
|   |   `-- VX_dma_node
|   |       `-- VX_dma_unit
|   |
|   +-- Local operand DMA
|   |   +-- Input
|   |   |   `-- VX_lmem_dma_misal
|   |   |       `-- VX_dma_unit
|   |   +-- Weight
|   |   |   `-- VX_lmem_weight_gather_dma
|   |   |       +-- VX_gemm_stream_dma_queue
|   |   |       `-- VX_gemm_lmem_weight_source
|   |   |           `-- 16-lane response assembly [NAIVE-only]
|   |   +-- Scale
|   |   |   `-- VX_lmem_dma_misal -> VX_dma_unit
|   |   `-- Zero-point
|   |       `-- VX_lmem_dma_misal -> VX_dma_unit
|   |
|   +-- Output DMA                          [separate]
|   |   `-- VX_lmem_dma_misal -> VX_dma_unit
|   |
|   `-- existing LMEM arbiter
|       `-- ready/valid arbitration only; no bank scheduler
|
`-- GEMM_IMPROVE
    |
    +-- Global DMA
    |   `-- VX_dma_engine
    |       `-- per-channel VX_dma_unit
    |
    `-- VX_tmem_subsystem
        +-- TMEM readiness scheduler         [IMPROVE-only]
        +-- TMEM bank arbiter                [IMPROVE-only]
        +-- Input DMA
        |   +-- VX_gemm_stream_dma_queue
        |   `-- VX_gemm_tmem_contig_source
        +-- Weight DMA
        |   +-- VX_gemm_stream_dma_queue
        |   `-- VX_gemm_tmem_weight_source
        |       `-- VX_tmem_wide_read_switch [complete 128B response]
        +-- Scale DMA
        |   +-- VX_gemm_stream_dma_queue
        |   `-- VX_gemm_tmem_contig_source
        +-- Zero-point DMA
        |   +-- VX_gemm_stream_dma_queue
        |   `-- VX_gemm_tmem_contig_source
        `-- Output DMA                       [existing separate path]
```

`VX_tmem_*_dma`는 목표 역할 이름이다. 초기 migration에서는 외부 hierarchy와
test XMR을 깨지 않도록 기존 `VX_lmem_dma_input_overlap`,
`VX_lmem_dma_weight_overlap`, `VX_lmem_dma_qparam_overlap` 이름을 유지하고
내부 구현만 공통 primitive로 교체한다. 최종 rename은 Phase 7 cleanup에서
별도 수행한다.

#### 7.3.2 `VX_gemm_stream_dma_queue` 책임

이 primitive는 LMEM/TMEM physical address를 계산하거나 bank를 선택하지 않는다.
backend FSM/source adapter가 만든 logical fetch를 순서대로 관리한다.

- 최대 `CMD_FIFO_DEPTH`개의 descriptor 저장
- fetch command head와 install command head를 독립적으로 관리
- logical response slot에 `{command, sequence, beat}` 소유권 부여
- source request가 `valid && !ready`일 때 slot/context 불변 보장
- 완성된 logical beat를 tag로 capture
- source 응답 순서와 무관하게 destination에는 command/beat 순서대로 drain
- descriptor별 `requested`, `fetched`, `installed` beat count 제공
- `fetch_complete`와 `install_complete`를 별도 event로 제공
- Input은 writer release를 항상 허용하고 actual destination handshake를 admission
  fence로 사용
- W/S/Z는 외부의 registered `writer_release_i` 이후에만 install
- scheduler policy를 포함하지 않고, IMPROVE scheduler가 사용할 progress만 export

공통 descriptor는 sequence, work sequence, total beats, destination metadata,
writer-wait metadata와 backend-private opaque metadata를 저장한다. row-major,
tile-major, QDIR, LMEM lane 및 TMEM bank 의미는 공통 queue가 해석하지 않는다.

#### 7.3.3 Weight response assembly boundary 확정

`VX_tmem_wide_read_switch` audit 결과 IMPROVE Weight에는 별도 공통 fragment
join을 추가하지 않는다.

- target WLOAD8에서 `DATA_SIZE=64B`, `GEMM_WEIGHT_DATA_SIZE=128B`이므로
  `BANKS_PER_BEAT=2`이다.
- switch가 128B request를 두 개의 64B TMEM bank read로 분할한다.
- switch 내부 context가 bank mask, issued mask, response-seen mask와 bank별
  response data를 소유한다.
- 대상 bank 두 개의 response가 모두 도착한 뒤에만 upstream `rsp_valid`를
  발생시키며, 128B data와 original tag를 한 번에 반환한다.
- 여러 outstanding context의 upstream response도 request acceptance 순서로
  retire한다.

따라서 `VX_lmem_dma_weight_overlap`과 향후 공통 queue가 받는 응답은 이미
완성된 logical 128B Weight beat이다. IMPROVE 쪽에 또 fragment join을 넣으면
동일한 조립과 mask tracking을 중복하게 된다.

NAIVE Weight의 16개 LMEM lane response 조립은 row-major gather source에만
필요하다. 이 logic은 `VX_gemm_lmem_weight_source` 역할 내부에 backend-specific
logic으로 유지한다. 별도 파일로 분리하더라도 공통 primitive가 아니라
`VX_gemm_lmem_weight_join` 같은 NAIVE-private helper로 취급한다.

#### 7.3.4 backend별 사용 결정

| 경로 | 공통 queue | logical beat assembly owner | 별도 유지할 부분 |
|---|---:|---|---|
| NAIVE Input | 사용 안 함 | `VX_dma_unit` | `VX_lmem_dma_misal -> VX_dma_unit` |
| NAIVE Weight | 사용 | NAIVE gather source, 16 lanes | row-major base/stride/lane request |
| NAIVE Scale/ZP | 사용 안 함 | `VX_dma_unit` | `VX_lmem_dma_misal -> VX_dma_unit`, opcode별 destination |
| NAIVE Output | 범위 밖 | 기존 output DMA | 기존 DIR=1/output completion path |
| IMPROVE Input | 사용 | ordinary TMEM switch | TMEM source mapping과 scheduler gate |
| IMPROVE Weight | 사용 | `VX_tmem_wide_read_switch` | TMEM 2-bank read와 bank mapping |
| IMPROVE Scale/ZP | 사용 | ordinary TMEM switch | 독립 TMEM source와 register destination |
| IMPROVE Output | 범위 밖 | 기존 output DMA | 기존 TMEM output path |

NAIVE Input/S/Z를 새 queue로 즉시 바꾸지 않는 이유는 기존 `VX_dma_unit`이 이미
misalignment, outstanding/tag, response reorder와 destination backpressure를
제공하기 때문이다. 이를 다시 구현하거나 `VX_dma_unit` 내부를 동시에 크게
분해하지 않는다.

#### 7.3.5 LMEM scheduler 비도입과 bounded prefetch

NAIVE local DMA에는 readiness, deadline, urgency 또는 priority scheduler를
추가하지 않는다. 공통 queue에는 scheduler가 없으며 NAIVE source는 다음
조건으로만 request를 발행한다.

- free logical response slot 존재
- instance별 outstanding limit 이하
- source adapter와 LMEM arbiter의 normal ready/valid handshake
- destination generation/lifetime fence 만족

첫 migration의 NAIVE Weight 설정은 `CMD_FIFO_DEPTH=1`로 하여 기존 command
schedule을 보존하고, 기존 `RD_PREFETCH_DEPTH` 범위의 in-command group prefetch만
허용한다. XRT/FSDB에서 Weight source-empty가 실제 병목으로 확인될 때만
`CMD_FIFO_DEPTH=2` cross-command prefetch를 별도 성능 실험으로 연다. 이 경우도
LMEM priority를 추가하지 않고 기존 arbiter의 bounded fairness를 사용한다.

IMPROVE는 기존 `CMD_FIFO_DEPTH=4`, response-slot budget 및 TMEM scheduler를
유지한다. scheduler의 issue enable/priority hold는 TMEM source adapter가
소유하고, 공통 queue는 descriptor progress만 제공한다.

#### 7.3.6 추출 범위 제한

초기 migration에서 이 추출이 너무 큰 위험이면 기능을 복사하지 않는다.
먼저 기존 NAIVE DMA를 common compute interface에 연결하고, 독립 phase에서
IMPROVE overlap core와 NAIVE Weight gather의 실제 중복만 치환한다. 동일한
algorithm을 두 파일에 복제하는 방식은 최종 상태로 허용하지 않는다.

Output DMA와 ACC LMEM adapter는 local operand ingress primitive에 포함하지
않는다. 방향, final completion 및 ownership authority가 다르므로 필요하다면
별도 계획에서 공통화한다.

## 8. 파일별 수정 계획

### 8.1 공용 package/interface

#### `hw/rtl/VX_gpu_pkg.sv`

- backend 독립적인 compute packet type 정의
- ACC request/response tag width와 transaction ID type 정의
- W/S/Z generation type을 공통화
- 기존 `gemm_input_ctrl_t`와 중복을 최소화하고, 가능하면 호환 확장
- layout, TMEM bank 또는 LMEM lane 수를 공통 type에 넣지 않음

#### 신규 `hw/rtl/core/gemm/VX_gemm_acc_if.sv`

- read request/response/write request channel 정의
- 각 channel의 independent ready/valid 정의
- tag, address, data, final/last metadata 정의
- modport 방향과 stalled-payload contract 정의

#### `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`

- packet admission, generation level, consume event, pipeline empty 및 completion 의미를 backend 독립적으로 정리
- scheduler-only feedback은 wrapper/node interface로 분리하거나 명확히 optional로 유지
- memory adapter가 compute ready 권한을 우회하지 못하도록 authority 명시

### 8.2 공통 compute core

#### 신규 `hw/rtl/core/gemm/VX_gemm_compute_core.sv`

- 현재 `VX_gemm_unit_v2`의 pre/tree/post arithmetic과 elastic control 이동 추출
- Input data와 packet metadata를 lockstep으로 이동
- tree output credit/FIFO contract 유지
- exact W/S/Z consumer gate 및 consume event 유지
- accumulator operand request와 result write를 `VX_gemm_acc_if`로 교체
- variable-latency ACC response를 기다리는 elastic join 추가
- final write handshake에서 retire/completion 생성
- layout, LMEM, TMEM, DMA channel을 참조하지 않음

#### `hw/rtl/core/gemm/VX_gemm_unit_v2.sv`

- 외부 module 이름과 IMPROVE integration을 유지하는 wrapper로 전환
- common compute core + internal ACC adapter 인스턴스화
- 단계별 migration 동안 기존 v2와 cycle/numerical equivalence 유지
- migration 완료 전에는 unrelated scheduler/operand lifetime logic을 동시에 변경하지 않음

### 8.3 ACC adapter

#### 신규 `hw/rtl/core/gemm/VX_gemm_acc_internal.sv`

- 현재 v2의 4-bank ACC SRAM, address decode 및 output read 기능 소유
- common ACC interface에 fixed-latency response 제공
- immediate/history forwarding이 backend 독립이면 core 쪽에 유지하고, SRAM-specific early/nominal scheduling만 adapter에 둠
- 기존 IMPROVE unit test의 read/write latency와 output 결과를 보존

#### 신규 `hw/rtl/core/gemm/VX_gemm_acc_lmem.sv`

- 기존 NAIVE `psum_rd_lmem_bus_if`, `psum_wr_lmem_bus_if`, `final_lmem_bus_if` 연결 유지
- logical PSUM request/tag/prefetch는 유지하고 physical lane split/response 조립은
  전용 OOO join에 위임
- read transaction tag/order queue와 response holding 구현
- LMEM response latency와 bank conflict를 common core ready에 반영
- non-final result는 PSUM LMEM, final result는 기존 final-output LMEM 경로에 write
- pending write와 같은 set/address의 read ordering 보존
- 고정 약 30-response startup watermark를 correctness 조건에서 제거

#### 신규 `hw/rtl/core/gemm/VX_gemm_psum_read_ooo_join.sv`

- `VX_gemm_node_naive`의 PSUM read 경로에서 기존 `psum_rd_lane_split`만 치환
- wide logical request를 bounded physical slot에 capture하고 16개 64-bit LMEM
  lane request로 scatter
- physical slot ID를 lane tag에 기록하고 lane response를 slot/bitmap으로 OOO 조립
- slot metadata에 원래 ACC tag와 set을 보존하고 complete 시 tag를 복원
- complete slot을 2-entry tagged FIFO로 넘겨 LMEM response와 ACC adapter를 분리
- Input/S/Z/output/final/PSUM-write의 generic `VX_mem_bus_split`은 변경하지 않음
- per-lane LMEM arbiter와 pending/current PSUM-write fence는 node에 유지
- tagged OOO focused test가 통과한 뒤에만 node와 `VX_gemm_acc_lmem`의
  same-active-set issue 제한 및 cross-set read drain counter를 제거

### 8.4 공통 packetizer

#### 신규 `hw/rtl/core/gemm/VX_gemm_input_packetizer.sv`

- command context FIFO
- 실제 Input handshake 기반 packet index 증가
- ACC read/write/final-output address 생성 hook
- QDIR, W/S/Z bank와 generation target 전달
- exact `last`, `notify_on_writeback`, `work_seq` 생성
- ingress completion과 final writeback completion 분리

address 생성 자체는 backend-specific FSM/address generator의 입력으로 받는다.

- NAIVE: row-major command와 external PSUM/final LMEM address
- IMPROVE: tile-major command와 internal ACC address

packetizer는 layout 수식을 직접 포함하지 않는다.

### 8.5 NAIVE node/control

#### `hw/rtl/core/gemm/VX_gemm_node_naive.sv`

- legacy `VX_gemm_unit` 대신 common compute wrapper 연결
- 기존 LMEM lane, Weight gather, PSUM/final-result arbiter 연결 유지
- Input/Weight/S/Z stream을 common unit port 형태로 정리
- Scale와 ZP의 logical completion/generation을 독립적으로 제공
- 기존 output write queue는 LMEM adapter ownership으로 이동하거나 하나의 명확한 위치에만 유지
- duplicate buffering과 두 개의 completion authority 제거

#### `hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv`

- row-major command ordering과 child routing은 유지
- unit `start/idle/done` 의존을 packet-context enqueue/final-retire contract로 교체
- command queue payload는 shared logical metadata를 사용
- command done은 예상 latency가 아니라 actual final write/notify handshake로 결정

#### `hw/rtl/core/gemm/VX_gemm_fsm_naive.sv`

- row-major descriptor/address 생성 유지
- Input command에 W/S/Z bank와 exact generation target 추가
- legacy global `gemm_unit_ctrl` 전용 flag 제거
- layout과 tile loop는 변경하지 않음

#### `hw/rtl/core/gemm/VX_gemm_fsm.sv`

- tile-major descriptor/TMEM/internal-ACC address 생성 유지
- NAIVE row-major address 분기를 추가하지 않음
- common packetizer에 normalized address/control을 전달하는 연결만 정리
- 기존 TMEM/HBM topology와 scheduler command metadata 유지

#### `hw/rtl/core/gemm/VX_gemm_sync_naive.sv`

- 기존 row-major command dependency는 유지
- unit completion endpoint 변경에 필요한 최소 수정만 수행
- TMEM scheduler/RID 정책을 그대로 복사하지 않음

### 8.6 local operand DMA primitive와 backend adapter

#### 신규 `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv`

- descriptor FIFO와 독립 fetch/install head 구현
- logical response-slot의 command/sequence/beat ownership 관리
- source request와 destination drain의 valid/payload hold contract 보장
- out-of-order source response capture와 in-order destination drain
- requested/fetched/installed count와 fetch/install completion 분리
- registered writer-release 입력으로 W/S/Z overwrite 차단
- memory address, lane, bank, QDIR 또는 scheduler priority 계산 금지
- `CMD_FIFO_DEPTH={1,4}`와 기존 response-slot depth를 parameter로 지원

#### 신규 `hw/rtl/core/gemm/VX_gemm_dma_fetch_if.sv`

- queue에서 source adapter로 보내는 fetch request 정의
- slot, command sequence, beat index와 backend-private source metadata 전달
- source adapter에서 queue로 보내는 completed logical response와 slot tag 정의
- stalled request/response payload stability 명시
- scheduler priority는 포함하지 않음; IMPROVE TMEM source wrapper의 별도 sideband로 유지

#### 신규 `hw/rtl/core/gemm/VX_gemm_dma_sink_if.sv`

- Input/W/S/Z destination의 logical write ready/valid 정의
- command sequence, beat index, destination metadata와 data 전달
- actual sink handshake만 install progress와 completion을 증가시키도록 명시

#### `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv`

- request/response backpressure 중 payload와 row context 안정성 보장
- 여러 row response의 logical Weight write 조립 완료를 exact generation write와 연결
- 외부 module/port contract를 유지하면서 내부 command/slot/drain을
  `VX_gemm_stream_dma_queue`로 치환
- lane response bitmap/data assembly와 row/lane request 생성을
  `VX_gemm_lmem_weight_source` 역할의 backend-private logic에 유지
- 별도 helper module로 분리할 경우에도 NAIVE-private module로 두고 공통
  stream queue에 LMEM lane 수나 fragment mask를 노출하지 않음
- row-major gather 수식과 LMEM lane mapping 유지
- 고정 `NUM_LANES==8`, `GEMM_BYTES==64` 가정을 제거하고 `GEMM_WEIGHT_DATA_SIZE/LSU_WORD_SIZE`에서 폭을 유도
- target WLOAD8에서 128-byte Weight beat를 16개의 8-byte LMEM lane response로 정확히 조립
- lane별 request/response bitmap, slot tag 및 done 조건을 16 lanes까지 안전하게 확장
- WLOAD8의 logical command당 `W_LMEM_DMA_CMD_BEATS=4` request-beat contract를 assertion과 directed test로 확인
- 첫 migration은 `CMD_FIFO_DEPTH=1`로 기존 schedule과 in-command prefetch를 보존
- depth 2는 FSDB가 Weight source-empty 병목을 증명한 뒤 별도 실험으로만 허용

#### `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`

- base wrapper의 공용 `VX_dma_unit` 사용 유지
- NAIVE Input/S/Z/output은 새 stream queue로 이동하지 않음
- common packet/stream contract에 필요한 completion/progress sideband만 최소 확장
- IMPROVE specialized overlap module과 base wrapper를 무리하게 하나의 거대 module로 합치지 않음
- Output DIR=1 path는 operand queue 공통화 범위 밖으로 유지

#### 기존 `VX_lmem_dma_input_overlap`, `VX_lmem_dma_weight_overlap`,
`VX_lmem_dma_qparam_overlap`

- initial migration에서는 외부 module 이름, port, debug hierarchy를 유지
- duplicated descriptor FIFO/slot/drain logic을 `VX_gemm_stream_dma_queue`로 치환
- Input과 qparam은 ordinary TMEM switch가 반환한 complete beat를 queue에 전달
- Weight는 `VX_tmem_wide_read_switch`가 두 64B bank response를 조립한 complete
  128B beat를 queue에 전달하며 추가 fragment join을 두지 않음
- TMEM scheduler progress 출력은 공통 queue count에서 생성
- priority/urgency hold와 bank request gate는 TMEM source adapter에 유지
- IMPROVE의 기존 `CMD_FIFO_DEPTH=4`, response-slot 수와 same-cycle recycle timing 유지

#### `hw/rtl/mem/VX_tmem_subsystem.sv`

- 공통 queue를 직접 scheduler로 만들지 않음
- 기존 microtile readiness scheduler와 bank priority wiring 유지
- source adapter의 scheduler gate/priority hold와 queue의 progress interface 연결
- refactor 전후 per-source request/grant/loss와 total cycle equivalence 확인

#### `hw/rtl/core/gemm/VX_gemm_node_naive.sv`

- Input/SZ/Output의 기존 64-byte/8-lane contract는 유지
- Weight만 parameter-derived 128-byte/16-lane WLOAD8 contract를 허용하도록 tensor-width assertion 수정
- 16 logical Weight lanes가 32 LMEM ports에 매핑될 때 wrap, lane offset 및 다른 LMEM client와의 arbitration이 기존 row-major 의미를 보존하는지 확인
- LMEM scheduler, urgency tier 또는 operand deadline priority wiring을 추가하지 않음

#### 신규 `configs/naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16_w8.sh`

- 기존 NAIVE config의 LMEM, DCache, `VX_dma_node` 및 row-major 조건을 그대로 유지
- `-DMXU_WLOAD_NUM=8`을 명시하며 default WLOAD4에 의존하지 않음
- 최종 NAIVE/IMPROVE 비교에서는 이 config와 기존 IMPROVE `_w8.sh`만 사용
- 기존 WLOAD4 config는 호환성 진단에만 사용할 수 있으며 acceptance/performance 숫자에는 사용하지 않음

### 8.7 legacy unit

#### `hw/rtl/core/gemm/VX_gemm_unit.sv`

- migration 중 reference와 rollback용으로 유지
- 새로운 backpressure 기능을 v1에 별도로 복제하지 않음
- bring-up용 compile parameter로만 선택 가능하게 하고, 최종 기본 NAIVE 경로에서는 제거
- migration 완료 뒤 삭제 여부는 별도 cleanup 결정으로 남김

## 9. 구현 단계

### 9.0 현재 phase 상태

| Phase | 상태 | 확보한 증거 / 남은 작업 |
|---|---|---|
| 0 WLOAD8 | 완료 | NAIVE 128B/16-lane gather, command당 4 beats; legacy XRT M4 QCOL/QROW 4900/15303 cycles |
| 1 internal ACC 분리 | 완료 | IMPROVE focused/node/XRT equivalence |
| 2 common core 추출 | 완료 | deterministic node exact equivalence; XRT external-stall noise ±2-cycle gate |
| 3 variable ACC | 완료 | latency 1..15, reorder, RAW, reset, bounded 4-read/2-write queue stress PASS |
| 4 LMEM ACC adapter | 완료 | 8 read slots, tag translation/reorder, final FP16 conversion PASS; legacy baseline exact 유지 |
| 5 NAIVE 통합 | 완료 | 4-slot lane-response OOO join + 2-entry tagged FIFO focused/integration PASS; M4 QCOL XRT/FSDB 4738 cycle, cross-set outstanding와 lane/tag ownership exact; 지원 QBLK 및 required matrix PASS |
| 6 DMA parity | 완료 | Steps 1~13 closed: five bounded shared-queue instances, exact IMPROVE and NAIVE acceptance, NAIVE depth1 retained because the depth2 source-empty precondition is absent |
| 7 구조 고정 | cleanup 구현/정적 검증 완료, final regression 대기 | two dead overlap module bodies and unreferenced aliases removed; common-core NAIVE manifest no longer lists v1 unit sources, while production legacy wrappers/tests remain intact |

### Phase 0: WLOAD8 readiness와 parity baseline 고정

#### Phase 0A: current-state audit

1. 현재 HEAD의 NAIVE config가 WLOAD를 명시하지 않아 WLOAD4 default를 사용하는 사실을 manifest에 기록한다.
2. NAIVE를 `MXU_WLOAD_NUM=8`로 compile/elaborate하여 현재의 64-byte/8-lane assertion을 재현하고 정확한 blocker를 남긴다.
3. 기존 WLOAD4 결과는 historical diagnostic으로만 보존하고 최종 baseline 또는 성능 비교 기준으로 사용하지 않는다.

이 sub-phase에서는 RTL 동작을 바꾸지 않는다.

#### Phase 0B: isolated NAIVE WLOAD8 enablement

1. NAIVE 전용 explicit WLOAD8 config를 추가한다.
2. `VX_gemm_node_naive`의 Weight width/lane assertion과 LMEM lane mapping을 parameter화한다.
3. `VX_lmem_weight_gather_dma`를 128-byte/16-lane logical Weight transaction에 맞게 일반화한다.
4. 이때 compute unit, FSM address 계산식, LMEM topology 및 DMA-node 연결은 변경하지 않는다.
5. WLOAD8 gather unittest와 legacy NAIVE node numerical test가 통과한 뒤 이 상태를 NAIVE pre-migration baseline으로 고정한다.

#### Phase 0C: comparable baseline capture

1. NAIVE/IMPROVE 모두 `MXU_WLOAD_NUM=8`인 fresh VCS baseline을 수집한다.
2. historical baseline은 `QBLK=32`로 유지하고, 최종 support matrix는
   `QBLK={32,64,128}`로 확장한다. 모든 경우 `M={4,32,64,128,256}`,
   `N=K=256`, `QDIR={QCOL,QROW}`를 기록한다.
3. NAIVE의 Input accept, PSUM request/response, compute result, LMEM write 및 done count를 기록한다.
4. IMPROVE의 packet admission, compute fire, ACC write 및 retire count를 기록한다.
5. 두 configuration의 arithmetic mode, MXU size, WLOAD=8 및 app ABI를 manifest에 남긴다.
6. 공통 core에 포함할 신호와 memory adapter에 남길 신호를 checklist로 고정한다.
7. NAIVE와 IMPROVE의 address trace를 별도로 저장하고 각 layout reference와 대조한다. 두 backend 사이의 address equality는 요구하지 않는다.

### Phase 1: v2 내부 ACC memory 분리

1. `VX_gemm_acc_if`를 추가한다.
2. 현재 v2 internal ACC SRAM을 `VX_gemm_acc_internal`로 이동한다.
3. `VX_gemm_unit_v2` 외부 behavior와 hierarchy wrapper를 유지한다.
4. 기존 `gemm_unit_v2`, backpressure, node 및 XRT-VCS 결과가 cycle-accurate하게 동일한지 확인한다.

이 phase가 통과하기 전에는 NAIVE를 연결하지 않는다.

### Phase 2: 공통 compute core 추출

1. v2의 arithmetic 및 elastic region을 `VX_gemm_compute_core`로 이동한다.
2. internal ACC adapter와 common interface로 연결한다.
3. data/control lockstep, tree credit, operand consumer 및 retire assertion을 공통 core에 둔다.
4. IMPROVE regression이 Phase 1 baseline과 동일한지 확인한다.

성공 기준은 refactor 전후 IMPROVE numerical/cycle/count 동일성이다.

### Phase 3: variable-latency ACC contract 검증

1. unittest용 programmable-latency ACC adapter를 만든다.
2. read latency, response ordering 및 write backpressure를 randomize한다.
3. ACC response가 늦을 때 post-process가 멈추고 tree credit을 통해 Input까지 안전하게 backpressure되는지 확인한다.
4. response hold, forwarding, reset 및 same-address RAW를 검증한다.

이 phase가 통과해야 external LMEM adapter를 연결할 수 있다.

### Phase 4: NAIVE LMEM ACC adapter 구현

1. 기존 PSUM read/write/final paths를 `VX_gemm_acc_lmem` 뒤로 이동한다.
2. LMEM request tag와 transaction ordering queue를 연결한다.
3. existing lane split, bank-set ordering 및 pending-write fence를 보존한다.
4. common core가 PSUM availability에 맞춰 stall하도록 연결한다.
5. 약 30-response startup watermark 없이 small/large command가 동작하는지 확인한다.
6. legacy unit과 동일 stimulus를 lockstep numerical 비교한다.

### Phase 5: NAIVE packetizer와 common unit 통합

1. NAIVE command를 common packet context로 변환한다.
2. 실제 Input handshake에서 packet index를 진행한다.
3. W/S/Z generation target과 QDIR metadata를 transaction에 포함한다.
4. command completion을 final LMEM write handshake에 연결한다.
5. bring-up parameter로 legacy/common unit A/B가 가능하게 한다.
6. common 경로가 gate를 통과하면 common unit을 NAIVE 기본값으로 전환한다.
7. `VX_gemm_psum_read_ooo_join`을 추가하고 physical response slot 4개에서 lane별
   response를 slot ID로 조립한다.
8. complete slot 뒤에 2-entry tagged FIFO를 두고 원래 ACC tag를 복원한다.
9. 신규 모듈은 `VX_gemm_node_naive`의 PSUM read `VX_mem_bus_split`만 치환한다.
   generic splitter, IMPROVE, 다른 operand DMA 및 PSUM write/final path는 바꾸지
   않는다.
10. focused OOO test에서 alternating set `0,1,0,1`, lane skew/reorder, FIFO
    backpressure, slot full, same-cycle complete/push, reset 및 duplicate/stale tag를
    검증한다.
11. focused test 통과 뒤에만 read-read cross-set drain fence와 adapter의
    same-active-set issue restriction을 제거한다. write-read RAW와 pending/current
    write fence는 유지한다.
12. M4 QCOL을 fresh XRT/FSDB로 재실행하여 numerical/count exact,
    cross-set outstanding>0, lane mixing 0 및 `total_cycles<=4900`을 요구한다.
    통과 전에는 Phase 6으로 넘어가지 않는다.

### Phase 6: operand DMA control parity

1. Phase 0B에서 확보한 WLOAD8/16-lane Weight gather 기능과 Phase 5의 exact
   request/response/write/generation count를 baseline으로 고정한다.
2. Phase 5 XRT/FSDB에서 실제 남은 stall을 `source-empty`, `response-wait`,
   `install-wait`, `ACC-wait`로 분류하고 per-source outstanding/slot occupancy를
   기록한다.
3. `VX_dma_unit`, `VX_dma_unit_align`, `VX_dma_unit_misal`의 generic fix가 두
   backend에 이미 공유되는지 audit한다. NAIVE contiguous Input/S/Z/output은
   이 경로에 그대로 남긴다.
4. `VX_gemm_dma_fetch_if`, `VX_gemm_dma_sink_if`와 interface-only protocol
   assertion을 먼저 추가한다. 이 단계에서는 functional schedule과 cycle을
   바꾸지 않는다.
5. `VX_gemm_stream_dma_queue` focused unittest를 먼저 구현한다. depth 1/4,
   response reorder, same-cycle pop/enqueue, writer fence, held valid, reset 및
   counter wrap을 source adapter 없이 검증한다.
6. `VX_tmem_wide_read_switch` directed test에서 WLOAD8 128B request가 두 64B
   bank response를 모두 받은 뒤에만 one logical response로 retire하는 현재
   boundary를 고정한다. 별도 IMPROVE fragment join은 만들지 않는다.
7. IMPROVE Input overlap DMA의 duplicated descriptor/slot/drain logic을 공통
   queue로 치환한다. 기존 module 이름과 `CMD_FIFO_DEPTH=4`, slot budget,
   same-cycle recycle 및 scheduler progress timing을 유지하고 exact focused/node/
   XRT cycle/count equivalence를 확인한다.
8. IMPROVE qparam과 Weight overlap DMA를 순서대로 치환한다. 각 모듈 변경 뒤
   독립 regression을 수행한다. Weight queue는 wide switch의 complete 128B
   response를 한 logical response로 capture한다.
9. NAIVE Weight gather의 descriptor/slot/drain만 공통 queue로 치환하고,
   16-lane assembly는 NAIVE source adapter에 유지한다. `CMD_FIFO_DEPTH=1`과
   기존 in-command prefetch depth를 유지하여 LMEM request schedule 변화 없이
   numerical/count/cycle equivalence를 먼저 통과한다.
10. row-major gather address/lane mapping은 NAIVE source adapter에, TMEM
    bank/partial mapping과 priority hold는 IMPROVE source adapter에만 남긴다.
11. NAIVE에는 readiness/deadline/urgency scheduler를 추가하지 않는다. LMEM
    요청은 slot/outstanding credit와 기존 arbiter ready로만 제한하고 starvation,
    ACC traffic 및 Input traffic regression을 측정한다.
12. baseline에서 Weight source-empty가 measurable bottleneck일 때만 NAIVE
    Weight `CMD_FIFO_DEPTH=2`를 별도 A/B 실험한다. LMEM arbitration regression,
    Input/ACC starvation 또는 유의미한 성능 이득 부재 시 depth 1을 최종값으로
    유지한다.
13. Output DMA와 ACC LMEM adapter는 이 phase에서 구조 변경하지 않는다.

이 phase는 Phase 5 XRT correctness와 baseline이 확보된 뒤 수행한다. DMA
refactor와 compute migration을 한 patch에 섞지 않으며, 이미 통과한 common
core의 cycle/count를 DMA cleanup 때문에 바꾸지 않는다. IMPROVE는 각 치환
단계에서 refactor 전 cycle/count가 exact해야 하며, NAIVE depth-2 실험만 명시적
performance optimization으로 분리한다.

Phase 6 closure evidence (iteration 126):

- [x] The NAIVE gather alone owns row-major base/stride/lane mapping and its
  bounded 16-lane response assembly.
- [x] TMEM bank selection, partial-wide assembly and scheduler priority remain
  inside the IMPROVE TMEM switches/source adapters.
- [x] NAIVE LMEM requests are limited only by bounded slot/outstanding credit
  and ordinary ready/valid arbitration; no readiness/deadline/urgency scheduler
  was introduced.
- [x] The final hierarchy contains five independent common queues: four
  depth-4 IMPROVE operand queues and one depth-1 NAIVE Weight queue.
- [x] No accepted waveform identifies Weight source-empty as a limiting NAIVE
  interval, so the optional depth-2 experiment is not opened and depth 1 is
  final for this plan.
- [x] Output DMA and `VX_gemm_acc_lmem` remained structurally unchanged during
  Phase 6.

### Phase 7: legacy 제거와 구조 고정

1. NAIVE 기본 build가 common compute core만 사용하는지 elaboration hierarchy로 확인한다.
2. 임시 A/B parameter와 duplicate control path를 제거한다.
3. v1-only queue/prefetch counter/debug를 제거하거나 legacy file에 격리한다.
4. 문서와 synthesis source manifest를 갱신한다.

Iteration-126 cleanup boundary:

- Remove only the unreferenced `VX_lmem_dma_input_overlap_legacy` and
  `VX_lmem_dma_weight_overlap_legacy` module bodies from
  `VX_lmem_dma_misal.sv`.
- Remove the legacy `VX_gemm_unit.sv` and `VX_gemm_unit_if.sv` entries only
  from the common-core NAIVE `gemm_node` focused manifest. Do not delete those
  production files: dedicated legacy unit tests and synthesis wrappers still
  own them.
- Remove only simulation-only compatibility aliases with no repository test
  reference. Retain qparam/Weight/gather binding markers and direct queue-state
  aliases used by the accepted focused tests.
- The NAIVE gather command depth may be made an internal constant of one after
  confirming that no final hierarchy overrides it; retain its focused binding
  marker. Do not introduce or test depth 2 in cleanup.
- Do not rename active public overlap wrappers in this phase. Their names and
  hierarchy are accepted external test/debug contracts even though their
  internals now use the common queue.

Iteration-127 implementation result:

- Removed the two unreferenced legacy overlap module definitions from
  `VX_lmem_dma_misal.sv`. Repository-wide source search reports no remaining
  definition or reference, while the active Input/qparam/Weight common-queue
  wrappers remain unchanged in name and ownership.
- Removed only the simulation aliases enumerated by the iteration-126 audit.
  Focused-test-owned queue binding, qparam writer, Weight, and NAIVE gather
  visibility remains available.
- Removed `VX_gemm_unit.sv` and `VX_gemm_unit_if.sv` only from the common-core
  NAIVE `gemm_node` focused manifest. Both production files, the dedicated
  legacy unit manifest, and synthesis wrappers remain intact.
- Kept `VX_lmem_weight_gather_dma.CMD_FIFO_DEPTH` as a compatibility parameter.
  It remains statically constrained to one and has no live override; changing
  its public signature would add interface churn without removing an active
  control path.
- Fresh VCS compile/elaboration passed for the depth-1/depth-4 common queue,
  NAIVE WLOAD8 gather, full NAIVE WLOAD8 node, and full IMPROVE fixed888 node.
  Full IMPROVE Verilator lint also completed with warnings only. The dedicated
  legacy unit source remains live, but its existing focused TB cannot elaborate
  because three current LMEM interface ports are unconnected; cleanup does not
  alter or mask that independent test-infrastructure issue.

## 10. 검증 계획

### 10.1 공통 compute-core unittest

새 `hw/unittest/gemm_compute_core`에서 QCOL/QROW 모두 검증한다.

- 매 cycle Input accept 가능한 full-rate case
- 1/2/6/7-cycle post-process stall
- random Input/ACC/write backpressure
- tree full-rate 중 first-output-cycle stall
- result FIFO empty/nonempty stop-resume
- valid/payload/control stability
- accepted/compute/result/retire count 일치
- data loss, duplicate, reorder 없음
- W/S/Z generation을 독립 지연한 consumer stall
- reset with occupied pipeline
- immediate/history/backend-response RAW case

### 10.2 ACC adapter unittest

`gemm_acc_internal`:

- 기존 v2 fixed-latency read/write
- four-bank conflict와 output read
- refactor 전후 exact result/count/cycle

`gemm_acc_lmem`:

- aligned/misaligned address boundary
- LMEM lane response skew
- out-of-order bank response
- read/write backpressure
- pending write와 same-set read ordering
- multiple outstanding tags와 wrap
- final/non-final destination 선택
- reset/abort/drain

### 10.3 DMA unittest

Configured VCS에서 다음 기존 suite를 유지한다.

- `dma_mem_unit`
- `dma_mem_unit_misal`
- `dma_node`
- `lmem_dma_misal`
- `lmem_dma_input_overlap`
- `lmem_dma_weight_overlap`
- `tmem_wide_read_switch`
- `tensor_mem_bank`

신규 공통 primitive suite를 추가한다.

`gemm_stream_dma_queue`:

- `CMD_FIFO_DEPTH={1,4}`, response-slot depth wrap과 full/empty turnover
- source request 및 destination response `valid && !ready` payload 안정성
- 여러 descriptor에 걸친 out-of-order response와 ordered destination drain
- fetch head와 install head의 독립 진행
- requested/fetched/installed exact count와 fetch/install completion 분리
- W/S/Z writer release 전 install 금지와 release cycle handoff
- Input writer fence bypass 및 destination handshake admission fence
- same-cycle descriptor pop/enqueue와 slot free/reallocate
- occupied reset과 stale response rejection
- scheduler priority, LMEM lane 또는 TMEM bank 의존성이 elaboration에 없는지 확인

추가해야 할 NAIVE directed case:

- WLOAD8, 128-byte, 16-lane row-major Weight gather의 request/response/write exact count
- WLOAD8에서 `W_LMEM_DMA_CMD_BEATS=4` 및 lane 0..15 data placement
- row-major Weight gather response skew/backpressure
- gather valid hold 중 address/row/lane context 안정성
- S/Z independent generation completion
- Input source가 빠르고 ACC LMEM response가 느린 경우의 bounded backpressure
- final output LMEM write stall과 정확한 done
- Weight queue `CMD_FIFO_DEPTH=1`에서 refactor 전 LMEM request 순서와 exact
  command cycle equivalence
- LMEM request priority/urgency sideband이 추가되지 않았고 기존 arbiter만 실제
  grant authority인지 hierarchy/assertion으로 확인
- optional depth-2 A/B에서는 Input/ACC maximum service gap, per-client LMEM
  grant count와 starvation zero를 반드시 측정

추가해야 할 IMPROVE directed case:

- 공통 queue 치환 전후 Input/Weight/S/Z descriptor accept, request, response,
  install 순서와 cycle exact equivalence
- `CMD_FIFO_DEPTH=4`, 기존 response-slot occupancy와 same-cycle recycle 유지
- WLOAD8 Weight 128B request마다 정확히 두 개의 64B TMEM bank request가
  발생하고 두 bank response가 모두 오기 전에는 upstream response가 없음
- 두 bank response 순서를 바꾸고 backpressure를 걸어도 assembled 128B data,
  original tag와 request-order retirement가 정확함
- `VX_tmem_wide_read_switch` response 하나가 Weight overlap queue의 response
  count 하나만 증가시키며 추가 fragment assembly stage가 없음
- fetch-complete Weight가 writer fence 이전에는 install되지 않음
- TMEM scheduler priority가 source request hold에 고정되고 공통 queue 내부에는
  priority decision이 없음
- per-bank offer/grant/loss와 M4/M256 QCOL/QROW total cycle exact equivalence

### 10.4 node unittest

NAIVE node에서 다음을 검증한다.

- legacy/common A/B numerical equivalence
- `MXU_WLOAD_NUM=8` 고정; WLOAD4 fallback 금지
- `M={4,32,64,128,256}`
- `N=K=256`, `QBLK={32,64,128}`
- `QDIR={0,1}`, `WTRANS={0,1}`
- command/packet/admission/retire count
- PSUM request/response/write count
- W/S/Z load/install/consume generation count
- stalled Input payload/control 안정성
- no early done, no duplicate final write
- NAIVE row-major address progression과 LMEM/PSUM/final address correctness
- IMPROVE tile-major/TMEM/internal-ACC address progression regression
- packet stall 중 backend-specific address/control stability

IMPROVE node regression도 같은 common core 변경 때문에 반드시 재실행한다.

### 10.5 XRT-VCS blackbox

반드시 configured build와 `ci/run_black.sh xrt-vcs-sim`을 사용한다.

NAIVE:

- config: 신규 `naive_gemm_th32_tcol32_hwexp_dcache_sxbar_f16_w8.sh`
- required define: `-DMXU_WLOAD_NUM=8`
- app: `fpint_gemm_ffn_hw_naive`

IMPROVE:

- config: `improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem_w8.sh`
- required define: `-DMXU_WLOAD_NUM=8`
- app: `fpint_gemm_ffn_hw`

필수 shape:

```text
M={4,32,64,128,256}
N=256
K=256
QBLK={32,64,128}
WTRANS={0,1}
QDIR={0,1}
```

모든 case에서 numerical PASS, 정상 shutdown, exact compile config 및 fresh simv를 확인한다. compile log/manifest에는 각 build에 `MXU_WLOAD_NUM=8`이 정확히 한 번 적용되고 conflicting WLOAD define이 없다는 검사를 추가한다.

현재 재개 순서는 다음으로 고정한다.

1. `VX_gemm_psum_read_ooo_join` focused test와 `VX_gemm_acc_lmem` alternating-set
   integration test
2. fixed WLOAD8 IMPROVE unit/node exact-cycle regression
3. QBLK32 NAIVE M4 QCOL WTRANS0 fresh XRT/FSDB에서 `<=4900` gate 확인
4. QBLK32 NAIVE M4 QROW, M256 QCOL/QROW WTRANS0
5. QBLK64/128의 M4 QCOL/QROW WTRANS0로 qparam command/write/generation
   contract 확인
6. `M={32,64,128,256}`, `QBLK={32,64,128}` QCOL/QROW WTRANS0 확장
7. 동일 M/QBLK set의 WTRANS1 확장
8. matched IMPROVE WLOAD8/QBLK matrix

QBLK16은 모든 mode에서 이 matrix에 넣지 않는다. 첫 required-scope failure가
발생하면 후속 case로 넘어가지 않고 동일 case를 수정/재검증한다.

### 10.6 FSDB 분석

NAIVE M4와 M256 QCOL/QROW에서 다음 timeline을 수집한다.

- Input source valid/ready/fire
- packetizer index/control
- pre-process/tree/post-process valid/ready
- tree credit와 result FIFO occupancy
- ACC LMEM read request/response/tag
- accumulator join stall
- PSUM/final write request/ready/fire
- W/S/Z generation ready와 consumer fire
- command final retire/done

핵심 확인은 기존의 약 30-response startup wait가 제거되고, 실제 LMEM response shortage에서만 local backpressure가 발생하는지다.

## 11. 성능 및 비교 기준

### 11.1 migration no-regression gate

Phase 0에서 fresh baseline을 먼저 고정한다. 기본 gate는 다음과 같다.

- IMPROVE: refactor 전후 cycle/count exact match를 우선 요구
- NAIVE M4: common-core migration 후 current baseline보다 느려지지 않음
- NAIVE M256: current baseline 대비 1% 이내
- full-ready compute core: initiation interval 1
- Input/ACC/output backpressure가 없으면 불필요한 bubble 0

숫자 gate를 만족하지 못하면 기능 PASS와 별도로 performance failure로 기록하고 원인을 FSDB로 분류한다. correctness를 위해 필요한 memory latency stall과 control refactor가 만든 불필요한 stall을 구분한다.

확정된 비교 기준은 다음과 같다.

| backend/revision | M4 QCOL | M4 QROW | M256 QCOL | M256 QROW |
|---|---:|---:|---:|---:|
| NAIVE legacy WLOAD8 Phase 0 | 4900 | 15303 | 측정 matrix에서 재확인 | 측정 matrix에서 재확인 |
| IMPROVE common-core WLOAD8 Phase 3 | 602 | 607 | 17768 | 17769 |

IMPROVE deterministic unit/node는 exact cycle/count equality를 요구한다. XRT는
50% DRAM exit-stall scheduling 때문에 같은 simv에서도 최대 2 cycle 변동이
확인됐으므로 numerical/count exact + case별 baseline ±2 cycle을 사용한다.
범위를 벗어나면 같은 simv를 최소 2회 더 실행하고 median으로 판정한다.

NAIVE common-core M4 QCOL은 PSUM checker 수정과 LMEM ACC early prefetch/same-set
batching 뒤의 5274 cycle을 거쳐, 4-slot lane-response OOO join과 2-entry tagged
FIFO 적용 후 4738 cycle로 확정됐다. Input/Weight는 각각 256 fire/0 stall이고,
ACC read/write는 224/256이며 numerical/count/ownership은 정확하다. legacy 4900
이하 strict migration gate를 162 cycle 여유로 통과했다. FSDB는 서로 다른
PSUM set의 live issued incomplete slot이 동시에 존재한 cycle 563개, 반대 set이
미완료인 동안의 physical issue 168회, logical join/adapter/core request-response
224/224와 lane request-response 3584/3584를 확인했다. 최대 join occupancy는
4이고 response FIFO occupancy는 1이며 terminal ownership은 모두 0이다.

### 11.2 최종 NAIVE 대 IMPROVE 비교

최종 비교는 다음 조건을 고정한다.

- 동일 common compute core revision
- 양쪽 모두 `MXU_WLOAD_NUM=8`
- 동일 `M/N/K/QBLK/WTRANS/QDIR`
- NAIVE는 row-major/LMEM/`VX_dma_node`, IMPROVE는 tile-major/TMEM/multi-channel DMA
- WLOAD4 측정치는 historical 참고 자료로만 분리하고 WLOAD8 speedup 계산의 분모/분자에 사용하지 않음

따라서 최종 속도 차이는 WLOAD 폭이 아니라 두 memory system, layout, address FSM 및 backend-specific arbitration/latency의 차이로 해석한다.

공통 core의 source hash 또는 build manifest를 결과에 남겨 두 configuration이 실제로 같은 compute RTL을 사용했음을 증명한다.

## 12. Assertion과 invariant

공통 core:

- stalled transaction의 data/control 안정성
- input accept마다 정확히 한 retire
- tree reservation 없이 compute fire 금지
- tree inflight + result FIFO occupancy가 capacity 이하
- W/S/Z expected generation이 맞지 않으면 consumer fire 금지
- final retire는 실제 write handshake와 동일
- pipeline empty일 때 outstanding ACC transaction 0

ACC adapter:

- request 없는 response 금지
- tag duplicate/reuse-before-retire 금지
- response hold 중 data/tag 안정성
- write ready 없이 completion 금지
- pending write/read ordering violation 금지
- LMEM lane response 조립 전 wide response 금지

DMA:

- valid/ready stall 중 request payload/tag 안정성
- slot overflow/underflow 금지
- source response마다 정확히 한 destination write
- command done 전 모든 response/write drain
- fixed direction과 byte count 일치
- WLOAD8 Weight command당 4 request beats, logical beat당 16 lane responses 및 정확히 한 assembled write
- lane response가 skew되더라도 16개가 모두 모이기 전 Weight write/install 금지

## 13. Hard Rule

다음 문제가 발견되면 작은 local fix로 우회하지 말고 설계 논의로 되돌린다.

1. common compute core가 variable-latency ACC response를 수용하려면 unbounded storage가 필요한 경우
2. NAIVE LMEM response tag/order contract로 transaction과 PSUM을 정확히 결합할 수 없는 경우
3. tree fixed-latency island의 bounded credit으로 downstream arbitrary backpressure를 수용할 수 없는 경우
4. external LMEM write/read hazard를 해결하기 위해 row-major layout이나 기존 LMEM mapping을 바꿔야 하는 경우
5. 동일 compute core를 유지하려면 IMPROVE의 functional/cycle behavior를 깨야 하는 경우
6. DMA commonization이 `VX_dma_node`를 multi-channel engine으로 바꾸거나 NAIVE를 TMEM으로 이동시키는 경우
7. final-result LMEM path를 제거해야만 v2 control pipeline을 연결할 수 있는 경우
8. common packetizer/core에 row-major 또는 tile-major address 계산 분기가 들어가야 하는 경우
9. NAIVE WLOAD8 지원을 위해 row-major layout, LMEM endpoint 또는 `VX_dma_node` topology를 바꿔야 하는 경우
10. 128-byte Weight transaction을 지원하지 못해 WLOAD4로 silent fallback하거나 두 backend에 서로 다른 WLOAD를 사용해야 하는 경우
11. `QBLK<32` 지원을 현재 계획에 다시 포함하려는 경우. 사용자가 확정한
    support 범위는 QBLK32/64/128이며, 더 작은 QBLK를 위한 group-aware
    storage/arithmetic 확장은 별도 architecture task다.
12. cross-set OOO read를 지원하기 위해 generic `VX_mem_bus_split`, IMPROVE ACC
    path, row-major address mapping 또는 PSUM write ownership을 함께 바꿔야 하는
    경우. 선택한 구조는 NAIVE PSUM read 전용 bounded join 안에서 끝나야 한다.

다음은 blocker가 아니다.

- interface port 추가와 tie-off
- testbench hierarchy drift
- source manifest 수정
- simulation-only assertion/debug signal 추가
- module rename 없이 wrapper를 두는 호환 변경

## 14. 완료 기준

- [x] NAIVE와 IMPROVE가 동일한 `VX_gemm_compute_core`를 인스턴스화한다.
- [x] NAIVE/IMPROVE 모두 explicit `MXU_WLOAD_NUM=8` config를 가진다.
- [x] NAIVE Weight path가 128-byte, 16 lanes, command당 4 beats를 만족한다.
- [x] FSM/address generator는 row-major와 tile-major로 분리되어 있다.
- [x] NAIVE는 LMEM/`VX_dma_node`/external PSUM-final을 유지하고 IMPROVE는 TMEM/multi-channel/internal ACC를 유지한다.
- [x] legacy `VX_gemm_unit`은 NAIVE 기본 elaboration에서 제거됐다.
- [x] programmable/internal/LMEM ACC와 packetizer focused VCS가 통과했다.
- [x] QBLK32 NAIVE node `M={4,256} × QDIR={0,1} × WTRANS={0,1}`가 numerical/count/generation/terminal-zero를 통과했다.
- [x] 4-slot PSUM lane-response OOO join과 2-entry tagged FIFO가 alternating-set,
  lane reorder, backpressure, reset 및 slot reuse focused test를 통과한다.
- [x] M4 QCOL FSDB에서 서로 다른 PSUM set의 physical read가 동시에 outstanding이며
  slot별 16-lane data/tag가 섞이지 않고 `total_cycles<=4900`을 만족한다.
- [x] QBLK64/128 NAIVE node에서 QCOL/QROW qparam command/write/generation과 numerical 결과가 통과한다.
- [x] PSUM OOO join 적용 뒤 NAIVE XRT minimum matrix M4/M256 QCOL/QROW가 통과한다.
- [x] NAIVE XRT WTRANS0 `M={32,64,128}`, `QBLK={32,64,128}` matrix가 통과한다.
- [x] NAIVE XRT M4 WTRANS1 `QBLK={32,64,128}` QCOL/QROW matrix가 통과한다.
  더 큰 M의 WTRANS1은 아직 실행하지 않았고 필수 Phase 5 gate로 간주하지 않는다.
- [x] matched IMPROVE QBLK32/64/128 matrix와 common-core source hash가 기록된다.
- [x] FSDB에서 fixed startup watermark가 correctness authority가 아니며 실제 LMEM/ACC shortage만 backpressure를 만든다는 것을 확인한다.
- [x] Phase 6 DMA audit and the required bounded refactor are complete.
- [x] Phase 7 bounded legacy/debug/manifest cleanup is complete.
- [x] 최종 성능 보고서가 compute parity 증거와 memory-system 차이를 함께 기록한다.

## 15. 권장 실행 순서 요약

```text
baseline capture
  -> v2 internal ACC interface extraction
  -> common compute core extraction
  -> programmable-latency ACC unittest
  -> NAIVE LMEM ACC adapter
  -> NAIVE packetizer/common-core integration
  -> [현재] NAIVE common-core XRT 재검증
  -> FSDB stall classification
  -> 필요한 operand DMA queue/control parity만 수행
  -> legacy/debug/source cleanup
  -> full matched VCS/XRT comparison과 보고서
```

가장 중요한 순서 규칙은 compute-core refactor, NAIVE LMEM adapter, DMA optimization을 각각 독립된 검증 phase로 수행하는 것이다. 세 변경을 동시에 적용하면 numerical failure, backpressure deadlock 및 performance regression의 최초 원인을 구분할 수 없다.

## 16. Future work

### 16.1 NAIVE contiguous DMA의 multi-command data overlap

현재 `VX_dma_unit_align`의 `PREPARE -> ACTIVATE` chaining은 다음 command의
주소 correction을 미리 계산하고 이전 `DONE`과 다음 시작 사이의 setup bubble을
줄인다. 하지만 active data-transfer command는 여전히 하나이므로 command N의
destination drain 중 command N+1의 source data를 동시에 fetch하지는 않는다.

후속 최적화에서는 NAIVE Input/S/Z contiguous DMA에 bounded command FIFO와
per-command response-slot ownership을 추가하여 N+1 source fetch와 N install을
겹칠 수 있다. LMEM scheduler는 추가하지 않고 고정 outstanding/slot credit과
기존 LMEM arbiter의 fairness만 사용한다. 이 작업은 FSDB에서 command-boundary
source idle이 실제 병목으로 확인된 경우에만 별도 최적화 task로 수행하며,
현재 Phase 6의 필수 acceptance에는 포함하지 않는다.

# VX_elastic_buffer - 탄성 버퍼

## 개요
`VX_elastic_buffer`는 Vortex에서 가장 범용적으로 사용되는 버퍼 모듈로, valid-ready handshake 프로토콜을 사용하는 데이터 스트림을 버퍼링한다. "탄성(elastic)"이라는 이름은 데이터 흐름의 속도 차이를 흡수하여 파이프라인이 유연하게 동작하도록 한다는 의미이다.

**파일**: `hw/rtl/libs/VX_elastic_buffer.sv`

## 용도

### 1. Pipeline Stage 분리
- 긴 조합 경로를 여러 단계로 분리
- 타이밍 개선 (critical path 단축)
- 각 stage가 독립적으로 동작

### 2. Backpressure 흡수
- 다운스트림이 stall될 때 업스트림 데이터 임시 저장
- 데이터 손실 방지
- 처리량(throughput) 향상

### 3. 클럭 도메인 경계
- 외부 버스 인터페이스 (icache, dcache)
- OUT_REG=1로 출력 레지스터링
- Setup/hold time 마진 확보

### 4. 레이턴시 숨김 (Latency Hiding)
- Long latency 연산 중 다른 요청 버퍼링
- 파이프라인 깊이 증가
- 처리량 최대화

## 파라미터

### DATAW
```systemverilog
parameter DATAW = 1
```
- 데이터 폭 (비트 수)
- 모든 타입의 데이터 저장 가능

### SIZE
```systemverilog
parameter SIZE = 1
```
- **버퍼 깊이** (엔트리 수)
- **SIZE=0**: Passthrough (버퍼 없음, 조합 논리)
- **SIZE=1**: 단일 파이프 레지스터
- **SIZE=2**: 2-엔트리 stream buffer (full bandwidth)
- **SIZE≥3**: FIFO queue

### OUT_REG
```systemverilog
parameter OUT_REG = 0
```
- **출력 레지스터 단계 수**
- **OUT_REG=0**: 출력 레지스터 없음
- **OUT_REG=1**: 1-stage 출력 레지스터
- **OUT_REG>1**: 다단계 파이프 레지스터
- **목적**: 타이밍 개선, 외부 인터페이스용

### LUTRAM
```systemverilog
parameter LUTRAM = 0
```
- **LUTRAM=1**: FPGA LUT RAM 사용 (분산 메모리)
- **LUTRAM=0**: Flip-flop 사용
- SIZE≥3일 때만 의미 있음

## 인터페이스

### 입력 (Producer)
```systemverilog
input  wire             valid_in   // 데이터 유효
output wire             ready_in   // 수신 가능
input  wire [DATAW-1:0] data_in    // 데이터
```

### 출력 (Consumer)
```systemverilog
output wire             valid_out  // 데이터 유효
input  wire             ready_out  // 소비 가능
output wire [DATAW-1:0] data_out   // 데이터
```

### Handshake 프로토콜
```
fire_in  = valid_in && ready_in    // 데이터 push
fire_out = valid_out && ready_out  // 데이터 pop
```

## 내부 구현 (SIZE별)

### SIZE=0: Passthrough
```systemverilog
assign valid_out = valid_in;
assign data_out  = data_in;
assign ready_in  = ready_out;
```
- **지연**: 0 사이클 (조합 논리)
- **용도**: 인터페이스 표준화, 조건부 버퍼링
- **장점**: 면적 절약
- **단점**: 타이밍 경로 연결 (critical path)

### SIZE=1: Pipe Buffer
```systemverilog
VX_pipe_buffer #(
    .DATAW (DATAW),
    .DEPTH (MAX(OUT_REG, 1))
) pipe_buffer
```
- **지연**: 1 사이클
- **구조**: 단일 레지스터
- **특징**: 
  - Full bandwidth (fire_in과 fire_out 동시 가능)
  - ready_in과 ready_out가 결합 (coupled)
  - `ready_in = ready_out || ~valid_out`
- **용도**: 간단한 파이프라인 레지스터

### SIZE=2: Stream Buffer + Output Pipe
```systemverilog
VX_stream_buffer #(
    .DATAW   (DATAW),
    .OUT_REG (OUT_REG == 1)
) stream_buffer

VX_pipe_buffer #(
    .DATAW (DATAW),
    .DEPTH ((OUT_REG > 1) ? (OUT_REG-1) : 0)
) out_buf
```
- **지연**: 1~2 사이클
- **구조**: 2개 레지스터 (data_out_r, buffer_r)
- **특징**:
  - Full bandwidth
  - ready_in과 ready_out 디커플링 (decoupled)
  - 동시 push/pop 가능
- **용도**: 높은 처리량 요구 시

#### Stream Buffer 동작
```systemverilog
valid_in_r: 내부 버퍼 여유 여부
buffer_r:   백업 데이터 저장
data_out_r: 출력 데이터

flow_out = ready_out || ~valid_out

if (flow_out) {
    data_out_r <= valid_in_r ? data_in : buffer_r;
}
if (fire_in) {
    buffer_r <= data_in;
}
```
- `valid_in_r=1`: 버퍼 비어있음 → push 가능
- `valid_in_r=0`: 버퍼 가득참 → push 불가
- buffer_r은 백업 슬롯 (2번째 엔트리)

### SIZE≥3: FIFO Queue + Output Pipe
```systemverilog
VX_fifo_queue #(
    .DATAW   (DATAW),
    .DEPTH   (SIZE),
    .OUT_REG (OUT_REG == 1),
    .LUTRAM  (LUTRAM)
) fifo_queue

wire push = valid_in && ready_in;
wire pop = valid_out_t && ready_out_t;

assign ready_in = ~full;
assign valid_out_t = ~empty;
```
- **지연**: 1~3 사이클 (FIFO 구현에 따라)
- **구조**: FIFO queue (circular buffer 또는 shift register)
- **특징**:
  - 깊은 버퍼링
  - Out-of-order 지원 불가
  - 순차적 FIFO 동작
- **용도**: 큰 backpressure 흡수

## 사용 예시

### 1. Fetch Stage (외부 버스)
```systemverilog
VX_elastic_buffer #(
    .DATAW   (ICACHE_ADDR_WIDTH + ICACHE_TAG_WIDTH),
    .SIZE    (2),
    .OUT_REG (1)  // 외부 버스는 레지스터 출력
) req_buf
```
- **SIZE=2**: Full bandwidth 유지
- **OUT_REG=1**: Setup/hold time 마진

### 2. Decode Stage (인터페이스 표준화)
```systemverilog
VX_elastic_buffer #(
    .DATAW (OUT_DATAW),
    .SIZE  (0)  // Passthrough
) req_buf
```
- **SIZE=0**: 지연 없음
- 인터페이스 일관성 유지

### 3. IBuffer (명령어 버퍼링)
```systemverilog
VX_elastic_buffer #(
    .DATAW   (OUT_DATAW),
    .SIZE    (IBUF_SIZE),  // 일반적으로 2
    .OUT_REG (1)
) instr_buf
```
- **SIZE=IBUF_SIZE**: Decode burst 흡수
- **OUT_REG=1**: Scoreboard 타이밍 개선

### 4. Memory Request Queue
```systemverilog
VX_elastic_buffer #(
    .DATAW (REQ_DATAW),
    .SIZE  (QUEUE_SIZE),  // 8 이상
    .OUT_REG (0)
) req_queue
```
- **SIZE≥3**: 많은 pending 요청 저장
- Cache miss 시 레이턴시 숨김

### 5. Commit Arbitration
```systemverilog
VX_stream_arb #(
    .OUT_BUF (1)  // elastic_buffer SIZE=1 내부 사용
) commit_arb
```
- Arbitration 결과 버퍼링
- Writeback path 타이밍 개선

## 성능 특성

### Throughput (처리량)
- **SIZE=0**: 1 transaction/cycle (조합 경로 허용 시)
- **SIZE=1**: 1 transaction/cycle (ready 결합)
- **SIZE≥2**: 1 transaction/cycle (full bandwidth)

### Latency (지연)
- **SIZE=0**: 0 cycle
- **SIZE=1**: 1 cycle
- **SIZE=2**: 1 cycle (OUT_REG=0), 2 cycles (OUT_REG=1)
- **SIZE≥3**: 1~3 cycles (FIFO 구현 의존)

### Buffering Capacity (버퍼 용량)
- **SIZE=0**: 0 entry
- **SIZE=1**: 1 entry (동시 push/pop 시 2처럼 동작)
- **SIZE=2**: 2 entries
- **SIZE=N**: N entries

## 설계 패턴

### 1. Pipeline Register
```systemverilog
VX_elastic_buffer #(.SIZE(1))
```
간단한 파이프라인 스테이지

### 2. High-Throughput Buffer
```systemverilog
VX_elastic_buffer #(.SIZE(2))
```
Full bandwidth, decoupled ready

### 3. External Interface
```systemverilog
VX_elastic_buffer #(.SIZE(2), .OUT_REG(1))
```
타이밍 마진 확보

### 4. Deep Queue
```systemverilog
VX_elastic_buffer #(.SIZE(8~64))
```
큰 레이턴시 흡수

### 5. Conditional Buffer
```systemverilog
VX_elastic_buffer #(.SIZE(ENABLE ? 2 : 0))
```
조건부 버퍼링 (면적 절약)

## Vortex 파이프라인에서의 역할

### Fetch Stage
```
Schedule → elastic_buffer(SIZE=2, OUT_REG=1) → Icache
```
외부 버스 타이밍

### Issue Stage
```
Decode → elastic_buffer(SIZE=IBUF_SIZE) → Scoreboard
```
명령어 버퍼링

### Execute Stage
```
Dispatch → elastic_buffer(SIZE=2) → Execute Unit
```
실행 유닛 입력 버퍼

### Commit Stage
```
Execute Unit → stream_arb(OUT_BUF=1) → Writeback
```
중재 결과 버퍼링

## 타이밍 고려사항

### Critical Path 분리
```
Long Combinational Logic
    → elastic_buffer (SIZE=1 이상)
    → Next Stage
```
레지스터 삽입으로 경로 단축

### Ready Path
- **SIZE=0**: ready_in = ready_out (조합 경로)
- **SIZE=1**: ready_in = ready_out || ~valid_out (조합)
- **SIZE≥2**: ready_in = ~full (레지스터 기반)

SIZE≥2 사용 시 ready path도 개선됨

### Fanout 감소
```
1-to-N fanout 
    → elastic_buffer (SIZE=1)
    → Reduced fanout
```

## 면적 vs 성능 트레이드오프

### 최소 면적
- **SIZE=0**: 면적 0
- 타이밍 허용 시 사용

### 균형
- **SIZE=1~2**: 작은 면적, 충분한 버퍼링
- 대부분의 경우 적합

### 최대 성능
- **SIZE=큼**: 레이턴시 숨김 최대화
- 면적 증가
- Long latency 연산에 적합

## 디버깅

### 버퍼 Full/Empty 추적
SIZE≥3일 때 FIFO의 full/empty 신호 확인

### Stall 분석
```systemverilog
wire stall_in  = valid_in && ~ready_in;
wire stall_out = valid_out && ~ready_out;
```
어느 쪽이 병목인지 판단

### Data Flow 추적
```systemverilog
wire fire_in  = valid_in && ready_in;
wire fire_out = valid_out && ready_out;
```
실제 데이터 이동 추적

## 요약

`VX_elastic_buffer`는:
1. **범용 버퍼**: 모든 데이터 타입 지원
2. **유연한 크기**: SIZE 파라미터로 조정
3. **타이밍 최적화**: OUT_REG로 출력 레지스터링
4. **Full bandwidth**: SIZE≥2에서 동시 push/pop
5. **Backpressure 지원**: valid-ready handshake
6. **파이프라인 핵심**: Vortex 전체에서 광범위하게 사용

적절한 SIZE와 OUT_REG 선택이 면적, 타이밍, 성능 균형의 핵심이다.

# Commit Stage - 명령어 완료 및 레지스터 쓰기

## 개요
Commit stage는 파이프라인의 마지막 단계로, 실행 유닛에서 완료된 명령어의 결과를 레지스터 파일에 쓰고, CSR을 업데이트하며, scheduler에 완료 정보를 전달한다.

**파일**: `hw/rtl/core/VX_commit.sv`

## 파이프라인 위치
```
Execute → [COMMIT: Arbitration → Writeback → CSR Update → Scheduler Notify] → (Pipeline End)
```

## 주요 인터페이스

### 입력
```systemverilog
VX_commit_if.slave commit_if[NUM_EX_UNITS * ISSUE_WIDTH]
- ALU, LSU, FPU, SFU, TCU의 ISSUE_WIDTH개 결과 (총 NUM_EX_UNITS * ISSUE_WIDTH)
- Out-of-order로 도착 (실행 유닛별 레이턴시 다름)
```

### 출력
```systemverilog
VX_writeback_if.master writeback_if[ISSUE_WIDTH]
- Scoreboard와 Operands로 전달 (레지스터 해제 및 forwarding)

VX_commit_csr_if.master commit_csr_if
- CSR 업데이트 (instret 등)

VX_commit_sched_if.master commit_sched_if
- Scheduler에 완료된 warp 정보 전달
```

## 핵심 구조

### 1. Commit Arbitration (우선순위 중재)
```systemverilog
for (genvar i = 0; i < ISSUE_WIDTH; ++i) begin
    VX_stream_arb #(
        .NUM_INPUTS (NUM_EX_UNITS),
        .ARBITER ("P"),  // Priority arbiter
        .OUT_BUF (1)
    ) commit_arb
    
    // 입력: commit_if[0*ISSUE_WIDTH+i], commit_if[1*ISSUE_WIDTH+i], ...
    // 출력: commit_arb_if[i]
end
```

### Arbiter 우선순위
```
Priority (낮은 번호 = 높은 우선순위):
1. EX_ALU  (0)
2. EX_LSU  (1)
3. EX_FPU  (2)
4. EX_SFU  (3)
5. EX_TCU  (4)
```
- ALU가 가장 빠르고 빈번하므로 우선순위 높음
- LSU, FPU는 long latency이지만 우선 처리
- SFU는 CSR이나 warp control이므로 덜 빈번

### OUT_BUF=1
- Arbitration 결과를 1 사이클 버퍼링
- Writeback path 타이밍 개선

## 2. Commit Size Tracking (완료 명령어 수 추적)

### Per-Issue Commit Size
```systemverilog
for (genvar i = 0; i < ISSUE_WIDTH; ++i) begin
    wire [COMMIT_SIZEW-1:0] count;
    `POP_COUNT(count, per_issue_commit_tmask[i]);
    assign commit_size[i] = count;
end
```
- **tmask**: 활성 스레드 마스크
- **POP_COUNT**: tmask에서 1의 개수 세기
- **commit_size[i]**: 해당 issue slice에서 완료된 스레드 수

### Total Commit Size (모든 issue 합산)
```systemverilog
VX_reduce_tree #(
    .IN_W  (COMMIT_SIZEW),
    .OUT_W (COMMIT_ALL_SIZEW),
    .N     (ISSUE_WIDTH),
    .OP    ("+")
) commit_size_reduce (
    .data_in  (commit_size_r),
    .data_out (commit_size_all_r)
);
```
- **reduce_tree**: ISSUE_WIDTH개 크기를 더함
- **commit_size_all**: 모든 issue에서 완료된 총 스레드 수

### Pipeline 레지스터
```systemverilog
commit_size → reg1 → commit_size_r → reduce_tree → reg2 → commit_size_all_rr
```
- 2단계 파이프라인으로 타이밍 개선
- **reg1**: Per-issue 크기 등록
- **reg2**: 합산 결과 등록

## 3. CSR Update (instret)

### Instruction Retired Counter
```systemverilog
reg [PERF_CTR_BITS-1:0] instret;

always @(posedge clk) begin
    if (reset) begin
        instret <= '0;
    end else begin
        if (commit_fire_any_rr) begin
            instret <= instret + PERF_CTR_BITS'(commit_size_all_rr);
        end
    end
end

assign commit_csr_if.instret = instret;
```
- **instret**: RISC-V 표준 CSR (완료된 명령어 수)
- **commit_fire_any_rr**: 2 사이클 지연된 commit 신호
- **commit_size_all_rr**: 2 사이클 지연된 완료 스레드 수
- 매 사이클 완료된 스레드 수만큼 증가

## 4. Committed Warps Tracking

### Warp 완료 추적
```systemverilog
reg [NUM_WARPS-1:0] committed_warps;

always @(*) begin
    committed_warps = 0;
    for (integer i = 0; i < ISSUE_WIDTH; ++i) begin
        if (per_issue_commit_fire[i] && per_issue_commit_eop[i]) begin
            committed_warps[per_issue_commit_wid[i]] = 1;
        end
    end
end
```
- **eop (End of Packet)**: 명령어의 마지막 UOP 완료
- **committed_warps**: 비트맵, 완료된 warp ID 표시
- **Scheduler로 전달**: Warp가 명령어 완료하여 다음 명령어 fetch 가능

### Pipeline Register
```systemverilog
VX_pipe_register #(
    .DATAW  (NUM_WARPS),
    .RESETW (NUM_WARPS)
) committed_pipe_reg (
    .data_in  (committed_warps),
    .data_out (commit_sched_if.committed_warps)
);
```
- 1 사이클 지연
- Scheduler와 타이밍 분리

## 5. Writeback Interface

### Writeback 생성
```systemverilog
for (genvar i = 0; i < ISSUE_WIDTH; ++i) begin
    assign writeback_if[i].valid = commit_arb_if[i].valid && commit_arb_if[i].data.wb;
    assign writeback_if[i].data.uuid  = commit_arb_if[i].data.uuid;
    assign writeback_if[i].data.wis   = wid_to_wis(commit_arb_if[i].data.wid);
    assign writeback_if[i].data.sid   = commit_arb_if[i].data.sid;
    assign writeback_if[i].data.PC    = commit_arb_if[i].data.PC;
    assign writeback_if[i].data.tmask = commit_arb_if[i].data.tmask;
    assign writeback_if[i].data.rd    = commit_arb_if[i].data.rd;
    assign writeback_if[i].data.data  = commit_arb_if[i].data.data;
    assign writeback_if[i].data.sop   = commit_arb_if[i].data.sop;
    assign writeback_if[i].data.eop   = commit_arb_if[i].data.eop;
    assign commit_arb_if[i].ready = 1;  // Always ready
end
```

### Writeback 조건
```systemverilog
writeback_if[i].valid = commit_arb_if[i].valid && commit_arb_if[i].data.wb
```
- **wb=1**: Destination 레지스터가 있고, writeback 필요
- **wb=0**: Store, Branch (taken), Fence 등 (writeback 불필요)

### Always Ready
```systemverilog
commit_arb_if[i].ready = 1;
```
- Commit은 항상 결과를 받을 수 있음 (backpressure 없음)
- Writeback이 stall해도 문제없음 (Scoreboard가 관리)

## 주요 신호

### commit_t (입력)
```systemverilog
typedef struct packed {
    logic [`UUID_WIDTH-1:0] uuid;
    logic [NW_WIDTH-1:0] wid;
    logic [SID_W-1:0] sid;
    logic [PC_BITS-1:0] PC;
    logic [`SIMD_WIDTH-1:0] tmask;
    logic [NUM_REGS_BITS-1:0] rd;
    logic [`SIMD_WIDTH-1:0][`XLEN-1:0] data;
    logic wb;   // Writeback 필요 여부
    logic sop;  // Start of packet
    logic eop;  // End of packet
} commit_t;
```

### writeback_t (출력)
```systemverilog
typedef struct packed {
    logic [`UUID_WIDTH-1:0] uuid;
    logic [ISSUE_WIS_W-1:0] wis;
    logic [SID_W-1:0] sid;
    logic [PC_BITS-1:0] PC;
    logic [`SIMD_WIDTH-1:0] tmask;
    logic [NUM_REGS_BITS-1:0] rd;
    logic [`SIMD_WIDTH-1:0][`XLEN-1:0] data;
    logic sop;
    logic eop;
} writeback_t;
```
- **wid → wis**: Warp ID를 Issue Subindex로 변환
- `wis = wid_to_wis(wid)` = `wid % PER_ISSUE_WARPS`

## Commit Flow

### 1. 실행 유닛 완료
```
Execute units → commit_if[NUM_EX_UNITS * ISSUE_WIDTH]
- 각 유닛이 독립적으로 결과 생성
- Out-of-order completion
```

### 2. Arbitration
```
commit_if → VX_stream_arb → commit_arb_if[ISSUE_WIDTH]
- Issue별로 NUM_EX_UNITS 중 하나 선택
- Priority arbiter (ALU > LSU > FPU > SFU > TCU)
```

### 3. Commit Size 계산
```
tmask → POP_COUNT → commit_size[i]
commit_size[] → VX_reduce_tree → commit_size_all
```

### 4. CSR 업데이트
```
commit_size_all_rr → instret += commit_size_all_rr
```

### 5. Scheduler 통지
```
committed_warps (wid별 완료) → commit_sched_if
```

### 6. Writeback
```
commit_arb_if (wb=1) → writeback_if → Scoreboard & Operands
- Scoreboard: inuse_regs[rd] = 0 (레지스터 해제)
- Operands: Forwarding (최신 값 전달)
```

## 성능 고려사항

### 1. Arbitration Latency
- OUT_BUF=1: 1 사이클 추가 레이턴시
- 트레이드오프: 타이밍 개선 vs 레이턴시

### 2. CSR Update Pipeline
- 2단계 파이프라인 (reg1, reg2)
- instret이 2 사이클 지연되어 업데이트
- 정확성은 보장 (모든 완료 반영)

### 3. Committed Warps
- 1 사이클 지연으로 scheduler 통지
- Scheduler가 다음 사이클에 해당 warp re-schedule 가능

### 4. Backpressure 없음
- Commit은 항상 ready
- Scoreboard가 의존성 관리
- 실행 유닛이 결과 생성 즉시 전달

## Writeback Forwarding

### 목적
- RAW hazard 최소화
- 최신 값을 operands stage에 직접 전달

### 동작
```
Commit → Writeback_if → Operands
- Operands가 레지스터 파일 읽는 동시에 writeback 데이터 확인
- 같은 레지스터면 writeback 데이터 사용 (bypass)
```

## 디버깅

### Trace (DBG_TRACE_PIPELINE)
```systemverilog
for (genvar i = 0; i < ISSUE_WIDTH; ++i) begin
    for (genvar j = 0; j < NUM_EX_UNITS; ++j) begin
        if (commit_if[j*ISSUE_WIDTH+i].valid && commit_if[j*ISSUE_WIDTH+i].ready) begin
            "wid=%0d, sid=%0d, PC=0x%0h, ex=%s, tmask=%b, wb=%0d, rd=%0d, sop=%b, eop=%b, data=..."
        end
    end
end
```
- 모든 commit 출력 추적
- 실행 유닛별, issue별로 구분

## 설계 특징

### 1. Out-of-Order Commit
- 실행 유닛이 준비된 순서대로 commit
- Warp 내 명령어 순서는 보장 안 함 (Scoreboard가 의존성 보장)
- SIMT 모델에서 허용 가능

### 2. Always Accept
- Commit stage는 backpressure 생성 안 함
- 실행 유닛이 block되지 않음
- Scoreboard가 issue 제어

### 3. Pipeline Balancing
- 2단계 파이프라인으로 타이밍 개선
- instret 업데이트 지연 허용 (정확성 유지)

### 4. Multi-Issue Support
- ISSUE_WIDTH개 독립적인 commit 경로
- 각 issue가 NUM_EX_UNITS 중 하나 선택
- 병렬 처리로 throughput 증가

## Commit Size 의미

### SIMD 모델
- 하나의 명령어가 `SIMD_WIDTH`개 스레드 실행
- **tmask**: 실제 활성 스레드 마스크
- **commit_size**: 활성 스레드 수 = 완료된 명령어 수 (SIMD 관점)

### instret CSR
- RISC-V 표준: 완료된 명령어 수
- Vortex: 완료된 스레드 수로 해석
- GPU 컨텍스트에서 의미 있는 메트릭

## Scheduler 통신

### committed_warps
```systemverilog
commit_sched_if.committed_warps[NUM_WARPS-1:0]
```
- **비트맵**: 각 warp의 완료 여부
- **사용**: Scheduler가 다음 명령어 fetch 가능 여부 판단
- **지연**: 1 사이클 (pipe register)

### Warp Unlock (Decode에서)
```systemverilog
decode_sched_if.unlock = ~is_wstall
```
- Branch/Jump 명령어는 warp stall
- Commit 완료 후에도 warp unlock 필요 (decode에서 결정)

## 요약
Commit stage는 파이프라인의 완결자로:
1. **Arbitration**: 다중 실행 유닛 결과 선택
2. **Writeback**: 레지스터 파일 업데이트
3. **CSR Update**: 성능 카운터 업데이트
4. **Scheduler Notify**: 완료된 warp 통지

Out-of-order execution을 지원하면서도 Scoreboard 덕분에 데이터 의존성을 보장하는 핵심 역할을 수행한다.

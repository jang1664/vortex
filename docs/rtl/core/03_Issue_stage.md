# Issue Stage - 명령어 발행

## 개요
Issue stage는 디코딩된 명령어를 실행 가능한 상태로 만드는 단계로, IBuffer, Scoreboard, Operands 수집, Dispatch의 4개 서브 모듈로 구성된다.

**파일**: 
- `hw/rtl/core/VX_issue.sv` (Top-level wrapper)
- `hw/rtl/core/VX_issue_slice.sv` (Issue slice)
- `hw/rtl/core/VX_ibuffer.sv` (Instruction buffer)
- `hw/rtl/core/VX_scoreboard.sv` (Dependency tracking)
- `hw/rtl/core/VX_operands.sv` (Register file read)

## 파이프라인 위치
```
Decode → [ISSUE: IBuffer → Scoreboard → Operands → Dispatch] → Execute → Commit
```

## Issue Width (멀티 이슈)
```systemverilog
ISSUE_WIDTH: 동시 발행 가능한 명령어 수 (1, 2, 4 등)
PER_ISSUE_WARPS = NUM_WARPS / ISSUE_WIDTH

Issue Slice ID (ISW): wid를 ISSUE_WIDTH로 나눈 인덱스
  decode_isw = wid_to_isw(decode_if.data.wid)
  // wid=0,4,8... → isw=0
  // wid=1,5,9... → isw=1
```

## VX_issue (Top-level)
**역할**: Decode 출력을 ISSUE_WIDTH개 슬라이스로 분배

### 입력
```systemverilog
VX_decode_if.slave decode_if
VX_writeback_if.slave writeback_if[ISSUE_WIDTH]
```

### 출력
```systemverilog
VX_dispatch_if.master dispatch_if[NUM_EX_UNITS * ISSUE_WIDTH]
VX_issue_sched_if.master issue_sched_if[ISSUE_WIDTH]
```

### 동작
```systemverilog
wire [ISSUE_ISW_W-1:0] decode_isw = wid_to_isw(decode_if.data.wid);

// 각 슬라이스로 분배
slice_decode_if[issue_id].valid = decode_if.valid && (decode_isw == issue_id);
decode_if.ready = decode_ready_in[decode_isw];
```

## VX_issue_slice (핵심)
각 issue slice는 독립적으로 동작하며 PER_ISSUE_WARPS개 warp를 관리한다.

### 구성 요소
```
decode_if → IBuffer → Scoreboard → Operands → Dispatch
                ↑                      ↑
          writeback_if           writeback_if
```

## 1. IBuffer (Instruction Buffer)

### 파일: VX_ibuffer.sv

### 역할
- 디코딩된 명령어를 warp별로 버퍼링
- UOP sequencing (미세 연산 분할)

### 구조
```systemverilog
for (genvar w = 0; w < PER_ISSUE_WARPS; ++w) begin
    VX_elastic_buffer #(
        .SIZE (IBUF_SIZE),  // 기본값: 2
        .OUT_REG (1)
    ) instr_buf
    
    VX_uop_sequencer uop_sequencer
end
```

### 동작
```
1. Decode 완료된 명령어 수신
2. decode_wis = wid_to_wis(decode_if.data.wid) 계산
3. 해당 warp의 버퍼에 저장
4. UOP sequencer가 명령어를 미세 연산으로 분할 (필요 시)
5. Scoreboard로 전달
```

### UOP Sequencing
일부 명령어는 여러 미세 연산으로 분할:
- **예**: 벡터 연산이 SIMD width보다 클 때
- **SOP (Start of Packet)**: 첫 UOP
- **EOP (End of Packet)**: 마지막 UOP

### IBuffer Pop (L1_ENABLE 없을 때)
```systemverilog
decode_if.ibuf_pop[w] = uop_sequencer_if.valid && uop_sequencer_if.ready;
```
Fetch stage의 pending size 관리에 사용

## 2. Scoreboard (의존성 추적)

### 파일: VX_scoreboard.sv

### 역할
- Register dependency tracking (RAW hazard 방지)
- 실행 유닛 사용 중 추적
- Operands ready 신호 생성

### Warp별 상태
```systemverilog
for (genvar w = 0; w < PER_ISSUE_WARPS; ++w) begin
    reg [NUM_REGS-1:0] inuse_regs;  // 사용 중인 레지스터 비트맵
    
    // NUM_REGS = RV_REGS * REG_TYPES
    // Integer: [0:31], Float: [32:63]
end
```

### 의존성 검사
```systemverilog
// 현재 명령어의 operands
wire [NUM_OPDS-1:0][NUM_REGS_BITS-1:0] stg_opds = {rs3, rs2, rs1, rd};
wire [NUM_OPDS-1:0] stg_used_rs = {used_rs[2:0], wb};

// 각 operand가 사용 중인지 확인
for (genvar i = 0; i < NUM_OPDS; ++i) begin
    wire [REG_TYPE_BITS-1:0] rtype = get_reg_type(stg_opds[i]);
    assign operands_busy[i] = (in_use_mask[rtype] & stg_opd_mask[i][rtype]) != 0;
end

// 모든 operands가 준비됨
assign operands_ready[w] = ~(| regs_busy);
```

### 레지스터 예약/해제
```systemverilog
// 명령어 발행 시: destination 레지스터 예약
if (staging_fire && staging_if[w].data.wb) begin
    inuse_regs[rd] = 1;
end

// Writeback 완료 시: 레지스터 해제
if (writeback_fire && writeback_if.data.eop) begin
    inuse_regs[writeback_if.data.rd] = 0;
end
```

### Staging Buffer
```systemverilog
VX_pipe_buffer stanging_buf (
    .valid_in (ibuffer_if[w].valid),
    .ready_in (ibuffer_if[w].ready),
    .valid_out(staging_if[w].valid),
    .ready_out(staging_if[w].ready)
);
```
- **목적**: Scoreboard 로직 타이밍 개선
- **깊이**: 1 사이클

### 실행 유닛 추적 (PERF_ENABLE)
```systemverilog
reg [NUM_REGS-1:0][EX_WIDTH-1:0] inuse_units;  // 레지스터별 사용 중인 유닛
```
- Destination 레지스터 예약 시 실행 유닛도 기록
- 성능 카운터: 유닛별 사용률 추적

## 3. Operands (레지스터 파일 읽기)

### 파일: VX_operands.sv

### 역할
- Scoreboard에서 준비된 명령어의 operands를 레지스터 파일에서 읽음
- Writeback 데이터 forwarding

### 구조
```systemverilog
for (genvar i = 0; i < NUM_OPCS; i++) begin
    VX_opc_unit #(
        .NUM_BANKS (NUM_GPR_BANKS)
    ) opc_unit (
        .writeback_if,   // Forwarding용
        .scoreboard_if,  // 입력
        .operands_if     // 출력 (rs1_data, rs2_data, rs3_data)
    );
end

VX_stream_arb output_arb (
    .STICKY (OUT_ARB_STICKY)
);
```

### NUM_OPCS (Operand Collector 개수)
```systemverilog
NUM_OPCS = (SIMD_WIDTH > NUM_GPR_BANKS) ? (SIMD_WIDTH / NUM_GPR_BANKS) : 1
```
- **이유**: 레지스터 파일 뱅크 부족 시 여러 사이클에 걸쳐 읽음
- **예**: SIMD_WIDTH=8, NUM_GPR_BANKS=4 → NUM_OPCS=2

### Sticky Arbitration (OUT_ARB_STICKY)
```systemverilog
OUT_ARB_STICKY = (NUM_OPCS != 1) && (SIMD_COUNT != 1)
```
- **문제**: LSU는 같은 warp의 부분 요청을 동시에 처리 불가
- **해결**: Sticky arbiter로 OPC가 완전히 전송될 때까지 고정

### Warp Issue Subindex (WIS)
```systemverilog
wis = wid % PER_ISSUE_WARPS
opc = wis[NUM_OPCS_W-1:0]  // 하위 비트
```
OPC 선택 시 wis의 하위 비트 사용

## 4. Dispatch (실행 유닛으로 전송)

### 파일: VX_dispatch.sv

### 역할
- Operands 준비된 명령어를 실행 유닛별로 라우팅

### 구조
```systemverilog
for (genvar ex_id = 0; ex_id < NUM_EX_UNITS; ++ex_id) begin
    VX_elastic_buffer #(
        .SIZE (2)
    ) req_buf (
        .valid_in (operands_if.valid && (ex_unit == ex_id)),
        .data_in  (operands_if.data),
        .valid_out(dispatch_if[ex_id].valid),
        .data_out (dispatch_if[ex_id].data)
    );
end
```

### 실행 유닛 라우팅
```systemverilog
ex_unit = operands_if.data.ex_type;
// EX_ALU → dispatch_if[EX_ALU]
// EX_LSU → dispatch_if[EX_LSU]
// EX_FPU → dispatch_if[EX_FPU]
// EX_SFU → dispatch_if[EX_SFU]
```

## Scheduler 통신
```systemverilog
issue_sched_if[issue_id].valid = operands_if.valid && operands_if.ready && operands_if.data.sop;
issue_sched_if[issue_id].wis = operands_if.data.wis;
```
- **valid**: 명령어 발행됨
- **sop**: Start of packet (UOP 첫 번째)
- **wis**: Warp issue subindex

## 데이터 흐름

### Forward Path
```
1. Decode → IBuffer (warp별 분리)
2. IBuffer → Scoreboard (staging buffer 경유)
3. Scoreboard: 의존성 검사, operands_ready 생성
4. Scoreboard → Operands (ready 시)
5. Operands: 레지스터 파일 읽기, forwarding
6. Operands → Dispatch
7. Dispatch → Execute units
```

### Backward Path (Writeback)
```
1. Execute units → Commit
2. Commit → Writeback_if
3. Writeback_if → Scoreboard (레지스터 해제)
4. Writeback_if → Operands (forwarding)
```

## Stall 조건

### 1. IBuffer Stall
- IBuffer가 가득 참 (SIZE=2)
- Decode가 대기

### 2. Scoreboard Stall
- Operands busy (의존성 미해결)
- Staging buffer에서 대기

### 3. Operands Stall
- 레지스터 파일 읽기 대기 (뱅크 충돌)
- Sticky arbiter 대기 (다른 OPC 처리 중)

### 4. Dispatch Stall
- 실행 유닛 busy
- Elastic buffer 가득 참

## 성능 고려사항

### 1. Issue Width
- 높을수록 ILP (Instruction-Level Parallelism) 증가
- 하드웨어 복잡도와 트레이드오프

### 2. IBuffer Size
- 크면 버스트 디코딩 가능
- Scoreboard stall 흡수
- 기본값 2는 최소한의 파이프라인 깊이

### 3. GPR Banks
- 많을수록 동시 읽기 가능
- NUM_OPCS 감소 → latency 감소

### 4. Scoreboard 정확도
- Conservative: 모든 RAW hazard 방지
- 불필요한 stall 가능 (false dependency)

## In-Order Issue 특성

### 장점
1. **단순성**: Out-of-order보다 간단한 하드웨어
2. **예측 가능성**: Deterministic 동작
3. **면적 효율**: 복잡한 reorder buffer 불필요

### 단점
1. **ILP 제한**: True dependency 시 stall
2. **Long latency 연산**: FPU, LSU가 파이프라인 블록
3. **Structural hazard**: 실행 유닛 busy 시 대기

### Vortex의 완화 전략
1. **SIMT 모델**: 많은 warp로 latency 숨김
2. **Multi-issue**: ISSUE_WIDTH로 TLP (Thread-Level Parallelism) 활용
3. **Scoreboard**: 준비된 warp만 선택

## 주요 신호

### ibuffer_t
```systemverilog
typedef struct packed {
    logic [`UUID_WIDTH-1:0] uuid;
    logic [`NUM_THREADS-1:0] tmask;
    logic [PC_BITS-1:0] PC;
    logic [EX_BITS-1:0] ex_type;
    logic [INST_OP_BITS-1:0] op_type;
    op_args_t op_args;
    logic wb;
    logic [2:0] used_rs;
    logic [NUM_REGS_BITS-1:0] rd, rs1, rs2, rs3;
} ibuffer_t;
```

### operands_t
```systemverilog
typedef struct packed {
    logic [`UUID_WIDTH-1:0] uuid;
    logic [ISSUE_WIS_W-1:0] wis;
    logic [SID_W-1:0] sid;
    logic [`SIMD_WIDTH-1:0] tmask;
    logic [PC_BITS-1:0] PC;
    logic [EX_BITS-1:0] ex_type;
    logic [INST_OP_BITS-1:0] op_type;
    op_args_t op_args;
    logic wb;
    logic [NUM_REGS_BITS-1:0] rd;
    logic [`SIMD_WIDTH-1:0][`XLEN-1:0] rs1_data, rs2_data, rs3_data;
    logic sop, eop;
} operands_t;
```

## 디버깅

### Trace
```systemverilog
DBG_TRACE_PIPELINE:
- ibuffer: wid, PC, ex_type, op_type, tmask, wb, used_rs, rd/rs1/rs2/rs3
- dispatch: wid, sid, PC, ex_type, op_type, tmask, wb, rd, rs1_data/rs2_data/rs3_data
```

### Scope
- Decode fire, operands fire, writeback 신호 추적
- UUID 기반 명령어 추적

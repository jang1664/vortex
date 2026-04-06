# Execute Stage - 명령어 실행

## 개요
Execute stage는 발행된 명령어를 실제로 실행하는 단계로, 5개의 실행 유닛(ALU, LSU, FPU, SFU, TCU)으로 구성된다.

**파일**: `hw/rtl/core/VX_execute.sv`

## 파이프라인 위치
```
Issue → [EXECUTE: ALU/LSU/FPU/SFU/TCU] → Commit
```

## 실행 유닛 구성
```systemverilog
VX_alu_unit  // Arithmetic, Logic, Branch
VX_lsu_unit  // Load, Store, Fence
VX_fpu_unit  // Floating-Point (EXT_F_ENABLE)
VX_sfu_unit  // Special Function (CSR, Warp control)
VX_tcu_unit  // Tensor Core (EXT_TCU_ENABLE)
```

## 인터페이스

### 입력
```systemverilog
VX_dispatch_if.slave dispatch_if[NUM_EX_UNITS * ISSUE_WIDTH]
- ISSUE_WIDTH: Issue width (동시 발행 수)
- NUM_EX_UNITS: 실행 유닛 개수 (5개)
- 배치: [EX_ALU][0..ISSUE_WIDTH-1], [EX_LSU][0..ISSUE_WIDTH-1], ...
```

### 출력
```systemverilog
VX_commit_if.master commit_if[NUM_EX_UNITS * ISSUE_WIDTH]
- 각 실행 유닛의 결과를 commit stage로 전달
```

### 제어 인터페이스
```systemverilog
VX_sched_csr_if.slave sched_csr_if        // CSR 읽기 (scheduler용)
VX_branch_ctl_if.master branch_ctl_if[NUM_ALU_BLOCKS]  // Branch 결과
VX_warp_ctl_if.master warp_ctl_if         // Warp control 결과
VX_commit_csr_if.slave commit_csr_if      // CSR 쓰기 (commit으로부터)
```

### 메모리 인터페이스
```systemverilog
VX_lsu_mem_if.master lsu_mem_if[NUM_LSU_BLOCKS]  // LSU → Memory hierarchy
```

## 1. ALU Unit (Arithmetic Logic Unit)

### 파일: VX_alu_unit.sv

### 담당 연산
- **Arithmetic**: ADD, SUB, LUI, AUIPC
- **Logic**: AND, OR, XOR
- **Shift**: SLL, SRL, SRA
- **Compare**: SLT, SLTU
- **Branch**: BEQ, BNE, BLT, BGE, BLTU, BGEU, JAL, JALR
- **SIMT**: VOTE, SHUFFLE (커스텀)
- **Conditional**: CZERO.EQZ, CZERO.NEZ (Zicond)

### Block 구조
```systemverilog
NUM_ALU_BLOCKS: ALU 블록 개수 (일반적으로 ISSUE_WIDTH)

for (genvar i = 0; i < NUM_ALU_BLOCKS; ++i) begin
    VX_alu_int   alu_int_inst    // Integer ALU
    VX_alu_muldiv alu_muldiv_inst  // Multiplier/Divider (EXT_M_ENABLE)
end
```

### 주요 특징
- **Low latency**: 대부분 1 사이클 (MUL/DIV 제외)
- **Branch resolution**: 분기 결과를 branch_ctl_if로 전달
- **Pipeline depth**: 
  - Integer: 1 cycle
  - MUL: 여러 cycle (파이프라인)
  - DIV: 여러 cycle (반복)

### Branch Control
```systemverilog
branch_ctl_if[i].valid  // 분기 명령어 완료
branch_ctl_if[i].wid    // Warp ID
branch_ctl_if[i].taken  // 분기 taken 여부
branch_ctl_if[i].dest   // 분기 목적지 주소
```
Scheduler가 이를 받아 warp의 PC 업데이트

## 2. LSU Unit (Load-Store Unit)

### 파일: VX_lsu_unit.sv

### 담당 연산
- **Load**: LB, LH, LW, LD, LBU, LHU, LWU
- **Store**: SB, SH, SW, SD
- **Floating-Point**: FLW, FLD, FSW, FSD
- **Fence**: Memory ordering

### Block 구조
```systemverilog
NUM_LSU_BLOCKS: LSU 블록 개수

for (genvar i = 0; i < NUM_LSU_BLOCKS; ++i) begin
    VX_lsu_slice lsu_slice_inst
        → VX_mem_scheduler
        → VX_lmem_switch (Local/Global 분리)
        → Local memory / Global memory (cache)
end
```

### 메모리 계층
```
LSU → VX_lmem_switch → Local Memory (Shared/Scratchpad)
                    → VX_mem_unit → D-Cache → L2/L3 → DRAM
```

### 주요 특징
- **Variable latency**: 캐시 히트/미스에 따라 다름
- **Address calculation**: base + offset
- **Alignment check**: Misaligned access 불가 (assertion)
- **Coalescing**: 같은 캐시 라인 접근 병합
- **Out-of-order completion**: TAG 기반 매칭

### 메모리 타입
```systemverilog
MEM_REQ_FLAG_LOCAL: Local memory (shared)
MEM_REQ_FLAG_IO:    I/O memory (uncached)
기타:               Global memory (cached)
```

## 3. FPU Unit (Floating-Point Unit)

### 파일: VX_fpu_unit.sv (EXT_F_ENABLE)

### 담당 연산
- **Arithmetic**: FADD, FSUB, FMUL, FDIV, FSQRT
- **Fused Multiply-Add**: FMADD, FMSUB, FNMSUB, FNMADD
- **Compare**: FEQ, FLT, FLE
- **Conversion**: FCVT.W.S, FCVT.S.W, FCVT.D.S, FCVT.S.D
- **Move**: FMV.X.W, FMV.W.X
- **Sign-injection**: FSGNJ, FSGNJN, FSGNJX
- **Min/Max**: FMIN, FMAX
- **Classify**: FCLASS

### Block 구조
```systemverilog
NUM_FPU_BLOCKS: FPU 블록 개수

for (genvar i = 0; i < NUM_FPU_BLOCKS; ++i) begin
    VX_fpu_agent fpu_agent_inst
end
```

### 주요 특징
- **Long latency**: 여러 사이클 (연산에 따라 다름)
- **Pipelined**: 높은 처리량
- **Rounding modes**: RNE, RTZ, RDN, RUP, RMM
- **Exception flags**: NV, DZ, OF, UF, NX (fflags)

### FPU CSR
```systemverilog
VX_fpu_csr_if fpu_csr_if[NUM_FPU_BLOCKS]
- frm: Rounding mode
- fflags: Exception flags
```

## 4. SFU Unit (Special Function Unit)

### 파일: VX_sfu_unit.sv

### 담당 연산
- **CSR**: CSRRW, CSRRS, CSRRC (및 immediate 버전)
- **Warp Control**: TMC, WSPAWN, SPLIT, JOIN, BAR, PRED
- **Performance Counters**: 읽기
- **GPU 상태**: Warp ID, Thread ID, 블록/그리드 정보

### SFU 서브 유닛
```systemverilog
VX_wctl_unit  // Warp control (WSPAWN, SPLIT, JOIN, ...)
VX_gather_unit // Thread data gathering (성능 카운터)
```

### CSR 주소 공간
```systemverilog
VX_CSR_FFLAGS, VX_CSR_FRM, VX_CSR_FCSR    // FPU CSR
VX_CSR_SATP, VX_CSR_MSTATUS, ...          // Supervisor/Machine CSR
VX_CSR_WTID, VX_CSR_LTID, VX_CSR_GTID     // Thread ID
VX_CSR_LWID, VX_CSR_GWID                  // Warp ID
VX_CSR_GCID, VX_CSR_GSIZE                 // Grid info
VX_CSR_MPM_*                              // Performance counters
```

### Warp Control
```systemverilog
warp_ctl_if.valid    // Warp control 명령어 실행
warp_ctl_if.wid      // Target warp ID
warp_ctl_if.wspawn   // Warp spawn
warp_ctl_if.split    // Divergence split
warp_ctl_if.tmc      // Thread mask control
warp_ctl_if.barrier  // Barrier sync
```

### 주요 특징
- **Variable latency**: CSR 읽기는 빠름, warp control은 느림
- **Side effects**: Warp 상태 변경, barrier 동기화
- **CSR forwarding**: commit_csr_if로 최신 값 전달

## 5. TCU Unit (Tensor Core Unit)

### 파일: VX_tcu_unit.sv (EXT_TCU_ENABLE)

### 담당 연산
- **WMMA**: Warp-level Matrix Multiply-Accumulate
- **Tensor formats**: FP16, FP32, INT8, INT16

### 주요 특징
- **High throughput**: Matrix 연산 가속
- **Deep pipeline**: 여러 사이클 레이턴시

## 실행 유닛 선택
```systemverilog
// Dispatch stage에서 이미 분리됨
dispatch_if[EX_ALU * ISSUE_WIDTH +: ISSUE_WIDTH] → ALU
dispatch_if[EX_LSU * ISSUE_WIDTH +: ISSUE_WIDTH] → LSU
dispatch_if[EX_FPU * ISSUE_WIDTH +: ISSUE_WIDTH] → FPU
dispatch_if[EX_SFU * ISSUE_WIDTH +: ISSUE_WIDTH] → SFU
dispatch_if[EX_TCU * ISSUE_WIDTH +: ISSUE_WIDTH] → TCU
```

## Commit Interface

### commit_t 구조
```systemverilog
typedef struct packed {
    logic [`UUID_WIDTH-1:0] uuid;
    logic [ISSUE_WIS_W-1:0] wis;
    logic [`SIMD_WIDTH-1:0] tmask;
    logic [NUM_REGS_BITS-1:0] rd;
    logic [`SIMD_WIDTH-1:0][`XLEN-1:0] data;
    logic wb;       // Writeback 필요 여부
    logic eop;      // End of packet
    logic sop;      // Start of packet
} commit_t;
```

### 출력 시점
- **ALU**: 연산 완료 즉시 (1~수십 사이클)
- **LSU**: 메모리 응답 수신 시 (가변)
- **FPU**: 파이프라인 완료 시 (수 사이클)
- **SFU**: CSR 읽기 또는 warp control 완료 시
- **TCU**: Matrix 연산 완료 시

## Out-of-Order Completion
- Issue는 in-order이지만 실행은 out-of-order
- 각 실행 유닛이 독립적으로 완료
- Commit stage에서 warp별로 재정렬 (순서 보장은 안 함)
- Scoreboard가 의존성 보장 (writeback으로 해제)

## 성능 최적화

### 1. 다중 블록
```systemverilog
NUM_ALU_BLOCKS, NUM_LSU_BLOCKS, NUM_FPU_BLOCKS
```
- ISSUE_WIDTH와 매칭하여 병렬 처리
- 각 블록이 독립적인 명령어 처리

### 2. Pipelining
- ALU: Integer 1 cycle, MUL 여러 cycle
- FPU: 깊은 파이프라인 (FADD ~5, FDIV ~20 cycle)
- LSU: Cache hierarchy 파이프라인

### 3. Warp 전환
- Long latency 연산 중 다른 warp 실행
- Scoreboard가 준비된 warp만 issue
- SIMT 모델의 핵심 장점

## 주요 신호 흐름

### Forward Path
```
1. Dispatch → Execute unit
2. Execute unit: 연산 수행
3. ALU: Branch control 생성 (분기 시)
4. LSU: Memory request 생성
5. SFU: Warp control 신호 생성
6. Execute unit → Commit
```

### Backward Path
```
1. Commit → Writeback
2. Writeback → Scoreboard (레지스터 해제)
3. Writeback → Operands (forwarding)
4. Commit → CSR update (CSR 명령어 시)
5. Branch control → Scheduler (PC 업데이트)
6. Warp control → Scheduler (Warp 상태 변경)
```

## 디버깅

### Trace
```systemverilog
DBG_TRACE_PIPELINE:
- ALU: wid, PC, op_type, result, branch taken/dest
- LSU: wid, PC, addr, byteen, data (read/write)
- FPU: wid, PC, op_type, operands, result
- SFU: wid, PC, CSR addr/data, warp control
```

### Performance Counters (PERF_ENABLE)
```systemverilog
sysmem_perf: Memory hierarchy 성능
pipeline_perf: Pipeline stage 성능
- ALU/LSU/FPU/SFU 사용률
- Cache 히트/미스
- Stall 사이클
```

## 설계 특징

### 1. 모듈화
- 각 실행 유닛이 독립적
- 새로운 유닛 추가 용이

### 2. 확장 가능성
- `EXT_F_ENABLE`, `EXT_TCU_ENABLE`으로 선택적 활성화
- 면적/성능 트레이드오프

### 3. In-Order Issue, Out-of-Order Completion
- Issue는 순서 보장
- 실행은 준비된 순서대로
- Scoreboard가 데이터 의존성 보장

### 4. SIMT 최적화
- 모든 실행 유닛이 SIMD_WIDTH 레인 처리
- Warp divergence 지원 (tmask)
- Thread-level parallelism 활용

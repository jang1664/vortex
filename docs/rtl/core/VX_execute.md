# `core/VX_execute.sv` — Execute Stage Top Module

## 개요

Vortex GPU 파이프라인의 Execute Stage를 구현하는 최상위 모듈.
Issue Stage에서 디스패치된 명령어를 받아 적절한 실행 유닛으로 라우팅하고,
실행 결과를 Commit Stage로 전달한다.

## 파이프라인 위치

```
Schedule → Fetch → Decode → Issue → [EXECUTE] → Commit → Writeback
```

## 모듈 파라미터

| 파라미터 | 설명 |
|----------|------|
| `INSTANCE_ID` | 디버깅용 인스턴스 식별자 |
| `CORE_ID` | 멀티코어 환경에서 현재 코어 ID |

## 실행 유닛 구성

`VX_gpu_pkg.sv`에서 정의된 EX_* 상수로 식별:

| 유닛 | ID | 모듈 | 담당 명령어 | 조건 |
|------|------|------|-------------|------|
| ALU | 0 | `VX_alu_unit` | 정수 연산, 분기 | 항상 |
| LSU | 1 | `VX_lsu_unit` | Load/Store | 항상 |
| SFU | 2 | `VX_sfu_unit` | CSR, Warp Control | 항상 |
| FPU | 3 | `VX_fpu_unit` | 부동소수점 | `EXT_F_ENABLE` |
| TCU | 4 | `VX_tcu_unit` | Tensor Core | `EXT_TCU_ENABLE` |

## 인터페이스

### 입력 인터페이스

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `dispatch_if` | `VX_dispatch_if.slave` | Issue Stage에서 명령어 수신 |
| `sched_csr_if` | `VX_sched_csr_if.slave` | Scheduler에서 CSR 데이터 읽기 |
| `commit_csr_if` | `VX_commit_csr_if.slave` | Commit에서 instret 카운터 수신 |
| `base_dcrs` | `base_dcrs_t` | Device Control Registers |

### 출력 인터페이스

| 인터페이스 | 타입 | 설명 |
|-----------|------|------|
| `commit_if` | `VX_commit_if.master` | Commit Stage로 실행 결과 전달 |
| `lsu_mem_if` | `VX_lsu_mem_if.master` | Memory Hierarchy로 메모리 요청 |
| `branch_ctl_if` | `VX_branch_ctl_if.master` | Scheduler로 분기 결과 전달 |
| `warp_ctl_if` | `VX_warp_ctl_if.master` | Scheduler로 warp 제어 신호 전달 |

### 조건부 인터페이스

| 인터페이스 | 조건 | 설명 |
|-----------|------|------|
| `fpu_csr_if` | `EXT_F_ENABLE` | FPU ↔ SFU CSR 통신 |
| `sysmem_perf`, `pipeline_perf` | `PERF_ENABLE` | 성능 카운터 입력 |

## 인터페이스 배치

dispatch_if와 commit_if는 모든 실행 유닛에 대해 배열로 구성:

```systemverilog
// 각 실행 유닛은 ISSUE_WIDTH 개의 슬롯 사용
dispatch_if[EX_ALU * ISSUE_WIDTH +: ISSUE_WIDTH]  → ALU
dispatch_if[EX_LSU * ISSUE_WIDTH +: ISSUE_WIDTH]  → LSU
dispatch_if[EX_SFU * ISSUE_WIDTH +: ISSUE_WIDTH]  → SFU
dispatch_if[EX_FPU * ISSUE_WIDTH +: ISSUE_WIDTH]  → FPU (조건부)
dispatch_if[EX_TCU * ISSUE_WIDTH +: ISSUE_WIDTH]  → TCU (조건부)
```

## 데이터 흐름

```
                    ┌─────────────────────────────────────────────────────┐
                    │                   VX_execute                        │
                    │                                                     │
  dispatch_if ──────┼──→ VX_alu_unit ───→ commit_if ──────────────────────┼──→
       │            │         │                                           │
       │            │         └──→ branch_ctl_if ─────────────────────────┼──→ Scheduler
       │            │                                                     │
       ├────────────┼──→ VX_lsu_unit ───→ commit_if ──────────────────────┼──→
       │            │         │                                           │
       │            │         └──→ lsu_mem_if ────────────────────────────┼──→ Memory
       │            │                                                     │
       ├────────────┼──→ VX_sfu_unit ───→ commit_if ──────────────────────┼──→
       │            │         │                                           │
       │            │         └──→ warp_ctl_if ───────────────────────────┼──→ Scheduler
       │            │                                                     │
       ├────────────┼──→ VX_fpu_unit ───→ commit_if ──────────────────────┼──→
       │            │         │                                           │
       │            │         └──→ fpu_csr_if ←──→ VX_sfu_unit            │
       │            │                                                     │
       └────────────┼──→ VX_tcu_unit ───→ commit_if ──────────────────────┼──→
                    │                                                     │
                    └─────────────────────────────────────────────────────┘
```

## 실행 유닛 상세

### ALU Unit (VX_alu_unit)

**담당 명령어:**
- 산술: ADD, SUB, LUI, AUIPC
- 논리: AND, OR, XOR
- 시프트: SLL, SRL, SRA
- 비교: SLT, SLTU
- 분기: BEQ, BNE, BLT, BGE, JAL, JALR
- SIMT 확장: VOTE, SHUFFLE
- 조건부 제로 (Zicond): CZERO.EQZ, CZERO.NEZ
- M 확장: MUL, MULH, DIV, REM

**출력:** `commit_if`, `branch_ctl_if`

### LSU Unit (VX_lsu_unit)

**담당 명령어:**
- Load: LB, LH, LW, LD, LBU, LHU, LWU
- Store: SB, SH, SW, SD
- FP Load/Store: FLW, FLD, FSW, FSD
- Fence: 메모리 순서 보장

**메모리 계층:**
- Local Memory (shared/scratchpad)
- D-Cache → L2/L3 → DRAM

**특징:**
- Variable latency (캐시 히트/미스에 따라)
- Coalescing: 같은 캐시 라인 접근 병합

### FPU Unit (VX_fpu_unit)

**조건:** `EXT_F_ENABLE`

**담당 명령어:**
- 산술: FADD, FSUB, FMUL, FDIV, FSQRT
- FMA: FMADD, FMSUB, FNMSUB, FNMADD
- 비교: FEQ, FLT, FLE
- 변환: FCVT.W.S, FCVT.S.W, ...
- 이동: FMV.X.W, FMV.W.X
- 부호: FSGNJ, FSGNJN, FSGNJX
- Min/Max: FMIN, FMAX
- 분류: FCLASS

**특징:**
- 파이프라인 구조 (multi-cycle)
- fflags 예외 플래그 생성 → SFU로 전달

### TCU Unit (VX_tcu_unit)

**조건:** `EXT_TCU_ENABLE`

**담당 명령어:**
- WMMA: Warp-level Matrix Multiply-Accumulate

**특징:**
- 행렬 연산 가속
- 딥 파이프라인

### SFU Unit (VX_sfu_unit)

**담당 명령어:**
- CSR 접근: CSRRW, CSRRS, CSRRC
- Warp 제어: TMC, WSPAWN, SPLIT, JOIN, BAR, PRED
- 성능 카운터 읽기
- GPU 상태: Thread ID, Warp ID, Grid 정보

**서브 유닛:**
- VX_wctl_unit: Warp 제어
- VX_gather_unit: 스레드 데이터 수집

## 주요 특징

### In-Order Issue, Out-of-Order Completion

- 명령어는 순서대로 발행 (Issue Stage)
- 실행 완료는 비순차적 가능
  - LSU: 캐시 미스 시 지연
  - FPU: 연산별 다른 레이턴시
- Scoreboard가 데이터 의존성 관리

### 병렬 실행

- 각 실행 유닛이 독립적으로 동작
- `ISSUE_WIDTH` 개의 병렬 슬롯
- `NUM_*_BLOCKS` 파라미터로 유닛별 병렬도 조절

### 조건부 인스턴스화

```systemverilog
`ifdef EXT_F_ENABLE
    VX_fpu_unit fpu_unit (...);
`endif

`ifdef EXT_TCU_ENABLE
    VX_tcu_unit tcu_unit (...);
`endif
```

## 관련 파일

### 인터페이스 정의
- [VX_dispatch_if.sv](../../../hw/rtl/interfaces/VX_dispatch_if.sv) - dispatch_t 구조
- [VX_commit_if.sv](../../../hw/rtl/interfaces/VX_commit_if.sv) - commit_t 구조
- [VX_branch_ctl_if.sv](../../../hw/rtl/interfaces/VX_branch_ctl_if.sv) - 분기 제어
- [VX_warp_ctl_if.sv](../../../hw/rtl/interfaces/VX_warp_ctl_if.sv) - warp 제어
- [VX_sched_csr_if.sv](../../../hw/rtl/interfaces/VX_sched_csr_if.sv) - CSR 통신
- [VX_fpu_csr_if.sv](../../../hw/rtl/fpu/VX_fpu_csr_if.sv) - FPU CSR

### 실행 유닛
- [VX_alu_unit.sv](../../../hw/rtl/core/VX_alu_unit.sv)
- [VX_lsu_unit.sv](../../../hw/rtl/core/VX_lsu_unit.sv)
- [VX_sfu_unit.sv](../../../hw/rtl/core/VX_sfu_unit.sv)
- [VX_fpu_unit.sv](../../../hw/rtl/fpu/VX_fpu_unit.sv)
- [VX_tcu_unit.sv](../../../hw/rtl/tcu/VX_tcu_unit.sv)

### 관련 문서
- [04_Execute_stage.md](04_Execute_stage.md) - Execute Stage 전체 개요
- [VX_alu_unit.md](VX_alu_unit.md) - ALU 유닛 상세
- [VX_alu_int.md](VX_alu_int.md) - 정수 ALU 상세

## 디버깅 팁

### SCOPE_IO

시뮬레이션 시 LSU에 디버깅 스코프 바인딩:
```systemverilog
`SCOPE_IO_SWITCH (1);
VX_lsu_unit lsu_unit (
    `SCOPE_IO_BIND (0)
    ...
);
```

### 트레이스 출력

`DBG_TRACE_PIPELINE` 활성화 시 각 유닛의 동작 추적 가능.

### 성능 카운터

`PERF_ENABLE` 활성화 시:
- `sysmem_perf`: 메모리 계층 통계
- `pipeline_perf`: 파이프라인 스테이지 통계

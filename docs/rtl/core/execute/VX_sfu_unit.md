# `core/VX_sfu_unit.sv` — Special Function Unit

## 개요

CSR 접근과 Warp 제어 명령어를 처리하는 실행 유닛.
SIMT divergence 관리(TMC, SPLIT, JOIN)와 시스템 레지스터 접근을 담당.

## 아키텍처

```
                    ┌──────────────────────────────────────────────────────────────┐
                    │                      VX_sfu_unit                              │
                    │                                                              │
dispatch_if ───────┼──→ [VX_dispatch_unit] ──→ [VX_pe_switch] ──┬──→ [VX_wctl_unit]│
[ISSUE_WIDTH]       │         (패킷 분할)           (PE 선택)   │        ↓         │
                    │                                           │   warp_ctl_if ───┼──→ Scheduler
                    │                                           │        ↓         │
                    │                                           └──→ [VX_csr_unit] │
                    │                                                    ↓         │
                    │                          ┌─────────────────────────┘         │
                    │                          ▼                                   │
commit_if ←────────┼──← [VX_gather_unit] ←── result_if                            │
[ISSUE_WIDTH]       │       (패킷 병합)                                            │
                    └──────────────────────────────────────────────────────────────┘

외부 인터페이스:
  ← fpu_csr_if[NUM_FPU_BLOCKS]  : FPU CSR 접근 (fflags, frm)
  ← commit_csr_if               : Commit CSR (instret)
  ← sched_csr_if                : Scheduler CSR (cycles, active_warps)
```

## 모듈 파라미터

| 파라미터 | 값 | 설명 |
|----------|-----|------|
| `BLOCK_SIZE` | 1 | SFU 블록 수 (항상 1) |
| `NUM_LANES` | `NUM_SFU_LANES` | 레인 수 |
| `PE_COUNT` | 2 | PE 수 (WCTL, CSR) |

## PE 선택 로직

```systemverilog
localparam PE_IDX_WCTL = 0;  // Warp Control
localparam PE_IDX_CSRS = 1;  // CSR

always @(*) begin
    pe_select = PE_IDX_WCTL;  // 기본: Warp Control
    if (inst_sfu_is_csr(op_type)) begin
        pe_select = PE_IDX_CSRS;  // CSR 명령어면 CSR 유닛
    end
end
```

## 서브모듈 구성

```
VX_sfu_unit
├── VX_dispatch_unit     : 패킷 분할 (SIMD_WIDTH → NUM_LANES)
├── VX_pe_switch         : PE 라우팅 (WCTL or CSR)
│   ├── VX_wctl_unit     : Warp 제어 명령어 처리
│   │   └── warp_ctl_if  : → Scheduler로 제어 신호
│   └── VX_csr_unit      : CSR 읽기/쓰기
│       └── VX_csr_data  : CSR 레지스터 저장소
└── VX_gather_unit       : 패킷 병합 (NUM_LANES → SIMD_WIDTH)
```

## 지원 명령어

| 명령어 | PE | 설명 |
|--------|-----|------|
| TMC | WCTL | Thread Mask Control |
| PRED | WCTL | Predicated execution |
| WSPAWN | WCTL | Warp Spawn |
| SPLIT | WCTL | Divergence Split |
| JOIN | WCTL | Divergence Join |
| BARRIER | WCTL | Warp Barrier |
| CSRRW | CSR | CSR Read/Write |
| CSRRS | CSR | CSR Read and Set |
| CSRRC | CSR | CSR Read and Clear |

## 인터페이스

### 입력

| 인터페이스 | 설명 |
|-----------|------|
| `dispatch_if[ISSUE_WIDTH]` | Issue Stage에서 명령어 수신 |
| `fpu_csr_if[NUM_FPU_BLOCKS]` | FPU CSR 접근 (fflags 누적) |
| `commit_csr_if` | Commit 통계 (instret) |
| `sched_csr_if` | Scheduler 상태 (cycles, active_warps) |
| `base_dcrs` | Device Configuration Registers |

### 출력

| 인터페이스 | 설명 |
|-----------|------|
| `commit_if[ISSUE_WIDTH]` | Commit Stage로 결과 전달 |
| `warp_ctl_if` | Scheduler로 Warp 제어 신호 |

## 관련 파일

- [VX_wctl_unit.md](VX_wctl_unit.md) - Warp Control 유닛 상세
- [VX_csr_unit.md](VX_csr_unit.md) - CSR 유닛 상세
- [VX_gather_unit.md](VX_gather_unit.md) - Gather 유닛 상세
- [VX_dispatch_unit.md](VX_dispatch_unit.md) - Dispatch 유닛
- [VX_pe_switch.md](VX_pe_switch.md) - PE 스위치

# `core/VX_csr_unit.sv` — CSR Unit

## 개요

RISC-V Control and Status Register (CSR) 접근을 처리하는 유닛.
시스템 정보 읽기, 성능 카운터, FPU 상태 레지스터 관리를 담당.

## 아키텍처

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    VX_csr_unit                           │
                    │                                                         │
execute_if ────────┼──→ ┌──────────────────────────────────────────────────┐ │
                    │    │               CSR 주소 디코딩                     │ │
                    │    │                                                  │ │
                    │    │  ┌────────────┐     ┌────────────────────────┐  │ │
                    │    │  │ Read Logic │     │     VX_csr_data        │  │ │
                    │    │  │            │←────│  (CSR 레지스터 저장소)   │  │ │
                    │    │  │ THREAD_ID  │     │  - mscratch            │  │ │
                    │    │  │ MHARTID    │     │  - fcsr (FPU)          │  │ │
                    │    │  │ (직접계산) │     │  - perf counters       │  │ │
                    │    │  └────────────┘     └────────────────────────┘  │ │
                    │    │         │                      ↑                │ │
                    │    │         ▼                      │                │ │
                    │    │  ┌────────────┐     ┌──────────┴───────────┐   │ │
                    │    │  │Write Logic │────→│  CSRRW/CSRRS/CSRRC   │   │ │
                    │    │  └────────────┘     └──────────────────────┘   │ │
                    │    └─────────────────────────────────────────────────┘ │
                    │                         │                              │
                    │              ┌──────────▼──────────┐                   │
                    │              │  VX_elastic_buffer  │                   │
                    │              └──────────┬──────────┘                   │
                    └─────────────────────────┼──────────────────────────────┘
                                              ▼
                                          result_if
```

## CSR 명령어

| 명령어 | 동작 |
|--------|------|
| CSRRW | rd = CSR; CSR = rs1 |
| CSRRS | rd = CSR; CSR = CSR \| rs1 |
| CSRRC | rd = CSR; CSR = CSR & ~rs1 |

```systemverilog
always @(*) begin
    case (execute_if.data.op_type)
        INST_SFU_CSRRW: csr_write_data = csr_req_data;
        INST_SFU_CSRRS: csr_write_data = csr_read_data_rw | csr_req_data;
        INST_SFU_CSRRC: csr_write_data = csr_read_data_rw & ~csr_req_data;
    endcase
end
```

## 지원 CSR 목록

### Read-Only CSR

| 주소 | 이름 | 설명 |
|------|------|------|
| 0xF11 | MVENDORID | Vendor ID |
| 0xF12 | MARCHID | Architecture ID |
| 0xF13 | MIMPID | Implementation ID |
| 0x301 | MISA | ISA 확장 비트맵 |
| 0xCC0 | THREAD_ID | 스레드 ID (warp 내) |
| 0xCC1 | WARP_ID | Warp ID |
| 0xCC2 | CORE_ID | Core ID |
| 0xCC4 | ACTIVE_THREADS | 활성 스레드 마스크 |
| 0xCC5 | ACTIVE_WARPS | 활성 Warp 마스크 |
| 0xFC0 | NUM_THREADS | Warp당 스레드 수 |
| 0xFC1 | NUM_WARPS | Core당 Warp 수 |
| 0xFC2 | NUM_CORES | 전체 Core 수 |
| 0xB00 | MCYCLE | 사이클 카운터 |
| 0xB02 | MINSTRET | 명령어 retire 카운터 |
| 0xF14 | MHARTID | 전역 Hart ID |

### Read-Write CSR

| 주소 | 이름 | 설명 |
|------|------|------|
| 0x340 | MSCRATCH | Machine scratch register |
| 0x001 | FFLAGS | FPU 예외 플래그 (EXT_F) |
| 0x002 | FRM | FPU 반올림 모드 (EXT_F) |
| 0x003 | FCSR | FPU 제어/상태 (EXT_F) |

## Thread ID 계산

각 레인마다 다른 Thread ID 반환:

```systemverilog
// Warp 내 Thread ID
for (genvar i = 0; i < NUM_LANES; ++i) begin
    if (PID_BITS != 0) begin
        assign wtid[i] = `XLEN'(execute_if.data.pid * NUM_LANES + i);
    end else begin
        assign wtid[i] = `XLEN'(i);
    end
end

// 전역 Hart ID (MHARTID)
for (genvar i = 0; i < NUM_LANES; ++i) begin
    assign gtid[i] = (CORE_ID << (NW_BITS + NT_BITS))
                   + (wid << NT_BITS)
                   + wtid[i];
end
```

**예시** (CORE_ID=1, wid=2, NUM_LANES=4, pid=1):
```
wtid[0] = 4, wtid[1] = 5, wtid[2] = 6, wtid[3] = 7
gtid[0] = (1 << 6) + (2 << 4) + 4 = 100
```

## FPU CSR 특수 처리

### FPU CSR 접근 시 Stall

FPU 명령어가 진행 중일 때 FPU CSR 접근 방지:

```systemverilog
wire is_fpu_csr = (csr_addr <= `VX_CSR_FCSR);

// Scheduler에 alm_empty 확인 요청
assign sched_csr_if.alm_empty_wid = execute_if.data.wid;
wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;

// pending 명령어 있으면 stall
wire csr_req_valid = execute_if.valid && no_pending_instr;
assign execute_if.ready = csr_req_ready && no_pending_instr;
```

### FFLAGS 누적

FPU 블록에서 예외 플래그 누적:

```systemverilog
// VX_csr_data.sv
always @(*) begin
    fcsr_n = fcsr;
    // FPU 블록에서 오는 fflags OR 연산
    for (integer i = 0; i < `NUM_FPU_BLOCKS; ++i) begin
        if (fpu_write_enable[i]) begin
            fcsr_n[fpu_write_wid[i]][`FP_FLAGS_BITS-1:0] =
                fcsr[fpu_write_wid[i]][`FP_FLAGS_BITS-1:0] | fpu_write_fflags[i];
        end
    end
end
```

### FRM 읽기

FPU가 반올림 모드 조회:

```systemverilog
for (genvar i = 0; i < `NUM_FPU_BLOCKS; ++i) begin
    assign fpu_csr_if[i].read_frm = fcsr[fpu_csr_if[i].read_wid][FRM_BITS-1:0];
end
```

## 성능 카운터 (PERF_ENABLE)

### Core 성능

| CSR | 설명 |
|-----|------|
| MPM_SCHED_ID | Scheduler idle 사이클 |
| MPM_SCHED_ST | Scheduler stall 사이클 |
| MPM_IBUF_ST | Instruction buffer stall |
| MPM_SCRB_ST | Scoreboard stall |
| MPM_OPDS_ST | Operand stall |
| MPM_SCRB_ALU/LSU/SFU/FPU | 각 유닛 사용 횟수 |

### Memory 성능

| CSR | 설명 |
|-----|------|
| MPM_ICACHE_READS | I-cache 읽기 횟수 |
| MPM_ICACHE_MISS_R | I-cache miss 횟수 |
| MPM_DCACHE_READS/WRITES | D-cache 접근 |
| MPM_DCACHE_MISS_R/W | D-cache miss |
| MPM_L2/L3CACHE_* | L2/L3 캐시 통계 |
| MPM_MEM_READS/WRITES | 메모리 접근 |

## Warp Unlock

FPU CSR 접근 완료 후 warp unlock 신호:

```systemverilog
// EOP에서 FPU CSR 접근 완료 시 unlock
assign sched_csr_if.unlock_warp = csr_req_valid && csr_req_ready
                                && execute_if.data.eop && is_fpu_csr;
assign sched_csr_if.unlock_wid = execute_if.data.wid;
```

## 데이터 흐름

```
execute_if.data
     │
     ├── op_args.csr.addr ──→ CSR 주소 디코딩
     │                              │
     │                    ┌─────────┴─────────┐
     │                    ▼                   ▼
     │              직접 계산            VX_csr_data
     │           (THREAD_ID,            (MSCRATCH,
     │            MHARTID)               FCSR, ...)
     │                    │                   │
     │                    └─────────┬─────────┘
     │                              ▼
     ├── op_args.csr.use_imm ──→ Write 값 선택
     │   rs1_data ─────────────→ (imm or rs1)
     │                              │
     │                              ▼
     │                    ┌─────────────────────┐
     │                    │ CSRRW/CSRRS/CSRRC   │
     │                    │    연산 수행         │
     │                    └─────────────────────┘
     │                              │
     └──────────────────────────────┼──────────────→ result_if.data.data
                                    │                (레인별 CSR 값)
                                    ▼
                              VX_csr_data
                              (CSR 갱신)
```

## 성능 특성

- **레이턴시**: 2 사이클 (elastic buffer)
- **FPU CSR Stall**: pending FPU 명령어 있으면 대기
- **스루풋**: 사이클당 1 명령어

## 관련 파일

- [VX_sfu_unit.sv](VX_sfu_unit.md) - 상위 모듈
- [VX_csr_data.sv](../../../../hw/rtl/core/VX_csr_data.sv) - CSR 저장소
- [VX_sched_csr_if.sv](../../../../hw/rtl/interfaces/VX_sched_csr_if.sv) - Scheduler CSR 인터페이스
- [VX_fpu_csr_if.sv](../../../../hw/rtl/interfaces/VX_fpu_csr_if.sv) - FPU CSR 인터페이스

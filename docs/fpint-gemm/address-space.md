# FPINT GEMM Address Space Map

## Memory Regions

- 여러 개의 address space 존재
    - 서로 다른 address space은 주소 겹침 고려 안함.
    - core 마다 CSR이 있음. CSR 접근은 CSR 명령의 12-bit immediate로 접근 (소프트웨어에선 csrr/csrw 또는 csr_read/csr_write 매크로 사용)
    - 각 instruction 마다 어떤 주소 공간을 접근하지는 정해져 있다.
    
    ```bash
    csrr x?, 0xB00 -> CSR 공간 접근
    lw x?, 0xB00(x0) -> 메모리 or IO 공간 접근
    ```
    
- 주소 공간 종류
    - CSR
    - memory
    - IO

## XLEN64 Address Space

| **영역** | **기본 주소/범위** | **크기** | **Scope** | **접근 방법** |
| --- | --- | --- | --- | --- |
| Kernel image + global/static 변수 (.text/.data/.bss) | STARTUP_ADDR = 0x0000_0000_8000_0000부터 배치 | 링크 결과 크기(시뮬레이터 VM 예약 예: 0x40000) | 프로그램 이미지(디바이스 공통) | IFetch + load/store |
| User/global alloc 시작점 | USER_BASE_ADDR = 0x0000_0000_0001_0000 | GLOBAL_MEM_SIZE = 0x2_0000_0000 (8GB) 내 | 디바이스 global memory | vx_mem_alloc, load/store |
| IO window | [0x0000_0000_0000_0040, 0x0000_0000_0001_0000) | 0xFFC0 | MMIO 메모리 공간 | LSU load/store (MEM_REQ_FLAG_IO) |
| Console MMIO | [0x0000_0000_0000_0040, 0x0000_0000_0000_0080) | 64B | 디바이스 콘솔 | store byte |
| MPM MMIO dump | IO_MPM_ADDR = 0x0000_0000_0000_0080, core별 + 0x100 * core_id | 256B/core (exitcode = +0x8) | core별 성능카운터 dump 영역 | 커널 dump + 호스트 조회 |
| Stack | STACK_BASE_ADDR = 0x0000_0001_FFFF_0000, sp = base - (mhartid << 13) | 8KB/hart | hart별 | 일반 메모리 접근 |
| LMEM (local memory) | 기본 LMEM_BASE_ADDR = STACK_BASE_ADDR = 0x0000_0001_FFFF_0000 | 2^LMEM_LOG_SIZE = 16KB ([0x...F0000, 0x...F4000)) | core-local | LSU local flag 경로 |
| Page-table reserved (VM_ENABLE) | PAGE_TABLE_BASE_ADDR = 0x0000_0000_F000_0000 | runtime가 상위 구간 예약 | VM 시스템 영역 | 런타임/페이지테이블 |

## IO Region Detail

| name | start | size | note |
| --- | --- | --- | --- |
| IO_WINDOW | 64'h000000040 | 65472B | IO 전체 space |
| IO_COUT | 64'h000000040 | 64B | console |
| IO_MPM | 64'h000000080 | 256B/core | Machine Performance-monitoring, core마다 있음 |
| **IO_GEMM0** | 64'h000001080 | 1KB | GEMM |
| **IO_GEMM1** | 64'h000001480 | 1KB | DMA |
| USER | 64'h000010000 |  | malloc 같은거 여기로 들어감 |
| STARTUP_ADDR | 64'h080000000 |  | text, …, data, .. 등 여러 section 들어감 |
| Page-table reserved | 0x0000_0000_F000_0000 |  | Virtual memory? |
| STACK | 64'h1_FFFF_0000(밑으로 내려감) | 8KB | (thread 마다 독립적) |
| LOCAL | 64'h1FFFF0000 | 16KB | thread block 마다 독립적 |

## Control Space (XLEN 무관)

| **공간** | **주소** | **Scope** | **접근 방법** |
| --- | --- | --- | --- |
| CSR | 12-bit (0x000~0xFFF, 예: MPM 0xB00/0xB80) | core-local(코어마다 CSR 인스턴스) | csrr/csrw 명령 |
| DCR(base) | 0x001~0x005 | host가 설정, 각 core에 fanout/copy | Host MMIO를 통한 DCR write |
| Host AFU MMIO | offset 0x00, 0x10, 0x18, 0x20, 0x28, 0x30 | host-device 제어 평면 | PCIe/XRT register R/W |
| Scope 채널 | MMIO_SCP_ADDR(0x28) + scope cmd | 로직 분석기 제어 | host callback (vx_scope_*) |

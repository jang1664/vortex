# Runtime Interface

SimX 시뮬레이터를 호스트 프로그램에서 사용하는 방법을 설명한다.
두 가지 경로가 있다: standalone 실행(`main.cpp`)과 런타임 API(`vortex.cpp`).

## 1. Standalone 실행 (main.cpp)

> 소스: `sim/simx/main.cpp`

커맨드라인에서 직접 바이너리를 실행하는 방식이다.

### 커맨드라인 옵션

```
simx [옵션] <프로그램 파일>

  -t <N>    스레드 수/warp (기본: NUM_THREADS)
  -w <N>    warp 수/코어   (기본: NUM_WARPS)
  -c <N>    코어 수        (기본: NUM_CORES)
  -s        통계 출력
  -h        도움말
```

### 실행 순서

```
1. Arch 생성 (num_threads, num_warps, num_cores)
2. RAM 생성 (MEM_PAGE_SIZE 단위 페이지 할당)
3. Processor 생성 + RAM 연결
4. DCR 설정:
   - VX_DCR_BASE_STARTUP_ADDR0/1 = 프로그램 시작 주소
   - VX_DCR_BASE_MPM_CLASS = 0
5. 프로그램 로드 (.bin 또는 .hex)
6. processor.run() → 시뮬레이션 완료까지 블로킹
7. 종료 코드 읽기: RAM[IO_MPM_ADDR + 8]
```

### 프로그램 포맷

```
.bin: Raw 바이너리 → STARTUP_ADDR에 직접 로드
.hex: Intel HEX → 주소/데이터 쌍으로 로드
```

## 2. 런타임 API (vortex.cpp)

> 소스: `runtime/simx/vortex.cpp`

호스트 프로그램(C/C++)에서 Vortex 디바이스를 제어하는 API이다.
실제 FPGA 런타임(XRT, OPAE)과 동일한 인터페이스를 제공하므로,
같은 호스트 코드를 시뮬레이터와 FPGA에서 그대로 사용할 수 있다.

### vx_device 내부 구조

```cpp
class vx_device {
  Arch arch_;                          // 아키텍처 설정
  RAM ram_;                            // 메인 메모리
  Processor processor_;                // 시뮬레이터
  MemoryAllocator global_mem_;         // 메모리 할당기
  std::future<int> future_;            // 비동기 실행 핸들
  DCRS dcrs_;                          // DCR 로컬 캐시
  std::unordered_map<...> mpm_cache_;  // MPM 데이터 캐시
#ifdef VM_ENABLE
  // 가상 메모리 관련 (페이지 테이블, SATP)
#endif
};
```

### API 호출 흐름

전형적인 호스트 프로그램의 실행 흐름:

```
┌─────────────────────────────────────────────────────┐
│                  호스트 프로그램                       │
│                                                      │
│  1. vx_dev_open()     ← 디바이스 열기                │
│  2. vx_mem_alloc()    ← 디바이스 메모리 할당          │
│  3. vx_copy_to_dev()  ← 커널 + 데이터 업로드         │
│  4. vx_start()        ← 커널 실행 시작               │
│  5. vx_ready_wait()   ← 실행 완료 대기               │
│  6. vx_copy_from_dev()← 결과 다운로드                │
│  7. vx_mem_free()     ← 메모리 해제                  │
│  8. vx_dev_close()    ← 디바이스 닫기                │
└─────────────────────────────────────────────────────┘
```

### 주요 API 함수

#### init() — 디바이스 초기화

```
- vortex-smi 공유 메모리 초기화 (모니터링용)
- 디바이스 상태 설정
```

#### get_caps() — 디바이스 역량 조회

```
VX_CAPS_VERSION          → 구현 ID
VX_CAPS_NUM_THREADS      → warp당 스레드 수
VX_CAPS_NUM_WARPS        → 코어당 warp 수
VX_CAPS_NUM_CORES        → 총 코어 수
VX_CAPS_CACHE_LINE_SIZE  → 캐시 라인 크기
VX_CAPS_GLOBAL_MEM_SIZE  → 전체 메모리 크기
VX_CAPS_LOCAL_MEM_SIZE   → 로컬 메모리 크기
VX_CAPS_ISA_FLAGS        → ISA 확장 플래그
VX_CAPS_NUM_MEM_BANKS    → DRAM 뱅크 수
```

#### mem_alloc() — 디바이스 메모리 할당

```
입력: size, flags
출력: dev_addr (디바이스 주소)

동작:
  1. global_mem_.allocate(size) → 물리 주소 할당
  2. VM 활성화 시: phy_to_virt_map() → 가상 주소 매핑
  3. dev_addr 반환 (VM시 가상 주소, 아니면 물리 주소)
```

#### upload() / download() — 데이터 전송

```
upload(dev_addr, host_buf, size):
  1. VM 활성화 시: dev_addr를 물리 주소로 변환 (page_table_walk)
  2. RAM에 데이터 쓰기

download(host_buf, dev_addr, size):
  1. VM 활성화 시: dev_addr를 물리 주소로 변환
  2. RAM에서 데이터 읽기
```

#### start() — 커널 실행 시작

```cpp
int start(uint64_t krnl_addr, uint64_t args_addr) {
  // 1. DCR에 커널 시작 주소 설정
  processor_.dcr_write(VX_DCR_BASE_STARTUP_ADDR0, krnl_addr & 0xffffffff);
  processor_.dcr_write(VX_DCR_BASE_STARTUP_ADDR1, krnl_addr >> 32);

  // 2. DCR에 커널 인자 주소 설정
  processor_.dcr_write(VX_DCR_BASE_STARTUP_ARG0, args_addr & 0xffffffff);
  processor_.dcr_write(VX_DCR_BASE_STARTUP_ARG1, args_addr >> 32);

  // 3. 비동기로 시뮬레이션 시작
  future_ = std::async(std::launch::async, [&] {
    return processor_.run();
  });
}
```

#### ready_wait() — 실행 완료 대기

```cpp
int ready_wait(uint64_t timeout) {
  if (future_.valid()) {
    // 1초 간격으로 폴링, timeout 초과 시 실패
    for (;;) {
      auto status = future_.wait_for(std::chrono::seconds(1));
      if (status == std::future_status::ready) break;
      if (timeout expiring) return -1;
    }
  }
}
```

#### mpm_query() — 성능 모니터링 데이터 조회

```
입력: addr (MPM 레지스터 주소), core_id
출력: value (64비트 카운터 값)

동작:
  1. MPM 캐시에 해당 코어 데이터가 없으면 RAM에서 다운로드
  2. 캐시에서 값 반환
```

## 3. DCR (Device Configuration Registers)

> 소스: `sim/simx/dcrs.h`, `dcrs.cpp`

호스트에서 디바이스 동작을 설정하는 레지스터이다.

### 주요 DCR

| DCR | 용도 |
|-----|------|
| `VX_DCR_BASE_STARTUP_ADDR0` | 커널 시작 주소 (하위 32비트) |
| `VX_DCR_BASE_STARTUP_ADDR1` | 커널 시작 주소 (상위 32비트, 64비트용) |
| `VX_DCR_BASE_STARTUP_ARG0` | 커널 인자 포인터 (하위 32비트) |
| `VX_DCR_BASE_STARTUP_ARG1` | 커널 인자 포인터 (상위 32비트) |
| `VX_DCR_BASE_MPM_CLASS` | 성능 모니터링 클래스 |

### DCR 접근 구조

```cpp
class BaseDCRS {
  std::array<uint32_t, VX_DCR_BASE_STATE_COUNT> states_;

  uint32_t read(uint32_t addr) const;
  void write(uint32_t addr, uint32_t value);
};

class DCRS {
  BaseDCRS base_dcrs;
  void write(uint32_t addr, uint32_t value);
};
```

## 4. 가상 메모리 (VM_ENABLE)

VM이 활성화되면 디바이스 주소가 가상 주소가 되고,
페이지 테이블을 통해 물리 주소로 변환된다.

### 페이지 테이블 구조

```
SV32 (32비트): 2단계 페이지 테이블
SV39 (64비트): 3단계 페이지 테이블
```

### 주소 변환 흐름

```
가상 주소 (vAddr)
    │
    ▼
page_table_walk(vAddr)
    │
    ├─ Level 2 (SV39만): PTE 룩업
    ├─ Level 1: PTE 룩업
    └─ Level 0: PTE 룩업 → 물리 페이지 번호 (PPN)
    │
    ▼
물리 주소 = PPN << PAGE_OFFSET | vAddr[PAGE_OFFSET-1:0]
```

### VM 초기화 (init_VM)

```
1. 페이지 테이블 메모리 할당 (예약 영역)
2. 가상 주소 할당기 초기화
3. SATP (Supervisor Address Translation and Protection) 레지스터 설정
4. 프로세서에 SATP 전달
```

### 메모리 할당 시 VM 흐름

```
mem_alloc(size):
  1. global_mem_.allocate(size) → pAddr (물리 주소)
  2. vAddr 할당 (가상 주소 공간에서)
  3. phy_to_virt_map(vAddr, pAddr, size) → 페이지 테이블 업데이트
  4. vAddr 반환 (호스트에게)
```

## 5. 실행 흐름 전체 타이밍

```
호스트 프로그램                SimX 시뮬레이터
─────────────                ─────────────────
vx_dev_open()
  └→ vx_device 생성
     Processor 생성
     RAM 생성                  [Processor 초기화 완료]

vx_mem_alloc(kernel_size)
  └→ 메모리 할당               [물리/가상 주소 반환]

vx_copy_to_dev(kernel_addr, binary)
  └→ RAM에 커널 쓰기           [커널 코드 로드됨]

vx_mem_alloc(data_size)
vx_copy_to_dev(data_addr, input)
  └→ RAM에 데이터 쓰기         [입력 데이터 로드됨]

vx_start(kernel_addr, args_addr)
  └→ DCR 설정                  [시작 주소, 인자 설정]
  └→ async processor.run()     [시뮬레이션 시작 ──────┐]
                                                      │
vx_ready_wait(timeout)          [매 사이클 tick()     │]
  └→ future.wait()              [Core[0..N] 실행 중   │]
     ···                        [모든 코어 완료 ──────┘]
  └→ 반환

vx_copy_from_dev(output, result_addr)
  └→ RAM에서 결과 읽기         [결과 다운로드]

vx_mem_free(...)
vx_dev_close()
```

## 6. 런타임 API와 FPGA 런타임의 관계

SimX 런타임은 FPGA 런타임(XRT, OPAE)과 동일한 API를 구현한다:

```
runtime/
├── simx/vortex.cpp      ← SimX 구현 (이 문서)
├── rtlsim/vortex.cpp    ← Verilator RTL 시뮬레이션 구현
├── xrt/vortex.cpp       ← Xilinx XRT FPGA 구현
└── opae/vortex.cpp      ← Intel OPAE FPGA 구현
```

동일한 호스트 프로그램이 백엔드만 바꿔서 시뮬레이터/FPGA에서 실행된다.
이를 통해 개발 시 simx로 빠르게 검증한 뒤, 같은 코드를 FPGA에 배포할 수 있다.

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/main.cpp` | Standalone 실행 진입점 |
| `runtime/simx/vortex.cpp` | 런타임 API 구현 (vx_device) |
| `sim/simx/processor.h/cpp` | Processor, ProcessorImpl |
| `sim/simx/dcrs.h/cpp` | DCR (디바이스 설정 레지스터) |
| `sim/simx/types.h/cpp` | MemReq, MemRsp, AddrType |

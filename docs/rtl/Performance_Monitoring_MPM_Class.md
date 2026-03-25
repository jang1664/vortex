# Machine Performance-Monitoring (MPM) Class

## 개요

**MPM Class**는 Vortex GPGPU의 성능 카운터(Performance Counter)를 그룹화하는 메커니즘입니다. 동일한 CSR 주소 공간을 여러 성능 카운터 그룹이 공유하면서, DCR 설정으로 어떤 그룹의 데이터를 읽을지 결정하는 **멀티플렉싱 시스템**입니다.

### 핵심 개념
- **DCR (Device Configuration Register)**: 하드웨어 설정을 제어하는 레지스터
- **CSR (Control and Status Register)**: RISC-V 표준 레지스터
- **MPM Class**: 성능 카운터 그룹 선택자 (CORE, MEM, NONE)

---

## DCR 주소 및 클래스 정의

### DCR 레지스터

**주소**: `VX_DCR_BASE_MPM_CLASS (0x005)`

이 DCR에 값을 쓰면 성능 모니터링 클래스가 변경됩니다.

### 클래스 종류

| 클래스 이름 | 값 | 설명 |
|------------|-----|------|
| `VX_DCR_MPM_CLASS_NONE` | 0 | 성능 모니터링 비활성화 |
| `VX_DCR_MPM_CLASS_CORE` | 1 | 코어 파이프라인 성능 카운터 |
| `VX_DCR_MPM_CLASS_MEM` | 2 | 메모리 계층 성능 카운터 |

**정의 위치**:
- [hw/VX_types.h](hw/VX_types.h#L40-L42)
- [hw/rtl/VX_types.vh](hw/rtl/VX_types.vh#L35-L37)

---

## CSR 주소 공간

### 사용자 MPM CSR 범위

성능 카운터는 다음 CSR 주소 범위를 사용합니다:

- **Base**: `VX_CSR_MPM_BASE (0xB00 ~ 0xB1F)` - 32개
- **High**: `VX_CSR_MPM_BASE_H (0xB80 ~ 0xB9F)` - 32개 (64-bit 카운터의 상위 32비트)

### 64-bit 카운터 읽기

성능 카운터는 대부분 64-bit 값입니다. RISC-V는 32-bit 레지스터를 사용하므로:

1. **Lower 32-bit**: `VX_CSR_MPM_xxx (0xB00 + offset)`
2. **Upper 32-bit**: `VX_CSR_MPM_xxx_H (0xB80 + offset)`

예시:
```c
uint64_t read_perf_counter(int csr_addr) {
    uint32_t lower = read_csr(csr_addr);
    uint32_t upper = read_csr(csr_addr + 0x80);  // High part
    return ((uint64_t)upper << 32) | lower;
}
```

---

## MPM_CLASS_CORE - 코어 파이프라인 성능

### 설정 방법

```cpp
// DCR write로 CORE 클래스 활성화
processor.dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_CORE);
```

### 측정 가능한 성능 카운터

#### 1. 파이프라인 Stall 관련

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_SCHED_ID` | 0xB00 | Schedule stage idle 사이클 |
| `VX_CSR_MPM_SCHED_ST` | 0xB02 | Schedule stage stall 사이클 |
| `VX_CSR_MPM_IBUF_ST` | 0xB04 | Instruction buffer stall |
| `VX_CSR_MPM_SCRB_ST` | 0xB06 | Scoreboard stall (전체) |
| `VX_CSR_MPM_OPDS_ST` | 0xB08 | Operand dependency stall |

**설명**:
- **Schedule idle**: 실행 가능한 warp가 없는 사이클
- **Schedule stall**: Warp가 있지만 stall된 사이클
- **IBUF stall**: Instruction buffer가 가득 차서 fetch 불가
- **Scoreboard stall**: 레지스터 dependency로 인한 대기
- **Operand stall**: Operand 준비 안 됨

#### 2. Scoreboard - 실행 유닛별 사용

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_SCRB_ALU` | 0xB0A | ALU 유닛 사용 횟수 |
| `VX_CSR_MPM_SCRB_LSU` | 0xB0C | LSU 유닛 사용 횟수 |
| `VX_CSR_MPM_SCRB_SFU` | 0xB0E | SFU 유닛 사용 횟수 |
| `VX_CSR_MPM_SCRB_FPU` | 0xB10 | FPU 유닛 사용 횟수 (EXT_F 활성화 시) |
| `VX_CSR_MPM_SCRB_TCU` | 0xB12 | TCU 유닛 사용 횟수 (EXT_TCU 활성화 시) |

**설명**:
- Issue stage에서 각 실행 유닛으로 명령어가 dispatch된 횟수
- 유닛별 활용도 분석 가능

#### 3. SFU 세부 분류

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_SCRB_CSRS` | 0xB14 | CSR 명령어 실행 횟수 |
| `VX_CSR_MPM_SCRB_WCTL` | 0xB16 | Warp control 명령어 실행 횟수 |

**설명**:
- SFU(Special Function Unit) 내부 세부 기능별 사용 통계
- CSRS: CSR read/write, CSRRW, CSRRS 등
- WCTL: TMC, WSPAWN, SPLIT, JOIN, BARRIER

#### 4. 메모리 접근 통계

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_IFETCHES` | 0xB18 | Instruction fetch 요청 횟수 |
| `VX_CSR_MPM_LOADS` | 0xB1A | Load 명령어 실행 횟수 |
| `VX_CSR_MPM_STORES` | 0xB1C | Store 명령어 실행 횟수 |
| `VX_CSR_MPM_IFETCH_LT` | 0xB1E | Instruction fetch 누적 레이턴시 (사이클) |
| `VX_CSR_MPM_LOAD_LT` | 0xB20 | Load 누적 레이턴시 (사이클) |

**사용 예시**:
```c
uint64_t loads = read_perf_counter(VX_CSR_MPM_LOADS);
uint64_t load_latency = read_perf_counter(VX_CSR_MPM_LOAD_LT);
double avg_load_latency = (double)load_latency / loads;

printf("Average load latency: %.2f cycles\n", avg_load_latency);
```

### RTL 구현 위치

성능 카운터 집계:
- [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L211-L238) - CSR read 처리

시뮬레이터:
- [sim/simx/emulator.cpp](sim/simx/emulator.cpp#L481-L507) - SIMX 성능 카운터

---

## MPM_CLASS_MEM - 메모리 계층 성능

### 설정 방법

```cpp
// DCR write로 MEM 클래스 활성화
processor.dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_MEM);
```

### 측정 가능한 성능 카운터

#### 1. ICache (Instruction Cache) 성능

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_ICACHE_READS` | 0xB00 | ICache 읽기 요청 횟수 |
| `VX_CSR_MPM_ICACHE_MISS_R` | 0xB02 | ICache read miss 횟수 |
| `VX_CSR_MPM_ICACHE_MSHR_ST` | 0xB04 | ICache MSHR stall 사이클 |

**설명**:
- **Reads**: Fetch stage에서 ICache 접근 횟수
- **Miss_R**: Cache miss 발생 횟수
- **MSHR_ST**: MSHR(Miss Status Holding Register)이 가득 차서 stall
- **Miss rate**: `MISS_R / READS * 100%`

#### 2. DCache (Data Cache) 성능

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_DCACHE_READS` | 0xB06 | DCache 읽기 요청 횟수 |
| `VX_CSR_MPM_DCACHE_WRITES` | 0xB08 | DCache 쓰기 요청 횟수 |
| `VX_CSR_MPM_DCACHE_MISS_R` | 0xB0A | DCache read miss 횟수 |
| `VX_CSR_MPM_DCACHE_MISS_W` | 0xB0C | DCache write miss 횟수 |
| `VX_CSR_MPM_DCACHE_BANK_ST` | 0xB0E | DCache bank conflict stall |
| `VX_CSR_MPM_DCACHE_MSHR_ST` | 0xB10 | DCache MSHR stall 사이클 |

**설명**:
- **Bank_ST**: 같은 bank에 동시 접근으로 인한 stall
- **MSHR_ST**: Outstanding miss 개수 초과로 인한 stall

#### 3. L2 Cache 성능

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_L2CACHE_READS` | 0xB12 | L2 캐시 읽기 요청 횟수 |
| `VX_CSR_MPM_L2CACHE_WRITES` | 0xB14 | L2 캐시 쓰기 요청 횟수 |
| `VX_CSR_MPM_L2CACHE_MISS_R` | 0xB16 | L2 read miss 횟수 |
| `VX_CSR_MPM_L2CACHE_MISS_W` | 0xB18 | L2 write miss 횟수 |
| `VX_CSR_MPM_L2CACHE_BANK_ST` | 0xB1A | L2 bank conflict stall |
| `VX_CSR_MPM_L2CACHE_MSHR_ST` | 0xB1C | L2 MSHR stall 사이클 |

#### 4. L3 Cache 성능

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_L3CACHE_READS` | 0xB1E | L3 캐시 읽기 요청 횟수 |
| `VX_CSR_MPM_L3CACHE_WRITES` | 0xB20 | L3 캐시 쓰기 요청 횟수 |
| `VX_CSR_MPM_L3CACHE_MISS_R` | 0xB22 | L3 read miss 횟수 |
| `VX_CSR_MPM_L3CACHE_MISS_W` | 0xB24 | L3 write miss 횟수 |
| `VX_CSR_MPM_L3CACHE_BANK_ST` | 0xB26 | L3 bank conflict stall |
| `VX_CSR_MPM_L3CACHE_MSHR_ST` | 0xB28 | L3 MSHR stall 사이클 |

#### 5. Memory Controller (DRAM)

| CSR 레지스터 | 주소 | 설명 |
|--------------|------|------|
| `VX_CSR_MPM_MEM_READS` | 0xB2A | DRAM 읽기 요청 횟수 |
| `VX_CSR_MPM_MEM_WRITES` | 0xB2C | DRAM 쓰기 요청 횟수 |
| `VX_CSR_MPM_MEM_LT` | 0xB2E | DRAM 누적 레이턴시 |

### 성능 분석 예시

```c
// 캐시 계층별 miss rate 계산
void print_cache_stats() {
    // ICache
    uint64_t ic_reads = read_perf_counter(VX_CSR_MPM_ICACHE_READS);
    uint64_t ic_misses = read_perf_counter(VX_CSR_MPM_ICACHE_MISS_R);
    printf("ICache miss rate: %.2f%%\n", 
           (double)ic_misses / ic_reads * 100);
    
    // DCache
    uint64_t dc_reads = read_perf_counter(VX_CSR_MPM_DCACHE_READS);
    uint64_t dc_read_misses = read_perf_counter(VX_CSR_MPM_DCACHE_MISS_R);
    printf("DCache read miss rate: %.2f%%\n", 
           (double)dc_read_misses / dc_reads * 100);
    
    // L2 Cache
    uint64_t l2_reads = read_perf_counter(VX_CSR_MPM_L2CACHE_READS);
    uint64_t l2_misses = read_perf_counter(VX_CSR_MPM_L2CACHE_MISS_R);
    printf("L2 miss rate: %.2f%%\n", 
           (double)l2_misses / l2_reads * 100);
    
    // DRAM latency
    uint64_t mem_reads = read_perf_counter(VX_CSR_MPM_MEM_READS);
    uint64_t mem_latency = read_perf_counter(VX_CSR_MPM_MEM_LT);
    printf("Average DRAM latency: %.2f cycles\n", 
           (double)mem_latency / mem_reads);
}
```

### RTL 구현 위치

- [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L240-L270) - MEM 클래스 CSR read
- [sim/simx/emulator.cpp](sim/simx/emulator.cpp#L507-L534) - SIMX 메모리 성능 카운터

---

## 동작 원리

### 1. DCR 설정

소프트웨어(또는 시뮬레이터)가 DCR에 클래스 값을 씁니다:

```cpp
// VX_dcr_data.sv에서 처리
always @(posedge clk) begin
    if (dcr_bus_if.write_valid) begin
        case (dcr_bus_if.write_addr)
            `VX_DCR_BASE_MPM_CLASS: 
                dcrs.mpm_class <= dcr_bus_if.write_data[7:0];
        endcase
    end
end
```

### 2. CSR Read 멀티플렉싱

CSR read 시 `mpm_class` 값에 따라 다른 성능 카운터를 반환합니다:

```systemverilog
// VX_csr_data.sv
case (base_dcrs.mpm_class)
    `VX_DCR_MPM_CLASS_CORE: begin
        case (read_addr)
            `VX_CSR_MPM_SCHED_ID: 
                read_data_ro_w = pipeline_perf.sched.idles;
            `VX_CSR_MPM_LOADS: 
                read_data_ro_w = pipeline_perf.loads;
            // ...
        endcase
    end
    `VX_DCR_MPM_CLASS_MEM: begin
        case (read_addr)
            `VX_CSR_MPM_ICACHE_READS: 
                read_data_ro_w = sysmem_perf.icache.reads;
            `VX_CSR_MPM_DCACHE_MISS_R: 
                read_data_ro_w = sysmem_perf.dcache.read_misses;
            // ...
        endcase
    end
endcase
```

### 3. 성능 카운터 집계

각 하드웨어 모듈에서 이벤트 발생 시 카운터 증가:

```systemverilog
// 예: Schedule idle 카운팅
always @(posedge clk) begin
    if (no_active_warps) begin
        pipeline_perf.sched.idles <= pipeline_perf.sched.idles + 1;
    end
end

// 예: DCache miss 카운팅
always @(posedge clk) begin
    if (cache_miss && is_read) begin
        sysmem_perf.dcache.read_misses <= 
            sysmem_perf.dcache.read_misses + 1;
    end
end
```

---

## 사용 예시

### 소프트웨어에서 성능 분석

```c
#include <vx_intrinsics.h>

void benchmark_kernel() {
    // CORE 클래스로 설정
    vx_dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_CORE);
    
    // 카운터 초기화 (시작 값 읽기)
    uint64_t start_cycles = vx_csr_read(VX_CSR_MCYCLE);
    uint64_t start_loads = read_perf_64(VX_CSR_MPM_LOADS);
    
    // === 커널 실행 ===
    my_kernel();
    // =================
    
    // 종료 값 읽기
    uint64_t end_cycles = vx_csr_read(VX_CSR_MCYCLE);
    uint64_t end_loads = read_perf_64(VX_CSR_MPM_LOADS);
    
    // 통계 출력
    uint64_t elapsed = end_cycles - start_cycles;
    uint64_t num_loads = end_loads - start_loads;
    
    printf("Elapsed cycles: %llu\n", elapsed);
    printf("Number of loads: %llu\n", num_loads);
    printf("Loads per cycle: %.2f\n", (double)num_loads / elapsed);
    
    // MEM 클래스로 전환
    vx_dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_MEM);
    
    uint64_t icache_misses = read_perf_64(VX_CSR_MPM_ICACHE_MISS_R);
    uint64_t dcache_misses = read_perf_64(VX_CSR_MPM_DCACHE_MISS_R);
    
    printf("ICache misses: %llu\n", icache_misses);
    printf("DCache misses: %llu\n", dcache_misses);
}
```

### 시뮬레이터 초기화

```cpp
// sim/simx/main.cpp
int main() {
    Processor processor;
    
    // 성능 모니터링 비활성화 (기본값)
    processor.dcr_write(VX_DCR_BASE_MPM_CLASS, 0);
    
    // 또는 CORE 클래스 활성화
    processor.dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_CORE);
    
    processor.run();
    
    return 0;
}
```

---

## 주요 파일 위치

### 정의 파일

| 파일 | 내용 |
|------|------|
| [hw/VX_types.h](hw/VX_types.h#L32) | DCR 주소 및 클래스 정의 (C/C++) |
| [hw/rtl/VX_types.vh](hw/rtl/VX_types.vh#L27) | DCR 주소 및 클래스 정의 (Verilog) |
| [hw/rtl/VX_gpu_pkg.sv](hw/rtl/VX_gpu_pkg.sv#L488) | DCR 구조체 (`mpm_class` 필드) |

### 구현 파일

| 파일 | 내용 |
|------|------|
| [hw/rtl/core/VX_dcr_data.sv](hw/rtl/core/VX_dcr_data.sv#L42) | DCR write 처리 (`mpm_class` 설정) |
| [hw/rtl/core/VX_csr_data.sv](hw/rtl/core/VX_csr_data.sv#L211) | CSR read 처리 (클래스별 멀티플렉싱) |
| [sim/simx/emulator.cpp](sim/simx/emulator.cpp#L477) | SIMX 시뮬레이터 성능 카운터 |

---

## 설계 이점

### 1. 주소 공간 절약
- 동일한 CSR 주소 범위(0xB00-0xB1F)를 여러 용도로 재사용
- RISC-V CSR 주소 공간 제약 극복

### 2. 유연한 성능 분석
- 런타임에 모니터링 대상 변경 가능
- 코어 파이프라인 분석 ↔ 메모리 계층 분석 전환 가능

### 3. 오버헤드 최소화
- NONE 클래스로 설정 시 성능 카운팅 비활성화
- 프로덕션 환경에서 오버헤드 제거 가능

### 4. 확장성
- 새로운 클래스 추가 용이 (예: `VX_DCR_MPM_CLASS_NETWORK`)
- 클래스별 독립적인 카운터 세트 관리

---

## 성능 분석 워크플로우

```
1. DCR 설정
   vx_dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_CORE)
   ↓
2. 시작 카운터 읽기
   start_loads = vx_csr_read(VX_CSR_MPM_LOADS)
   ↓
3. 커널 실행
   my_kernel()
   ↓
4. 종료 카운터 읽기
   end_loads = vx_csr_read(VX_CSR_MPM_LOADS)
   ↓
5. 분석
   num_loads = end_loads - start_loads
   ↓
6. 클래스 전환 (필요 시)
   vx_dcr_write(VX_DCR_BASE_MPM_CLASS, VX_DCR_MPM_CLASS_MEM)
   ↓
7. 메모리 통계 읽기
   cache_misses = vx_csr_read(VX_CSR_MPM_DCACHE_MISS_R)
```

---

## 디버깅 팁

### 1. 카운터 오버플로우 확인

64-bit 카운터지만 long-running 시뮬레이션에서 오버플로우 가능:

```c
uint64_t read_perf_64(int csr_base) {
    uint32_t lower = vx_csr_read(csr_base);
    uint32_t upper = vx_csr_read(csr_base + 0x80);
    return ((uint64_t)upper << 32) | lower;
}

// 오버플로우 감지
uint64_t prev_val = 0;
uint64_t curr_val = read_perf_64(VX_CSR_MPM_LOADS);
if (curr_val < prev_val) {
    printf("WARNING: Counter overflow detected!\n");
}
```

### 2. 클래스 설정 확인

```c
// 현재 설정된 클래스 확인 (DCR read)
uint8_t current_class = vx_dcr_read(VX_DCR_BASE_MPM_CLASS);
printf("Current MPM class: %d\n", current_class);
```

### 3. 시뮬레이터 트레이스

```systemverilog
// VX_trace_pkg.sv에서 DCR write 트레이스
`VX_DCR_BASE_MPM_CLASS: `TRACE(level, ("MPM_CLASS"))
```

---

## 요약

| 항목 | 내용 |
|------|------|
| **목적** | CSR 주소 공간 절약 + 성능 카운터 그룹화 |
| **메커니즘** | DCR로 클래스 선택 → CSR read 시 멀티플렉싱 |
| **클래스** | NONE(0), CORE(1), MEM(2) |
| **주소 범위** | 0xB00-0xB1F (lower), 0xB80-0xB9F (upper) |
| **주요 용도** | 파이프라인 분석, 캐시 성능 분석, 병목 지점 식별 |

**핵심**: 동일한 CSR 주소로 다른 성능 메트릭을 선택적으로 읽을 수 있는 **멀티플렉싱 시스템**

---

*문서 작성일: 2025-12-22*  
*Vortex GPGPU Project - Machine Performance-Monitoring Class Guide*

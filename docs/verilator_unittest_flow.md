# Verilator Unit Test 실행 흐름 (Tool Execution Flow)

## 📌 개요

Verilator는 **Verilog/SystemVerilog RTL을 C++로 변환**하여 사이클 정확한(cycle-accurate) 시뮬레이션을 수행하는 툴입니다. Vortex의 unittest 폴더에서는 개별 RTL 모듈을 테스트하는 데 사용됩니다.

---

## 🔄 전체 실행 흐름 (End-to-End Flow)

```
┌─────────────────┐
│  1. RTL 작성    │  .sv 파일
│  (Verilog/SV)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  2. Verilator   │  verilator --build --cc ...
│     컴파일      │
└────────┬────────┘
         │
         ├─→ RTL 파싱 & 검증
         ├─→ C++ 코드 생성 (V<module>.cpp/h)
         └─→ Makefile 생성
         │
         ▼
┌─────────────────┐
│  3. C++ 컴파일  │  g++ -c V<module>*.cpp
│                 │
└────────┬────────┘
         │
         ├─→ Verilated 모델 컴파일
         ├─→ 테스트 코드 컴파일 (main.cpp)
         └─→ 라이브러리 링크
         │
         ▼
┌─────────────────┐
│  4. 실행파일    │  ./cache_top
│     실행        │
└────────┬────────┘
         │
         ├─→ reset() 호출
         ├─→ step() 반복 (클럭 toggle)
         └─→ eval() 시뮬레이션
         │
         ▼
┌─────────────────┐
│  5. 결과 확인   │
│                 │
├─────────────────┤
│ • stdout 출력   │
│ • VCD 파일 생성 │
│ • 성공/실패     │
└─────────────────┘
```

---

## 📂 디렉토리 구조

```
hw/unittest/
├── common.mk              # 공통 Makefile 템플릿
├── common/
│   └── vl_simulator.h     # Verilator wrapper 클래스
└── cache_top/             # 테스트 케이스 예시
    ├── Makefile           # 테스트별 설정
    └── main.cpp           # 테스트 시나리오
```

---

## 🔧 단계별 상세 설명

### **Step 1: Makefile 설정** (`cache_top/Makefile`)

```makefile
PROJECT := cache_top          # 테스트 프로젝트 이름
TOP := VX_cache_top          # 시뮬레이션할 RTL 최상위 모듈

# RTL 소스 위치
RTL_DIR := $(VORTEX_HOME)/hw/rtl
RTL_INCLUDE := -I$(RTL_DIR) -I$(RTL_DIR)/cache ...

# C++ 테스트 코드
SRCS := $(SRC_DIR)/main.cpp

# RTL 패키지 파일
RTL_PKGS := $(RTL_DIR)/VX_gpu_pkg.sv

include ../common.mk
```

**역할:**
- 테스트할 RTL 모듈 지정
- RTL include 경로 설정
- C++ 테스트 코드 경로 지정

---

### **Step 2: Verilator 실행** (`verilator --build`)

#### 2-1. Verilator 명령어 구성

`common.mk`에서 실제 실행되는 명령:

```bash
verilator --build \
  --exe \                          # 실행 파일 생성
  --language 1800-2009 \           # SystemVerilog 2009 표준
  --assert -Wall -Wpedantic \      # 경고 활성화
  --x-initial unique \             # X 초기값 unique
  --x-assign unique \              # X 할당 unique
  -DSIMULATION -DSV_DPI \          # 전처리 매크로
  -I<RTL_DIR> ... \                # Include 경로들
  VX_gpu_pkg.sv \                  # 패키지 파일
  --cc VX_cache_top \              # C++로 변환
  --top-module VX_cache_top \      # 최상위 모듈
  main.cpp \                       # 테스트 코드
  -CFLAGS '...' \                  # C++ 컴파일 옵션
  -o ../cache_top                  # 출력 실행파일
```

#### 2-2. Verilator의 내부 동작

```
┌──────────────────────────────┐
│  Verilator 내부 처리 단계     │
├──────────────────────────────┤
│ 1. RTL 파싱                   │
│    - .sv/.v 파일 읽기          │
│    - 문법 검증                 │
│    - 모듈 계층 구조 파악       │
├──────────────────────────────┤
│ 2. 최적화                     │
│    - 조합 논리 단순화          │
│    - Dead code 제거            │
│    - 상수 전파                 │
├──────────────────────────────┤
│ 3. C++ 코드 생성               │
│    - V<module>.h              │
│    - V<module>.cpp            │
│    - V<module>__Syms.cpp      │
│    - V<module>___024root.cpp  │
├──────────────────────────────┤
│ 4. Makefile 생성               │
│    - obj_dir/V<module>.mk     │
├──────────────────────────────┤
│ 5. C++ 컴파일 실행             │
│    - g++ -c V*.cpp            │
│    - g++ -o 실행파일           │
└──────────────────────────────┘
```

#### 2-3. 생성되는 주요 파일들

```
obj_dir/
├── VVX_cache_top.h           # 모듈 클래스 선언
├── VVX_cache_top.cpp         # 모듈 구현
├── VVX_cache_top___024root.cpp  # 시뮬레이션 로직
├── VVX_cache_top__Syms.h/cpp    # 심볼 테이블
├── VVX_cache_top.mk          # 빌드 Makefile
└── ...
```

**VVX_cache_top.h의 구조:**
```cpp
class VVX_cache_top {
public:
    // RTL의 포트들이 멤버 변수로 변환
    uint8_t clk;
    uint8_t reset;
    uint32_t req_valid;
    uint32_t req_addr;
    // ...
    
    // 시뮬레이션 함수
    void eval();           // 조합 논리 평가
    void final();          // 정리
    void trace(VerilatedVcdC*, int);  // 트레이스
};
```

---

### **Step 3: C++ 테스트 코드 작성** (`main.cpp`)

#### 3-1. vl_simulator 래퍼 클래스 사용

```cpp
#include "vl_simulator.h"
#include "VVX_fifo_queue.h"  // Verilator가 생성한 헤더

using Device = VVX_fifo_queue;

int main(int argc, char **argv) {
    // 1. Verilator 초기화
    Verilated::commandArgs(argc, argv);
    
    // 2. 시뮬레이터 생성 (자동으로 VCD 트레이스 설정)
    vl_simulator<Device> sim;
    
    // 3. 리셋
    uint64_t timestamp = sim.reset(0);
    
    // 4. 시뮬레이션 루프
    while (timestamp < MAX_TICKS) {
        // 입력 신호 설정
        sim->push = 1;
        sim->data_in = 0xa;
        
        // 클럭 토글 (2 ticks = 1 cycle)
        timestamp = sim.step(timestamp, 2);
        
        // 출력 검증
        CHECK(sim->data_out == 0xa);
    }
    
    return 0;
}
```

#### 3-2. vl_simulator 클래스 동작

**vl_simulator.h 핵심 코드:**

```cpp
template <typename T>
class vl_simulator {
private:
    T top_;                    // Verilated 모듈 인스턴스
    VerilatedVcdC tfp_;       // VCD 트레이스 파일
    
public:
    vl_simulator() {
        top_.clk = 0;
        top_.reset = 0;
        
        // VCD 트레이스 초기화
        Verilated::traceEverOn(true);
        top_.trace(&tfp_, 99);  // 깊이 99까지 트레이스
        tfp_.open("trace.vcd");
    }
    
    // 리셋 시퀀스
    uint64_t reset(uint64_t ticks) {
        top_.reset = 1;
        ticks = this->step(ticks, 2);  // 2 ticks
        top_.reset = 0;
        return ticks;
    }
    
    // 시뮬레이션 스텝
    uint64_t step(uint64_t ticks, uint32_t count = 1) {
        while (count--) {
            top_.eval();           // 조합 논리 평가
            tfp_.dump(ticks);      // 파형 덤프
            top_.clk = !top_.clk;  // 클럭 토글
            ++ticks;
        }
        return ticks;
    }
    
    // 모듈 접근 (sim->signal_name)
    T* operator->() { return &top_; }
};
```

---

### **Step 4: 실행 파일 실행**

```bash
cd hw/unittest/cache_top
make                  # 빌드
./cache_top          # 실행
```

#### 4-1. 실행 시 내부 흐름

```
Program Start
    │
    ├─→ Verilated::commandArgs()  # 명령행 인자 파싱
    │
    ├─→ vl_simulator 생성
    │   ├─→ top_ 생성 (VVX_cache_top 인스턴스)
    │   ├─→ VCD 파일 열기 (trace.vcd)
    │   └─→ clk=0, reset=0 초기화
    │
    ├─→ reset() 호출
    │   ├─→ reset=1
    │   ├─→ eval() → VCD dump → clk toggle (2회)
    │   └─→ reset=0
    │
    ├─→ 시뮬레이션 루프
    │   │
    │   ├─→ [Tick 0] 입력 설정
    │   │   ├─→ sim->push = 1
    │   │   └─→ sim->data_in = 0xa
    │   │
    │   ├─→ step(2) 호출
    │   │   ├─→ [Tick 0] eval() → dump() → clk=1
    │   │   └─→ [Tick 1] eval() → dump() → clk=0
    │   │
    │   ├─→ [Tick 2] 출력 검증
    │   │   └─→ CHECK(sim->data_out == 0xa)
    │   │
    │   └─→ 반복...
    │
    ├─→ VCD 파일 닫기
    │
    └─→ Program Exit
```

#### 4-2. eval() 함수의 동작

Verilator가 생성한 `eval()` 함수:

```cpp
void VVX_cache_top::eval() {
    // 1. 입력 샘플링
    // (이미 main.cpp에서 설정됨)
    
    // 2. 조합 논리 평가
    //    - RTL의 assign 문들
    //    - always_comb 블록들
    __eval_comb();
    
    // 3. 순차 논리 (클럭 엣지에서만)
    if (clk의 posedge) {
        __eval_sequential();
        //    - always_ff 블록들
        //    - 레지스터 업데이트
    }
    
    // 4. 최종 조합 논리 재평가
    //    (레지스터 변경의 영향)
    __eval_settle();
}
```

---

### **Step 5: VCD 파일 생성 및 분석**

#### 5-1. VCD 파일 구조

```vcd
$date
    Mon Jan  6 12:00:00 2026
$end
$version
    Verilated 5.028
$end
$timescale 1ns $end

$scope module top $end
 $var wire 1 ! clk $end
 $var wire 1 " reset $end
 $var wire 1 # push $end
 $var wire 8 $ data_in $end
 $var wire 8 % data_out $end
$upscope $end

#0
0!
1"
0#
b00000000 $

#1
1!

#2
0!
0"
1#
b00001010 $
```

#### 5-2. 파형 뷰어로 확인

```bash
gtkwave trace.vcd
```

---

## 🎯 디버깅 옵션

### DEBUG 모드 빌드

```bash
DEBUG=1 make
```

**활성화되는 기능:**
- `--trace`: 파형 덤프
- `--trace-structs`: 구조체 내부까지 트레이스
- `-g -O0`: 디버그 심볼, 최적화 끔
- `-DVCD_OUTPUT`: VCD 파일 생성

### 트레이스 시간 범위 설정

```cpp
#define TRACE_START_TIME 100ull  // 100 tick부터
#define TRACE_STOP_TIME  500ull  // 500 tick까지
```

---

## 💡 주요 Verilator 플래그 설명

| 플래그 | 설명 |
|--------|------|
| `--exe` | 실행 파일 생성 (라이브러리 아님) |
| `--cc` | C++로 변환 |
| `--top-module` | 최상위 모듈 지정 |
| `--trace` | VCD 트레이스 활성화 |
| `--trace-structs` | 구조체 내부 신호 트레이스 |
| `-Wall -Wpedantic` | 모든 경고 활성화 |
| `--x-initial unique` | X 초기값을 unique하게 (디버깅 용이) |
| `--x-assign unique` | X 할당을 unique하게 |
| `-j N` | 병렬 컴파일 (N 스레드) |
| `-DSIMULATION` | SIMULATION 매크로 정의 |
| `-CFLAGS '...'` | C++ 컴파일러 플래그 |

---

## 🔍 실제 사용 예시

### 예시 1: FIFO Queue 테스트

```cpp
// 1. Push 연산
sim->push = 1;
sim->data_in = 0xAB;
timestamp = sim.step(timestamp, 2);  // 1 cycle

// 2. 출력 확인
CHECK(sim->empty == 0);
CHECK(sim->full == 0);

// 3. Pop 연산
sim->pop = 1;
timestamp = sim.step(timestamp, 2);

// 4. 데이터 확인
CHECK(sim->data_out == 0xAB);
```

### 예시 2: Cache 요청/응답

```cpp
// Request phase
sim->req_valid = 1;
sim->req_addr = 0x1000;
sim->req_rw = 1;  // write
sim->req_data = 0xDEADBEEF;

while (!sim->req_ready) {
    timestamp = sim.step(timestamp, 2);
}

// Response phase
while (!sim->rsp_valid) {
    timestamp = sim.step(timestamp, 2);
}

CHECK(sim->rsp_data == expected_value);
```

---

## 📊 성능 비교

| 시뮬레이터 | 속도 | 정확도 | 파형 | 디버깅 |
|-----------|------|--------|------|--------|
| **Verilator** | ⚡⚡⚡ 빠름 | Cycle-accurate | VCD | C++ debugger |
| ModelSim/QuestaSim | ⚡ 느림 | Cycle-accurate | WLF/VCD | HDL debugger |
| Vivado Simulator | ⚡⚡ 보통 | Cycle-accurate | WDB | HDL debugger |

**Verilator 장점:**
- 컴파일된 C++ 실행 → 매우 빠름
- 표준 C++ 디버거(GDB) 사용 가능
- CI/CD 자동화 용이
- 무료 오픈소스

---

## 🛠️ 트러블슈팅

### 1. "Cannot find module" 에러

```
%Error: Cannot find file containing module: 'VX_gemm_node'
```

**해결:**
- RTL_INCLUDE 경로에 해당 모듈이 있는 디렉토리 추가
```makefile
RTL_INCLUDE += -I$(RTL_DIR)/core/gemm
```

### 2. VCD 파일이 생성되지 않음

**해결:**
```bash
DEBUG=1 make  # VCD_OUTPUT 매크로 정의됨
```

### 3. 시뮬레이션이 느림

**해결:**
- DEBUG 모드 끄기: `make` (DEBUG 없이)
- 트레이스 범위 제한: `TRACE_START_TIME` 설정
- 최적화 레벨 높이기: `-O3`

### 4. X값이 출력됨

```
data_out = xxxx
```

**원인:**
- 초기화되지 않은 레지스터
- Reset 시퀀스 누락

**해결:**
```cpp
timestamp = sim.reset(0);  // 반드시 호출
```

---

## 결론

**Verilator Unit Test 흐름 요약:**

1. **RTL 작성** → `.sv` 파일
2. **Verilator 컴파일** → `V<module>.cpp/h` 생성
3. **C++ 컴파일** → 실행 파일 생성
4. **테스트 실행** → `eval()` + `step()` 반복
5. **결과 확인** → VCD 파형 + stdout

핵심은 **RTL을 C++ 클래스로 변환**하여, C++ 코드에서 **직접 신호를 읽고 쓰면서** 시뮬레이션을 제어할 수 있다는 것입니다!

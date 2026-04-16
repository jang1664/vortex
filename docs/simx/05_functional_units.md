# Functional Units

기능 유닛(FU)은 파이프라인의 execute 단계에서 명령어를 처리하는 실행 엔진이다.
각 FU는 명령어를 수신하고, 연산 타입에 따른 지연(latency)만큼 대기한 뒤 결과를 출력한다.

## 1. FuncUnit 베이스 클래스

> 소스: `sim/simx/func_unit.h`

모든 FU는 `FuncUnit`을 상속한다.

```cpp
class FuncUnit : public SimObject<FuncUnit> {
  std::vector<SimPort<instr_trace_t*>> Inputs;    // ISSUE_WIDTH개 입력 포트
  std::vector<SimPort<instr_trace_t*>> Outputs;   // ISSUE_WIDTH개 출력 포트
  virtual void tick() = 0;
};
```

### 공통 동작 패턴

```cpp
void SomeUnit::tick() {
  for (int iw = 0; iw < ISSUE_WIDTH; ++iw) {
    if (Inputs[iw].empty()) continue;
    auto trace = Inputs[iw].front();
    // ... 연산 타입 확인, 레이턴시 결정 ...
    Outputs[iw].push(trace, latency);   // latency 사이클 후 commit에 도착
    Inputs[iw].pop();
  }
}
```

## 2. ALU Unit

> 소스: `sim/simx/func_unit.cpp` — `AluUnit`

정수 연산, 분기, 곱셈/나눗셈을 처리한다.

### 연산별 레이턴시

| 연산 그룹 | 명령어 | 레이턴시 |
|-----------|--------|----------|
| 기본 산술 | ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU | 2 cycles |
| 상위 즉치 | LUI, AUIPC | 2 cycles |
| CZERO | CZERO.EQZ, CZERO.NEZ | 2 cycles |
| 분기/점프 | BEQ, BNE, BLT, BGE, JAL, JALR | 2 cycles |
| 시스템 | ECALL, EBREAK | 2 cycles |
| 곱셈 | MUL, MULH, MULHU, MULHSU | 2 cycles |
| 나눗셈 | DIV, DIVU, REM, REMU | XLEN+2 cycles (34 or 66) |
| Warp 연산 | VOTE.ALL/ANY/UNI/BAL | 2 cycles |
| Warp 셔플 | SHFL.UP/DOWN/BFLY/IDX | 2 cycles |

### Warp 연산 (Vote / Shuffle)

SIMT 프로그래밍에서 warp 내 스레드 간 통신을 위한 특수 연산:

- **VOTE**: 모든 스레드의 조건을 집계
  - `VOTE.ALL`: 모든 스레드가 참이면 참
  - `VOTE.ANY`: 하나라도 참이면 참
  - `VOTE.UNI`: 모든 스레드의 값이 같으면 참
  - `VOTE.BAL`: ballot — 각 스레드의 조건을 비트맵으로 반환

- **SHFL**: 스레드 간 데이터 교환
  - `SHFL.IDX`: 임의 스레드의 값 읽기
  - `SHFL.UP/DOWN`: 인접 스레드와 교환
  - `SHFL.BFLY`: 버터플라이 패턴 교환

### 분기 처리

ALU는 분기 명령어도 처리한다. Emulator에서 이미 분기 결과가 결정되었으므로,
ALU는 단지 2사이클 레이턴시만 추가한다.

`trace->fetch_stall`이 설정된 경우 (분기에 의한 PC 변경),
ALU 완료 시 `emulator_.resume(wid)` 호출하여 warp를 재개한다.

## 3. FPU Unit

> 소스: `sim/simx/func_unit.cpp` — `FpuUnit`

부동소수점 연산을 처리한다.

### 연산별 레이턴시

| 연산 그룹 | 명령어 | 레이턴시 |
|-----------|--------|----------|
| 비교/이동 | FCMP, FSGNJ, FCLASS, FMINMAX, FMVXW, FMVWX | 2+2 cycles |
| 사칙연산 | FADD, FSUB, FMUL | LATENCY_FMA+2 cycles (~7) |
| FMA | FMADD, FMSUB, FNMADD, FNMSUB | LATENCY_FMA+2 cycles (~7) |
| 나눗셈 | FDIV | LATENCY_FDIV+2 cycles (~14) |
| 제곱근 | FSQRT | LATENCY_FSQRT+2 cycles (~15) |
| 변환 | F2I, I2F, F2F | LATENCY_FCVT+2 cycles (~4) |

### 레이턴시 상수 (일반적인 값)

```
LATENCY_FMA   ≈ 5   (Fused Multiply-Add)
LATENCY_FDIV  ≈ 12  (부동소수점 나눗셈)
LATENCY_FSQRT ≈ 13  (부동소수점 제곱근)
LATENCY_FCVT  ≈ 2   (형변환)
```

## 4. LSU Unit (Load/Store Unit)

> 소스: `sim/simx/func_unit.cpp` — `LsuUnit`

메모리 로드/스토어를 처리하는 가장 복잡한 FU이다.

### 지원 연산

| 연산 그룹 | 명령어 |
|-----------|--------|
| Load | LB, LH, LW, LD, LBU, LHU, LWU |
| Load (FP) | FLW, FLD |
| Store | SB, SH, SW, SD |
| Store (FP) | FSW, FSD |
| Atomic (AMO) | LR, SC, AMOADD, AMOSWAP, AMOAND, AMOOR, AMOXOR, AMOMIN, AMOMAX |
| Fence | FENCE |

### 상태 관리 (LSU 블록별)

```cpp
// 각 LSU 블록은 독립적인 상태를 가짐
struct {
  HashTable<instr_trace_t*> pending_rd_reqs;  // 진행 중인 읽기 요청
  instr_trace_t* fence_trace;                  // 대기 중인 fence
  bool fence_lock;                             // fence 잠금 상태
};
```

### 동작 흐름

**Store (쓰기):**
```
1. 메모리 요청 생성 (주소, 데이터)
2. D-cache에 쓰기 요청 전송
3. 즉시 output에 push (응답 대기 없음)
```

**Load (읽기):**
```
1. 메모리 요청 생성
2. D-cache에 읽기 요청 전송
3. pending_rd_reqs에 등록하고 대기
4. D-cache 응답 수신 시 카운터 감소
5. 모든 응답 수신 완료 (eop) → output에 push
```

**Fence:**
```
1. LSU 블록 잠금 (새 요청 차단)
2. 모든 pending_rd_reqs 완료 대기
3. 완료 후 output에 push, 잠금 해제
```

### 성능 카운터

- `loads`, `stores` — 로드/스토어 횟수
- `load_latency` — 로드 응답 대기 누적

## 5. SFU Unit (Special Function Unit)

> 소스: `sim/simx/func_unit.cpp` — `SfuUnit`

특수 기능 연산을 처리한다: warp 제어 및 CSR 접근.

### 연산별 동작

| 연산 | 동작 | 레이턴시 |
|------|------|----------|
| WSPAWN | warp 스폰 요청. eop에서 `core_->wspawn()` 호출 | 2+2 cycles |
| TMC | 스레드 마스크 변경 | 2+2 cycles |
| SPLIT | 스레드 분기 (IPDOM 스택 push) | 2+2 cycles |
| JOIN | 스레드 합류 (IPDOM 스택 pop) | 2+2 cycles |
| BAR | 배리어 동기화. eop에서 `core_->barrier()` 호출 | 2+2 cycles |
| PRED | 프레디케이션 | 2+2 cycles |
| CSRRW/S/C | CSR 읽기-수정-쓰기 | 2+2 cycles |

### 배리어 처리 상세

```
SFU가 BAR 명령어의 eop를 수신:
  → core_->barrier(bar_id, count, wid) 호출
  → Emulator가 warp를 stalled 상태로 전환
  → 모든 참가 warp가 도달하면 일괄 재개
```

### WSPAWN 처리 상세

```
SFU가 WSPAWN 명령어의 eop를 수신:
  → core_->wspawn(num_warps, nextPC) 호출
  → Emulator가 wspawn_ 구조체에 기록
  → 다음 step()에서 warp들이 실제 활성화
```

## 6. TCU Unit (Tensor Compute Unit)

> 소스: `sim/simx/func_unit.cpp` — `TcuUnit`, `sim/simx/tensor_unit.h/cpp`

텐서 연산(WMMA — Weighted Matrix Multiply-Accumulate)을 처리한다.
`EXT_TCU_ENABLE`이 정의된 경우에만 활성화된다.

### 동작

TCU는 자체 `tick()` 로직 없이 `TensorUnit`에 입출력을 위임한다:
```cpp
TcuUnit::TcuUnit(...) {
  // 입출력 포트를 TensorUnit에 직접 바인딩
  this->Inputs[iw].bind(&core->tensor_unit()->Inputs[iw]);
  core->tensor_unit()->Outputs[iw].bind(&this->Outputs[iw]);
}
```

### WMMA 연산

WMMA는 디코딩 시 여러 마이크로 연산으로 분해된다.
각 스텝은 K/M/N 차원의 부분 FMA를 수행한다.

지원 포맷:
- fp16 → fp32
- bf16 → fp32
- int8 → int32
- int4 → int32

## 7. VPU Unit (Vector Processing Unit)

> 소스: `sim/simx/func_unit.cpp` — `VpuUnit`, `sim/simx/vec_unit.h/cpp`

벡터 확장(RVV) 연산을 처리한다.
`EXT_V_ENABLE`이 정의된 경우에만 활성화된다.

### 연산별 레이턴시

| 연산 그룹 | 레이턴시 |
|-----------|----------|
| VSET (설정) | 0+2 cycles (패스스루) |
| ARITH / ARITH_R | 1+2 cycles |
| IMUL (정수 곱셈) | 3+2 cycles |
| IDIV (정수 나눗셈) | XLEN+2 cycles |
| FNCP / FNCP_R | 2+2 cycles |
| FMA / FMA_R | LATENCY_FMA+2 cycles |
| FDIV | LATENCY_FDIV+2 cycles |
| FSQRT | LATENCY_FSQRT+2 cycles |
| FCVT | LATENCY_FCVT+2 cycles |

## 8. FU 타입 열거

```cpp
enum class FUType {
  ALU,    // 정수 연산, 분기
  LSU,    // 로드/스토어
  FPU,    // 부동소수점
  SFU,    // 특수 기능 (warp 제어, CSR)
  VPU,    // 벡터 (선택적)
  TCU,    // 텐서 (선택적)
  Count   // FU 타입 개수
};
```

## 9. Dispatcher와의 관계

각 FU 타입에는 전용 Dispatcher가 있다.
Dispatcher는 명령어의 스레드 수가 FU 레인 수를 초과할 경우
여러 패킷으로 분할한다.

```
ISSUE_WIDTH=1, NUM_THREADS=4, NUM_ALU_LANES=2 인 경우:

ALU Dispatcher:
  num_packets = 4 / 2 = 2

  원본 trace: tmask=[1,1,1,1]
    → 패킷 0: tmask=[1,1,0,0], pid=0, sop=true,  eop=false
    → 패킷 1: tmask=[0,0,1,1], pid=1, sop=false, eop=true
```

FU는 각 패킷을 독립적으로 처리하고,
commit 단계에서 `eop=true`인 마지막 패킷에서만 은퇴가 완료된다.

## 10. 레이턴시 요약 표

| FU | 연산 | 레이턴시 (cycles) |
|----|------|-------------------|
| ALU | 기본 산술/논리 | 2 |
| ALU | 곱셈 | 2 |
| ALU | 나눗셈 | XLEN+2 (34/66) |
| FPU | 비교/이동 | 4 |
| FPU | FMA | ~7 |
| FPU | FDIV | ~14 |
| FPU | FSQRT | ~15 |
| FPU | 형변환 | ~4 |
| LSU | Store | 즉시 (응답 대기 없음) |
| LSU | Load | 캐시 응답 시간에 의존 |
| LSU | Fence | 모든 pending 완료 대기 |
| SFU | Warp 제어/CSR | 4 |

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/func_unit.h` | FuncUnit 베이스 클래스 |
| `sim/simx/func_unit.cpp` | AluUnit, FpuUnit, LsuUnit, SfuUnit, TcuUnit, VpuUnit |
| `sim/simx/dispatcher.h/cpp` | Dispatcher (스레드 패킷 분할) |
| `sim/simx/tensor_unit.h/cpp` | TensorUnit (WMMA 연산) |
| `sim/simx/vec_unit.h/cpp` | VecUnit (벡터 연산) |

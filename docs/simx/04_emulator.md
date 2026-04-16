# Emulator (Functional Simulator)

Emulator는 SimX의 **기능적 시뮬레이션** 부분이다.
RISC-V ISA 명령어를 즉시 실행하고, 결과를 아키텍처 상태에 반영한다.
타이밍 파이프라인에 넘길 `instr_trace_t`를 생성하는 것이 주된 출력이다.

## 역할 분담

```
Emulator (이 문서)              Pipeline Timing Model (03_pipeline.md)
──────────────────              ─────────────────────────────────────
명령어를 즉시 실행               trace가 파이프라인을 통과
레지스터 읽기/쓰기               캐시 지연, 해저드 모델링
분기 해결                        스코어보드, 스톨
instr_trace_t 생성               사이클 수 결정
```

## 1. Emulator 클래스 구조

> 소스: `sim/simx/emulator.h`, `emulator.cpp`

### 주요 멤버 변수

```cpp
class Emulator {
  // Warp 상태
  std::vector<warp_t> warps_;           // warp별 상태 (레지스터, PC, 마스크)
  WarpMask active_warps_;               // 활성 warp 비트맵
  WarpMask stalled_warps_;              // 배리어 대기 warp 비트맵

  // Warp 스폰
  wspawn_t wspawn_;                     // 대기중인 warp 스폰 정보

  // 배리어
  std::vector<WarpMask> barriers_;      // 배리어별 참가 warp 비트맵

  // 기타
  MMU mmu_;                             // 메모리 관리 (주소 변환)
  uint32_t ipdom_size_;                 // IPDOM 스택 크기 (= num_threads - 1)
};
```

### warp_t — Warp 상태

```cpp
struct warp_t {
  // 레지스터 파일 (레지스터 32개 x 스레드 수)
  std::vector<std::vector<Word>>     ireg_file;    // 정수 레지스터 [32][num_threads]
  std::vector<std::vector<uint64_t>> freg_file;    // 부동소수점 레지스터 [32][num_threads]

  // 명령어 버퍼
  std::deque<Instr::Ptr> ibuffer;      // 디코딩된 마이크로 연산들

  // 분기 분기/합류 스택
  IPDomStack ipdom_stack;               // IPDOM (Immediate Post-Dominator) 스택

  // 실행 상태
  ThreadMask tmask;                     // 활성 스레드 마스크
  Word PC;                              // 프로그램 카운터
  uint32_t fcsr;                        // 부동소수점 CSR
  uint64_t uuid;                        // 명령어 고유 ID 카운터
};
```

**레지스터 파일 구조:**
- 각 warp는 독립적인 레지스터 파일을 가진다
- 레지스터 하나에 `num_threads`개의 값이 있다 (SIMT: 스레드마다 다른 값)
- `ireg_file[0][t]`는 항상 0 (RISC-V의 x0 레지스터)
- 부동소수점 레지스터는 64비트로 저장 (32비트 값은 NaN-boxing)

## 2. step() — 메인 실행 흐름

> 소스: `emulator.cpp` — `Emulator::step()`

`Core::schedule()`에서 매 사이클 호출된다. 하나의 warp를 선택하여
명령어를 실행하고 trace를 반환한다.

### 실행 흐름

```
step()
  │
  ├─ 1. Warp Spawn 처리 (대기중인 spawn이 있으면)
  │     └─ active_warps 중 1개만 남았으면 나머지 warp 활성화
  │
  ├─ 2. Warp 선택 (round-robin)
  │     └─ active이면서 !stalled인 첫 번째 warp
  │     └─ 없으면 null 반환 (sched_idle)
  │
  ├─ 3. 명령어 버퍼 확인
  │     ├─ ibuffer 비어있으면:
  │     │   └─ fetch() → decode() → ibuffer에 마이크로 연산 push
  │     └─ ibuffer에 명령어 있으면:
  │         └─ pop하여 실행
  │
  └─ 4. execute() — 기능적 실행
        └─ instr_trace_t* 반환
```

### Warp 선택 알고리즘

```cpp
// Round-robin: 이전에 선택한 warp 다음부터 순회
for (uint32_t i = 0; i < num_warps; ++i) {
  uint32_t wid = (last_schedule_wid_ + 1 + i) % num_warps;
  if (active_warps_.test(wid) && !stalled_warps_.test(wid)) {
    // 이 warp 선택
    break;
  }
}
```

## 3. fetch() — 명령어 패치

> 소스: `emulator.cpp` — `Emulator::fetch()`

```cpp
void Emulator::fetch(warp_t& warp) {
  uint32_t instr_code;
  mmu_.read(&instr_code, warp.PC, sizeof(uint32_t));  // I-cache에서 읽기
}
```

메모리에서 32비트 명령어 코드를 읽어온다. 실제로는 `icache_read`를 통해
시뮬레이션된 메모리에서 읽는다.

## 4. decode() — 명령어 디코딩

> 소스: `sim/simx/decode.cpp`

32비트 명령어 코드를 `Instr` 객체로 디코딩한다.
일부 복합 명령어(예: WMMA)는 여러 마이크로 연산으로 분해되어
ibuffer에 복수 개가 push된다.

```
RISC-V 명령어 코드 (32비트)
       │
       ▼
  ┌──────────┐
  │ decode() │
  └──────────┘
       │
       ▼
  Instr 객체 (opcode, funct3/7, rd, rs1, rs2, imm 등)
       │
       ├─ 단순 명령어: ibuffer에 1개 push
       └─ WMMA 등 복합 명령어: ibuffer에 N개 push (마이크로 연산)
```

## 5. execute() — 기능적 명령어 실행

> 소스: `sim/simx/execute.cpp`

디코딩된 명령어를 실제로 실행한다. **모든 활성 스레드에 대해** 연산을 수행한다.

### 실행 흐름

```
execute()
  │
  ├─ 1. fetch_registers() — 소스 레지스터 값 읽기 (모든 스레드)
  │
  ├─ 2. instr_trace_t 생성 — FU 타입, 연산 타입, 레지스터 정보 기록
  │
  ├─ 3. 명령어 타입별 실행:
  │     ├─ R-type (ALU): add, sub, and, or, xor, sll, srl, ...
  │     ├─ I-type (ALU): addi, slti, xori, ...
  │     ├─ Load/Store (LSU): lw, sw, lb, sh, ...
  │     ├─ Branch: beq, bne, blt, bge, jal, jalr
  │     ├─ FP: fadd, fsub, fmul, fmadd, ...
  │     ├─ CSR: csrrw, csrrs, csrrc
  │     ├─ System: ecall, ebreak
  │     ├─ Warp Control: wspawn, tmc, split, join, bar
  │     ├─ Vector (EXT_V): vadd, vmul, ...
  │     └─ Tensor (EXT_TCU): wmma
  │
  └─ 4. 결과 쓰기 — 목적 레지스터에 결과 저장 (모든 활성 스레드)
```

### 레지스터 읽기

```cpp
void Emulator::fetch_registers(warp_t& warp, instr_trace_t* trace) {
  for (int t = 0; t < num_threads; ++t) {
    if (!warp.tmask.test(t)) continue;  // 비활성 스레드 건너뜀

    // 소스 레지스터 값 읽기
    for (auto& src : trace->src_regs) {
      if (src.type == RegType::Integer) {
        rsdata[t] = warp.ireg_file[src.idx][t];
      } else if (src.type == RegType::Float) {
        rsdata[t] = warp.freg_file[src.idx][t];
      }
    }
  }
}
```

### SIMT 실행 모델

모든 명령어는 warp 내의 **활성 스레드 전체**에 대해 실행된다:

```
warp.tmask = [1, 1, 0, 1]  (스레드 0,1,3 활성, 스레드 2 비활성)

ADD x3, x1, x2 실행:
  스레드 0: x3 = x1 + x2  (각 스레드의 레지스터 값이 다름)
  스레드 1: x3 = x1 + x2
  스레드 2: (건너뜀)
  스레드 3: x3 = x1 + x2
```

## 6. 분기 분기/합류 (IPDOM)

SIMT에서 조건부 분기 시 스레드가 분기(diverge)하면,
IPDOM(Immediate Post-Dominator) 스택으로 관리한다.

### SPLIT (분기)

```
tmask = [1,1,1,1], branch condition = [T,T,F,F]

SPLIT 실행:
  then_mask = [1,1,0,0]  ← 조건 참인 스레드
  else_mask = [0,0,1,1]  ← 조건 거짓인 스레드

  ipdom_stack.push({else_mask, else_PC})  ← 나중에 실행할 경로 저장
  tmask = then_mask  ← then 경로부터 실행
```

### JOIN (합류)

```
JOIN 실행:
  {saved_mask, saved_PC} = ipdom_stack.pop()
  tmask = saved_mask   ← else 경로의 스레드 활성화
  PC = saved_PC         ← else 경로로 점프
```

모든 분기 경로가 실행된 후 스레드 마스크가 복원된다.

## 7. Warp Spawn (wspawn)

새로운 warp를 활성화하는 메커니즘이다.
커널 실행 시 사용된다.

```cpp
bool Emulator::wspawn(uint32_t num_warps, Word nextPC) {
  wspawn_.valid = true;
  wspawn_.num_warps = num_warps;
  wspawn_.nextPC = nextPC;
  // 실제 활성화는 다음 step()에서 수행
}
```

### 지연 활성화

```
step()에서:
  if (wspawn_.valid && active_warps_.count() == 1) {
    // 현재 warp 1개만 활성 상태일 때
    for (wid = 1; wid < wspawn_.num_warps; ++wid) {
      warps_[wid].PC = wspawn_.nextPC;
      warps_[wid].tmask = thread_0_only;  // 스레드 0만 활성
      active_warps_.set(wid);
    }
    wspawn_.valid = false;
  }
```

warp 0이 초기화 코드를 완료한 후에야 나머지 warp들이 활성화된다.

## 8. 배리어 (Barrier)

warp 간 동기화 지점이다.

### 로컬 배리어 (코어 내)

```cpp
bool Emulator::barrier(uint32_t bar_id, uint32_t count, uint32_t wid) {
  auto& barrier = barriers_.at(bar_id);
  barrier.set(wid);                        // 현재 warp 등록
  stalled_warps_.set(wid);                 // warp 정지

  if (barrier.count() == count) {          // 모든 참가자 도달
    stalled_warps_ &= ~barrier;            // 모든 참가 warp 재개
    barrier.reset();                       // 배리어 리셋
    return true;
  }
  return false;
}
```

### 글로벌 배리어 (코어 간)

코어 내 모든 warp가 도달하면, `Cluster::barrier()`로 전파되어
클러스터 내 모든 코어의 동기화를 관리한다.

## 9. 지원 ISA

| 확장 | 설명 |
|------|------|
| RV32I / RV64I | 기본 정수 ISA |
| RV32M / RV64M | 곱셈/나눗셈 |
| RV32F / RV64F | 단정밀도 부동소수점 |
| RV32D / RV64D | 배정밀도 부동소수점 |
| Vortex 커스텀 | wspawn, tmc, split, join, bar, pred (warp 제어) |
| EXT_V | 벡터 확장 (선택적) |
| EXT_TCU | 텐서 확장 - WMMA (선택적) |

## 10. instr_trace_t — 명령어 추적 정보

> 소스: `sim/simx/instr_trace.h`

Emulator가 생성하고 파이프라인이 소비하는 핵심 데이터 구조이다.

```cpp
struct instr_trace_t {
  const uint64_t uuid;      // 고유 명령어 ID
  uint32_t cid;             // 코어 ID
  uint32_t wid;             // warp ID
  ThreadMask tmask;         // 활성 스레드 마스크
  Word PC;                  // 프로그램 카운터

  bool wb;                  // write-back 여부
  RegOpd dst_reg;           // 목적 레지스터 (타입 + 인덱스)
  RegOpd src_regs[3];       // 소스 레지스터들

  FUType fu_type;           // 기능 유닛 타입 (ALU, FPU, LSU, SFU, ...)
  OpType op_type;           // 연산 타입 (variant)

  int pid;                  // 패킷 ID (Dispatcher 분할용)
  bool sop, eop;            // Start/End of Packet
  uint64_t issue_time;      // 발행 사이클

  ITraceData::Ptr data;     // FU별 추가 데이터 (LSU 주소, SFU 인자 등)

  bool fetch_stall;         // fetch 스톨 여부
};
```

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/emulator.h/cpp` | Emulator 클래스, step(), warp 관리 |
| `sim/simx/decode.cpp` | 명령어 디코딩 |
| `sim/simx/execute.cpp` | 기능적 명령어 실행 |
| `sim/simx/instr.h` | Instr (디코딩된 명령어 구조체) |
| `sim/simx/instr_trace.h` | instr_trace_t (파이프라인 추적 정보) |

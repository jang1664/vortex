# Pipeline (6-Stage)

Core의 6단계 파이프라인 상세 동작을 설명한다.
각 스테이지는 `Core::tick()` 에서 역순으로 호출된다.

## 파이프라인 전체 구조

```
┌──────────┐  ┌───────┐  ┌────────┐  ┌───────┐  ┌─────────┐  ┌────────┐
│ Schedule │→│ Fetch │→│ Decode │→│ Issue │→│ Execute │→│ Commit │
│          │  │       │  │        │  │       │  │         │  │        │
│Emulator  │  │I-cache│  │IBuffer │  │Score- │  │FuncUnit │  │Write-  │
│.step()   │  │req/rsp│  │저장    │  │board  │  │실행     │  │back    │
└──────────┘  └───────┘  └────────┘  └───────┘  └─────────┘  └────────┘
      ↓            ↓           ↓          ↓           ↓            ↓
 fetch_latch  decode_latch  ibuffer  operands_  dispatchers  commit_arbs
                                       ↓         ↓
                                    Operands  Dispatcher → func_units
```

### 각 스테이지 간 지연 (SimPort push delay)

```
Schedule → Fetch:    fetch_latch (큐, delay 없음)
Fetch    → Decode:   decode_latch (큐, delay 없음)
Fetch    → I-cache:  icache_req_port.push(req, 2)     ← 2 cycles
Decode   → IBuffer:  ibuffer.push() (직접 삽입)
Issue    → Operand:  operands_[iw]->Input.push(trace, 1)  ← 1 cycle
Execute  → FU:       func_units_[fu]->Inputs[iw].push(trace, 2) ← 2 cycles
```

## Stage 1: schedule()

> 소스: `core.cpp` — `Core::schedule()`

**역할**: Emulator에서 다음 명령어를 가져와 파이프라인에 투입한다.

```
Emulator.step()  →  fetch_latch_  (+ pending_instrs_ 추적)
```

### 동작

1. `emulator_.step()` 호출 → warp 선택 → 기능적 실행 → `instr_trace_t*` 반환
2. 반환된 trace를 `fetch_latch_`에 push
3. `pending_instrs_`에 추가 (in-flight 추적)
4. `emulator_.suspend(trace->wid)` — 해당 warp 일시 정지 (중복 fetch 방지)

### 스톨 조건

- `emulator_.step()` 이 null 반환 (모든 warp가 정지/대기 상태)
  → `perf_stats_.sched_idle++`

### 핵심 포인트

Emulator가 명령어를 **기능적으로 완전히 실행**한 뒤 trace를 반환한다.
레지스터 결과, 분기 결과 등은 이미 확정되어 있다.
이후 파이프라인은 **타이밍만** 시뮬레이션한다.

## Stage 2: fetch()

> 소스: `core.cpp` — `Core::fetch()`

**역할**: I-cache 요청/응답을 처리하여 명령어를 decode 단계로 전달한다.

```
I-cache 응답 → decode_latch_
fetch_latch_ → I-cache 요청 (delay=2)
```

### 동작

**응답 경로** (I-cache → decode):
1. `icache_rsp_port`에 응답이 있는지 확인
2. 응답의 tag로 `pending_icache_`에서 원래 trace 검색
3. trace를 `decode_latch_`에 push
4. `pending_icache_` 엔트리 해제, `pending_ifetches_--`

**요청 경로** (fetch_latch → I-cache):
1. `fetch_latch_`에서 trace를 꺼냄
2. `MemReq` 생성 (addr = trace->PC)
3. `icache_req_port.push(mem_req, 2)` — **2사이클 지연**으로 I-cache에 전달
4. `pending_icache_`에 tag↔trace 매핑 저장, `pending_ifetches_++`

### 성능 카운터

- `perf_stats_.ifetch_latency += pending_ifetches_` — 매 사이클 누적
- `perf_stats_.ifetches++` — I-cache 요청 횟수

## Stage 3: decode()

> 소스: `core.cpp` — `Core::decode()`

**역할**: decode_latch의 명령어를 warp별 IBuffer에 저장한다.

```
decode_latch_ → ibuffers_[wid]
```

### 동작

1. `decode_latch_`에서 trace를 꺼냄
2. `ibuffers_[trace->wid]`의 용량 확인 (최대 `IBUF_SIZE=4`)
3. IBuffer가 가득 차면 스톨 → `perf_stats_.ibuf_stalls++`
4. IBuffer에 push
5. `emulator_.resume(trace->wid)` — fetch_stall이 아니면 warp 재개

### 스톨 조건

- IBuffer가 가득 참 (용량: IBUF_SIZE = 4)
  → 이 사이클에서 decode를 건너뛰고, 다음 사이클에 재시도

## Stage 4: issue()

> 소스: `core.cpp` — `Core::issue()`

**역할**: IBuffer에서 명령어를 선택하고, 스코어보드를 확인한 뒤
오퍼랜드 수집 단계로 전달한다. 가장 복잡한 스테이지이다.

### 두 부분으로 구성

#### Part A — 오퍼랜드 → 디스패처 전달

```
operands_[iw].Output → dispatchers_[fu_type].Inputs[iw]
```

각 issue slot(iw)에 대해, 오퍼랜드 수집이 완료된 명령어를
해당 FU 타입의 디스패처로 전달한다.

#### Part B — IBuffer → 스코어보드 → 오퍼랜드

```
ibuffers_[wid] → scoreboard_ 확인 → operands_[iw].Input (delay=1)
```

각 issue slot(iw)에 대해:

1. **Warp 선택**: `PER_ISSUE_WARPS`개의 warp 중에서 round-robin 중재
   - `wid = w * ISSUE_WIDTH + iw` (w: warp 인덱스, iw: issue slot)
   - 빈 IBuffer는 건너뜀

2. **스코어보드 확인**: `scoreboard_.in_use(trace)`
   - 소스/목적 레지스터가 아직 사용 중이면 이 warp는 스킵
   - `perf_stats_.scrb_stalls++` 및 FU별 세부 카운터 증가

3. **발행(issue)**:
   - `scoreboard_.reserve(trace)` — 목적 레지스터를 "사용중"으로 표시
   - `operands_[iw]->Input.push(trace, 1)` — **1사이클 지연**

### Warp 스케줄링 구조

```
ISSUE_WIDTH = 1 (기본), NUM_WARPS = 4 → PER_ISSUE_WARPS = 4

Issue slot 0:  warp 0, warp 1, warp 2, warp 3  (round-robin)

ISSUE_WIDTH = 2, NUM_WARPS = 8 → PER_ISSUE_WARPS = 4

Issue slot 0:  warp 0, warp 2, warp 4, warp 6
Issue slot 1:  warp 1, warp 3, warp 5, warp 7
```

### 스코어보드 (Scoreboard)

> 소스: `sim/simx/scoreboard.h`

레지스터 데이터 해저드를 탐지하는 구조체이다.

```cpp
class Scoreboard {
  // warp별, 레지스터 타입별(Int/Float/Vec) 사용중 비트맵
  in_use_regs_[warp_id][reg_type]  →  BitVector

  void reserve(trace)   // 목적 레지스터를 사용중으로 표시
  void release(trace)   // 목적 레지스터를 해제
  bool in_use(trace)    // 소스/목적 레지스터 중 사용중인 것이 있는지
  auto get_uses(trace)  // 충돌 중인 명령어 목록 반환
};
```

## Stage 5: execute()

> 소스: `core.cpp` — `Core::execute()`

**역할**: 디스패처 출력을 기능 유닛(FU)에 전달한다.

```
dispatchers_[fu].Outputs[iw] → func_units_[fu].Inputs[iw] (delay=2)
```

### 동작

모든 FU 타입(ALU, FPU, LSU, SFU, VPU, TCU)과 issue slot에 대해:
1. 디스패처 출력 포트에 데이터가 있는지 확인
2. `func_units_[fu]->Inputs[iw].push(trace, 2)` — **2사이클 지연**

### 오퍼랜드 수집 → 디스패치 경로 상세

Issue에서 execute까지의 중간 단계:

```
Issue         Operands         Dispatcher        Execute
  │              │                │                 │
  │  push(1)     │   push(내부)   │   push(내부)    │  push(2)
  ├─────────────>├──────────────>├───────────────>├──────────> FuncUnit
  │              │                │                 │
  │              │ 레지스터 뱅크  │ 스레드 패킷     │
  │              │ 충돌 검사      │ 분할            │
```

- **Operands** (`operands.h/cpp`, `opc_unit.h/cpp`):
  레지스터 파일 읽기 시뮬레이션. 뱅크 충돌 시 추가 사이클 스톨.
  `bank_idx = reg_idx % NUM_GPR_BANKS` — 같은 뱅크의 레지스터를 동시에 읽으면 충돌.

- **Dispatcher** (`dispatcher.h/cpp`):
  명령어의 스레드 수가 FU 레인 수보다 많으면 여러 패킷으로 분할한다.
  - `num_packets = NUM_THREADS / num_lanes`
  - 각 패킷에 `pid` (packet ID), `sop`/`eop` (시작/끝) 플래그 부여
  - 라운드-로빈으로 블록을 순회하며 1사이클에 1패킷씩 디스패치

## Stage 6: commit()

> 소스: `core.cpp` — `Core::commit()`

**역할**: 기능 유닛의 결과를 수집하고, 스코어보드를 해제하며, 명령어를 은퇴시킨다.

```
commit_arbs_[iw].Outputs[0] → writeback → scoreboard release → deallocate
```

### 동작

각 issue slot(iw)에 대해:
1. `commit_arbs_[iw]`에서 중재된 결과를 꺼냄 (FU들 간 라운드-로빈)
2. `trace->wb` && `trace->eop`이면:
   - `operands_[iw]->writeback(trace)` — 레지스터 파일에 결과 쓰기
   - `scoreboard_.release(trace)` — 레지스터 해제
3. `trace->eop`이면:
   - `pending_instrs_.remove(trace)` — in-flight 목록에서 제거
   - `trace_pool_.deallocate(trace)` — trace 객체 반환
   - `perf_stats_.instrs += trace->tmask.count()` — 실행된 스레드 수 누적

### eop (End of Packet) 의미

Dispatcher에서 명령어가 여러 패킷으로 분할된 경우,
`eop=true`인 마지막 패킷에서만 스코어보드 해제와 은퇴가 수행된다.
중간 패킷(`eop=false`)은 커밋되지만 완전한 은퇴는 하지 않는다.

## 전체 타이밍 예시

1개 명령어가 파이프라인을 통과하는 최소 사이클 (모든 것이 hit, 스톨 없음):

```
Cycle  0: schedule() — Emulator.step() → trace 생성 → fetch_latch
Cycle  0: fetch()    — fetch_latch → icache_req.push(req, 2)
Cycle  2: (I-cache에 req 도착, cache hit 가정, latency=2)
Cycle  4: fetch()    — icache_rsp 수신 → decode_latch
Cycle  4: decode()   — decode_latch → ibuffer
Cycle  4: issue()    — ibuffer → scoreboard → operands.push(trace, 1)
Cycle  5: (operands에 도착, 뱅크 충돌 없음 가정)
Cycle  5: issue()    — operands → dispatcher
Cycle  5: execute()  — dispatcher → func_unit.push(trace, 2)
Cycle  7: (FU에 도착, ALU 2-cycle latency 가정)
Cycle  9: commit()   — FU 결과 수신 → writeback → 은퇴
```

실제로는 캐시 미스, 스코어보드 해저드, IBuffer 풀, 뱅크 충돌 등으로
사이클이 늘어난다.

## 성능 카운터 요약

| 카운터 | 스테이지 | 의미 |
|--------|----------|------|
| `sched_idle` | schedule | 실행 가능한 warp 없음 |
| `ifetch_latency` | fetch | I-cache 요청 대기 누적 |
| `ifetches` | fetch | I-cache 요청 횟수 |
| `ibuf_stalls` | decode | IBuffer 풀 스톨 |
| `scrb_stalls` | issue | 스코어보드 해저드 스톨 |
| `scrb_alu/fpu/lsu/sfu/vpu/tcu` | issue | FU별 스코어보드 스톨 |
| `instrs` | commit | 은퇴된 명령어 수 (스레드 합산) |

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/core.h/cpp` | Core 클래스, 6단계 파이프라인 |
| `sim/simx/pipeline.h` | PipelineLatch (fetch_latch, decode_latch) |
| `sim/simx/ibuffer.h` | IBuffer (warp별 명령어 버퍼, 용량 IBUF_SIZE) |
| `sim/simx/scoreboard.h` | Scoreboard (레지스터 해저드 탐지) |
| `sim/simx/instr_trace.h` | instr_trace_t (명령어 추적 정보) |
| `sim/simx/operands.h/cpp` | Operands (오퍼랜드 수집, 뱅크 충돌) |
| `sim/simx/opc_unit.h/cpp` | OpcUnit (오퍼랜드 컬렉터 유닛) |
| `sim/simx/dispatcher.h/cpp` | Dispatcher (스레드 패킷 분할) |

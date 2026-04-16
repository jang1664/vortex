# Simulation Engine (DES Framework)

SimX의 모든 시뮬레이션 객체는 `sim/common/simobject.h`에 정의된
이산 이벤트 시뮬레이션(Discrete Event Simulation, DES) 프레임워크 위에서 동작한다.

## 핵심 구성 요소

```
SimPlatform (싱글톤)
├── objects_[]          ← 등록된 모든 SimObject
├── imm_events_         ← 즉시(delta) 이벤트 큐
├── reg_events_         ← 미래 사이클 이벤트 큐
├── push_list_          ← 이번 사이클에 push된 포트들
├── pop_list_           ← 이번 사이클에 pop된 포트들
├── cycles_             ← 전역 사이클 카운터
└── delta_              ← delta 사이클 카운터
```

## 1. SimPlatform — 전역 시뮬레이션 스케줄러

`SimPlatform`은 싱글톤으로, 전체 시뮬레이션의 시간 진행과 이벤트 스케줄링을 관리한다.

### 주요 멤버 변수

```cpp
class SimPlatform {
  std::vector<SimObjectBase::Ptr> objects_;        // 등록된 시뮬레이션 객체들
  LinkedList<SimEventBase> reg_events_;             // 미래 사이클 이벤트 (delay > 0)
  LinkedList<SimEventBase> imm_events_;             // 즉시 이벤트 (delay == 0)
  LinkedList<SimPortBase>  push_list_;              // push가 발생한 포트 추적
  LinkedList<SimPortBase>  pop_list_;               // pop이 예약된 포트 추적
  uint64_t cycles_;                                 // 현재 사이클 번호
  uint32_t delta_;                                  // 현재 사이클 내 delta 카운터
};
```

### tick() — 1 사이클 실행

`SimPlatform::tick()`은 매 사이클마다 한 번 호출되며, 아래 4단계를 순서대로 수행한다:

```
┌─────────────────────────────────────────────────────────┐
│                SimPlatform::tick()                        │
│                                                          │
│  Phase 1: fire_immediate_events()                        │
│           → delta 이벤트 처리 (이전 사이클 잔여)          │
│                                                          │
│  Phase 2: for each object in objects_:                   │
│             object->do_tick()     ← 각 객체의 tick() 호출│
│             fire_immediate_events()  ← delta 이벤트 처리 │
│                                                          │
│  Phase 3: pop_list_ 처리                                 │
│           → 예약된 포트 데이터 제거                       │
│           push_list_ 초기화                               │
│                                                          │
│  Phase 4: fire_registered_events()                       │
│           → ++cycles_                                    │
│           → 현재 사이클에 예약된 미래 이벤트 처리          │
└─────────────────────────────────────────────────────────┘
```

**핵심 포인트:**
- Phase 2에서 각 객체의 `tick()` 후마다 즉시 이벤트를 처리한다 (delta-cycle 의미론)
- Phase 4에서 `cycles_`를 **먼저 증가**시킨 후, 해당 사이클의 이벤트를 처리한다
- 따라서 `delay=1`로 스케줄된 이벤트는 다음 사이클 번호에서 실행된다

### schedule() — 이벤트 스케줄링

```cpp
void schedule(callback, pkt, delay) {
  if (delay == 0) {
    // 즉시 이벤트: imm_events_에 추가, delta 번호 부여
    imm_events_.push_back(new SimCallEvent(callback, pkt, delta_));
    ++delta_;
  } else {
    // 미래 이벤트: reg_events_에 추가, 절대 사이클 번호 부여
    reg_events_.push_back(new SimCallEvent(callback, pkt, cycles_ + delay));
  }
}
```

## 2. SimObject — 시뮬레이션 객체 베이스 클래스

모든 시뮬레이션 가능한 객체(Core, CacheSim, MemSim 등)는 `SimObject<Impl>`을 상속한다.

```cpp
// 베이스 (비템플릿)
class SimObjectBase {
  virtual void do_reset() = 0;   // SimPlatform::reset()에서 호출
  virtual void do_tick() = 0;    // SimPlatform::tick()에서 호출
};

// CRTP 템플릿 래퍼
template <typename Impl>
class SimObject : public SimObjectBase {
  void do_reset() override { static_cast<Impl*>(this)->reset(); }
  void do_tick()  override { static_cast<Impl*>(this)->tick(); }
};
```

### 객체 생성과 등록

```cpp
// 팩토리 메서드로 생성 → 자동으로 SimPlatform에 등록
auto core = Core::Create(core_id, socket, arch, dcrs);
// 내부적으로: SimPlatform::instance().create_object<Core>(args...)
```

모든 객체는 생성 시 `SimPlatform::objects_` 벡터에 추가된다.
`tick()` 호출 순서는 **등록 순서** (= 생성 순서)를 따른다.

### 구현 예시

```cpp
class Core : public SimObject<Core> {
public:
  void reset() { /* 초기 상태 설정 */ }
  void tick()  {
    this->commit();
    this->execute();
    this->issue();
    this->decode();
    this->fetch();
    this->schedule();
    ++perf_stats_.cycles;
  }
};
```

## 3. SimPort\<T\> — 포트 기반 통신

`SimPort<T>`는 SimObject 간에 데이터를 **지연 전달**하는 통신 채널이다.
파이프라인 래치, 캐시 요청/응답 등 모든 데이터 전달에 사용된다.

### 구조

```cpp
template <typename Pkt>
class SimPort : public SimPortBase {
  struct timed_pkt_t {
    Pkt pkt;           // 패킷 데이터
    uint64_t cycles;   // 전달 완료 시점 (절대 사이클)
  };
  std::queue<timed_pkt_t> queue_;   // 수신 큐
};
```

### 핵심 메서드

#### push(data, delay) — 데이터 전송

```cpp
port.push(packet, 2);  // 2사이클 후에 수신측에서 받을 수 있음
```

내부 동작:
1. `SimPlatform::schedule_push(port, pkt, delay)` 호출
2. `delay == 0`: 즉시 이벤트로 등록 (현재 사이클 내 전달)
3. `delay > 0`: 미래 이벤트로 등록 (`cycles_ + delay` 사이클에 전달)
4. 이벤트가 fire되면 `port->transfer(pkt, cycle)` 호출 → 수신 큐에 삽입

#### front() / pop() — 데이터 수신

```cpp
if (!port.empty()) {
  auto& data = port.front();   // 큐의 맨 앞 데이터 읽기 (제거 안 함)
  // ... 데이터 처리 ...
  port.pop();                   // 데이터 제거 예약 (Phase 3에서 실제 제거)
}
```

#### empty() — 수신 가능 여부

```cpp
if (!port.empty()) {
  // 데이터가 도착해 있음 (delivery cycle <= 현재 cycle)
}
```

### 포트 바인딩 (연결)

포트를 연결하면 push된 데이터가 수신측 포트의 큐로 직접 전달된다:

```cpp
// 소스 포트를 싱크 포트에 바인딩
icache_req_port.bind(&cache_sim.CoreReqPorts[0]);

// 이후 소스에서 push하면 싱크의 큐로 전달됨
icache_req_port.push(mem_req, 2);
// → 2사이클 후 cache_sim.CoreReqPorts[0].front()로 수신 가능
```

```
  Core                          CacheSim
  ┌──────────┐                  ┌──────────┐
  │ icache_  │ ──── bind ────> │ CoreReq  │
  │ req_port │    push(req,2)   │ Ports[0] │
  └──────────┘                  └──────────┘
                  2 cycles later:
                                │ queue_에 req 도착
                                │ front()로 읽기 가능
```

### tx_callback — 전송 모니터링

포트에 콜백을 등록하면 push가 발생할 때마다 호출된다.
성능 카운터 수집에 활용된다:

```cpp
memsim_->MemReqPorts.at(i).tx_callback([&](const MemReq& req, uint64_t cycle) {
  perf_mem_reads_  += !req.write;
  perf_mem_writes_ += req.write;
});
```

## 4. 이벤트 타입

### SimCallEvent — 콜백 이벤트

```cpp
SimPlatform::instance().schedule(callback, packet, delay);
// → SimCallEvent 생성
// → fire()시 callback(packet) 호출
```

### SimPortEvent — 포트 전달 이벤트

```cpp
port.push(packet, delay);
// → SimPortEvent 생성
// → fire()시 port->transfer(packet, cycle) 호출
// → 수신측 큐에 패킷 삽입
```

두 이벤트 타입 모두 **메모리 풀 할당** (`PoolAllocator<T, 64>`)을 사용하여
빈번한 이벤트 생성/소멸의 오버헤드를 최소화한다.

## 5. 즉시 이벤트 vs 등록 이벤트

| | 즉시 이벤트 (Immediate) | 등록 이벤트 (Registered) |
|---|---|---|
| delay | `0` | `>= 1` |
| 저장 | `imm_events_` | `reg_events_` |
| 실행 시점 | 같은 사이클, 객체 tick 사이 | `cycles_ + delay` 사이클 |
| 식별 | delta 번호 (사이클 내 순서) | 절대 사이클 번호 |
| 용도 | 같은 사이클 내 전파 | 파이프라인 지연 모델링 |

### Delta 사이클 메커니즘

하나의 시뮬레이션 사이클 내에서도 여러 이벤트가 순서대로 처리될 수 있다:

```
사이클 N:
  delta 0: 이벤트 A 실행 → 새로운 즉시 이벤트 B 생성 (delta 1)
  delta 1: 이벤트 B 실행 → 새로운 즉시 이벤트 C 생성 (delta 2)
  delta 2: 이벤트 C 실행
  → delta_ 리셋 (0으로)
```

이 메커니즘은 같은 사이클 내에서 연쇄적인 데이터 전파를 가능하게 한다.

## 6. 전체 타이밍 다이어그램 예시

Core가 I-cache에 요청을 보내고 응답을 받는 과정:

```
Cycle 0:
  Core::tick()
    fetch() → icache_req_port.push(req, 2)
              → SimPortEvent 생성 (cycle = 0 + 2 = 2)

Cycle 1:
  Core::tick()
    fetch() → icache_rsp_port.empty() == true (아직 미도착)

Cycle 2:
  fire_registered_events()
    → SimPortEvent(cycle=2).fire()
    → CacheSim.CoreReqPorts[0].transfer(req)  ← 캐시에 요청 도착
  CacheSim::tick()
    → 요청 처리, hit이면 응답 생성
    → CoreRspPorts[0].push(rsp, latency)

Cycle 2 + latency:
  fire_registered_events()
    → CoreRspPorts[0]에 응답 도착
  Core::tick()
    fetch() → icache_rsp_port.front() ← 응답 수신!
```

## 소스 파일

| 파일 | 내용 |
|------|------|
| `sim/common/simobject.h` | SimPlatform, SimObject, SimPort, SimEvent 전체 정의 |

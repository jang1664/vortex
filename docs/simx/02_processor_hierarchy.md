# Processor Hierarchy

SimX는 실제 Vortex 하드웨어의 계층 구조를 그대로 반영한다:
Processor → Cluster → Socket → Core.

## 계층 다이어그램

```
ProcessorImpl
├── MemSim (DRAM 시뮬레이터)
├── L3 Cache (전체 프로세서 공유)
│
├── Cluster[0]                          ← NUM_CLUSTERS개
│   ├── L2 Cache (클러스터 내 공유)
│   ├── barriers_[]                     ← 배리어 동기화 상태
│   │
│   ├── Socket[0]                       ← 클러스터당 NUM_SOCKETS개
│   │   ├── L1 I-Cache Cluster          ← NUM_ICACHES개 인스턴스
│   │   ├── L1 D-Cache Cluster          ← NUM_DCACHES개 인스턴스
│   │   ├── L1 Arbiter (I/D → L2)
│   │   │
│   │   ├── Core[0]                     ← 소켓당 SOCKET_SIZE개
│   │   │   ├── Emulator               ← 기능적 ISA 실행
│   │   │   ├── fetch_latch_
│   │   │   ├── decode_latch_
│   │   │   ├── ibuffers_[]            ← warp별 명령어 버퍼
│   │   │   ├── scoreboard_            ← 데이터 해저드 탐지
│   │   │   ├── operands_[]            ← 오퍼랜드 수집기
│   │   │   ├── dispatchers_[]         ← FU별 디스패처
│   │   │   ├── func_units_[]          ← ALU, FPU, LSU, SFU, ...
│   │   │   └── commit_arbs_[]         ← 커밋 중재기
│   │   │
│   │   └── Core[1]
│   │
│   └── Socket[1]
│       └── ...
│
└── Cluster[1]
    └── ...
```

## 1. ProcessorImpl — 최상위 프로세서

> 소스: `sim/simx/processor.h`, `processor_impl.h`, `processor.cpp`

`Processor`는 얇은 래퍼이고, 실제 구현은 `ProcessorImpl`에 있다.

### 멤버 변수

```cpp
class ProcessorImpl {
  const Arch& arch_;
  std::vector<Cluster::Ptr> clusters_;     // 클러스터 배열
  DCRS dcrs_;                              // 디바이스 설정 레지스터
  MemSim::Ptr memsim_;                     // DRAM 시뮬레이터
  CacheSim::Ptr l3cache_;                  // L3 캐시
  uint64_t perf_mem_reads_;                // 메모리 읽기 횟수
  uint64_t perf_mem_writes_;               // 메모리 쓰기 횟수
  uint64_t perf_mem_latency_;              // 누적 메모리 지연
  uint64_t perf_mem_pending_reads_;        // 현재 진행중인 읽기 수
};
```

### 초기화 순서

ProcessorImpl 생성자에서 하드웨어 계층을 바텀업으로 조립한다:

```
1. MemSim 생성 (DRAM)
   └─ Config: NUM_BANKS, MEM_PORTS, BLOCK_SIZE, CLOCK_RATIO

2. Cluster 생성 (NUM_CLUSTERS개)
   └─ 각 Cluster 내부에서 Socket, Core를 재귀적으로 생성

3. L3 Cache 생성
   └─ Config: SIZE, WAYS, BANKS, MSHR, LATENCY

4. L3 ↔ Cluster 연결
   └─ 각 Cluster의 mem_req/rsp_ports를 L3의 CoreReq/RspPorts에 바인딩

5. L3 ↔ MemSim 연결
   └─ L3의 MemReq/RspPorts를 MemSim에 바인딩

6. 성능 카운터 콜백 등록
   └─ MemSim 포트에 tx_callback으로 읽기/쓰기 추적
```

### 메인 시뮬레이션 루프

```cpp
int ProcessorImpl::run() {
  SimPlatform::instance().reset();   // 모든 객체 reset
  this->reset();                     // 성능 카운터 초기화

  bool done;
  do {
    SimPlatform::instance().tick();  // ◀ 1 사이클 진행

    done = true;
    for (auto cluster : clusters_) {
      if (cluster->running()) {      // 아직 실행 중인 클러스터가 있으면
        done = false;
        continue;
      }
      exitcode |= cluster->get_exitcode();
    }
    perf_mem_latency_ += perf_mem_pending_reads_;  // 메모리 지연 누적
  } while (!done);

  return exitcode;
}
```

루프는 모든 클러스터의 모든 코어가 실행을 완료할 때까지 반복된다.
`cluster->running()`은 재귀적으로 socket → core의 `running()`을 확인한다.

## 2. Cluster — 클러스터

> 소스: `sim/simx/cluster.h`, `cluster.cpp`

클러스터는 여러 소켓과 L2 캐시를 묶는 단위이다.

### 멤버 변수

```cpp
class Cluster : public SimObject<Cluster> {
  uint32_t cluster_id_;
  ProcessorImpl* processor_;
  std::vector<Socket::Ptr> sockets_;      // 소켓 배열
  std::vector<CoreMask> barriers_;        // 배리어 상태 (배리어 ID별)
  CacheSim::Ptr l2cache_;                 // L2 캐시
  uint32_t cores_per_socket_;

  // 외부 포트
  std::vector<SimPort<MemReq>> mem_req_ports;  // L2 → L3 요청
  std::vector<SimPort<MemRsp>> mem_rsp_ports;  // L3 → L2 응답
};
```

### 초기화 순서

```
1. Socket 생성 (소켓 수 = NUM_SOCKETS / NUM_CLUSTERS)
2. L2 Cache 생성
   └─ Config: L2_CACHE_SIZE, L2_NUM_WAYS, L2_NUM_BANKS, L2_MSHR_SIZE
3. Socket ↔ L2 연결
   └─ 각 Socket의 mem_req/rsp_ports를 L2의 CoreReq/RspPorts에 바인딩
4. L2 → Cluster 외부 포트 연결
```

### 배리어 동기화

```cpp
void Cluster::barrier(uint32_t bar_id, uint32_t count, uint32_t core_id) {
  auto& barrier = barriers_.at(bar_id);
  barrier.set(core_id);               // 도달한 코어 표시

  if (barrier.count() == count) {      // 모든 코어가 도달했으면
    for (int i = 0; i < barrier.size(); ++i) {
      if (barrier.test(i)) {
        sockets_[i/cores_per_socket_]->resume(i % cores_per_socket_);
      }
    }
    barrier.reset();                   // 배리어 리셋
  }
}
```

배리어는 클러스터 내의 코어들 간 동기화 지점을 제공한다.
`count`개의 코어가 모두 도달하면 일괄적으로 재개(resume)된다.

## 3. Socket — 소켓

> 소스: `sim/simx/socket.h`, `socket.cpp`

소켓은 여러 코어와 L1 I/D 캐시를 묶는 단위이다.

### 멤버 변수

```cpp
class Socket : public SimObject<Socket> {
  uint32_t socket_id_;
  Cluster* cluster_;
  std::vector<Core::Ptr> cores_;        // 코어 배열 (SOCKET_SIZE개)
  CacheCluster::Ptr icaches_;           // L1 명령어 캐시 클러스터
  CacheCluster::Ptr dcaches_;           // L1 데이터 캐시 클러스터

  std::vector<SimPort<MemReq>> mem_req_ports;  // L1 → L2 요청
  std::vector<SimPort<MemRsp>> mem_rsp_ports;  // L2 → L1 응답
};
```

### 초기화 순서

```
1. L1 I-Cache Cluster 생성 (NUM_ICACHES개 인스턴스)
   └─ Read-only, write-back 없음

2. L1 D-Cache Cluster 생성 (NUM_DCACHES개 인스턴스)
   └─ Write-back 가능, 코얼레싱 지원

3. L1 Arbiter 생성 (L1_MEM_PORTS개)
   └─ I-cache와 D-cache의 메모리 요청을 중재 (round-robin)
   └─ 하위 → L2 방향으로 전달

4. Core 생성 (SOCKET_SIZE개)
   └─ 각 Core에 core_id 할당

5. Core ↔ Cache 연결
   └─ 코어의 icache_req/rsp_ports → I-Cache의 CoreReq/RspPorts
   └─ 코어의 dcache_req/rsp_ports → D-Cache의 CoreReq/RspPorts
      (코어당 DCACHE_NUM_REQS개의 D-cache 포트)
```

### 데이터 흐름

```
Core[0]  Core[1]       (SOCKET_SIZE개의 코어)
  │  │     │  │
  │  └─┐   │  └─┐
  │    │   │    │
  ▼    ▼   ▼    ▼
I-Cache  D-Cache        (L1 캐시 클러스터)
  │        │
  └───┐┌───┘
      ▼▼
   L1 Arbiter            (round-robin 중재)
      │
      ▼
 mem_req/rsp_ports       (→ Cluster의 L2 캐시로)
```

## 4. Core — 코어

> 소스: `sim/simx/core.h`, `core.cpp`

코어는 파이프라인의 실행 단위이다. 상세 동작은 [03_pipeline.md](03_pipeline.md) 참조.

### 핵심 멤버 변수

```cpp
class Core : public SimObject<Core> {
  // 파이프라인 래치
  PipelineLatch fetch_latch_;              // schedule → fetch
  PipelineLatch decode_latch_;             // fetch → decode

  // warp별 명령어 버퍼
  std::vector<IBuffer> ibuffers_;          // warp당 1개, 용량 IBUF_SIZE

  // 해저드 탐지
  Scoreboard scoreboard_;                  // 레지스터 의존성 추적

  // 오퍼랜드 / 디스패치 / 실행
  std::vector<Operands::Ptr> operands_;    // ISSUE_WIDTH개
  std::vector<Dispatcher::Ptr> dispatchers_;  // FU 타입별
  std::vector<FuncUnit::Ptr> func_units_;    // FU 타입별
  std::vector<TraceArbiter::Ptr> commit_arbs_;  // ISSUE_WIDTH개

  // 기능적 에뮬레이터
  Emulator emulator_;

  // I-cache 추적
  HashTable<instr_trace_t*> pending_icache_;
  std::list<instr_trace_t*> pending_instrs_;
};
```

### tick() — 파이프라인 실행

```cpp
void Core::tick() {
  this->commit();     // 6단계: 결과 수집, 스코어보드 해제
  this->execute();    // 5단계: 디스패처 → FU 전달
  this->issue();      // 4단계: IBuffer → 스코어보드 → 오퍼랜드
  this->decode();     // 3단계: decode_latch → IBuffer
  this->fetch();      // 2단계: I-cache 요청/응답
  this->schedule();   // 1단계: Emulator.step() → fetch_latch
  ++perf_stats_.cycles;
}
```

## 5. Arch — 아키텍처 설정

> 소스: `sim/simx/arch.h`

```cpp
class Arch {
  uint16_t num_threads_;       // warp당 스레드 수 (런타임 설정 가능)
  uint16_t num_warps_;         // 코어당 warp 수   (런타임 설정 가능)
  uint16_t num_cores_;         // 총 코어 수       (런타임 설정 가능)
  uint16_t num_clusters_;      // 컴파일타임: NUM_CLUSTERS
  uint16_t socket_size_;       // 컴파일타임: SOCKET_SIZE
  uint16_t num_barriers_;      // 컴파일타임: NUM_BARRIERS
  uint64_t local_mem_base_;    // 컴파일타임: LMEM_BASE_ADDR
};
```

**런타임 vs 컴파일타임 설정:**
- `num_threads`, `num_warps`, `num_cores`는 커맨드라인으로 변경 가능 (`-t`, `-w`, `-c`)
- `NUM_CLUSTERS`, `SOCKET_SIZE` 등은 컴파일타임에 결정 (`VX_config.h`)

## 6. 주요 파생 상수

> 소스: `sim/simx/constants.h`

```
NUM_SOCKETS       = ceil(NUM_CORES / SOCKET_SIZE)
ISSUE_WIDTH       = ceil(NUM_WARPS / 16)
PER_ISSUE_WARPS   = NUM_WARPS / ISSUE_WIDTH
DCACHE_NUM_REQS   = NUM_LSU_BLOCKS * DCACHE_CHANNELS
L2_NUM_REQS       = NUM_SOCKETS * L1_MEM_PORTS
L3_NUM_REQS       = NUM_CLUSTERS * L2_MEM_PORTS
```

## 소스 파일 요약

| 파일 | 내용 |
|------|------|
| `sim/simx/processor.h/cpp` | Processor 래퍼 + ProcessorImpl 메인 루프 |
| `sim/simx/processor_impl.h` | ProcessorImpl 정의 |
| `sim/simx/cluster.h/cpp` | Cluster, L2 캐시, 배리어 |
| `sim/simx/socket.h/cpp` | Socket, L1 캐시, 코어 연결 |
| `sim/simx/core.h/cpp` | Core 파이프라인 |
| `sim/simx/arch.h` | 아키텍처 설정 |
| `sim/simx/constants.h` | 상수, 파생 설정값 |

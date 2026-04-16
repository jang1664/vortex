# SimX Overview

SimX는 Vortex GPGPU 프로세서의 **cycle-approximate functional simulator**이다.
RTL 시뮬레이션보다 수십~수백 배 빠르면서도, 사이클 수준의 성능 추정치를 제공한다.

## 설계 철학: 기능 실행 + 타이밍 모델 분리

SimX의 핵심 아이디어는 **기능적 실행**과 **타이밍 시뮬레이션**을 분리하는 것이다.

```
┌─────────────────────────────────────────────────────┐
│                    Core                              │
│                                                      │
│  ┌──────────┐    instr_trace_t    ┌───────────────┐ │
│  │ Emulator │ ──────────────────> │ Pipeline      │ │
│  │ (기능적) │   즉시 실행 완료,   │ Timing Model  │ │
│  │          │   trace 생성        │ (사이클 모델) │ │
│  └──────────┘                     └───────────────┘ │
└─────────────────────────────────────────────────────┘
```

1. **Emulator**: 명령어를 즉시 기능적으로 실행한다 (레지스터 읽기 → 연산 → 결과 쓰기).
   결과는 곧바로 아키텍처 상태에 반영된다.
   실행의 부산물로 `instr_trace_t` (명령어 추적 정보)를 생성한다.

2. **Pipeline Timing Model**: `instr_trace_t`가 6단계 파이프라인을 통과하며
   캐시 지연, 데이터 해저드, 구조 해저드 등을 사이클 단위로 모델링한다.
   기능적 결과는 이미 확정되어 있으므로, 여기서는 **시간만** 시뮬레이션한다.

이 분리 덕분에:
- 기능적 정확성과 타이밍 모델링을 독립적으로 검증할 수 있다
- 타이밍 모델이 틀려도 기능적 결과에 영향이 없다
- 구현이 단순해지고 시뮬레이션 속도가 빠르다

## 하드웨어 계층 구조

SimX는 실제 Vortex RTL의 하드웨어 계층을 그대로 모델링한다:

```
Processor (ProcessorImpl)
├── L3 Cache (전체 공유)
├── MemSim (DRAM)
│
├── Cluster[0]
│   ├── L2 Cache (클러스터 내 공유)
│   ├── Socket[0]
│   │   ├── L1 I-Cache (소켓 내 공유)
│   │   ├── L1 D-Cache (소켓 내 공유)
│   │   ├── Core[0] ── Emulator + Pipeline + FuncUnits
│   │   └── Core[1]
│   └── Socket[1]
│       ├── L1 I-Cache
│       ├── L1 D-Cache
│       └── Core[2], Core[3]
│
└── Cluster[1]
    └── ...
```

| 계층 | 클래스 | 역할 |
|------|--------|------|
| Processor | `ProcessorImpl` | L3 캐시, DRAM, 클러스터 관리, 메인 루프 |
| Cluster | `Cluster` | L2 캐시, 소켓 관리, 배리어 동기화 |
| Socket | `Socket` | L1 I/D 캐시, 코어 관리, L1↔L2 중재 |
| Core | `Core` | 파이프라인, Emulator, 기능 유닛, 스코어보드 |

## 시뮬레이션 엔진

SimX는 **이산 이벤트 시뮬레이션(DES)** 프레임워크 위에 구축되어 있다.

- **SimPlatform**: 전역 시뮬레이션 스케줄러. 사이클 카운터, 이벤트 큐 관리
- **SimObject**: 모든 시뮬레이션 객체의 베이스 클래스. `tick()` 메서드로 매 사이클 구동
- **SimPort\<T\>**: 객체 간 통신 포트. `push(data, delay)` 로 미래 사이클에 데이터 전달

매 사이클마다 `SimPlatform::tick()`이 호출되어:
1. 즉시(delta) 이벤트 처리
2. 모든 SimObject의 `tick()` 호출
3. 포트 큐 업데이트 (pop)
4. 등록된 미래 이벤트 처리 + 사이클 카운터 증가

## 파이프라인 개요

각 Core는 6단계 파이프라인을 모델링한다.
`Core::tick()` 에서 **역순으로** 스테이지를 실행한다 (RTL 관례):

```
tick() 호출 순서:                  데이터 흐름:

1. commit()    ◄────────────────  FuncUnit 결과 수집, 스코어보드 해제
2. execute()   ◄────────────────  Dispatcher → FuncUnit 전달
3. issue()     ◄────────────────  IBuffer에서 명령어 선택, 스코어보드 확인
4. decode()    ◄────────────────  decode_latch → IBuffer 저장
5. fetch()     ◄────────────────  I-cache 요청/응답 처리
6. schedule()  ◄────────────────  Emulator.step() → fetch_latch
```

역순 실행 이유: 뒷 스테이지가 먼저 자리를 비워야 앞 스테이지가 데이터를 밀어넣을 수 있다.

## 소스 파일 맵

```
sim/simx/
├── main.cpp              # 진입점, 커맨드라인 파싱, 시뮬레이션 시작
├── processor.h/cpp       # Processor, ProcessorImpl (메인 루프)
├── processor_impl.h      # ProcessorImpl 정의
├── cluster.h/cpp         # Cluster (L2, 배리어)
├── socket.h/cpp          # Socket (L1 I/D 캐시, 코어 연결)
├── core.h/cpp            # Core (6단계 파이프라인)
├── emulator.h/cpp        # Emulator (기능적 ISA 실행)
├── decode.cpp            # 명령어 디코딩
├── execute.cpp           # 명령어 기능적 실행
├── func_unit.h/cpp       # ALU, FPU, LSU, SFU 유닛
├── dispatcher.h/cpp      # 명령어 분배 (스레드 분할)
├── operands.h/cpp        # 오퍼랜드 수집 (레지스터 읽기)
├── opc_unit.h/cpp        # 오퍼랜드 컬렉터 유닛
├── tensor_unit.h/cpp     # TCU (텐서 연산)
├── vec_unit.h/cpp        # VPU (벡터 연산)
├── cache_sim.h/cpp       # 캐시 시뮬레이터 (L1/L2/L3 공통)
├── cache_cluster.h       # 캐시 클러스터 (다중 캐시 인스턴스)
├── mem_sim.h/cpp         # DRAM 시뮬레이터
├── local_mem.h/cpp       # 로컬 메모리 (스크래치패드)
├── mem_coalescer.h/cpp   # 메모리 요청 합병기
├── instr.h               # 명령어 구조체
├── instr_trace.h         # 명령어 추적 정보
├── pipeline.h            # 파이프라인 래치
├── ibuffer.h             # 명령어 버퍼
├── scoreboard.h          # 스코어보드 (해저드 탐지)
├── arch.h                # 아키텍처 설정
├── constants.h           # 상수 및 파생 설정값
├── types.h/cpp           # 타입 정의, 메모리 어댑터
├── dcrs.h/cpp            # 디바이스 설정 레지스터
└── debug.h               # 디버그 유틸리티

sim/common/
└── simobject.h           # SimPlatform, SimObject, SimPort (DES 엔진)

runtime/simx/
└── vortex.cpp            # 호스트 런타임 API (메모리 할당, 커널 실행)
```

## 문서 구성

| 문서 | 내용 |
|------|------|
| [01_simulation_engine.md](01_simulation_engine.md) | DES 엔진: SimPlatform, SimObject, SimPort |
| [02_processor_hierarchy.md](02_processor_hierarchy.md) | 프로세서 계층: Processor → Cluster → Socket → Core |
| [03_pipeline.md](03_pipeline.md) | 6단계 파이프라인 상세 동작 |
| [04_emulator.md](04_emulator.md) | 기능적 에뮬레이터: warp 관리, ISA 실행 |
| [05_functional_units.md](05_functional_units.md) | 기능 유닛: ALU, FPU, LSU, SFU, TCU, VPU |
| [06_memory_hierarchy.md](06_memory_hierarchy.md) | 메모리 계층: 캐시, DRAM, 로컬 메모리 |
| [07_runtime_interface.md](07_runtime_interface.md) | 런타임 인터페이스: 호스트 API, DCR, 커널 실행 |

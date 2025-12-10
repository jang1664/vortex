# `VX_cluster.sv` — 상세 노트

파일: `hw/rtl/VX_cluster.sv`

목적(한 문장)
- 하나의 클러스터(Cluster) 인스턴스를 정의하는 상위 모듈로, 클러스터 내 소켓(또는 서브-소켓)들을 인스턴스화하고 L2 캐시와의 연결 및 DCR 분배, 상태 집계 등을 담당합니다.

파라미터
- `CLUSTER_ID` : 클러스터 고유 ID (정수)
- `INSTANCE_ID` : 인스턴스 이름(문자열)

주요 포트
- `clk`, `reset` : 전역 클럭 및 리셋
- `dcr_bus_if` (slave) : 상위에서 전달되는 DCR 쓰기/제어 버스 인터페이스
- `mem_bus_if` (master [`L2_MEM_PORTS`]) : L2 캐시가 외부(상위)와 연결할 메모리 포트들
- `busy` (output) : 클러스터 내부 활동 상태 (소켓 단위 busy OR)

주요 내부 선언/인터페이스
- `per_socket_mem_bus_if` : 각 소켓이 사용하는 L1/L2 수준의 메모 버스 인터페이스 배열. 크기: `NUM_SOCKETS * L1_MEM_PORTS`.
- `l2cache` (`VX_cache_wrap`) : 이 클러스터 수준의 L2 캐시 래퍼. `core_bus_if`에 `per_socket_mem_bus_if`를 연결하고, `mem_bus_if`(상위)에 바인딩.

핵심 블록 및 동작 흐름
- 리셋 처리
  - `RESET_RELAY (l2_reset, reset);` 로 L2 캐시 리셋을 로컬로 릴레이. 각 소켓도 `RESET_RELAY (socket_reset, reset)`를 사용하여 개별 리셋을 제공합니다.

- L2 캐시 인스턴스화
  - `VX_cache_wrap` 인스턴스 `l2cache`가 생성됩니다. 주요 파라미터:
    - 캐시 크기/라인/뱅크/웨이/단어 크기 등(`L2_CACHE_SIZE`, `L2_LINE_SIZE`, `L2_NUM_BANKS`, `L2_NUM_WAYS` 등)
    - `MSHR_SIZE`, `CRSQ_SIZE`, `MREQ_SIZE` 등 동시성/큐 크기
    - `PASSTHRU`/`WRITEBACK`/`DIRTY_BYTES` 등 동작 제어
  - 포트 연결:
    - `.core_bus_if(per_socket_mem_bus_if)` : 각 소켓(혹은 L1)로부터의 요청을 수신
    - `.mem_bus_if(mem_bus_if)` : 상위(클러스터 바깥)으로 나가는 메모 포트

- 소켓 생성 루프
  - `for (genvar socket_id = 0; socket_id < NUM_SOCKETS; ++socket_id)` 블록에서 `VX_socket` 인스턴스들을 생성
  - 각 소켓에 대해:
    - 개별 리셋(`socket_reset`) 적용
    - `dcr_bus_if` 버퍼링: `socket_dcr_bus_if`를 생성하고 `BUFFER_DCR_BUS_IF` 매크로로 상위 `dcr_bus_if`의 일부(조건: `is_base_dcr_addr`)만 전달하거나 분배
    - `per_socket_mem_bus_if`의 해당 슬라이스(`[socket_id * L1_MEM_PORTS +: L1_MEM_PORTS]`)를 연결
    - (옵션) `gbar_bus_if` 연결 (GBAR_ENABLE 시)
    - 각 소켓의 `busy` 신호를 `per_socket_busy[socket_id]`에 보고

- busy 집계
  - 각 소켓의 `per_socket_busy`를 OR 연산으로 합쳐 상위 `busy` 출력으로 노출: `BUFFER_EX(busy, (| per_socket_busy), ...)`

옵션/조건부 기능
- `PERF_ENABLE` : L2 성능 계측(`l2_perf`)을 선언하고 상위 `sysmem_perf`와 병합. 캐시/메모 관련 성능 카운터 집계 가능.
- `GBAR_ENABLE` : GBAR(글로벌 바?) 관련 인터페이스를 생성하고, `gbar_arb`/`gbar_unit` 인스턴스를 사용하여 소켓별 요청을 중재.

중요 신호/매크로(주의해서 볼 것)
- `VX_mem_bus_if` 타입 필드: `req_valid`, `req_ready`, `req_data`(내부: `rw`, `byteen`, `addr`, `data`, `tag`, `flags` 등), `rsp_valid`, `rsp_ready`, `rsp_data`.
- `BUFFER_DCR_BUS_IF` 매크로: DCR 버스의 버퍼링/분배 정책을 구현 — 어느 주소 범위를 각 소켓이 처리하는지(이 코드에서는 `is_base_dcr_addr` 참조).
- `RESET_RELAY`, `BUFFER_EX` 등의 매크로: 리셋/버퍼 처리와 집계 로직을 간결하게 표현하므로, 매크로 구현을 찾아 내부 동작을 꼭 확인할 것.

읽기 포인트(권장 라인/섹션)
- 모듈 헤더(파라미터/포트 선언): 모듈이 외부와 어떤 계약을 맺는지 빠르게 파악
- `per_socket_mem_bus_if` 선언부: 메모 인터페이스 배열의 크기/타입
- `l2cache` 인스턴스화 블록: 파라미터화된 옵션들(`PASSTHRU`, `WRITEBACK`, `MSHR_SIZE`)이 어떻게 설정되는지 확인
- `g_sockets` 제네레이트 블록 전체: `socket_dcr_bus_if` 생성/버퍼링, `VX_socket`의 포트 매핑, `per_socket_mem_bus_if` 슬라이스 연결 방식
- `BUFFER_EX(busy, ...)` 라인: busy 신호 집계 방식

디버그/검증 체크리스트
- 각 소켓의 `mem_bus_if` 슬라이스가 `l2cache.core_bus_if`와 정확하게 정렬되어 있는지 확인 (`socket_id * L1_MEM_PORTS +: L1_MEM_PORTS` 인덱싱)
- DCR 주소 범위(`VX_DCR_BASE_STATE_BEGIN/END`) 판정에 따라 어떤 DCR들이 클러스터 레벨로 향하는지 확인
- `PASSTHRU`가 활성화되면 캐시가 bypass 되는지(즉, 메모 요청이 캐시를 거치지 않는지) 확인
- `PERF_ENABLE` 경로의 `sysmem_perf_tmp` 병합 로직이 올바른지 확인(정보가 덮어쓰기 되지 않는지)

학습/분석 팁
- Top-down 방식: 먼저 `Vortex.sv`에서 이 클러스터가 어떻게 인스턴스화되는지(입/출력) 확인한 뒤, `VX_cluster.sv`를 읽어 소켓/캐시/버스 구조를 파악하세요.
- 인터페이스 타입(`VX_mem_bus_if`, `VX_dcr_bus_if`) 정의 파일을 열어 필드별 의미(특히 `tag`, `flags`)를 정확히 이해하면 디버깅이 쉬워집니다.
- 매크로(`BUFFER_DCR_BUS_IF`, `RESET_RELAY`, `BUFFER_EX`)들은 파일 내 다른 위치(또는 공통 헤더)에서 정의되어 있으니 해당 정의도 함께 읽으세요.

추가로 정리할 항목(원하시면 생성)
- `VX_socket.sv`와 `VX_cache_wrap.sv`의 상세 매핑표(포트 ↔ 신호 이름 일람)
- `dcr_bus_if` 주소별 분배 매핑(어떤 주소가 base인지, socket별로 다른지)
- 테스트 포인트: 시뮬레이터에서 `NUM_SOCKETS>1`와 `NUM_SOCKETS==1`의 동작 차이 확인

질문 리스트(학습하면서 체크할 것)
1. `per_socket_mem_bus_if`의 정확한 포맷(`req_data.flags` 포함)과 flags의 의미는 무엇인가?
2. `BUFFER_DCR_BUS_IF` 매크로는 내부적으로 어떤 큐잉/우선순위 정책을 사용하는가?
3. `PASSTHRU`가 활성화된 경우 L2가 어떤 조건에서 동작을 건너뛰는가(전부 bypass인가, 일부만인가)?
4. `gbar` 블록은 어떤 리소스를 중재하며, GBAR_ENABLE이 켜진 환경/목적은 무엇인가?

다음 제안
- 원하시면 이 노트를 바탕으로 `VX_socket.sv`와 `cache/VX_cache_wrap.sv`의 매핑표(포트 대 포트, 인덱스 범위)를 자동으로 생성해 드리겠습니다.

---
생성: `docs/rtl/VX_cluster.md` (한글, 상세 노트)
# `VX_cluster.sv` — 파일 요약

요약
- 하나의 클러스터 인스턴스를 정의하는 상위 모듈입니다. 코어(또는 여러 코어), 로컬 메모, 스케줄러/디스패처, 인터페이스 등을 묶어 클러스터 단위 동작을 제공합니다.

주요 인터페이스 (예상)
- 클럭/리셋: `clk`, `reset`.
- DCR 버스 인터페이스: `dcr_bus_if`로부터 제어 레지스터 접근을 받음.
- 메모 버스 인터페이스: L2 포트 집합(`VX_mem_bus_if` 타입) — 상위 `Vortex.sv`의 `per_cluster_mem_bus_if`와 연결.
- 클러스터 상태 출력: `busy` 등.

주요 내부 모듈(추정)
- 코어 인스턴스(`VX_core` 또는 복수의 코어 인스턴스).
- 로컬 메모/스케줄러, warp/스레드 관리 유닛(`VX_wctl_unit` 등).
- 클러스터 내에서 사용하는 로컬 캐시 또는 통신 브릿지.

읽기 포인트
- 파일 초반: 파라미터(클러스터 ID, 인스턴스 이름)와 포트 선언부.
- 중간: 코어/워프 제어 유닛 인스턴스화 블록 — 각 인스턴스에 메모/인터럽트/CSR이 어떻게 바인딩되는지 확인.
- 끝부분: 클러스터 `busy` 집계 및 DCR 버스 버퍼링 로직.

비고
- 내부 구성은 프로젝트 설정(클러스터당 코어 수 등)에 따라 달라질 수 있으니 파라미터 정의를 먼저 확인하세요.

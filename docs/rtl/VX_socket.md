# VX_socket

## 개요
`VX_socket` 모듈은 Vortex GPGPU의 주요 구성 요소 중 하나로, 여러 개의 `VX_core`와 이들이 공유하는 L1 캐시(명령어 및 데이터)를 포함하는 클러스터 단위입니다. 프로세서의 계층 구조에서 코어(Core)와 클러스터(Cluster) 사이의 레벨에 위치하며, 리소스 공유와 통신을 효율적으로 관리합니다.

## 주요 기능
*   **Core Grouping**: `SOCKET_SIZE` 매크로에 정의된 수만큼의 코어를 인스턴스화하여 관리합니다.
*   **L1 Cache Sharing**: 소켓 내의 모든 코어는 L1 명령어 캐시(I-cache)와 L1 데이터 캐시(D-cache)를 공유합니다. 이를 통해 코어 간의 데이터 일관성을 유지하고 캐시 효율을 높입니다.
*   **Memory Arbitration**: I-cache와 D-cache에서 발생하는 메모리 요청(Cache Miss 등)을 중재하여 상위 메모리 계층(L2 캐시 또는 메인 메모리)으로 전달합니다.
*   **Barrier Synchronization**: `GBAR_ENABLE`이 설정된 경우, 소켓 내 코어들의 배리어(Barrier) 요청을 중재하여 글로벌 배리어 네트워크에 연결합니다.
*   **Performance Monitoring**: `PERF_ENABLE`이 설정된 경우, 캐시 및 시스템 메모리의 성능 카운터를 집계합니다.

## 인터페이스

| 포트 이름 | 방향 | 타입 | 설명 |
| --- | --- | --- | --- |
| `clk` | Input | wire | 시스템 클럭 |
| `reset` | Input | wire | 시스템 리셋 |
| `dcr_bus_if` | Slave | VX_dcr_bus_if | DCR(Device Control Register) 접근을 위한 버스 인터페이스 |
| `mem_bus_if` | Master | VX_mem_bus_if array | 메모리 시스템(L2 캐시 또는 메모리)으로 연결되는 마스터 인터페이스 배열 (`L1_MEM_PORTS` 개수) |
| `gbar_bus_if` | Master | VX_gbar_bus_if | 글로벌 배리어 동기화를 위한 인터페이스 (Optional) |
| `busy` | Output | wire | 소켓 내의 코어가 작업 중임을 나타내는 상태 신호 |
| `sysmem_perf` | Input | sysmem_perf_t | 시스템 메모리 성능 카운터 데이터 (Optional) |

## 내부 구조

### 1. VX_core
`SOCKET_SIZE`만큼의 `VX_core` 모듈이 인스턴스화됩니다. 각 코어는 고유한 `CORE_ID`를 가지며, I-cache와 D-cache 버스 인터페이스를 통해 캐시에 접근합니다.

### 2. VX_cache_cluster (I-cache)
*   **역할**: 명령어 캐시 클러스터입니다.
*   **구성**: `NUM_ICACHES` 단위로 구성되며, 소켓 내 모든 코어의 명령어 인출(Fetch) 요청을 처리합니다.
*   **연결**: 코어의 `icache_bus_if`와 연결됩니다.

### 3. VX_cache_cluster (D-cache)
*   **역할**: 데이터 캐시 클러스터입니다.
*   **구성**: `NUM_DCACHES` 단위로 구성되며, 코어의 데이터 로드/스토어 요청을 처리합니다.
*   **특징**: Write-back 또는 Write-through 정책을 지원하며, `L1_MEM_PORTS` 수만큼의 메모리 포트를 가집니다.

### 4. VX_mem_arb
L1 캐시(I-cache, D-cache)와 상위 메모리 인터페이스(`mem_bus_if`) 사이의 중재자입니다.
*   **포트 0**: I-cache와 D-cache의 요청을 중재합니다. 이때 I-cache의 요청이 우선순위("P" Priority)를 가집니다.
*   **그 외 포트**: `L1_MEM_PORTS`가 1보다 큰 경우, 나머지 포트는 D-cache의 추가 메모리 포트와 직접 연결됩니다.

### 5. VX_gbar_arb
`GBAR_ENABLE`이 활성화된 경우 사용됩니다. 소켓 내 여러 코어에서 발생하는 배리어 요청을 중재하여 하나의 `gbar_bus_if`로 내보냅니다.

## 파라미터
*   `SOCKET_ID`: 소켓의 고유 식별자입니다.
*   `INSTANCE_ID`: 디버깅 및 시뮬레이션 로그를 위한 인스턴스 이름 문자열입니다.

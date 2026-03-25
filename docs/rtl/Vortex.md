# `Vortex.sv` — High-level 요약

아래 문서는 `hw/rtl/Vortex.sv`의 상위 수준 설명입니다. 상세한 구현 주석은 원본 소스 파일에 직접 추가하는 방식으로 제공하되, 이 문서는 빠르게 아키텍처를 파악하기 위한 개요입니다.

## 개요

- `Vortex.sv`는 시스템 최상위 모듈로, 여러 클러스터를 인스턴스화하고 L3 캐시 및 외부 메모리 인터페이스와 연결하여 전체 GPU-스타일 아키텍처의 상호 연결을 관리합니다. 또한 DCR(Device Control Register) 버스의 분배와 각 클러스터의 `busy` 상태 집계를 담당합니다.

## 주요 역할

- 클러스터 인스턴스화: `NUM_CLUSTERS`만큼 `VX_cluster` 모듈을 생성하고 각 클러스터에 로컬 메모 인터페이스와 DCR 버스를 연결합니다.
- L3 캐시 래핑: `VX_cache_wrap`(`l3cache`) 인스턴스를 통해 클러스터로부터의 메모 요청을 집계하고 외부 메모 포트(`mem_bus_if`)로 전달합니다.
- 메모 포트 바인딩: 내부 `mem_bus_if` 신호들을 외부 포트(`mem_req_*`, `mem_rsp_*`)에 매핑합니다.
- 성능 계측 및 디버그: 컴파일 타임 옵션(`PERF_ENABLE`, `DBG_TRACE_MEM`, `SIMULATION`)에 따라 성능 카운터와 메모리 트레이스 출력, 시뮬레이션 입출력 플러시 등을 추가합니다.

## 주요 포트(요약)

- `clk`, `reset`: 전역 클럭 및 리셋.
- 메모리 요청/응답: `mem_req_valid`, `mem_req_rw`, `mem_req_byteen`, `mem_req_addr`, `mem_req_data`, `mem_req_tag`, `mem_req_ready`, `mem_rsp_valid`, `mem_rsp_data`, `mem_rsp_tag`, `mem_rsp_ready`.
- DCR 쓰기: `dcr_wr_valid`, `dcr_wr_addr`, `dcr_wr_data`.
- 상태 출력: `busy` (모든 클러스터의 OR 결과).

## 내부 블록과 연결 요약

1. `per_cluster_mem_bus_if`: 각 클러스터(L2)와 연결되는 버스 인터페이스 배열.
2. `mem_bus_if`: L3/외부 메모 포트 인터페이스 배열.
3. `l3cache` (`VX_cache_wrap`): `per_cluster_mem_bus_if`를 `core_bus_if`로 받아 `mem_bus_if`로 연결.
4. `g_mem_bus_if` 제네레이트 블록: `mem_bus_if`의 필드들을 외부 포트들(`mem_req_*`, `mem_rsp_*`)과 바인딩.
5. 클러스터 루프: 각 클러스터에 대해 `cluster_dcr_bus_if`를 통해 DCR을 버퍼링하고, `per_cluster_mem_bus_if`의 슬라이스를 연결.

## 공부 포인트 (Top-down 권장 순서)

1. `Vortex.sv`(이 파일): 전체 데이터/제어 흐름 파악.
2. `VX_cluster.sv`: 클러스터 내부 구조(코어, 로컬 메모, 스케줄러 등).
3. `cache/` 디렉터리: `VX_cache_wrap.sv`, `VX_cache_top.sv` 등에서 L3의 태그/MSHR/쓰기 동작을 확인.
4. `interfaces/`: `VX_mem_bus_if` 및 DCR/스케줄링 인터페이스 규약 파악.

---
파일 위치: `docs/rtl/Vortex.md` — 필요하면 더 상세한 섹션(예: 신호 맵, 시퀀스 다이어그램)을 추가해 드립니다.

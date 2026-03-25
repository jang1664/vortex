# RTL 파일 트리 및 간단 설명

다음 문서는 `hw/rtl` 디렉터리의 파일/디렉터리 구조와 각 항목의 역할을 간략히 정리한 것입니다. 각 항목은 1~3줄로 설명합니다.

## 최상위 파일

- `Vortex.sv`: 시스템 최상위 모듈. 클러스터 생성, L3 캐시 래핑 및 메모리 인터페이스 연결 등 전체 탑 레벨 연결을 담당.
- `Vortex_axi.sv`: AXI 인터페이스 관련 래퍼 및 어댑터. 시스템과 외부 AXI 메모리 연결을 처리.
- `VX_cluster.sv`: 하나의 클러스터(코어 그룹) 인스턴스를 정의. 코어, 로컬 메모리, 스케줄러 등 클러스터 내부 구성 요소를 포함.
- `VX_config.vh`: RTL과 빌드에 사용되는 매크로/설정값을 정의하는 헤더 파일.
- `VX_define.vh`: 공통 define, 유틸 매크로 및 전원/리셋 관련 헬퍼 매크로를 제공.
- `VX_gpu_pkg.sv`: GPU 스타일 아키텍처에서 사용하는 공통 타입, 파라미터, 패키지 정의.
- `VX_platform.vh`: 타겟 플랫폼(보드/시뮬레이터) 관련 설정과 플랫폼 종속적 정의.
- `VX_scope.vh`: 시뮬레이션/트레이스 스코프 관련 매크로 및 선언.
- `VX_socket.sv`: 소켓/인터페이스 추상화 레이어 — 외부와의 통신(예: 메모리 소켓) 정의.
- `VX_trace_pkg.sv`: 로깅/트레이스 유틸리티 패키지.
- `VX_types.vh`: 공통 타입 정의 및 비트 필드, 구조체 등.

## 하위 디렉터리 및 주요 파일

- `afu/`: AFU (Accelerator Function Unit) 관련 RTL 및 어댑터들이 위치.
  - `opae/`, `xrt/` 등 각 백엔드(시뮬레이터/런타임)와 연동되는 구현을 포함.

- `cache/`: 캐시 계층 관련 구현.
  - `VX_cache_wrap.sv`, `VX_cache_top.sv`, `VX_cache.sv`: L2/L3 캐시 래퍼와 핵심 캐시 로직.
  - `VX_cache_tags.sv`, `VX_cache_mshr.sv`, `VX_cache_repl.sv`: 태그, MSHR, 교체 정책 등 내부 모듈.
  - `VX_cache_bank.sv`, `VX_cache_data.sv`: 뱅크화된 데이터 저장 및 접근 로직.

- `core/`: 프로세서 코어와 파이프라인 관련 파일(주요 파일 상세)
  - `VX_core.sv`: 개별 코어의 상위 모듈 — 파이프라인과 유닛들 연결.
  - `VX_core_top.sv`: 코어 탑 레벨 인스턴스화 및 인터페이스 연결.
  - `VX_fetch.sv`, `VX_decode.sv`, `VX_issue.sv`, `VX_execute.sv`, `VX_writeback_if.sv`: 기본적인 파이프라인 스테이지와 인터페이스.
  - `VX_dispatch.sv`, `VX_dispatch_unit.sv`: 명령 디스패치 로직과 유닛.
  - `VX_commmit.sv`, `VX_commit.sv`: 명령 커밋 및 상태 관리(레지스터 파일, CSR 등).
  - `VX_lsu_unit.sv`, `VX_mem_unit.sv`, `VX_mem_unit_top.sv`: 로드/스토어 유닛 및 메모리 액세스 경로.
  - `VX_scoreboard.sv`, `VX_schedule.sv`: 자원 추적과 스케줄러 로직.
  - `VX_alu_unit.sv`, `VX_alu_int.sv`, `VX_alu_muldiv.sv`: 산술/논리/곱셈-나눗셈 유닛.
  - `VX_ibuffer.sv`, `VX_issue_slice.sv`, `VX_issue_top.sv`: 인스트럭션 버퍼 및 발행(issue) 관련 모듈.
  - `VX_wctl_unit.sv`, `VX_uop_sequencer.sv`: warp/스레드 제어 및 마이크로-오퍼레이션 시퀀서.
  - `VX_uuid_gen.sv`: 유니크 태그/아이디 생성기.

- `fpu/`: 부동소수점 연산 관련 유닛
  - `VX_fpu_unit.sv`, `VX_fpu_pkg.sv`, `VX_fpu_cvt.sv`, `VX_fpu_div.sv`, `VX_fpu_sqrt.sv`: FPU 연산, 변환, 분할/제곱근 등 구현.
  - `VX_fpu_define.vh`: FPU 관련 파라미터와 정의.

- `interfaces/`: 다양한 모듈 간의 SystemVerilog 인터페이스 정의
  - `VX_dcr_bus_if.sv`: DCR (Device Control Register) 버스 인터페이스.
  - `VX_commit_if.sv`, `VX_fetch_if.sv`, `VX_issue_sched_if.sv`, `VX_scoreboard_if.sv` 등: 코어/스케줄러/커밋 등 각 기능별 인터페이스 정의.

- `libs/`: 범용 라이브러리 모듈들(어댑터, FIFO, 버퍼, 산술 등)
  - `VX_fifo_queue.sv`, `VX_elastic_buffer.sv`, `VX_bypass_buffer.sv`: 버퍼/큐 관련 유틸.
  - `VX_axi_adapter.sv`, `VX_avs_adapter.sv`: 외부 인터페이스(AXI/AVS) 어댑터.
  - `VX_bits_concat.sv`, `VX_bits_insert.sv`, `VX_find_first.sv`: 비트 조작 유틸리티.

- `mem/`: 메모리 서브시스템 관련 코드(세부 파일은 디렉터리 참조).

- `tcu/`: 타이밍/테스트 제어 유닛 또는 특수 컨트롤 유닛(구현에 따라 다름).


## 참고 및 다음 단계

- 필요하면 각 파일별로 더 깊은 설명(핵심 함수/모듈 내부 흐름, 신호 맵)을 추가해 드립니다.
- 원하시면 이 파일을 Git으로 커밋하도록 도와드리거나, 각 파일에 대한 링크/라인 범위를 포함한 더 상세 노트를 생성할 수 있습니다.

---
Generated: `hw/rtl` 폴더 스캔 기반 요약 (간단 정리, 한글)

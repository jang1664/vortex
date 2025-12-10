아래는 추천 공부 순서(Top-down)와 각 단계에서 집중할 포인트입니다. 한글로 간결하게 정리했습니다.

1) 전체 구조 파악 (Already done / 복습)
- 파일: `Vortex.sv`  
- 포인트: 클러스터 인스턴스화, L3 캐시(`l3cache`) 연결, `per_cluster_mem_bus_if` ↔ `mem_bus_if` 매핑, DCR 분배, `busy` 집계.  
- 목표(30–60분): 전체 데이터 흐름을 머릿속에 그림으로 그리기. 각 인터페이스 이름과 역할 외우기.

2) 클러스터 레벨 심화 (첫 번째 우선순위)
- 파일: `VX_cluster.sv` (+ `VX_cluster`가 인스턴스화하는 상위 요소)  
- 포인트: 클러스터가 코어를 어떻게 구성하는지(코어 수, 로컬 메모, 스케줄러), DCR 버스 버퍼링(`BUFFER_DCR_BUS_IF`), `per_cluster_mem_bus_if` 슬라이스 바인딩.  
- 목표(1–2시간): 클러스터 입/출력 포트 전부 정리, 클러스터 내부에서 어떤 모듈이 메모 요청을 생성하는지 파악.

3) 코어 내부 (핵심: 파이프라인 흐름)
- 먼저 읽을 파일 우선순위:
  - `core/VX_core_top.sv` → `core/VX_core.sv`  
  - `core/VX_fetch.sv` → `core/VX_decode.sv` → `core/VX_issue.sv` (및 `VX_issue_top.sv`, `VX_issue_slice.sv`) → `core/VX_execute.sv` → `core/VX_commit.sv`
  - 보조: `core/VX_ibuffer.sv`, `core/VX_dispatch.sv`, `core/VX_schedule.sv`, `core/VX_scoreboard.sv`, `core/VX_operands.sv`
  - 메모 경로: `core/VX_lsu_unit.sv`, `core/VX_mem_unit_top.sv`, `core/VX_mem_unit.sv`
- 포인트: 각 스테이지의 인터페이스(핸드셰이크), uop 포맷, 스코어보드/포워딩/리소스 관리, LSU의 주소 정렬 및 태그 처리.  
- 목표(파일당 30–90분): 흐름(인스트럭션이 fetch→commit까지 어떻게 이동하는지), 종속성 해소/발행/리트라이 포인트 파악.

4) 캐시 & 메모리 경로 (두 번째 우선순위)
- 파일: `cache/VX_cache_wrap.sv`, `cache/VX_cache_top.sv`, `cache/VX_cache.sv`, `cache/VX_cache_tags.sv`, `cache/VX_cache_mshr.sv`, `cache/VX_cache_repl.sv`, `cache/VX_cache_data.sv`, `cache/VX_cache_bank.sv`  
- 포인트: 요청이 들어왔을 때 히트/미스 경로, MSHR 할당/응답 매칭, writeback/eviction 시퀀스, 태그와 데이터 뱅크 관계.  
- 목표(각 소단원 1–2시간): L3와 L2(클러스터) 사이의 변환 규약 완전히 이해.

5) 인터페이스 파일 집중
- 파일: `interfaces/VX_mem_bus_if.sv`, `interfaces/VX_dcr_bus_if.sv`, `interfaces/*_if.sv` (fetch/commit/issue 등)  
- 포인트: 인터페이스 필드(태그, flags, byteen 등), 핸드셰이크 규약, 파라미터화된 폭.  
- 목표(각 파일 20–40분): 어떤 필드가 어떤 의미인지 정리(노트에 표로 정리 추천).

6) 공통 라이브러리/유틸
- 파일: `libs/VX_fifo_queue.sv`, `VX_elastic_buffer.sv`, `VX_axi_adapter.sv`, `VX_bits_*` 등  
- 포인트: 재사용 블록의 API(입력/출력/버퍼링 방식), AXI/AVS 어댑터의 데이터 폭/스트로브 변환 처리.  
- 목표(파일당 20–60분): 재사용성 이해 → 상위 모듈을 읽을 때 빠르게 맥락 파악 가능.

7) FPU 및 특수 유닛
- 파일: `fpu/VX_fpu_unit.sv` 및 서브모듈들  
- 포인트: 파이프라인 깊이, 라운딩/예외 전파, 유닛 간 인터페이스.  
- 목표: FPU 명령의 지연과 commit/예외 처리 연동 파악.

8) AFU / 플랫폼 / 시뮬레이터 적층
- 파일: `afu/`, `Vortex_axi.sv`, `VX_socket.sv`, `mem/` 디렉터리  
- 포인트: 호스트 런타임과의 경계, 시뮬레이션 스텁/모델, 플랫폼 분기(`#ifdef`), AXI 매핑 세부사항.  
- 목표: 실제 HW 연동/시뮬 환경 차이 이해.

학습 방식(권장)
- 노트 템플릿(각 파일에 대해 작성):
  - 목적(한 문장), 주요 포트(표 형태), 내부 인스턴스(간단 리스트), 데이터 흐름(한 단락), 읽을 포인트(체크리스트), 의문점(질문 목록)
- 코드 옆에 임시 주석 추가(로컬 복사본에) — 이해 안 되는 부분에 TODO/QUESTION 주석 표시.
- 자주 쓰는 검색 명령:
  - 특정 신호(예: `mem_req_valid`) 사용 위치 찾기: grep/rg로 전역 검색
  - 인터페이스 타입 사용 위치: `grep -R \"VX_mem_bus_if\" -n hw/rtl`
- 매 단계 끝에 짧은 체크포인트: "이 파일에서 답을 찾은 질문 3개" 정리.

권장 학습 순서(요약)
- 1: `Vortex.sv` (완료/복습)  
- 2: `VX_cluster.sv`  
- 3: Core 계열(Top→Stage 순)  
- 4: Cache 계열 (wrap→core→tags→mshr)  
- 5: Interfaces  
- 6: Libs/Adapters  
- 7: FPU 및 특수 유닛  
- 8: AFU/Platform/시뮬 관련
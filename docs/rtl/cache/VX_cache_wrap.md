# `cache/VX_cache_wrap.sv` — 상세 노트

파일: `hw/rtl/cache/VX_cache_wrap.sv`

목적(한 문장)
- 캐시 래퍼(wrapper) 모듈로, 상위 레벨(예: `Vortex.sv`, `VX_cluster.sv`)과 실제 캐시 구현(`VX_cache.sv`) 사이를 연결하며, bypass/passthru 옵션, 성능 계측, 버퍼링 정책을 통합 관리합니다.

주요 파라미터
- `INSTANCE_ID` : 인스턴스 이름(문자열) — 디버그/트레이스 식별용
- `TAG_SEL_IDX` : 태그 선택 인덱스(bypass 관련)
- `NUM_REQS` : 코어 측에서 동시 요청 가능한 수 (기본값 4)
- `MEM_PORTS` : 외부 메모리 포트 수 (기본값 1)
- `CACHE_SIZE` : 캐시 크기(바이트)
- `LINE_SIZE` : 캐시 라인 크기(바이트)
- `NUM_BANKS`, `NUM_WAYS` : 뱅크 수, way 수
- `WORD_SIZE` : 워드 크기(바이트)
- `CRSQ_SIZE`, `MSHR_SIZE`, `MRSQ_SIZE`, `MREQ_SIZE` : 내부 큐/MSHR 크기
- `WRITE_ENABLE` : 쓰기 가능 여부 (1=enable, 0=read-only)
- `WRITEBACK` : writeback 정책 사용 여부 (1=writeback, 0=write-through)
- `DIRTY_BYTES` : writeback 시 더티 바이트 추적 여부
- `REPL_POLICY` : 교체 정책 (`CS_REPL_FIFO` 등)
- `TAG_WIDTH` : 코어 요청 태그 폭 (기본값 `UUID_WIDTH + 1`)
- `NC_ENABLE` : non-cacheable 주소 bypass 활성화 여부
- `PASSTHRU` : 모든 요청을 캐시 우회(강제 bypass) 여부 (1=캐시 완전 우회)
- `CORE_OUT_BUF`, `MEM_OUT_BUF` : 코어/메모 응답 출력 버퍼 크기

주요 포트
- `clk`, `reset` : 전역 클럭 및 리셋
- `cache_perf` (output, `PERF_ENABLE` 시) : 캐시 성능 계측 구조체
- `core_bus_if` (slave, 배열 `[NUM_REQS]`) : 코어 측으로부터의 메모 요청/응답 인터페이스 (`VX_mem_bus_if`, WORD_SIZE)
- `mem_bus_if` (master, 배열 `[MEM_PORTS]`) : 외부(상위) 메모리로의 요청/응답 인터페이스 (`VX_mem_bus_if`, LINE_SIZE)

주요 내부 선언/인터페이스
- `core_bus_cache_if` : bypass 또는 직결된 캐시 입력 인터페이스 (WORD_SIZE)
- `mem_bus_cache_if` : 캐시가 생성하는 메모 요청/응답 인터페이스 (LINE_SIZE, `CACHE_MEM_TAG_WIDTH`)
- `mem_bus_tmp_if` : bypass 레이어 출력 후 최종 외부로 나가기 전 중간 인터페이스 (LINE_SIZE, `MEM_TAG_WIDTH`)
- 태그 폭 계산(로컬 파라미터):
  - `CACHE_MEM_TAG_WIDTH` : 캐시가 메모 요청에 붙이는 태그 폭 (MSHR/뱅크/메모포트/UUID 기반 계산)
  - `BYPASS_TAG_WIDTH` : bypass 경로의 태그 폭
  - `NC_TAG_WIDTH` : NC_ENABLE 시 non-cacheable 태그 폭 (`MAX(CACHE, BYPASS) + 1`)
  - `MEM_TAG_WIDTH` : 실제 mem_bus_if에서 사용할 최종 태그 폭 (PASSTHRU/NC_ENABLE에 따라 선택)

핵심 블록 및 동작 흐름
- bypass/passthru 처리 (`g_bypass` 블록)
  - 조건: `BYPASS_ENABLE = (NC_ENABLE || PASSTHRU)`
  - 활성화 시:
    - `VX_cache_bypass` 인스턴스를 생성하여 코어 요청(`core_bus_if`)을 받아 캐시 경로(`core_bus_cache_if`)와 우회 경로로 분리하고, 캐시에서 온 메모 응답(`mem_bus_cache_if`)과 우회 응답을 병합하여 `mem_bus_tmp_if`로 출력합니다.
    - bypass 내부에서 주소 기반(또는 PASSTHRU 설정)으로 캐시 우회 여부를 판단하고, LINE_SIZE ↔ WORD_SIZE 변환을 수행합니다.
  - 비활성화 시:
    - `core_bus_if`를 `core_bus_cache_if`에 직접 바인딩 (`ASSIGN_VX_MEM_BUS_IF`)
    - `mem_bus_cache_if`를 `mem_bus_tmp_if`에 직접 바인딩

- 쓰기 가능 여부에 따른 외부 포트 매핑 (`g_mem_bus_if` 블록)
  - `WRITE_ENABLE == 1` : `mem_bus_tmp_if`를 `mem_bus_if`에 전체 신호(읽기/쓰기) 매핑
  - `WRITE_ENABLE == 0` : `mem_bus_tmp_if`를 `mem_bus_if`에 읽기 전용으로 매핑 (`ASSIGN_VX_MEM_BUS_RO_IF`)

- 실제 캐시 인스턴스화 (`g_cache` 블록, `PASSTHRU == 0` 시)
  - `VX_cache` 인스턴스를 생성하고 `core_bus_cache_if`(코어측)와 `mem_bus_cache_if`(메모측)를 연결합니다.
  - 파라미터: 캐시 크기/라인/뱅크/way, MSHR 크기, writeback/dirty 옵션 등 모두 전달
  - 성능 출력: `cache_perf`를 상위로 보고
  - 버퍼링: `BYPASS_ENABLE`이 켜져 있으면 내부 버퍼를 작게(1), 아니면 파라미터값 그대로 사용

- passthru 모드 (`g_passthru` 블록, `PASSTHRU == 1` 시)
  - 캐시 인스턴스를 생성하지 않고, `core_bus_cache_if`와 `mem_bus_cache_if`를 UNUSED/INIT 처리합니다.
  - 성능 계측: `PERF_ENABLE` 시에도 캐시 히트/미스 대신 요청 수, 스톨만 집계합니다(캐시가 없으므로 미스는 항상 0).

성능 계측 (PERF_ENABLE 및 PASSTHRU 조합)
- PASSTHRU=0 (캐시 활성):
  - `cache_perf`는 `VX_cache`에서 직접 출력 (reads, writes, read_misses, write_misses, bank_stalls, mshr_stalls, mem_stalls, crsp_stalls)
- PASSTHRU=1 (캐시 우회):
  - 읽기/쓰기 요청 수, 메모 스톨, 응답 스톨만 집계 (미스/뱅크 스톨은 모두 0)

디버그 트레이스 (DBG_TRACE_CACHE)
- 각 코어 요청(`core_bus_if[i]`)과 메모 요청(`mem_bus_if[i]`)의 req/rsp를 시뮬레이션 타임에 TRACE 출력합니다(읽기/쓰기, 주소, 태그, 데이터 등).

읽기 포인트(권장 라인/섹션)
- 파라미터 선언부: 캐시 크기, 정책, bypass/passthru 옵션 확인
- 태그 폭 계산(`CACHE_MEM_TAG_WIDTH`, `BYPASS_TAG_WIDTH`, `NC_TAG_WIDTH`, `MEM_TAG_WIDTH`): 각 조건별로 어떤 태그가 선택되는지 파악
- `g_bypass` 블록: `VX_cache_bypass`의 역할과 입출력 매핑
- `g_cache` 블록: 실제 `VX_cache` 인스턴스화 시 전달되는 파라미터들과 버퍼 크기 조정 로직
- `g_passthru` 블록: 캐시 우회 시의 성능 계측 방식
- `g_mem_bus_if` 블록: 쓰기 가능 여부에 따른 출력 포트 매핑 차이

디버그/검증 체크리스트
- `PASSTHRU`와 `NC_ENABLE` 설정 조합에 따라 `BYPASS_ENABLE`이 예상대로 설정되는지 확인
- `MEM_TAG_WIDTH`가 bypass/cache 경로에 맞게 계산되는지 확인 (태그 폭 불일치 시 컴파일/런타임 오류 발생 가능)
- bypass 레이어가 WORD_SIZE ↔ LINE_SIZE 변환을 올바르게 수행하는지(주소 정렬, byteen 처리)
- `WRITE_ENABLE==0` 시 쓰기 요청이 차단되거나 무시되는지 확인
- 성능 카운터(PASSTHRU=1일 때) 집계가 올바른지 — 미스는 항상 0이어야 함

학습/분석 팁
- 이 파일은 캐시 계층의 "인터페이스 래퍼"이므로, 실제 캐시 동작(태그 매칭, MSHR, writeback)은 `VX_cache.sv`에서 구현됩니다. `VX_cache_wrap`는 상위와의 계약(인터페이스 폭, 태그, bypass 옵션)을 관리하는 역할입니다.
- bypass 로직(`VX_cache_bypass.sv`)은 별도 파일이므로, 더 자세히 보려면 해당 파일도 읽어야 합니다.
- 태그 폭 계산이 복잡하므로, 매크로(`CACHE_MEM_TAG_WIDTH`, `CACHE_BYPASS_TAG_WIDTH`) 정의를 확인해 어떤 필드들이 포함되는지 파악하세요.

추가로 정리할 항목
- `VX_cache_bypass.sv`의 동작 원리(주소 기반 분기, 데이터 폭 변환 방식)
- `VX_cache.sv`의 내부 구조(뱅크, MSHR, 태그 매칭, writeback 흐름)
- 성능 카운터 필드 상세(각 필드가 정확히 무엇을 측정하는지)

질문 리스트(학습하면서 체크할 것)
1. `NC_ENABLE`이 활성화되면 어떤 주소가 non-cacheable로 판정되는가? (bypass 로직 내부 확인 필요)
2. `BYPASS_ENABLE` 시 `core_bus_cache_if`와 `mem_bus_cache_if`를 bypass가 어떻게 중간에서 라우팅하는가?
3. `WRITEBACK==1`과 `DIRTY_BYTES==1` 조합 시, dirty 라인의 부분 쓰기(partial write)가 어떻게 추적되는가?
4. `CORE_OUT_BUF`와 `MEM_OUT_BUF` 크기가 성능/레이턴시에 미치는 영향은?

---
생성: `docs/rtl/cache/VX_cache_wrap.md` (한글, 상세 노트)

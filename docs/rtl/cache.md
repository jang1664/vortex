# `cache/` 디렉터리 요약

`cache/` 디렉터리는 L2/L3 캐시 동작 관련 소스들을 포함합니다. 태그, 데이터 뱅크, MSHR, 교체 정책 등 캐시의 핵심 컴포넌트가 이 디렉터리에 있음.

주요 파일
- `VX_cache_wrap.sv`: 캐시 래퍼 — 상위 레벨에서 캐시를 인스턴스화하고 인터페이스를 노출.
- `VX_cache_top.sv`: 캐시의 토플로직 연결부.
- `VX_cache.sv`: 캐시의 핵심 로직 구현.
- `VX_cache_tags.sv`: 태그 저장 및 검색 로직.
- `VX_cache_mshr.sv`: MSHR(미해결 요청) 관리 로직.
- `VX_cache_repl.sv`: 교체 정책(교체 알고리즘) 관련 모듈.
- `VX_cache_bank.sv`, `VX_cache_data.sv`: 데이터 뱅크와 데이터 저장/접근 로직.

역할
- 메모리 요청을 캐시 계층에서 처리하여 외부 메모 대역폭을 절감.
- MSHR을 통해 동시 다중 미해결 요청을 추적하고 처리.

다음 학습 포인트
- `VX_cache_wrap.sv`가 `Vortex.sv`와 어떻게 연결되는지(버스 인터페이스 매핑) 확인.
- 태그 매칭, 라인 이그젝션/쓰기백(writeback) 시퀀스를 추적.

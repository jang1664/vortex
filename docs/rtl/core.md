# `core/` 디렉터리 요약

`core/` 디렉터리는 프로세서 코어의 파이프라인, 실행 유닛, 스케줄러, 발행(issue), 커밋 등 CPU/GPU 코어의 핵심 로직을 포함합니다. 학습 우선순위에서 가장 중요한 디렉터리입니다.

주요 파일(선택)
- `VX_core.sv`: 개별 코어 상위 모듈 — 파이프라인 유닛들을 연결.
- `VX_core_top.sv`: 코어 탑 레벨 인스턴스화 및 외부 인터페이스 연결 담당.
- 파이프라인 스테이지: `VX_fetch.sv`, `VX_decode.sv`, `VX_execute.sv`, `VX_writeback_if.sv` 등.
- 발행/디스패치: `VX_issue.sv`, `VX_issue_top.sv`, `VX_dispatch.sv`, `VX_dispatch_unit.sv`.
- 로드/스토어 관련: `VX_lsu_unit.sv`, `VX_mem_unit.sv`, `VX_mem_unit_top.sv`.
- 기타: `VX_scoreboard.sv`, `VX_schedule.sv`, `VX_ibuffer.sv`, `VX_issue_slice.sv`.

역할
- 명령 인출에서 실행, 커밋에 이르는 전체 명령 처리 파이프라인을 구현.
- 스케줄러와 스코어보드를 통해 명령 자원/종속성 관리를 수행.

다음 학습 포인트
- `VX_core.sv`를 먼저 읽고, 그 다음 `VX_fetch.sv` → `VX_decode.sv` → `VX_issue.sv` → `VX_execute.sv` 순으로 상세 분석 권장.

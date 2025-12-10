# `core/VX_core.sv` — 파일 요약

요약
- 개별 코어의 상위 모듈로서, 파이프라인 스테이지(fetch→decode→issue→execute→writeback)와 실행 유닛들을 연결합니다. 레지스터 파일, CSR, 예외/인터럽트 처리와 연동됩니다.

주요 인터페이스
- 파이프라인 인터페이스(입력: fetch/디코드로부터의 인스트럭션 스트림, 출력: commit 신호 등).
- 메모 유닛/LSU와의 연결 포트.
- CSR/DCR 접근 포트.

주요 내부 모듈(추정)
- `VX_fetch`, `VX_decode`, `VX_issue`, `VX_execute`, `VX_writeback_if` 등 파이프라인 스테이지 모듈들.
- ALU/FPU/LSU 등 실행 유닛.

읽기 포인트
- 파이프라인 전송 규약(인터페이스 파일 참조)과 각 스테이지 간 종속성 처리 로직.
- 예외 및 커밋 경로.

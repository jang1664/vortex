# `interfaces/` 디렉터리 요약

`interfaces/` 디렉터리는 모듈 간 통신을 위해 정의된 SystemVerilog 인터페이스 파일들을 포함합니다. 이들 인터페이스는 신호 집합과 핸드셰이크 규약을 표준화하여 모듈 간 결합도를 낮춥니다.

주요 파일(선택)
- `VX_dcr_bus_if.sv`: DCR(Device Control Register) 버스 인터페이스 — 제어 레지스터 쓰기/읽기 규약.
- `VX_mem_bus_if.sv`(여기서는 상위에서 사용됨): 메모리 요청/응답 인터페이스 정의.
- 스케줄/커밋/디스패치 관련 인터페이스: `VX_commit_if.sv`, `VX_fetch_if.sv`, `VX_issue_sched_if.sv`, `VX_scoreboard_if.sv` 등.

역할
- 모듈 간 신호 묶음(버스)을 추상화하여 구현 변경 시 인터페이스 호환성을 보장.

다음 학습 포인트
- 각 인터페이스의 필드(예: 요청/응답 포맷, 태그, 플래그)를 확인하여 상호 계약을 이해하세요.

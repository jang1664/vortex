# `interfaces/VX_dcr_bus_if.sv` — 파일 요약

요약
- DCR(Device Control Register) 쓰기/읽기 버스 인터페이스 정의. 상위 모듈(Vortex)에서 들어온 DCR 쓰기 요청을 클러스터나 내부 모듈에 전달하는 표준 신호 집합을 정의합니다.

주요 필드(예상)
- `write_valid`, `write_addr`, `write_data` 등 쓰기용 신호.
- 버스 버퍼링/우선순위 처리를 위한 플래그.

읽기 포인트
- 인터페이스의 메서드/작업 함수(예: enqueue/dequeue)와 동기화 규약.

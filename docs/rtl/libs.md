# `libs/` 디렉터리 요약

`libs/` 디렉터리는 프로젝트 전반에서 재사용 가능한 유틸리티 및 IP 블록들을 포함합니다. 버퍼, 큐, 어댑터, 비트 조작 유틸리티 등이 여기에 위치합니다.

주요 파일
- `VX_fifo_queue.sv`, `VX_elastic_buffer.sv`, `VX_bypass_buffer.sv`: 다양한 버퍼/큐 구현.
- `VX_axi_adapter.sv`, `VX_avs_adapter.sv`: AXI/AVS 같은 외부 프로토콜 어댑터.
- `VX_bits_concat.sv`, `VX_bits_insert.sv`, `VX_find_first.sv`: 비트/벡터 처리 유틸리티.

역할
- 공통적으로 필요한 자료구조(큐, 버퍼)와 프로토콜 어댑터를 중앙에 둬서 중복 구현을 줄임.

다음 학습 포인트
- 자주 쓰이는 유틸리티들을 먼저 익혀 핵심 모듈을 읽을 때 반복되는 패턴을 빠르게 이해하세요.

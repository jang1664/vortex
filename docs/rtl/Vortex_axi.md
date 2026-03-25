# `Vortex_axi.sv` — 파일 요약

요약
- AXI 인터페이스 관련 래퍼/어댑터 모듈. 외부 AXI 메모리나 디바이스와 시스템 간의 데이터 전송을 중개합니다.

주요 인터페이스 (예상)
- AXI 신호 집합: `aw/awready/awvalid/awaddr`, `w/wvalid/wready/wdata/wstrb`, `b/bvalid/bready`, `ar/arvalid/arready/araddr`, `r/rvalid/rready/rdata` 등.
- 내부 시스템 메모 포트/버스 인터페이스와의 변환 계층(예: `VX_mem_bus_if` 또는 내부 버스 IF).

주요 인스턴스/연결(추정)
- AXI 채널을 내부 메모 버스에 맞춰 변환하는 어댑터 인스턴스.
- 스트로브(byteen)와 데이터 폭 변환 처리 로직.

읽을 포인트
- 모듈 상단의 포트 선언부: 외부 AXI 인터페이스와 내부 포트가 어떻게 매핑되는지 확인.
- 어댑터/변환 함수들(데이터 정렬, 나눠보내기) 섹션.

비고
- 파일명으로부터 역할을 추정했습니다. 상세 신호 맵은 파일 내부 포트 선언부를 확인하세요.

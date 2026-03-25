# `fpu/` 디렉터리 요약

`fpu/` 디렉터리는 부동소수점 연산 유닛과 관련된 구현을 포함합니다. IEEE 규격 변환, 연산 유닛(FMA, DIV, SQRT 등), 라운딩 및 예외 처리를 담당합니다.

주요 파일
- `VX_fpu_unit.sv`: FPU 상위 유닛 통합.
- `VX_fpu_cvt.sv`, `VX_fpu_div.sv`, `VX_fpu_sqrt.sv`: 변환/나눗셈/제곱근 유닛.
- `VX_fpu_pkg.sv`, `VX_fpu_define.vh`: FPU 관련 타입과 매크로 정의.

역할
- 부동소수점 명령을 구현하고, 코어의 실행 유닛과 인터페이스합니다.

다음 학습 포인트
- `VX_fpu_unit.sv`의 입력/출력 포맷과 파이프라인 대역폭(클럭 대 레이턴시)을 확인하세요.

# 목적
m1k1024n1024 에서 속도 향상을 목표로 최적화 한다.

# 문제들
- gemm unit 에서 input 읽기 req issue에서 부터 acc memory에 저장하는데 까지의 latency가 너무 크다
  - mxu에서 col propagation이 32 cycle로 큰 상태
  - LDMA에서의 pre-calc 등 eplilog와 prolog의 latency 때문에 읽어오는 data가 작을 경우 overhead가 커진다.
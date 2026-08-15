# Weight TMEM Arbitration Optimization

## 문제점

Weight LDMA의 command context를 4개로 늘리고 response slot을 8개 유지해도 Input burst 사이의 gap이 남아 있다. 원인은 command/context 부족이 아니라 Input LDMA와 Weight LDMA가 같은 TMEM bank를 동시에 읽으면서 발생하는 bank arbitration 충돌이다.

Weight의 한 beat는 여러 TMEM bank lane의 응답이 모두 필요하지만, Input prefetch가 일부 lane을 먼저 grant받으면 Weight wide read가 여러 cycle로 분리된다. 그 결과 Weight response와 WREG write가 늦어지고, 이미 slot에 준비된 Input도 필요한 Weight가 ready가 될 때까지 GEMM unit에 들어가지 못한다.

## 해결책

Input admission head가 Weight만 기다리는 critical window에서는 TMEM arbiter가 해당 Weight wide-read request를 Input prefetch보다 우선하도록 한다. Scale/ZP/ACC가 모두 준비됐고 Input payload도 이미 buffered된 경우에만 이 우선순위를 적용하고, 그 외에는 기존 arbitration과 fairness를 유지한다.

이 방식으로 Weight response와 WREG write를 연속적으로 완료해, 최종적으로 4-beat Input burst 사이의 gap을 0 cycle로 줄인다. 고정적인 Weight 최우선 정책은 Input starvation을 만들 수 있으므로 사용하지 않는다.

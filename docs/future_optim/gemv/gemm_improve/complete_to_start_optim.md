# Overview
현재 FSM이 생성하는 command 사이에는 dependency가 있다. 이걸 WAIT, NOTIFY COMMAND를 사용해서 명시적으로 sync하고 있다. 문제는 WAIT와 NOTIFY command의 생성 및 실제 실행 cycle 때문에 실제 valid한 work을 하는 command 사이의 complete to start delay가 생기게 된다. GEMV같은 tight한 workload에서는 이게 문제가 된다.

# 해결책
command에 dependency 정보를 embed하자. 즉 어떤 command를 wait 해야하는지 command 내부에 적어두자.
command의 executor에서는 command가 종료되는 직후 cycle에 sigal을 emit하자.
waiting command는 이 signal을 보고 해당 cycle에 바로 dependency를 resolve하고 가능하면 바로 executor로 issue한다.
즉 명시적인 WAIT/NOTIFY COMMAND를 생성하지 않는다.

# 참고사항
feat/gemv-opt branch를 참고한다. 비슷하게 구현된 RTL이 있다.
관련된 부분만 참고한다.
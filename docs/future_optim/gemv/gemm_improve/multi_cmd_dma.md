# 문제점

DMA engine이 하나의 CMD만 수행 가능하다. VX_gemm_fsm이 OUTPUT_STORE를 issue해서 DMA engine이 output store를 수행하면
그 이후에 INPUT_LOAD cmd를 fsm이 생성해도 OUTPUT_STORE가 끝날 때 까지 INPUT_LOAD는 수행되지 않는다. 즉 OUTPUT_STORE에서
그 다음 INPUT_LOAD->COMPUTE 가 overlap 될 수 없다.

# 해결책

DMA engine를 확장해서 outstanding multi cmd를 support할 수 있도록 하자. 내부에 CMD queue를 넣자. depth는 parameterize하고 default는 4개 depth를 사용하자.
DMA cmd의 field의 최대 burst length를 추가하자. OUTPUT_STORE의 경우는 8을 최대 burst length로 하자. 즉 FSM이 command 생성할 때 8로 지정해줘야한다.
INPUT_LOAD는 최대 burst length를 -1로 해서 제한을 없애자.
이 때 한번의 transaction이 끝났을 때를 arbitration 하는 시점으로 사용하자. 즉 OUTPUT_STORE CMD가 먼저 들어오고 그 이후에 INPUT_LOAD CMD가 들어온다고 했을 때 OUTPUT_STORE의 초반 8개 beat transfer가 끝나면
그 이후에는 OUTPUT_STORE와 INPUT_LOAD가 경쟁해야한다. 이때 CMD에 priority field를 추가해서 이걸 기반으로 누굴 먼저할 지 결정하도록 하자. aging 같은 기능은 고려하지 않는다.
이 기능은 HBM을 접근하는 TILE DMA 즉 dma_engine에만 필요하다. 즉 dma_unit을 바꾸지 말고 dma_engine을 확장해서 다른 local DMA등은 불필요한 overhead가 없도록 한다.

# hard rule

계획 수행 도중에 계획한 설계에서 문제가 발견되면 즉시 멈추고 문제를 보고한다.  그 이후에 해결책을 논의한다.

# unresolved issues

# 구현 계획

# 핵심 instances
- local memory xbar
- cache xbar
- axi adapter xbar
- cache bypass switch
  - core request를 cache 또는 direct path로 우회시킨다. (IO request가 bypass하는 것)
  - VX_mem_switch를 사용함.
- lmem switch
  - LSU의 목적지를 switch한다.
  - global mem, local mem, GEMM control MMIO, DMA control MMIO 4 중에 하나를 골라서 보낸다.
- tmem switch
  - local DMA input을 TMEM bank 중 하나로 보낸다. 1:N bank demux임.
- VX_mem_arb
  - mem bus 여러개 들어오는 것을 arbitration 한다. MUX라고 보면 된다. response 돌려보내는 기능도 있다.
  - stream arbiter를 사용한다. 즉 interleaved based interconnection이다.
  - 사용 예시
    - Icache, Dcache가 L1 mem port로 올라가는 것 arbitration
    - VX_cache_bypass 내부에서 core request -> mem request로 올라갈 때 + core request -> 최종 memory ports 들 (direct-path)
    - cache cluster에서 여러 cache를 상위로 올릴 때
    - local memory에 접근하려는 애들 arbitration할 때 (CPU, DMA, GEMM request 등등)
- VX_lmem_arb

### VX_mem_arb
- source와 dst 간의 연결이 fixed.
- interleaving based interconnection.

### VX_stream_xbar
- 일반적인 xbar
- 내부에 arbitration logic이 포함됨.
- 대표 instances
  - "vortex/**/*cache/**/core_req_xbar"
  - "vortex/**/*cache/**/core_rsp_xbar"
  - "vortex/**/mem_unit/**/local_mem/req_xbar"
  - "vortex/**/mem_unit/**/local_mem/rsp_xbar"
  - "vortex/**/axi_adapter/**/req_xbar"
  - "vortex/**/axi_adapter/**/rsp_xbar"

### VX_stream_switch
- routing을 위함. 연결 자체는 fully 연결될 수 있다.
- 내부에 arbitration 기능이 없다. 외부에서 `sel_in`으로 routing을 결정해준다.
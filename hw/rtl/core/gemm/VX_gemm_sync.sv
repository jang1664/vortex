/*
  - Gemm cmd간의 sync를 담당한다.
  - parent cmd queue에서 cmd를 받아서 sync를 맞춰주고 child cmd queue로 demuxing 해준다.
  - wait와 notify cmd를 처리한다. (나머지 cmd는 demuxing 해줌.)
    - notify는 그전에 들어간 cmd 따라서 감. DMA와 gemm node는 notify cmd를 만나면, sync module로 signal을 보내준다.
    - sync module은 wait cmd를 만나면 조건이 만족될때 까지 stall하고 child queue로 req를 보내는 것을 pending한다.
  - sync  module 안에는  N개의 sync register가 존재한다. 이걸 사용해서 wait and notify를 구현한다.
    - notify: register 하나 골라서 특정 value로 set함.
    - wait: 특정 register를 골라서 그게 target하는 condition을 만족하는지 확인함.
        - reg0이 3보다 작다. ← 이런게 이전 compute phase가 끝났는지 알 수 있음. 현재 iteration이 i이면 reg0이 i보다 큰지, 이런식으로 확인
    - 예시
        - double buffering할 때 이전 compute stage가 끝났는지 확인 → wait
        - compute stage은 자기할거 끝내고 notify

*/
`include "VX_define.vh"

module VX_gemm_sync import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_CHILDREN  = 1,
    parameter N_NODE      = 2
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_gemm_fsm_if.slave  gemm_fsm_slv_if, // from parent queue
    VX_gemm_fsm_if.master gemm_fsm_mas_if[N_CHILDREN],  // to child queue
    VX_gemm_sync_if.slave gemm_sync_slv_if[N_NODE] // from cmd ctrls
);

  assign gemm_fsm_slv_if.flag.done = 1'b0;
  assign gemm_fsm_slv_if.flag.idle = 1'b1;
  generate
    for(genvar i=0; i<N_CHILDREN; i=i+1) begin : GEN_CHILDREN
      assign gemm_fsm_mas_if[i].ctrl = '0;
    end

    for(genvar j=0; j<N_NODE; j=j+1) begin : GEN_NODES
      assign gemm_sync_slv_if[j].ready = '1;
    end
  endgenerate

endmodule
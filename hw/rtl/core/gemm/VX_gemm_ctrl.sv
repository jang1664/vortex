/*
  - Gemm 연산할 때 필요한 제어 신호들을 생성하는 모듈. 주로 DMA와 관련된 제어 신호를 생성한다.
  - cfg_reg를 받아서 동작함. cfg_reg에는 matrix 크기, stride, padding 등 정보가 들어있음.
    - start, idle, done signal을 이용해서 시작 시점을 제어함.
    - 내부에 wid, tid등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
  - gemm 연산을 위한 input, weight, output 데이터의 LMEM 접근 제어 신호를 생성함.
    - 각 데이터 타입별로 별도의 read/write 제어 신호를 생성함.
    - gemm_node안에있는 local DMA 엔진과 연동됨.
    - LMEM <-> GEMM 유닛 간 데이터 전송을 control 하는 것이 목적.
  - tiling을 위해서 global memory (dcache) <-> LMEM 사이의 DMA를 제어함.
    - dma cmd controller에게 제어 신호를 보냄.
  
*/

`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_CHILDREN  = 1,
    parameter N_NODE   = 2
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_config_reg_if.slave  cfg_reg_if, // from gemm node
    VX_gemm_ctrl_if.master  gemm_ctrl_if, // to gemm unit
    VX_gemm_sync_if.slave gemm_sync_slv_if[N_NODE] // from cmd CTRLs
);

    VX_gemm_fsm_if gemm_fsm_if ();
    VX_gemm_fsm_if gemm_pqueue_out ();
    VX_gemm_fsm_if gemm_sync_out[N_CHILDREN] ();

    //TODO: implementation
    assign cfg_reg_if.ready = 1'b0;
    assign gemm_ctrl_if.input_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.output_write_ctrl.start = 1'b0;
    assign gemm_ctrl_if.weight_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.quant_param_read_ctrl.start = 1'b0;
    assign gemm_ctrl_if.dma_ctrl.start = 1'b0;

    // control registers

    // top level FSM
    VX_gemm_fsm #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_fsm (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(cfg_reg_if),
      .gemm_fsm_if(gemm_fsm_if)
    );

    // parent cmd queue

    // sync
    VX_gemm_sync #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE)
    ) VX_gemm_sync_instance (
      .clk(clk),
      .reset(reset),
      .gemm_fsm_slv_if(gemm_pqueue_out),
      .gemm_fsm_mas_if(gemm_sync_out),
      .gemm_sync_slv_if(gemm_sync_slv_if)
    );

    // child cmd queue

endmodule
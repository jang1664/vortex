/*
  - Configuration registers for DMA/GEMM control
    - Receives lsu_mem_if for R/W access
    - Outputs entire register set as wire
    - register에 첫번째 register를 start하라는 걸 의미하는 register로 사용. START_BIT 파라미터로 첫번째 register에서 몇번째 bit이 start에 해당하는 bit인지 결정.
      - control과 관련된 bit이 추가적으로 필요하면 첫번째 register를 사용해서 구현 가능.
      - start를 의미하는 곳에 1을 write하는 request가 lsu_mem_if에서 들어온 경우에, config register는 뒷단에 있는 node가 free할 때 까지 write request에 대한 gnt를 pending해야함.
        - 뒷단에 있는 node가 free되면, config register는 start signal을 1로 설정하고, 뒷단에 있는 node가 start signal을 받아서 동작을 시작함.
    - write request를 날리는 master가 여러개인 경우가 일반적일 것임. (from SIMT core + gemm node 등)
      - 각 master별로 독립적인 register set을 구현. regs_out으로 보내는 register set은 내부에서 Round Robin해서 arbitrate함.
*/

`include "VX_define.vh"

module VX_config_registers import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter NUM_REGS  = 16,           // Number of 32-bit registers
  parameter START_BIT = 0,             // Bit position of start signal in register space
  parameter MAS_NUM   = 1
) (
  input wire clk,
  input wire reset,

  // LSU memory interface for register access
  VX_lsu_mem_if.slave lsu_mem_if[MAS_NUM],
  VX_config_reg_if.master regs_out // entire register set output
);

  generate
    for (genvar i = 0; i < MAS_NUM; i = i + 1) begin : block
      assign lsu_mem_if[i].req_ready = 1'b1;
      assign lsu_mem_if[i].rsp_valid = 1'b0;
      assign lsu_mem_if[i].rsp_data  = '0;
    end
  endgenerate

  // Master modport outputs: regs, wid, tid, valid
  assign regs_out.regs  = '0;
  assign regs_out.wid   = '0;
  assign regs_out.tid   = '0;
  assign regs_out.valid = 1'b0;

  // config registers

endmodule

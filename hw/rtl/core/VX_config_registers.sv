/*
  - Configuration registers for DMA/GEMM control
    - Receives lsu_mem_if for R/W access
    - composition : ENTRY x NUM_REGS x wrap_size x 32 bits
      - one set == NUM_REGS
      - we have ENTRY num sets

    - Outputs entire register set as wire
    - register에 첫번째 register(first one from NUM_REGS regs)를 start하라는 걸 의미하는 register로 사용. START_BIT 파라미터로 첫번째 register에서 몇번째 bit이 start에 해당하는 bit인지 결정.
      - control과 관련된 bit이 추가적으로 필요하면 첫번째 register를 사용해서 구현 가능.
    
    - write phase
      - entry가 occupy되어 있는지 확인할 수 있는 signal을 내부에 가지고 있어야함.
      - lsu_mem_if로 wrtie request가 오는 경우에 gnt는 occupy를 봐서 결정.
      - 여기서는 wrap 단위로 request를 받아서 reg에 저장해둠.
    
    - pop phase (cmd issue)
      - occupy된 entry 중에서 start bit이 1인 것들을 round robin해서 backend로 issue 해주기.
      - issue 되는 것은 occupy를 clear하기.
      - 여기서는 thread 단위로 arbitration해서 issue해주기.
        - ENTRY 0에서 thread가 4개 있는 상황. 근데 그 중에 2개가 실제로 start를 1로 올렸음.
        - 그러면 둘 중 하나 골라서 cmd를 issue하기.
      - issue handshake은 VX_config_reg_if의 valid & ready로 판단.
    
    - clear phase (clear register occupy and control reg)
      - ENTRY에는 여러 개의 thread에 대한 request가 있을 수 있음.
      - occupy랑 첫번째 Reg를 clear하는 것은 해당 ENTRY의 모든 request가 issue된 후에 해야함.

    - register set
      - R0
        - control_reg
        - stride
        - bnd
      - R1
        - control reg
        - stride
        -bnd
*/

`include "VX_define.vh"

module VX_config_registers import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter NUM_REGS  = 16,           // Number of 32-bit registers
  parameter NUM_ENTRY = 2,
  parameter START_BIT = 0,            // Bit position of start signal in register space
  parameter MAS_NUM   = 1
) (
  input wire clk,
  input wire reset,

  // LSU memory interface for register access
  VX_lsu_mem_if.slave lsu_mem_if[MAS_NUM],
  VX_config_reg_if.master regs_out // entire register output
);

  logic [NUM_ENTRY-1:0][NUM_REGS-1:0][WARP_SIZE-1:0][31:0] regs;
  logic [NUM_ENTRY-1:0] occupy;
  logic [NUM_ENTRY-1:0][7:0] owner_wid;

  // (not occupy) 일 때만 write gnt를 해주기.
  // 이때 not occupy애를 찾아서 master 에 중에 하나에 할당해줘야함. (round robin)

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

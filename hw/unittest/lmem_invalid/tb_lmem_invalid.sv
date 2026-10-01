`timescale 1ns/1ps
`include "VX_define.vh"
module tb_lmem_invalid;
  logic clk=0;
  always #5 clk=~clk;
  VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(64)) bus[4]();
  for(genvar p=0;p<4;++p)begin
    assign bus[p].req_valid=0;assign bus[p].req_data='0;assign bus[p].rsp_ready=1;
  end
  VX_local_mem #(.SIZE(1572864-8),.NUM_REQS(4),.NUM_BANKS(16),
    .ADDR_WIDTH(18),.WORD_SIZE(8),.TAG_WIDTH(64)) dut(.clk(clk),.reset(1'b1),.mem_bus_if(bus));
  initial begin #100;$finish;end
endmodule

`timescale 1ns/1ps
`include "VX_define.vh"
module tb_acc_capacity;
  logic clk=0,reset=1;
  always #5 clk=~clk;
  localparam DATAW=`MXU_COL*32;
  VX_gemm_acc_if acc();
  VX_mem_bus_if #(.DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),.TAG_WIDTH(64)) output_bus();
  VX_gemm_acc_internal dut(.clk(clk),.reset(reset),.acc_if(acc),.o_lmem_bus_if(output_bus));
  function automatic logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr(input int bank,input int row);
    return (bank/2)*(2*`GEMM_ACC_MEM_DEPTH*`GEMM_PSUM_DATA_SIZE)
         +(bank%2)*`GEMM_PSUM_DATA_SIZE+row*(2*`GEMM_PSUM_DATA_SIZE);
  endfunction
  function automatic logic [DATAW-1:0] pattern(input int bank,input int row);
    for(int c=0;c<`MXU_COL;++c) pattern[c*32+:32]=32'h3f000000+bank*65536+row*16+c;
  endfunction
  task automatic write_row(input int bank,input int row);
    @(negedge clk);
    acc.wr_req_valid=1;acc.wr_req_addr=addr(bank,row);acc.wr_req_data=pattern(bank,row);
    do @(posedge clk);while(!acc.wr_req_ready);
    @(negedge clk);acc.wr_req_valid=0;
  endtask
  task automatic read_row(input int bank,input int row);
    @(negedge clk);
    acc.rd_req_valid=1;acc.rd_req_addr=addr(bank,row);acc.rd_req_tag=bank*4096+row;
    do @(posedge clk);while(!acc.rd_req_ready);
    @(negedge clk);acc.rd_req_valid=0;
    do @(posedge clk);while(!acc.rd_rsp_valid);
    assert(acc.rd_rsp_tag==bank*4096+row && acc.rd_rsp_data===pattern(bank,row))
      else $fatal(1,"ACC bank=%0d row=%0d tag=%0d data=%h expected=%h",bank,row,acc.rd_rsp_tag,acc.rd_rsp_data,pattern(bank,row));
    @(negedge clk);
  endtask
  initial begin
    assert(`GEMM_ACC_MEM_DEPTH==2048 && `MXU_COL==16 && `GEMM_ACC_MEM_TOT_SIZE==524288)
      else $fatal(1,"Expected 512KiB four-bank ACC profile");
    acc.rd_req_valid=0;acc.rd_req_tag=0;acc.rd_req_addr=0;
    acc.rd_dependency_valid=0;acc.rd_dependency_addr=0;acc.rd_rsp_ready=1;
    acc.wr_req_valid=0;acc.wr_req_tag=0;acc.wr_req_addr=0;acc.wr_req_data=0;
    acc.wr_req_final_output=0;acc.wr_req_last=0;
    acc.txn_accept_valid=0;acc.txn_accept_tag=0;acc.txn_accept_rd_en=0;acc.txn_accept_wr_en=0;
    acc.txn_accept_rd_addr=0;acc.txn_accept_wr_addr=0;
    acc.txn_retire_valid=0;acc.txn_retire_tag=0;acc.txn_retire_rd_en=0;acc.txn_retire_wr_en=0;
    acc.txn_retire_rd_addr=0;acc.txn_retire_wr_addr=0;
    output_bus.req_valid=0;output_bus.req_data='0;output_bus.rsp_ready=1;
    repeat(5)@(negedge clk);reset=0;
    for(int b=0;b<4;++b)begin write_row(b,0);write_row(b,1023);write_row(b,1024);write_row(b,2047);end
    for(int b=0;b<4;++b)begin read_row(b,0);read_row(b,1023);read_row(b,1024);read_row(b,2047);end
    $display("TEST PASSED: ACC512KiB all banks rows0/1023/1024/2047, no alias");$finish;
  end
  initial begin #200000;$fatal(1,"ACC capacity timeout");end
endmodule

`timescale 1ns/1ps
`include "VX_define.vh"
module tb_VX_naive_node_integration;
  import VX_gpu_pkg::*;
  logic clk=0, reset=1;
  logic [`GEMM_CFG_REG_NUM-1:0][31:0] reset_test_regs;
  always #5 clk=~clk;
  VX_lsu_mem_if #(.NUM_LANES(1),.DATA_SIZE(8),.TAG_WIDTH(8)) mmio[1]();
  VX_lsu_mem_if #(.NUM_LANES(1),.DATA_SIZE(64),.TAG_WIDTH(8)) dma();
  VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(LMEM_TAG_WIDTH)) lmem[`LMEM_NUM_PORTS]();
  VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(PSUM_LMEM_TAG_WIDTH)) rd[`LMEM_NUM_PORTS]();
  VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(PSUM_ARB_TAG_WIDTH)) wr[`LMEM_NUM_PORTS]();
  VX_gemm_node_naive #(.INSTANCE_ID("integrated_node")) dut (
    .clk(clk),.reset(reset),.mmio_if(mmio),.dma_if(dma),.lmem_bus_if(lmem),
    .psum_rd_lmem_bus_if(rd),.psum_wr_lmem_bus_if(wr),.naive_write_commit('0)
`ifdef PERF_ENABLE
    ,.gemm_unit_perf(),.gemm_node_perf()
`endif
  );
  assign mmio[0].req_valid=0;
  assign mmio[0].req_data='0;
  assign mmio[0].rsp_ready=1;
  assign dma.req_ready=1;
  assign dma.rsp_valid=0;
  assign dma.rsp_data='0;
  for(genvar p=0;p<`LMEM_NUM_PORTS;++p) begin
    assign lmem[p].req_ready=1; assign lmem[p].rsp_valid=0; assign lmem[p].rsp_data='0;
    assign rd[p].req_ready=1; assign rd[p].rsp_valid=0; assign rd[p].rsp_data='0;
    assign wr[p].req_ready=1; assign wr[p].rsp_valid=0; assign wr[p].rsp_data='0;
    always @(posedge clk) if(!reset) begin
      assert(!lmem[p].req_valid && !rd[p].req_valid && !wr[p].req_valid)
        else $fatal(1,"idle node emitted memory request");
    end
  end
  initial begin
    repeat(8) @(negedge clk); reset=0;
    repeat(30) @(negedge clk);
    if(!dut.control_idle || !( &dut.executor_idle) || !dut.gemm_unit_v2_if.pipeline_empty || dma.req_valid)
      $fatal(1,"node not quiescent after reset");
    if ($test$plusargs("ACTIVE_RESET_NEGATIVE")) begin
      // Inject a job at the existing frontend-to-control configuration boundary.
      // The DUT's job-active state and acceptance logic are never forced.
      reset_test_regs='0;
      reset_test_regs[0]=1;
      reset_test_regs[29]=3;reset_test_regs[30]=64;reset_test_regs[31]=64;
      reset_test_regs[32]=5;
      reset_test_regs[33]=3;reset_test_regs[34]=64;reset_test_regs[35]=64;
      force dut.issue_if.regs=reset_test_regs;
      force dut.issue_if.entry_id=0;
      force dut.issue_if.valid=1;
      @(posedge clk);
      if(!dut.cfg_start_fire) $fatal(1,"Reset test job was not accepted");
      #1;
      if(dut.job_active_q!==1'b1) $fatal(1,"Reset test did not enter active invocation");
      $display("ACTIVE_RESET_JOB_ACCEPTED MXU=%0d",`MXU_ROW);
      @(negedge clk);
      release dut.issue_if.valid;release dut.issue_if.regs;release dut.issue_if.entry_id;
      reset=1;
      @(posedge clk); #1;
      $fatal(1,"Active reset was not rejected by the node diagnostic");
    end
    // Also exercise a second full-node reset after verified quiescence.
    reset=1;repeat(3) @(negedge clk);reset=0;
    repeat(8) @(negedge clk);
    if(!dut.control_idle || !( &dut.executor_idle) || dut.job_active_q || dma.req_valid)
      $fatal(1,"node not quiescent after second reset");
    $display("TEST PASSED: actual metadata node initial/quiescent reset MXU=%0d",`MXU_ROW);
    $finish;
  end
endmodule

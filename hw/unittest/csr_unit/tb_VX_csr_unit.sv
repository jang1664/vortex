`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_csr_unit import VX_gpu_pkg::*; ();
  localparam int PERIOD = 10;
  localparam int NUM_REQS = 8;

  logic clk = 1'b0;
  logic reset = 1'b1;
  base_dcrs_t base_dcrs;
  sysmem_perf_t sysmem_perf;
  pipeline_perf_t pipeline_perf;
  accel_perf_t accel_perf;

  logic [UUID_WIDTH-1:0] expected_uuid[NUM_REQS];
  logic [NUM_REGS_BITS-1:0] expected_rd[NUM_REQS];
  logic [PC_BITS-1:0] expected_PC[NUM_REQS];
  logic [`XLEN-1:0] expected_data[NUM_REQS];
  int response_count;
  int cycle_count;

  always #(PERIOD / 2) clk = ~clk;

  VX_commit_csr_if commit_csr_if();
  VX_sched_csr_if sched_csr_if();
  VX_fpu_csr_if fpu_csr_if[`NUM_FPU_BLOCKS]();
  VX_execute_if #(.data_t(sfu_exe_t)) execute_if();
  VX_result_if #(.data_t(sfu_res_t)) result_if();

  assign commit_csr_if.instret = '0;
  assign sched_csr_if.cycles = '0;
  assign sched_csr_if.active_warps = '0;
  assign sched_csr_if.thread_masks = '0;
  assign sched_csr_if.alm_empty = 1'b1;

  for (genvar i = 0; i < `NUM_FPU_BLOCKS; ++i) begin : g_fpu_csr
    assign fpu_csr_if[i].write_enable = 1'b0;
    assign fpu_csr_if[i].write_wid = '0;
    assign fpu_csr_if[i].write_fflags = '0;
    assign fpu_csr_if[i].read_wid = '0;
  end

  VX_csr_unit #(
    .INSTANCE_ID ("csr_unit_tb"),
    .CORE_ID     (0),
    .NUM_LANES   (`NUM_SFU_LANES)
  ) dut (
    .clk           (clk),
    .reset         (reset),
    .base_dcrs     (base_dcrs),
    .sysmem_perf   (sysmem_perf),
    .pipeline_perf (pipeline_perf),
    .accel_perf    (accel_perf),
    .fpu_csr_if    (fpu_csr_if),
    .commit_csr_if (commit_csr_if),
    .sched_csr_if  (sched_csr_if),
    .execute_if    (execute_if),
    .result_if     (result_if)
  );

  always_ff @(posedge clk) begin
    if (reset) begin
      cycle_count <= 0;
      result_if.ready <= 1'b0;
    end else begin
      cycle_count <= cycle_count + 1;
      result_if.ready <= ((cycle_count % 3) != 1);
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      response_count <= 0;
    end else if (result_if.valid && result_if.ready) begin
      if (response_count >= NUM_REQS)
        $fatal(1, "unexpected extra CSR response");
      if (result_if.data.uuid !== expected_uuid[response_count])
        $fatal(1, "response %0d uuid mismatch: expected=%0h actual=%0h",
               response_count, expected_uuid[response_count], result_if.data.uuid);
      if (result_if.data.rd !== expected_rd[response_count])
        $fatal(1, "response %0d rd mismatch: expected=%0h actual=%0h",
               response_count, expected_rd[response_count], result_if.data.rd);
      if (result_if.data.PC !== expected_PC[response_count])
        $fatal(1, "response %0d PC mismatch: expected=%0h actual=%0h",
               response_count, expected_PC[response_count], result_if.data.PC);
      if (result_if.data.data[0] !== expected_data[response_count])
        $fatal(1, "response %0d data mismatch: expected=%0h actual=%0h",
               response_count, expected_data[response_count], result_if.data.data[0]);
      response_count <= response_count + 1;
    end
  end

  task automatic drive_request(
    input int index,
    input logic [7:0] mpm_class,
    input logic [`VX_CSR_ADDR_BITS-1:0] addr
  );
    begin
      @(negedge clk);
      base_dcrs.mpm_class = mpm_class;
      execute_if.data.uuid = UUID_WIDTH'(index + 1);
      execute_if.data.PC = PC_BITS'((index + 1) * 4);
      execute_if.data.rd = NUM_REGS_BITS'(index + 1);
      execute_if.data.op_args.csr.addr = addr;
      execute_if.valid = 1'b1;
      do @(posedge clk); while (!execute_if.ready);
    end
  endtask

  initial begin
    base_dcrs = '0;
    sysmem_perf = '0;
    pipeline_perf = '0;
    accel_perf = '0;
    execute_if.valid = 1'b0;
    execute_if.data = '0;
    execute_if.data.tmask = '1;
    execute_if.data.wb = 1'b1;
    execute_if.data.sop = 1'b1;
    execute_if.data.eop = 1'b1;
    execute_if.data.op_type = INST_SFU_CSRRS;
    execute_if.data.op_args.csr.use_imm = 1'b1;
    execute_if.data.op_args.csr.imm = '0;

    pipeline_perf.sched.idles = PERF_CTR_BITS'(101);
    sysmem_perf.icache.reads = PERF_CTR_BITS'(202);
    accel_perf.gemm_unit.compute_cycles = PERF_CTR_BITS'(303);
    accel_perf.cpu_dma.rd_bytes = PERF_CTR_BITS'(404);
    accel_perf.lmem_dma_input.rd_bytes = PERF_CTR_BITS'(505);
    accel_perf.lmem_dma_weight.rd_bytes = PERF_CTR_BITS'(606);
    accel_perf.lmem_dma_sz.rd_bytes = PERF_CTR_BITS'(707);
    accel_perf.lmem_dma_output.rd_bytes = PERF_CTR_BITS'(808);

    for (int i = 0; i < NUM_REQS; ++i) begin
      expected_uuid[i] = UUID_WIDTH'(i + 1);
      expected_rd[i] = NUM_REGS_BITS'(i + 1);
      expected_PC[i] = PC_BITS'((i + 1) * 4);
    end
    expected_data[0] = `XLEN'(101);
    expected_data[1] = `XLEN'(202);
    expected_data[2] = `XLEN'(303);
    expected_data[3] = `XLEN'(404);
    expected_data[4] = `XLEN'(505);
    expected_data[5] = `XLEN'(606);
    expected_data[6] = `XLEN'(707);
    expected_data[7] = `XLEN'(808);

    repeat (5) @(posedge clk);
    reset = 1'b0;

    drive_request(0, `VX_DCR_MPM_CLASS_CORE,           `VX_CSR_MPM_SCHED_ID);
    drive_request(1, `VX_DCR_MPM_CLASS_MEM,            `VX_CSR_MPM_ICACHE_READS);
    drive_request(2, `VX_DCR_MPM_CLASS_ACCEL_MXU,      `VX_CSR_MPM_GEMM_COMPUTE_CYC);
    drive_request(3, `VX_DCR_MPM_CLASS_ACCEL_DMA,      `VX_CSR_MPM_CPU_DMA_RD_BYTES);
    drive_request(4, `VX_DCR_MPM_CLASS_ACCEL_LDMA_IN,  `VX_CSR_MPM_LDMA_RD_BYTES);
    drive_request(5, `VX_DCR_MPM_CLASS_ACCEL_LDMA_WT,  `VX_CSR_MPM_LDMA_RD_BYTES);
    drive_request(6, `VX_DCR_MPM_CLASS_ACCEL_LDMA_SZ,  `VX_CSR_MPM_LDMA_RD_BYTES);
    drive_request(7, `VX_DCR_MPM_CLASS_ACCEL_LDMA_OUT, `VX_CSR_MPM_LDMA_RD_BYTES);

    @(negedge clk);
    execute_if.valid = 1'b0;

    for (int timeout = 0; timeout < 100; ++timeout) begin
      @(posedge clk);
      if (response_count == NUM_REQS) begin
        $display("TEST PASSED");
        $finish;
      end
    end
    $fatal(1, "CSR response timeout: received %0d/%0d", response_count, NUM_REQS);
  end

endmodule

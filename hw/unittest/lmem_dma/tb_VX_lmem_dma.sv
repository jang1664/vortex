// tb_VX_lmem_dma.sv
`timescale 1ns / 1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// Testbench for VX_lmem_dma (VX_dma_node TB style-ish)
// - OBJ = "func" / "power"
// - dump fsdb(fst) + logs/reports
// - task-based tests
//
// Start is pulse-style (1 cycle).
// Completion detected by ctrl_if.idle toggling (idle->busy->idle).
// Also checks gemm_sync_if.valid/reg_idx/value at end.
// -----------------------------------------------------------------------------

module tb_VX_lmem_dma import VX_gpu_pkg::*; ();

  parameter string tb_name = "tb_VX_lmem_dma";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";  // "func" or "power"
  parameter string FILE_POSTFIX = "func";

  // -----------------------------
  // Params
  // -----------------------------
  localparam int NDIM           = 3;
  localparam int DATA_SIZE_BYTES= 16;      // bus beat bytes
  localparam int MEM_BYTES      = 64*1024;

  // -----------------------------
  // Clock / reset
  // -----------------------------
  logic clk;
  logic reset;

  initial clk = 1'b0;
  always #(PERIOD/2.0) clk = ~clk;

  initial begin
    reset = 1'b1;
    repeat (5) @(posedge clk);
    reset = 1'b0;
  end

  // -----------------------------
  // Interfaces (DIR=0)
  // -----------------------------
  VX_lmem_dma_ctrl_if #(.NDIM(NDIM)) ctrl0_if();
  VX_gemm_sync_if                 sync0_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(8)
  ) lmem0_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(8)
  ) gemm0_bus_if();

  // -----------------------------
  // Interfaces (DIR=1)
  // -----------------------------
  VX_lmem_dma_ctrl_if #(.NDIM(NDIM)) ctrl1_if();
  VX_gemm_sync_if                 sync1_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(8)
  ) lmem1_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(8)
  ) gemm1_bus_if();

  // -----------------------------
  // DUTs
  // -----------------------------
  VX_lmem_dma #(
    .INSTANCE_ID("lmem_dma_dir0"),
    .DIR(0),
    .LMEM_DW(DATA_SIZE_BYTES*8),
    .GEMM_DW(DATA_SIZE_BYTES*8),
    .NDIM(NDIM)
  ) dut_dir0 (
    .clk         (clk),
    .reset       (reset),
    .ctrl_if     (ctrl0_if),
    .gemm_sync_if(sync0_if),
    .lmem_bus_if (lmem0_bus_if),
    .gemm_bus_if (gemm0_bus_if)
  );

  VX_lmem_dma #(
    .INSTANCE_ID("lmem_dma_dir1"),
    .DIR(1),
    .LMEM_DW(DATA_SIZE_BYTES*8),
    .GEMM_DW(DATA_SIZE_BYTES*8),
    .NDIM(NDIM)
  ) dut_dir1 (
    .clk         (clk),
    .reset       (reset),
    .ctrl_if     (ctrl1_if),
    .gemm_sync_if(sync1_if),
    .lmem_bus_if (lmem1_bus_if),
    .gemm_bus_if (gemm1_bus_if)
  );

  // -----------------------------
  // Files / dump (dma_node TB style)
  // -----------------------------
  integer rpt_fd;
  integer log_fd;

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s.%s", tb_name, FILE_POSTFIX);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path,  "./reports/%s.fst",  name);
    $sformat(log_file_path,  "./logs/%s.log",     name);
    $sformat(rpt_file_path,  "./reports/%s.rpt",  name);

`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_lmem_dma);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // -----------------------------
  // Memory models (byte-addressed)
  // -----------------------------
  byte lmem0_mem [0:MEM_BYTES-1];
  byte gemm0_mem [0:MEM_BYTES-1];

  byte lmem1_mem [0:MEM_BYTES-1];
  byte gemm1_mem [0:MEM_BYTES-1];

  // always ready
  assign lmem0_bus_if.req_ready = 1'b1;
  assign gemm0_bus_if.req_ready = 1'b1;
  assign lmem1_bus_if.req_ready = 1'b1;
  assign gemm1_bus_if.req_ready = 1'b1;

  // sync ready always
  assign sync0_if.ready = 1'b1;
  assign sync1_if.ready = 1'b1;

  typedef struct packed {
      logic [`UP(UUID_WIDTH)-1:0]   uuid;
      logic [8-`UP(UUID_WIDTH)-1:0] value;
  } tag_t;

  typedef struct packed {
    logic                         valid;
    logic                         rw;
    logic [lmem0_bus_if.ADDR_WIDTH-1:0] addr_beats;
    logic [DATA_SIZE_BYTES*8-1:0] data;
    logic [DATA_SIZE_BYTES-1:0]   byteen;
    tag_t                         tag;
  } pend_t;

  pend_t l0_pend, g0_pend, l1_pend, g1_pend;

  // -----------------------------
  // Bus slave models (1-cycle latency each) - Verilator friendly
  // -----------------------------

  // LMEM0 slave
  always @(posedge clk) begin
    if (reset) begin
      lmem0_bus_if.rsp_valid <= 1'b0;
      lmem0_bus_if.rsp_data  <= '0;
      l0_pend.valid          <= 1'b0;
    end else begin
      if (lmem0_bus_if.rsp_valid && lmem0_bus_if.rsp_ready)
        lmem0_bus_if.rsp_valid <= 1'b0;

      l0_pend.valid <= 1'b0;
      if (lmem0_bus_if.req_valid && lmem0_bus_if.req_ready) begin
        l0_pend.valid      <= 1'b1;
        l0_pend.rw         <= lmem0_bus_if.req_data.rw;
        l0_pend.addr_beats <= lmem0_bus_if.req_data.addr;
        l0_pend.data       <= lmem0_bus_if.req_data.data;
        l0_pend.byteen     <= lmem0_bus_if.req_data.byteen;
        l0_pend.tag        <= lmem0_bus_if.req_data.tag;
      end

      if (l0_pend.valid) begin
        int unsigned base_b;
        base_b = (l0_pend.addr_beats << $clog2(DATA_SIZE_BYTES));

        lmem0_bus_if.rsp_valid    <= 1'b1;
        lmem0_bus_if.rsp_data.tag <= l0_pend.tag;

        if (!l0_pend.rw) begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              lmem0_bus_if.rsp_data.data[i*8 +: 8] <= lmem0_mem[base_b + i];
            else
              lmem0_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (l0_pend.byteen[i] && (base_b + i < MEM_BYTES))
              lmem0_mem[base_b + i] <= l0_pend.data[i*8 +: 8];
          end
          lmem0_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end

  // GEMM0 slave
  always @(posedge clk) begin
    if (reset) begin
      gemm0_bus_if.rsp_valid <= 1'b0;
      gemm0_bus_if.rsp_data  <= '0;
      g0_pend.valid          <= 1'b0;
    end else begin
      if (gemm0_bus_if.rsp_valid && gemm0_bus_if.rsp_ready)
        gemm0_bus_if.rsp_valid <= 1'b0;

      g0_pend.valid <= 1'b0;
      if (gemm0_bus_if.req_valid && gemm0_bus_if.req_ready) begin
        g0_pend.valid      <= 1'b1;
        g0_pend.rw         <= gemm0_bus_if.req_data.rw;
        g0_pend.addr_beats <= gemm0_bus_if.req_data.addr;
        g0_pend.data       <= gemm0_bus_if.req_data.data;
        g0_pend.byteen     <= gemm0_bus_if.req_data.byteen;
        g0_pend.tag        <= gemm0_bus_if.req_data.tag;
      end

      if (g0_pend.valid) begin
        int unsigned base_b;
        base_b = (g0_pend.addr_beats << $clog2(DATA_SIZE_BYTES));

        gemm0_bus_if.rsp_valid    <= 1'b1;
        gemm0_bus_if.rsp_data.tag <= g0_pend.tag;

        if (!g0_pend.rw) begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              gemm0_bus_if.rsp_data.data[i*8 +: 8] <= gemm0_mem[base_b + i];
            else
              gemm0_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (g0_pend.byteen[i] && (base_b + i < MEM_BYTES))
              gemm0_mem[base_b + i] <= g0_pend.data[i*8 +: 8];
          end
          gemm0_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end

  // LMEM1 slave
  always @(posedge clk) begin
    if (reset) begin
      lmem1_bus_if.rsp_valid <= 1'b0;
      lmem1_bus_if.rsp_data  <= '0;
      l1_pend.valid          <= 1'b0;
    end else begin
      if (lmem1_bus_if.rsp_valid && lmem1_bus_if.rsp_ready)
        lmem1_bus_if.rsp_valid <= 1'b0;

      l1_pend.valid <= 1'b0;
      if (lmem1_bus_if.req_valid && lmem1_bus_if.req_ready) begin
        l1_pend.valid      <= 1'b1;
        l1_pend.rw         <= lmem1_bus_if.req_data.rw;
        l1_pend.addr_beats <= lmem1_bus_if.req_data.addr;
        l1_pend.data       <= lmem1_bus_if.req_data.data;
        l1_pend.byteen     <= lmem1_bus_if.req_data.byteen;
        l1_pend.tag        <= lmem1_bus_if.req_data.tag;
      end

      if (l1_pend.valid) begin
        int unsigned base_b;
        base_b = (l1_pend.addr_beats << $clog2(DATA_SIZE_BYTES));

        lmem1_bus_if.rsp_valid    <= 1'b1;
        lmem1_bus_if.rsp_data.tag <= l1_pend.tag;

        if (!l1_pend.rw) begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              lmem1_bus_if.rsp_data.data[i*8 +: 8] <= lmem1_mem[base_b + i];
            else
              lmem1_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (l1_pend.byteen[i] && (base_b + i < MEM_BYTES))
              lmem1_mem[base_b + i] <= l1_pend.data[i*8 +: 8];
          end
          lmem1_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end

  // GEMM1 slave
  always @(posedge clk) begin
    if (reset) begin
      gemm1_bus_if.rsp_valid <= 1'b0;
      gemm1_bus_if.rsp_data  <= '0;
      g1_pend.valid          <= 1'b0;
    end else begin
      if (gemm1_bus_if.rsp_valid && gemm1_bus_if.rsp_ready)
        gemm1_bus_if.rsp_valid <= 1'b0;

      g1_pend.valid <= 1'b0;
      if (gemm1_bus_if.req_valid && gemm1_bus_if.req_ready) begin
        g1_pend.valid      <= 1'b1;
        g1_pend.rw         <= gemm1_bus_if.req_data.rw;
        g1_pend.addr_beats <= gemm1_bus_if.req_data.addr;
        g1_pend.data       <= gemm1_bus_if.req_data.data;
        g1_pend.byteen     <= gemm1_bus_if.req_data.byteen;
        g1_pend.tag        <= gemm1_bus_if.req_data.tag;
      end

      if (g1_pend.valid) begin
        int unsigned base_b;
        base_b = (g1_pend.addr_beats << $clog2(DATA_SIZE_BYTES));

        gemm1_bus_if.rsp_valid    <= 1'b1;
        gemm1_bus_if.rsp_data.tag <= g1_pend.tag;

        if (!g1_pend.rw) begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              gemm1_bus_if.rsp_data.data[i*8 +: 8] <= gemm1_mem[base_b + i];
            else
              gemm1_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (g1_pend.byteen[i] && (base_b + i < MEM_BYTES))
              gemm1_mem[base_b + i] <= g1_pend.data[i*8 +: 8];
          end
          gemm1_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end

  // -----------------------------
  // Utilities (dma_node TB style)
  // -----------------------------
  task automatic mem_clear_all();
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      lmem0_mem[i] = 8'h00;
      gemm0_mem[i] = 8'h00;
      lmem1_mem[i] = 8'h00;
      gemm1_mem[i] = 8'h00;
    end
  endtask

  task automatic mem_fill_inc_0_lmem(input int unsigned base, input int unsigned nbytes, input byte start);
    byte v;
    v = start;
    for (int unsigned i = 0; i < nbytes; i++) begin
      if (base + i < MEM_BYTES) begin
        lmem0_mem[base + i] = v;
        v++;
      end
    end
  endtask

  task automatic mem_fill_inc_1_gemm(input int unsigned base, input int unsigned nbytes, input byte start);
    byte v;
    v = start;
    for (int unsigned i = 0; i < nbytes; i++) begin
      if (base + i < MEM_BYTES) begin
        gemm1_mem[base + i] = v;
        v++;
      end
    end
  endtask

  task automatic mem_check_equal_0_l_to_g(
    input int unsigned l_base,
    input int unsigned g_base,
    input int unsigned nbytes,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((l_base + i) >= MEM_BYTES || (g_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if (lmem0_mem[l_base + i] !== gemm0_mem[g_base + i]) begin
        $fatal(1, "Mismatch %s @+%0d: L=%02x G=%02x",
               msg, i, lmem0_mem[l_base + i], gemm0_mem[g_base + i]);
      end
    end
  endtask

  task automatic mem_check_equal_1_g_to_l(
    input int unsigned g_base,
    input int unsigned l_base,
    input int unsigned nbytes,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((g_base + i) >= MEM_BYTES || (l_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if (gemm1_mem[g_base + i] !== lmem1_mem[l_base + i]) begin
        $fatal(1, "Mismatch %s @+%0d: G=%02x L=%02x",
               msg, i, gemm1_mem[g_base + i], lmem1_mem[l_base + i]);
      end
    end
  endtask

  // start pulse + program ctrl regs (DIR0)
  task automatic ctrl0_pulse_start(
    input logic [31:0] src_base,
    input logic [31:0] dst_base,
    input logic [31:0] stride0,
    input logic [31:0] stride1,
    input logic [31:0] stride2,
    input logic [31:0] b0,
    input logic [31:0] b1,
    input logic [31:0] b2,
    input logic [31:0] seg_size,
    input logic [31:0] reg_idx,
    input logic [31:0] reg_val
  );
    // wait idle (only accept when idle)
    do @(posedge clk); while (!ctrl0_if.idle);

    ctrl0_if.src_base_addr  = src_base;
    ctrl0_if.dst_base_addr  = dst_base;

    ctrl0_if.src_strides[0] = stride0;
    ctrl0_if.src_strides[1] = stride1;
    ctrl0_if.src_strides[2] = stride2;

    ctrl0_if.dst_strides[0] = stride0;
    ctrl0_if.dst_strides[1] = stride1;
    ctrl0_if.dst_strides[2] = stride2;

    ctrl0_if.bounds[0] = b0;
    ctrl0_if.bounds[1] = b1;
    ctrl0_if.bounds[2] = b2;

    ctrl0_if.seg_size  = seg_size;

    ctrl0_if.reg_idx   = reg_idx;
    ctrl0_if.reg_value = reg_val;

    ctrl0_if.start = 1'b1;
    @(posedge clk);
    ctrl0_if.start = 1'b0;
  endtask

  // start pulse + program ctrl regs (DIR1)
  task automatic ctrl1_pulse_start(
    input logic [31:0] src_base,
    input logic [31:0] dst_base,
    input logic [31:0] stride0,
    input logic [31:0] stride1,
    input logic [31:0] stride2,
    input logic [31:0] b0,
    input logic [31:0] b1,
    input logic [31:0] b2,
    input logic [31:0] seg_size,
    input logic [31:0] reg_idx,
    input logic [31:0] reg_val
  );
    do @(posedge clk); while (!ctrl1_if.idle);

    ctrl1_if.src_base_addr  = src_base;
    ctrl1_if.dst_base_addr  = dst_base;

    ctrl1_if.src_strides[0] = stride0;
    ctrl1_if.src_strides[1] = stride1;
    ctrl1_if.src_strides[2] = stride2;

    ctrl1_if.dst_strides[0] = stride0;
    ctrl1_if.dst_strides[1] = stride1;
    ctrl1_if.dst_strides[2] = stride2;

    ctrl1_if.bounds[0] = b0;
    ctrl1_if.bounds[1] = b1;
    ctrl1_if.bounds[2] = b2;

    ctrl1_if.seg_size  = seg_size;

    ctrl1_if.reg_idx   = reg_idx;
    ctrl1_if.reg_value = reg_val;

    ctrl1_if.start = 1'b1;
    @(posedge clk);
    ctrl1_if.start = 1'b0;
  endtask

  // done detect: idle deassert -> assert (DIR0)
  task automatic wait_dma_done0();
    do @(posedge clk); while (ctrl0_if.idle);   // left IDLE, idle이 1인 동안 기다림, 0이 되어야 다음 단계
    do @(posedge clk); while (!ctrl0_if.idle);  // back to IDLE, idle이 0인 동안 기다림, 1이 되어야 다음 단계
  endtask

  // done detect: idle deassert -> assert (DIR1)
  task automatic wait_dma_done1();
    do @(posedge clk); while (ctrl1_if.idle);
    do @(posedge clk); while (!ctrl1_if.idle);
  endtask

  // wait for sync valid and check payload (DIR0)
  task automatic wait_sync0_and_check(
    input logic [31:0] exp_idx,
    input logic [31:0] exp_val,
    input string msg
  );
    do @(posedge clk); while (!sync0_if.valid);  //sync0_if.valid가 0인 동안 기다림, 1이 되어야 다음 단계
    if (sync0_if.reg_idx !== exp_idx || sync0_if.value !== exp_val) begin
      $fatal(1, "SYNC0 mismatch %s: idx=%0d/%0d val=%08x/%08x",
             msg, sync0_if.reg_idx, exp_idx, sync0_if.value, exp_val);
    end
  endtask

  // wait for sync valid and check payload (DIR1)
  task automatic wait_sync1_and_check(
    input logic [31:0] exp_idx,
    input logic [31:0] exp_val,
    input string msg
  );
    do @(posedge clk); while (!sync1_if.valid);  //sync1_if.valid가 0인 동안 기다림, 1이 되어야 다음 단계
    if (sync1_if.reg_idx !== exp_idx || sync1_if.value !== exp_val) begin
      $fatal(1, "SYNC1 mismatch %s: idx=%0d/%0d val=%08x/%08x",
             msg, sync1_if.reg_idx, exp_idx, sync1_if.value, exp_val);
    end
  endtask

  // -----------------------------
  // Test case runner (dir0 + dir1)
  // -----------------------------
  task automatic run_case(
    input int unsigned seg_bytes,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2
  );
    int unsigned total_bytes;
    int unsigned stride0, stride1, stride2;

    int unsigned l0_src_base, g0_dst_base;
    int unsigned g1_src_base, l1_dst_base;

    logic [31:0] reg0_idx, reg0_val;
    logic [31:0] reg1_idx, reg1_val;

    total_bytes = b0*b1*b2*seg_bytes;

    stride0 = seg_bytes;
    stride1 = b0 * seg_bytes;
    stride2 = b0 * b1 * seg_bytes;

    // base addresses
    l0_src_base = 16'h1000;
    g0_dst_base = 16'h2000;

    g1_src_base = 16'h3000;
    l1_dst_base = 16'h4000;

    reg0_idx = 32'd13;
    reg0_val = 32'hCAFE_BABE;

    reg1_idx = 32'd21;
    reg1_val = 32'hDEAD_BEEF;

    mem_clear_all();

    // -------------------------
    // DIR=0 : LMEM -> GEMM
    // -------------------------
    mem_fill_inc_0_lmem(l0_src_base, total_bytes, 8'h10);

    $display("\n[CASE] seg=%0d bnd=(%0d,%0d,%0d)  DIR0 LMEM->GEMM", seg_bytes, b0, b1, b2);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d)  DIR0 L->G", seg_bytes, b0, b1, b2);

    ctrl0_pulse_start(
      l0_src_base, g0_dst_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg0_idx, reg0_val
    );

    wait_sync0_and_check(reg0_idx, reg0_val, "DIR0");
    wait_dma_done0();
    mem_check_equal_0_l_to_g(l0_src_base, g0_dst_base, total_bytes, "DIR0");

    // -------------------------
    // DIR=1 : GEMM -> LMEM
    // -------------------------
    mem_fill_inc_1_gemm(g1_src_base, total_bytes, 8'h40);

    $display("[CASE] seg=%0d bnd=(%0d,%0d,%0d)  DIR1 GEMM->LMEM", seg_bytes, b0, b1, b2);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d)  DIR1 G->L", seg_bytes, b0, b1, b2);

    ctrl1_pulse_start(
      g1_src_base, l1_dst_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg1_idx, reg1_val
    );

    wait_sync1_and_check(reg1_idx, reg1_val, "DIR1");
    wait_dma_done1();
    mem_check_equal_1_g_to_l(g1_src_base, l1_dst_base, total_bytes, "DIR1");

    $display("[CASE] PASS ✅");
    $fdisplay(rpt_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) PASS", seg_bytes, b0, b1, b2);
  endtask

  // -----------------------------
  // sim_func / sim_power
  // -----------------------------
  task sim_func();
    int unsigned b0 = 2;
    int unsigned b1 = 2;
    int unsigned b2 = 2;

    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BUS_BYTES: %0d", DATA_SIZE_BYTES);

    // ctrl defaults
    ctrl0_if.start = 1'b0;
    ctrl1_if.start = 1'b0;

    // Wait stable
    repeat (5) @(posedge clk);

    run_case(DATA_SIZE_BYTES * 1, b0, b1, b2);
    run_case(DATA_SIZE_BYTES * 2, b0, b1, b2);
    run_case(DATA_SIZE_BYTES * 4, b0, b1, b2);

    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
    $display("TEST PASSED");
  endtask

  task sim_power();
    int unsigned seg_choices [0:2];
    int unsigned b0 = 2;
    int unsigned b1 = 2;
    int unsigned b2 = 2;

    seg_choices[0] = DATA_SIZE_BYTES;
    seg_choices[1] = DATA_SIZE_BYTES * 2;
    seg_choices[2] = DATA_SIZE_BYTES * 4;

    $display("=====================================================================");
    $display("=======================  START POWER SIM  ===========================");
    $display("=====================================================================");

    ctrl0_if.start = 1'b0;
    ctrl1_if.start = 1'b0;

    for (int iter = 0; iter < 300; iter++) begin
      int unsigned seg_bytes = seg_choices[$urandom_range(0,2)];
      run_case(seg_bytes, b0, b1, b2);
      repeat (3) @(posedge clk);
    end

    $display("[POWER] DONE");
    $fdisplay(rpt_fd, "[POWER] DONE");
  endtask

  // -----------------------------
  // Top-level objective runner
  // -----------------------------
  generate
    localparam string OBJ_ = OBJ;
    initial begin
      @(negedge reset);
      repeat (5) @(posedge clk);

      if (OBJ_ == "power") begin
        sim_power();
      end else if (OBJ_ == "func") begin
        sim_func();
      end else begin
        $display("please set proper objective of the simulation");
      end

`ifdef VCS
      $fsdbDumpoff();
`else
      $dumpoff();
`endif
      $fclose(rpt_fd);
      $fclose(log_fd);
      $finish;
    end
  endgenerate

endmodule

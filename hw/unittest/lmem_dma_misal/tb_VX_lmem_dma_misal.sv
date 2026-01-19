// tb_VX_lmem_dma_misal.sv
`timescale 1ns / 1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// Testbench for VX_lmem_dma_misal with REAL VX_local_mem + byte-addressed GEMM node
//
// What we test:
//   Roundtrip:
//     (1) GEMM(src) -> LMEM(tmp) using DIR=1
//     (2) LMEM(tmp) -> GEMM(dst) using DIR=0
//   Verification:
//     Compare only GEMM memory: gemm_mem[src..] == gemm_mem[dst..]
//
// Key points:
//   - One shared LMEM slave bus (VX_local_mem instance)
//   - One shared GEMM slave bus (byte-addressed array model)
//   - Two DMA DUTs (DIR=0/1) act as masters; TB multiplexes their buses
//   - Start is pulse-style (1 cycle), accepted only when ctrl_if.idle=1
//   - Completion detected by idle toggling (idle->busy->idle)
//   - Also checks gemm_sync_if.valid/reg_idx/value at end of each run
// -----------------------------------------------------------------------------

module tb_VX_lmem_dma_misal import VX_gpu_pkg::*; ();

  parameter string tb_name      = "tb_VX_lmem_dma_misal";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";  // "func" or "power"
  parameter string FILE_POSTFIX = "func";

  // -----------------------------
  // Params
  // -----------------------------
  localparam int NDIM            = 3;
  localparam int DATA_SIZE_BYTES = 16;      // bus beat bytes
  localparam int MEM_BYTES       = 64*1024;

  localparam int TAG_WIDTH  = 45;  // >= `UP(UUID_WIDTH) is enough

  localparam int LMEM_PORTS = 1;
  localparam int NUM_REQS   = LMEM_PORTS;
  localparam int NUM_BANKS  = 4;

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
  // Control interfaces (DIR=0/1)
  // -----------------------------
  VX_lmem_dma_ctrl_if #(.NDIM(NDIM)) ctrl0_if();
  VX_gemm_sync_if                  sync0_if();

  VX_lmem_dma_ctrl_if #(.NDIM(NDIM)) ctrl1_if();
  VX_gemm_sync_if                  sync1_if();

  // sync ready always
  assign sync0_if.ready = 1'b1;
  assign sync1_if.ready = 1'b1;

  // -----------------------------
  // Shared slave buses
  // -----------------------------
  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_ifs[LMEM_PORTS]();  // [0]=LDMA only

  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) gemm_bus_s();

  // -----------------------------
  // Per-DUT master buses (to be muxed into shared slaves)
  // -----------------------------
  VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE_BYTES), .TAG_WIDTH(TAG_WIDTH)) lmem0_bus_m();
  VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE_BYTES), .TAG_WIDTH(TAG_WIDTH)) gemm0_bus_m();

  VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE_BYTES), .TAG_WIDTH(TAG_WIDTH)) lmem1_bus_m();
  VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE_BYTES), .TAG_WIDTH(TAG_WIDTH)) gemm1_bus_m();
  
  // -----------------------------
  // DUTs
  // -----------------------------
  VX_lmem_dma_misal #(
    .INSTANCE_ID("lmem_dma_dir0"),
    .DIR(0),
    .NDIM(NDIM)
  ) dut_dir0 (
    .clk         (clk),
    .reset       (reset),
    .ctrl_if     (ctrl0_if),
    .gemm_sync_if(sync0_if),
    .lmem_bus_if (lmem0_bus_m),
    .gemm_bus_if (gemm0_bus_m)
  );

  VX_lmem_dma_misal #(
    .INSTANCE_ID("lmem_dma_dir1"),
    .DIR(1),
    .NDIM(NDIM)
  ) dut_dir1 (
    .clk         (clk),
    .reset       (reset),
    .ctrl_if     (ctrl1_if),
    .gemm_sync_if(sync1_if),
    .lmem_bus_if (lmem1_bus_m),
    .gemm_bus_if (gemm1_bus_m)
  );

  // -----------------------------
  // Bus muxing (only one DMA active at a time)
  //
  // sel = 1 -> DIR1 active (GEMM->LMEM)
  // sel = 0 -> DIR0 active (LMEM->GEMM)
  //
  // We choose sel based on ctrl1_if.idle:
  //   During DIR1 operation: ctrl1_if.idle=0 => sel=1
  //   Otherwise sel=0
  // -----------------------------
  wire sel = ~ctrl1_if.idle;

  // LMEM mux: drive shared slave inputs from selected master
  assign lmem_bus_ifs[0].req_valid = sel ? lmem1_bus_m.req_valid : lmem0_bus_m.req_valid;
  assign lmem_bus_ifs[0].req_data  = sel ? lmem1_bus_m.req_data  : lmem0_bus_m.req_data;
  assign lmem_bus_ifs[0].rsp_ready = sel ? lmem1_bus_m.rsp_ready : lmem0_bus_m.rsp_ready;

  // return slave outputs to the selected master; deassert to unselected
  assign lmem0_bus_m.req_ready = sel ? 1'b0 : lmem_bus_ifs[0].req_ready;
  assign lmem1_bus_m.req_ready = sel ? lmem_bus_ifs[0].req_ready : 1'b0;
  assign lmem0_bus_m.rsp_valid = sel ? 1'b0 : lmem_bus_ifs[0].rsp_valid;
  assign lmem1_bus_m.rsp_valid = sel ? lmem_bus_ifs[0].rsp_valid : 1'b0;

  assign lmem0_bus_m.rsp_data  = lmem_bus_ifs[0].rsp_data;
  assign lmem1_bus_m.rsp_data  = lmem_bus_ifs[0].rsp_data;
  // GEMM mux
  assign gemm_bus_s.req_valid = sel ? gemm1_bus_m.req_valid : gemm0_bus_m.req_valid;
  assign gemm_bus_s.req_data  = sel ? gemm1_bus_m.req_data  : gemm0_bus_m.req_data;
  assign gemm_bus_s.rsp_ready = sel ? gemm1_bus_m.rsp_ready : gemm0_bus_m.rsp_ready;

  assign gemm0_bus_m.req_ready = sel ? 1'b0 : gemm_bus_s.req_ready;
  assign gemm1_bus_m.req_ready = sel ? gemm_bus_s.req_ready : 1'b0;

  assign gemm0_bus_m.rsp_valid = sel ? 1'b0 : gemm_bus_s.rsp_valid;
  assign gemm1_bus_m.rsp_valid = sel ? gemm_bus_s.rsp_valid : 1'b0;

  assign gemm0_bus_m.rsp_data  = gemm_bus_s.rsp_data;
  assign gemm1_bus_m.rsp_data  = gemm_bus_s.rsp_data;

  // -----------------------------
  // VX_local_mem instance (LMEM slave)
  // -----------------------------

  localparam int NUM_WORDS = MEM_BYTES / DATA_SIZE_BYTES;

  VX_local_mem #(
    .INSTANCE_ID ("lmem0"),
    .SIZE        (MEM_BYTES),
    .NUM_REQS    (NUM_REQS),
    .NUM_BANKS   (NUM_BANKS),
    .ADDR_WIDTH  (`CLOG2(NUM_WORDS)),
    .WORD_SIZE   (DATA_SIZE_BYTES),
    .TAG_WIDTH   (TAG_WIDTH),
    .OUT_BUF     (0)
  ) u_lmem (
    .clk       (clk),
    .reset     (reset),
`ifdef PERF_ENABLE
    .lmem_perf (),
`endif
    .mem_bus_if(lmem_bus_ifs)
  );

  // -----------------------------
  // GEMM node memory model (byte-addressed) + bus slave (1-cycle latency)
  // -----------------------------
  byte gemm_mem [0:MEM_BYTES-1];

  typedef struct packed {
      logic [`UP(UUID_WIDTH)-1:0]   uuid;
      logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0] value;
  } tag_t;

  typedef struct packed {
    logic                            valid;
    logic                            rw;
    logic [gemm_bus_s.ADDR_WIDTH-1:0] addr_beats;
    logic [DATA_SIZE_BYTES*8-1:0]     data;
    logic [DATA_SIZE_BYTES-1:0]       byteen;
    tag_t                            tag;
  } pend_t;

  pend_t g_pend;

  always @(posedge clk) begin
    if (reset) begin
      gemm_bus_s.req_ready <= 1'b1;
      gemm_bus_s.rsp_valid <= 1'b0;
      gemm_bus_s.rsp_data  <= '0;
      g_pend.valid         <= 1'b0;
    end else begin
      // always ready
      gemm_bus_s.req_ready <= 1'b1;

      // clear response when accepted
      if (gemm_bus_s.rsp_valid && gemm_bus_s.rsp_ready)
        gemm_bus_s.rsp_valid <= 1'b0;

      // capture request into pending (1-cycle latency)
      g_pend.valid <= 1'b0;
      if (gemm_bus_s.req_valid && gemm_bus_s.req_ready) begin
        g_pend.valid      <= 1'b1;
        g_pend.rw         <= gemm_bus_s.req_data.rw;
        g_pend.addr_beats <= gemm_bus_s.req_data.addr;
        g_pend.data       <= gemm_bus_s.req_data.data;
        g_pend.byteen     <= gemm_bus_s.req_data.byteen;
        g_pend.tag        <= gemm_bus_s.req_data.tag;
      end

      // execute pending
      if (g_pend.valid) begin
        int unsigned base_b;
        base_b = (g_pend.addr_beats << $clog2(DATA_SIZE_BYTES));

        gemm_bus_s.rsp_valid    <= 1'b1;
        gemm_bus_s.rsp_data.tag <= g_pend.tag;

        if (!g_pend.rw) begin
          // READ
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              gemm_bus_s.rsp_data.data[i*8 +: 8] <= gemm_mem[base_b + i];
            else
              gemm_bus_s.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          // WRITE (respect byteen)
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (g_pend.byteen[i] && (base_b + i < MEM_BYTES))
              gemm_mem[base_b + i] <= g_pend.data[i*8 +: 8];
          end
          gemm_bus_s.rsp_data.data <= '0;
        end
      end
    end
  end

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
    $dumpvars(0, tb_VX_lmem_dma_misal);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // -----------------------------
  // GEMM utilities (byte-addressed)
  // -----------------------------
  task automatic gemm_clear();
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      gemm_mem[i] = 8'h00;
    end
  endtask

  task automatic gemm_fill_inc(input int unsigned base, input int unsigned nbytes, input byte start);
    byte v; v = start;
    for (int unsigned i = 0; i < nbytes; i++) begin
      if (base + i < MEM_BYTES) begin
        gemm_mem[base + i] = v;
        v++;
      end
    end
  endtask

  task automatic gemm_clear_range(input int unsigned base, input int unsigned nbytes);
    for (int unsigned i = 0; i < nbytes; i++) begin
      if (base + i < MEM_BYTES) gemm_mem[base + i] = 8'h00;
    end
  endtask

  task automatic gemm_check_equal(
    input int unsigned src_base,
    input int unsigned dst_base,
    input int unsigned nbytes,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((src_base + i) >= MEM_BYTES || (dst_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if (gemm_mem[src_base + i] !== gemm_mem[dst_base + i]) begin
        $fatal(1, "Mismatch %s @+%0d: SRC=%02x DST=%02x",
               msg, i, gemm_mem[src_base + i], gemm_mem[dst_base + i]);
      end
    end
  endtask

  // -----------------------------
  // Start pulse + program ctrl regs
  // NOTE: dst_strides are set equal to src_strides here (like your old TB)
  // -----------------------------
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

  // done detect: idle deassert -> assert
  task automatic wait_dma_done0();
    do @(posedge clk); while (ctrl0_if.idle);
    do @(posedge clk); while (!ctrl0_if.idle);
  endtask

  task automatic wait_dma_done1();
    do @(posedge clk); while (ctrl1_if.idle);
    do @(posedge clk); while (!ctrl1_if.idle);
  endtask

  // wait for sync valid and check payload
  task automatic wait_sync0_and_check(
    input logic [31:0] exp_idx,
    input logic [31:0] exp_val,
    input string msg
  );
    do @(posedge clk); while (!sync0_if.valid);
    if (sync0_if.reg_idx !== exp_idx || sync0_if.value !== exp_val) begin
      $fatal(1, "SYNC0 mismatch %s: idx=%0d/%0d val=%08x/%08x",
             msg, sync0_if.reg_idx, exp_idx, sync0_if.value, exp_val);
    end
  endtask

  task automatic wait_sync1_and_check(
    input logic [31:0] exp_idx,
    input logic [31:0] exp_val,
    input string msg
  );
    do @(posedge clk); while (!sync1_if.valid);
    if (sync1_if.reg_idx !== exp_idx || sync1_if.value !== exp_val) begin
      $fatal(1, "SYNC1 mismatch %s: idx=%0d/%0d val=%08x/%08x",
             msg, sync1_if.reg_idx, exp_idx, sync1_if.value, exp_val);
    end
  endtask

  // -----------------------------
  // Roundtrip test case
  //   1) GEMM(src)->LMEM(tmp)  (DIR=1)
  //   2) LMEM(tmp)->GEMM(dst)  (DIR=0)
  // Verify only GEMM memory: src == dst
  // -----------------------------
  task automatic run_case_roundtrip(
    input int unsigned seg_bytes,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned src_off,   // 0..DATA_SIZE_BYTES-1
    input int unsigned dst_off,   // 0..DATA_SIZE_BYTES-1
    input int unsigned lmem_off   // 0..DATA_SIZE_BYTES-1
  );
    int unsigned total_bytes;
    int unsigned stride0, stride1, stride2;

    int unsigned gemm_src_base, gemm_dst_base;
    int unsigned lmem_base;

    logic [31:0] reg0_idx, reg0_val;
    logic [31:0] reg1_idx, reg1_val;

    total_bytes = b0*b1*b2*seg_bytes;

    stride0 = seg_bytes;
    stride1 = b0 * seg_bytes;
    stride2 = b0 * b1 * seg_bytes;

    gemm_src_base = 16'h3000 + src_off;
    gemm_dst_base = 16'h5000 + dst_off;
    lmem_base     = 16'h1000 + lmem_off;

    reg1_idx = 32'd21; reg1_val = 32'hDEAD_BEEF; // DIR1 sync
    reg0_idx = 32'd13; reg0_val = 32'hCAFE_BABE; // DIR0 sync

    gemm_clear();

    // Fill SRC, clear DST
    gemm_fill_inc(gemm_src_base, total_bytes, 8'h40);
    gemm_clear_range(gemm_dst_base, total_bytes);

    $display("\n[CASE] seg=%0d bnd=(%0d,%0d,%0d) off(s=%0d d=%0d l=%0d) ROUNDTRIP",
             seg_bytes, b0, b1, b2, src_off, dst_off, lmem_off);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) off(s=%0d d=%0d l=%0d) ROUNDTRIP",
              seg_bytes, b0, b1, b2, src_off, dst_off, lmem_off);

    // 1) GEMM -> LMEM  (DIR=1)
    ctrl1_pulse_start(
      gemm_src_base, lmem_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg1_idx, reg1_val
    );
    wait_sync1_and_check(reg1_idx, reg1_val, "DIR1");
    wait_dma_done1();

    // 2) LMEM -> GEMM  (DIR=0)
    ctrl0_pulse_start(
      lmem_base, gemm_dst_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg0_idx, reg0_val
    );
    wait_sync0_and_check(reg0_idx, reg0_val, "DIR0");
    wait_dma_done0();

    // 3) Verify GEMM only
    gemm_check_equal(gemm_src_base, gemm_dst_base, total_bytes, "ROUNDTRIP");

    $display("[CASE] PASS ✅");
    $fdisplay(rpt_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) off(s=%0d d=%0d l=%0d) PASS",
              seg_bytes, b0, b1, b2, src_off, dst_off, lmem_off);
  endtask

  // -----------------------------
  // sim_func / sim_power
  // -----------------------------
  task automatic sim_func();
    int unsigned b0 = 2, b1 = 2, b2 = 2;

    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BUS_BYTES: %0d", DATA_SIZE_BYTES);

    // ctrl defaults
    ctrl0_if.start = 1'b0;
    ctrl1_if.start = 1'b0;

    // Wait stable
    repeat (5) @(posedge clk);

    // aligned baseline
    run_case_roundtrip(DATA_SIZE_BYTES*1, b0,b1,b2, 0,0,0);
    run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 0,0,0);
    run_case_roundtrip(DATA_SIZE_BYTES*4, b0,b1,b2, 0,0,0);

    // misaligned base offsets (src!=dst, and LMEM base offset too)
    run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 1,7,3);
    run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 15,2,11);

    // misaligned seg_bytes too (important)
    run_case_roundtrip(DATA_SIZE_BYTES + 5,   b0,b1,b2, 3,11,1);
    run_case_roundtrip(DATA_SIZE_BYTES*2 + 3, b0,b1,b2, 5,1,9);
    run_case_roundtrip(DATA_SIZE_BYTES*4 - 1, b0,b1,b2, 9,13,7);

    run_case_roundtrip(DATA_SIZE_BYTES - 5,   b0,b1,b2, 3,11,1);
    run_case_roundtrip(DATA_SIZE_BYTES - 1, b0,b1,b2, 5,1,9);
    run_case_roundtrip(DATA_SIZE_BYTES, b0,b1,b2, 9,13,7);

    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
  endtask

  task automatic sim_power();
    int unsigned b0 = 2, b1 = 2, b2 = 2;
    int unsigned seg_choices [0:5];

    seg_choices[0] = DATA_SIZE_BYTES;
    seg_choices[1] = DATA_SIZE_BYTES * 2;
    seg_choices[2] = DATA_SIZE_BYTES * 4;
    seg_choices[3] = DATA_SIZE_BYTES + 5;
    seg_choices[4] = DATA_SIZE_BYTES * 2 + 3;
    seg_choices[5] = DATA_SIZE_BYTES * 4 - 1;

    $display("=====================================================================");
    $display("=======================  START POWER SIM  ===========================");
    $display("=====================================================================");

    ctrl0_if.start = 1'b0;
    ctrl1_if.start = 1'b0;

    for (int iter = 0; iter < 300; iter++) begin
      int unsigned seg_bytes = seg_choices[$urandom_range(0,5)];
      int unsigned so = $urandom_range(0, DATA_SIZE_BYTES-1);
      int unsigned doff = $urandom_range(0, DATA_SIZE_BYTES-1);
      int unsigned lo = $urandom_range(0, DATA_SIZE_BYTES-1);

      run_case_roundtrip(seg_bytes, b0,b1,b2, so, doff, lo);
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

// tb_VX_dma_node.sv
`timescale 1ns / 1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// Testbench for VX_dma_node
// - DCACHE: byte-array slave model (1-cycle latency)
// - LMEM  : real VX_local_mem instance (banked, xbar, ready/valid behavior)
//   - LMEM has 1 port (NUM_REQS=1): driven only by DMA
//   - Therefore TB cannot directly read LMEM; correctness is validated end-to-end:
//       GLOBAL(src) -> LMEM -> GLOBAL(dst), then compare src vs dst (with padding rules)
// - task-based tests
// -----------------------------------------------------------------------------

module tb_VX_dma_mem_unit import VX_gpu_pkg::*; ();

  parameter string tb_name = "tb_VX_dma_mem_unit";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";  // "func" or "power"
  parameter string FILE_POSTFIX = "func";

  // -----------------------------
  // Params
  // -----------------------------
  localparam int CFG_NUM    = `DMA_CFG_REG_NUM;
  localparam int CFG_DW     = 32;

  localparam int MEM_BYTES  = 64*1024;
  localparam int TAG_WIDTH  = 45;  // 일단 `UP(UUID_WIDTH) 보다 크기만 하면 됨
  // Make DCACHE wider than LMEM to test width mismatch
  localparam int DCACHE_BYTES = 32;
  localparam int LMEM_BYTES   = 16; // IMPORTANT: match VX_local_mem word size (usually 8)

  // LMEM instance: 1 port
  localparam int LMEM_PORTS = 1;
  localparam int NUM_REQS   = LMEM_PORTS;
  localparam int NUM_BANKS  = 4;
  
  // segment/padding cases
  localparam int SEG_SIZE_1   = 32;
  localparam int SEG_SIZE_2   = 64;
  localparam int SEG_SIZE_3   = 128;

  // Note: LMEM_BYTES is usually 8, but keep these as your original intent.
  localparam int PADDING_1     = 3;   // padding < LMEM_BYTES (if XLEN=64)
  localparam int PADDING_2     = 8;   // padding == LMEM_BYTES (if XLEN=64)
  localparam int PADDING_3     = 18;  // padding > LMEM_BYTES

  localparam int BIG_PADDING_1 = 15;  // padding < DCACHE_BYTES
  localparam int BIG_PADDING_2 = 32;  // padding == DCACHE_BYTES
  localparam int BIG_PADDING_3 = 75;  // padding > DCACHE_BYTES

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
  // Interfaces
  // -----------------------------
  VX_config_reg_if #(.NUM(CFG_NUM), .DW(CFG_DW)) cfg_reg_if();

  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) dcache_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_ifs [LMEM_PORTS](); // [0]=DMA only

  VX_node_done_if done_if();

  // -----------------------------
  // DUT
  // -----------------------------
  // Aligned-path coverage: the bases (0x1000 / 0x3000) and strides in this
  // testbench are all LMEM_BYTES-aligned, so keep ENABLE_MISALIGN=0 (default)
  // to exercise the simplified datapath.
  VX_dma_unit #(
    .INSTANCE_ID     ("dma0"),
    .ENABLE_MISALIGN (1'b0),
    .DCACHE_TAG_WIDTH(TAG_WIDTH),
    .LMEM_TAG_WIDTH  (TAG_WIDTH)
  ) dut (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (cfg_reg_if),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_ifs[0]),     // DMA uses LMEM port 0
    .done_if      (done_if)
  );

  // -----------------------------
  // Real LMEM (banked) instance
  // NUM_REQS=1, NUM_BANKS=4 as requested
  // -----------------------------
  initial begin
    $display("[LMEM PARAMS] ADDR_WIDTH=%0d BANK_ADDR_WIDTH=%0d NUM_BANKS=%0d CLOG2(NUM_BANKS)=%0d WORD_WIDTH=%0d",
            u_lmem.ADDR_WIDTH,
            u_lmem.BANK_ADDR_WIDTH,
            u_lmem.NUM_BANKS,
            $clog2(u_lmem.NUM_BANKS),
            u_lmem.WORD_WIDTH);
  end

  localparam NUM_WORDS       = MEM_BYTES / LMEM_BYTES;

  VX_local_mem #(
    .INSTANCE_ID ("lmem0"),
    .SIZE        (MEM_BYTES),
    .NUM_REQS    (NUM_REQS),
    .NUM_BANKS   (NUM_BANKS),
    .ADDR_WIDTH  (`CLOG2(NUM_WORDS)),   // ★ 핵심 수정
    .WORD_SIZE   (LMEM_BYTES),
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
  // Files / dump
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
    $dumpvars(0, tb_VX_dma_mem_unit);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // -----------------------------
  // DCACHE memory model (byte-addressed)
  // -----------------------------
  byte dcache_mem [0:MEM_BYTES-1];

  // always ready for DCACHE model
  assign dcache_bus_if.req_ready = 1'b1;
  assign done_if.ready = 1'b1;

  // -----------------------------
  // DCACHE slave: 1-cycle latency, rsp_valid asserted for 1 cycle
  // -----------------------------
  typedef struct packed {
    logic [`UP(UUID_WIDTH)-1:0]        uuid;
    logic [TAG_WIDTH -`UP(UUID_WIDTH)-1:0]      value;
  } dtag_t;

  typedef struct packed {
    logic                                valid;
    logic                                rw;
    logic [dcache_bus_if.ADDR_WIDTH-1:0]  addr_beats;
    logic [DCACHE_BYTES*8-1:0]            data;
    logic [DCACHE_BYTES-1:0]              byteen;
    dtag_t                                tag;
  } d_pend_t;

  d_pend_t d_pend;

  always @(posedge clk) begin
    if (reset) begin
      dcache_bus_if.rsp_valid <= 1'b0;
      dcache_bus_if.rsp_data  <= '0;
      d_pend.valid            <= 1'b0;
    end else begin
      // clear rsp_valid after handshake
      if (dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready)
        dcache_bus_if.rsp_valid <= 1'b0;

      // capture req into pending (one-cycle response)
      d_pend.valid <= 1'b0;
      if (dcache_bus_if.req_valid && dcache_bus_if.req_ready) begin
        d_pend.valid      <= 1'b1;
        d_pend.rw         <= dcache_bus_if.req_data.rw;
        d_pend.addr_beats <= dcache_bus_if.req_data.addr;
        d_pend.data       <= dcache_bus_if.req_data.data;
        d_pend.byteen     <= dcache_bus_if.req_data.byteen;
        d_pend.tag        <= dcache_bus_if.req_data.tag;
      end

      // respond from pending
      if (d_pend.valid) begin
        int unsigned base_b;
        base_b = (d_pend.addr_beats << $clog2(DCACHE_BYTES));

        dcache_bus_if.rsp_valid    <= 1'b1;
        dcache_bus_if.rsp_data.tag <= d_pend.tag;

        if (!d_pend.rw) begin
          // READ
          for (int i = 0; i < DCACHE_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= dcache_mem[base_b + i];
            else
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          // WRITE
          for (int i = 0; i < DCACHE_BYTES; i++) begin
            if (d_pend.byteen[i] && (base_b + i < MEM_BYTES))
              dcache_mem[base_b + i] <= d_pend.data[i*8 +: 8];
          end
          dcache_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end



  // -----------------------------
  // Utilities
  // -----------------------------
  task automatic mem_clear_global();
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      dcache_mem[i] = 8'h00;
    end
  endtask

  task automatic mem_fill_inc_global(input int unsigned base, input int unsigned nbytes, input byte start);
    byte v;
    v = start;
    for (int unsigned i = 0; i < nbytes; i++) begin
      if (base + i < MEM_BYTES) begin
        dcache_mem[base + i] = v;
        v++;
      end
    end
  endtask

  // src vs dst compare in GLOBAL (dcache_mem), with padding rule:
  // - within each segment of seg_size bytes, the last 'padding' bytes must be zero in dst.
  task automatic mem_check_equal_g_to_g_with_padding(
    input int unsigned src_base,
    input int unsigned dst_base,
    input int unsigned nbytes,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((src_base + i) >= MEM_BYTES || (dst_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if ((i % seg_size) >= (seg_size - padding)) begin
        if (dcache_mem[dst_base + i] !== 8'h00) begin
          $fatal(1, "Padding Mismatch %s @+%0d: SRC=%02x DST=%02x",
                 msg, i, dcache_mem[src_base + i], dcache_mem[dst_base + i]);
        end
      end else begin
        if (dcache_mem[src_base + i] !== dcache_mem[dst_base + i]) begin
          $fatal(1, "Mismatch %s @+%0d: SRC=%02x DST=%02x",
                 msg, i, dcache_mem[src_base + i], dcache_mem[dst_base + i]);
        end
      end
    end
  endtask

  // -----------------------------
  // cfg helpers
  // -----------------------------
  task automatic cfg_send_desc(
    input logic [31:0] w [0:CFG_NUM-1],
    input logic [31:0] wid
  );
    cfg_reg_if.entry_id = wid;

    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    for (int i = 0; i < CFG_NUM; i++) begin
      cfg_reg_if.regs[i] = w[i];
    end

    while (!cfg_reg_if.ready) @(posedge clk);
    cfg_reg_if.valid = 1'b1;
    @(posedge clk);
    cfg_reg_if.valid = 1'b0;
  endtask

  task automatic wait_dma_done();
    do @(posedge clk); while (!done_if.valid);
    @(posedge clk);
  endtask

  // -----------------------------
  // Test case runner
  // -----------------------------
  task automatic run_case(
    input int unsigned seg_bytes,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned padding
  );
    int unsigned total_bytes;
    int unsigned stride0, stride1, stride2;
    int unsigned g_src_base, l_mid_base, g_dst_base;

    logic [31:0] d1 [0:CFG_NUM-1];
    logic [31:0] d2 [0:CFG_NUM-1];

    total_bytes = b0*b1*b2*seg_bytes;

    stride0 = seg_bytes;
    stride1 = b0 * seg_bytes;
    stride2 = b0 * b1 * seg_bytes;

    // base addresses (keep aligned-ish)
    g_src_base = 16'h1000;
    l_mid_base = 16'h2000;
    g_dst_base = 16'h3000;

    for (int i = 0; i < CFG_NUM; i++) begin
      d1[i] = '0;
      d2[i] = '0;
    end

    // init global
    mem_clear_global();
    mem_fill_inc_global(g_src_base, total_bytes, 8'h10);
    // clear destination
    for (int unsigned i = 0; i < total_bytes; i++) begin
      if (g_dst_base + i < MEM_BYTES) dcache_mem[g_dst_base + i] = 8'h00;
    end

    $display("\n[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  G->L->G",
             seg_bytes, b0, b1, b2, padding);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  G->L->G",
             seg_bytes, b0, b1, b2, padding);

    // -------------------------
    // GLOBAL -> LMEM
    // -------------------------
    d1[0]  = 32'h0000_0001; // start=1
    d1[1]  = l_mid_base[31:0];
    d1[2]  = 32'(l_mid_base >> 32);
    d1[3]  = g_src_base[31:0];
    d1[4]  = 32'(g_src_base >> 32);
    d1[5]  = stride0; d1[6]  = stride0;
    d1[7]  = stride1; d1[8]  = stride1;
    d1[9]  = stride2; d1[10] = stride2;
    d1[11] = b0;      d1[12] = b1; d1[13] = b2;
    d1[14] = seg_bytes;
    d1[15] = padding;
    d1[16] = 32'd0; // G2L: GLOBAL/DCACHE -> LMEM

    cfg_send_desc(d1, 32'd5);
    wait_dma_done();

    // -------------------------
    // LMEM -> GLOBAL
    // -------------------------
    d2[0]  = 32'h0000_0001; // start=1
    d2[1]  = g_dst_base[31:0];
    d2[2]  = 32'(g_dst_base >> 32);
    d2[3]  = l_mid_base[31:0];
    d2[4]  = 32'(l_mid_base >> 32);
    d2[5]  = stride0; d2[6]  = stride0;
    d2[7]  = stride1; d2[8]  = stride1;
    d2[9]  = stride2; d2[10] = stride2;
    d2[11] = b0;      d2[12] = b1; d2[13] = b2;
    d2[14] = seg_bytes;
    d2[15] = padding;
    d2[16] = 32'd1; // L2G: LMEM -> GLOBAL/DCACHE

    cfg_send_desc(d2, 32'd9);
    wait_dma_done();

    // -------------------------
    // FINAL CHECK: GLOBAL src vs GLOBAL dst
    // -------------------------
    mem_check_equal_g_to_g_with_padding(g_src_base, g_dst_base, total_bytes, seg_bytes, padding, "G->L->G");

    $display("[CASE] PASS ✅");
    $fdisplay(rpt_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d PASS",
              seg_bytes, b0, b1, b2, padding);
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
    $display("LMEM_BYTES:   %0d", LMEM_BYTES);
    $display("DCACHE_BYTES: %0d", DCACHE_BYTES);

    // cfg defaults
    cfg_reg_if.valid = 1'b0;
    cfg_reg_if.entry_id = '0;
    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    repeat (5) @(posedge clk);

    run_case(SEG_SIZE_1, b0, b1, b2, PADDING_1);
    run_case(SEG_SIZE_1, b0, b1, b2, PADDING_2);
    run_case(SEG_SIZE_1, b0, b1, b2, PADDING_3);

    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_1);
    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_2);
    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_3);

    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_1);
    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_2);
    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_3);

    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
  endtask

  task sim_power();
    int unsigned seg_choices [0:2];
    int unsigned b0 = 2;
    int unsigned b1 = 2;
    int unsigned b2 = 2;

    seg_choices[0] = SEG_SIZE_1;
    seg_choices[1] = SEG_SIZE_2;
    seg_choices[2] = SEG_SIZE_3;

    $display("=====================================================================");
    $display("=======================  START POWER SIM  ===========================");
    $display("=====================================================================");

    cfg_reg_if.valid = 1'b0;
    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    mem_clear_global();

    for (int iter = 0; iter < 300; iter++) begin
      int unsigned seg_bytes = seg_choices[$urandom_range(0,2)];
      run_case(seg_bytes, b0, b1, b2, PADDING_1);
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

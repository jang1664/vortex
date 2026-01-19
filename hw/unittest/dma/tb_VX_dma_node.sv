// tb_VX_dma_node.sv
`timescale 1ns / 1ps
`include "VX_define.vh"

// -----------------------------------------------------------------------------
// Testbench for VX_dma_node (VX_gemm_tree TB style-ish):
// - OBJ = "func" / "power"
// - dump fsdb(fst) + logs/reports
// - task-based tests
// -----------------------------------------------------------------------------

module tb_VX_dma_node import VX_gpu_pkg::*; ();

  parameter string tb_name = "tb_VX_dma_node";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";  // "func" or "power"
  parameter string FILE_POSTFIX = "func";

  // -----------------------------
  // Params
  // -----------------------------
  localparam int CFG_NUM    = 7;
  localparam int CFG_DW     = 64;
  localparam int DESC_WORDS = 14;

  localparam int MEM_BYTES  = 64*1024;

  // Handy locals that match the interface widths
  localparam int DCACHE_BYTES = 32;
  localparam int LMEM_BYTES   = 16;

  localparam int SEG_SIZE_1   = 32;
  localparam int SEG_SIZE_2   = 64;
  localparam int SEG_SIZE_3   = 128;
  localparam int PADDING_1    = 3;   //padding < LMEM_BYTES 인 경우
  localparam int PADDING_2    = 16;  //padding == LMEM_BYTES 인 경우
  localparam int PADDING_3    = 18;  //padding > LMEM_BYTES 인 경우
  
  // SEG_SIZE_3 용 BIG_PADDING
  localparam int BIG_PADDING_1 = 15;  //padding < DCACHE_BYTES 인 경우
  localparam int BIG_PADDING_2 = 32;  //padding == DCACHE_BYTES 인 경우
  localparam int BIG_PADDING_3 = 75;  //padding > DCACHE_BYTES 인 경우
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


  // Make DCACHE bus wider than LMEM bus to test width mismatch
  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES), // DCACHE = 16B/beat
    .TAG_WIDTH(8)
  ) dcache_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_BYTES),   // LMEM = 8B/beat
    .TAG_WIDTH(8)
  ) lmem_bus_if();


  // -----------------------------
  // DUT
  // -----------------------------
  VX_dma_node #(.INSTANCE_ID("dma0")) dut (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (cfg_reg_if),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_if)
  );

  // -----------------------------
  // Files / dump (gemm TB style)
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
    $dumpvars(0, tb_VX_dma_node);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // -----------------------------
  // Memory models (byte-addressed)
  // -----------------------------
  byte dcache_mem [0:MEM_BYTES-1];
  byte lmem_mem   [0:MEM_BYTES-1];

  // always ready
  assign dcache_bus_if.req_ready = 1'b1;
  assign lmem_bus_if.req_ready   = 1'b1;

  typedef struct packed {
      logic [`UP(UUID_WIDTH)-1:0]   uuid;
      logic [8-`UP(UUID_WIDTH)-1:0] value;
  } tag_t;

  // Pending structs MUST match each bus width
  typedef struct packed {
    logic                               valid;
    logic                               rw;
    logic [dcache_bus_if.ADDR_WIDTH-1:0] addr_beats;
    logic [DCACHE_BYTES*8-1:0]          data;
    logic [DCACHE_BYTES-1:0]            byteen;
    tag_t                               tag;
  } d_pend_t;

  typedef struct packed {
    logic                               valid;
    logic                               rw;
    logic [lmem_bus_if.ADDR_WIDTH-1:0]  addr_beats;
    logic [LMEM_BYTES*8-1:0]            data;
    logic [LMEM_BYTES-1:0]              byteen;
    tag_t                               tag;
  } l_pend_t;

  d_pend_t d_pend;
  l_pend_t l_pend;

  // -----------------------------
  // DCACHE slave: 1-cycle latency, rsp_valid asserted for 1 cycle
  // -----------------------------
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
        base_b = (d_pend.addr_beats << $clog2(DCACHE_BYTES)); // IMPORTANT: use DCACHE_BYTES

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
  // LMEM slave: 1-cycle latency, rsp_valid asserted for 1 cycle
  // -----------------------------
  always @(posedge clk) begin
    if (reset) begin
      lmem_bus_if.rsp_valid <= 1'b0;
      lmem_bus_if.rsp_data  <= '0;
      l_pend.valid          <= 1'b0;
    end else begin
      if (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready)
        lmem_bus_if.rsp_valid <= 1'b0;

      l_pend.valid <= 1'b0;
      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready) begin
        l_pend.valid      <= 1'b1;
        l_pend.rw         <= lmem_bus_if.req_data.rw;
        l_pend.addr_beats <= lmem_bus_if.req_data.addr;
        l_pend.data       <= lmem_bus_if.req_data.data;
        l_pend.byteen     <= lmem_bus_if.req_data.byteen;
        l_pend.tag        <= lmem_bus_if.req_data.tag;
      end

      if (l_pend.valid) begin
        int unsigned base_b;
        base_b = (l_pend.addr_beats << $clog2(LMEM_BYTES)); // IMPORTANT: use LMEM_BYTES

        lmem_bus_if.rsp_valid    <= 1'b1;
        lmem_bus_if.rsp_data.tag <= l_pend.tag;

        if (!l_pend.rw) begin
          // READ
          for (int i = 0; i < LMEM_BYTES; i++) begin
            if (base_b + i < MEM_BYTES)
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= lmem_mem[base_b + i];
            else
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          // WRITE
          for (int i = 0; i < LMEM_BYTES; i++) begin
            if (l_pend.byteen[i] && (base_b + i < MEM_BYTES))
              lmem_mem[base_b + i] <= l_pend.data[i*8 +: 8];
          end
          lmem_bus_if.rsp_data.data <= '0;
        end
      end
    end
  end

  // -----------------------------
  // Utilities
  // -----------------------------
  task automatic mem_clear_all();
    for (int unsigned i = 0; i < MEM_BYTES; i++) begin
      dcache_mem[i] = 8'h00;
      lmem_mem[i]   = 8'h00;
    end
  endtask

  // fill global from base, incrementing bytes
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

  task automatic mem_check_equal_g_to_l(
    input int unsigned g_base,
    input int unsigned l_base,
    input int unsigned nbytes,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((g_base + i) >= MEM_BYTES || (l_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if (i % seg_size >= seg_size - padding) begin
        if (lmem_mem[l_base + i] !== 8'h00) begin
          $fatal(1, "Padding Mismatch %s @+%0d: G=%02x L=%02x",
               msg, i, dcache_mem[g_base + i], lmem_mem[l_base + i]);
        end
      end
      else if (dcache_mem[g_base + i] !== lmem_mem[l_base + i]) begin
        $fatal(1, "Mismatch %s @+%0d: G=%02x L=%02x",
               msg, i, dcache_mem[g_base + i], lmem_mem[l_base + i]);
      end
    end
  endtask

  task automatic mem_check_equal_l_to_g(
    input int unsigned l_base,
    input int unsigned g_base,
    input int unsigned nbytes,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    for (int unsigned i = 0; i < nbytes; i++) begin
      if ((g_base + i) >= MEM_BYTES || (l_base + i) >= MEM_BYTES)
        $fatal(1, "OOR %s i=%0d", msg, i);

      if (i % seg_size >= seg_size - padding) begin
        if (dcache_mem[g_base + i] !== 8'h00) begin
          $fatal(1, "Padding Mismatch %s @+%0d: L=%02x G=%02x",
               msg, i, lmem_mem[l_base + i], dcache_mem[g_base + i]);
        end
      end
      else if (lmem_mem[l_base + i] !== dcache_mem[g_base + i]) begin
        $fatal(1, "Mismatch %s @+%0d: L=%02x G=%02x",
               msg, i, lmem_mem[l_base + i], dcache_mem[g_base + i]);
      end
    end
  endtask

  // pack 14x32 words into 7x64 regs and pulse valid until accepted
  task automatic cfg_send_desc(
    input logic [31:0] w [0:DESC_WORDS-1],
    input logic [31:0] wid,
    input logic [31:0] tid
  );
    cfg_reg_if.wid = wid;
    cfg_reg_if.tid = tid;

    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    for (int i = 0; i < DESC_WORDS; i++) begin
      int r = i / 2;
      if ((i % 2) == 0) cfg_reg_if.regs[r][31:0]  = w[i];
      else              cfg_reg_if.regs[r][63:32] = w[i];
    end

    cfg_reg_if.valid = 1'b1;
    // wait accept (ready only high in S_IDLE)
    do @(posedge clk); while (!cfg_reg_if.ready);
    @(posedge clk);
    cfg_reg_if.valid = 1'b0;
  endtask

  // done detect: ready deassert -> assert
  task automatic wait_dma_done();
    do @(posedge clk); while (cfg_reg_if.ready);   // left IDLE
    do @(posedge clk); while (!cfg_reg_if.ready);  // back to IDLE
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
    int unsigned g_src_base, l_dst_base, g_dst_base;


    logic [31:0] d1 [0:DESC_WORDS-1];
    logic [31:0] d2 [0:DESC_WORDS-1];

    total_bytes = b0*b1*b2*seg_bytes;

    stride0 = seg_bytes;
    stride1 = b0 * seg_bytes;
    stride2 = b0 * b1 * seg_bytes;

    // base addresses
    g_src_base = 16'h1020;
    l_dst_base = 16'h2010;
    g_dst_base = 16'h3020;

    mem_clear_all();
    mem_fill_inc_global(g_src_base, total_bytes, 8'h10);

    $display("[DEBUG] g_src_base=0x%h, l_dst_base=0x%h, g_dst_base=0x%h", 
             g_src_base, l_dst_base, g_dst_base);
    $display("[DEBUG] total_bytes=%0d, seg_bytes=%0d", total_bytes, seg_bytes);
    
    // -------------------------
    // GLOBAL -> LMEM
    // -------------------------
    d1[0]  = 32'h0000_0003; // start=1, dir=1 (GLOBAL->LMEM)
    d1[1]  = g_src_base;
    d1[2]  = l_dst_base;
    d1[3]  = stride0; d1[4]  = stride0;
    d1[5]  = stride1; d1[6]  = stride1;
    d1[7]  = stride2; d1[8]  = stride2;
    d1[9]  = b0;      d1[10] = b1; d1[11] = b2;
    d1[12] = seg_bytes;
    d1[13] = padding;

    $display("\n[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  GLOBAL->LMEM", seg_bytes, b0, b1, b2, padding);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  G->L", seg_bytes, b0, b1, b2, padding);

    cfg_send_desc(d1, 32'd5, 32'd7);
    wait_dma_done();
    mem_check_equal_g_to_l(g_src_base, l_dst_base, total_bytes, seg_bytes, padding, "G->L");

    // -------------------------
    // LMEM -> GLOBAL
    // -------------------------
    for (int unsigned i = 0; i < total_bytes; i++) begin
      if (g_dst_base + i < MEM_BYTES) dcache_mem[g_dst_base + i] = 8'h00;
    end

    d2[0]  = 32'h0000_0001; // start=1, dir=0 (LMEM->GLOBAL)
    d2[1]  = l_dst_base;
    d2[2]  = g_dst_base;
    d2[3]  = stride0; d2[4]  = stride0;
    d2[5]  = stride1; d2[6]  = stride1;
    d2[7]  = stride2; d2[8]  = stride2;
    d2[9]  = b0;      d2[10] = b1; d2[11] = b2;
    d2[12] = seg_bytes;
    d2[13] = padding;

    $display("[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  LMEM->GLOBAL", seg_bytes, b0, b1, b2, padding);
    $fdisplay(log_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) padding=%0d  L->G", seg_bytes, b0, b1, b2, padding);

    cfg_send_desc(d2, 32'd9, 32'd11);
    wait_dma_done();
    mem_check_equal_l_to_g(l_dst_base, g_dst_base, total_bytes, seg_bytes, padding, "L->G");

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
    $display("LMEM_BYTES: %0d", LMEM_BYTES);
    $display("DCACHE_BYTES: %0d", DCACHE_BYTES);

    // cfg defaults
    cfg_reg_if.valid = 1'b0;
    cfg_reg_if.wid   = '0;
    cfg_reg_if.tid   = '0;
    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    repeat (5) @(posedge clk);

    // seg_size sweep (based on LMEM beat bytes in this TB)
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

    mem_clear_all();

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

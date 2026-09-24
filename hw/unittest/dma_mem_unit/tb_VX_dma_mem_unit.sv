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
  parameter int    DCACHE_BYTES_P = 32;
  parameter int    LMEM_BYTES_P   = 16;
  parameter int    MAX_DIMS_P     = 3;
  parameter bit    DIMS_ONLY_P    = 1'b0;

  // -----------------------------
  // Params
  // -----------------------------
  localparam int CFG_NUM    = `DMA_CFG_REG_NUM;
  localparam int CFG_DW     = 32;
  localparam int DESC_WORDS = `DMA_CFG_REG_NUM;

  localparam int MEM_BYTES  = 64*1024;
  localparam int TAG_WIDTH  = 45;  // 일단 `UP(UUID_WIDTH) 보다 크기만 하면 됨
  localparam int DCACHE_BYTES = DCACHE_BYTES_P;
  localparam int LMEM_BYTES   = LMEM_BYTES_P;
  localparam int MAX_BUS_BYTES = (DCACHE_BYTES > LMEM_BYTES)
                               ? DCACHE_BYTES : LMEM_BYTES;

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
  VX_node_done_if done_if();
  VX_dma_lookahead_if dma_lookahead_if();

  logic dma_prepare_valid_s;
  logic dma_prepare_id_s;
  logic [1:0][31:0] dma_prepare_src_stride_s;
  logic [1:0][31:0] dma_prepare_dst_stride_s;
  logic [1:0][`DMA_BOUND_WIDTH-1:0] dma_prepare_bound_s;
  logic dma_activate_s;
  logic dma_activate_id_s;
  logic dma_done_ready_s;

  assign dma_lookahead_if.prepare_valid = dma_prepare_valid_s;
  assign dma_lookahead_if.prepare_id = dma_prepare_id_s;
  assign dma_lookahead_if.src_stride = dma_prepare_src_stride_s;
  assign dma_lookahead_if.dst_stride = dma_prepare_dst_stride_s;
  assign dma_lookahead_if.bound = dma_prepare_bound_s;
  assign dma_lookahead_if.activate = dma_activate_s;
  assign dma_lookahead_if.activate_id = dma_activate_id_s;
  assign dma_lookahead_if.data_release = 1'b1;
  assign dma_lookahead_if.data_max_beats = '0;

  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) dcache_bus_if();

  VX_mem_bus_if #(
    .DATA_SIZE(LMEM_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_ifs [LMEM_PORTS](); // [0]=DMA only

  // -----------------------------
  // DUT
  // -----------------------------
  // Aligned-path coverage: the bases (0x1000 / 0x3000) and strides in this
  // testbench are all LMEM_BYTES-aligned, so keep ENABLE_MISALIGN=0 (default)
  // to exercise the simplified datapath.
  VX_dma_unit_align #(
    .INSTANCE_ID      ("dma0"),
    .DCACHE_ADDR_WIDTH(`MEM_ADDR_WIDTH - `CLOG2(DCACHE_BYTES)),
    .LMEM_ADDR_WIDTH  (`MEM_ADDR_WIDTH - `CLOG2(LMEM_BYTES)),
    .DCACHE_TAG_WIDTH (TAG_WIDTH),
    .LMEM_TAG_WIDTH   (TAG_WIDTH),
    .MAX_DIMS         (MAX_DIMS_P)
  ) dut (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (cfg_reg_if),
    .lookahead_if (dma_lookahead_if),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_ifs[0]),
    .done_if      (done_if)
  );

  assign done_if.ready = dma_done_ready_s;

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

  logic [2:0] dcache_ready_phase;
  logic dcache_req_stalled;
  logic [$bits(dcache_bus_if.req_data)-1:0] dcache_req_hold;
  int unsigned dcache_rd_stall_cycles;
  int unsigned dcache_wr_stall_cycles;

  // Two ready cycles followed by three blocked cycles. This fills the
  // request buffer and exercises its registered backpressure boundary.
  assign dcache_bus_if.req_ready = (dcache_ready_phase < 3'd2);

  always @(posedge clk) begin
    if (reset) begin
      dcache_ready_phase <= '0;
      dcache_req_stalled <= 1'b0;
      dcache_req_hold <= '0;
      dcache_rd_stall_cycles <= 0;
      dcache_wr_stall_cycles <= 0;
    end else begin
      dcache_ready_phase <= (dcache_ready_phase == 3'd4)
                          ? 3'd0 : dcache_ready_phase + 3'd1;

      if (dcache_bus_if.req_valid && !dcache_bus_if.req_ready) begin
        if (dcache_req_stalled && (dcache_bus_if.req_data !== dcache_req_hold))
          $fatal(1, "DCACHE request payload changed while stalled");
        dcache_req_stalled <= 1'b1;
        dcache_req_hold <= dcache_bus_if.req_data;
        if (dcache_bus_if.req_data.rw)
          dcache_wr_stall_cycles <= dcache_wr_stall_cycles + 1;
        else
          dcache_rd_stall_cycles <= dcache_rd_stall_cycles + 1;
      end else begin
        dcache_req_stalled <= 1'b0;
      end

      if (done_if.valid) begin
        if (dut.dcache_req_buf_pending_r != 0)
          $fatal(1, "DMA completed with %0d buffered DCACHE requests", dut.dcache_req_buf_pending_r);
        if (dcache_bus_if.req_valid)
          $fatal(1, "DMA completed while a DCACHE request was still valid");
      end
    end
  end

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
    input logic [31:0] w [0:DESC_WORDS-1],
    input logic [31:0] entry_id
  );
    cfg_reg_if.entry_id = entry_id;

    for (int r = 0; r < CFG_NUM; r++) cfg_reg_if.regs[r] = '0;

    for (int i = 0; i < DESC_WORDS; i++)
      cfg_reg_if.regs[i] = w[i];

    cfg_reg_if.valid = 1'b1;
    // wait accept (ready only high in S_IDLE)
    do @(posedge clk); while (!cfg_reg_if.ready);
    @(posedge clk);
    cfg_reg_if.valid = 1'b0;
  endtask

  // Observe and consume DONE explicitly; ready is also high in S_DONE to
  // support prepared-command chaining, so it no longer identifies IDLE alone.
  task automatic wait_dma_done();
    do @(posedge clk); while (cfg_reg_if.ready);   // left IDLE
    do @(posedge clk); while (!done_if.valid);     // completion is visible
    @(posedge clk);                                // consume DONE handshake
    do @(posedge clk); while (!cfg_reg_if.ready);  // back to IDLE
  endtask

  task automatic prepare_phase5_slot(input logic prep_id);
    int wait_cycles;
    begin
      @(negedge clk);
      dma_prepare_id_s = prep_id;
      dma_prepare_src_stride_s[0] = 32'd32;
      dma_prepare_dst_stride_s[0] = 32'd16;
      dma_prepare_src_stride_s[1] = 32'd64;
      dma_prepare_dst_stride_s[1] = 32'd32;
      dma_prepare_bound_s[0] = 32'd2;
      dma_prepare_bound_s[1] = 32'd2;
      dma_prepare_valid_s = 1'b1;
      do @(posedge clk); while (!dma_lookahead_if.prepare_ready);
      @(negedge clk);
      dma_prepare_valid_s = 1'b0;

      wait_cycles = 0;
      while ((dma_lookahead_if.result_ready != 2'b11)
          && (wait_cycles < 20)) begin
        @(posedge clk);
        wait_cycles++;
      end
      if (dma_lookahead_if.result_ready != 2'b11)
        $fatal(1, "phase5 prep_id %0d result timeout", prep_id);
    end
  endtask

  task automatic activate_phase5_slot(input logic prep_id,
                                      input logic [31:0] entry_id);
    logic [31:0] d [0:CFG_NUM-1];
    begin
      for (int r = 0; r < CFG_NUM; ++r)
        d[r] = '0;
      d[0]  = 32'd1;
      d[1]  = 32'h0000_2000;
      d[3]  = 32'h0000_1000;
      d[5]  = 32'd32;
      d[6]  = 32'd16;
      d[7]  = 32'd64;
      d[8]  = 32'd32;
      d[11] = 32'd2;
      d[12] = 32'd2;
      d[13] = 32'd1;
      d[14] = 32'd16;
      d[15] = 32'd0;
      d[16] = 32'd0;

      @(negedge clk);
      cfg_reg_if.entry_id = entry_id;
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      dma_activate_id_s = prep_id;
      dma_activate_s = 1'b1;
      cfg_reg_if.valid = 1'b1;
      #1;
      if (!cfg_reg_if.ready || !dut.activate_cache_hit)
        $fatal(1, "phase5 prep_id %0d did not produce a cache hit", prep_id);
      @(posedge clk);
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      dma_activate_s = 1'b0;
      wait_dma_done();
      if (dut.prep_owner_valid_r[prep_id])
        $fatal(1, "phase5 prep_id %0d was not retired", prep_id);
    end
  endtask

  task automatic run_phase5_cache_smoke();
    begin
      prepare_phase5_slot(1'b0);
      prepare_phase5_slot(1'b1);
      activate_phase5_slot(1'b1, 32'h51);
      activate_phase5_slot(1'b0, 32'h50);
      $display("DMA_PHASE5_CACHE_PASS slots=2 slot1_before_slot0=1 tagged=1 cache_hit=2 retired=2");
    end
  endtask

  task automatic run_phase6_chain_smoke();
    logic [31:0] d [0:CFG_NUM-1];
    logic [31:0] old_entry;
    int wait_cycles;
    begin
      for (int r = 0; r < CFG_NUM; ++r)
        d[r] = '0;
      d[0]  = 32'd1;
      d[1]  = 32'h0000_2400;
      d[3]  = 32'h0000_1400;
      d[5]  = 32'd32;
      d[6]  = 32'd16;
      d[7]  = 32'd64;
      d[8]  = 32'd32;
      d[11] = 32'd2;
      d[12] = 32'd2;
      d[13] = 32'd4;
      d[14] = 32'd16;
      d[15] = 32'd0;
      d[16] = 32'd0;

      // Hold the old completion so the next descriptor can be prepared while
      // the transfer is active and then presented before S_DONE.
      dma_done_ready_s = 1'b0;
      cfg_send_desc(d, 32'h0000_00a0);
      if (cfg_reg_if.ready || done_if.valid)
        $fatal(1, "phase6 PREPARE did not overlap an active descriptor");
      prepare_phase5_slot(1'b0);

      @(negedge clk);
      cfg_reg_if.entry_id = 32'h0000_00b0;
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      dma_activate_id_s = 1'b0;
      dma_activate_s = 1'b1;
      cfg_reg_if.valid = 1'b1;

      wait_cycles = 0;
      while (!done_if.valid && (wait_cycles < 200)) begin
        @(posedge clk);
        wait_cycles++;
      end
      if (!done_if.valid)
        $fatal(1, "phase6 old completion timeout");
      old_entry = done_if.entry_id;
      if (old_entry != 32'h0000_00a0 || cfg_reg_if.ready)
        $fatal(1, "phase6 old completion visibility/readiness mismatch");

      @(negedge clk);
      dma_done_ready_s = 1'b1;
      #1;
      if (!done_if.valid || !cfg_reg_if.ready || !dut.activate_cache_hit)
        $fatal(1, "phase6 completion and prepared ACTIVATE did not pair");
      @(posedge clk);
      #1;
      if (done_if.valid || !dut.dcache_req_valid_w)
        $fatal(1, "phase6 next internal request was not asserted after ACTIVATE");
      @(posedge clk);
      #1;
      if (!dcache_bus_if.req_valid)
        $fatal(1, "phase6 buffered request did not reach the memory interface");
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      dma_activate_s = 1'b0;
      wait_dma_done();
      if (dut.prep_owner_valid_r[0])
        $fatal(1, "phase6 chained cache owner was not retired");
      $display("DMA_PHASE6_CHAIN_PASS completion_to_activate=0 activate_to_first_request=1 cache=hit id=0 old_entry=0x%0h new_entry=0x%0h",
               old_entry, 32'h0000_00b0);

      // An ACTIVATE without a prepared owner remains legal through the Phase-1
      // overlap path and must never consume stale slot contents.
      @(negedge clk);
      cfg_reg_if.entry_id = 32'h0000_00c0;
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      dma_activate_id_s = 1'b1;
      dma_activate_s = 1'b1;
      cfg_reg_if.valid = 1'b1;
      #1;
      if (!cfg_reg_if.ready || dut.activate_cache_hit)
        $fatal(1, "phase6 unprepared ACTIVATE did not select cache miss path");
      @(posedge clk);
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      dma_activate_s = 1'b0;
      wait_dma_done();
      $display("DMA_PHASE6_CACHE_MISS_PASS cache=miss id=1 phase1_overlap=1 stale_result_use=0");
    end
  endtask

  task automatic run_phase7_rollover_case(
    input bit direction_l2g,
    input bit carry_d1_to_d2
  );
    logic [31:0] d [0:CFG_NUM-1];
    logic [3:0] expected_needed;
    int rd_set_count;
    int wr_set_count;
    int rd_release_count;
    int wr_release_count;
    int wait_cycles;
    begin
      for (int r = 0; r < CFG_NUM; ++r)
        d[r] = '0;
      d[0] = 32'd1;
      d[1] = direction_l2g ? 32'h0000_3800 : 32'h0000_1800;
      d[3] = direction_l2g ? 32'h0000_1800 : 32'h0000_1000;
      d[5] = 32'd32; d[6] = direction_l2g ? 32'd32 : 32'd16;
      d[7] = 32'd64; d[8] = 32'd32;
      d[9] = 32'd128; d[10] = 32'd64;
      d[11] = carry_d1_to_d2 ? 32'd1 : 32'd2;
      d[12] = 32'd2;
      d[13] = carry_d1_to_d2 ? 32'd2 : 32'd1;
      d[14] = 32'd16;
      d[16] = direction_l2g;
      expected_needed = carry_d1_to_d2 ? 4'b1100 : 4'b0011;

      @(negedge clk);
      cfg_reg_if.entry_id = {30'd0, carry_d1_to_d2, direction_l2g};
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      cfg_reg_if.valid = 1'b1;
      @(posedge clk);
      if (carry_d1_to_d2)
        force dut.precalc_ready_now = 4'b0011;
      else
        force dut.precalc_ready_now = 4'b1100;
      #1;
      if (dut.precalc_needed_r !== expected_needed)
        $fatal(1, "phase7 dependency mask mismatch dir=%0d d1d2=%0d got=%b exp=%b",
               direction_l2g, carry_d1_to_d2,
               dut.precalc_needed_r, expected_needed);
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;

      rd_set_count = 0;
      wr_set_count = 0;
      rd_release_count = 0;
      wr_release_count = 0;
      wait_cycles = 0;
      while (((rd_set_count == 0) || (wr_set_count == 0))
          && (wait_cycles < 300)) begin
        @(posedge clk);
        if (dut.rd_rollover_set) rd_set_count++;
        if (dut.wr_rollover_set) wr_set_count++;
        if (dut.rd_rollover_release) rd_release_count++;
        if (dut.wr_rollover_release) wr_release_count++;
        wait_cycles++;
      end
      if ((rd_set_count != 1) || (wr_set_count != 1)) begin
        release dut.precalc_ready_now;
        $fatal(1, "phase7 pending rollover not independently observed dir=%0d d1d2=%0d rd=%0d wr=%0d",
               direction_l2g, carry_d1_to_d2,
               rd_set_count, wr_set_count);
      end
      release dut.precalc_ready_now;

      wait_cycles = 0;
      while (!cfg_reg_if.ready && (wait_cycles < 500)) begin
        @(posedge clk);
        if (dut.rd_rollover_set) rd_set_count++;
        if (dut.wr_rollover_set) wr_set_count++;
        if (dut.rd_rollover_release) rd_release_count++;
        if (dut.wr_rollover_release) wr_release_count++;
        wait_cycles++;
      end
      if (!cfg_reg_if.ready)
        $fatal(1, "phase7 rollover descriptor timeout");
      if ((rd_set_count != 1) || (wr_set_count != 1)
       || (rd_release_count != 1) || (wr_release_count != 1))
        $fatal(1, "phase7 rollover exactly-once mismatch dir=%0d d1d2=%0d set=%0d/%0d release=%0d/%0d",
               direction_l2g, carry_d1_to_d2, rd_set_count, wr_set_count,
               rd_release_count, wr_release_count);
    end
  endtask

  task automatic run_phase7_known_zero_cases();
    logic [31:0] d [0:CFG_NUM-1];
    begin
      for (int dir = 0; dir < 2; ++dir) begin
        for (int r = 0; r < CFG_NUM; ++r)
          d[r] = '0;
        d[0] = 32'd1;
        d[1] = dir ? 32'h0000_3c00 : 32'h0000_1c00;
        d[3] = dir ? 32'h0000_1c00 : 32'h0000_1000;
        d[5] = 32'd32; d[6] = dir ? 32'd32 : 32'd16;
        d[11] = 32'd4; d[12] = 32'd1; d[13] = 32'd1;
        d[14] = 32'd16; d[16] = 32'(dir);
        @(negedge clk);
        cfg_reg_if.entry_id = 32'h700 + dir;
        for (int r = 0; r < CFG_NUM; ++r)
          cfg_reg_if.regs[r] = d[r];
        cfg_reg_if.valid = 1'b1;
        @(posedge clk);
        #1;
        if (dut.precalc_needed_r != 4'b0000)
          $fatal(1, "phase7 pure-1D unexpectedly depended on corrections dir=%0d mask=%b",
                 dir, dut.precalc_needed_r);
        @(negedge clk);
        cfg_reg_if.valid = 1'b0;
        wait_dma_done();
      end

      // A consumed D0 with a zero source stride must suppress only that
      // product; the destination correction remains required.
      for (int r = 0; r < CFG_NUM; ++r)
        d[r] = '0;
      d[0] = 32'd1; d[1] = 32'h0000_2000; d[3] = 32'h0000_1000;
      d[5] = 32'd0; d[6] = 32'd16;
      d[11] = 32'd2; d[12] = 32'd2; d[13] = 32'd1;
      d[14] = 32'd16;
      @(negedge clk);
      cfg_reg_if.entry_id = 32'h702;
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      cfg_reg_if.valid = 1'b1;
      @(posedge clk);
      #1;
      if (dut.precalc_needed_r !== 4'b0010)
        $fatal(1, "phase7 zero-stride mask mismatch got=%b exp=0010",
               dut.precalc_needed_r);
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      wait_dma_done();
      $display("DMA_PHASE7_KNOWN_ZERO_PASS pure_1d=2 bound_one=1 zero_stride=1 correction_dependency=0");
    end
  endtask

  task automatic run_phase7_prepare_isolation();
    logic [31:0] d [0:CFG_NUM-1];
    logic [31:0] active_entry;
    logic [CFG_NUM-1:0][31:0] active_regs;
    int wait_cycles;
    begin
      for (int r = 0; r < CFG_NUM; ++r)
        d[r] = '0;
      d[0] = 32'd1; d[1] = 32'h0000_2800; d[3] = 32'h0000_1000;
      d[5] = 32'd32; d[6] = 32'd16; d[7] = 32'd64; d[8] = 32'd32;
      d[11] = 32'd2; d[12] = 32'd2; d[13] = 32'd2; d[14] = 32'd16;

      dma_done_ready_s = 1'b0;
      cfg_send_desc(d, 32'h710);
      active_entry = dut.entry_id_latched;
      active_regs = dut.regs_latched;

      @(negedge clk);
      dma_prepare_id_s = 1'b1;
      dma_prepare_src_stride_s[0] = 32'd32;
      dma_prepare_dst_stride_s[0] = 32'd16;
      dma_prepare_src_stride_s[1] = 32'd64;
      dma_prepare_dst_stride_s[1] = 32'd32;
      dma_prepare_bound_s[0] = 32'd2;
      dma_prepare_bound_s[1] = 32'd2;
      dma_prepare_valid_s = 1'b1;
      do @(posedge clk); while (!dma_lookahead_if.prepare_ready);
      #1;
      if (dut.cfg_fire || dut.entry_id_latched != active_entry
       || dut.regs_latched !== active_regs)
        $fatal(1, "phase7 PREPARE changed active descriptor/bookkeeping");
      if (dma_lookahead_if.prepare_ready)
        $fatal(1, "phase7 prep_id reused on acceptance edge");

      // Mutate every live operand after acceptance.  The slot result must use
      // its captured snapshot, not these bus values.
      @(negedge clk);
      dma_prepare_src_stride_s = '{32'd320, 32'd640};
      dma_prepare_dst_stride_s = '{32'd160, 32'd320};
      dma_prepare_bound_s = '{32'd3, 32'd3};
      wait_cycles = 0;
      while ((dma_lookahead_if.result_ready != 2'b11)
          && (wait_cycles < 30)) begin
        @(posedge clk);
        if (dma_lookahead_if.prepare_ready)
          $fatal(1, "phase7 prep_id released before late results arrived");
        wait_cycles++;
      end
      if (dma_lookahead_if.result_ready != 2'b11)
        $fatal(1, "phase7 snapshot result timeout");
      #1;
      if ((dut.prep_result_r[1][0] != 64'd32)
       || (dut.prep_result_r[1][1] != 64'd16)
       || (dut.prep_result_r[1][2] != 64'd64)
       || (dut.prep_result_r[1][3] != 64'd32))
        $fatal(1, "phase7 PREPARE operands were not snapshotted");
      @(negedge clk);
      dma_prepare_valid_s = 1'b0;
      dma_done_ready_s = 1'b1;
      wait_dma_done();

      // Retire slot1 by ACTIVATE and keep a same-ID PREPARE asserted across
      // that edge.  It is not reusable on the retirement edge, but is ready
      // exactly once on the following cycle; deassert before accepting it.
      @(negedge clk);
      cfg_reg_if.entry_id = 32'h711;
      for (int r = 0; r < CFG_NUM; ++r)
        cfg_reg_if.regs[r] = d[r];
      dma_activate_id_s = 1'b1;
      dma_activate_s = 1'b1;
      dma_prepare_id_s = 1'b1;
      dma_prepare_valid_s = 1'b1;
      cfg_reg_if.valid = 1'b1;
      #1;
      if (!cfg_reg_if.ready || !dut.activate_cache_hit
       || dma_lookahead_if.prepare_ready)
        $fatal(1, "phase7 slot reuse/ACTIVATE edge contract mismatch");
      @(posedge clk);
      #1;
      if (!dma_lookahead_if.prepare_ready)
        $fatal(1, "phase7 retired prep_id was not released next cycle");
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      dma_activate_s = 1'b0;
      dma_prepare_valid_s = 1'b0;
      wait_dma_done();
      if (dut.prep_owner_valid_r[1])
        $fatal(1, "phase7 prep_id owner survived retirement");
      $display("DMA_PHASE7_PREPARE_ISOLATION_PASS operand_snapshot=1 cfg_fire=0 active_bookkeeping_change=0 same_cycle_reuse=0 late_stale_write=0 release_next_cycle=1");
    end
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

    logic [31:0] d1 [0:DESC_WORDS-1];
    logic [31:0] d2 [0:DESC_WORDS-1];

    total_bytes = b0*b1*b2*seg_bytes;

    stride0 = seg_bytes;
    stride1 = b0 * seg_bytes;
    stride2 = b0 * b1 * seg_bytes;

    // base addresses (keep aligned-ish)
    g_src_base = 16'h1000;
    l_mid_base = 16'h2000;
    g_dst_base = 16'h3000;

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
    d1 = '{default:'0};
    d1[0]  = 32'h0000_0001;
    d1[1]  = l_mid_base; d1[2] = 32'd0;
    d1[3]  = g_src_base; d1[4] = 32'd0;
    d1[5]  = stride0; d1[6]  = stride0;
    d1[7]  = stride1; d1[8]  = stride1;
    d1[9]  = stride2; d1[10] = stride2;
    d1[11] = b0;      d1[12] = b1; d1[13] = b2;
    d1[14] = seg_bytes;
    d1[15] = padding;
    d1[16] = 32'd0; // GLOBAL -> LMEM

    cfg_send_desc(d1, 32'd7);
    wait_dma_done();

    // -------------------------
    // LMEM -> GLOBAL
    // -------------------------
    d2 = '{default:'0};
    d2[0]  = 32'h0000_0001;
    d2[1]  = g_dst_base; d2[2] = 32'd0;
    d2[3]  = l_mid_base; d2[4] = 32'd0;
    d2[5]  = stride0; d2[6]  = stride0;
    d2[7]  = stride1; d2[8]  = stride1;
    d2[9]  = stride2; d2[10] = stride2;
    d2[11] = b0;      d2[12] = b1; d2[13] = b2;
    d2[14] = seg_bytes;
    d2[15] = padding;
    d2[16] = 32'd1; // LMEM -> GLOBAL

    cfg_send_desc(d2, 32'd11);
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

    run_phase5_cache_smoke();
    run_phase6_chain_smoke();
    run_phase7_known_zero_cases();
    run_phase7_rollover_case(1'b0, 1'b0);
    run_phase7_rollover_case(1'b1, 1'b0);
    run_phase7_rollover_case(1'b0, 1'b1);
    run_phase7_rollover_case(1'b1, 1'b1);
    $display("DMA_PHASE7_ROLLOVER_PASS d0_to_d1=2 d1_to_d2=2 directions=2 rd_wr_independent=1 release_once=1 backpressure=1");
    run_phase7_prepare_isolation();

    if (SEG_SIZE_1 >= MAX_BUS_BYTES) begin
      run_case(SEG_SIZE_1, b0, b1, b2, PADDING_1);
      run_case(SEG_SIZE_1, b0, b1, b2, PADDING_2);
      run_case(SEG_SIZE_1, b0, b1, b2, PADDING_3);
    end

    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_1);
    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_2);
    run_case(SEG_SIZE_2, b0, b1, b2, PADDING_3);

    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_1);
    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_2);
    run_case(SEG_SIZE_3, b0, b1, b2, BIG_PADDING_3);

    if (dcache_rd_stall_cycles == 0 || dcache_wr_stall_cycles == 0)
      $fatal(1, "backpressure coverage missing: read=%0d write=%0d",
             dcache_rd_stall_cycles, dcache_wr_stall_cycles);

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

  task sim_dims();
    int unsigned dim1;
    int unsigned dim2;
    begin
      dim1 = (MAX_DIMS_P >= 2) ? 3 : 1;
      dim2 = 1;
      cfg_reg_if.valid = 1'b0;
      cfg_reg_if.entry_id = '0;
      for (int r = 0; r < CFG_NUM; r++)
        cfg_reg_if.regs[r] = '0;
      repeat (5) @(posedge clk);
      run_case(SEG_SIZE_2, 3, dim1, dim2, 0);
      $display("DMA_DIMS_PASS max_dims=%0d bnd=(3,%0d,%0d)",
               MAX_DIMS_P, dim1, dim2);
    end
  endtask

  // -----------------------------
  // Top-level objective runner
  // -----------------------------
  generate
    localparam string OBJ_ = OBJ;
    initial begin
      dma_prepare_valid_s = 1'b0;
      dma_prepare_id_s = 1'b0;
      dma_prepare_src_stride_s = '0;
      dma_prepare_dst_stride_s = '0;
      dma_prepare_bound_s = '0;
      dma_activate_s = 1'b0;
      dma_activate_id_s = 1'b0;
      dma_done_ready_s = 1'b1;
      @(negedge reset);
      repeat (5) @(posedge clk);

      if (DIMS_ONLY_P) begin
        sim_dims();
      end else if (OBJ_ == "power") begin
        sim_power();
      end else if (OBJ_ == "func") begin
        sim_func();
      end else begin
        $display("please set proper objective of the simulation");
      end
      if ((OBJ_ == "func") || DIMS_ONLY_P) begin
        $display("TEST PASSED");
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

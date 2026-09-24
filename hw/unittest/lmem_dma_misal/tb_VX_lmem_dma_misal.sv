// tb_VX_lmem_dma_misal.sv
`timescale 1ns / 1ps
`include "VX_define.vh"
`ifndef TB_RD_PREFETCH_DEPTH
`define TB_RD_PREFETCH_DEPTH 1
`endif
`ifndef TB_ENABLE_MISALIGN
`define TB_ENABLE_MISALIGN 1
`endif
`ifndef TB_REORDER_RESPONSES
`define TB_REORDER_RESPONSES 0
`endif
`ifndef TB_GEMM_REQ_BACKPRESSURE
`define TB_GEMM_REQ_BACKPRESSURE 1
`endif
`ifdef GEMM_IMPROVE
`define TB_NO_WRAPPER_SYNC
`elsif GEMM_NAIVE
`define TB_NO_WRAPPER_SYNC
`endif

// -----------------------------------------------------------------------------
// Testbench for VX_lmem_dma_misal with REAL VX_local_mem + byte-addressed GEMM node
//
// Updates in this version:
//   - GEMM slave model: **NO write response** (rsp_valid asserted only for READ)
//   - LMEM slave (VX_local_mem) is connected directly for this TB.
// -----------------------------------------------------------------------------

module tb_VX_lmem_dma_misal import VX_gpu_pkg::*; ();

  parameter string tb_name      = "tb_VX_lmem_dma_misal";
  parameter real   PERIOD       = 10.0;
  parameter string OBJ          = "func";  // "func" or "power"
  parameter string FILE_POSTFIX = "func";
  parameter int    RD_PREFETCH_DEPTH = `TB_RD_PREFETCH_DEPTH;
  parameter bit    ENABLE_MISALIGN = `TB_ENABLE_MISALIGN;
  parameter bit    REORDER_RESPONSES = `TB_REORDER_RESPONSES;
  parameter bit    GEMM_REQ_BACKPRESSURE = `TB_GEMM_REQ_BACKPRESSURE;

  // -----------------------------
  // Params
  // -----------------------------
  localparam int NDIM            = 3;
  localparam int DATA_SIZE_BYTES = 16;      // bus beat bytes
  localparam int MEM_BYTES       = 64*1024;

  localparam int TAG_WIDTH  = GEMM_MEM_TAG_WIDTH;
  localparam int BUS_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE_BYTES);

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

  logic sync0_ready_r;
  logic sync1_ready_r;

  assign sync0_if.ready = sync0_ready_r;
  assign sync1_if.ready = sync1_ready_r;

  // -----------------------------
  // Shared slave buses
  // -----------------------------
  // This is the LMEM bus "seen by DMAs" (after mux).
  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_s();

  // GEMM shared slave bus (byte-addressed array model)
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
    .NDIM(NDIM),
    .TAG_WIDTH(TAG_WIDTH),
    .RD_PREFETCH_DEPTH(RD_PREFETCH_DEPTH),
    .ENABLE_MISALIGN(ENABLE_MISALIGN),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
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
    .NDIM(NDIM),
    .TAG_WIDTH(TAG_WIDTH),
    .RD_PREFETCH_DEPTH(RD_PREFETCH_DEPTH),
    .ENABLE_MISALIGN(ENABLE_MISALIGN),
    .LMEM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .GEMM_ADDR_WIDTH_P(BUS_ADDR_WIDTH),
    .LMEM_TAG_WIDTH_P(TAG_WIDTH),
    .GEMM_TAG_WIDTH_P(TAG_WIDTH)
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
  // -----------------------------
  wire sel = ~ctrl1_if.idle;

  // LMEM mux: drive shared slave inputs from selected master
  assign lmem_bus_s.req_valid = sel ? lmem1_bus_m.req_valid : lmem0_bus_m.req_valid;
  assign lmem_bus_s.req_data  = sel ? lmem1_bus_m.req_data  : lmem0_bus_m.req_data;
  assign lmem_bus_s.rsp_ready = sel ? lmem1_bus_m.rsp_ready : lmem0_bus_m.rsp_ready;

  // return slave outputs to the selected master; deassert to unselected
  assign lmem0_bus_m.req_ready = sel ? 1'b0 : lmem_bus_s.req_ready;
  assign lmem1_bus_m.req_ready = sel ? lmem_bus_s.req_ready : 1'b0;
  assign lmem0_bus_m.rsp_valid = sel ? 1'b0 : lmem_bus_s.rsp_valid;
  assign lmem1_bus_m.rsp_valid = sel ? lmem_bus_s.rsp_valid : 1'b0;

  assign lmem0_bus_m.rsp_data  = lmem_bus_s.rsp_data;
  assign lmem1_bus_m.rsp_data  = lmem_bus_s.rsp_data;

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

  // Raw LMEM bus that actually connects to VX_local_mem
  VX_mem_bus_if #(
    .DATA_SIZE(DATA_SIZE_BYTES),
    .TAG_WIDTH(TAG_WIDTH)
  ) lmem_bus_raw_ifs[LMEM_PORTS]();

  logic lmem_write_stall_r;
  logic lmem_rsp_gate_r;
  always_ff @(posedge clk) begin
    if (reset)
      lmem_write_stall_r <= 1'b0;
    else
      lmem_write_stall_r <= ~lmem_write_stall_r;
  end
  wire lmem_req_enable = !lmem_bus_s.req_data.rw || !lmem_write_stall_r;

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
    .mem_bus_if(lmem_bus_raw_ifs)
  );

  // Direct LMEM wiring
  assign lmem_bus_raw_ifs[0].req_valid = lmem_bus_s.req_valid && lmem_req_enable;
  assign lmem_bus_raw_ifs[0].req_data  = lmem_bus_s.req_data;
  assign lmem_bus_s.req_ready = lmem_bus_raw_ifs[0].req_ready && lmem_req_enable;
  assign lmem_bus_raw_ifs[0].rsp_ready = lmem_bus_s.rsp_ready
                                      && lmem_rsp_gate_r;
  assign lmem_bus_s.rsp_data  = lmem_bus_raw_ifs[0].rsp_data;
  assign lmem_bus_s.rsp_valid = lmem_bus_raw_ifs[0].rsp_valid
                              && lmem_rsp_gate_r;

  // -----------------------------
  // GEMM node memory model (byte-addressed) + bus slave (1-cycle latency)
  //   UPDATED: **NO write response**
  //     - rsp_valid asserted only for READs
  // -----------------------------
  byte gemm_mem [0:MEM_BYTES-1];

  typedef struct packed {
      logic [`UP(UUID_WIDTH)-1:0]   uuid;
      logic [TAG_WIDTH-`UP(UUID_WIDTH)-1:0] value;
  } tag_t;

  localparam int GEMM_RD_Q_DEPTH = 64;
  localparam int GEMM_RD_Q_BITS  = $clog2(GEMM_RD_Q_DEPTH);

  logic [GEMM_RD_Q_BITS-1:0]         g_rd_head_r;
  logic [GEMM_RD_Q_BITS-1:0]         g_rd_tail_r;
  logic [GEMM_RD_Q_BITS:0]           g_rd_count_r;
  logic                               gemm_req_stall_r;
  logic [gemm_bus_s.ADDR_WIDTH-1:0]  g_rd_addr_q [0:GEMM_RD_Q_DEPTH-1];
  tag_t                              g_rd_tag_q  [0:GEMM_RD_Q_DEPTH-1];
  wire                               gemm_req_fire = gemm_bus_s.req_valid && gemm_bus_s.req_ready;
  wire                               gemm_req_read_fire = gemm_req_fire && !gemm_bus_s.req_data.rw;
  wire [GEMM_RD_Q_BITS-1:0]          g_rsp_idx = REORDER_RESPONSES
                                                ? (g_rd_tail_r - 1'b1)
                                                : g_rd_head_r;
  wire                               gemm_rsp_release = !REORDER_RESPONSES
                                                       || (g_rd_count_r >= 4)
                                                       || !gemm_bus_s.req_valid;
  wire                               gemm_rsp_issue = (!gemm_bus_s.rsp_valid || gemm_bus_s.rsp_ready)
                                                    && (g_rd_count_r != 0)
                                                    && gemm_rsp_release;

  always @(posedge clk) begin
    if (reset) begin
      gemm_bus_s.req_ready <= 1'b1;
      gemm_bus_s.rsp_valid <= 1'b0;
      gemm_bus_s.rsp_data  <= '0;
      g_rd_head_r          <= '0;
      g_rd_tail_r          <= '0;
      g_rd_count_r         <= '0;
      gemm_req_stall_r     <= 1'b0;
    end else begin
      gemm_req_stall_r <= GEMM_REQ_BACKPRESSURE ? ~gemm_req_stall_r : 1'b0;
      gemm_bus_s.req_ready <= (g_rd_count_r != GEMM_RD_Q_DEPTH)
                           && !gemm_req_stall_r;

      if (gemm_bus_s.rsp_valid && gemm_bus_s.rsp_ready)
        gemm_bus_s.rsp_valid <= 1'b0;

      if (gemm_req_fire) begin
        int unsigned base_b;
        base_b = int'(gemm_bus_s.req_data.addr) << $clog2(DATA_SIZE_BYTES);

        if (gemm_bus_s.req_data.rw) begin
          for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
            if (gemm_bus_s.req_data.byteen[i] && (base_b + i < MEM_BYTES))
              gemm_mem[base_b + i] <= gemm_bus_s.req_data.data[i*8 +: 8];
          end
        end else begin
          if (g_rd_count_r == GEMM_RD_Q_DEPTH)
            $fatal(1, "GEMM read queue overflow");
          g_rd_addr_q[g_rd_tail_r] <= gemm_bus_s.req_data.addr;
          g_rd_tag_q[g_rd_tail_r]  <= gemm_bus_s.req_data.tag;
          if (!REORDER_RESPONSES)
            g_rd_tail_r <= g_rd_tail_r + 1'b1;
        end
      end

      if (gemm_rsp_issue) begin
        int unsigned base_b;
        base_b = int'(g_rd_addr_q[g_rsp_idx]) << $clog2(DATA_SIZE_BYTES);

        gemm_bus_s.rsp_valid    <= 1'b1;
        gemm_bus_s.rsp_data.tag <= g_rd_tag_q[g_rsp_idx];
        for (int i = 0; i < DATA_SIZE_BYTES; i++) begin
          if (base_b + i < MEM_BYTES)
            gemm_bus_s.rsp_data.data[i*8 +: 8] <= gemm_mem[base_b + i];
          else
            gemm_bus_s.rsp_data.data[i*8 +: 8] <= 8'h00;
        end

        if (!REORDER_RESPONSES)
          g_rd_head_r <= g_rd_head_r + 1'b1;
      end

      unique case ({gemm_req_read_fire, gemm_rsp_issue})
        2'b10: g_rd_count_r <= g_rd_count_r + 1'b1;
        2'b01: g_rd_count_r <= g_rd_count_r - 1'b1;
        default:;
      endcase

      if (REORDER_RESPONSES) begin
        unique case ({gemm_req_read_fire, gemm_rsp_issue})
          2'b10: g_rd_tail_r <= g_rd_tail_r + 1'b1;
          2'b01: g_rd_tail_r <= g_rd_tail_r - 1'b1;
          default:;
        endcase
      end
    end
  end

  longint unsigned cycle_count_r;
  integer sync0_accept_count;
  integer sync1_accept_count;
  integer done0_count;
  integer done1_count;
  integer write_done0_count;
  integer write_done1_count;
  integer request_accept_count;
  longint unsigned expected_write_remaining0;
  longint unsigned expected_write_remaining1;

  always_ff @(posedge clk) begin
    if (reset) begin
      cycle_count_r <= 0;
      sync0_accept_count <= 0;
      sync1_accept_count <= 0;
      done0_count <= 0;
      done1_count <= 0;
      write_done0_count <= 0;
      write_done1_count <= 0;
      request_accept_count <= 0;
      expected_write_remaining0 <= 0;
      expected_write_remaining1 <= 0;
    end else begin
      cycle_count_r <= cycle_count_r + 1;
      if (sync0_if.valid && sync0_if.ready)
        sync0_accept_count <= sync0_accept_count + 1;
      if (sync1_if.valid && sync1_if.ready)
        sync1_accept_count <= sync1_accept_count + 1;
      if (ctrl0_if.done)
        done0_count <= done0_count + 1;
      if (ctrl1_if.done)
        done1_count <= done1_count + 1;
      if (ctrl0_if.start)
        expected_write_remaining0 <= 64'(ctrl0_if.seg_size)
                                   * 64'(ctrl0_if.bounds[0])
                                   * 64'(ctrl0_if.bounds[1])
                                   * 64'(ctrl0_if.bounds[2]);
      if (ctrl1_if.start)
        expected_write_remaining1 <= 64'(ctrl1_if.seg_size)
                                   * 64'(ctrl1_if.bounds[0])
                                   * 64'(ctrl1_if.bounds[1])
                                   * 64'(ctrl1_if.bounds[2]);
      if (!sel && gemm_req_fire && gemm_bus_s.req_data.rw) begin
        if (ctrl0_if.write_done
            !== (expected_write_remaining0 == $countones(gemm_bus_s.req_data.byteen)))
          $fatal(1, "DIR0 write_done is not the exact final accepted destination write");
        expected_write_remaining0 <= expected_write_remaining0
                                   - $countones(gemm_bus_s.req_data.byteen);
      end else if (ctrl0_if.write_done) begin
        $fatal(1, "DIR0 write_done without accepted GEMM destination write");
      end
      if (sel && lmem_bus_s.req_valid && lmem_bus_s.req_ready
          && lmem_bus_s.req_data.rw) begin
        if (ctrl1_if.write_done
            !== (expected_write_remaining1 == $countones(lmem_bus_s.req_data.byteen)))
          $fatal(1, "DIR1 write_done is not the exact final accepted destination write");
        expected_write_remaining1 <= expected_write_remaining1
                                   - $countones(lmem_bus_s.req_data.byteen);
      end else if (ctrl1_if.write_done) begin
        $fatal(1, "DIR1 write_done without accepted LMEM destination write");
      end
      if (ctrl0_if.write_done) begin
        if (ctrl0_if.done)
          $fatal(1, "DIR0 write_done was delayed to wrapper done");
        write_done0_count <= write_done0_count + 1;
      end
      if (ctrl1_if.write_done) begin
        if (ctrl1_if.done)
          $fatal(1, "DIR1 write_done was delayed to wrapper done");
        write_done1_count <= write_done1_count + 1;
      end
      request_accept_count <= request_accept_count
                            + (lmem_bus_s.req_valid && lmem_bus_s.req_ready)
                            + (gemm_bus_s.req_valid && gemm_bus_s.req_ready);
    end
  end

`ifdef TB_PERF_TRACE
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (lmem_bus_s.req_valid && lmem_bus_s.req_ready)
        $display("[BUS_FIRE] t=%0t dir=%0d endpoint=lmem rw=%0d", $time, sel,
                 lmem_bus_s.req_data.rw);
      if (gemm_bus_s.req_valid && gemm_bus_s.req_ready)
        $display("[BUS_FIRE] t=%0t dir=%0d endpoint=gemm rw=%0d", $time, sel,
                 gemm_bus_s.req_data.rw);
      if (lmem_bus_s.rsp_valid && lmem_bus_s.rsp_ready)
        $display("[RSP_FIRE] t=%0t dir=%0d endpoint=lmem", $time, sel);
      if (gemm_bus_s.rsp_valid && gemm_bus_s.rsp_ready)
        $display("[RSP_FIRE] t=%0t dir=%0d endpoint=gemm", $time, sel);
      if (dut_dir0.dma_done_if.valid && (dut_dir0.state == 1))
        $display("[CORE_DONE] t=%0t dir=0", $time);
      if (dut_dir1.dma_done_if.valid && (dut_dir1.state == 1))
        $display("[CORE_DONE] t=%0t dir=1", $time);
    end
  end
`endif

`ifdef TB_NO_WRAPPER_SYNC
  always_ff @(posedge clk) begin
    if (!reset && (sync0_if.valid || sync1_if.valid))
      $fatal(1, "Improved/naive local DMA unexpectedly emitted wrapper sync");
`ifdef GEMM_IMPROVE
    if (!reset && ((dut_dir0.state == dut_dir0.S_SYNC)
                || (dut_dir1.state == dut_dir1.S_SYNC)))
      $fatal(1, "GEMM_IMPROVE local DMA entered removed S_SYNC state");
`endif
  end
`endif

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
  // NOTE: dst_strides are set equal to src_strides here
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
    @(negedge clk);
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
    @(negedge clk);
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
    integer sync_before, done_before, write_done_before;
    longint unsigned dir0_start_cycle, dir1_start_cycle;
    longint unsigned dir0_cycles, dir1_cycles;

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
    sync_before = sync1_accept_count;
    done_before = done1_count;
    write_done_before = write_done1_count;
    dir1_start_cycle = cycle_count_r;
    ctrl1_pulse_start(
      gemm_src_base, lmem_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg1_idx, reg1_val
    );
`ifndef TB_NO_WRAPPER_SYNC
    wait_sync1_and_check(reg1_idx, reg1_val, "DIR1");
`endif
    wait_dma_done1();
    #1;
    dir1_cycles = cycle_count_r - dir1_start_cycle;
`ifdef TB_NO_WRAPPER_SYNC
    if (sync1_accept_count != sync_before)
      $fatal(1, "DIR1 improved/naive emitted sync");
`else
    if (sync1_accept_count != (sync_before + 1))
      $fatal(1, "DIR1 sync count mismatch: before=%0d after=%0d",
             sync_before, sync1_accept_count);
`endif
    if (done1_count != (done_before + 1))
      $fatal(1, "DIR1 done pulse count mismatch: before=%0d after=%0d",
             done_before, done1_count);
    if (write_done1_count != (write_done_before + 1))
      $fatal(1, "DIR1 write_done exact pulse count mismatch: before=%0d after=%0d",
             write_done_before, write_done1_count);

    // 2) LMEM -> GEMM  (DIR=0)
    sync_before = sync0_accept_count;
    done_before = done0_count;
    write_done_before = write_done0_count;
    dir0_start_cycle = cycle_count_r;
    ctrl0_pulse_start(
      lmem_base, gemm_dst_base,
      stride0, stride1, stride2,
      b0, b1, b2,
      seg_bytes,
      reg0_idx, reg0_val
    );
`ifndef TB_NO_WRAPPER_SYNC
    wait_sync0_and_check(reg0_idx, reg0_val, "DIR0");
`endif
    wait_dma_done0();
    #1;
    dir0_cycles = cycle_count_r - dir0_start_cycle;
`ifdef TB_NO_WRAPPER_SYNC
    if (sync0_accept_count != sync_before)
      $fatal(1, "DIR0 improved/naive emitted sync");
`else
    if (sync0_accept_count != (sync_before + 1))
      $fatal(1, "DIR0 sync count mismatch: before=%0d after=%0d",
             sync_before, sync0_accept_count);
`endif
    if (done0_count != (done_before + 1))
      $fatal(1, "DIR0 done pulse count mismatch: before=%0d after=%0d",
             done_before, done0_count);
    if (write_done0_count != (write_done_before + 1))
      $fatal(1, "DIR0 write_done exact pulse count mismatch: before=%0d after=%0d",
             write_done_before, write_done0_count);

    // 3) Verify GEMM only
    gemm_check_equal(gemm_src_base, gemm_dst_base, total_bytes, "ROUNDTRIP");

    $display("[CYCLES] dir1=%0d dir0=%0d total=%0d",
             dir1_cycles, dir0_cycles, dir1_cycles + dir0_cycles);
    $display("[CASE] PASS ✅");
    $fdisplay(rpt_fd, "[CASE] seg=%0d bnd=(%0d,%0d,%0d) off(s=%0d d=%0d l=%0d) PASS",
              seg_bytes, b0, b1, b2, src_off, dst_off, lmem_off);
  endtask

  task automatic run_zero_case(
    input bit dir,
    input bit zero_seg_size,
    input bit zero_bound
  );
    integer req_before, sync_before, done_before, write_done_before;
    logic [31:0] reg_idx, reg_val;

    req_before = request_accept_count;
    reg_idx = dir ? 32'd41 : 32'd40;
    reg_val = dir ? 32'h0102_0304 : 32'hA0B0_C0D0;

    if (dir) begin
      sync_before = sync1_accept_count;
      done_before = done1_count;
      write_done_before = write_done1_count;
      ctrl1_pulse_start(
        32'h3000, 32'h1000,
        DATA_SIZE_BYTES, DATA_SIZE_BYTES, DATA_SIZE_BYTES,
        zero_bound ? 0 : 1, 1, 1,
        zero_seg_size ? 0 : DATA_SIZE_BYTES,
        reg_idx, reg_val
      );
`ifndef TB_NO_WRAPPER_SYNC
      wait_sync1_and_check(reg_idx, reg_val, "DIR1_ZERO");
`endif
      wait_dma_done1();
      #1;
      if (done1_count != (done_before + 1))
        $fatal(1, "DIR1 zero-size done count mismatch");
`ifdef TB_NO_WRAPPER_SYNC
      if (sync1_accept_count != sync_before)
        $fatal(1, "DIR1 zero-size GEMM_NAIVE emitted sync");
`else
      if (sync1_accept_count != (sync_before + 1))
        $fatal(1, "DIR1 zero-size sync count mismatch");
`endif
      if (write_done1_count != write_done_before)
        $fatal(1, "DIR1 zero-size unexpectedly emitted write_done");
    end else begin
      sync_before = sync0_accept_count;
      done_before = done0_count;
      write_done_before = write_done0_count;
      ctrl0_pulse_start(
        32'h1000, 32'h5000,
        DATA_SIZE_BYTES, DATA_SIZE_BYTES, DATA_SIZE_BYTES,
        zero_bound ? 0 : 1, 1, 1,
        zero_seg_size ? 0 : DATA_SIZE_BYTES,
        reg_idx, reg_val
      );
`ifndef TB_NO_WRAPPER_SYNC
      wait_sync0_and_check(reg_idx, reg_val, "DIR0_ZERO");
`endif
      wait_dma_done0();
      #1;
      if (done0_count != (done_before + 1))
        $fatal(1, "DIR0 zero-size done count mismatch");
`ifdef TB_NO_WRAPPER_SYNC
      if (sync0_accept_count != sync_before)
        $fatal(1, "DIR0 zero-size GEMM_NAIVE emitted sync");
`else
      if (sync0_accept_count != (sync_before + 1))
        $fatal(1, "DIR0 zero-size sync count mismatch");
`endif
      if (write_done0_count != write_done_before)
        $fatal(1, "DIR0 zero-size unexpectedly emitted write_done");
    end

    if (request_accept_count != req_before)
      $fatal(1, "zero-size command issued memory requests: before=%0d after=%0d",
             req_before, request_accept_count);
    $display("[ZERO] PASS dir=%0d zero_seg=%0d zero_bound=%0d",
             dir, zero_seg_size, zero_bound);
  endtask

`ifndef TB_NO_WRAPPER_SYNC
  task automatic run_sync_backpressure_case();
    integer sync_before, done_before;
    logic [31:0] reg_idx = 32'd52;
    logic [31:0] reg_val = 32'h55AA_33CC;

    sync_before = sync0_accept_count;
    done_before = done0_count;
    sync0_ready_r = 1'b0;
    ctrl0_pulse_start(
      32'h1000, 32'h5000,
      DATA_SIZE_BYTES, DATA_SIZE_BYTES, DATA_SIZE_BYTES,
      1, 1, 1, 0,
      reg_idx, reg_val
    );
    wait_sync0_and_check(reg_idx, reg_val, "DIR0_SYNC_BP");
    repeat (3) begin
      @(posedge clk);
      if (!sync0_if.valid || ctrl0_if.done || ctrl0_if.idle)
        $fatal(1, "sync was not held while ready=0");
    end
    @(negedge clk);
    sync0_ready_r = 1'b1;
    wait_dma_done0();
    #1;
    if (sync0_accept_count != (sync_before + 1))
      $fatal(1, "sync backpressure acceptance count mismatch: before=%0d after=%0d",
             sync_before, sync0_accept_count);
    if (done0_count != (done_before + 1))
      $fatal(1, "sync backpressure done count mismatch: before=%0d after=%0d",
             done_before, done0_count);
    $display("[SYNC_BP] PASS");
  endtask
`endif

  task automatic program_ctrl0_descriptor(
    input logic [31:0] src_base,
    input logic [31:0] dst_base,
    input logic [31:0] seg_size
  );
    begin
      ctrl0_if.src_base_addr = src_base;
      ctrl0_if.dst_base_addr = dst_base;
      for (int d = 0; d < NDIM; ++d) begin
        ctrl0_if.src_strides[d] = seg_size;
        ctrl0_if.dst_strides[d] = seg_size;
        ctrl0_if.bounds[d] = 32'd1;
      end
      ctrl0_if.seg_size = seg_size;
      ctrl0_if.reg_idx = 32'd61;
      ctrl0_if.reg_value = 32'hCA11_AB1E;
    end
  endtask

  task automatic pulse_ctrl0_prepare(input int unsigned max_beats);
    begin
      do @(posedge clk); while (!ctrl0_if.prepare_ready);
      @(negedge clk);
      ctrl0_if.prepare_max_beats = GEMM_PREFETCH_MAX_BEATS_WIDTH'(max_beats);
      ctrl0_if.prepare = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ctrl0_if.prepare = 1'b0;
    end
  endtask

  task automatic pulse_ctrl0_release();
    begin
      if (!ctrl0_if.idle)
        $fatal(1, "LMEM_PREPARE exact descriptor was not release-ready");
      @(negedge clk);
      ctrl0_if.start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      ctrl0_if.start = 1'b0;
    end
  endtask

  task automatic run_unsupported_prepare_case();
    int req_before;
    begin
      program_ctrl0_descriptor(32'h1000, 32'h5800, 32'd32);
      req_before = request_accept_count;
      @(negedge clk);
      ctrl0_if.prepare_max_beats = GEMM_PREFETCH_MAX_BEATS_WIDTH'(1);
      ctrl0_if.prepare = 1'b1;
      repeat (3) begin
        @(posedge clk);
        #1;
        if (ctrl0_if.prepare_ready)
          $fatal(1, "LMEM_PREPARE unsupported DIR0/misaligned path became ready");
        if (dut_dir0.state != dut_dir0.S_IDLE)
          $fatal(1, "LMEM_PREPARE unsupported request changed wrapper state");
      end
      @(negedge clk);
      ctrl0_if.prepare = 1'b0;
      if (request_accept_count != req_before)
        $fatal(1, "LMEM_PREPARE unsupported request emitted bus traffic");
      if (ctrl1_if.prepare_ready)
        $fatal(1, "LMEM_PREPARE DIR1 unexpectedly advertised prepare support");
      $display("LMEM_PREPARE_UNSUPPORTED_PASS enable_misalign=%0d dir0_ready=0 dir1_ready=0 normal_fallback=covered",
               ENABLE_MISALIGN);
    end
  endtask

  task automatic run_unsupported_dir1_prepare_case();
    int req_before;
    begin
      ctrl1_if.src_base_addr = 32'h3200;
      ctrl1_if.dst_base_addr = 32'h1200;
      for (int d = 0; d < NDIM; ++d) begin
        ctrl1_if.src_strides[d] = 32'd32;
        ctrl1_if.dst_strides[d] = 32'd32;
        ctrl1_if.bounds[d] = 32'd1;
      end
      ctrl1_if.seg_size = 32'd32;
      ctrl1_if.reg_idx = 32'd62;
      ctrl1_if.reg_value = 32'hD1D1_0000;
      req_before = request_accept_count;
      @(negedge clk);
      ctrl1_if.prepare_max_beats = GEMM_PREFETCH_MAX_BEATS_WIDTH'(1);
      ctrl1_if.prepare = 1'b1;
      repeat (3) begin
        @(posedge clk);
        #1;
        if (ctrl1_if.prepare_ready)
          $fatal(1, "LMEM_PREPARE unsupported DIR1 became ready");
        if (dut_dir1.state != dut_dir1.S_IDLE)
          $fatal(1, "LMEM_PREPARE unsupported DIR1 changed wrapper state");
      end
      @(negedge clk);
      ctrl1_if.prepare = 1'b0;
      if (request_accept_count != req_before)
        $fatal(1, "LMEM_PREPARE unsupported DIR1 emitted bus traffic");
      $display("LMEM_PREPARE_DIR1_UNSUPPORTED_PASS prepare_ready=0 traffic=0");
    end
  endtask

  task automatic wait_ctrl0_done_with_limit(input int max_cycles);
    int cycles;
    begin
      cycles = 0;
      while (!ctrl0_if.done && (cycles < max_cycles)) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (!ctrl0_if.done)
        $fatal(1, "LMEM_PREPARE timeout waiting for DIR0 done");
      @(posedge clk);
      #1;
    end
  endtask

  task automatic run_aligned_prepare_case(
    input bit hold_response,
    input logic [31:0] dst_base,
    input string marker
  );
    int src_req_count;
    int dst_write_count;
    int write_done_before;
    int done_before;
    int traffic_before;
    int wait_cycles;
    bit source_seen;
    bit response_seen;
    begin
      gemm_clear_range(dst_base, 32);
      program_ctrl0_descriptor(32'h1200, dst_base, 32'd32);
      lmem_rsp_gate_r = !hold_response;
      src_req_count = 0;
      dst_write_count = 0;
      source_seen = 1'b0;
      response_seen = 1'b0;
      write_done_before = write_done0_count;
      done_before = done0_count;
      traffic_before = request_accept_count;
      pulse_ctrl0_prepare(1);

      wait_cycles = 0;
      while ((!source_seen || (!hold_response && !response_seen))
          && (wait_cycles < 30)) begin
        @(posedge clk);
        #1;
        if (lmem0_bus_m.req_valid && lmem0_bus_m.req_ready
         && !lmem0_bus_m.req_data.rw) begin
          src_req_count++;
          source_seen = 1'b1;
        end
        if (lmem0_bus_m.rsp_valid && lmem0_bus_m.rsp_ready)
          response_seen = 1'b1;
        if (gemm0_bus_m.req_valid && gemm0_bus_m.req_ready
         && gemm0_bus_m.req_data.rw)
          dst_write_count++;
        if (ctrl0_if.write_done || ctrl0_if.done)
          $fatal(1, "LMEM_PREPARE %s completed before release", marker);
        wait_cycles++;
      end
      if (!source_seen || (!hold_response && !response_seen))
        $fatal(1, "LMEM_PREPARE %s did not reach requested pre-release state",
               marker);
      repeat (2) begin
        @(posedge clk);
        #1;
        if (lmem0_bus_m.req_valid && lmem0_bus_m.req_ready
         && !lmem0_bus_m.req_data.rw)
          src_req_count++;
        if (gemm0_bus_m.req_valid && gemm0_bus_m.req_ready
         && gemm0_bus_m.req_data.rw)
          dst_write_count++;
        if (ctrl0_if.write_done || ctrl0_if.done)
          $fatal(1, "LMEM_PREPARE %s exposed completion before release", marker);
      end
      if (src_req_count != 1 || dst_write_count != 0)
        $fatal(1,
          "LMEM_PREPARE %s bounded/no-commit mismatch src=%0d dst=%0d",
          marker, src_req_count, dst_write_count);

      // The wrapper only presents idle/acceptance for the exact prepared
      // descriptor.  A changed destination must not be accepted as release.
      ctrl0_if.dst_base_addr = dst_base + 32'd16;
      #1;
      if (ctrl0_if.idle)
        $fatal(1, "LMEM_PREPARE %s accepted mismatched descriptor", marker);
      ctrl0_if.dst_base_addr = dst_base;
      #1;
      if (!ctrl0_if.idle)
        $fatal(1, "LMEM_PREPARE %s lost exact descriptor match", marker);

      pulse_ctrl0_release();
      if (hold_response)
        lmem_rsp_gate_r = 1'b1;

      wait_ctrl0_done_with_limit(100);
      if (write_done0_count != (write_done_before + 1)
       || done0_count != (done_before + 1))
        $fatal(1,
          "LMEM_PREPARE %s completion count mismatch write_done=%0d done=%0d",
          marker, write_done0_count - write_done_before,
          done0_count - done_before);
      if (request_accept_count != (traffic_before + 4))
        $fatal(1,
          "LMEM_PREPARE %s duplicate/reordered traffic count=%0d expected=4",
          marker, request_accept_count - traffic_before);
      gemm_check_equal(32'h3200, dst_base, 32, marker);
      $display("%s src_pre_release=1 max_beats=1 dst_pre_release=0 exact_match=1 no_duplicate=1 write_done=1 done=1",
               marker);
    end
  endtask

  task automatic run_aligned_four_beat_prepare_case();
    localparam int TEST_BYTES = 6 * DATA_SIZE_BYTES;
    int src_req_count;
    int dst_write_count;
    int write_done_before;
    int done_before;
    int traffic_before;
    int wait_cycles;
    begin
      gemm_clear_range(32'h5500, TEST_BYTES);
      program_ctrl0_descriptor(32'h1600, 32'h5500, TEST_BYTES);
      lmem_rsp_gate_r = 1'b1;
      src_req_count = 0;
      dst_write_count = 0;
      write_done_before = write_done0_count;
      done_before = done0_count;
      traffic_before = request_accept_count;
      pulse_ctrl0_prepare(4);

      wait_cycles = 0;
      while ((src_req_count < 4) && (wait_cycles < 40)) begin
        @(posedge clk);
        #1;
        if (lmem0_bus_m.req_valid && lmem0_bus_m.req_ready
         && !lmem0_bus_m.req_data.rw)
          src_req_count++;
        if (gemm0_bus_m.req_valid && gemm0_bus_m.req_ready
         && gemm0_bus_m.req_data.rw)
          dst_write_count++;
        if (ctrl0_if.write_done || ctrl0_if.done)
          $fatal(1, "LMEM_PREPARE four-beat case completed before release");
        wait_cycles++;
      end
      if (src_req_count != 4)
        $fatal(1, "LMEM_PREPARE four-beat source count=%0d expected=4",
               src_req_count);
      repeat (4) begin
        @(posedge clk);
        #1;
        if (lmem0_bus_m.req_valid && lmem0_bus_m.req_ready
         && !lmem0_bus_m.req_data.rw)
          src_req_count++;
        if (gemm0_bus_m.req_valid && gemm0_bus_m.req_ready
         && gemm0_bus_m.req_data.rw)
          dst_write_count++;
        if (ctrl0_if.write_done || ctrl0_if.done)
          $fatal(1, "LMEM_PREPARE four-beat case exposed completion before release");
      end
      if (src_req_count != 4 || dst_write_count != 0)
        $fatal(1,
          "LMEM_PREPARE four-beat credit/no-commit mismatch src=%0d dst=%0d",
          src_req_count, dst_write_count);

      pulse_ctrl0_release();
      wait_ctrl0_done_with_limit(160);
      if (write_done0_count != (write_done_before + 1)
       || done0_count != (done_before + 1))
        $fatal(1, "LMEM_PREPARE four-beat completion count mismatch");
      if (request_accept_count != (traffic_before + 12))
        $fatal(1,
          "LMEM_PREPARE four-beat traffic count=%0d expected=12",
          request_accept_count - traffic_before);
      gemm_check_equal(32'h3600, 32'h5500, TEST_BYTES,
                       "LMEM_PREPARE_FOUR_BEAT_PASS");
      $display("LMEM_PREPARE_FOUR_BEAT_PASS src_pre_release=4 max_beats=4 dst_pre_release=0 total_source=6 total_destination=6");
    end
  endtask

  task automatic run_aligned_reset_invalidate_case();
    int dst_before;
    int wait_cycles;
    begin
      program_ctrl0_descriptor(32'h1200, 32'h5400, 32'd32);
      lmem_rsp_gate_r = 1'b0;
      pulse_ctrl0_prepare(1);
      wait_cycles = 0;
      while (!(lmem0_bus_m.req_valid && lmem0_bus_m.req_ready
            && !lmem0_bus_m.req_data.rw) && (wait_cycles < 30)) begin
        @(posedge clk);
        #1;
        wait_cycles++;
      end
      if (wait_cycles == 30)
        $fatal(1, "LMEM_PREPARE reset case never issued source read");
      dst_before = write_done0_count;
      @(negedge clk);
      reset = 1'b1;
      ctrl0_if.prepare = 1'b0;
      ctrl0_if.start = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      lmem_rsp_gate_r = 1'b1;
      repeat (5) begin
        @(posedge clk);
        #1;
        if (gemm0_bus_m.req_valid && gemm0_bus_m.req_ready
         && gemm0_bus_m.req_data.rw)
          $fatal(1, "LMEM_PREPARE reset released stale destination write");
      end
      if (dut_dir0.prepared_r || dut_dir0.released_r
       || dut_dir0.state != dut_dir0.S_IDLE || write_done0_count != 0)
        $fatal(1, "LMEM_PREPARE reset did not invalidate prepared state");
      $display("LMEM_PREPARE_RESET_INVALIDATE_PASS stale_write=0 prepared=0 released=0");
    end
  endtask

  // -----------------------------
  // sim_func / sim_power
  // -----------------------------
  task automatic sim_func();
    int unsigned b0 = 2, b1 = 2, b2 = 2;
    int unsigned sb0 = 8, sb1 = 1, sb2 = 1;

    $display("=====================================================================");
    $display("=======================  START SIMULATION  ==========================");
    $display("=====================================================================");
    $display("BUS_BYTES: %0d", DATA_SIZE_BYTES);

    // ctrl defaults
    ctrl0_if.start = 1'b0;
    ctrl1_if.start = 1'b0;
    ctrl0_if.prepare = 1'b0;
    ctrl1_if.prepare = 1'b0;
    ctrl0_if.prepare_max_beats = '0;
    ctrl1_if.prepare_max_beats = '0;
    lmem_rsp_gate_r = 1'b1;
    sync0_ready_r = 1'b1;
    sync1_ready_r = 1'b1;

    // Wait stable
    repeat (5) @(posedge clk);

    // aligned baseline
    run_case_roundtrip(DATA_SIZE_BYTES*1, 1,1,1, 0,0,0);
    run_case_roundtrip(DATA_SIZE_BYTES*8, 1,1,1, 0,0,0);
    if (ENABLE_MISALIGN) begin
      run_unsupported_prepare_case();
    end else begin
      // Populate 0x1200 with immutable source bytes through the normal DIR1
      // path, then exercise both release timing cases on aligned DIR0.
      gemm_fill_inc(32'h3200, 64, 8'h70);
      ctrl1_pulse_start(32'h3200, 32'h1200, 64, 64, 64,
                        1, 1, 1, 64, 32'd60, 32'h600D_F00D);
      wait_dma_done1();
      run_aligned_prepare_case(1'b0, 32'h5200,
                               "LMEM_PREPARE_BUFFERED_RELEASE_PASS");
      run_aligned_prepare_case(1'b1, 32'h5300,
                               "LMEM_PREPARE_PENDING_RELEASE_PASS");
      gemm_fill_inc(32'h3600, 6 * DATA_SIZE_BYTES, 8'h90);
      ctrl1_pulse_start(32'h3600, 32'h1600,
                        6 * DATA_SIZE_BYTES, 6 * DATA_SIZE_BYTES,
                        6 * DATA_SIZE_BYTES, 1, 1, 1,
                        6 * DATA_SIZE_BYTES, 32'd63, 32'h600D_0004);
      wait_dma_done1();
      run_aligned_four_beat_prepare_case();
      run_aligned_reset_invalidate_case();
      run_unsupported_dir1_prepare_case();
    end
    run_case_roundtrip(DATA_SIZE_BYTES*1, b0,b1,b2, 0,0,0);
    run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 0,0,0);
    run_case_roundtrip(DATA_SIZE_BYTES*4, b0,b1,b2, 0,0,0);

    // single-beat segments repeated across segment boundaries
    run_case_roundtrip(DATA_SIZE_BYTES*1, sb0,sb1,sb2, 0,0,0);

    // GEMM output shape that exercises simultaneous reader/writer segment
    // advances with the depth-four prefetch window.
    run_case_roundtrip(DATA_SIZE_BYTES*1, 128,4,1, 0,0,0);

    if (ENABLE_MISALIGN) begin
      // Independently misaligned source, destination, and LMEM addresses.
      run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 1,0,0);
      run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 0,7,0);
      run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 0,0,3);
      run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 1,7,3);
      run_case_roundtrip(DATA_SIZE_BYTES*2, b0,b1,b2, 15,2,11);

      // Partial final beats and sub-beat segments.
      run_case_roundtrip(DATA_SIZE_BYTES + 5,   b0,b1,b2, 3,11,1);
      run_case_roundtrip(DATA_SIZE_BYTES*2 + 3, b0,b1,b2, 5,1,9);
      run_case_roundtrip(DATA_SIZE_BYTES*4 - 1, b0,b1,b2, 9,13,7);
      run_case_roundtrip(DATA_SIZE_BYTES - 5, b0,b1,b2, 3,11,1);
      run_case_roundtrip(DATA_SIZE_BYTES - 1, b0,b1,b2, 5,1,9);
      run_case_roundtrip(DATA_SIZE_BYTES,     b0,b1,b2, 9,13,7);
    end

    run_zero_case(1'b0, 1'b1, 1'b0);
    run_zero_case(1'b0, 1'b0, 1'b1);
    run_zero_case(1'b1, 1'b1, 1'b0);
    run_zero_case(1'b1, 1'b0, 1'b1);

`ifndef TB_NO_WRAPPER_SYNC
    run_sync_backpressure_case();
`endif

    $display("=====================================================================");
    $display("=====================  ALL TESTS COMPLETED  =========================");
    $display("=====================================================================");
    $display("TEST PASSED");
`ifdef GEMM_IMPROVE
    $display("LMEM_DMA_EXACT_COMPLETION_PASS dir0_write_done=%0d dir1_write_done=%0d sync0=%0d sync1=%0d s_sync_entries=0",
             write_done0_count, write_done1_count,
             sync0_accept_count, sync1_accept_count);
`endif
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
    ctrl0_if.prepare = 1'b0;
    ctrl1_if.prepare = 1'b0;
    ctrl0_if.prepare_max_beats = '0;
    ctrl1_if.prepare_max_beats = '0;

    for (int iter = 0; iter < 300; iter++) begin
      int unsigned seg_bytes = seg_choices[$urandom_range(0,5)];
      int unsigned so  = $urandom_range(0, DATA_SIZE_BYTES-1);
      int unsigned dof = $urandom_range(0, DATA_SIZE_BYTES-1);
      int unsigned lo  = $urandom_range(0, DATA_SIZE_BYTES-1);

      run_case_roundtrip(seg_bytes, b0,b1,b2, so, dof, lo);
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

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1,
      "TB timeout: dir0 idle=%0b wrapper=%0d core_done=%0b | dir1 idle=%0b wrapper=%0d core_done=%0b",
      ctrl0_if.idle, dut_dir0.state, dut_dir0.dma_done_if.valid,
      ctrl1_if.idle, dut_dir1.state, dut_dir1.dma_done_if.valid
    );
  end

endmodule

`timescale 1ns / 1ps
`include "VX_define.vh"
`include "VX_cache_define.vh"

module tb_VX_gemm_node_improve
  import VX_gpu_pkg::*;
  import fpint_emul::*;
  import cf_math_util_pkg::*;
();

  // =========================================================================
  // Params
  // =========================================================================
  parameter string TB_NAME  = "tb_VX_gemm_node_improve";
  parameter string OBJ      = "func";
  parameter int    PERIOD   = 10;
  parameter int    N_MASTER = 1;

  // compare tolerance
  localparam real FP16_TOL = 0.01; // ~1.5 LSB of FP16

  // default smoke sizes (runtime-configurable via tasks)
  localparam int DEFAULT_M_TEST = 32;
  localparam int DEFAULT_N_TEST = 32;
  localparam int DEFAULT_K_TEST = 128;
  localparam int DEFAULT_QBLK   = 32;

  // GEMM DMA tile/micro-tile shape (must match DUT build-time config)
  localparam int DMA_MT     = `GEMM_FSM_MT;
  localparam int DMA_NT     = `GEMM_FSM_NT;
  localparam int DMA_KT     = `GEMM_FSM_KT;
  localparam int DMA_MXU_KT = `GEMM_FSM_MXU_KT;
  localparam int DMA_MXU_NT = `GEMM_FSM_MXU_NT;

  localparam int FP16_WIDTH   = 16;

  // LMEM layout footprint (tile-based, double-buffered)
  localparam longint unsigned LMEM_LAYOUT_ALIGN_BYTES = 64'd4096;
  localparam longint unsigned LMEM_GROUPS_TILE        = (longint'(DMA_KT) + longint'(DEFAULT_QBLK) - 1) / longint'(DEFAULT_QBLK);
  localparam longint unsigned LMEM_IBUF_BYTES         = longint'(DMA_MT) * longint'(DMA_KT) * 2;
  localparam longint unsigned LMEM_WBUF_BYTES         = longint'(DMA_KT) * longint'((DMA_NT + 1) / 2);
  localparam longint unsigned LMEM_SCBUF_BYTES        = LMEM_GROUPS_TILE * longint'(DMA_NT) * 2;
  localparam longint unsigned LMEM_ZPBUF_BYTES        = LMEM_GROUPS_TILE * longint'(DMA_NT) * 2;
  localparam longint unsigned LMEM_OBUF_BYTES         = longint'(DMA_MT) * longint'(DMA_NT) * 2;

  localparam longint unsigned LMEM_IBUF_ALLOC_BYTES   = ((LMEM_IBUF_BYTES  + LMEM_LAYOUT_ALIGN_BYTES - 1) / LMEM_LAYOUT_ALIGN_BYTES) * LMEM_LAYOUT_ALIGN_BYTES;
  localparam longint unsigned LMEM_WBUF_ALLOC_BYTES   = ((LMEM_WBUF_BYTES  + LMEM_LAYOUT_ALIGN_BYTES - 1) / LMEM_LAYOUT_ALIGN_BYTES) * LMEM_LAYOUT_ALIGN_BYTES;
  localparam longint unsigned LMEM_SCBUF_ALLOC_BYTES  = ((LMEM_SCBUF_BYTES + LMEM_LAYOUT_ALIGN_BYTES - 1) / LMEM_LAYOUT_ALIGN_BYTES) * LMEM_LAYOUT_ALIGN_BYTES;
  localparam longint unsigned LMEM_ZPBUF_ALLOC_BYTES  = ((LMEM_ZPBUF_BYTES + LMEM_LAYOUT_ALIGN_BYTES - 1) / LMEM_LAYOUT_ALIGN_BYTES) * LMEM_LAYOUT_ALIGN_BYTES;
  localparam longint unsigned LMEM_OBUF_ALLOC_BYTES   = ((LMEM_OBUF_BYTES  + LMEM_LAYOUT_ALIGN_BYTES - 1) / LMEM_LAYOUT_ALIGN_BYTES) * LMEM_LAYOUT_ALIGN_BYTES;
  localparam longint unsigned LMEM_REQUIRED_BYTES     = (2 * LMEM_IBUF_ALLOC_BYTES)
                                                      + (2 * LMEM_WBUF_ALLOC_BYTES)
                                                      + (2 * LMEM_SCBUF_ALLOC_BYTES)
                                                      + (2 * LMEM_ZPBUF_ALLOC_BYTES)
                                                      + LMEM_OBUF_ALLOC_BYTES;

  // VX_local_mem is most robust with power-of-two footprint.
  localparam longint unsigned LMEM_SIZE_U = (64'd1 << `CLOG2(LMEM_REQUIRED_BYTES));
  localparam int LMEM_SIZE             = int'(LMEM_SIZE_U);
  localparam int LMEM_NUM_BANKS        = 4;
  localparam int LMEM_WORD_ADDR_WIDTH  = `CLOG2(LMEM_SIZE / LSU_WORD_SIZE);

  // DCACHE model size (byte addressed)
  localparam int DRAM_SIZE       = 100 * 1024 * 1024; // 100MB
  localparam int DRAM_ADDR_WIDTH = `CLOG2(DRAM_SIZE);

  localparam int DCACHE_BYTES = LSU_WORD_SIZE;
  localparam int CACHE_NUM_REQS     = 1;
  localparam int CACHE_MEM_PORTS    = 1;
  localparam int CACHE_SIZE         = 4096;
  localparam int CACHE_LINE_SIZE    = 64;
  localparam int CACHE_NUM_BANKS    = 4;
  localparam int CACHE_NUM_WAYS     = 4;
  localparam int CACHE_CRSQ_SIZE    = 4;
  localparam int CACHE_MSHR_SIZE    = 8;
  localparam int CACHE_MRSQ_SIZE    = 4;
  localparam int CACHE_MREQ_SIZE    = 4;
  localparam int CACHE_CORE_OUT_BUF = 2;
  localparam int CACHE_MEM_OUT_BUF  = 2;
  localparam int CACHE_MEM_TAG_WIDTH= `CACHE_MEM_TAG_WIDTH(CACHE_MSHR_SIZE, CACHE_NUM_BANKS, CACHE_MEM_PORTS, UUID_WIDTH);
  localparam int CACHE_MEM_LATENCY  = 6;

  // MMIO base (job_frontend CFG_BASE_ADDR)
  localparam logic [63:0] GEMM_BASE = `GEMM_REG_BASE_ADDR;

  // Match GEMM node LMEM-facing tag width (includes GEMM internal arb route bits).
  localparam int DMA_TAG_WIDTH = GEMM_LMEM_TAG_WIDTH;
  localparam int G_ARB_NUM_INPUTS = 2;
  localparam int L_ARB_NUM_INPUTS = 3;
  localparam int G_ARB_SEL_BITS   = `ARB_SEL_BITS(G_ARB_NUM_INPUTS, 1);
  localparam int L_ARB_SEL_BITS   = `ARB_SEL_BITS(L_ARB_NUM_INPUTS, 1);
  localparam int G_ARB_TAG_WIDTH  = DMA_TAG_WIDTH + G_ARB_SEL_BITS;
  localparam int L_ARB_TAG_WIDTH  = DMA_TAG_WIDTH + L_ARB_SEL_BITS;

  // TB modes
  localparam int TB_MODE_STREAM = 1;
  localparam int TB_MODE_STREAM_GEMM = 2;

  // Raw instruction opcodes (must match VX_cmd_constructor)
  localparam logic [3:0] RAW_OP_DMA_LOAD         = 4'd1;
  localparam logic [3:0] RAW_OP_DMA_STORE        = 4'd2;
  localparam logic [3:0] RAW_OP_NOTIFY           = 4'd3;
  localparam logic [3:0] RAW_OP_WAIT             = 4'd4;
  localparam logic [3:0] RAW_OP_MXU_LOAD_WEIGHT  = 4'd5;
  localparam logic [3:0] RAW_OP_MXU_LOAD_QPARAM  = 4'd6;
  localparam logic [3:0] RAW_OP_MXU_LOAD_INPUT   = 4'd7;
  localparam logic [3:0] RAW_OP_MXU_STORE_OUTPUT = 4'd8;
  localparam logic [3:0] RAW_OP_CLEAR            = 4'd9;

  localparam logic [63:0] GEMM_STREAM_ADDR = GEMM_BASE + 64'd8;

  // =========================================================================
  // Clock/Reset
  // =========================================================================
  logic clk, reset;
  initial clk = 1'b0;
  always #(PERIOD/2) clk = ~clk;


  integer rpt_fd;
  integer log_fd;

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s", TB_NAME);
    $sformat(fsdb_file_path, "./reports/%s.fsdb", name);
    $sformat(fst_file_path,  "./reports/%s.fst",  name);
    $sformat(log_file_path,  "./logs/%s.log",     name);
    $sformat(rpt_file_path,  "./reports/%s.rpt",  name);

`ifdef VCS
    $fsdbDumpfile(fsdb_file_path);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file_path);
    $dumpvars(0, tb_VX_gemm_node_improve);
`endif

    rpt_fd = $fopen(rpt_file_path, "w");
    log_fd = $fopen(log_file_path, "w");
  end

  // =========================================================================
  // Interfaces
  // =========================================================================
  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) mmio_if[N_MASTER] ();

  // DUT->dma_node MMIO-like LSU interface
  VX_lsu_mem_if #(
    .NUM_LANES(`NUM_LSU_LANES),
    .DATA_SIZE(LSU_WORD_SIZE), //8
    .TAG_WIDTH(LSU_TAG_WIDTH)
  ) dma_if[1] ();

  // DUT LMEM port
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH)
  ) lmem_bus_if ();

  // DUT LMEM tag adaption toward shared LMEM arbiter domain
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) lmem_bus_if_dut_arb ();

  // dma_node dcache/lmem ports
  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) dcache_bus_if ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) lmem_bus_if_dma ();

  // Optional background ports to drive contention/initialization
  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) bg_global_if ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) bg_local_if ();

  // Global path: arbiter -> cache wrap -> backing memory
  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) g_arb_in_if[G_ARB_NUM_INPUTS] ();

  VX_mem_bus_if #(
    .DATA_SIZE(DCACHE_BYTES),
    .TAG_WIDTH(G_ARB_TAG_WIDTH)
  ) g_arb_out_if[1] ();

  VX_mem_bus_if #(
    .DATA_SIZE(CACHE_LINE_SIZE),
    .TAG_WIDTH(CACHE_MEM_TAG_WIDTH)
  ) cache_mem_if[CACHE_MEM_PORTS] ();

  // Local path: arbiter -> local mem
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) l_arb_in_if[L_ARB_NUM_INPUTS] ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(L_ARB_TAG_WIDTH)
  ) l_arb_out_if[1] ();

  // =========================================================================
  // DUT
  // =========================================================================
  VX_gemm_node #(
    .INSTANCE_ID("gemm_node_0"),
    .N_MASTER(N_MASTER),
    .N_CHILDREN(5)
  ) u_dut (
    .clk         (clk),
    .reset       (reset),
    .mmio_if     (mmio_if),
    .dma_if      (dma_if[0]),        // to dma_node below
    .lmem_bus_if (lmem_bus_if)    // DUT direct LMEM access
  );

  // =========================================================================
  // DMA NODE
  // =========================================================================
  VX_dma_node #(
    .INSTANCE_ID("dma_node_tb"),
    .N_MASTER(1),
    .NUM_ENTRIES(4)
  ) u_dma_node (
    .clk          (clk),
    .reset        (reset),
    .mmio_if      (dma_if),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_if_dma)
  );

  // =========================================================================
  // Memory fabric (closer to real Vortex path)
  //   global: dma -> mem_arb -> cache_wrap -> backing memory
  //   local : gemm+dma(+tb init) -> mem_arb -> local_mem
  // =========================================================================

  // DUT LMEM tag-width adaptation into arbiter domain
  assign lmem_bus_if_dut_arb.req_valid       = lmem_bus_if.req_valid;
  assign lmem_bus_if_dut_arb.req_data.rw     = lmem_bus_if.req_data.rw;
  assign lmem_bus_if_dut_arb.req_data.addr   = lmem_bus_if.req_data.addr;
  assign lmem_bus_if_dut_arb.req_data.data   = lmem_bus_if.req_data.data;
  assign lmem_bus_if_dut_arb.req_data.byteen = lmem_bus_if.req_data.byteen;
  assign lmem_bus_if_dut_arb.req_data.flags  = lmem_bus_if.req_data.flags;
  assign lmem_bus_if_dut_arb.req_data.tag    = DMA_TAG_WIDTH'(lmem_bus_if.req_data.tag);
  assign lmem_bus_if.req_ready               = lmem_bus_if_dut_arb.req_ready;

  assign lmem_bus_if.rsp_valid               = lmem_bus_if_dut_arb.rsp_valid;
  assign lmem_bus_if.rsp_data.data           = lmem_bus_if_dut_arb.rsp_data.data;
  assign lmem_bus_if.rsp_data.tag            = GEMM_LMEM_TAG_WIDTH'(lmem_bus_if_dut_arb.rsp_data.tag);
  assign lmem_bus_if_dut_arb.rsp_ready       = lmem_bus_if.rsp_ready;

  `ASSIGN_VX_MEM_BUS_IF(g_arb_in_if[0], dcache_bus_if);
  `ASSIGN_VX_MEM_BUS_IF(g_arb_in_if[1], bg_global_if);

  VX_mem_arb #(
    .NUM_INPUTS  (G_ARB_NUM_INPUTS),
    .NUM_OUTPUTS (1),
    .DATA_SIZE   (DCACHE_BYTES),
    .TAG_WIDTH   (DMA_TAG_WIDTH),
    .TAG_SEL_IDX (DMA_TAG_WIDTH - UUID_WIDTH),
    .REQ_OUT_BUF (2),
    .RSP_OUT_BUF (2),
    .ARBITER     ("P")
  ) u_g_mem_arb (
    .clk        (clk),
    .reset      (reset),
    .bus_in_if  (g_arb_in_if),
    .bus_out_if (g_arb_out_if)
  );

  VX_cache_wrap #(
    .INSTANCE_ID   ("gemm_node_dcache"),
    .CACHE_SIZE    (CACHE_SIZE),
    .LINE_SIZE     (CACHE_LINE_SIZE),
    .NUM_BANKS     (CACHE_NUM_BANKS),
    .NUM_WAYS      (CACHE_NUM_WAYS),
    .WORD_SIZE     (DCACHE_BYTES),
    .NUM_REQS      (CACHE_NUM_REQS),
    .MEM_PORTS     (CACHE_MEM_PORTS),
    .CRSQ_SIZE     (CACHE_CRSQ_SIZE),
    .MSHR_SIZE     (CACHE_MSHR_SIZE),
    .MRSQ_SIZE     (CACHE_MRSQ_SIZE),
    .MREQ_SIZE     (CACHE_MREQ_SIZE),
    .TAG_WIDTH     (G_ARB_TAG_WIDTH),
    .WRITE_ENABLE  (1),
    .WRITEBACK     (0),
    .DIRTY_BYTES   (0),
    .CORE_OUT_BUF  (CACHE_CORE_OUT_BUF),
    .MEM_OUT_BUF   (CACHE_MEM_OUT_BUF)
  ) u_cache (
    .clk        (clk),
    .reset      (reset),
`ifdef PERF_ENABLE
    .cache_perf (),
`endif
    .core_bus_if(g_arb_out_if),
    .mem_bus_if (cache_mem_if)
  );

  `ASSIGN_VX_MEM_BUS_IF(l_arb_in_if[0], lmem_bus_if_dut_arb);
  `ASSIGN_VX_MEM_BUS_IF(l_arb_in_if[1], lmem_bus_if_dma);
  `ASSIGN_VX_MEM_BUS_IF(l_arb_in_if[2], bg_local_if);

  VX_mem_arb #(
    .NUM_INPUTS  (L_ARB_NUM_INPUTS),
    .NUM_OUTPUTS (1),
    .DATA_SIZE   (LSU_WORD_SIZE),
    .TAG_WIDTH   (DMA_TAG_WIDTH),
    .TAG_SEL_IDX (DMA_TAG_WIDTH - UUID_WIDTH),
    .REQ_OUT_BUF (2),
    .RSP_OUT_BUF (2),
    .ARBITER     ("P")
  ) u_l_mem_arb (
    .clk        (clk),
    .reset      (reset),
    .bus_in_if  (l_arb_in_if),
    .bus_out_if (l_arb_out_if)
  );

  VX_local_mem #(
    .INSTANCE_ID ("gemm_node_lmem"),
    .SIZE        (LMEM_SIZE),
    .NUM_REQS    (1),
    .NUM_BANKS   (LMEM_NUM_BANKS),
    .ADDR_WIDTH  (LMEM_WORD_ADDR_WIDTH),
    .WORD_SIZE   (LSU_WORD_SIZE),
    .TAG_WIDTH   (L_ARB_TAG_WIDTH),
    .OUT_BUF     (0)
  ) u_local_mem (
    .clk       (clk),
    .reset     (reset),
`ifdef PERF_ENABLE
    .lmem_perf (),
`endif
    .mem_bus_if(l_arb_out_if)
  );

  // Global memory backend (byte addressed, served by cache line interface)
  byte dram [0:DRAM_SIZE-1];

  typedef struct {
    logic [CACHE_LINE_SIZE*8-1:0]   data;
    logic [CACHE_MEM_TAG_WIDTH-1:0] tag;
    int unsigned                    delay;
  } mem_rsp_entry_t;

  mem_rsp_entry_t mem_rsp_queue[$];

  assign cache_mem_if[0].req_ready = 1'b1;

  always @(posedge clk) begin
    if (reset) begin
      mem_rsp_queue.delete();
      cache_mem_if[0].rsp_valid <= 1'b0;
      cache_mem_if[0].rsp_data  <= '0;
    end else begin
      if (cache_mem_if[0].req_valid && cache_mem_if[0].req_ready) begin
        logic [cache_mem_if[0].ADDR_WIDTH-1:0] line_addr;
        int unsigned base_b;

        line_addr = cache_mem_if[0].req_data.addr;
        base_b = int'(line_addr << $clog2(CACHE_LINE_SIZE));

        if (cache_mem_if[0].req_data.rw) begin
          for (int b = 0; b < CACHE_LINE_SIZE; ++b) begin
            if (cache_mem_if[0].req_data.byteen[b] && ((base_b + b) < DRAM_SIZE))
              dram[base_b + b] = cache_mem_if[0].req_data.data[b*8 +: 8];
          end
        end else begin
          mem_rsp_entry_t e;
          e.tag   = cache_mem_if[0].req_data.tag;
          e.delay = CACHE_MEM_LATENCY;
          for (int b = 0; b < CACHE_LINE_SIZE; ++b) begin
            if ((base_b + b) < DRAM_SIZE)
              e.data[b*8 +: 8] = dram[base_b + b];
            else
              e.data[b*8 +: 8] = 8'h00;
          end
          mem_rsp_queue.push_back(e);
        end
      end

      foreach (mem_rsp_queue[i]) begin
        if (mem_rsp_queue[i].delay > 0)
          mem_rsp_queue[i].delay--;
      end

      if (cache_mem_if[0].rsp_valid && cache_mem_if[0].rsp_ready)
        cache_mem_if[0].rsp_valid <= 1'b0;

      if ((!cache_mem_if[0].rsp_valid || cache_mem_if[0].rsp_ready)
       && (mem_rsp_queue.size() > 0)
       && (mem_rsp_queue[0].delay == 0)) begin
        cache_mem_if[0].rsp_valid     <= 1'b1;
        cache_mem_if[0].rsp_data.data <= mem_rsp_queue[0].data;
        cache_mem_if[0].rsp_data.tag  <= mem_rsp_queue[0].tag;
        mem_rsp_queue.delete(0);
      end
    end
  end

  // =========================================================================
  // MMIO master helpers (lane0 only)
  //  - IMPORTANT: job_desc regs are packed per beat; must support word-in-beat offset.
  // =========================================================================
  initial begin
    mmio_if[0].req_valid = 1'b0;
    mmio_if[0].rsp_ready = 1'b1;

    bg_global_if.req_valid = 1'b0;
    bg_global_if.req_data  = '0;
    bg_global_if.rsp_ready = 1'b1;

    bg_local_if.req_valid = 1'b0;
    bg_local_if.req_data  = '0;
    bg_local_if.rsp_ready = 1'b1;
  end

  logic [LSU_TAG_WIDTH-1:0] mmio_tag_cnt = '0;

  task automatic mmio_read32_word(
    input  logic [63:0] addr,          // byte address of beat
    input  int unsigned word_in_beat,
    output logic [31:0] data
  );
    int unsigned timeout;
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;

    lane_mask = '0;
    lane_addr = '0;
    lane_mask[0] = 1'b1;
    lane_addr[0] = addr >> `CLOG2(LSU_WORD_SIZE);

    @(posedge clk);
    mmio_if[0].req_valid       <= 1'b1;
    mmio_if[0].req_data.rw     <= 1'b0;
    mmio_if[0].req_data.mask   <= lane_mask;
    mmio_if[0].req_data.addr   <= lane_addr;
    mmio_if[0].req_data.data   <= '0;
    mmio_if[0].req_data.byteen <= '0;
    mmio_if[0].req_data.flags  <= '0;
    mmio_if[0].req_data.tag    <= mmio_tag_cnt;
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    // Drop req_valid immediately after the accepted beat so a ready-high sink
    // does not consume the same MMIO request twice on the following cycle.
    mmio_if[0].req_valid <= 1'b0;

    timeout = 0;
    while (!mmio_if[0].rsp_valid) begin
      @(posedge clk);
      timeout++;
      if (timeout > 5000) $fatal(1, "[%0t] MMIO READ timeout addr=0x%h", $time, addr);
    end

    data = mmio_if[0].rsp_data.data[0][word_in_beat*32 +: 32];
    @(posedge clk);
    $display("[%0t] MMIO READ32: addr=0x%h word=%0d data=0x%08h", $time, addr, word_in_beat, data);
  endtask

  task automatic mmio_write64_beat(
    input logic [63:0] addr,
    input logic [63:0] data
  );
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] lane_data;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE-1:0]   lane_byteen;

    lane_mask   = '0;
    lane_addr   = '0;
    lane_data   = '0;
    lane_byteen = '0;

    lane_mask[0]   = 1'b1;
    lane_addr[0]   = addr >> `CLOG2(LSU_WORD_SIZE);
    lane_data[0]   = data;
    lane_byteen[0] = '1;

    @(posedge clk);
    mmio_if[0].req_valid       <= 1'b1;
    mmio_if[0].req_data.rw     <= 1'b1;
    mmio_if[0].req_data.mask   <= lane_mask;
    mmio_if[0].req_data.addr   <= lane_addr;
    mmio_if[0].req_data.data   <= lane_data;
    mmio_if[0].req_data.byteen <= lane_byteen;
    mmio_if[0].req_data.flags  <= '0;
    mmio_if[0].req_data.tag    <= mmio_tag_cnt;
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    // Drop req_valid immediately after the accepted beat so a ready-high sink
    // does not consume the same MMIO request twice on the following cycle.
    mmio_if[0].req_valid <= 1'b0;

    $display("[%0t] MMIO WRITE64: addr=0x%h data=0x%016h", $time, addr, data);
  endtask

  function automatic logic [63:0] make_raw_notify_word(
    input logic        set_mode,
    input logic [31:0] value,
    input logic [4:0]  reg_id
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[41]    = set_mode;
      word[40:9]  = value;
      word[8:4]   = reg_id;
      word[3:0]   = RAW_OP_NOTIFY;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_wait_word(
    input logic [31:0] value,
    input logic [4:0]  reg_id
  );
    logic [63:0] word;
    begin
      word       = '0;
      word[40:9] = value;
      word[8:4]  = reg_id;
      word[3:0]  = RAW_OP_WAIT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_clear_word();
    logic [63:0] word;
    begin
      word      = '0;
      word[3:0] = RAW_OP_CLEAR;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word0(
    input logic [23:0] tmem_base,
    input logic [35:0] dram_base,
    input logic [3:0]  raw_op
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[63:40] = tmem_base;
      word[39:4]  = dram_base;
      word[3:0]   = raw_op;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word1(
    input logic [15:0] tmem_stride,
    input logic [15:0] dram_stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[47:32] = tmem_stride;
      word[31:16] = dram_stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_dma_word2(input logic [31:0] seg_size);
    logic [63:0] word;
    begin
      word       = '0;
      word[31:0] = seg_size;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_weight_word(
    input logic        wtrans,
    input logic        reg_idx,
    input logic [15:0] bound,
    input logic [15:0] stride,
    input logic [23:0] tmem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[61]    = wtrans;
      word[60]    = reg_idx;
      word[59:44] = bound;
      word[43:28] = stride;
      word[27:4]  = tmem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_WEIGHT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_qparam_word0(
    input logic [23:0] mxu_base,
    input logic [23:0] tmem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[51:28] = mxu_base;
      word[27:4]  = tmem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_QPARAM;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_qparam_word1(
    input logic [15:0] tmem_stride,
    input logic [15:0] mxu_stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[47:32] = tmem_stride;
      word[31:16] = mxu_stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_input_word0(
    input logic        is_accum,
    input logic        is_last,
    input logic        wreg_idx,
    input logic        sreg_idx,
    input logic        zreg_idx,
    input logic        qdir,
    input logic [23:0] tmem_base,
    input logic [23:0] acc_mem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[57]    = is_accum;
      word[56]    = is_last;
      word[55]    = wreg_idx;
      word[54]    = sreg_idx;
      word[53]    = zreg_idx;
      word[52]    = qdir;
      word[51:28] = tmem_base;
      word[27:4]  = acc_mem_base;
      word[3:0]   = RAW_OP_MXU_LOAD_INPUT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_load_input_word1(
    input logic [31:0] acc_cnt,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[63:32] = acc_cnt;
      word[31:16] = stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_store_output_word0(
    input logic [23:0] tmem_base,
    input logic [23:0] acc_mem_base
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[51:28] = tmem_base;
      word[27:4]  = acc_mem_base;
      word[3:0]   = RAW_OP_MXU_STORE_OUTPUT;
      return word;
    end
  endfunction

  function automatic logic [63:0] make_raw_mxu_store_output_word1(
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    logic [63:0] word;
    begin
      word        = '0;
      word[31:16] = stride;
      word[15:0]  = bound;
      return word;
    end
  endfunction

  task automatic frontend_stream_alloc(output logic alloc_ok);
    logic [31:0] r;
    begin
      mmio_read32_word(GEMM_BASE + 64'(0), 0, r);
      alloc_ok = r[0];
      $display("[%0t] STREAM ALLOC: ok=%0d r=0x%08h", $time, alloc_ok, r);
    end
  endtask

  task automatic frontend_stream_send_word(input logic [63:0] inst_word);
    begin
      mmio_write64_beat(GEMM_STREAM_ADDR, inst_word);
      $display("[%0t] STREAM INST: word=0x%016h opcode=%0d", $time, inst_word, inst_word[3:0]);
    end
  endtask

  task automatic frontend_stream_send_dma_cmd(
    input logic [3:0]  raw_op,
    input logic [63:0] tmem_base,
    input logic [63:0] dram_base,
    input logic [15:0] tmem_stride,
    input logic [15:0] dram_stride,
    input logic [15:0] bound,
    input logic [31:0] seg_size
  );
    begin
      frontend_stream_send_word(make_raw_dma_word0(tmem_base[23:0], dram_base[35:0], raw_op));
      frontend_stream_send_word(make_raw_dma_word1(tmem_stride, dram_stride, bound));
      frontend_stream_send_word(make_raw_dma_word2(seg_size));
    end
  endtask

  task automatic frontend_stream_send_mxu_weight_cmd(
    input logic        wtrans,
    input logic        reg_idx,
    input logic [15:0] bound,
    input logic [15:0] stride,
    input logic [63:0] tmem_base
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_weight_word(wtrans, reg_idx, bound, stride, tmem_base[23:0])
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_qparam_cmd(
    input logic [63:0] mxu_base,
    input logic [63:0] tmem_base,
    input logic [15:0] tmem_stride,
    input logic [15:0] mxu_stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_qparam_word0(mxu_base[23:0], tmem_base[23:0])
      );
      frontend_stream_send_word(
        make_raw_mxu_load_qparam_word1(tmem_stride, mxu_stride, bound)
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_input_cmd(
    input logic        is_accum,
    input logic        is_last,
    input logic        wreg_idx,
    input logic        sreg_idx,
    input logic        zreg_idx,
    input logic        qdir,
    input logic [63:0] tmem_base,
    input logic [63:0] acc_mem_base,
    input logic [31:0] acc_cnt,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_load_input_word0(
          is_accum, is_last, wreg_idx, sreg_idx, zreg_idx, qdir, tmem_base[23:0], acc_mem_base[23:0]
        )
      );
      frontend_stream_send_word(
        make_raw_mxu_load_input_word1(acc_cnt, stride, bound)
      );
    end
  endtask

  task automatic frontend_stream_send_mxu_store_output_cmd(
    input logic [63:0] tmem_base,
    input logic [63:0] acc_mem_base,
    input logic [15:0] stride,
    input logic [15:0] bound
  );
    begin
      frontend_stream_send_word(
        make_raw_mxu_store_output_word0(tmem_base[23:0], acc_mem_base[23:0])
      );
      frontend_stream_send_word(
        make_raw_mxu_store_output_word1(stride, bound)
      );
    end
  endtask

  task automatic wait_frontend_occupied(
    input logic expected_occupied,
    input int unsigned timeout_cycles = 1000
  );
    int unsigned timeout;
    begin
      timeout = 0;
      while (u_dut.u_gemm_job_frontend.occupied_q !== expected_occupied) begin
        @(posedge clk);
        timeout++;
        if (timeout > timeout_cycles) begin
          $fatal(1, "[%0t] frontend occupied timeout: expected=%0d got=%0d",
                 $time, expected_occupied, u_dut.u_gemm_job_frontend.occupied_q);
        end
      end
    end
  endtask

  task automatic wait_sync_reg_value(
    input int unsigned reg_id,
    input logic [31:0] expected_value,
    input int unsigned timeout_cycles = 100000
  );
    int unsigned timeout;
    begin
      timeout = 0;
      while (u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_id] !== expected_value) begin
        @(posedge clk);
        timeout++;
        if (timeout > timeout_cycles) begin
          $fatal(1, "[%0t] sync reg timeout: reg=%0d expected=0x%08h got=0x%08h",
                 $time, reg_id, expected_value,
                 u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[reg_id]);
        end
      end
    end
  endtask

  // =========================================================================
  // Reset/init
  // =========================================================================
  function automatic logic [bg_local_if.ADDR_WIDTH-1:0] to_local_addr(input logic [63:0] byte_addr);
    return bg_local_if.ADDR_WIDTH'(byte_addr >> $clog2(LSU_WORD_SIZE));
  endfunction

  task automatic lmem_bg_write_word(
    input logic [63:0] byte_addr,
    input logic [LSU_WORD_SIZE*8-1:0] data,
    input logic [LSU_WORD_SIZE-1:0] byteen
  );
    int guard;
    begin
      bg_local_if.req_data        = '0;
      bg_local_if.req_data.rw     = 1'b1;
      bg_local_if.req_data.addr   = to_local_addr(byte_addr);
      bg_local_if.req_data.byteen = byteen;
      bg_local_if.req_data.data   = data;
      bg_local_if.req_data.flags  = '0;
      bg_local_if.req_data.tag    = '0;

      @(negedge clk);
      bg_local_if.req_valid = 1'b1;
      guard = 0;
      while (!(bg_local_if.req_valid && bg_local_if.req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 200000)
          $fatal(1, "lmem_bg_write_word timeout waiting req_ready");
      end

      @(negedge clk);
      bg_local_if.req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic clear_lmem();
    logic [LSU_WORD_SIZE*8-1:0] zero_data;
    logic [LSU_WORD_SIZE-1:0]   full_byteen;
    begin
      zero_data   = '0;
      full_byteen = '1;
      for (longint unsigned addr = 0; addr < longint'(LMEM_SIZE); addr += LSU_WORD_SIZE)
        lmem_bg_write_word(addr[63:0], zero_data, full_byteen);
    end
  endtask

  task automatic init_memories();
    for (int i = 0; i < DRAM_SIZE; i++) dram[i] = 8'h00;
    clear_lmem();
  endtask

  task automatic apply_reset();
    reset = 1'b1;
    repeat (10) @(posedge clk);
    reset = 1'b0;
    repeat (10) @(posedge clk);
  endtask

  // =========================================================================
  // Helpers: FP16/INT4 packing into dram
  // =========================================================================
  function automatic logic [7:0] pack_int4_pair(input logic [3:0] lo, input logic [3:0] hi);
    return {hi, lo};
  endfunction

  function automatic longint unsigned align_up(
    input longint unsigned value,
    input longint unsigned alignment
  );
    if (alignment == 0) begin
      align_up = value;
    end else begin
      align_up = ((value + alignment - 1) / alignment) * alignment;
    end
  endfunction

  // =========================================================================
  // Test: end-to-end one GEMM
  // =========================================================================
  // Auto layout base/alignment
  localparam longint unsigned AUTO_DRAM_BASE = 64'h0000_0000_0010_0000;
  localparam longint unsigned AUTO_LMEM_BASE = 64'h0000_0000_0000_0000;
  localparam longint unsigned ADDR_ALIGN_BYTES = LMEM_LAYOUT_ALIGN_BYTES;

  localparam longint unsigned DRAM_LIMIT = longint'(DRAM_SIZE);
  localparam longint unsigned LMEM_LIMIT = longint'(LMEM_SIZE);

  // data generators
  logic [FP16_WIDTH-1:0] input_mat [0:fpint_emul::MAX_M*fpint_emul::MAX_K-1];
  logic [3:0]            weight_mat[0:fpint_emul::MAX_K*fpint_emul::MAX_N-1];
  logic [FP16_WIDTH-1:0] scale_vec [0:fpint_emul::MAX_N-1];
  logic [15:0]           zp_vec    [0:fpint_emul::MAX_N-1];

  logic [fpint_emul::IN_WIDTH-1:0] ref_input[fpint_emul::MAX_M*fpint_emul::MAX_K];
  logic [fpint_emul::MAX_W_WIDTH-1:0] ref_weight[fpint_emul::MAX_K*fpint_emul::MAX_N];
  logic [fpint_emul::S_WIDTH-1:0] ref_scale[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::Z_WIDTH-1:0] ref_zero[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::O_WIDTH-1:0] ref_output[fpint_emul::MAX_M*fpint_emul::MAX_N];
  logic [fpint_emul::P_WIDTH-1:0] ref_psum[fpint_emul::MAX_M*fpint_emul::MAX_N];

  task automatic build_test_vectors(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans = 0,
    input int test_qdir = 0,
    input int input_random_type=0,
    input int weight_random_type=0,
    input int scale_random_type=0,
    input int zp_random_type=0
  );
    int groups_total;
    if ((test_m <= 0) || (test_m > fpint_emul::MAX_M))
      $fatal(1, "Invalid M=%0d (max=%0d)", test_m, fpint_emul::MAX_M);
    if ((test_n <= 0) || (test_n > fpint_emul::MAX_N))
      $fatal(1, "Invalid N=%0d (max=%0d)", test_n, fpint_emul::MAX_N);
    if ((test_k <= 0) || (test_k > fpint_emul::MAX_K))
      $fatal(1, "Invalid K=%0d (max=%0d)", test_k, fpint_emul::MAX_K);
    if (test_qblk <= 0)
      $fatal(1, "Invalid QBLK=%0d", test_qblk);
    if ((test_wtrans != 0) && (test_wtrans != 1))
      $fatal(1, "Invalid WTRANS=%0d", test_wtrans);
    groups_total = (test_k + test_qblk - 1) / test_qblk;

    for (int m = 0; m < test_m; m++) begin
      for (int k = 0; k < test_k; k++) begin
        shortreal v;
        if(input_random_type == 0) begin
          v = shortreal'(1.0);
        end else if(input_random_type == 1) begin
          v = shortreal'(1.0 + ((m+k) % 7));
        end else if(input_random_type == 2) begin
          v = shortreal'(((m*test_k+k) % 5 - 2.0));
        end else begin
          v = shortreal'(1.0);
        end
        input_mat[m*test_k + k] = cf_math_util_pkg::fp32_val_to_fp16_bit(v);
        ref_input[m*test_k + k] = input_mat[m*test_k + k];
      end
    end
    for (int k = 0; k < test_k; k++) begin
      for (int n = 0; n < test_n; n++) begin
        int w;
        if(weight_random_type == 0) begin
          w = 1;
        end else if(weight_random_type == 1) begin
          w = ((k*test_n + n) % 7) - 3; // -3..3
        end else if(weight_random_type == 2) begin
          w = ((k*test_n + n) % 15) - 7; // -7..7
        end else begin
          w = 1;
        end
        weight_mat[k*test_n + n] = w[3:0];
        ref_weight[k*test_n + n] = signed'(w[3:0]);
      end
    end
    for (int n = 0; n < test_n; n++) begin
      shortreal v;
      int       z;
      if(scale_random_type == 0) begin
        v = shortreal'(1.0);
      end else if(scale_random_type == 1) begin
        v = shortreal'(1.0 + (n % 7));
      end else if(scale_random_type == 2) begin
        v = shortreal'(((n*5) % 11 - 5.0));
      end else begin
        v = shortreal'(1.0);
      end

      if(zp_random_type == 0) begin
        z = 2;
      end else if(zp_random_type == 1) begin
        z = (n % 7) - 3; // -3..3
      end else if(zp_random_type == 2) begin
         z = (n % 15) - 7; // -7..7
      end else begin
        z = 2;
      end

      scale_vec[n] = cf_math_util_pkg::fp32_val_to_fp16_bit(v);
      zp_vec[n]    = z[15:0];
    end

    if (test_qdir == 0) begin
      // QCOL: ref_scale/ref_zero in [KG, N] layout
      for (int kg = 0; kg < groups_total; kg++) begin
        for (int n = 0; n < test_n; n++) begin
          int idx_kg_n;
          idx_kg_n = kg * test_n + n;
          ref_scale[idx_kg_n] = scale_vec[n];
          ref_zero[idx_kg_n]  = zp_vec[n];
        end
      end
    end else begin
      // QROW: ref_scale/ref_zero in [K, NG] layout
      // scale_vec[n] / zp_vec[n] are per-N-group values
      int ng_total;
      ng_total = (test_n + test_qblk - 1) / test_qblk;
      for (int k = 0; k < test_k; k++) begin
        for (int ng = 0; ng < ng_total; ng++) begin
          int idx_k_ng;
          idx_k_ng = k * ng_total + ng;
          // Use scale_vec[ng] as all K rows share same per-group scale
          ref_scale[idx_k_ng] = scale_vec[ng];
          ref_zero[idx_k_ng]  = zp_vec[ng];
        end
      end
    end

    fpint_emul::fpint_gemm_ref(
        ref_input,
        ref_weight,
        ref_scale,
        ref_zero,
        test_m, test_n, test_k,
        ref_output,
        test_qdir ? `QDIR_ROW : `QDIR_COL,
        test_wtrans,
        1'b0,
        '{default: '0},
        test_qblk
    );

    $display("Test Inputs:");
    for (int m = 0; m < test_m; m++) begin
      for (int k = 0; k < test_k; k++) begin
        $write("%0x ", input_mat[m*test_k + k]);
      end
      $write("\n");
    end

    $display("Test Weights:");
    for (int k = 0; k < test_k; k++) begin
      for (int n = 0; n < test_n; n++) begin
        $write("%0x ", weight_mat[k*test_n + n]);
      end
      $write("\n");
    end

    $display("Test Scales:");
    for (int n = 0; n < test_n; n++) begin
      $write("%0x ", scale_vec[n]);
    end
    $write("\n");

    $display("Test ZPs:");
    for (int n = 0; n < test_n; n++) begin
      $write("%0x ", zp_vec[n]);
    end
    $write("\n");

    $display("Reference Output:");
    for (int m = 0; m < test_m; m++) begin
      for (int n = 0; n < test_n; n++) begin
        $write("%0x ", ref_output[m*test_n + n]);
      end
      $write("\n");
    end
  endtask

  task automatic write_dram_inputs_weights_sc_zp(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    input logic [63:0] dram_in_base,
    input logic [63:0] dram_w_base,
    input logic [63:0] dram_sc_base,
    input logic [63:0] dram_zp_base
  );
    byte unsigned buf_in[];
    byte unsigned buf_w[];
    byte unsigned buf_sc[];
    byte unsigned buf_zp[];
    int idx = 0;
    int groups_total;
    logic [3:0] w0, w1;

    if (test_qblk <= 0)
      $fatal(1, "Invalid QBLK=%0d", test_qblk);
    groups_total = (test_k + test_qblk - 1) / test_qblk;

    buf_in = new[test_m*test_k*2];
    for (int i = 0; i < test_m*test_k; i++) begin
      buf_in[i*2 + 0] = input_mat[i][7:0];
      buf_in[i*2 + 1] = input_mat[i][15:8];
    end
    for (int i = 0; i < buf_in.size(); i++)
      if ((dram_in_base + i) < DRAM_SIZE) dram[dram_in_base + i] = buf_in[i];

    if (test_wtrans == 0) begin
      buf_w = new[test_k * ((test_n+1)/2)];
      for (int k = 0; k < test_k; k++) begin
        for (int n = 0; n < test_n; n += 2) begin
          w0 = weight_mat[k*test_n + n];
          w1 = (n+1 < test_n) ? weight_mat[k*test_n + (n+1)] : 4'h0;
          buf_w[idx++] = pack_int4_pair(w0, w1);
        end
      end
    end else begin
      buf_w = new[test_n * ((test_k+1)/2)];
      for (int n = 0; n < test_n; n++) begin
        for (int k = 0; k < test_k; k += 2) begin
          w0 = weight_mat[k*test_n + n];
          w1 = (k+1 < test_k) ? weight_mat[(k+1)*test_n + n] : 4'h0;
          buf_w[idx++] = pack_int4_pair(w0, w1);
        end
      end
    end
    for (int i = 0; i < buf_w.size(); i++)
      if ((dram_w_base + i) < DRAM_SIZE) dram[dram_w_base + i] = buf_w[i];

    if (test_qdir == 0) begin
      // QCOL: scale/zp layout [KG, N]
      buf_sc = new[groups_total*test_n*2];
      for (int kg = 0; kg < groups_total; kg++) begin
        for (int n = 0; n < test_n; n++) begin
          int idx_kg_n;
          idx_kg_n = kg * test_n + n;
          buf_sc[idx_kg_n*2 + 0] = scale_vec[n][7:0];
          buf_sc[idx_kg_n*2 + 1] = scale_vec[n][15:8];
        end
      end

      buf_zp = new[groups_total*test_n*2];
      for (int kg = 0; kg < groups_total; kg++) begin
        for (int n = 0; n < test_n; n++) begin
          int idx_kg_n;
          idx_kg_n = kg * test_n + n;
          buf_zp[idx_kg_n*2 + 0] = zp_vec[n][7:0];
          buf_zp[idx_kg_n*2 + 1] = zp_vec[n][15:8];
        end
      end
    end else begin
      // QROW: scale/zp layout [K, NG]
      int ng_total;
      ng_total = (test_n + test_qblk - 1) / test_qblk;
      buf_sc = new[test_k*ng_total*2];
      for (int k = 0; k < test_k; k++) begin
        for (int ng = 0; ng < ng_total; ng++) begin
          int idx_k_ng;
          idx_k_ng = k * ng_total + ng;
          buf_sc[idx_k_ng*2 + 0] = scale_vec[ng][7:0];
          buf_sc[idx_k_ng*2 + 1] = scale_vec[ng][15:8];
        end
      end

      buf_zp = new[test_k*ng_total*2];
      for (int k = 0; k < test_k; k++) begin
        for (int ng = 0; ng < ng_total; ng++) begin
          int idx_k_ng;
          idx_k_ng = k * ng_total + ng;
          buf_zp[idx_k_ng*2 + 0] = zp_vec[ng][7:0];
          buf_zp[idx_k_ng*2 + 1] = zp_vec[ng][15:8];
        end
      end
    end

    for (int i = 0; i < buf_sc.size(); i++)
      if ((dram_sc_base + i) < DRAM_SIZE) dram[dram_sc_base + i] = buf_sc[i];
    for (int i = 0; i < buf_zp.size(); i++)
      if ((dram_zp_base + i) < DRAM_SIZE) dram[dram_zp_base + i] = buf_zp[i];
  endtask

  task automatic write_dram_stream_qparam_packed_qcol(
    input int test_n,
    input logic [63:0] dram_qparam_base
  );
    byte unsigned buf_qparam[];
    begin
      buf_qparam = new[test_n * 4];
      for (int n = 0; n < test_n; n++) begin
        buf_qparam[n*2 + 0] = scale_vec[n][7:0];
        buf_qparam[n*2 + 1] = scale_vec[n][15:8];
      end
      for (int n = 0; n < test_n; n++) begin
        int base_idx;
        base_idx = (test_n * 2) + (n * 2);
        buf_qparam[base_idx + 0] = zp_vec[n][7:0];
        buf_qparam[base_idx + 1] = zp_vec[n][15:8];
      end
      for (int i = 0; i < buf_qparam.size(); i++)
        if ((dram_qparam_base + i) < DRAM_SIZE) dram[dram_qparam_base + i] = buf_qparam[i];
    end
  endtask

  // =========================================================================
  // Simple output checker
  // =========================================================================
  function automatic logic [15:0] dram_read_u16(input int unsigned addr);
    logic [15:0] x;
    x[7:0]  = (addr < DRAM_SIZE) ? dram[addr] : 8'h00;
    x[15:8] = ((addr+1) < DRAM_SIZE) ? dram[addr+1] : 8'h00;
    return x;
  endfunction

  function automatic int compare_fp16(
      input logic [FP16_WIDTH-1:0] actual,
      input logic [FP16_WIDTH-1:0] expected,
      input shortreal tolerance = 0.01
  );
      shortreal actual_fp, expected_fp, diff;
      actual_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(actual);
      expected_fp = cf_math_util_pkg::fp16_bit_to_fp16_val(expected);

      if (expected_fp == 0.0) begin
          diff = (actual_fp >= 0) ? actual_fp : -actual_fp;
      end else begin
          diff = (actual_fp - expected_fp) / expected_fp;
          diff = (diff >= 0) ? diff : -diff;
      end

      return (diff <= tolerance) ? 1 : 0;
  endfunction

  task automatic check_output(
    input int test_m,
    input int test_n,
    input logic [63:0] dram_out_base
  );
    int mismatch_count = 0;
    int printed = 0;

    $display("=========================================================");
    $display("====                                                 ====");
    $display("====                  OUTPUT CHECK                   ====");
    $display("====                                                 ====");
    $display("=========================================================");
    for (int m = 0; m < test_m; m++) begin
      for (int n = 0; n < test_n; n++) begin
        int unsigned idx = m * test_n + n;
        int unsigned addr = dram_out_base + (idx * 2);
        logic [15:0] got = dram_read_u16(addr);
        logic [15:0] exp = ref_output[idx];
        if (!compare_fp16(got, exp, FP16_TOL)) begin
          mismatch_count++;
          $display("[%0t] OUTPUT_MISMATCH m=%0d n=%0d addr=0x%0h got=0x%04h exp=0x%04h got_f=%f exp_f=%f",
                    $time, m, n, addr, got, exp,
                    cf_math_util_pkg::fp16_bit_to_fp16_val(got),
                    cf_math_util_pkg::fp16_bit_to_fp16_val(exp));
          printed++;
        end
      end
    end

    if (mismatch_count != 0) begin
      $fatal(1, "[%0t] OUTPUT CHECK FAILED: mismatches=%0d", $time, mismatch_count);
    end else begin
      $display("[%0t] OUTPUT CHECK PASSED: compared %0d elements", $time, test_m * test_n);
    end
    $display("=========================================================");
  endtask

  function automatic logic ranges_overlap(
    input longint unsigned a_base,
    input longint unsigned a_size,
    input longint unsigned b_base,
    input longint unsigned b_size
  );
    longint unsigned a_end, b_end;
    begin
      a_end = a_base + a_size;
      b_end = b_base + b_size;
      ranges_overlap = (a_size != 0) && (b_size != 0)
                    && (a_base < b_end)
                    && (b_base < a_end);
    end
  endfunction

  task automatic assert_range_fit(
    input string name,
    input longint unsigned base,
    input longint unsigned size,
    input longint unsigned limit
  );
    if ((base + size) > limit) begin
      $fatal(1, "[%0t] %s out of range: [0x%0h, 0x%0h) limit=0x%0h",
             $time, name, base, base + size, limit);
    end
  endtask

  task automatic assert_no_overlap(
    input string a_name,
    input longint unsigned a_base,
    input longint unsigned a_size,
    input string b_name,
    input longint unsigned b_base,
    input longint unsigned b_size
  );
    if (ranges_overlap(a_base, a_size, b_base, b_size)) begin
      $fatal(1, "[%0t] range overlap: %s [0x%0h,0x%0h) vs %s [0x%0h,0x%0h)",
             $time, a_name, a_base, a_base + a_size, b_name, b_base, b_base + b_size);
    end
  endtask

  task automatic check_tensor_layout(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    input logic [63:0] dram_in_base,
    input logic [63:0] dram_w_base,
    input logic [63:0] dram_sc_base,
    input logic [63:0] dram_zp_base,
    input logic [63:0] dram_out_base,
    input logic [63:0] lmem_ibuf0_base,
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base
  );
    longint unsigned dram_in_bytes;
    longint unsigned dram_w_bytes;
    longint unsigned dram_sc_bytes;
    longint unsigned dram_zp_bytes;
    longint unsigned dram_out_bytes;
    longint unsigned lmem_ibuf_bytes;
    longint unsigned lmem_wbuf_bytes;
    longint unsigned lmem_scbuf_bytes;
    longint unsigned lmem_zpbuf_bytes;
    longint unsigned lmem_obuf_bytes;
    longint unsigned groups_total;
    longint unsigned groups_tile;
    longint unsigned ng_total, ng_tile;
    begin
      if (test_qblk <= 0) begin
        $fatal(1, "[%0t] Invalid QBLK=%0d", $time, test_qblk);
      end
      if ((test_wtrans != 0) && (test_wtrans != 1)) begin
        $fatal(1, "[%0t] Invalid WTRANS=%0d", $time, test_wtrans);
      end
      groups_total = (longint'(test_k) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_total     = (longint'(test_n) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_tile      = (longint'(DMA_NT)  + longint'(test_qblk) - 1) / longint'(test_qblk);

      dram_in_bytes  = longint'(test_m) * longint'(test_k) * 2;
      dram_w_bytes   = (test_wtrans == 0)
                     ? (longint'(test_k) * longint'((test_n + 1) / 2))
                     : (longint'(test_n) * longint'((test_k + 1) / 2));
      if (test_qdir == 0) begin
        dram_sc_bytes  = groups_total * longint'(test_n) * 2;
        dram_zp_bytes  = groups_total * longint'(test_n) * 2;
      end else begin
        dram_sc_bytes  = longint'(test_k) * ng_total * 2;
        dram_zp_bytes  = longint'(test_k) * ng_total * 2;
      end
      dram_out_bytes = longint'(test_m) * longint'(test_n) * 2;

      // LMEM allocation must follow DMA tile footprint, not logical tensor bytes.
      groups_tile      = (longint'(DMA_KT) + longint'(test_qblk) - 1) / longint'(test_qblk);
      lmem_ibuf_bytes  = longint'(DMA_MT) * longint'(DMA_KT) * 2;               // fp16
      lmem_wbuf_bytes  = longint'(DMA_KT) * longint'((DMA_NT + 1) / 2);         // int4 packed
      if (test_qdir == 0) begin
        lmem_scbuf_bytes = groups_tile * longint'(DMA_NT) * 2;                   // QCOL: [groups_tile, NT]
        lmem_zpbuf_bytes = groups_tile * longint'(DMA_NT) * 2;
      end else begin
        lmem_scbuf_bytes = longint'(DMA_KT) * ng_tile * 2;                       // QROW: [KT, NG_tile]
        lmem_zpbuf_bytes = longint'(DMA_KT) * ng_tile * 2;
      end
      lmem_obuf_bytes  = longint'(DMA_MT) * longint'(DMA_NT) * 2;                // fp16 output

      // dram range checks
      assert_range_fit("dram_IN",  dram_in_base,  dram_in_bytes,  DRAM_LIMIT);
      assert_range_fit("dram_W",   dram_w_base,   dram_w_bytes,   DRAM_LIMIT);
      assert_range_fit("dram_SC",  dram_sc_base,  dram_sc_bytes,  DRAM_LIMIT);
      assert_range_fit("dram_ZP",  dram_zp_base,  dram_zp_bytes,  DRAM_LIMIT);
      assert_range_fit("dram_OUT", dram_out_base, dram_out_bytes, DRAM_LIMIT);

      assert_no_overlap("dram_IN",  dram_in_base,  dram_in_bytes,  "dram_W",   dram_w_base,   dram_w_bytes);
      assert_no_overlap("dram_IN",  dram_in_base,  dram_in_bytes,  "dram_SC",  dram_sc_base,  dram_sc_bytes);
      assert_no_overlap("dram_IN",  dram_in_base,  dram_in_bytes,  "dram_ZP",  dram_zp_base,  dram_zp_bytes);
      assert_no_overlap("dram_IN",  dram_in_base,  dram_in_bytes,  "dram_OUT", dram_out_base, dram_out_bytes);
      assert_no_overlap("dram_W",   dram_w_base,   dram_w_bytes,   "dram_SC",  dram_sc_base,  dram_sc_bytes);
      assert_no_overlap("dram_W",   dram_w_base,   dram_w_bytes,   "dram_ZP",  dram_zp_base,  dram_zp_bytes);
      assert_no_overlap("dram_W",   dram_w_base,   dram_w_bytes,   "dram_OUT", dram_out_base, dram_out_bytes);
      assert_no_overlap("dram_SC",  dram_sc_base,  dram_sc_bytes,  "dram_ZP",  dram_zp_base,  dram_zp_bytes);
      assert_no_overlap("dram_SC",  dram_sc_base,  dram_sc_bytes,  "dram_OUT", dram_out_base, dram_out_bytes);
      assert_no_overlap("dram_ZP",  dram_zp_base,  dram_zp_bytes,  "dram_OUT", dram_out_base, dram_out_bytes);

      // LMEM range checks
      assert_range_fit("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  LMEM_LIMIT);
      assert_range_fit("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  LMEM_LIMIT);
      assert_range_fit("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  LMEM_LIMIT);
      assert_range_fit("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  LMEM_LIMIT);
      assert_range_fit("LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes, LMEM_LIMIT);
      assert_range_fit("LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes, LMEM_LIMIT);
      assert_range_fit("LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes, LMEM_LIMIT);
      assert_range_fit("LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes, LMEM_LIMIT);
      assert_range_fit("LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes,  LMEM_LIMIT);

      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_IBUF0", lmem_ibuf0_base, lmem_ibuf_bytes,  "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_IBUF1", lmem_ibuf1_base, lmem_ibuf_bytes,  "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_WBUF0", lmem_wbuf0_base, lmem_wbuf_bytes,  "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  "LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  "LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_WBUF1", lmem_wbuf1_base, lmem_wbuf_bytes,  "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes, "LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes);
      assert_no_overlap("LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes, "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes, "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_SCBUF0", lmem_scbuf0_base, lmem_scbuf_bytes, "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes, "LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes, "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_SCBUF1", lmem_scbuf1_base, lmem_scbuf_bytes, "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes, "LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes);
      assert_no_overlap("LMEM_ZPBUF0", lmem_zpbuf0_base, lmem_zpbuf_bytes, "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);
      assert_no_overlap("LMEM_ZPBUF1", lmem_zpbuf1_base, lmem_zpbuf_bytes, "LMEM_OBUF",  lmem_obuf_base,  lmem_obuf_bytes);

      $display("[%0t] Tensor layout check passed", $time);
    end
  endtask

  task automatic compute_auto_layout(
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    output logic [63:0] dram_in_base,
    output logic [63:0] dram_w_base,
    output logic [63:0] dram_sc_base,
    output logic [63:0] dram_zp_base,
    output logic [63:0] dram_out_base,
    output logic [63:0] lmem_ibuf0_base,
    output logic [63:0] lmem_ibuf1_base,
    output logic [63:0] lmem_wbuf0_base,
    output logic [63:0] lmem_wbuf1_base,
    output logic [63:0] lmem_scbuf0_base,
    output logic [63:0] lmem_scbuf1_base,
    output logic [63:0] lmem_zpbuf0_base,
    output logic [63:0] lmem_zpbuf1_base,
    output logic [63:0] lmem_obuf_base
  );
    longint unsigned cur_dram, cur_lmem;
    longint unsigned dram_in_bytes, dram_w_bytes, dram_sc_bytes, dram_zp_bytes, dram_out_bytes;
    longint unsigned lmem_ibuf_bytes, lmem_wbuf_bytes, lmem_scbuf_bytes, lmem_zpbuf_bytes, lmem_obuf_bytes;
    longint unsigned groups_total;
    longint unsigned groups_tile;
    longint unsigned ng_total, ng_tile;
    begin
      if (test_qblk <= 0) begin
        $fatal(1, "[%0t] Invalid QBLK=%0d", $time, test_qblk);
      end
      if ((test_wtrans != 0) && (test_wtrans != 1)) begin
        $fatal(1, "[%0t] Invalid WTRANS=%0d", $time, test_wtrans);
      end
      groups_total = (longint'(test_k) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_total     = (longint'(test_n) + longint'(test_qblk) - 1) / longint'(test_qblk);
      ng_tile      = (longint'(DMA_NT)  + longint'(test_qblk) - 1) / longint'(test_qblk);

      dram_in_bytes  = longint'(test_m) * longint'(test_k) * 2;
      dram_w_bytes   = (test_wtrans == 0)
                     ? (longint'(test_k) * longint'((test_n + 1) / 2))
                     : (longint'(test_n) * longint'((test_k + 1) / 2));
      if (test_qdir == 0) begin
        // QCOL: [KG, N]
        dram_sc_bytes  = groups_total * longint'(test_n) * 2;
        dram_zp_bytes  = groups_total * longint'(test_n) * 2;
      end else begin
        // QROW: [K, NG]
        dram_sc_bytes  = longint'(test_k) * ng_total * 2;
        dram_zp_bytes  = longint'(test_k) * ng_total * 2;
      end
      dram_out_bytes = longint'(test_m) * longint'(test_n) * 2;

      groups_tile      = (longint'(DMA_KT) + longint'(test_qblk) - 1) / longint'(test_qblk);
      lmem_ibuf_bytes  = longint'(DMA_MT) * longint'(DMA_KT) * 2;
      lmem_wbuf_bytes  = longint'(DMA_KT) * longint'((DMA_NT + 1) / 2);
      if (test_qdir == 0) begin
        // QCOL: [groups_tile, NT]
        lmem_scbuf_bytes = groups_tile * longint'(DMA_NT) * 2;
        lmem_zpbuf_bytes = groups_tile * longint'(DMA_NT) * 2;
      end else begin
        // QROW: [KT, NG_tile]
        lmem_scbuf_bytes = longint'(DMA_KT) * ng_tile * 2;
        lmem_zpbuf_bytes = longint'(DMA_KT) * ng_tile * 2;
      end
      lmem_obuf_bytes  = longint'(DMA_MT) * longint'(DMA_NT) * 2;

      cur_dram = align_up(AUTO_DRAM_BASE, ADDR_ALIGN_BYTES);
      dram_in_base = cur_dram[63:0];
      cur_dram += align_up(dram_in_bytes, ADDR_ALIGN_BYTES);
      dram_w_base = cur_dram[63:0];
      cur_dram += align_up(dram_w_bytes, ADDR_ALIGN_BYTES);
      dram_sc_base = cur_dram[63:0];
      cur_dram += align_up(dram_sc_bytes, ADDR_ALIGN_BYTES);
      dram_zp_base = cur_dram[63:0];
      cur_dram += align_up(dram_zp_bytes, ADDR_ALIGN_BYTES);
      dram_out_base = cur_dram[63:0];

      cur_lmem = align_up(AUTO_LMEM_BASE, ADDR_ALIGN_BYTES);
      lmem_ibuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_ibuf_bytes, ADDR_ALIGN_BYTES);
      lmem_ibuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_ibuf_bytes, ADDR_ALIGN_BYTES);
      lmem_wbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_wbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_wbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_wbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_scbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_scbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_scbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_scbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_zpbuf0_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_zpbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_zpbuf1_base = cur_lmem[63:0];
      cur_lmem += align_up(lmem_zpbuf_bytes, ADDR_ALIGN_BYTES);
      lmem_obuf_base = cur_lmem[63:0];
    end
  endtask

  task automatic run_instruction_stream_smoke(input string case_name);
    logic alloc_ok;
    int unsigned sync_reg_id;
    begin
      sync_reg_id = 3;

      $display("\n[%0t] === RUN STREAM SMOKE: %s ===", $time, case_name);

      apply_reset();
      init_memories();

      frontend_stream_alloc(alloc_ok);
      if (!alloc_ok) begin
        $fatal(1, "[%0t] stream alloc failed at start", $time);
      end
      wait_frontend_occupied(1'b1);

      frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, sync_reg_id[4:0]));
      wait_sync_reg_value(sync_reg_id, 32'd1);

      frontend_stream_send_word(make_raw_wait_word(32'd1, sync_reg_id[4:0]));
      repeat (4) @(posedge clk);

      frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd2, sync_reg_id[4:0]));
      wait_sync_reg_value(sync_reg_id, 32'd3);

      frontend_stream_send_word(make_raw_wait_word(32'd3, sync_reg_id[4:0]));
      repeat (4) @(posedge clk);

      frontend_stream_send_word(make_raw_clear_word());
      wait_frontend_occupied(1'b0);

      frontend_stream_alloc(alloc_ok);
      if (!alloc_ok) begin
        $fatal(1, "[%0t] stream realloc failed after clear", $time);
      end
      wait_frontend_occupied(1'b1);

      frontend_stream_send_word(make_raw_clear_word());
      wait_frontend_occupied(1'b0);

      $display("[%0t] STREAM SMOKE PASSED: sync_reg[%0d]=0x%08h",
               $time, sync_reg_id, u_dut.u_VX_gemm_ctrl.u_VX_gemm_sync.sync_regs[sync_reg_id]);
    end
  endtask

  task automatic run_instruction_stream_gemm_micro(
    input string case_name,
    input int test_m,
    input int test_n,
    input int test_k,
    input int test_qblk,
    input int test_wtrans,
    input int test_qdir,
    input logic [63:0] dram_in_base,
    input logic [63:0] dram_w_base,
    input logic [63:0] dram_sc_base,
    input logic [63:0] dram_zp_base,
    input logic [63:0] dram_out_base,
    input logic [63:0] lmem_ibuf0_base,
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base
  );
    logic alloc_ok;
    int unsigned rid_ld0;
    int unsigned rid_w0;
    int unsigned rid_sz0;
    int unsigned rid_g0;
    int unsigned rid_o0;
    int unsigned rid_st;
    logic [31:0] input_bytes;
    logic [31:0] weight_bytes;
    logic [31:0] qparam_bytes;
    logic [31:0] output_bytes;
    logic [15:0] qparam_src_stride;
    logic [15:0] qparam_dst_stride;
    begin
      rid_ld0 = 0;
      rid_w0  = 2;
      rid_sz0 = 4;
      rid_g0  = 6;
      rid_o0  = 8;
      rid_st  = 10;

      if ((test_m <= 0) || (test_m > DMA_MT))
        $fatal(1, "[%0t] stream GEMM only supports 1 <= M <= %0d (got %0d)", $time, DMA_MT, test_m);
      if (test_n != DMA_MXU_NT)
        $fatal(1, "[%0t] stream GEMM currently requires N=%0d (got %0d)", $time, DMA_MXU_NT, test_n);
      if ((test_k % DMA_MXU_KT != 0) || (test_k <= 0) || (test_k > DMA_KT))
        $fatal(1, "[%0t] stream GEMM requires K to be a multiple of MXU_KT=%0d and <= %0d (got %0d)", $time, DMA_MXU_KT, DMA_KT, test_k);
      if (test_qblk != DMA_MXU_KT)
        $fatal(1, "[%0t] stream GEMM currently requires QBLK=%0d (got %0d)", $time, DMA_MXU_KT, test_qblk);
      if (test_qdir != 0)
        $fatal(1, "[%0t] stream GEMM currently supports QDIR=0 only (got %0d)", $time, test_qdir);
      if ((test_wtrans != 0) && (test_wtrans != 1))
        $fatal(1, "[%0t] invalid WTRANS=%0d", $time, test_wtrans);

      if ((dram_sc_base + 64'(test_n * 4)) > dram_zp_base)
        $fatal(1, "[%0t] packed qparam dram range overlaps next region", $time);
      if ((lmem_scbuf0_base + 64'(test_n * 4)) > lmem_scbuf1_base)
        $fatal(1, "[%0t] packed qparam LMEM range overlaps next region", $time);

      input_bytes  = test_m * test_k * 2;
      weight_bytes = test_k * ((test_n + 1) / 2);
      qparam_bytes = test_n * 4;
      output_bytes = test_m * test_n * 2;
      qparam_src_stride = test_n * 2;
      qparam_dst_stride = DMA_MXU_NT * 4;

      $display("\n[%0t] === RUN STREAM GEMM: %s (M=%0d, N=%0d, K=%0d, WTRANS=%0d) ===",
               $time, case_name, test_m, test_n, test_k, test_wtrans);

      apply_reset();
      init_memories();

      build_test_vectors(
        .test_m(test_m),
        .test_n(test_n),
        .test_k(test_k),
        .test_qblk(test_qblk),
        .test_wtrans(test_wtrans),
        .test_qdir(test_qdir),
        .input_random_type(1),
        .weight_random_type(1),
        .scale_random_type(1),
        .zp_random_type(1)
      );

      check_tensor_layout(
        test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
        dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base,
        lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base,
        lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base
      );

      write_dram_inputs_weights_sc_zp(
        test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
        dram_in_base, dram_w_base, dram_sc_base, dram_zp_base
      );
      write_dram_stream_qparam_packed_qcol(test_n, dram_sc_base);

      frontend_stream_alloc(alloc_ok);
      if (!alloc_ok)
        $fatal(1, "[%0t] stream GEMM alloc failed", $time);
      wait_frontend_occupied(1'b1);

      // ---- Phase 1: DMA LOAD input, weight, qparam → LMEM ----
      $display("[%0t] [PHASE 1] DMA LOAD: input(%0d B), weight(%0d B), qparam(%0d B) → LMEM",
               $time, input_bytes, weight_bytes, qparam_bytes);

      frontend_stream_send_dma_cmd(
        RAW_OP_DMA_LOAD, lmem_ibuf0_base, dram_in_base, 16'd0, 16'd0, 16'd1, input_bytes
      );
      frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));

      frontend_stream_send_dma_cmd(
        RAW_OP_DMA_LOAD, lmem_wbuf0_base, dram_w_base, 16'd0, 16'd0, 16'd1, weight_bytes
      );
      frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));

      frontend_stream_send_dma_cmd(
        RAW_OP_DMA_LOAD, lmem_scbuf0_base, dram_sc_base, 16'd0, 16'd0, 16'd1, qparam_bytes
      );
      frontend_stream_send_word(make_raw_notify_word(1'b0, 32'd1, rid_ld0[4:0]));
      frontend_stream_send_word(make_raw_wait_word(32'd3, rid_ld0[4:0]));

      wait_sync_reg_value(rid_ld0, 32'd3, 50000);
      $display("[%0t] [PHASE 1] DONE - all 3 DMA loads completed (sync_reg[%0d]=3)", $time, rid_ld0);

      // ---- Phase 2-4: K-block iteration (weight load + qparam load + GEMM compute) ----
      begin
        int k_blocks;
        logic [63:0] w_lmem_base;
        logic [63:0] i_src_base;
        logic [15:0] i_src_stride;
        int          w_seg_bytes;

        k_blocks   = test_k / DMA_MXU_KT;
        w_seg_bytes = DMA_MXU_KT * ((test_n + 1) / 2);  // weight bytes per K-block
        i_src_stride = 16'(test_k * 2);                  // row stride in LMEM (full K width)

        $display("[%0t] [PHASE 2-4] K-block loop: k_blocks=%0d, w_seg=%0d B, i_stride=%0d",
                 $time, k_blocks, w_seg_bytes, i_src_stride);

        for (int kb = 0; kb < k_blocks; kb++) begin
          logic is_first, is_last_blk;
          is_first    = (kb == 0);
          is_last_blk = (kb == k_blocks - 1);

          // -- Weight load for this K-block --
          w_lmem_base = lmem_wbuf0_base + 64'(kb * w_seg_bytes);
          $display("[%0t] [K%0d] WEIGHT LOAD: lmem=0x%h (%0d B)", $time, kb, w_lmem_base, w_seg_bytes);

          frontend_stream_send_mxu_weight_cmd(test_wtrans[0], 1'b0, 16'd1, 16'd0, w_lmem_base);
          frontend_stream_send_word(make_raw_notify_word(is_first ? 1'b1 : 1'b0, 32'd1, rid_w0[4:0]));

          // -- Qparam load (only on first K-block; QCOL scale/zp are per-column, not per-K) --
          if (is_first) begin
            $display("[%0t] [K%0d] QPARAM LOAD: src_stride=%0d, dst_stride=%0d", $time, kb, qparam_src_stride, qparam_dst_stride);
            frontend_stream_send_mxu_qparam_cmd(
              64'd0, lmem_scbuf0_base, qparam_src_stride, qparam_dst_stride, 16'd2
            );
            frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_sz0[4:0]));
          end

          // -- Wait for weight (and qparam on first) to complete --
          frontend_stream_send_word(make_raw_wait_word(32'(kb + 1), rid_w0[4:0]));
          if (is_first) begin
            frontend_stream_send_word(make_raw_wait_word(32'd1, rid_sz0[4:0]));
          end

          wait_sync_reg_value(rid_w0, 32'(kb + 1), 50000);
          $display("[%0t] [K%0d] WEIGHT DONE (sync_reg[%0d]=%0d)", $time, kb, rid_w0, kb + 1);

          // -- GEMM compute for this K-block --
          i_src_base = lmem_ibuf0_base + 64'(kb * DMA_MXU_KT * 2);
          $display("[%0t] [K%0d] GEMM COMPUTE: is_accum=%0d, is_last=%0d, src=0x%h, stride=%0d, bound=%0d, acc_cnt=%0d",
                   $time, kb, !is_first, is_last_blk, i_src_base, i_src_stride, test_m, test_m);

          frontend_stream_send_mxu_input_cmd(
            !is_first,     // is_accum: 0 for first block, 1 for rest
            is_last_blk,   // is_last: 1 only for final block
            1'b0, 1'b0, 1'b0, 1'b0,  // wreg/sreg/zreg_idx=0, qdir=0
            i_src_base, 64'd0,
            test_m,        // acc_cnt = M rows per K-block
            i_src_stride,  // stride between rows in LMEM
            16'(test_m)    // bound = M rows
          );
          frontend_stream_send_word(make_raw_notify_word(is_first ? 1'b1 : 1'b0, 32'd1, rid_g0[4:0]));
          frontend_stream_send_word(make_raw_wait_word(32'(kb + 1), rid_g0[4:0]));

          wait_sync_reg_value(rid_g0, 32'(kb + 1), 100000);
          $display("[%0t] [K%0d] GEMM DONE (sync_reg[%0d]=%0d)", $time, kb, rid_g0, kb + 1);
        end

        $display("[%0t] [PHASE 2-4] ALL K-blocks completed", $time);
      end

      // ---- Debug: dump GEMM pipeline valid counters (snapshot) ----
      $display("[%0t] [DEBUG] Pipeline valid counts:", $time);
      $display("  in_pipe_valid_out count (input beats arrived): check waveform");
      $display("  prealigner_out_valid:  %0d", u_dut.u_VX_gemm_unit.prealigner_out_valid);
      $display("  merger_in_valid:       %0d", u_dut.u_VX_gemm_unit.merger_in_valid);
      $display("  merger_out_valid:      %0d", u_dut.u_VX_gemm_unit.merger_out_valid);
      $display("  int2fp_valid[0]:       %0d", u_dut.u_VX_gemm_unit.int2fp_output_valid[0]);
      $display("  scaler_out_valid[0]:   %0d", u_dut.u_VX_gemm_unit.scaler_output_valid[0]);
      $display("  final_scaler_valid:    %0d", u_dut.u_VX_gemm_unit.final_scaler_output_valid);
      $display("  acc_mem_wr_en[0..3]:   %b %b %b %b",
               u_dut.u_VX_gemm_unit.acc_mem_wr_en[0],
               u_dut.u_VX_gemm_unit.acc_mem_wr_en[1],
               u_dut.u_VX_gemm_unit.acc_mem_wr_en[2],
               u_dut.u_VX_gemm_unit.acc_mem_wr_en[3]);

      // ---- Debug: dump GEMM unit state and acc_mem ----
      begin
        $display("[%0t] [DEBUG] GEMM unit state: state=%0d, is_load=%0d, acc_wr_state=%0d, acc_wr_cnt=%0d",
                 $time,
                 u_dut.u_VX_gemm_unit.state,
                 u_dut.u_VX_gemm_unit.gemm_unit_ctrl.is_load,
                 u_dut.u_VX_gemm_unit.acc_mem_accum_wr_state,
                 u_dut.u_VX_gemm_unit.acc_mem_accum_wr_cnt);
        $display("[%0t] [DEBUG] acc_mem wr_addr=0x%h, wr_bank=%0d",
                 $time,
                 u_dut.u_VX_gemm_unit.acc_mem_accum_wr_addr,
                 u_dut.u_VX_gemm_unit.acc_mem_accum_wr_bank);
        // Dump first entries from all 4 banks at depth 0
        $display("  bank0 d0 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[0].VX_sp_ram_instance.ram[0][31:0]);
        $display("  bank1 d0 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[1].VX_sp_ram_instance.ram[0][31:0]);
        $display("  bank2 d0 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[2].VX_sp_ram_instance.ram[0][31:0]);
        $display("  bank3 d0 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[3].VX_sp_ram_instance.ram[0][31:0]);
        // bank0 depth 0-3
        $display("  bank0 d1 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[0].VX_sp_ram_instance.ram[1][31:0]);
        $display("  bank0 d2 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[0].VX_sp_ram_instance.ram[2][31:0]);
        $display("  bank0 d3 = 0x%08h", u_dut.u_VX_gemm_unit.gen_acc_mem[0].VX_sp_ram_instance.ram[3][31:0]);
      end

      // ---- Phase 5: MXU store output (accumulator → LMEM) ----
      $display("[%0t] [PHASE 5] MXU STORE OUTPUT → LMEM: obuf_base=0x%h", $time, lmem_obuf_base);

      frontend_stream_send_mxu_store_output_cmd(lmem_obuf_base, 64'd0, 16'd0, 16'(test_m));
      frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_o0[4:0]));
      frontend_stream_send_word(make_raw_wait_word(32'd1, rid_o0[4:0]));

      wait_sync_reg_value(rid_o0, 32'd1, 50000);
      $display("[%0t] [PHASE 5] DONE - output stored to LMEM (sync_reg[%0d]=1)", $time, rid_o0);

      // ---- Phase 6: DMA STORE output (LMEM → DRAM) ----
      $display("[%0t] [PHASE 6] DMA STORE: LMEM → DRAM (%0d B), dram_out=0x%h", $time, output_bytes, dram_out_base);

      frontend_stream_send_dma_cmd(
        RAW_OP_DMA_STORE, lmem_obuf_base, dram_out_base, 16'd0, 16'd0, 16'd1, output_bytes
      );
      frontend_stream_send_word(make_raw_notify_word(1'b1, 32'd1, rid_st[4:0]));
      frontend_stream_send_word(make_raw_wait_word(32'd1, rid_st[4:0]));

      wait_sync_reg_value(rid_st, 32'd1, 50000);
      $display("[%0t] [PHASE 6] DONE - output written to DRAM (sync_reg[%0d]=1)", $time, rid_st);

      // ---- Cleanup ----
      frontend_stream_send_word(make_raw_clear_word());
      wait_frontend_occupied(1'b0, 20000);

      repeat (50) @(posedge clk);
      check_output(test_m, test_n, dram_out_base);

      $display("[%0t] STREAM GEMM PASSED: M=%0d N=%0d K=%0d WTRANS=%0d",
               $time, test_m, test_n, test_k, test_wtrans);
    end
  endtask

  // =========================================================================
  // Main sim
  // =========================================================================
  initial begin
    string case_name;
    int tb_mode;
    int test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir;
    logic [63:0] dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base;
    logic [63:0] lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base;
    logic [63:0] lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base;

    $timeformat(-9, 0, "ns", 0);
    reset = 1'b0;

    if (!$value$plusargs("TB_MODE=%d", tb_mode))
      tb_mode = TB_MODE_STREAM_GEMM;
    if (!$value$plusargs("M=%d", test_m))
      test_m = DEFAULT_M_TEST;
    if (!$value$plusargs("N=%d", test_n))
      test_n = DEFAULT_N_TEST;
    if (!$value$plusargs("K=%d", test_k))
      test_k = DEFAULT_K_TEST;
    if (!$value$plusargs("QBLK=%d", test_qblk))
      test_qblk = DEFAULT_QBLK;
    if (!$value$plusargs("WTRANS=%d", test_wtrans))
      test_wtrans = 0;
    if (!$value$plusargs("QDIR=%d", test_qdir))
      test_qdir = 0;
    if (!$value$plusargs("TEST=%s", case_name)) begin
      if (tb_mode == TB_MODE_STREAM) begin
        $sformat(case_name, "stream_smoke");
      end else begin
        $sformat(case_name, "stream_gemm_M%0d_N%0d_K%0d_WT%0d", test_m, test_n, test_k, test_wtrans);
      end
    end

    if (tb_mode == TB_MODE_STREAM) begin
      $display("[%0t] STREAM_TEST_CFG | {name=%s, TB_MODE=%0d}", $time, case_name, tb_mode);
      run_instruction_stream_smoke(case_name);
    end else begin
      compute_auto_layout(
        test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
        dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base,
        lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base,
        lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base
      );

      $display("[%0t] STREAM_GEMM_TEST_CFG | {name=%s, TB_MODE=%0d, M=%0d, N=%0d, K=%0d, QBLK=%0d, WTRANS=%0d, QDIR=%0d}",
               $time, case_name, tb_mode, test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir);
      run_instruction_stream_gemm_micro(
        case_name,
        test_m, test_n, test_k, test_qblk, test_wtrans, test_qdir,
        dram_in_base, dram_w_base, dram_sc_base, dram_zp_base, dram_out_base,
        lmem_ibuf0_base, lmem_ibuf1_base, lmem_wbuf0_base, lmem_wbuf1_base,
        lmem_scbuf0_base, lmem_scbuf1_base, lmem_zpbuf0_base, lmem_zpbuf1_base, lmem_obuf_base
      );
    end

    $display("[%0t] TB completed", $time);

`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

  parameter longint unsigned SIM_TIMEOUT_NS = 10_000_000; // 예: 2ms = 2,000,000ns

  // =========================================================================
  // Global watchdog timeout (hard stop)
  //  - Stops simulation even if TB is stuck waiting for req_ready/rsp_valid, etc.
  // =========================================================================
  // Real-time acc_mem write monitor (first 3 writes only)
  // =========================================================================
  int acc_wr_mon_cnt = 0;
  always @(posedge clk) begin
    if (!reset && u_dut.u_VX_gemm_unit.acc_mem_wr_en[0] && acc_wr_mon_cnt < 3) begin
      $display("[%0t] [ACC_WR_MON] bank0 wr: addr=0x%h depth=%0d data[31:0]=0x%08h data[63:32]=0x%08h",
               $time,
               u_dut.u_VX_gemm_unit.acc_mem_accum_wr_addr,
               u_dut.u_VX_gemm_unit.acc_mem_wr_depth_addr[0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[0][31:0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[0][63:32]);
      acc_wr_mon_cnt++;
    end
    if (!reset && u_dut.u_VX_gemm_unit.acc_mem_wr_en[1] && acc_wr_mon_cnt < 3) begin
      $display("[%0t] [ACC_WR_MON] bank1 wr: addr=0x%h depth=%0d data[31:0]=0x%08h data[63:32]=0x%08h",
               $time,
               u_dut.u_VX_gemm_unit.acc_mem_accum_wr_addr,
               u_dut.u_VX_gemm_unit.acc_mem_wr_depth_addr[1],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[1][31:0],
               u_dut.u_VX_gemm_unit.acc_mem_in_data[1][63:32]);
      acc_wr_mon_cnt++;
    end
  end

  // Monitor input pipe valid
  int in_pipe_cnt = 0;
  always @(posedge clk) begin
    if (!reset && u_dut.u_VX_gemm_unit.in_pipe_valid_out && in_pipe_cnt < 3) begin
      $display("[%0t] [IN_PIPE_MON] input beat %0d: data[15:0]=0x%04h data[31:16]=0x%04h",
               $time, in_pipe_cnt,
               u_dut.u_VX_gemm_unit.in_pipe_data_out[15:0],
               u_dut.u_VX_gemm_unit.in_pipe_data_out[31:16]);
      in_pipe_cnt++;
    end
  end

  // =========================================================================
  initial begin : watchdog_timeout
    // wait until time passes (absolute sim time)
//     #(SIM_TIMEOUT_NS);

//     $display("[WATCHDOG][%0t] Global timeout reached (%0d ns). Forcing finish.",
//              $time, SIM_TIMEOUT_NS);
//     $display("UUID_WIDTH: %0d", UUID_WIDTH);  //44

// `ifdef VCS
//     // stop dumping so fsdb closes cleanly
//     $fsdbDumpoff();
// `else
//     $dumpoff();
// `endif

//     // If you prefer fatal instead of finish, change to $fatal(1,...)
//     $finish;
  end
endmodule

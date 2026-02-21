`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_node
  import VX_gpu_pkg::*;
  import fpint_emul::*;
  import cf_math_pkg::*;
();

  // =========================================================================
  // Params
  // =========================================================================
  parameter string TB_NAME  = "tb_VX_gemm_node";
  parameter string OBJ      = "func";
  parameter int    PERIOD   = 10;
  parameter int    N_MASTER = 1;

  // compare tolerance
  localparam real FP16_TOL = 0.01; // ~1.5 LSB of FP16

  // smoke sizes
  localparam int M_TEST = 2;
  localparam int N_TEST = 32;
  localparam int K_TEST = 32;

  localparam int FP16_WIDTH   = 16;

  // LMEM model
  localparam int LMEM_SIZE       = 1024 * 1024;
  localparam int LMEM_ADDR_WIDTH = `CLOG2(LMEM_SIZE);

  // DCACHE model size (byte addressed)
  localparam int DMEM_SIZE       = 7 * 1024 * 1024; // 7MB
  localparam int DMEM_ADDR_WIDTH = `CLOG2(DMEM_SIZE);

  // MMIO base (job_frontend CFG_BASE_ADDR)
  localparam logic [63:0] GEMM_BASE = `GEMM_REG_BASE_ADDR;

  // dma_node tag width (tb_VX_gemm_dma_ctrl_with_dma 에서 45 사용)
  localparam int DMA_TAG_WIDTH = 45;

  // job_frontend params (must match DUT instantiation)
  localparam int JOB_NUM_ENTRIES = 4;
  localparam int JOB_NUM_REGS32  = 33;

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
    $dumpvars(0, tb_VX_gemm_node);
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
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_bus_if ();

  // dma_node dcache/lmem ports
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) dcache_bus_if ();

  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(DMA_TAG_WIDTH)
  ) lmem_bus_if_dma ();

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
  // Job regs indices (your map, 0..32)
  // =========================================================================
  localparam int REG_CONTROL             =  0;
  localparam int REG_INPUT_BASE_LO       =  1;
  localparam int REG_INPUT_BASE_HI       =  2;
  localparam int REG_WEIGHT_BASE_LO      =  3;
  localparam int REG_WEIGHT_BASE_HI      =  4;
  localparam int REG_OUTPUT_BASE_LO      =  5;
  localparam int REG_OUTPUT_BASE_HI      =  6;
  localparam int REG_SCALE_BASE_LO       =  7;
  localparam int REG_SCALE_BASE_HI       =  8;
  localparam int REG_ZP_BASE_LO          =  9;
  localparam int REG_ZP_BASE_HI          = 10;

  localparam int REG_LMEM_IBUF0_LO       = 11;
  localparam int REG_LMEM_IBUF0_HI       = 12;
  localparam int REG_LMEM_IBUF1_LO       = 13;
  localparam int REG_LMEM_IBUF1_HI       = 14;
  localparam int REG_LMEM_WBUF0_LO       = 15;
  localparam int REG_LMEM_WBUF0_HI       = 16;
  localparam int REG_LMEM_WBUF1_LO       = 17;
  localparam int REG_LMEM_WBUF1_HI       = 18;
  localparam int REG_LMEM_SCBUF0_LO      = 19;
  localparam int REG_LMEM_SCBUF0_HI      = 20;
  localparam int REG_LMEM_SCBUF1_LO      = 21;
  localparam int REG_LMEM_SCBUF1_HI      = 22;
  localparam int REG_LMEM_ZPBUF0_LO      = 23;
  localparam int REG_LMEM_ZPBUF0_HI      = 24;
  localparam int REG_LMEM_ZPBUF1_LO      = 25;
  localparam int REG_LMEM_ZPBUF1_HI      = 26;
  localparam int REG_LMEM_OBUF_LO        = 27;
  localparam int REG_LMEM_OBUF_HI        = 28;

  localparam int REG_M                   = 29;
  localparam int REG_N                   = 30;
  localparam int REG_K                   = 31;
  localparam int REG_QBLK                = 32;

  // =========================================================================
  // Shared LMEM byte array (DUT + dma_node share)
  // =========================================================================
  logic [7:0] lmem [0:LMEM_SIZE-1];

  // =========================================================================
  // LMEM slave model #1 : DUT lmem_bus_if
  // =========================================================================
  logic                        lmem_req_pending;
  logic [LMEM_ADDR_WIDTH-1:0]  lmem_req_addr;
  logic                        lmem_req_rw;
  logic [LSU_WORD_SIZE*8-1:0]  lmem_req_data;
  logic [LSU_WORD_SIZE-1:0]    lmem_req_byteen;
  logic [LMEM_TAG_WIDTH-1:0]   lmem_req_tag;

  always @(posedge clk) begin
    if (reset) begin
      lmem_bus_if.rsp_valid <= 1'b0;
      lmem_req_pending      <= 1'b0;
    end else begin
      if (lmem_bus_if.req_valid && lmem_bus_if.req_ready && !lmem_req_pending) begin
        lmem_req_pending <= 1'b1;
        lmem_req_addr    <= lmem_bus_if.req_data.addr[31:0] * LSU_WORD_SIZE; // beat->byte
        lmem_req_rw      <= lmem_bus_if.req_data.rw;
        lmem_req_data    <= lmem_bus_if.req_data.data;
        lmem_req_byteen  <= lmem_bus_if.req_data.byteen;
        lmem_req_tag     <= lmem_bus_if.req_data.tag;

        if (lmem_bus_if.req_data.rw) begin
          int i;
          int unsigned baddr;
          for (i = 0; i < LSU_WORD_SIZE; i++) begin
            if (lmem_bus_if.req_data.byteen[i]) begin
              baddr = (lmem_bus_if.req_data.addr[31:0] * LSU_WORD_SIZE + i);
              if (baddr < LMEM_SIZE)
                lmem[baddr] <= lmem_bus_if.req_data.data[i*8 +: 8];
            end
          end
        end
      end

      if (lmem_req_pending && !lmem_bus_if.rsp_valid) begin
        if (!lmem_req_rw) begin
          lmem_bus_if.rsp_valid    <= 1'b1;
          lmem_bus_if.rsp_data.tag <= lmem_req_tag;
          for (int i = 0; i < LSU_WORD_SIZE; i++) begin
            if ((lmem_req_addr + i) < LMEM_SIZE)
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= lmem[lmem_req_addr + i];
            else
              lmem_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          lmem_req_pending <= 1'b0;
        end
      end

      if (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready) begin
        lmem_bus_if.rsp_valid <= 1'b0;
        lmem_req_pending      <= 1'b0;
      end
    end
  end

  assign lmem_bus_if.req_ready = !lmem_req_pending;

  // =========================================================================
  // LMEM slave model #2 : dma_node lmem_bus_if_dma (TAG_WIDTH=DMA_TAG_WIDTH)
  // =========================================================================
  logic                        lmem2_req_pending;
  logic [LMEM_ADDR_WIDTH-1:0]  lmem2_req_addr;
  logic                        lmem2_req_rw;
  logic [LSU_WORD_SIZE*8-1:0]  lmem2_req_data;
  logic [LSU_WORD_SIZE-1:0]    lmem2_req_byteen;
  logic [DMA_TAG_WIDTH-1:0]    lmem2_req_tag;

  always @(posedge clk) begin
    if (reset) begin
      lmem_bus_if_dma.rsp_valid <= 1'b0;
      lmem2_req_pending         <= 1'b0;
    end else begin
      if (lmem_bus_if_dma.req_valid && lmem_bus_if_dma.req_ready && !lmem2_req_pending) begin
        lmem2_req_pending <= 1'b1;
        lmem2_req_addr    <= lmem_bus_if_dma.req_data.addr[31:0] * LSU_WORD_SIZE; // beat->byte
        lmem2_req_rw      <= lmem_bus_if_dma.req_data.rw;
        lmem2_req_data    <= lmem_bus_if_dma.req_data.data;
        lmem2_req_byteen  <= lmem_bus_if_dma.req_data.byteen;
        lmem2_req_tag     <= lmem_bus_if_dma.req_data.tag;

        if (lmem_bus_if_dma.req_data.rw) begin
          int i;
          int unsigned baddr;
          for (i = 0; i < LSU_WORD_SIZE; i++) begin
            if (lmem_bus_if_dma.req_data.byteen[i]) begin
              baddr = (lmem_bus_if_dma.req_data.addr[31:0] * LSU_WORD_SIZE + i);
              if (baddr < LMEM_SIZE)
                lmem[baddr] <= lmem_bus_if_dma.req_data.data[i*8 +: 8];
            end
          end
        end
      end

      if (lmem2_req_pending && !lmem_bus_if_dma.rsp_valid) begin
        if (!lmem2_req_rw) begin
          lmem_bus_if_dma.rsp_valid    <= 1'b1;
          lmem_bus_if_dma.rsp_data.tag <= lmem2_req_tag;
          for (int i = 0; i < LSU_WORD_SIZE; i++) begin
            if ((lmem2_req_addr + i) < LMEM_SIZE)
              lmem_bus_if_dma.rsp_data.data[i*8 +: 8] <= lmem[lmem2_req_addr + i];
            else
              lmem_bus_if_dma.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          lmem2_req_pending <= 1'b0;
        end
      end

      if (lmem_bus_if_dma.rsp_valid && lmem_bus_if_dma.rsp_ready) begin
        lmem_bus_if_dma.rsp_valid <= 1'b0;
        lmem2_req_pending         <= 1'b0;
      end
    end
  end

  assign lmem_bus_if_dma.req_ready = !lmem2_req_pending;

  // =========================================================================
  // DCACHE model (dma_node.dcache_bus_if): 1-cycle latency for reads, posted writes
  // =========================================================================
  byte dmem [0:DMEM_SIZE-1];

  assign dcache_bus_if.req_ready = 1'b1;

  typedef struct packed {
    logic                               valid;
    logic                               rw;
    logic [dcache_bus_if.ADDR_WIDTH-1:0] addr_beats;
    logic [LSU_WORD_SIZE*8-1:0]         data;
    logic [LSU_WORD_SIZE-1:0]           byteen;
    logic [DMA_TAG_WIDTH-1:0]           tag;
  } dpend_t;

  dpend_t d_pend;

  always @(posedge clk) begin
    if (reset) begin
      dcache_bus_if.rsp_valid <= 1'b0;
      dcache_bus_if.rsp_data  <= '0;
      d_pend.valid            <= 1'b0;
    end else begin
      if (dcache_bus_if.rsp_valid && dcache_bus_if.rsp_ready)
        dcache_bus_if.rsp_valid <= 1'b0;

      d_pend.valid <= 1'b0;
      if (dcache_bus_if.req_valid && dcache_bus_if.req_ready) begin
        d_pend.valid      <= 1'b1;
        d_pend.rw         <= dcache_bus_if.req_data.rw;
        d_pend.addr_beats <= dcache_bus_if.req_data.addr;
        d_pend.data       <= dcache_bus_if.req_data.data;
        d_pend.byteen     <= dcache_bus_if.req_data.byteen;
        d_pend.tag        <= dcache_bus_if.req_data.tag;
      end

      if (d_pend.valid) begin
        int unsigned base_b;
        base_b = (int'(d_pend.addr_beats) << $clog2(LSU_WORD_SIZE));

        if (!d_pend.rw) begin
          dcache_bus_if.rsp_valid    <= 1'b1;
          dcache_bus_if.rsp_data.tag <= d_pend.tag;
          for (int i = 0; i < LSU_WORD_SIZE; i++) begin
            if ((base_b + i) < DMEM_SIZE)
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= dmem[base_b + i];
            else
              dcache_bus_if.rsp_data.data[i*8 +: 8] <= 8'h00;
          end
        end else begin
          for (int i = 0; i < LSU_WORD_SIZE; i++) begin
            if (d_pend.byteen[i] && ((base_b + i) < DMEM_SIZE))
              dmem[base_b + i] <= d_pend.data[i*8 +: 8];
          end
        end
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
  end

  int unsigned mmio_tag_cnt = 0;

  task automatic mmio_write32_word(
    input logic [63:0] addr,           // byte address of beat
    input int unsigned word_in_beat,    // 0..(LSU_WORD_SIZE/4-1)
    input logic [31:0] data
  );
    logic [`NUM_LSU_LANES-1:0] lane_mask;
    logic [`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-`CLOG2(LSU_WORD_SIZE)-1:0] lane_addr;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE*8-1:0] lane_data;
    logic [`NUM_LSU_LANES-1:0][LSU_WORD_SIZE-1:0]   lane_byteen;

    lane_mask   = '0;
    lane_addr   = '0;
    lane_data   = '0;
    lane_byteen = '0;

    lane_mask[0] = 1'b1;
    lane_addr[0] = addr >> `CLOG2(LSU_WORD_SIZE);

    // place 32b at word slot
    lane_data[0][word_in_beat*32 +: 32] = data;
    lane_byteen[0][word_in_beat*4  +: 4] = 4'b1111;

    @(posedge clk);
    mmio_if[0].req_valid       <= 1'b1;
    mmio_if[0].req_data.rw     <= 1'b1;
    mmio_if[0].req_data.mask   <= lane_mask;
    mmio_if[0].req_data.addr   <= lane_addr;
    mmio_if[0].req_data.data   <= lane_data;
    mmio_if[0].req_data.byteen <= lane_byteen;
    mmio_if[0].req_data.flags  <= '0;
    mmio_if[0].req_data.tag    <= mmio_tag_cnt[LSU_TAG_WIDTH-1:0];
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    @(posedge clk);
    mmio_if[0].req_valid <= 1'b0;

    $display("[%0t] MMIO WRITE32: addr=0x%h word=%0d data=0x%08h", $time, addr, word_in_beat, data);
  endtask

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
    mmio_if[0].req_data.tag    <= mmio_tag_cnt[LSU_TAG_WIDTH-1:0];
    mmio_if[0].rsp_ready       <= 1'b1;
    mmio_tag_cnt++;

    while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) @(posedge clk);
    @(posedge clk);
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

  // =========================================================================
  // Job frontend address mapping helpers (must mirror VX_job_desc_mmio_regs)
  // =========================================================================
  localparam int WORDS_PER_BEAT = (LSU_WORD_SIZE / 4);
  localparam int NUM_BEATS      = (JOB_NUM_REGS32 + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;
  localparam int ENTRY_STRIDE_B = NUM_BEATS * LSU_WORD_SIZE;
  localparam int GLOBAL_ALLOC_B = LSU_WORD_SIZE; // mmio_if.DATA_SIZE

  function automatic logic [63:0] job_entry_beat_addr(
    input int unsigned eid,
    input int unsigned beat_idx
  );
    return GEMM_BASE
         + GLOBAL_ALLOC_B
         + 64'(eid) * 64'(ENTRY_STRIDE_B)
         + 64'(beat_idx) * 64'(LSU_WORD_SIZE);
  endfunction

  task automatic job_write_reg32(input int unsigned eid, input int unsigned r32, input logic [31:0] data);
    int unsigned beat_idx     = r32 / WORDS_PER_BEAT;
    int unsigned word_in_beat = r32 % WORDS_PER_BEAT;
    logic [63:0]  addr        = job_entry_beat_addr(eid, beat_idx);
    mmio_write32_word(addr, word_in_beat, data);
  endtask

  task automatic job_read_reg32(input int unsigned eid, input int unsigned r32, output logic [31:0] data);
    int unsigned beat_idx     = r32 / WORDS_PER_BEAT;
    int unsigned word_in_beat = r32 % WORDS_PER_BEAT;
    logic [63:0]  addr        = job_entry_beat_addr(eid, beat_idx);
    mmio_read32_word(addr, word_in_beat, data);
  endtask

  task automatic job_write_reg64(input int unsigned eid, input int unsigned reg_lo_idx, input logic [63:0] value);
    job_write_reg32(eid, reg_lo_idx,     value[31:0]);
    job_write_reg32(eid, reg_lo_idx + 1, value[63:32]);
  endtask

  // Alloc register read (lane0 only)
  task automatic job_alloc(output int unsigned eid, output int unsigned generation);
    logic [31:0] r;
    mmio_read32_word(GEMM_BASE + 64'(0), 0, r); // alloc beat word0
    if (r[0] != 1'b1) $fatal(1, "[%0t] JOB ALLOC failed r=0x%08h", $time, r);
    eid = r[`JOB_MMIO_ALLOC_ENTRY_LSB +: `JOB_MMIO_ALLOC_ENTRY_BITS]; // ENTRYID_W=8 in your frontend path (safe for <=255)
    generation = r[`JOB_MMIO_ALLOC_GEN_LSB +: `JOB_MMIO_ALLOC_GEN_BITS];
    if (eid >= JOB_NUM_ENTRIES) $fatal(1, "alloc returned eid=%0d out of range", eid);
    $display("[%0t] JOB ALLOC ok: eid=%0d generation=%0d (r=0x%08h)", $time, eid, generation, r);
  endtask

  // =========================================================================
  // Reset/init
  // =========================================================================
  task automatic init_memories();
    for (int i = 0; i < LMEM_SIZE; i++) lmem[i] = 8'h00;
    for (int i = 0; i < DMEM_SIZE; i++) dmem[i] = 8'h00;
  endtask

  task automatic apply_reset();
    reset = 1'b1;
    repeat (10) @(posedge clk);
    reset = 1'b0;
    repeat (10) @(posedge clk);
  endtask

  // =========================================================================
  // Helpers: FP16/INT4 packing into DMEM
  // =========================================================================
  function automatic logic [7:0] pack_int4_pair(input logic [3:0] lo, input logic [3:0] hi);
    return {hi, lo};
  endfunction

  // =========================================================================
  // Test: end-to-end one GEMM
  // =========================================================================
  // Global memory layout (byte addr in DCACHE model dmem[])
  localparam logic [63:0] GMEM_IN_BASE    = 64'h0000_0000_0010_0000;
  localparam logic [63:0] GMEM_W_BASE     = 64'h0000_0000_0020_0000;
  localparam logic [63:0] GMEM_SC_BASE    = 64'h0000_0000_0030_0000;
  localparam logic [63:0] GMEM_ZP_BASE    = 64'h0000_0000_0040_0000;
  localparam logic [63:0] GMEM_OUT_BASE   = 64'h0000_0000_0050_0000;

  // LMEM buffer layout (byte addr in LMEM)
  localparam logic [63:0] LMEM_IBUF0_BASE = 64'h0000_0000_0000_0000;
  localparam logic [63:0] LMEM_IBUF1_BASE = 64'h0000_0000_0002_0000;
  localparam logic [63:0] LMEM_WBUF0_BASE = 64'h0000_0000_0004_0000;
  localparam logic [63:0] LMEM_WBUF1_BASE = 64'h0000_0000_0006_0000;
  localparam logic [63:0] LMEM_SCBUF0_BASE= 64'h0000_0000_0008_0000;
  localparam logic [63:0] LMEM_SCBUF1_BASE= 64'h0000_0000_0009_0000;
  localparam logic [63:0] LMEM_ZPBUF0_BASE= 64'h0000_0000_000A_0000;
  localparam logic [63:0] LMEM_ZPBUF1_BASE= 64'h0000_0000_000B_0000;
  localparam logic [63:0] LMEM_OBUF_BASE  = 64'h0000_0000_000C_0000;

  localparam longint unsigned GMEM_IN_BYTES  = longint'(M_TEST) * longint'(K_TEST) * 2;
  localparam longint unsigned GMEM_W_BYTES   = longint'(K_TEST) * longint'((N_TEST + 1) / 2);
  localparam longint unsigned GMEM_SC_BYTES  = longint'(N_TEST) * 2;
  localparam longint unsigned GMEM_ZP_BYTES  = longint'(N_TEST) * 2;
  localparam longint unsigned GMEM_OUT_BYTES = longint'(M_TEST) * longint'(N_TEST) * 2;
  localparam longint unsigned DMEM_LIMIT     = longint'(DMEM_SIZE);

  localparam longint unsigned LMEM_IBUF_BYTES  = longint'(M_TEST) * longint'(K_TEST) * 2;
  localparam longint unsigned LMEM_WBUF_BYTES  = longint'(K_TEST) * longint'((N_TEST + 1) / 2);
  localparam longint unsigned LMEM_SCBUF_BYTES = longint'(N_TEST) * 2;
  localparam longint unsigned LMEM_ZPBUF_BYTES = longint'(N_TEST) * 2;
  localparam longint unsigned LMEM_OBUF_BYTES  = longint'(M_TEST) * longint'(N_TEST) * 2;
  localparam longint unsigned LMEM_LIMIT       = longint'(LMEM_SIZE);

  // data generators
  logic [FP16_WIDTH-1:0] input_mat [0:M_TEST*K_TEST-1];
  logic [3:0]            weight_mat[0:K_TEST*N_TEST-1];
  logic [FP16_WIDTH-1:0] scale_vec [0:N_TEST-1];
  logic [15:0]           zp_vec    [0:N_TEST-1];

  logic [fpint_emul::IN_WIDTH-1:0] ref_input[fpint_emul::MAX_M*fpint_emul::MAX_K];
  logic [fpint_emul::MAX_W_WIDTH-1:0] ref_weight[fpint_emul::MAX_K*fpint_emul::MAX_N];
  logic [fpint_emul::S_WIDTH-1:0] ref_scale[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::Z_WIDTH-1:0] ref_zero[fpint_emul::MAX_KG*fpint_emul::MAX_N];
  logic [fpint_emul::O_WIDTH-1:0] ref_output[fpint_emul::MAX_M*fpint_emul::MAX_N];
  logic [fpint_emul::P_WIDTH-1:0] ref_psum[fpint_emul::MAX_M*fpint_emul::MAX_N];

  task automatic build_test_vectors();
    for (int m = 0; m < M_TEST; m++) begin
      for (int k = 0; k < K_TEST; k++) begin
        // shortreal v = shortreal'(1.0 + ((m+k) % 7));
        shortreal v = shortreal'(((m*K_TEST+k) % 5 - 2.0));
        // shortreal v = shortreal'(1.0);
        input_mat[m*K_TEST + k] = cf_math_pkg::fp32_val_to_fp16_bit(v);
        ref_input[m*K_TEST + k] = input_mat[m*K_TEST + k];
      end
    end
    for (int k = 0; k < K_TEST; k++) begin
      for (int n = 0; n < N_TEST; n++) begin
        int w = ((k*N_TEST + n) % 13) - 6; // -6..6
        // int w = ((k*3 + n*5) % 13) - 6; // -6..6
        // int w = 1;
        weight_mat[k*N_TEST + n] = w[3:0];
        ref_weight[k*N_TEST + n] = signed'(w[3:0]);
      end
    end
    for (int n = 0; n < N_TEST; n++) begin
      // shortreal v = shortreal'((n % 7) - 3.0);
      shortreal v = shortreal'(1.0);

      // int z = (n*5 % 13) - 6; // -6..6
      int z = 2;

      scale_vec[n] = cf_math_pkg::fp32_val_to_fp16_bit(v);
      ref_scale[n] = scale_vec[n];

      zp_vec[n]    = z[15:0];
      ref_zero[n]  = zp_vec[n];
    end

    fpint_emul::fpint_gemm_ref(
        ref_input,
        ref_weight,
        ref_scale,
        ref_zero,
        M_TEST, N_TEST, K_TEST,
        ref_output,
        `QDIR_COL,
        fpint_emul::WNOTRANS,
        1'b0
    );

    $display("Test Inputs:");
    for (int m = 0; m < M_TEST; m++) begin
      for (int k = 0; k < K_TEST; k++) begin
        $write("%0x ", input_mat[m*K_TEST + k]);
      end
      $write("\n");
    end

    $display("Test Weights:");
    for (int k = 0; k < K_TEST; k++) begin
      for (int n = 0; n < N_TEST; n++) begin
        $write("%0x ", weight_mat[k*N_TEST + n]);
      end
      $write("\n");
    end

    $display("Test Scales:");
    for (int n = 0; n < N_TEST; n++) begin
      $write("%0x ", scale_vec[n]);
    end
    $write("\n");

    $display("Test ZPs:");
    for (int n = 0; n < N_TEST; n++) begin
      $write("%0x ", zp_vec[n]);
    end
    $write("\n");

    $display("Reference Output:");
    for (int m = 0; m < M_TEST; m++) begin
      for (int n = 0; n < N_TEST; n++) begin
        $write("%0x ", ref_output[m*N_TEST + n]);
      end
      $write("\n");
    end
  endtask

  task automatic write_gmem_inputs_weights_sc_zp();
    byte unsigned buf_in[];
    byte unsigned buf_w[];
    byte unsigned buf_sc[];
    byte unsigned buf_zp[];
    int idx = 0;
    logic [3:0] w0, w1;

    buf_in = new[M_TEST*K_TEST*2];
    for (int i = 0; i < M_TEST*K_TEST; i++) begin
      buf_in[i*2 + 0] = input_mat[i][7:0];
      buf_in[i*2 + 1] = input_mat[i][15:8];
    end
    for (int i = 0; i < buf_in.size(); i++)
      if ((GMEM_IN_BASE + i) < DMEM_SIZE) dmem[GMEM_IN_BASE + i] = buf_in[i];

    buf_w = new[K_TEST * ((N_TEST+1)/2)];
    for (int k = 0; k < K_TEST; k++) begin
      for (int n = 0; n < N_TEST; n += 2) begin
        w0 = weight_mat[k*N_TEST + n];
        w1 = (n+1 < N_TEST) ? weight_mat[k*N_TEST + (n+1)] : 4'h0;
        buf_w[idx++] = pack_int4_pair(w0, w1);
      end
    end
    for (int i = 0; i < buf_w.size(); i++)
      if ((GMEM_W_BASE + i) < DMEM_SIZE) dmem[GMEM_W_BASE + i] = buf_w[i];

    buf_sc = new[N_TEST*2];
    for (int n = 0; n < N_TEST; n++) begin
      buf_sc[n*2 + 0] = scale_vec[n][7:0];
      buf_sc[n*2 + 1] = scale_vec[n][15:8];
    end
    for (int i = 0; i < buf_sc.size(); i++)
      if ((GMEM_SC_BASE + i) < DMEM_SIZE) dmem[GMEM_SC_BASE + i] = buf_sc[i];

    buf_zp = new[N_TEST*2];
    for (int n = 0; n < N_TEST; n++) begin
      buf_zp[n*2 + 0] = zp_vec[n][7:0];
      buf_zp[n*2 + 1] = zp_vec[n][15:8];
    end
    for (int i = 0; i < buf_zp.size(); i++)
      if ((GMEM_ZP_BASE + i) < DMEM_SIZE) dmem[GMEM_ZP_BASE + i] = buf_zp[i];
  endtask

  // =========================================================================
  // Program GEMM node job regs via job_frontend
  // =========================================================================
  int unsigned job_eid;
  int unsigned job_gen;

  task automatic program_job_regs(input int unsigned eid);
    // globals
    job_write_reg64(eid, REG_INPUT_BASE_LO,  GMEM_IN_BASE);
    job_write_reg64(eid, REG_WEIGHT_BASE_LO, GMEM_W_BASE);
    job_write_reg64(eid, REG_OUTPUT_BASE_LO, GMEM_OUT_BASE);
    job_write_reg64(eid, REG_SCALE_BASE_LO,  GMEM_SC_BASE);
    job_write_reg64(eid, REG_ZP_BASE_LO,     GMEM_ZP_BASE);

    // lmem buffers
    job_write_reg64(eid, REG_LMEM_IBUF0_LO,   LMEM_IBUF0_BASE);
    job_write_reg64(eid, REG_LMEM_IBUF1_LO,   LMEM_IBUF1_BASE);
    job_write_reg64(eid, REG_LMEM_WBUF0_LO,   LMEM_WBUF0_BASE);
    job_write_reg64(eid, REG_LMEM_WBUF1_LO,   LMEM_WBUF1_BASE);
    job_write_reg64(eid, REG_LMEM_SCBUF0_LO,  LMEM_SCBUF0_BASE);
    job_write_reg64(eid, REG_LMEM_SCBUF1_LO,  LMEM_SCBUF1_BASE);
    job_write_reg64(eid, REG_LMEM_ZPBUF0_LO,  LMEM_ZPBUF0_BASE);
    job_write_reg64(eid, REG_LMEM_ZPBUF1_LO,  LMEM_ZPBUF1_BASE);
    job_write_reg64(eid, REG_LMEM_OBUF_LO,    LMEM_OBUF_BASE);

    // sizes
    job_write_reg32(eid, REG_M, M_TEST);
    job_write_reg32(eid, REG_N, N_TEST);
    job_write_reg32(eid, REG_K, K_TEST);
    job_write_reg32(eid, REG_QBLK, 32);

    // CONTROL.valid(bit0)=1 (start)
    job_write_reg32(eid, REG_CONTROL, 32'h1);
  endtask

  task automatic wait_job_done(input int unsigned eid, input int unsigned generation);
    logic [31:0] ctrl;
    int unsigned timeout = 0;
    int unsigned curr_gen=0;
    $display("[%0t] wait_job_done: polling entry%0d generation%0d CONTROL.valid(bit0)==0", $time, eid, generation);
    do begin
      job_read_reg32(eid, REG_CONTROL, ctrl);
      @(posedge clk);
      timeout++;
      if (timeout > 100000) begin
        $fatal(1, "[%0t] wait_job_done timeout (ctrl=0x%08h)", $time, ctrl);
      end
      curr_gen = ctrl[`JOB_MMIO_CTRL_GEN_LSB +: `JOB_MMIO_GEN_W];
    end while (generation >= curr_gen && ctrl[`JOB_MMIO_CTRL_VALID_BIT] == 1'b1);
    $display("[%0t] JOB DONE detected for entry%0d", $time, eid);
  endtask

  // =========================================================================
  // Simple output checker
  // =========================================================================
  function automatic logic [15:0] dmem_read_u16(input int unsigned addr);
    logic [15:0] x;
    x[7:0]  = (addr < DMEM_SIZE) ? dmem[addr] : 8'h00;
    x[15:8] = ((addr+1) < DMEM_SIZE) ? dmem[addr+1] : 8'h00;
    return x;
  endfunction

  function automatic int compare_fp16(
      input logic [FP16_WIDTH-1:0] actual,
      input logic [FP16_WIDTH-1:0] expected,
      input shortreal tolerance = 0.01
  );
      shortreal actual_fp, expected_fp, diff;
      actual_fp = cf_math_pkg::fp16_bit_to_fp16_val(actual);
      expected_fp = cf_math_pkg::fp16_bit_to_fp16_val(expected);

      if (expected_fp == 0.0) begin
          diff = (actual_fp >= 0) ? actual_fp : -actual_fp;
      end else begin
          diff = (actual_fp - expected_fp) / expected_fp;
          diff = (diff >= 0) ? diff : -diff;
      end

      return (diff <= tolerance) ? 1 : 0;
  endfunction

  task automatic check_output();
    int mismatch_count = 0;
    int printed = 0;

    $display("=== OUTPUT CHECK ===");
    for (int m = 0; m < M_TEST; m++) begin
      for (int n = 0; n < N_TEST; n++) begin
        int unsigned idx = m * N_TEST + n;
        int unsigned addr = GMEM_OUT_BASE + (idx * 2);
        logic [15:0] got = dmem_read_u16(addr);
        logic [15:0] exp = ref_output[idx];
        if (!compare_fp16(got, exp, FP16_TOL)) begin
          mismatch_count++;
          if (printed < 16) begin
            $display("[%0t] OUTPUT_MISMATCH m=%0d n=%0d addr=0x%0h got=0x%04h exp=0x%04h got_f=%f exp_f=%f",
                     $time, m, n, addr, got, exp,
                     cf_math_pkg::fp16_bit_to_fp16_val(got),
                     cf_math_pkg::fp16_bit_to_fp16_val(exp));
            printed++;
          end
        end
      end
    end

    if (mismatch_count != 0) begin
      $fatal(1, "[%0t] OUTPUT CHECK FAILED: mismatches=%0d", $time, mismatch_count);
    end else begin
      $display("[%0t] OUTPUT CHECK PASSED: compared %0d elements", $time, M_TEST * N_TEST);
    end
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

  task automatic check_tensor_layout();
    begin
      // GMEM range checks
      assert_range_fit("GMEM_IN",  GMEM_IN_BASE,  GMEM_IN_BYTES,  DMEM_LIMIT);
      assert_range_fit("GMEM_W",   GMEM_W_BASE,   GMEM_W_BYTES,   DMEM_LIMIT);
      assert_range_fit("GMEM_SC",  GMEM_SC_BASE,  GMEM_SC_BYTES,  DMEM_LIMIT);
      assert_range_fit("GMEM_ZP",  GMEM_ZP_BASE,  GMEM_ZP_BYTES,  DMEM_LIMIT);
      assert_range_fit("GMEM_OUT", GMEM_OUT_BASE, GMEM_OUT_BYTES, DMEM_LIMIT);

      assert_no_overlap("GMEM_IN",  GMEM_IN_BASE,  GMEM_IN_BYTES,  "GMEM_W",   GMEM_W_BASE,   GMEM_W_BYTES);
      assert_no_overlap("GMEM_IN",  GMEM_IN_BASE,  GMEM_IN_BYTES,  "GMEM_SC",  GMEM_SC_BASE,  GMEM_SC_BYTES);
      assert_no_overlap("GMEM_IN",  GMEM_IN_BASE,  GMEM_IN_BYTES,  "GMEM_ZP",  GMEM_ZP_BASE,  GMEM_ZP_BYTES);
      assert_no_overlap("GMEM_IN",  GMEM_IN_BASE,  GMEM_IN_BYTES,  "GMEM_OUT", GMEM_OUT_BASE, GMEM_OUT_BYTES);
      assert_no_overlap("GMEM_W",   GMEM_W_BASE,   GMEM_W_BYTES,   "GMEM_SC",  GMEM_SC_BASE,  GMEM_SC_BYTES);
      assert_no_overlap("GMEM_W",   GMEM_W_BASE,   GMEM_W_BYTES,   "GMEM_ZP",  GMEM_ZP_BASE,  GMEM_ZP_BYTES);
      assert_no_overlap("GMEM_W",   GMEM_W_BASE,   GMEM_W_BYTES,   "GMEM_OUT", GMEM_OUT_BASE, GMEM_OUT_BYTES);
      assert_no_overlap("GMEM_SC",  GMEM_SC_BASE,  GMEM_SC_BYTES,  "GMEM_ZP",  GMEM_ZP_BASE,  GMEM_ZP_BYTES);
      assert_no_overlap("GMEM_SC",  GMEM_SC_BASE,  GMEM_SC_BYTES,  "GMEM_OUT", GMEM_OUT_BASE, GMEM_OUT_BYTES);
      assert_no_overlap("GMEM_ZP",  GMEM_ZP_BASE,  GMEM_ZP_BYTES,  "GMEM_OUT", GMEM_OUT_BASE, GMEM_OUT_BYTES);

      // LMEM range checks
      assert_range_fit("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  LMEM_LIMIT);
      assert_range_fit("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  LMEM_LIMIT);
      assert_range_fit("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  LMEM_LIMIT);
      assert_range_fit("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  LMEM_LIMIT);
      assert_range_fit("LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES, LMEM_LIMIT);
      assert_range_fit("LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES, LMEM_LIMIT);
      assert_range_fit("LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES, LMEM_LIMIT);
      assert_range_fit("LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES, LMEM_LIMIT);
      assert_range_fit("LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES,  LMEM_LIMIT);

      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_IBUF0", LMEM_IBUF0_BASE, LMEM_IBUF_BYTES,  "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_IBUF1", LMEM_IBUF1_BASE, LMEM_IBUF_BYTES,  "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_WBUF0", LMEM_WBUF0_BASE, LMEM_WBUF_BYTES,  "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  "LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  "LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_WBUF1", LMEM_WBUF1_BASE, LMEM_WBUF_BYTES,  "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES, "LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES, "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES, "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF0", LMEM_SCBUF0_BASE, LMEM_SCBUF_BYTES, "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES, "LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES, "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_SCBUF1", LMEM_SCBUF1_BASE, LMEM_SCBUF_BYTES, "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES, "LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES);
      assert_no_overlap("LMEM_ZPBUF0", LMEM_ZPBUF0_BASE, LMEM_ZPBUF_BYTES, "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);
      assert_no_overlap("LMEM_ZPBUF1", LMEM_ZPBUF1_BASE, LMEM_ZPBUF_BYTES, "LMEM_OBUF",  LMEM_OBUF_BASE,  LMEM_OBUF_BYTES);

      $display("[%0t] Tensor layout check passed", $time);
    end
  endtask

  // =========================================================================
  // Main sim
  // =========================================================================
  initial begin
    $timeformat(-9, 0, "ns", 0);

    init_memories();

    reset = 1'b0;
    apply_reset();

    build_test_vectors();
    check_tensor_layout();
    write_gmem_inputs_weights_sc_zp();

    // 1) allocate job entry
    job_alloc(job_eid, job_gen);

    // 2) program that entry regs
    program_job_regs(job_eid);

    // 3) wait done via entry CONTROL.valid clearing
    wait_job_done(job_eid, job_gen);

    repeat (50) @(posedge clk);
    check_output();

    $display("[%0t] TB completed", $time);

`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

  parameter longint unsigned SIM_TIMEOUT_NS = 1_000_000; // 예: 2ms = 2,000,000ns

  // =========================================================================
  // Global watchdog timeout (hard stop)
  //  - Stops simulation even if TB is stuck waiting for req_ready/rsp_valid, etc.
  // =========================================================================
  initial begin : watchdog_timeout
    // wait until time passes (absolute sim time)
    #(SIM_TIMEOUT_NS);

    $display("[WATCHDOG][%0t] Global timeout reached (%0d ns). Forcing finish.",
             $time, SIM_TIMEOUT_NS);
    $display("UUID_WIDTH: %0d", UUID_WIDTH);  //44

`ifdef VCS
    // stop dumping so fsdb closes cleanly
    $fsdbDumpoff();
`else
    $dumpoff();
`endif

    // If you prefer fatal instead of finish, change to $fatal(1,...)
    $finish;
  end
endmodule

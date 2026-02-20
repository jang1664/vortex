`timescale 1ns / 1ps
`include "VX_define.vh"
`include "VX_cache_define.vh"

module tb_VX_dma_node import VX_gpu_pkg::*; #(
  parameter int    N_MASTER     = 1,
  parameter int    NUM_ENTRIES  = 8,
  parameter string TB_NAME      = "tb_VX_dma_node",
  parameter real   PERIOD        = 10.0,
  parameter string OBJ           = "func",
  parameter string FILE_POSTFIX  = "func"
) ();

  localparam int NUM_REGS32   = `DMA_CFG_REG_NUM;
  localparam int ENTRYID_W    = `LOG2UP(NUM_ENTRIES);

  localparam int MEM_BYTES    = 64 * 1024;

  localparam int DCACHE_BYTES = DCACHE_WORD_SIZE;
  localparam int LMEM_BYTES   = LSU_WORD_SIZE;

  localparam int DMA_DCACHE_TAG_WIDTH = UUID_WIDTH + 16;
  localparam int DMA_LMEM_TAG_WIDTH   = UUID_WIDTH + 8;

  localparam int MMIO_DATA_BYTES    = LSU_WORD_SIZE;
  localparam int MMIO_ADDR_SHIFT    = `CLOG2(MMIO_DATA_BYTES);
  localparam int MMIO_WORDS_PER_BEAT= (MMIO_DATA_BYTES / 4);
  localparam int MMIO_NUM_BEATS     = (NUM_REGS32 + MMIO_WORDS_PER_BEAT - 1) / MMIO_WORDS_PER_BEAT;
  localparam int MMIO_ENTRY_STRIDE_B= MMIO_NUM_BEATS * MMIO_DATA_BYTES;
  localparam int MMIO_ENTRY_BASE_B  = MMIO_DATA_BYTES;

  localparam int CTRL_VALID_BIT     = 0;
  localparam int CTRL_OCCUPY_BIT    = 1;
  localparam int CTRL_WORKING_BIT   = 2;

  localparam int ALLOC_SUCCESS_BIT  = 0;
  localparam int ALLOC_ENTRY_LSB    = 1;

  // Cache configuration (minimal)
  localparam int CACHE_NUM_REQS      = 1;
  localparam int CACHE_MEM_PORTS     = 1;
  localparam int CACHE_SIZE          = 4096;
  localparam int CACHE_LINE_SIZE     = 64;
  localparam int CACHE_NUM_BANKS     = 4;
  localparam int CACHE_NUM_WAYS      = 4;
  localparam int CACHE_CRSQ_SIZE     = 4;
  localparam int CACHE_MSHR_SIZE     = 8;
  localparam int CACHE_MRSQ_SIZE     = 4;
  localparam int CACHE_MREQ_SIZE     = 4;
  localparam int CACHE_WRITE_ENABLE  = 1;
  localparam int CACHE_WRITEBACK     = 0;
  localparam int CACHE_DIRTY_BYTES   = 0;
  localparam int CACHE_CORE_OUT_BUF  = 2;
  localparam int CACHE_MEM_OUT_BUF   = 2;
  localparam int CACHE_MEM_TAG_WIDTH = `CACHE_MEM_TAG_WIDTH(CACHE_MSHR_SIZE, CACHE_NUM_BANKS, CACHE_MEM_PORTS, UUID_WIDTH);
  localparam int CACHE_MEM_LATENCY   = 6;

  // LMEM configuration
  localparam int LMEM_NUM_REQS     = 1;
  localparam int LMEM_NUM_BANKS    = 4;
  localparam int LMEM_ADDR_WIDTH   = `CLOG2(MEM_BYTES / LMEM_BYTES);

  // Smoke case shape
  localparam int B0        = 2;
  localparam int B1        = 2;
  localparam int B2        = 2;
  localparam int SEG_BYTES = 32;
  localparam int PAD_BYTES = 3;

  logic clk;
  logic reset;

  integer rpt_fd;
  integer log_fd;

  int unsigned case_total_count;
  int unsigned case_pass_count;

  string fsdb_file_path;
  string fst_file_path;
  string rpt_file_path;
  string log_file_path;
  string name;

  // MMIO from LSU side to DMA node
  VX_lsu_mem_if #(
    .NUM_LANES (`NUM_LSU_LANES),
    .DATA_SIZE (LSU_WORD_SIZE),
    .TAG_WIDTH (LSU_TAG_WIDTH)
  ) mmio_if[N_MASTER]();

  for (genvar m = 0; m < N_MASTER; ++m) begin : g_mmio_rsp_ready
    assign mmio_if[m].rsp_ready = 1'b1;
  end

  // DMA direct data ports
  VX_mem_bus_if #(
    .DATA_SIZE (DCACHE_BYTES),
    .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
  ) dma_dcache_if();

  VX_mem_bus_if #(
    .DATA_SIZE (LMEM_BYTES),
    .TAG_WIDTH (DMA_LMEM_TAG_WIDTH)
  ) dma_lmem_if();

  // Decoupling shims:
  // keep DUT req_ready independent from arb combinational paths.
  VX_mem_bus_if #(
    .DATA_SIZE (DCACHE_BYTES),
    .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
  ) dma_to_arb_dcache_if();

  VX_mem_bus_if #(
    .DATA_SIZE (LMEM_BYTES),
    .TAG_WIDTH (DMA_LMEM_TAG_WIDTH)
  ) dma_to_arb_lmem_if();

  // Background traffic masters for arb contention
  VX_mem_bus_if #(
    .DATA_SIZE (DCACHE_BYTES),
    .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
  ) bg_global_if();

  VX_mem_bus_if #(
    .DATA_SIZE (LMEM_BYTES),
    .TAG_WIDTH (DMA_LMEM_TAG_WIDTH)
  ) bg_local_if();

  // Arbiter wiring (global path -> cache)
  VX_mem_bus_if #(
    .DATA_SIZE (DCACHE_BYTES),
    .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
  ) g_arb_in_if[2]();

  VX_mem_bus_if #(
    .DATA_SIZE (DCACHE_BYTES),
    .TAG_WIDTH (DMA_DCACHE_TAG_WIDTH)
  ) g_arb_out_if[1]();

  `ASSIGN_VX_MEM_BUS_IF(g_arb_in_if[0], dma_to_arb_dcache_if);
  `ASSIGN_VX_MEM_BUS_IF(g_arb_in_if[1], bg_global_if);

  // Cache backing memory interface
  VX_mem_bus_if #(
    .DATA_SIZE (CACHE_LINE_SIZE),
    .TAG_WIDTH (CACHE_MEM_TAG_WIDTH)
  ) cache_mem_if[CACHE_MEM_PORTS]();

  // Arbiter wiring (local path -> local memory)
  VX_mem_bus_if #(
    .DATA_SIZE (LMEM_BYTES),
    .TAG_WIDTH (DMA_LMEM_TAG_WIDTH)
  ) l_arb_in_if[2]();

  VX_mem_bus_if #(
    .DATA_SIZE (LMEM_BYTES),
    .TAG_WIDTH (DMA_LMEM_TAG_WIDTH)
  ) l_arb_out_if[1]();

  `ASSIGN_VX_MEM_BUS_IF(l_arb_in_if[0], dma_to_arb_lmem_if);
  `ASSIGN_VX_MEM_BUS_IF(l_arb_in_if[1], bg_local_if);

  // DUT
  VX_dma_node #(
    .INSTANCE_ID ("dma_node_tb"),
    .N_MASTER    (N_MASTER),
    .NUM_ENTRIES (NUM_ENTRIES)
  ) dut (
    .clk          (clk),
    .reset        (reset),
    .mmio_if      (mmio_if),
    .dcache_bus_if(dma_dcache_if),
    .lmem_bus_if  (dma_lmem_if)
  );

  typedef dma_dcache_if.req_data_t dcache_req_t;
  typedef dma_lmem_if.req_data_t   lmem_req_t;

  localparam int DMA_REQ_FIFO_DEPTH = 128;

  dcache_req_t dcache_req_fifo[DMA_REQ_FIFO_DEPTH];
  lmem_req_t   lmem_req_fifo[DMA_REQ_FIFO_DEPTH];

  int unsigned dcache_head_q  = 0;
  int unsigned dcache_tail_q  = 0;
  int unsigned dcache_count_q = 0;
  int unsigned lmem_head_q    = 0;
  int unsigned lmem_tail_q    = 0;
  int unsigned lmem_count_q   = 0;

  assign dma_dcache_if.req_ready = 1'b1;
  assign dma_lmem_if.req_ready   = 1'b1;

  always_ff @(posedge clk) begin
    if (reset) begin
      dcache_head_q <= 0;
      dcache_tail_q <= 0;
      dcache_count_q <= 0;
      lmem_head_q <= 0;
      lmem_tail_q <= 0;
      lmem_count_q <= 0;
    end else begin
      int unsigned d_head, d_tail, d_count;
      int unsigned l_head, l_tail, l_count;
      logic push_d, pop_d, push_l, pop_l;

      d_head = dcache_head_q;
      d_tail = dcache_tail_q;
      d_count = dcache_count_q;

      l_head = lmem_head_q;
      l_tail = lmem_tail_q;
      l_count = lmem_count_q;

      push_d = dma_dcache_if.req_valid && dma_dcache_if.req_ready;
      pop_d  = dma_to_arb_dcache_if.req_valid && dma_to_arb_dcache_if.req_ready;
      push_l = dma_lmem_if.req_valid && dma_lmem_if.req_ready;
      pop_l  = dma_to_arb_lmem_if.req_valid && dma_to_arb_lmem_if.req_ready;

      if (push_d) begin
        if (d_count >= DMA_REQ_FIFO_DEPTH) begin
          $fatal(1, "dcache request fifo overflow");
        end
        dcache_req_fifo[d_tail] <= dma_dcache_if.req_data;
        d_tail = (d_tail + 1) % DMA_REQ_FIFO_DEPTH;
        d_count = d_count + 1;
      end

      if (pop_d) begin
        if (d_count == 0) begin
          $fatal(1, "dcache request fifo underflow");
        end
        d_head = (d_head + 1) % DMA_REQ_FIFO_DEPTH;
        d_count = d_count - 1;
      end

      if (push_l) begin
        if (l_count >= DMA_REQ_FIFO_DEPTH) begin
          $fatal(1, "lmem request fifo overflow");
        end
        lmem_req_fifo[l_tail] <= dma_lmem_if.req_data;
        l_tail = (l_tail + 1) % DMA_REQ_FIFO_DEPTH;
        l_count = l_count + 1;
      end

      if (pop_l) begin
        if (l_count == 0) begin
          $fatal(1, "lmem request fifo underflow");
        end
        l_head = (l_head + 1) % DMA_REQ_FIFO_DEPTH;
        l_count = l_count - 1;
      end

      dcache_head_q <= d_head;
      dcache_tail_q <= d_tail;
      dcache_count_q <= d_count;

      lmem_head_q <= l_head;
      lmem_tail_q <= l_tail;
      lmem_count_q <= l_count;
    end
  end

  always_comb begin
    dma_to_arb_dcache_if.req_valid = (dcache_count_q != 0);
    dma_to_arb_dcache_if.req_data  = (dcache_count_q != 0) ? dcache_req_fifo[dcache_head_q] : '0;

    dma_to_arb_lmem_if.req_valid = (lmem_count_q != 0);
    dma_to_arb_lmem_if.req_data  = (lmem_count_q != 0) ? lmem_req_fifo[lmem_head_q] : '0;
  end

  assign dma_dcache_if.rsp_valid      = dma_to_arb_dcache_if.rsp_valid;
  assign dma_dcache_if.rsp_data       = dma_to_arb_dcache_if.rsp_data;
  assign dma_to_arb_dcache_if.rsp_ready = dma_dcache_if.rsp_ready;

  assign dma_lmem_if.rsp_valid        = dma_to_arb_lmem_if.rsp_valid;
  assign dma_lmem_if.rsp_data         = dma_to_arb_lmem_if.rsp_data;
  assign dma_to_arb_lmem_if.rsp_ready = dma_lmem_if.rsp_ready;

  // Global path arbiter
  VX_mem_arb #(
    .NUM_INPUTS  (2),
    .NUM_OUTPUTS (1),
    .DATA_SIZE   (DCACHE_BYTES),
    .TAG_WIDTH   (DMA_DCACHE_TAG_WIDTH),
    .TAG_SEL_IDX (DMA_DCACHE_TAG_WIDTH - UUID_WIDTH),
    .REQ_OUT_BUF (2),
    .RSP_OUT_BUF (2),
    .ARBITER     ("P")
  ) g_mem_arb (
    .clk        (clk),
    .reset      (reset),
    .bus_in_if  (g_arb_in_if),
    .bus_out_if (g_arb_out_if)
  );

  // Dcache model
  VX_cache_wrap #(
    .INSTANCE_ID   ("dma_node_dcache"),
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
    .TAG_WIDTH     (DMA_DCACHE_TAG_WIDTH),
    .WRITE_ENABLE  (CACHE_WRITE_ENABLE),
    .WRITEBACK     (CACHE_WRITEBACK),
    .DIRTY_BYTES   (CACHE_DIRTY_BYTES),
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

  // Local path arbiter
  VX_mem_arb #(
    .NUM_INPUTS  (2),
    .NUM_OUTPUTS (1),
    .DATA_SIZE   (LMEM_BYTES),
    .TAG_WIDTH   (DMA_LMEM_TAG_WIDTH),
    .TAG_SEL_IDX (DMA_LMEM_TAG_WIDTH - UUID_WIDTH),
    .REQ_OUT_BUF (2),
    .RSP_OUT_BUF (2),
    .ARBITER     ("P")
  ) l_mem_arb (
    .clk        (clk),
    .reset      (reset),
    .bus_in_if  (l_arb_in_if),
    .bus_out_if (l_arb_out_if)
  );

  VX_local_mem #(
    .INSTANCE_ID ("dma_node_lmem"),
    .SIZE        (MEM_BYTES),
    .NUM_REQS    (LMEM_NUM_REQS),
    .NUM_BANKS   (LMEM_NUM_BANKS),
    .ADDR_WIDTH  (LMEM_ADDR_WIDTH),
    .WORD_SIZE   (LMEM_BYTES),
    .TAG_WIDTH   (DMA_LMEM_TAG_WIDTH),
    .OUT_BUF     (0)
  ) u_local_mem (
    .clk       (clk),
    .reset     (reset),
`ifdef PERF_ENABLE
    .lmem_perf (),
`endif
    .mem_bus_if(l_arb_out_if)
  );

  // Backing memory for cache (byte-addressed)
  byte global_mem[0:MEM_BYTES-1];

  typedef struct {
    logic [CACHE_LINE_SIZE*8-1:0] data;
    logic [CACHE_MEM_TAG_WIDTH-1:0] tag;
    int unsigned delay;
  } mem_rsp_entry_t;

  mem_rsp_entry_t mem_rsp_queue[$];

  assign cache_mem_if[0].req_ready = 1'b1;

  always_ff @(posedge clk) begin
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
            if (cache_mem_if[0].req_data.byteen[b] && ((base_b + b) < MEM_BYTES)) begin
              global_mem[base_b + b] = cache_mem_if[0].req_data.data[b*8 +: 8];
            end
          end
        end else begin
          mem_rsp_entry_t e;
          e.tag   = cache_mem_if[0].req_data.tag;
          e.delay = CACHE_MEM_LATENCY;
          for (int b = 0; b < CACHE_LINE_SIZE; ++b) begin
            if ((base_b + b) < MEM_BYTES)
              e.data[b*8 +: 8] = global_mem[base_b + b];
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

  initial begin
    clk   = 1'b0;
    reset = 1'b1;
  end
  always #(PERIOD/2.0) clk = ~clk;

  initial begin
    $timeformat(-9, 0, "ns", 0);

    $sformat(name, "%s.%s", TB_NAME, FILE_POSTFIX);
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

  function automatic logic [mmio_if[0].ADDR_WIDTH-1:0] to_mmio_addr(input logic [63:0] byte_addr);
    return mmio_if[0].ADDR_WIDTH'(byte_addr >> MMIO_ADDR_SHIFT);
  endfunction

  function automatic logic [bg_global_if.ADDR_WIDTH-1:0] to_global_addr(input logic [63:0] byte_addr);
    return bg_global_if.ADDR_WIDTH'(byte_addr >> $clog2(DCACHE_BYTES));
  endfunction

  function automatic logic [bg_local_if.ADDR_WIDTH-1:0] to_local_addr(input logic [63:0] byte_addr);
    return bg_local_if.ADDR_WIDTH'(byte_addr >> $clog2(LMEM_BYTES));
  endfunction

  function automatic logic [63:0] alloc_reg_byte_addr();
    return `DMA_REG_BASE_ADDR;
  endfunction

  function automatic logic [63:0] entry_reg_byte_addr(input int entry_id, input int reg_idx);
    logic [63:0] beat_idx;
    begin
      beat_idx = reg_idx / MMIO_WORDS_PER_BEAT;
      return `DMA_REG_BASE_ADDR
           + 64'(MMIO_ENTRY_BASE_B)
           + 64'(entry_id) * 64'(MMIO_ENTRY_STRIDE_B)
           + beat_idx * 64'(MMIO_DATA_BYTES);
    end
  endfunction

  task automatic init_signals();
    begin
      mmio_if[0].req_valid = 1'b0;
      mmio_if[0].req_data  = '0;

      bg_global_if.req_valid = 1'b0;
      bg_global_if.req_data  = '0;
      bg_global_if.rsp_ready = 1'b1;

      bg_local_if.req_valid = 1'b0;
      bg_local_if.req_data  = '0;
      bg_local_if.rsp_ready = 1'b1;
    end
  endtask

  task automatic apply_reset();
    begin
      reset = 1'b1;
      repeat (10) @(posedge clk);
      reset = 1'b0;
      repeat (5) @(posedge clk);
    end
  endtask

  task automatic mem_clear_global();
    begin
      for (int unsigned i = 0; i < MEM_BYTES; ++i)
        global_mem[i] = 8'h00;
    end
  endtask

  task automatic mem_fill_inc_global(input logic [63:0] base, input int unsigned nbytes, input byte start);
    byte v;
    begin
      v = start;
      for (int unsigned i = 0; i < nbytes; ++i) begin
        int unsigned idx;
        idx = int'(base + i);
        if (idx < MEM_BYTES) begin
          global_mem[idx] = v;
          v = v + 8'd1;
        end
      end
    end
  endtask

  task automatic mem_zero_global(input logic [63:0] base, input int unsigned nbytes);
    begin
      for (int unsigned i = 0; i < nbytes; ++i) begin
        int unsigned idx;
        idx = int'(base + i);
        if (idx < MEM_BYTES)
          global_mem[idx] = 8'h00;
      end
    end
  endtask

  task automatic mem_check_equal_g_to_g_with_padding(
    input logic [63:0] src_base,
    input logic [63:0] dst_base,
    input int unsigned nbytes,
    input int unsigned seg_size,
    input int unsigned padding,
    input string msg
  );
    int unsigned valid_bytes;
    begin
      valid_bytes = (seg_size > padding) ? (seg_size - padding) : 0;

      for (int unsigned i = 0; i < nbytes; ++i) begin
        int unsigned src_idx;
        int unsigned dst_idx;

        src_idx = int'(src_base + i);
        dst_idx = int'(dst_base + i);

        if (src_idx >= MEM_BYTES || dst_idx >= MEM_BYTES)
          $fatal(1, "OOR %s i=%0d", msg, i);

        if ((i % seg_size) >= valid_bytes) begin
          if (global_mem[dst_idx] !== 8'h00)
            $fatal(1, "Padding mismatch %s @+%0d: src=%02x dst=%02x", msg, i, global_mem[src_idx], global_mem[dst_idx]);
        end else begin
          if (global_mem[src_idx] !== global_mem[dst_idx])
            $fatal(1, "Data mismatch %s @+%0d: src=%02x dst=%02x", msg, i, global_mem[src_idx], global_mem[dst_idx]);
        end
      end
    end
  endtask

  task automatic mmio_write_lane0(
    input logic [mmio_if[0].ADDR_WIDTH-1:0] addr,
    input logic [MMIO_DATA_BYTES*8-1:0] data,
    input logic [MMIO_DATA_BYTES-1:0] byteen
  );
    int guard;
    begin
      mmio_if[0].req_data           = '0;
      mmio_if[0].req_data.rw        = 1'b1;
      mmio_if[0].req_data.mask      = '0;
      mmio_if[0].req_data.mask[0]   = 1'b1;
      mmio_if[0].req_data.addr[0]   = addr;
      mmio_if[0].req_data.data[0]   = data;
      mmio_if[0].req_data.byteen[0] = byteen;
      mmio_if[0].req_data.flags[0]  = '0;
      mmio_if[0].req_data.tag       = '0;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 2000)
          $fatal(1, "mmio_write_lane0 timeout waiting req_ready");
      end

      @(negedge clk);
      mmio_if[0].req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic mmio_read_lane0(
    input  logic [mmio_if[0].ADDR_WIDTH-1:0] addr,
    output logic [MMIO_DATA_BYTES*8-1:0] data
  );
    int guard;
    begin
      mmio_if[0].req_data          = '0;
      mmio_if[0].req_data.rw       = 1'b0;
      mmio_if[0].req_data.mask     = '0;
      mmio_if[0].req_data.mask[0]  = 1'b1;
      mmio_if[0].req_data.addr[0]  = addr;
      mmio_if[0].req_data.flags[0] = '0;
      mmio_if[0].req_data.tag      = '0;

      @(negedge clk);
      mmio_if[0].req_valid = 1'b1;
      guard = 0;
      while (!(mmio_if[0].req_valid && mmio_if[0].req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 2000)
          $fatal(1, "mmio_read_lane0 timeout waiting req_ready");
      end

      @(negedge clk);
      mmio_if[0].req_valid = 1'b0;

      guard = 0;
      while (!mmio_if[0].rsp_valid) begin
        @(posedge clk);
        guard++;
        if (guard > 2000)
          $fatal(1, "mmio_read_lane0 timeout waiting rsp_valid");
      end

      data = mmio_if[0].rsp_data.data[0];
      @(posedge clk);
    end
  endtask

  task automatic mmio_write_reg32(
    input int entry_id,
    input int reg_idx,
    input logic [31:0] w32
  );
    logic [MMIO_DATA_BYTES*8-1:0] beat_data;
    logic [MMIO_DATA_BYTES-1:0]   beat_byteen;
    int                           lane32;
    begin
      lane32 = reg_idx % MMIO_WORDS_PER_BEAT;
      beat_data   = '0;
      beat_byteen = '0;

      for (int b = 0; b < 4; ++b) begin
        beat_data[lane32*32 + b*8 +: 8] = w32[b*8 +: 8];
        beat_byteen[lane32*4 + b] = 1'b1;
      end

      mmio_write_lane0(to_mmio_addr(entry_reg_byte_addr(entry_id, reg_idx)), beat_data, beat_byteen);
    end
  endtask

  task automatic mmio_read_reg32(
    input int entry_id,
    input int reg_idx,
    output logic [31:0] w32
  );
    logic [MMIO_DATA_BYTES*8-1:0] beat_data;
    int                           lane32;
    begin
      lane32 = reg_idx % MMIO_WORDS_PER_BEAT;
      mmio_read_lane0(to_mmio_addr(entry_reg_byte_addr(entry_id, reg_idx)), beat_data);
      w32 = beat_data[lane32*32 +: 32];
    end
  endtask

  task automatic alloc_entry(
    output logic success,
    output int   entry_id
  );
    logic [MMIO_DATA_BYTES*8-1:0] rd;
    logic [31:0]                  w;
    begin
      mmio_read_lane0(to_mmio_addr(alloc_reg_byte_addr()), rd);
      w       = rd[31:0];
      success = w[ALLOC_SUCCESS_BIT];
      entry_id = int'(w[ALLOC_ENTRY_LSB +: ENTRYID_W]);
    end
  endtask

  task automatic build_desc(
    input logic       dir_bit,
    input logic [63:0] src_base,
    input logic [63:0] dst_base,
    input int unsigned seg_bytes,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned padding,
    output logic [31:0] d[0:NUM_REGS32-1]
  );
    int unsigned stride0;
    int unsigned stride1;
    int unsigned stride2;
    begin
      for (int i = 0; i < NUM_REGS32; ++i)
        d[i] = 32'd0;

      stride0 = seg_bytes;
      stride1 = b0 * seg_bytes;
      stride2 = b0 * b1 * seg_bytes;

      d[0]  = 32'h0000_0001 | (dir_bit ? 32'h0000_0008 : 32'h0000_0000);
      d[1]  = dst_base[31:0];
      d[2]  = dst_base[63:32];
      d[3]  = src_base[31:0];
      d[4]  = src_base[63:32];
      d[5]  = stride0;
      d[6]  = stride0;
      d[7]  = stride1;
      d[8]  = stride1;
      d[9]  = stride2;
      d[10] = stride2;
      d[11] = b0;
      d[12] = b1;
      d[13] = b2;
      d[14] = seg_bytes;
      d[15] = padding;
    end
  endtask

  task automatic program_entry(input int entry_id, input logic [31:0] d[0:NUM_REGS32-1]);
    begin
      // Keep control(reg0) last so start/valid bit is set after all payload writes.
      for (int r = 1; r < NUM_REGS32; ++r)
        mmio_write_reg32(entry_id, r, d[r]);

      mmio_write_reg32(entry_id, 0, d[0]);
    end
  endtask

  task automatic wait_entry_cleared(input int entry_id, input int timeout_cycles);
    int c;
    logic [31:0] ctrl;
    begin
      c = 0;
      while (1) begin
        mmio_read_reg32(entry_id, 0, ctrl);
        if ((ctrl[CTRL_VALID_BIT] == 1'b0)
         && (ctrl[CTRL_OCCUPY_BIT] == 1'b0)
         && (ctrl[CTRL_WORKING_BIT] == 1'b0))
          return;

        @(posedge clk);
        c++;
        if (c > timeout_cycles)
          $fatal(1, "Timeout waiting entry %0d clear, ctrl=0x%08x", entry_id, ctrl);
      end
    end
  endtask

  task automatic send_bg_global_write(input logic [63:0] byte_addr, input int unsigned seed);
    int guard;
    logic [DCACHE_BYTES*8-1:0] wdata;
    begin
      for (int i = 0; i < DCACHE_BYTES; ++i)
        wdata[i*8 +: 8] = byte'((seed + i) & 'hFF);

      bg_global_if.req_data        = '0;
      bg_global_if.req_data.rw     = 1'b1;
      bg_global_if.req_data.addr   = to_global_addr(byte_addr);
      bg_global_if.req_data.byteen = '1;
      bg_global_if.req_data.data   = wdata;
      bg_global_if.req_data.flags  = '0;
      bg_global_if.req_data.tag    = '0;

      @(negedge clk);
      bg_global_if.req_valid = 1'b1;
      guard = 0;
      while (!(bg_global_if.req_valid && bg_global_if.req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 4000)
          $fatal(1, "send_bg_global_write timeout waiting req_ready");
      end
      @(negedge clk);
      bg_global_if.req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic send_bg_global_read(input logic [63:0] byte_addr);
    int guard;
    logic [DCACHE_BYTES*8-1:0] exp_data;
    logic [DCACHE_BYTES*8-1:0] got_data;
    begin
      for (int i = 0; i < DCACHE_BYTES; ++i) begin
        int unsigned idx;
        idx = int'(byte_addr + i);
        if (idx < MEM_BYTES)
          exp_data[i*8 +: 8] = global_mem[idx];
        else
          exp_data[i*8 +: 8] = 8'h00;
      end

      bg_global_if.req_data        = '0;
      bg_global_if.req_data.rw     = 1'b0;
      bg_global_if.req_data.addr   = to_global_addr(byte_addr);
      bg_global_if.req_data.byteen = '1;
      bg_global_if.req_data.data   = '0;
      bg_global_if.req_data.flags  = '0;
      bg_global_if.req_data.tag    = '0;

      @(negedge clk);
      bg_global_if.req_valid = 1'b1;
      guard = 0;
      while (!(bg_global_if.req_valid && bg_global_if.req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 4000)
          $fatal(1, "send_bg_global_read timeout waiting req_ready");
      end
      @(negedge clk);
      bg_global_if.req_valid = 1'b0;

      guard = 0;
      while (!bg_global_if.rsp_valid) begin
        @(posedge clk);
        guard++;
        if (guard > 4000)
          $fatal(1, "send_bg_global_read timeout waiting rsp_valid");
      end

      got_data = bg_global_if.rsp_data.data;
      if (got_data !== exp_data)
        $fatal(1, "bg global read mismatch @0x%0h exp=0x%0h got=0x%0h", byte_addr, exp_data, got_data);

      @(posedge clk);
    end
  endtask

  task automatic send_bg_local_write(input logic [63:0] byte_addr, input int unsigned seed);
    int guard;
    logic [LMEM_BYTES*8-1:0] wdata;
    begin
      for (int i = 0; i < LMEM_BYTES; ++i)
        wdata[i*8 +: 8] = byte'((seed + i) & 'hFF);

      bg_local_if.req_data        = '0;
      bg_local_if.req_data.rw     = 1'b1;
      bg_local_if.req_data.addr   = to_local_addr(byte_addr);
      bg_local_if.req_data.byteen = '1;
      bg_local_if.req_data.data   = wdata;
      bg_local_if.req_data.flags  = '0;
      bg_local_if.req_data.tag    = '0;

      @(negedge clk);
      bg_local_if.req_valid = 1'b1;
      guard = 0;
      while (!(bg_local_if.req_valid && bg_local_if.req_ready)) begin
        @(posedge clk);
        guard++;
        if (guard > 4000)
          $fatal(1, "send_bg_local_write timeout waiting req_ready");
      end
      @(negedge clk);
      bg_local_if.req_valid = 1'b0;
      @(posedge clk);
    end
  endtask

  task automatic run_bg_global_traffic(input int unsigned txns, input logic [63:0] base_addr);
    begin
      for (int unsigned i = 0; i < txns; ++i)
        send_bg_global_write(base_addr + i * DCACHE_BYTES, i);
    end
  endtask

  task automatic run_bg_global_read_traffic(input int unsigned txns, input logic [63:0] base_addr);
    begin
      for (int unsigned i = 0; i < txns; ++i)
        send_bg_global_read(base_addr + i * DCACHE_BYTES);
    end
  endtask

  task automatic run_bg_local_traffic(input int unsigned txns, input logic [63:0] base_addr);
    begin
      for (int unsigned i = 0; i < txns; ++i)
        send_bg_local_write(base_addr + i * LMEM_BYTES, i + 32);
    end
  endtask

  task automatic run_roundtrip_case_cfg(
    input string case_name,
    input int unsigned case_id,
    input int unsigned seg_bytes,
    input int unsigned b0,
    input int unsigned b1,
    input int unsigned b2,
    input int unsigned padding,
    input int unsigned g_src_off,
    input int unsigned l_mid_off,
    input int unsigned g_dst_off,
    input bit enable_global_bg,
    input bit enable_local_bg,
    input bit enable_global_bg_read
  );
    logic ok;
    int entry0;
    int entry1;
    int unsigned total_bytes;

    logic [63:0] g_src_base;
    logic [63:0] l_mid_base;
    logic [63:0] g_dst_base;
    logic [63:0] g_rd_base0;
    logic [63:0] g_rd_base1;
    int unsigned case_slot;

    logic [31:0] d0[0:NUM_REGS32-1];
    logic [31:0] d1[0:NUM_REGS32-1];

    begin
      case_total_count++;

      apply_reset();
      init_signals();

      total_bytes = b0 * b1 * b2 * seg_bytes;
      case_slot = (case_id % 32);

      g_src_base = 64'h0000_0000_0000_1000 + 64'(case_slot) * 64'd128 + 64'(g_src_off);
      l_mid_base = 64'h0000_0000_0000_3000 + 64'(case_slot) * 64'd128 + 64'(l_mid_off);
      g_dst_base = 64'h0000_0000_0000_5000 + 64'(case_slot) * 64'd128 + 64'(g_dst_off);
      g_rd_base0 = 64'h0000_0000_0000_7000 + 64'(case_slot) * 64'd128;
      g_rd_base1 = 64'h0000_0000_0000_8000 + 64'(case_slot) * 64'd128;

      if ((g_src_base + total_bytes) > MEM_BYTES)
        $fatal(1, "SRC out-of-range: base=0x%0h total=%0d", g_src_base, total_bytes);
      if ((l_mid_base + total_bytes) > MEM_BYTES)
        $fatal(1, "LMID out-of-range: base=0x%0h total=%0d", l_mid_base, total_bytes);
      if ((g_dst_base + total_bytes) > MEM_BYTES)
        $fatal(1, "DST out-of-range: base=0x%0h total=%0d", g_dst_base, total_bytes);
      if ((g_rd_base0 + 64 * DCACHE_BYTES) > MEM_BYTES)
        $fatal(1, "RD0 out-of-range: base=0x%0h", g_rd_base0);
      if ((g_rd_base1 + 64 * DCACHE_BYTES) > MEM_BYTES)
        $fatal(1, "RD1 out-of-range: base=0x%0h", g_rd_base1);

      mem_clear_global();
      mem_fill_inc_global(g_src_base, total_bytes, 8'h10);
      mem_zero_global(g_dst_base, total_bytes);
      if (enable_global_bg_read) begin
        mem_fill_inc_global(g_rd_base0, 64 * DCACHE_BYTES, 8'ha0);
        mem_fill_inc_global(g_rd_base1, 64 * DCACHE_BYTES, 8'h40);
      end

      $display("[CASE] %s start", case_name);
      $fdisplay(log_fd, "[CASE] %s start", case_name);

      // Stage 1: GLOBAL -> LMEM
      alloc_entry(ok, entry0);
      if (!ok)
        $fatal(1, "alloc failed (stage1) in %s", case_name);

      build_desc(1'b0, g_src_base, l_mid_base, seg_bytes, b0, b1, b2, padding, d0);
      program_entry(entry0, d0);

      fork
        begin : g_wait_done0
          wait_entry_cleared(entry0, 20000);
        end
        begin : g_bg_global0
          if (enable_global_bg)
            run_bg_global_traffic(64, 64'h0000_0000_0000_5000 + 64'(case_slot) * 64'd256);
        end
        begin : g_bg_local0
          if (enable_local_bg)
            run_bg_local_traffic(64, 64'h0000_0000_0000_7000 + 64'(case_slot) * 64'd128);
        end
        begin : g_bg_global_rd0
          if (enable_global_bg_read)
            run_bg_global_read_traffic(64, g_rd_base0);
        end
      join

      // Stage 2: LMEM -> GLOBAL
      alloc_entry(ok, entry1);
      if (!ok)
        $fatal(1, "alloc failed (stage2) in %s", case_name);

      build_desc(1'b1, l_mid_base, g_dst_base, seg_bytes, b0, b1, b2, padding, d1);
      program_entry(entry1, d1);

      fork
        begin : g_wait_done1
          wait_entry_cleared(entry1, 20000);
        end
        begin : g_bg_global1
          if (enable_global_bg)
            run_bg_global_traffic(64, 64'h0000_0000_0000_5800 + 64'(case_slot) * 64'd256);
        end
        begin : g_bg_local1
          if (enable_local_bg)
            run_bg_local_traffic(64, 64'h0000_0000_0000_7800 + 64'(case_slot) * 64'd128);
        end
        begin : g_bg_global_rd1
          if (enable_global_bg_read)
            run_bg_global_read_traffic(64, g_rd_base1);
        end
      join

      mem_check_equal_g_to_g_with_padding(
        g_src_base,
        g_dst_base,
        total_bytes,
        seg_bytes,
        padding,
        case_name
      );

      case_pass_count++;
      $display("[CASE] %s PASS", case_name);
      $fdisplay(rpt_fd, "[CASE] %s PASS", case_name);
    end
  endtask

  task automatic run_roundtrip_case(
    input string case_name,
    input int unsigned case_id,
    input bit enable_global_bg,
    input bit enable_local_bg,
    input bit enable_global_bg_read
  );
    begin
      run_roundtrip_case_cfg(
        case_name,
        case_id,
        SEG_BYTES, B0, B1, B2, PAD_BYTES,
        0, 0, 0,
        enable_global_bg,
        enable_local_bg,
        enable_global_bg_read
      );
    end
  endtask

  task automatic run_misaligned_sweep_case();
    int unsigned g_offs[0:8];
    int unsigned l_offs[0:7];
    int unsigned seg_choices[0:7];
    int unsigned pad_choices[0:4];
    int unsigned b0_choices[0:3];
    int unsigned b1_choices[0:3];
    int unsigned b2_choices[0:3];
    int unsigned g_half;
    int unsigned l_half;
    string cname;
    int unsigned case_seed;
    begin
      g_half = DCACHE_BYTES / 2;
      l_half = LMEM_BYTES / 2;

      g_offs[0] = 0;
      g_offs[1] = 1;
      g_offs[2] = 2;
      g_offs[3] = 3;
      g_offs[4] = (g_half > 0) ? (g_half - 1) : 0;
      g_offs[5] = g_half;
      g_offs[6] = (g_half + 1 < DCACHE_BYTES) ? (g_half + 1) : (DCACHE_BYTES - 1);
      g_offs[7] = (DCACHE_BYTES > 1) ? (DCACHE_BYTES - 2) : 0;
      g_offs[8] = (DCACHE_BYTES > 0) ? (DCACHE_BYTES - 1) : 0;

      l_offs[0] = 0;
      l_offs[1] = 1;
      l_offs[2] = 2;
      l_offs[3] = (l_half > 0) ? (l_half - 1) : 0;
      l_offs[4] = l_half;
      l_offs[5] = (l_half + 1 < LMEM_BYTES) ? (l_half + 1) : (LMEM_BYTES - 1);
      l_offs[6] = (LMEM_BYTES > 1) ? (LMEM_BYTES - 2) : 0;
      l_offs[7] = (LMEM_BYTES > 0) ? (LMEM_BYTES - 1) : 0;

      seg_choices[0] = 13;
      seg_choices[1] = 17;
      seg_choices[2] = 24;
      seg_choices[3] = 31;
      seg_choices[4] = 32;
      seg_choices[5] = 47;
      seg_choices[6] = 64;
      seg_choices[7] = 96;

      pad_choices[0] = 0;
      pad_choices[1] = 1;
      pad_choices[2] = 2;
      pad_choices[3] = 3;
      pad_choices[4] = 7;

      b0_choices[0] = 2; b1_choices[0] = 2; b2_choices[0] = 2;
      b0_choices[1] = 3; b1_choices[1] = 2; b2_choices[1] = 1;
      b0_choices[2] = 1; b1_choices[2] = 3; b2_choices[2] = 2;
      b0_choices[3] = 2; b1_choices[3] = 1; b2_choices[3] = 4;

      case_seed = 100;

      $display("[SWEEP] misaligned sweep start");
      $fdisplay(log_fd, "[SWEEP] misaligned sweep start");

      // source global offset sweep
      for (int i = 0; i < 9; ++i) begin
        $sformat(cname, "sweep_src_off_%0d", g_offs[i]);
        run_roundtrip_case_cfg(cname, case_seed + i, 48, 2, 2, 2, 3, g_offs[i], 0, 0, 1'b0, 1'b0, 1'b0);
      end
      case_seed += 9;

      // local memory offset sweep
      for (int i = 0; i < 8; ++i) begin
        $sformat(cname, "sweep_lmid_off_%0d", l_offs[i]);
        run_roundtrip_case_cfg(cname, case_seed + i, 48, 2, 2, 2, 3, 0, l_offs[i], 0, 1'b0, 1'b0, 1'b0);
      end
      case_seed += 8;

      // destination global offset sweep
      for (int i = 0; i < 9; ++i) begin
        $sformat(cname, "sweep_dst_off_%0d", g_offs[i]);
        run_roundtrip_case_cfg(cname, case_seed + i, 48, 2, 2, 2, 3, 0, 0, g_offs[i], 1'b0, 1'b0, 1'b0);
      end
      case_seed += 9;

      // mixed offset/segment sweep
      for (int i = 0; i < 18; ++i) begin
        int unsigned src_off;
        int unsigned l_off;
        int unsigned dst_off;
        int unsigned seg_b;
        int unsigned pad_eff;
        src_off = g_offs[i % 9];
        l_off = l_offs[(i * 3 + 1) % 8];
        dst_off = g_offs[(i * 5 + 2) % 9];
        seg_b = (i % 3 == 0) ? 17 : ((i % 3 == 1) ? 48 : 96);
        pad_eff = i % 4;
        $sformat(cname, "sweep_mix_%0d_s%0d_l%0d_d%0d_seg%0d_pad%0d", i, src_off, l_off, dst_off, seg_b, pad_eff);
        run_roundtrip_case_cfg(cname, case_seed + i, seg_b, 2, 2, 2, pad_eff, src_off, l_off, dst_off, 1'b0, 1'b0, 1'b0);
      end
      case_seed += 18;

      // seg/padding/shape sweep on varied offsets
      for (int si = 0; si < 8; ++si) begin
        for (int pi = 0; pi < 5; ++pi) begin
          int unsigned seg_b;
          int unsigned pad_b;
          int unsigned pad_eff;
          int unsigned shape_idx;
          int unsigned src_off;
          int unsigned l_off;
          int unsigned dst_off;
          int unsigned case_idx;
          seg_b = seg_choices[si];
          pad_b = pad_choices[pi];
          pad_eff = (pad_b < seg_b) ? pad_b : (seg_b - 1);
          shape_idx = (si + pi) % 4;
          src_off = g_offs[(si + pi) % 9];
          l_off = l_offs[(si * 2 + pi) % 8];
          dst_off = g_offs[(si * 3 + pi) % 9];
          case_idx = case_seed + (si * 5) + pi;
          $sformat(cname, "sweep_seg%0d_pad%0d_b%0dx%0dx%0d_s%0d_l%0d_d%0d",
            seg_b, pad_eff, b0_choices[shape_idx], b1_choices[shape_idx], b2_choices[shape_idx], src_off, l_off, dst_off);
          run_roundtrip_case_cfg(
            cname, case_idx, seg_b,
            b0_choices[shape_idx], b1_choices[shape_idx], b2_choices[shape_idx], pad_eff,
            src_off, l_off, dst_off,
            1'b0, 1'b0, 1'b0
          );
        end
      end
      case_seed += 40;

      // contention sweep with varied background traffic toggles
      for (int i = 0; i < 12; ++i) begin
        int unsigned seg_b;
        int unsigned pad_eff;
        int unsigned shape_idx;
        bit bg_g;
        bit bg_l;
        bit bg_r;
        seg_b = seg_choices[i % 8];
        pad_eff = (i % 5 < seg_b) ? (i % 5) : (seg_b - 1);
        shape_idx = i % 4;
        bg_g = (i % 2 == 0);
        bg_l = (i % 3 != 0);
        // bg_global_if is a single master stream: avoid concurrent read/write generators.
        bg_r = (i % 4 == 0) && !bg_g;
        $sformat(cname, "sweep_cont_%0d_seg%0d_pad%0d_bg%0d%0d%0d",
          i, seg_b, pad_eff, bg_g, bg_l, bg_r);
        run_roundtrip_case_cfg(
          cname, case_seed + i, seg_b,
          b0_choices[shape_idx], b1_choices[shape_idx], b2_choices[shape_idx], pad_eff,
          g_offs[(i * 3) % 9], l_offs[(i * 5 + 1) % 8], g_offs[(i * 7 + 2) % 9],
          bg_g, bg_l, bg_r
        );
      end

      $display("[SWEEP] misaligned sweep done");
      $fdisplay(log_fd, "[SWEEP] misaligned sweep done");
    end
  endtask

  task automatic print_summary();
    begin
      $display("[SUMMARY] PASS/TOTAL = %0d/%0d", case_pass_count, case_total_count);
      $fdisplay(log_fd, "[SUMMARY] PASS/TOTAL = %0d/%0d", case_pass_count, case_total_count);
      $fdisplay(rpt_fd, "[SUMMARY] PASS/TOTAL = %0d/%0d", case_pass_count, case_total_count);
    end
  endtask

  task automatic sim_func();
    begin
      $display("=====================================================================");
      $display("==================== START DMA NODE SMOKE TEST =====================");
      $display("=====================================================================");

      case_total_count = 0;
      case_pass_count  = 0;

      init_signals();

      run_roundtrip_case("smoke_basic",               0, 1'b0, 1'b0, 1'b0);
      run_roundtrip_case("smoke_global_content",      1, 1'b1, 1'b0, 1'b0);
      run_roundtrip_case("smoke_local_content",       2, 1'b0, 1'b1, 1'b0);
      run_roundtrip_case("smoke_global_read_content", 3, 1'b0, 1'b0, 1'b1);
      run_misaligned_sweep_case();

      print_summary();

      if (case_pass_count != case_total_count)
        $fatal(1, "Smoke failed: pass=%0d total=%0d", case_pass_count, case_total_count);
    end
  endtask

  task automatic sim_power();
    begin
      // For now, keep power mode aligned with smoke coverage.
      sim_func();
    end
  endtask

  initial begin
    @(posedge clk);
    if (N_MASTER != 1)
      $display("[INFO] N_MASTER=%0d (smoke flow uses master0 only)", N_MASTER);

    if (OBJ == "power") begin
      sim_power();
    end else begin
      sim_func();
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

endmodule

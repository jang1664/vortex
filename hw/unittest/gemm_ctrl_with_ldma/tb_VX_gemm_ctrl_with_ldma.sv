`timescale 1ns/1ps
`include "VX_define.vh"

//------------------------------------------------------------------------------
// connect VX_mem_bus_if by direct assign (Verilator-friendly modport directions)
//------------------------------------------------------------------------------
module vx_mem_bus_connect #(
  parameter int DATA_SIZE  = 1,
  parameter int TAG_WIDTH  = 1
) (
  VX_mem_bus_if.slave  up,
  VX_mem_bus_if.master down
);
  // req: up -> down
  assign down.req_valid = up.req_valid;
  assign down.req_data  = up.req_data;
  assign up.req_ready   = down.req_ready;

  // rsp: down -> up
  assign up.rsp_valid   = down.rsp_valid;
  assign up.rsp_data    = down.rsp_data;
  assign down.rsp_ready = up.rsp_ready;
endmodule

//------------------------------------------------------------------------------
// GEMM-side dummy memory slave (VX_mem_bus_if)
//  - returns 1-cycle response for BOTH reads and writes
//------------------------------------------------------------------------------
module vx_mem_bus_dummy_slave #(
  parameter int DATA_SIZE = 16,
  parameter int TAG_WIDTH = 16,
  parameter int ADDR_WIDTH = (`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE))
) (
  input  wire clk,
  input  wire reset,
  VX_mem_bus_if.slave bus_if
);
  logic pending;
  logic [DATA_SIZE*8-1:0] pending_rdata;
  logic [TAG_WIDTH-1:0]   pending_tag_bits;

  assign bus_if.req_ready = ~pending;

  assign bus_if.rsp_valid     = pending;
  assign bus_if.rsp_data.data = pending_rdata;
  assign bus_if.rsp_data.tag  = pending_tag_bits;

  wire fire_req = bus_if.req_valid && bus_if.req_ready;
  wire fire_rsp = bus_if.rsp_valid && bus_if.rsp_ready;

  function automatic logic [DATA_SIZE*8-1:0] make_data(input logic [ADDR_WIDTH-1:0] a);
    logic [DATA_SIZE*8-1:0] tmp;
    int i;
    begin
      tmp = '0;
      for (i = 0; i < DATA_SIZE; i++) begin
        tmp[i*8 +: 8] = a[7:0] + 8'(i);
      end
      return tmp;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (reset) begin
      pending          <= 1'b0;
      pending_rdata    <= '0;
      pending_tag_bits <= '0;
    end else begin
      if (pending && fire_rsp)
        pending <= 1'b0;

      if (~pending && fire_req) begin
        pending          <= 1'b1;
        pending_tag_bits <= bus_if.req_data.tag;

        if (~bus_if.req_data.rw) begin
          // READ
          pending_rdata <= make_data(bus_if.req_data.addr);
        end else begin
          // WRITE (ack only)
          pending_rdata <= '0;
        end
      end
    end
  end
endmodule

//------------------------------------------------------------------------------
// MMIO model for VX_lsu_mem_if (VX_gemm_dma_ctrl uses this)
//
// This model MATCHES your VX_gemm_dma_ctrl semantics:
//  - Global alloc register is at DMA_CFG_BASE_ADDR (+0), size = DATA_SIZE bytes.
//  - Entry regs start at DMA_CFG_BASE_ADDR + DATA_SIZE (GLOBAL_ALLOC_B).
//  - CONTROL completion is detected by occupy=0 && working=0 (bits [1],[2]).
//
// Behavior implemented:
//  1) ALLOC read returns success=1 and fixed tokens (entry_id=0, owner=1, gen=1)
//  2) When CONTROL.start(=bit0) is written for an entry, we:
//        - set occupy/working bits (bit1, bit2) to 1 immediately
//        - after LAT_DMA_DONE cycles, clear occupy/working (and also clear start)
//------------------------------------------------------------------------------
module vx_lsu_mmio_model #(
  parameter int NUM_LANES    = 1,
  parameter int DATA_SIZE    = 16,
  parameter int TAG_WIDTH    = 16,
  parameter int MEM_BYTES    = 64*1024,
  parameter int ADDR_WIDTH   = (`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),

  // must match VX_gemm_dma_ctrl params
  parameter logic [63:0] DMA_CFG_BASE_ADDR      = 64'h0,
  parameter int          DMA_ENTRY_STRIDE_BYTES = 64,     // 16 regs * 4B
  parameter int          LAT_DMA_DONE           = 80,

  // must match VX_gemm_dma_ctrl packing fields
  parameter int          ENTRYID_W              = 8,
  parameter int          CTRL_OWNER_W           = 1,
  parameter int          CTRL_GEN_W             = 16,

  // bits in CONTROL (must match VX_gemm_dma_ctrl)
  parameter int          DMA_CTRL_START_BIT     = 0,
  parameter int          DMA_CTRL_OCCUPY_BIT    = 1,
  parameter int          DMA_CTRL_WORKING_BIT   = 2,
  parameter int          DMA_CTRL_OWNER_LSB     = 4,
  parameter int          DMA_CTRL_GEN_LSB       = (DMA_CTRL_OWNER_LSB + CTRL_OWNER_W),

  // alloc response layout (must match VX_gemm_dma_ctrl)
  parameter int          ALLOC_SUCCESS_BIT      = 0,
  parameter int          ALLOC_ENTRY_LSB        = 1,
  parameter int          ALLOC_ENTRY_BITS       = (ENTRYID_W > 31) ? 31 : ENTRYID_W,
  parameter int          ALLOC_OWNER_LSB        = (ALLOC_ENTRY_LSB + ALLOC_ENTRY_BITS),
  parameter int          ALLOC_OWNER_BITS       = CTRL_OWNER_W,
  parameter int          ALLOC_GEN_LSB          = (ALLOC_OWNER_LSB + ALLOC_OWNER_BITS),
  parameter int          ALLOC_GEN_BITS         = CTRL_GEN_W,

  parameter bit          VERBOSE                = 1
) (
  input  wire clk,
  input  wire reset,
  VX_lsu_mem_if.slave mmio_if
);
  // backing store is BASE-RELATIVE:
  //   mem_idx = abs_byte_addr - DMA_CFG_BASE_ADDR
  byte mem [0:MEM_BYTES-1];

  // one outstanding response
  logic pending;

  // rsp fields (raw bits)
  logic [TAG_WIDTH-1:0] pending_tag_bits;
  logic [NUM_LANES-1:0] pending_mask;
  logic [NUM_LANES-1:0][DATA_SIZE*8-1:0] pending_data;

  assign mmio_if.req_ready = ~pending;
  assign mmio_if.rsp_valid = pending;

  always_comb begin
    mmio_if.rsp_data       = '0;
    mmio_if.rsp_data.tag   = pending_tag_bits;
    mmio_if.rsp_data.mask  = pending_mask;
    mmio_if.rsp_data.data  = pending_data;
  end

  wire fire_req = mmio_if.req_valid && mmio_if.req_ready;
  wire fire_rsp = mmio_if.rsp_valid && mmio_if.rsp_ready;

  // helpers
  function automatic longint unsigned lane_abs_base(input logic [ADDR_WIDTH-1:0] a_lane);
    // addr is in DATA_SIZE-byte units (already shifted in DUT via to_lsu_addr)
    return longint'(a_lane) * longint'(DATA_SIZE);
  endfunction

  function automatic bit in_mem_range(input longint unsigned abs_byte_addr);
    if (abs_byte_addr < DMA_CFG_BASE_ADDR) return 0;
    if ((abs_byte_addr - DMA_CFG_BASE_ADDR) >= MEM_BYTES) return 0;
    return 1;
  endfunction

  function automatic int unsigned mem_index(input longint unsigned abs_byte_addr);
    // caller should ensure in range
    return int'(abs_byte_addr - DMA_CFG_BASE_ADDR);
  endfunction

  localparam int unsigned GLOBAL_ALLOC_B = DATA_SIZE;
  localparam longint unsigned ENTRY_BASE_ABS = (DMA_CFG_BASE_ADDR + longint'(GLOBAL_ALLOC_B));

  // decode CONTROL word byte (absolute address)
  function automatic bit is_control_word_byte_abs(
    input longint unsigned abs_byte_addr,
    output int unsigned off_in_entry,
    output int unsigned entry_idx
  );
    longint unsigned diff;
    begin
      off_in_entry = 0;
      entry_idx    = 0;
      if (abs_byte_addr < ENTRY_BASE_ABS) return 0;
      diff = abs_byte_addr - ENTRY_BASE_ABS;
      if (DMA_ENTRY_STRIDE_BYTES <= 0) return 0;
      off_in_entry = int'(diff % DMA_ENTRY_STRIDE_BYTES);
      entry_idx    = int'(diff / DMA_ENTRY_STRIDE_BYTES);
      // CONTROL word occupies byte offsets 0..3 within each entry
      return (off_in_entry < 4);
    end
  endfunction

  // --------------------------------------------------------------------------
  // auto-complete (clear occupy/working) state
  // --------------------------------------------------------------------------
  logic        pend_complete;
  int unsigned complete_cnt;
  int unsigned ctrl_byte0_memidx; // mem index of CONTROL byte0 (bit0/1/2 live here)

  integer li, bi;

  // build a fixed ALLOC response (32-bit word in LSB of lane0 read)
  function automatic logic [31:0] make_alloc_rsp();
    logic [31:0] w;
    logic [ENTRYID_W-1:0]    entry_id;
    logic [CTRL_OWNER_W-1:0] owner;
    logic [CTRL_GEN_W-1:0]   gen;
    begin
      w = 32'd0;
      entry_id = '0;         // fixed entry 0
      owner    = '0; owner[0] = 1'b1; // owner = 1
      gen      = '0; gen[0]   = 1'b1; // gen = 1

      w[ALLOC_SUCCESS_BIT] = 1'b1;
      if (ALLOC_ENTRY_BITS > 0)
        w[ALLOC_ENTRY_LSB +: ALLOC_ENTRY_BITS] = entry_id[ALLOC_ENTRY_BITS-1:0];
      if (ALLOC_OWNER_BITS > 0)
        w[ALLOC_OWNER_LSB +: ALLOC_OWNER_BITS] = owner[ALLOC_OWNER_BITS-1:0];
      if (ALLOC_GEN_BITS > 0)
        w[ALLOC_GEN_LSB   +: ALLOC_GEN_BITS]   = gen[ALLOC_GEN_BITS-1:0];

      return w;
    end
  endfunction

  always_ff @(posedge clk) begin
    if (reset) begin
      pending          <= 1'b0;
      pending_tag_bits <= '0;
      pending_mask     <= '0;
      pending_data     <= '0;

      pend_complete    <= 1'b0;
      complete_cnt     <= 0;
      ctrl_byte0_memidx <= 0;

      // clear memory
      for (bi = 0; bi < MEM_BYTES; bi++) begin
        mem[bi] <= 8'h00;
      end

      // preload alloc register word0 (at DMA_CFG_BASE_ADDR + 0)
      if (MEM_BYTES >= 4) begin
        logic [31:0] alloc_w;
        alloc_w = make_alloc_rsp();
        mem[0] <= alloc_w[7:0];
        mem[1] <= alloc_w[15:8];
        mem[2] <= alloc_w[23:16];
        mem[3] <= alloc_w[31:24];
      end
    end else begin
      // complete countdown: clear occupy/working (+ start) bits in CONTROL byte0
      if (pend_complete) begin
        if (complete_cnt == 0) begin
          if (ctrl_byte0_memidx < MEM_BYTES) begin
            // clear bit0(start), bit1(occupy), bit2(working)
            mem[ctrl_byte0_memidx] <= mem[ctrl_byte0_memidx] & 8'hF8;
            if (VERBOSE) $display("[%0t] DMA_DONE: clear start/occupy/working @mem_idx=0x%0h (abs=0x%0h)",
                                  $time,
                                  ctrl_byte0_memidx,
                                  DMA_CFG_BASE_ADDR + longint'(ctrl_byte0_memidx));
          end
          pend_complete <= 1'b0;
        end else begin
          complete_cnt <= complete_cnt - 1;
        end
      end

      if (pending && fire_rsp)
        pending <= 1'b0;

      if (~pending && fire_req) begin
        pending <= 1'b1;

        pending_tag_bits <= mmio_if.req_data.tag;
        pending_mask     <= mmio_if.req_data.mask;

        for (li = 0; li < NUM_LANES; li++) begin
          pending_data[li] <= '0;
        end

        // per-lane handling
        for (li = 0; li < NUM_LANES; li++) begin
          if (mmio_if.req_data.mask[li]) begin
            longint unsigned abs_base;
            abs_base = lane_abs_base(mmio_if.req_data.addr[li]);

            if (mmio_if.req_data.rw) begin
              // WRITE
              for (bi = 0; bi < DATA_SIZE; bi++) begin
                if (mmio_if.req_data.byteen[li][bi]) begin
                  longint unsigned abs_byte;
                  abs_byte = abs_base + longint'(bi);

                  if (in_mem_range(abs_byte)) begin
                    int unsigned midx;
                    int unsigned off_in_entry;
                    int unsigned entry_idx;
                    bit is_ctrl_word;

                    midx = mem_index(abs_byte);
                    mem[midx] <= mmio_if.req_data.data[li][bi*8 +: 8];

                    // detect CONTROL.start write on CONTROL byte0 (off_in_entry==0) with bit0=1
                    is_ctrl_word = is_control_word_byte_abs(abs_byte, off_in_entry, entry_idx);
                    if (is_ctrl_word && (off_in_entry == 0)) begin
                      byte newb;
                      newb = mmio_if.req_data.data[li][bi*8 +: 8];
                      if (newb[DMA_CTRL_START_BIT]) begin
                        // Immediately set occupy/working bits as if backend accepted the job
                        mem[midx] <= (newb | (8'(1 << DMA_CTRL_OCCUPY_BIT)) | (8'(1 << DMA_CTRL_WORKING_BIT)));

                        // Schedule completion
                        pend_complete     <= 1'b1;
                        complete_cnt      <= LAT_DMA_DONE;
                        ctrl_byte0_memidx <= midx;

                        if (VERBOSE) begin
                          $display("[%0t] DMA_START: CONTROL.start seen @abs=0x%0h entry=%0d -> set occupy/working, complete after %0d cyc",
                                   $time, abs_byte, entry_idx, LAT_DMA_DONE);
                        end
                      end
                    end
                  end
                end
              end
              // write response data can be 0
              pending_data[li] <= '0;

            end else begin
              // READ
              logic [DATA_SIZE*8-1:0] rtmp;
              rtmp = '0;
              for (bi = 0; bi < DATA_SIZE; bi++) begin
                longint unsigned abs_byte;
                abs_byte = abs_base + longint'(bi);
                if (in_mem_range(abs_byte)) begin
                  int unsigned midx;
                  midx = mem_index(abs_byte);
                  rtmp[bi*8 +: 8] = mem[midx];
                end
              end
              pending_data[li] <= rtmp;
            end
          end
        end
      end
    end
  end
endmodule

//------------------------------------------------------------------------------
// TB: VX_gemm_ctrl_with_ldma + VX_local_mem
//------------------------------------------------------------------------------
module tb_VX_gemm_ctrl_with_ldma;
  import VX_gpu_pkg::*;

  localparam int    TOTAL_CYC = 100000*50;
  localparam string TB_NAME     = "tb_VX_gemm_ctrl_with_ldma";
  localparam string INSTANCE_ID = "tb";
  localparam real   PERIOD = 10.0;

  // emulate backend completion latency (occupy/working clear)
  localparam int LAT_DMA_DONE = 80;

  // IMPORTANT: must match VX_gemm_dma_ctrl params
  localparam logic [63:0] DMA_CFG_BASE_ADDR_TB      = 64'h0;
  localparam int          DMA_ENTRY_STRIDE_BYTES_TB = 16 * 4; // 64 bytes/entry

  // clock/reset
  logic clk;
  logic reset;

  initial begin
    clk = 1'b0;
    forever #(PERIOD/2.0) clk = ~clk;
  end

  // ---------------------------------------------------------------------------
  // Waveform dump
  // ---------------------------------------------------------------------------
  string fst_file;
  string fsdb_file;

  initial begin
    $sformat(fst_file,  "./reports/%s.fst",  TB_NAME);
    $sformat(fsdb_file, "./reports/%s.fsdb", TB_NAME);

`ifdef VCS
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, "+all", "+parameter", "+functions");
`else
    $dumpfile(fst_file);
    $dumpvars(0, tb_VX_gemm_ctrl_with_ldma);
`endif
  end

  // cfg interface: 33 regs x 32b (NOTE: assumes your VX_config_reg_if includes entry_id)
  VX_config_reg_if #(.NUM(33), .DW(32)) cfg_reg_if();

  // lmem bus from DUT
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_bus_if();

  // gemm-side buses
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) i_dma_gemm_bus_if();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) w_dma_gemm_bus_if();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) sz_dma_gemm_bus_if();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) o_dma_gemm_bus_if();

  // gemm_dma_ctrl MMIO
  VX_lsu_mem_if #(
    .NUM_LANES(1),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)
  ) dma_if();

  VX_node_done_if gemm_node_done_if();
  assign gemm_node_done_if.ready = 1'b1;

  // DUT
  VX_gemm_ctrl_with_ldma #(
    .INSTANCE_ID(INSTANCE_ID)
  ) dut (
    .clk(clk),
    .reset(reset),
    .cfg_reg_if(cfg_reg_if.slave),

    .lmem_bus_if(lmem_bus_if.master),

    .i_dma_gemm_bus_if(i_dma_gemm_bus_if.master),
    .w_dma_gemm_bus_if(w_dma_gemm_bus_if.master),
    .sz_dma_gemm_bus_if(sz_dma_gemm_bus_if.master),
    .o_dma_gemm_bus_if(o_dma_gemm_bus_if.master),

    .dma_if(dma_if.master),
    .gemm_node_done_if(gemm_node_done_if.master)
  );

  // ---------------------------------------------------------------------------
  // Local mem connection
  // ---------------------------------------------------------------------------
  VX_mem_bus_if #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) lmem_ports [1] ();

  vx_mem_bus_connect #(
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH)
  ) u_lmem_link (
    .up   (lmem_bus_if.slave),
    .down (lmem_ports[0].master)
  );

  localparam int MEM_BYTES  = 64*1024;
  localparam int NUM_WORDS  = MEM_BYTES / LSU_WORD_SIZE;
  localparam int NUM_REQS   = 1;
  localparam int NUM_BANKS  = 4;

  VX_local_mem #(
    .INSTANCE_ID("tb_lmem"),
    .SIZE(MEM_BYTES),
    .NUM_REQS(NUM_REQS),
    .NUM_BANKS(NUM_BANKS),
    .ADDR_WIDTH(`CLOG2(NUM_WORDS)),
    .WORD_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(LMEM_TAG_WIDTH),
    .OUT_BUF(0)
  ) u_local_mem (
    .clk(clk),
    .reset(reset),
`ifdef PERF_ENABLE
    .lmem_perf(),
`endif
    .mem_bus_if(lmem_ports)
  );

  // GEMM-side dummy memories (read+write ack)
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_i_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(i_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_w_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(w_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_sz_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(sz_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_o_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(o_dma_gemm_bus_if.slave));

  // MMIO model: alloc success + occupy/working complete
  vx_lsu_mmio_model #(
    .NUM_LANES(1),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .MEM_BYTES(64*1024),
    .DMA_CFG_BASE_ADDR(DMA_CFG_BASE_ADDR_TB),
    .DMA_ENTRY_STRIDE_BYTES(DMA_ENTRY_STRIDE_BYTES_TB),
    .LAT_DMA_DONE(LAT_DMA_DONE),

    // these match your VX_gemm_dma_ctrl defaults
    .ENTRYID_W(8),
    .CTRL_OWNER_W(1),
    .CTRL_GEN_W(16),

    .DMA_CTRL_START_BIT(0),
    .DMA_CTRL_OCCUPY_BIT(1),
    .DMA_CTRL_WORKING_BIT(2),
    .DMA_CTRL_OWNER_LSB(4),
    .DMA_CTRL_GEN_LSB(4 + 1),

    .VERBOSE(1)
  ) u_mmio (
    .clk(clk), .reset(reset), .mmio_if(dma_if.slave)
  );

  // ---------------------------------------------------------------------------
  // Reset / send_config
  // ---------------------------------------------------------------------------
  task automatic reset_dut();
    begin
      reset = 1'b1;

      cfg_reg_if.valid = 1'b0;
      cfg_reg_if.regs  = '0;
      cfg_reg_if.entry_id = '0;

      repeat (10) @(posedge clk);
      reset = 1'b0;
      repeat (5) @(posedge clk);
    end
  endtask

  task automatic send_config(
    input logic [63:0] input_base,
    input logic [63:0] weight_base,
    input logic [63:0] output_base,
    input logic [63:0] scale_base,
    input logic [63:0] zp_base,

    input logic [63:0] lmem_ibuf0_base,
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base,

    input logic [31:0] M,
    input logic [31:0] N,
    input logic [31:0] K,
    input logic [31:0] qblk,

    input logic [31:0] entry_id_val
  );
    begin
      // wait until DUT ready
      do @(posedge clk); while (!cfg_reg_if.ready);

      @(negedge clk);
      cfg_reg_if.valid    = 1'b0;
      cfg_reg_if.entry_id = entry_id_val;

      for (int i = 0; i < 33; i++) cfg_reg_if.regs[i] = '0;

      cfg_reg_if.regs[0]  = 32'h1;

      cfg_reg_if.regs[1]  = input_base[31:0];
      cfg_reg_if.regs[2]  = input_base[63:32];

      cfg_reg_if.regs[3]  = weight_base[31:0];
      cfg_reg_if.regs[4]  = weight_base[63:32];

      cfg_reg_if.regs[5]  = output_base[31:0];
      cfg_reg_if.regs[6]  = output_base[63:32];

      cfg_reg_if.regs[7]  = scale_base[31:0];
      cfg_reg_if.regs[8]  = scale_base[63:32];

      cfg_reg_if.regs[9]  = zp_base[31:0];
      cfg_reg_if.regs[10] = zp_base[63:32];

      cfg_reg_if.regs[11] = lmem_ibuf0_base[31:0];
      cfg_reg_if.regs[12] = lmem_ibuf0_base[63:32];

      cfg_reg_if.regs[13] = lmem_ibuf1_base[31:0];
      cfg_reg_if.regs[14] = lmem_ibuf1_base[63:32];

      cfg_reg_if.regs[15] = lmem_wbuf0_base[31:0];
      cfg_reg_if.regs[16] = lmem_wbuf0_base[63:32];

      cfg_reg_if.regs[17] = lmem_wbuf1_base[31:0];
      cfg_reg_if.regs[18] = lmem_wbuf1_base[63:32];

      cfg_reg_if.regs[19] = lmem_scbuf0_base[31:0];
      cfg_reg_if.regs[20] = lmem_scbuf0_base[63:32];

      cfg_reg_if.regs[21] = lmem_scbuf1_base[31:0];
      cfg_reg_if.regs[22] = lmem_scbuf1_base[63:32];

      cfg_reg_if.regs[23] = lmem_zpbuf0_base[31:0];
      cfg_reg_if.regs[24] = lmem_zpbuf0_base[63:32];

      cfg_reg_if.regs[25] = lmem_zpbuf1_base[31:0];
      cfg_reg_if.regs[26] = lmem_zpbuf1_base[63:32];

      cfg_reg_if.regs[27] = lmem_obuf_base[31:0];
      cfg_reg_if.regs[28] = lmem_obuf_base[63:32];

      cfg_reg_if.regs[29] = M;
      cfg_reg_if.regs[30] = N;
      cfg_reg_if.regs[31] = K;
      cfg_reg_if.regs[32] = qblk;

      cfg_reg_if.valid = 1'b1;

      @(posedge clk);
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;

      @(posedge clk);

      $display("[%0t] CFG sent: M=%0d N=%0d K=%0d qblk=%0d entry_id=%0d",
              $time, M, N, K, qblk, entry_id_val);
    end
  endtask

  task automatic wait_cycles(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Pretty-print opcodes
  // ---------------------------------------------------------------------------
  function automatic [7:0] op_of(input gemm_unified_cmd_t c);
    return c.instr[7:0];
  endfunction

  function automatic string op_name(input logic [7:0] op);
    begin
      unique case (op)
        8'hF0: op_name = "WAIT";
        8'hF1: op_name = "NOTIFY";
        8'h10: op_name = "DMA_LD";
        8'h11: op_name = "DMA_ST";
        8'h20: op_name = "W_LDMA_MXU";
        8'h21: op_name = "SC_LDMA_MXU";
        8'h22: op_name = "I_LDMA_ARM";
        8'h23: op_name = "O_ACC2LMEM";
        8'h24: op_name = "ZP_LDMA_MXU";
        default: op_name = "OP_??";
      endcase
    end
  endfunction

  task automatic print_cmd(input string who, input gemm_unified_cmd_t c);
    logic [7:0] op;
    begin
      op = op_of(c);
      $display("[%0t] %-10s op=0x%02h (%s) instr=0x%016h rs1_data=0x%016h rs2_data=0x%016h",
               $time, who, op, op_name(op), c.instr, c.rs1_data, c.rs2_data);
    end
  endtask

  // log node0~4 start pulses (hierarchical)
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (dut.gemm_ctrl_if.input_read_ctrl.start) begin
        print_cmd("NODE0_IN", dut.gemm_ctrl_if.input_read_ctrl.cmd);
      end
      if (dut.gemm_ctrl_if.weight_read_ctrl.start) begin
        print_cmd("NODE1_W", dut.gemm_ctrl_if.weight_read_ctrl.cmd);
      end
      if (dut.gemm_ctrl_if.quant_param_read_ctrl.start) begin
        print_cmd("NODE2_QP", dut.gemm_ctrl_if.quant_param_read_ctrl.cmd);
      end
      if (dut.gemm_ctrl_if.output_write_ctrl.start) begin
        print_cmd("NODE3_OUT", dut.gemm_ctrl_if.output_write_ctrl.cmd);
      end
      if (dut.gemm_ctrl_if.dma_ctrl.start) begin
        print_cmd("NODE4_DMA", dut.gemm_ctrl_if.dma_ctrl.cmd);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Test
  // ---------------------------------------------------------------------------
  initial begin
    $timeformat(-9, 0, "ns", 0);
    $display("====================================");
    $display("  %s", TB_NAME);
    $display("====================================");

    reset_dut();

    send_config(
      64'h1000_0000, // input_base
      64'h2000_0000, // weight_base
      64'h3000_0000, // output_base
      64'h4000_0000, // scale_base
      64'h5000_0000, // zp_base

      64'h6000_0000, // lmem_ibuf0_base
      64'h7000_0000, // lmem_ibuf1_base
      64'h8000_0000, // lmem_wbuf0_base
      64'h9000_0000, // lmem_wbuf1_base
      64'hA000_0000, // lmem_scbuf0_base
      64'hB000_0000, // lmem_scbuf1_base
      64'hC000_0000, // lmem_zpbuf0_base
      64'hD000_0000, // lmem_zpbuf1_base
      64'hE000_0000, // lmem_obuf_base

      32'd256,       // M
      32'd256,       // N
      32'd256,       // K
      32'd32,        // qblk
      32'd0          // entry_id_val
    );

    wait_cycles(TOTAL_CYC);

    $display("====================================");
    $display("  FINISH");
    $display("====================================");
`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

  initial begin
    #(10*TOTAL_CYC);
    $display("[%0t] TIMEOUT -> finish", $time);
`ifdef VCS
    $fsdbDumpoff();
`else
    $dumpoff();
`endif
    $finish;
  end

endmodule

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
  wire is_read  = fire_req && ~bus_if.req_data.rw;
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

      if (~pending && is_read) begin
        pending          <= 1'b1;
        pending_rdata    <= make_data(bus_if.req_data.addr);
        pending_tag_bits <= bus_if.req_data.tag;
      end
      // writes ignored
    end
  end
endmodule

//------------------------------------------------------------------------------
// MMIO model for VX_lsu_mem_if (VX_gemm_dma_ctrl uses this)
// - returns response for both reads and writes (1-cycle)
// - byte-addressable backing store
//
// ★ "CONTROL reg start bit auto-clear" (정확한 주소 기반):
//    control word byte addr = DMA_CFG_BASE_ADDR + entry*DMA_ENTRY_STRIDE_BYTES + 0
//    => (byte_addr - DMA_CFG_BASE_ADDR) % DMA_ENTRY_STRIDE_BYTES == 0..3  (word 범위)
//    => 특히 offset==0 byte에서 bit0이 1로 써지면 "start"로 간주하고
//       LAT_DMA_DONE 후 그 byte bit0만 clear
//------------------------------------------------------------------------------
module vx_lsu_mmio_model #(
  parameter int NUM_LANES    = 1,
  parameter int DATA_SIZE    = 16,
  parameter int TAG_WIDTH    = 16,
  parameter int MEM_BYTES    = 64*1024,
  parameter int ADDR_WIDTH   = (`MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)),

  // ★ config register mapping (must match VX_gemm_dma_ctrl params)
  parameter logic [63:0] DMA_CFG_BASE_ADDR      = 64'h0,
  parameter int          DMA_ENTRY_STRIDE_BYTES = 64,     // 16 regs * 4B
  parameter int          LAT_DMA_DONE           = 50,

  // logging
  parameter bit          VERBOSE                = 1
) (
  input  wire clk,
  input  wire reset,
  VX_lsu_mem_if.slave mmio_if
);
  byte mem [0:MEM_BYTES-1];

  // one outstanding response
  logic pending;

  // rsp fields (raw bits to avoid typedef mismatch)
  logic [TAG_WIDTH-1:0] pending_tag_bits;
  logic [NUM_LANES-1:0] pending_mask;
  logic [NUM_LANES-1:0][DATA_SIZE*8-1:0] pending_data;

  assign mmio_if.req_ready = ~pending;
  assign mmio_if.rsp_valid = pending;

  // pack response
  always_comb begin
    mmio_if.rsp_data       = '0;
    mmio_if.rsp_data.tag   = pending_tag_bits;
    mmio_if.rsp_data.mask  = pending_mask;
    mmio_if.rsp_data.data  = pending_data;
  end

  wire fire_req = mmio_if.req_valid && mmio_if.req_ready;
  wire fire_rsp = mmio_if.rsp_valid && mmio_if.rsp_ready;

  function automatic int unsigned lane_byte_base(input logic [ADDR_WIDTH-1:0] a_lane);
    return int'(a_lane) * DATA_SIZE; // addr is in DATA_SIZE-byte units
  endfunction

  function automatic bit is_control_word_byte(input longint unsigned byte_addr, output int unsigned off_in_entry);
    longint unsigned diff;
    begin
      off_in_entry = 0;
      if (byte_addr < DMA_CFG_BASE_ADDR) return 0;
      diff = byte_addr - DMA_CFG_BASE_ADDR;
      if (DMA_ENTRY_STRIDE_BYTES <= 0) return 0;
      off_in_entry = int'(diff % DMA_ENTRY_STRIDE_BYTES);
      // CONTROL reg is first 32-bit word => byte offsets 0..3
      return (off_in_entry < 4);
    end
  endfunction

  // --------------------------------------------------------------------------
  // start-bit auto-clear state
  // --------------------------------------------------------------------------
  logic        pend_clear;
  int unsigned clear_cnt;
  int unsigned clear_byte_addr; // which byte contains bit0 (CONTROL LSB byte)

  integer li, bi;

  always_ff @(posedge clk) begin
    if (reset) begin
      pending          <= 1'b0;
      pending_tag_bits <= '0;
      pending_mask     <= '0;
      pending_data     <= '0;

      pend_clear      <= 1'b0;
      clear_cnt       <= 0;
      clear_byte_addr <= 0;

      for (bi = 0; bi < MEM_BYTES; bi++) begin
        mem[bi] <= 8'h00;
      end
    end else begin
      // countdown and clear start bit
      if (pend_clear) begin
        if (clear_cnt == 0) begin
          if (clear_byte_addr < MEM_BYTES) begin
            mem[clear_byte_addr] <= mem[clear_byte_addr] & 8'hFE; // clear bit0 only
            if (VERBOSE) $display("[%0t] DMA_DONE auto-clear CONTROL.start @byte_addr=0x%0h", $time, clear_byte_addr);
          end
          pend_clear <= 1'b0;
        end else begin
          clear_cnt <= clear_cnt - 1;
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

        for (li = 0; li < NUM_LANES; li++) begin
          if (mmio_if.req_data.mask[li]) begin
            int unsigned base;
            base = lane_byte_base(mmio_if.req_data.addr[li]);

            if (mmio_if.req_data.rw) begin
              // WRITE
              for (bi = 0; bi < DATA_SIZE; bi++) begin
                if (mmio_if.req_data.byteen[li][bi]) begin
                  int unsigned baddr;
                  baddr = base + bi;

                  if (baddr < MEM_BYTES) begin
                    byte newb;
                    int unsigned off_in_entry;
                    bit is_ctrl_word;

                    newb = mmio_if.req_data.data[li][bi*8 +: 8];
                    mem[baddr] <= newb;

                    // detect CONTROL.start set
                    is_ctrl_word = is_control_word_byte(baddr, off_in_entry);
                    if (is_ctrl_word && (off_in_entry == 0) && newb[0]) begin
                      pend_clear      <= 1'b1;
                      clear_cnt       <= LAT_DMA_DONE;
                      clear_byte_addr <= baddr;
                      if (VERBOSE) $display("[%0t] DMA_START detected (CONTROL.start=1) @byte_addr=0x%0h -> will clear after %0d cycles",
                                            $time, baddr, LAT_DMA_DONE);
                    end
                  end
                end
              end
              pending_data[li] <= '0;

            end else begin
              // READ
              logic [DATA_SIZE*8-1:0] rtmp;
              rtmp = '0;
              for (bi = 0; bi < DATA_SIZE; bi++) begin
                if ((base + bi) < MEM_BYTES) begin
                  rtmp[bi*8 +: 8] = mem[base + bi];
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
// alloc stub for VX_config_entry_alloc_if
//------------------------------------------------------------------------------
module vx_alloc_stub #(
  parameter int OWNER_W   = 32,
  parameter int ENTRYID_W = 8
) (
  input  wire clk,
  input  wire reset,
  VX_config_entry_alloc_if.slave alloc_if
);
  logic [ENTRYID_W-1:0] next_id;

  assign alloc_if.ready    = 1'b1;
  assign alloc_if.entry_id = next_id;

  always_ff @(posedge clk) begin
    if (reset) begin
      next_id <= '0;
    end else if (alloc_if.valid && alloc_if.ready) begin
      next_id <= next_id + 1'b1;
    end
  end
endmodule

//------------------------------------------------------------------------------
// TB: VX_gemm_ctrl_with_ldma + VX_local_mem
//------------------------------------------------------------------------------
module tb_VX_gemm_ctrl_with_ldma;
  import VX_gpu_pkg::*;

  localparam TOTAL_CYC = 100000*50;

  localparam string TB_NAME     = "tb_VX_gemm_ctrl_with_ldma";
  localparam string INSTANCE_ID = "tb";

  localparam real PERIOD = 10.0;

  // emulate DMA completion latency (CONTROL.start auto-clear)
  localparam int LAT_DMA_DONE = 80;

  // IMPORTANT: must match VX_gemm_dma_ctrl defaults (or your overridden params)
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

  // cfg interface: 33 regs x 32b
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

  VX_config_entry_alloc_if #(.OWNER_W(32), .ENTRYID_W(8)) alloc_if();

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
    .alloc_if(alloc_if.master)
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

  // GEMM-side dummy memories
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_i_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(i_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_w_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(w_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_sz_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(sz_dma_gemm_bus_if.slave));
  vx_mem_bus_dummy_slave #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_MEM_TAG_WIDTH)) u_o_gemm_mem
    (.clk(clk), .reset(reset), .bus_if(o_dma_gemm_bus_if.slave));

  // ★ MMIO model: CONTROL.start auto-clear using base/stride mapping (+ verbose)
  vx_lsu_mmio_model #(
    .NUM_LANES(1),
    .DATA_SIZE(LSU_WORD_SIZE),
    .TAG_WIDTH(GEMM_MEM_TAG_WIDTH),
    .MEM_BYTES(64*1024),
    .DMA_CFG_BASE_ADDR(DMA_CFG_BASE_ADDR_TB),
    .DMA_ENTRY_STRIDE_BYTES(DMA_ENTRY_STRIDE_BYTES_TB),
    .LAT_DMA_DONE(LAT_DMA_DONE),
    .VERBOSE(1)
  ) u_mmio (
    .clk(clk), .reset(reset), .mmio_if(dma_if.slave)
  );

  // Allocator stub
  vx_alloc_stub #(.OWNER_W(32), .ENTRYID_W(8)) u_alloc
    (.clk(clk), .reset(reset), .alloc_if(alloc_if.slave));

  // ---------------------------------------------------------------------------
  // Reset / send_config
  // ---------------------------------------------------------------------------
  task automatic reset_dut();
    begin
      reset = 1'b1;

      cfg_reg_if.valid = 1'b0;
      cfg_reg_if.regs  = '0;
      cfg_reg_if.wid   = '0;
      cfg_reg_if.tid   = '0;

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

    input logic [31:0] wid_val,
    input logic [31:0] tid_val
  );
    begin
      @(posedge clk);

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

      cfg_reg_if.wid   = wid_val;
      cfg_reg_if.tid   = tid_val;
      cfg_reg_if.valid = 1'b1;

      @(posedge clk);

      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      @(posedge clk);

      $display("[%0t] CFG sent: M=%0d N=%0d K=%0d qblk=%0d wid=%0d tid=%0d",
               $time, M, N, K, qblk, wid_val, tid_val);
    end
  endtask

  task automatic wait_cycles(input int unsigned n);
    for (int unsigned i = 0; i < n; i++) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Pretty-print opcodes (same names you used)
  // ---------------------------------------------------------------------------
  localparam logic [7:0] OP_WAIT   = 8'hF0;
  localparam logic [7:0] OP_NOTIFY = 8'hF1;

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

  // ---------------------------------------------------------------------------
  // ★ REQUIRED: log node0~4 start ALWAYS when start pulses happen
  //
  // Note: In VX_gemm_ctrl_with_ldma, gemm_ctrl_if is an internal interface.
  // We access it hierarchically through dut.gemm_ctrl_if.*.start/cmd exactly
  // like you already did earlier.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (dut.gemm_ctrl_if.input_read_ctrl.start) begin
        print_cmd("NODE0_IN", dut.gemm_ctrl_if.input_read_ctrl.cmd);
        $display("[%0t] NODE0 start", $time);
      end
      if (dut.gemm_ctrl_if.weight_read_ctrl.start) begin
        print_cmd("NODE1_W", dut.gemm_ctrl_if.weight_read_ctrl.cmd);
        $display("[%0t] NODE1 start", $time);
      end
      if (dut.gemm_ctrl_if.quant_param_read_ctrl.start) begin
        print_cmd("NODE2_QP", dut.gemm_ctrl_if.quant_param_read_ctrl.cmd);
        $display("[%0t] NODE2 start", $time);
      end
      if (dut.gemm_ctrl_if.output_write_ctrl.start) begin
        print_cmd("NODE3_OUT", dut.gemm_ctrl_if.output_write_ctrl.cmd);
        $display("[%0t] NODE3 start", $time);
      end
      if (dut.gemm_ctrl_if.dma_ctrl.start) begin
        print_cmd("NODE4_DMA", dut.gemm_ctrl_if.dma_ctrl.cmd);
        $display("[%0t] NODE4 start", $time);
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
      32'd0, 32'd0   // wid, tid
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

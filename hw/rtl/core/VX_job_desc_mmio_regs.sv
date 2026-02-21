`include "VX_define.vh"

// ============================================================================
// VX_job_desc_mmio_regs
//  - Owns descriptor register storage and MMIO R/W
//  - Global ALLOC register (atomic): read allocates one free entry (RR)
//  - Receives state update commands from dispatcher
//  - CONTROL(reg 0) bit policy:
//      [0]                     valid      : RW
//      [1]                     occupy     : RO (writes ignored, mirrored from state)
//      [2]                     working    : RO (writes ignored, mirrored from state)
//      [3 +: OWNER_W]          owner      : RO (writes ignored, mirrored from state)
//      [CTRL_GEN_LSB +: GEN_W] generation : RO (writes ignored, mirrored from state)
// ============================================================================
module VX_job_desc_mmio_regs import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID        = "",
  parameter int NUM_ENTRIES            = 16,
  parameter int NUM_REGS32             = 16,
  parameter int ENTRYID_W              = `JOB_MMIO_ENTRYID_W,
  parameter int OWNER_W                = `JOB_MMIO_OWNER_W,
  parameter bit OWNER_FROM_TAG         = 1'b0,
  parameter int GEN_W                  = `JOB_MMIO_GEN_W,
  parameter logic [63:0] CFG_BASE_ADDR = 64'h0
) (
  input  wire clk,
  input  wire reset,

  VX_lsu_mem_if.slave            mmio_if,

  input  wire                    disp_set_working_valid_i,
  input  wire [ENTRYID_W-1:0]    disp_set_working_entry_id_i,
  input  wire                    disp_clear_entry_valid_i,
  input  wire [ENTRYID_W-1:0]    disp_clear_entry_id_i,

  output logic [NUM_ENTRIES-1:0] valid_o,
  output logic [NUM_ENTRIES-1:0] occupy_o,
  output logic [NUM_ENTRIES-1:0] working_o,
  output logic [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32_o
);

  // ------------------------------------------------------------
  // internal state
  // ------------------------------------------------------------
  logic [NUM_ENTRIES-1:0] occupy_q,  occupy_d;
  logic [NUM_ENTRIES-1:0] working_q, working_d;
  logic [NUM_ENTRIES-1:0][OWNER_W-1:0] owner_q, owner_d;
  logic [NUM_ENTRIES-1:0][GEN_W-1:0] generation_q, generation_d;
  logic [NUM_ENTRIES-1:0][NUM_REGS32-1:0][31:0] regs32_q, regs32_d;

  localparam int RRW = (NUM_ENTRIES <= 1) ? 1 : $clog2(NUM_ENTRIES);
  logic [RRW-1:0] rr_alloc_q, rr_alloc_d;

  localparam int CONTROL_IDX       = `JOB_MMIO_CONTROL_REG_IDX;
  localparam int CTRL_VALID_BIT    = `JOB_MMIO_CTRL_VALID_BIT;
  localparam int CTRL_OCCUPY_BIT   = `JOB_MMIO_CTRL_OCCUPY_BIT;
  localparam int CTRL_WORKING_BIT  = `JOB_MMIO_CTRL_WORKING_BIT;
  localparam int CTRL_OWNER_LSB    = `JOB_MMIO_CTRL_OWNER_LSB;
  localparam int CTRL_GEN_LSB      = `JOB_MMIO_CTRL_GEN_LSB;

  localparam int ALLOC_SUCCESS_BIT = `JOB_MMIO_ALLOC_SUCC_BIT;
  localparam int ALLOC_ENTRY_LSB   = `JOB_MMIO_ALLOC_ENTRY_LSB;
  localparam int ALLOC_ENTRY_BITS  = `JOB_MMIO_ALLOC_ENTRY_BITS;
  localparam int ALLOC_OWNER_LSB   = `JOB_MMIO_ALLOC_OWNER_LSB;
  localparam int ALLOC_OWNER_BITS  = `JOB_MMIO_ALLOC_OWNER_BITS;
  localparam int ALLOC_GEN_LSB     = `JOB_MMIO_ALLOC_GEN_LSB;
  localparam int ALLOC_GEN_BITS    = `JOB_MMIO_ALLOC_GEN_BITS;
  localparam int ALLOC_ENTRY_COPY_BITS = (ALLOC_ENTRY_BITS < ENTRYID_W) ? ALLOC_ENTRY_BITS : ENTRYID_W;
  localparam int ALLOC_OWNER_COPY_BITS = (ALLOC_OWNER_BITS < OWNER_W) ? ALLOC_OWNER_BITS : OWNER_W;
  localparam int ALLOC_GEN_COPY_BITS   = (ALLOC_GEN_BITS < GEN_W) ? ALLOC_GEN_BITS : GEN_W;

  // ------------------------------------------------------------
  // MMIO layout
  //   [CFG_BASE_ADDR + 0 .. +DATA_SIZE-1] : global alloc register
  //   [CFG_BASE_ADDR + DATA_SIZE .. ]      : per-entry descriptor beats
  // ------------------------------------------------------------
  localparam int WORDS_PER_BEAT    = (mmio_if.DATA_SIZE / 4);
  localparam int NUM_BEATS         = (NUM_REGS32 + WORDS_PER_BEAT - 1) / WORDS_PER_BEAT;
  localparam int ENTRY_STRIDE_B    = NUM_BEATS * mmio_if.DATA_SIZE;
  localparam int GLOBAL_ALLOC_B    = mmio_if.DATA_SIZE;
  localparam int ENTRY_BASE_OFF_B  = GLOBAL_ALLOC_B;

  initial begin
    if ((mmio_if.DATA_SIZE % 4) != 0) $fatal(1, "%s: mmio_if.DATA_SIZE must be multiple of 4", INSTANCE_ID);
    if (WORDS_PER_BEAT <= 0)          $fatal(1, "%s: WORDS_PER_BEAT invalid", INSTANCE_ID);
    if (ENTRYID_W < $clog2(NUM_ENTRIES)) $fatal(1, "%s: ENTRYID_W too small", INSTANCE_ID);
    if (OWNER_W <= 0)                 $fatal(1, "%s: OWNER_W must be >= 1", INSTANCE_ID);
    if (GEN_W <= 0)                   $fatal(1, "%s: GEN_W must be >= 1", INSTANCE_ID);
    if ((CTRL_GEN_LSB + GEN_W) > 32)  $fatal(1, "%s: CONTROL owner/gen bits exceed 32b", INSTANCE_ID);
  end

  // ------------------------------------------------------------
  // MMIO address decode
  // ------------------------------------------------------------
  localparam int LSU_ADDR_SHIFT = `CLOG2(mmio_if.DATA_SIZE);

  function automatic logic [63:0] addr_to_byte(input logic [mmio_if.ADDR_WIDTH-1:0] a);
    return (64'(a) << LSU_ADDR_SHIFT);
  endfunction

  function automatic logic [63:0] get_off(input logic [63:0] byte_addr);
    return (byte_addr >= CFG_BASE_ADDR) ? (byte_addr - CFG_BASE_ADDR)
                                        : 64'hFFFF_FFFF_FFFF_FFFF;
  endfunction

  function automatic logic is_alloc_reg(input logic [63:0] off);
    return (off < 64'(GLOBAL_ALLOC_B));
  endfunction

  function automatic logic in_entry_range(input logic [63:0] off);
    return (off >= 64'(ENTRY_BASE_OFF_B))
        && (off < (64'(ENTRY_BASE_OFF_B) + 64'(NUM_ENTRIES) * 64'(ENTRY_STRIDE_B)));
  endfunction

  function automatic logic [ENTRYID_W-1:0] off_to_entry(input logic [63:0] off);
    logic [63:0] e;
    logic [63:0] x;
    begin
      x = off - 64'(ENTRY_BASE_OFF_B);
      e = x / 64'(ENTRY_STRIDE_B);
      return e[ENTRYID_W-1:0];
    end
  endfunction

  function automatic int off_to_beatidx(input logic [63:0] off);
    logic [63:0] x;
    logic [63:0] entry_off;
    begin
      x = off - 64'(ENTRY_BASE_OFF_B);
      entry_off = x % 64'(ENTRY_STRIDE_B);
      return int'(entry_off / 64'(mmio_if.DATA_SIZE));
    end
  endfunction

  function automatic logic [31:0] pack_alloc_rsp(
      input logic success,
      input logic [ENTRYID_W-1:0] entry_id,
      input logic [OWNER_W-1:0] owner_id,
      input logic [GEN_W-1:0] generation
  );
    logic [31:0] w;
    begin
      w = '0;
      w[ALLOC_SUCCESS_BIT] = success;
      if (ALLOC_ENTRY_COPY_BITS > 0) begin
        w[ALLOC_ENTRY_LSB +: ALLOC_ENTRY_COPY_BITS] = entry_id[ALLOC_ENTRY_COPY_BITS-1:0];
      end
      if (ALLOC_OWNER_COPY_BITS > 0) begin
        w[ALLOC_OWNER_LSB +: ALLOC_OWNER_COPY_BITS] = owner_id[ALLOC_OWNER_COPY_BITS-1:0];
      end
      if (ALLOC_GEN_COPY_BITS > 0) begin
        w[ALLOC_GEN_LSB +: ALLOC_GEN_COPY_BITS] = generation[ALLOC_GEN_COPY_BITS-1:0];
      end
      return w;
    end
  endfunction

  // ------------------------------------------------------------
  // MMIO response registers
  // ------------------------------------------------------------
  logic rsp_valid_q, rsp_valid_d;
  logic [mmio_if.NUM_LANES-1:0] rsp_mask_q, rsp_mask_d;
  logic [mmio_if.NUM_LANES-1:0][mmio_if.DATA_SIZE*8-1:0] rsp_data_q, rsp_data_d;
  logic [$bits(mmio_if.rsp_data.tag)-1:0] rsp_tag_q, rsp_tag_d;

  logic [63:0]          byte_addr;
  logic [63:0]          off;
  logic [ENTRYID_W-1:0] eid;
  int                   beat_idx;
  int                   base32;
  int                   r32;
  logic [31:0]          old_w, new_w;
  logic [OWNER_W-1:0]   req_owner;

  int                   set_work_e;
  int                   clear_e;
  int                   alloc_sel_e;
  int                   alloc_probe_e;
  int                   next_alloc;
  logic                 alloc_success;
  logic                 alloc_taken;
  logic                 rsp_holding;

  // ------------------------------------------------------------
  // next-state + outputs
  // ------------------------------------------------------------
  always_comb begin
    regs32_d     = regs32_q;
    occupy_d     = occupy_q;
    working_d    = working_q;
    owner_d      = owner_q;
    generation_d = generation_q;
    rr_alloc_d   = rr_alloc_q;

    // If previous read response is still pending and requester is not ready,
    // stall new requests until response handshake completes.
    rsp_holding       = rsp_valid_q && ~mmio_if.rsp_ready;
    mmio_if.req_ready = ~rsp_holding;

    // Hold response payload by default until handshake.
    rsp_valid_d = rsp_valid_q;
    rsp_mask_d  = rsp_mask_q;
    rsp_data_d  = rsp_data_q;
    rsp_tag_d   = rsp_tag_q;

    // Drop response after successful handshake.
    if (rsp_valid_q && mmio_if.rsp_ready) begin
      rsp_valid_d = 1'b0;
      rsp_mask_d  = '0;
      rsp_data_d  = '0;
      rsp_tag_d   = '0;
    end

    byte_addr   = '0;
    off         = '0;
    eid         = '0;
    beat_idx    = 0;
    base32      = 0;
    r32         = 0;
    old_w       = '0;
    new_w       = '0;
    req_owner   = '0;

    set_work_e  = 0;
    clear_e     = 0;
    alloc_sel_e = -1;
    alloc_probe_e = 0;
    next_alloc  = 0;
    alloc_success = 1'b0;
    alloc_taken   = 1'b0;

    // dispatcher updates
    if (disp_set_working_valid_i) begin
      set_work_e = int'(disp_set_working_entry_id_i);
      if (set_work_e >= 0 && set_work_e < NUM_ENTRIES && occupy_q[set_work_e]) begin
        working_d[set_work_e] = 1'b1;
      end
    end

    if (disp_clear_entry_valid_i) begin
      clear_e = int'(disp_clear_entry_id_i);
      if (clear_e >= 0 && clear_e < NUM_ENTRIES && occupy_q[clear_e] && working_q[clear_e]) begin
        regs32_d[clear_e][CONTROL_IDX][CTRL_VALID_BIT] = 1'b0;
        occupy_d[clear_e]     = 1'b0;
        working_d[clear_e]    = 1'b0;
        owner_d[clear_e]      = '0;
      end
    end

    // MMIO request handling
    if (mmio_if.req_valid && mmio_if.req_ready) begin
      if (OWNER_FROM_TAG) begin
        req_owner  = mmio_if.req_data.tag[OWNER_W-1:0];
      end else begin
        req_owner  = '0;
      end
      rsp_valid_d = ~mmio_if.req_data.rw;
      rsp_mask_d  = mmio_if.req_data.mask;
      rsp_tag_d   = mmio_if.req_data.tag;
      rsp_data_d  = '0;

      for (int l = 0; l < mmio_if.NUM_LANES; l++) begin
        if (mmio_if.req_data.mask[l]) begin
          byte_addr = addr_to_byte(mmio_if.req_data.addr[l]);
          off       = get_off(byte_addr);

          if (~mmio_if.req_data.rw && is_alloc_reg(off)) begin
            // Global alloc read: lane0 only to avoid ambiguous multi-lane side effects.
            if (!alloc_taken && (l == 0)) begin
              alloc_success = 1'b0;
              alloc_sel_e   = -1;
              for (int k = 0; k < NUM_ENTRIES; k++) begin
                alloc_probe_e = (int'(rr_alloc_q) + k) % NUM_ENTRIES;
                if (!occupy_d[alloc_probe_e]) begin
                  alloc_success = 1'b1;
                  alloc_sel_e   = alloc_probe_e;
                  break;
                end
              end

              if (alloc_success) begin
                occupy_d[alloc_sel_e]     = 1'b1;
                working_d[alloc_sel_e]    = 1'b0;
                owner_d[alloc_sel_e]      = req_owner;
                generation_d[alloc_sel_e] = generation_q[alloc_sel_e] + GEN_W'(1);
                next_alloc = (alloc_sel_e + 1) % NUM_ENTRIES;
                rr_alloc_d = next_alloc[RRW-1:0];
                rsp_data_d[l][0 +: 32] = pack_alloc_rsp(
                    1'b1,
                    ENTRYID_W'(alloc_sel_e),
                    req_owner,
                    generation_d[alloc_sel_e]
                );
              end else begin
                rsp_data_d[l][0 +: 32] = 32'd0;
              end
            end else begin
              rsp_data_d[l] = '0;
            end
            alloc_taken = 1'b1;

          end else if (in_entry_range(off)) begin
            eid      = off_to_entry(off);
            beat_idx = off_to_beatidx(off);
            base32   = beat_idx * WORDS_PER_BEAT;

            if (mmio_if.req_data.rw) begin
              // write: beat -> regs32 merge write
              for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                r32 = base32 + i;
                if (r32 < NUM_REGS32) begin
                  old_w = regs32_q[eid][r32];
                  new_w = old_w;

                  for (int b = 0; b < 4; b++) begin
                    if (mmio_if.req_data.byteen[l][i*4 + b]) begin
                      new_w[b*8 +: 8] = mmio_if.req_data.data[l][i*32 + b*8 +: 8];
                    end
                  end

                  // CONTROL bit1/bit2 are read-only
                  if (r32 == CONTROL_IDX) begin
                    new_w[CTRL_OCCUPY_BIT]  = old_w[CTRL_OCCUPY_BIT];
                    new_w[CTRL_WORKING_BIT] = old_w[CTRL_WORKING_BIT];
                    new_w[CTRL_OWNER_LSB +: OWNER_W] = old_w[CTRL_OWNER_LSB +: OWNER_W];
                    new_w[CTRL_GEN_LSB +: GEN_W]     = old_w[CTRL_GEN_LSB +: GEN_W];
                  end

                  regs32_d[eid][r32] = new_w;
                end
              end
            end else begin
              // read: regs32 -> beat pack
              rsp_data_d[l] = '0;
              for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                r32 = base32 + i;
                if (r32 < NUM_REGS32) begin
                  rsp_data_d[l][i*32 +: 32] = regs32_q[eid][r32];
                end
              end
            end
          end else begin
            if (!mmio_if.req_data.rw) begin
              rsp_data_d[l] = '0;
            end
          end
        end
      end
    end

    // Keep CONTROL[1]/[2] mirrored from entry state
    for (int e = 0; e < NUM_ENTRIES; e++) begin
      regs32_d[e][CONTROL_IDX][CTRL_OCCUPY_BIT]  = occupy_d[e];
      regs32_d[e][CONTROL_IDX][CTRL_WORKING_BIT] = working_d[e];
      regs32_d[e][CONTROL_IDX][CTRL_OWNER_LSB +: OWNER_W] = owner_d[e];
      regs32_d[e][CONTROL_IDX][CTRL_GEN_LSB +: GEN_W]     = generation_d[e];
    end
  end

  // ------------------------------------------------------------
  // state update
  // ------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      regs32_q     <= '0;
      occupy_q     <= '0;
      working_q    <= '0;
      owner_q      <= '0;
      generation_q <= '0;
      rr_alloc_q   <= '0;

      rsp_valid_q  <= 1'b0;
      rsp_mask_q   <= '0;
      rsp_data_q   <= '0;
      rsp_tag_q    <= '0;
    end else begin
      regs32_q     <= regs32_d;
      occupy_q     <= occupy_d;
      working_q    <= working_d;
      owner_q      <= owner_d;
      generation_q <= generation_d;
      rr_alloc_q   <= rr_alloc_d;

      rsp_valid_q  <= rsp_valid_d;
      rsp_mask_q   <= rsp_mask_d;
      rsp_data_q   <= rsp_data_d;
      rsp_tag_q    <= rsp_tag_d;
    end
  end

  assign mmio_if.rsp_valid     = rsp_valid_q;
  assign mmio_if.rsp_data.mask = rsp_mask_q;
  assign mmio_if.rsp_data.data = rsp_data_q;
  assign mmio_if.rsp_data.tag  = rsp_tag_q;

  assign occupy_o     = occupy_q;
  assign working_o    = working_q;
  assign regs32_o     = regs32_q;
  always_comb begin
    for (int e = 0; e < NUM_ENTRIES; e++) begin
      valid_o[e] = regs32_q[e][CONTROL_IDX][CTRL_VALID_BIT];
    end
  end

endmodule

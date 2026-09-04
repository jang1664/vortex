`timescale 1ns/1ps

// The 2D burst-reorder form in VX_gemm_tmem_dma_ctrl requires
// PLATFORM_MEMORY_NUM_BANKS >= NUM_CHANNELS. Default VX_config.vh value
// is 2, which would trigger the `$fatal` elaboration guard. Pin it to 32
// here (the production value from hw_config.sh) so that
// NUM_BURST_GROUPS == PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS == 4.
// Unconditional define mirrors the Makefile flow used for end-to-end sim.
`ifndef PLATFORM_MEMORY_NUM_BANKS
  `define PLATFORM_MEMORY_NUM_BANKS 32
`endif

`include "VX_define.vh"

module tb_VX_gemm_tmem_dma_ctrl;
  import VX_gpu_pkg::*;

  localparam int CLK_PERIOD_NS = 10;
  localparam int NUM_CHANNELS  = 8;
  localparam int CFG_NUM       = `DMA_CFG_REG_NUM;
  localparam int HBM_MEM_BYTES = 1 << 20;
  localparam int TMEM_MEM_BYTES = 1 << 16;

  localparam int DMA_R_CONTROL     = 0;
  localparam int DMA_R_DST_BASE_LO = 1;
  localparam int DMA_R_DST_BASE_HI = 2;
  localparam int DMA_R_SRC_BASE_LO = 3;
  localparam int DMA_R_SRC_BASE_HI = 4;
  localparam int DMA_R_SRC_ST0     = 5;
  localparam int DMA_R_DST_ST0     = 6;
  localparam int DMA_R_SRC_ST1     = 7;
  localparam int DMA_R_DST_ST1     = 8;
  localparam int DMA_R_SRC_ST2     = 9;
  localparam int DMA_R_DST_ST2     = 10;
  localparam int DMA_R_BND0        = 11;
  localparam int DMA_R_BND1        = 12;
  localparam int DMA_R_BND2        = 13;
  localparam int DMA_R_SEG_SIZE    = 14;
  localparam int DMA_R_PAD         = 15;
  localparam int DMA_R_DIR         = 16;

  localparam logic [3:0] OP_DMA_LD = 4'd1;
  localparam logic [3:0] OP_DMA_ST = 4'd2;
  localparam logic [3:0] OP_NOTIFY = 4'd3;

  logic clk = 1'b0;
  logic reset;
  always #(CLK_PERIOD_NS/2) clk = ~clk;

  VX_gemm_dma_ctrl_if gemm_dma_ctrl_if();
  VX_gemm_sync_if     gemm_sync_if();

  VX_config_reg_if #(
    .NUM(CFG_NUM),
    .DW(32)
  ) cfg_reg_if [NUM_CHANNELS] ();

  VX_node_done_if done_if [NUM_CHANNELS] ();
  VX_dma_lookahead_if dma_lookahead_if [NUM_CHANNELS] ();
  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_lookahead_tieoff
    assign dma_lookahead_if[ch].prepare_ready = 1'b0;
    assign dma_lookahead_if[ch].result_ready = '0;
  end

  VX_gemm_tmem_dma_ctrl #(
    .INSTANCE_ID("tb"),
    .NUM_CHANNELS(NUM_CHANNELS)
  ) dut (
    .clk(clk),
    .reset(reset),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .store_done(),
    .gemm_sync_if(gemm_sync_if),
    .cfg_reg_if(cfg_reg_if),
    .lookahead_if(dma_lookahead_if),
    .done_if(done_if)
  );

  logic [NUM_CHANNELS-1:0]                     cfg_seen;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_seen;
  int                                          cfg_seen_count;
  logic                                        notify_seen;
  logic [31:0]                                 notify_reg_seen;
  logic [31:0]                                 notify_val_seen;
  logic [NUM_CHANNELS-1:0]                     cfg_valid_s;
  logic [NUM_CHANNELS-1:0]                     cfg_ready_s;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_s;
  logic [NUM_CHANNELS-1:0]                     done_valid_s;
  logic [NUM_CHANNELS-1:0][31:0]               done_entry_s;
  byte unsigned                                hbm_mem [0:HBM_MEM_BYTES-1];
  byte unsigned                                tmem_mem [0:NUM_CHANNELS-1][0:TMEM_MEM_BYTES-1];

  task automatic clear_done_inputs;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      done_valid_s[ch] = 1'b0;
      done_entry_s[ch] = '0;
    end
  endtask

  task automatic clear_cfg_scoreboard;
    cfg_seen_count = 0;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      cfg_seen[ch]     = 1'b0;
      cfg_regs_seen[ch] = '0;
    end
  endtask

  task automatic clear_notify_scoreboard;
    notify_seen     = 1'b0;
    notify_reg_seen = '0;
    notify_val_seen = '0;
  endtask

  task automatic pulse_start;
    gemm_dma_ctrl_if.start <= 1'b1;
    @(posedge clk);
    gemm_dma_ctrl_if.start <= 1'b0;
  endtask

  task automatic wait_done_or_timeout(input int unsigned max_cycles, input string tag);
    int unsigned c;
    c = 0;
    while (gemm_dma_ctrl_if.idle && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles)
      $fatal(1, "[%s] timeout: never left idle", tag);

    while (!gemm_dma_ctrl_if.done && (c < max_cycles)) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cycles)
      $fatal(1, "[%s] timeout: done not asserted", tag);

    @(posedge clk);
  endtask

  task automatic drive_done_for_active_channels;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (cfg_seen[ch]) begin
        done_valid_s[ch] = 1'b1;
        done_entry_s[ch] = 32'd0;
      end
    end
    @(posedge clk);
    clear_done_inputs();
  endtask

  task automatic expect_cfg_count(input int exp_count, input string tag);
    int got_count;
    got_count = 0;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (cfg_seen[ch])
        got_count++;
    end
    if (got_count != exp_count)
      $fatal(1, "[%s] cfg_seen_count mismatch: got=%0d exp=%0d", tag, got_count, exp_count);
  endtask

  task automatic expect_channel_active(input int ch, input bit exp_active, input string tag);
    if (cfg_seen[ch] !== exp_active)
      $fatal(1, "[%s] channel %0d active mismatch: got=%0b exp=%0b", tag, ch, cfg_seen[ch], exp_active);
  endtask

  task automatic expect_cfg_reg(input int ch, input int reg_idx, input logic [31:0] exp, input string tag);
    logic [31:0] got;
    got = cfg_regs_seen[ch][reg_idx];
    if (got !== exp)
      $fatal(1, "[%s] ch%0d reg[%0d] mismatch: got=0x%08x exp=0x%08x", tag, ch, reg_idx, got, exp);
  endtask

  function automatic logic [31:0] make_instr(input logic [3:0] op, input logic [27:0] size_bytes);
    return {size_bytes, op};
  endfunction

  function automatic logic [63:0] exp_tmem_bank_local_byte_addr(input logic [63:0] byte_addr);
    logic [63:0] low_off;
    logic [63:0] bank_local_beat;
    begin
      low_off = byte_addr & 64'h3f;
      bank_local_beat = byte_addr >> 9;
      return (bank_local_beat << 6) | low_off;
    end
  endfunction

  function automatic logic [2:0] exp_tmem_bank_idx(input logic [63:0] byte_addr);
    return byte_addr[8:6];
  endfunction

  function automatic byte unsigned pattern8(input logic [63:0] addr);
    logic [7:0] mixed;
    begin
      mixed = addr[7:0] ^ addr[15:8] ^ 8'h5a;
      return byte'(mixed);
    end
  endfunction

  task automatic clear_mock_mem;
    for (int i = 0; i < HBM_MEM_BYTES; ++i)
      hbm_mem[i] = 8'h00;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
      for (int i = 0; i < TMEM_MEM_BYTES; ++i)
        tmem_mem[ch][i] = 8'h00;
  endtask

  task automatic init_hbm_pattern(input logic [63:0] base_addr, input int unsigned size_bytes);
    for (int unsigned i = 0; i < size_bytes; ++i)
      hbm_mem[base_addr + i] = pattern8(base_addr + i);
  endtask

  task automatic init_tmem_global_pattern(input logic [63:0] base_addr, input int unsigned size_bytes);
    logic [63:0] cur_addr;
    logic [2:0]  bank_idx;
    logic [63:0] bank_local_addr;
    for (int unsigned i = 0; i < size_bytes; ++i) begin
      cur_addr = base_addr + i;
      bank_idx = exp_tmem_bank_idx(cur_addr);
      bank_local_addr = exp_tmem_bank_local_byte_addr(cur_addr);
      tmem_mem[bank_idx][bank_local_addr] = pattern8(cur_addr);
    end
  endtask

  task automatic exec_cfg_to_mock_mem(input string tag);
    logic [63:0] src_base;
    logic [63:0] dst_base;
    logic [31:0] src_st0, dst_st0, src_st1, dst_st1;
    logic [31:0] bnd0, bnd1, seg_size;
    logic        dir_is_st;
    logic [63:0] src_addr, dst_addr;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (!cfg_seen[ch])
        continue;
      src_base = {cfg_regs_seen[ch][DMA_R_SRC_BASE_HI], cfg_regs_seen[ch][DMA_R_SRC_BASE_LO]};
      dst_base = {cfg_regs_seen[ch][DMA_R_DST_BASE_HI], cfg_regs_seen[ch][DMA_R_DST_BASE_LO]};
      src_st0  = cfg_regs_seen[ch][DMA_R_SRC_ST0];
      dst_st0  = cfg_regs_seen[ch][DMA_R_DST_ST0];
      src_st1  = cfg_regs_seen[ch][DMA_R_SRC_ST1];
      dst_st1  = cfg_regs_seen[ch][DMA_R_DST_ST1];
      bnd0     = cfg_regs_seen[ch][DMA_R_BND0];
      bnd1     = cfg_regs_seen[ch][DMA_R_BND1];
      seg_size = cfg_regs_seen[ch][DMA_R_SEG_SIZE];
      dir_is_st = cfg_regs_seen[ch][DMA_R_DIR][0];
      for (int unsigned i1 = 0; i1 < bnd1; ++i1) begin
        for (int unsigned i0 = 0; i0 < bnd0; ++i0) begin
          src_addr = src_base + i0 * src_st0 + i1 * src_st1;
          dst_addr = dst_base + i0 * dst_st0 + i1 * dst_st1;
          for (int unsigned b = 0; b < seg_size; ++b) begin
            if (dir_is_st) begin
              if ((src_addr + b) >= TMEM_MEM_BYTES)
                $fatal(1, "[%s] TMEM src OOB: ch=%0d addr=0x%0h", tag, ch, src_addr + b);
              if ((dst_addr + b) >= HBM_MEM_BYTES)
                $fatal(1, "[%s] HBM dst OOB: ch=%0d addr=0x%0h", tag, ch, dst_addr + b);
              hbm_mem[dst_addr + b] = tmem_mem[ch][src_addr + b];
            end else begin
              if ((src_addr + b) >= HBM_MEM_BYTES)
                $fatal(1, "[%s] HBM src OOB: ch=%0d addr=0x%0h", tag, ch, src_addr + b);
              if ((dst_addr + b) >= TMEM_MEM_BYTES)
                $fatal(1, "[%s] TMEM dst OOB: ch=%0d addr=0x%0h", tag, ch, dst_addr + b);
              tmem_mem[ch][dst_addr + b] = hbm_mem[src_addr + b];
            end
          end
        end
      end
    end
  endtask

  task automatic expect_tmem_matches_hbm(
    input logic [63:0] hbm_base,
    input logic [63:0] tmem_base,
    input int unsigned size_bytes,
    input string tag
  );
    logic [63:0] cur_tmem_addr;
    logic [63:0] bank_local_addr;
    logic [2:0]  bank_idx;
    byte unsigned got_byte;
    byte unsigned exp_byte;
    for (int unsigned i = 0; i < size_bytes; ++i) begin
      cur_tmem_addr  = tmem_base + i;
      bank_idx       = exp_tmem_bank_idx(cur_tmem_addr);
      bank_local_addr = exp_tmem_bank_local_byte_addr(cur_tmem_addr);
      got_byte       = tmem_mem[bank_idx][bank_local_addr];
      exp_byte       = hbm_mem[hbm_base + i];
      if (got_byte !== exp_byte)
        $fatal(1, "[%s] TMEM mismatch at global=0x%0h bank=%0d local=0x%0h got=0x%02x exp=0x%02x",
          tag, cur_tmem_addr, bank_idx, bank_local_addr, got_byte, exp_byte);
    end
  endtask

  task automatic expect_hbm_matches_tmem(
    input logic [63:0] hbm_base,
    input logic [63:0] tmem_base,
    input int unsigned size_bytes,
    input string tag
  );
    logic [63:0] cur_tmem_addr;
    logic [63:0] bank_local_addr;
    logic [2:0]  bank_idx;
    byte unsigned got_byte;
    byte unsigned exp_byte;
    for (int unsigned i = 0; i < size_bytes; ++i) begin
      cur_tmem_addr  = tmem_base + i;
      bank_idx       = exp_tmem_bank_idx(cur_tmem_addr);
      bank_local_addr = exp_tmem_bank_local_byte_addr(cur_tmem_addr);
      got_byte       = hbm_mem[hbm_base + i];
      exp_byte       = tmem_mem[bank_idx][bank_local_addr];
      if (got_byte !== exp_byte)
        $fatal(1, "[%s] HBM mismatch at addr=0x%0h from TMEM global=0x%0h bank=%0d local=0x%0h got=0x%02x exp=0x%02x",
          tag, hbm_base + i, cur_tmem_addr, bank_idx, bank_local_addr, got_byte, exp_byte);
    end
  endtask

  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_if
    assign cfg_reg_if[ch].ready = 1'b1;
    assign cfg_valid_s[ch]      = cfg_reg_if[ch].valid;
    assign cfg_ready_s[ch]      = cfg_reg_if[ch].ready;
    assign cfg_regs_s[ch]       = cfg_reg_if[ch].regs;
    assign done_if[ch].valid    = done_valid_s[ch];
    assign done_if[ch].entry_id = done_entry_s[ch];
  end

  assign gemm_sync_if.ready = 1'b1;

  always @(posedge clk) begin
    int fires;
    if (reset) begin
      clear_cfg_scoreboard();
      clear_notify_scoreboard();
    end else begin
      fires = 0;
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        if (cfg_valid_s[ch] && cfg_ready_s[ch]) begin
          cfg_seen[ch]      <= 1'b1;
          cfg_regs_seen[ch] <= cfg_regs_s[ch];
          fires++;
          $display("[%0t] CFG_FIRE ch=%0d src=0x%08x_%08x dst=0x%08x_%08x bnd0=%0d seg=%0d dir=%0d",
            $time, ch,
            cfg_regs_s[ch][DMA_R_SRC_BASE_HI], cfg_regs_s[ch][DMA_R_SRC_BASE_LO],
            cfg_regs_s[ch][DMA_R_DST_BASE_HI], cfg_regs_s[ch][DMA_R_DST_BASE_LO],
            cfg_regs_s[ch][DMA_R_BND0], cfg_regs_s[ch][DMA_R_SEG_SIZE], cfg_regs_s[ch][DMA_R_DIR]);
        end
      end
      if (fires != 0)
        cfg_seen_count <= cfg_seen_count + fires;
      if (gemm_sync_if.valid && gemm_sync_if.ready) begin
        notify_seen     <= 1'b1;
        notify_reg_seen <= gemm_sync_if.reg_idx;
        notify_val_seen <= gemm_sync_if.value;
      end
    end
  end

  initial begin
    gemm_dma_ctrl_if.start = 1'b0;
    gemm_dma_ctrl_if.cmd   = '0;

    reset = 1'b1;
    clear_done_inputs();
    clear_cfg_scoreboard();
    clear_notify_scoreboard();
    clear_mock_mem();

    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      clear_notify_scoreboard();
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd64);
      c.rs1_data = 64'h0000_0000_0000_0000;
      c.rs2_data = 64'h0000_0000_0001_0000;
      c.stride   = {16'd512, 16'd64};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "ld_single_word");
      expect_channel_active(0, 1'b1, "ld_single_word");
      for (int ch = 1; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, 1'b0, "ld_single_word");
      expect_cfg_reg(0, DMA_R_SRC_BASE_LO, 32'h0001_0000, "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_BASE_LO, 32'h0000_0000, "ld_single_word");
      // ch_words=1 -> fallback (2D: BND0=1, BND1=ch_words).
      expect_cfg_reg(0, DMA_R_BND0,    32'd1, "ld_single_word");
      expect_cfg_reg(0, DMA_R_BND1,    32'd1, "ld_single_word");
      expect_cfg_reg(0, DMA_R_SRC_ST0, 32'd0, "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_ST0, 32'd0, "ld_single_word");
      // Fallback ST1: LD dir -> SRC=HBM(HBM_BUS_STRIDE=512), DST=TMEM(MEM_BLOCK_SIZE=64).
      expect_cfg_reg(0, DMA_R_SRC_ST1, 32'(`HBM_BUS_STRIDE), "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "ld_single_word");
      expect_cfg_reg(0, DMA_R_SEG_SIZE, 32'd64, "ld_single_word");
      expect_cfg_reg(0, DMA_R_DIR, 32'd0, "ld_single_word");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "ld_single_word");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd512);
      c.rs1_data = 64'h0000_0000_0000_0200;
      c.rs2_data = 64'h0000_0000_0002_0000;
      c.stride   = {16'd512, 16'd64};
      // 2D burst-reorder SVA requires cmd.bound == 1 (kernel always emits 1).
      // The former multi-segment path routed cmd.bound to DMA_R_BND1 and has
      // been removed; BND1 is now the bank dim, derived from ch_words.
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(8, "ld_full_8ch");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expect_channel_active(ch, 1'b1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_BASE_LO, 32'h0002_0000 + ch * 32'd64, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_BASE_LO, 32'h0000_0040, "ld_full_8ch");
        // ch_words = 1 per channel -> fallback (BND0=1, BND1=ch_words=1).
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_ST0, 32'd0, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_ST0, 32'd0, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_ST1, 32'(`HBM_BUS_STRIDE), "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "ld_full_8ch");
      end
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "ld_full_8ch");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      c = '0;
      // seg_size=640 -> num_words=10 -> ch 0,1 get ch_words=2; ch 2..7 get
      // ch_words=1. Both are below NUM_BURST_GROUPS=4, so all channels use
      // fallback: BND0=1, BND1=ch_words, ST1 = HBM_BUS_STRIDE / MEM_BLOCK_SIZE.
      c.instr    = make_instr(OP_DMA_LD, 28'd640);
      c.rs1_data = 64'h0000_0000_0000_0400;
      c.rs2_data = 64'h0000_0000_0003_0000;
      c.stride   = {16'd1024, 16'd128};
      // 2D burst-reorder SVA requires cmd.bound == 1.
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(8, "ld_remainder");
      // All channels: BND0 is always 1 in fallback mode.
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "ld_remainder");
      // BND1 = ch_words: ch 0,1 -> 2, ch 2..7 -> 1.
      expect_cfg_reg(0, DMA_R_BND1, 32'd2, "ld_remainder");
      expect_cfg_reg(1, DMA_R_BND1, 32'd2, "ld_remainder");
      for (int ch = 2; ch < NUM_CHANNELS; ++ch)
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "ld_remainder");
      // Fallback strides: LD -> SRC=HBM_BUS_STRIDE, DST=MEM_BLOCK_SIZE.
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expect_cfg_reg(ch, DMA_R_SRC_ST0, 32'd0, "ld_remainder");
        expect_cfg_reg(ch, DMA_R_DST_ST0, 32'd0, "ld_remainder");
        expect_cfg_reg(ch, DMA_R_SRC_ST1, 32'(`HBM_BUS_STRIDE), "ld_remainder");
        expect_cfg_reg(ch, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "ld_remainder");
      end
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "ld_remainder");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      c = '0;
      c.instr    = make_instr(OP_DMA_ST, 28'd512);
      c.rs1_data = 64'h0000_0000_0004_0000;
      c.rs2_data = 64'h0000_0000_0000_0800;
      c.stride   = {16'd512, 16'd64};
      // 2D burst-reorder SVA requires cmd.bound == 1.
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(8, "st_full_8ch");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expect_cfg_reg(ch, DMA_R_DIR, 32'd1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_BASE_LO, 32'h0000_0100, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_BASE_LO, 32'h0004_0000 + ch * 32'd64, "st_full_8ch");
        // ch_words = 1 per channel -> fallback (BND0=1, BND1=1).
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_ST0, 32'd0, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_ST0, 32'd0, "st_full_8ch");
        // Fallback ST direction: SRC=TMEM(MEM_BLOCK_SIZE), DST=HBM(HBM_BUS_STRIDE).
        expect_cfg_reg(ch, DMA_R_SRC_ST1, 32'(`MEM_BLOCK_SIZE), "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_ST1, 32'(`HBM_BUS_STRIDE), "st_full_8ch");
      end
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "st_full_8ch");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      clear_notify_scoreboard();
      c = '0;
      c.instr    = make_instr(OP_NOTIFY, 28'd0);
      c.rs1_data = 64'h0000_0000_0000_0012;
      c.rs2_data = 64'h0000_0000_dead_beef;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      wait_done_or_timeout(100, "notify");
      expect_cfg_count(0, "notify");
      if (!notify_seen || notify_reg_seen != 32'h12 || notify_val_seen != 32'hdead_beef)
        $fatal(1, "[notify] notify mismatch seen=%0b reg=0x%08x val=0x%08x", notify_seen, notify_reg_seen, notify_val_seen);
    end

    begin
      gemm_unified_cmd_t c;
      logic [63:0] tmem_byte_addr;
      logic [63:0] spec_bank_local_byte;
      logic [31:0] tmem_byte_stride;
      clear_cfg_scoreboard();
      // This case verifies that the TMEM base address is remapped to its
      // bank-local offset (independent of the user s0 stride). In the 2D
      // burst-reorder form, user s0 no longer flows into DMA_R_DST_ST1 -
      // DST_ST1 is always MEM_BLOCK_SIZE (the bank stride in TMEM space) in
      // fallback mode, so this test now cross-checks the BASE_LO remap only.
      tmem_byte_addr       = 64'h0000_0000_0000_0003;
      tmem_byte_stride     = 32'h0000_0043;
      spec_bank_local_byte = exp_tmem_bank_local_byte_addr(tmem_byte_addr);
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd64);
      c.rs1_data = tmem_byte_addr;
      c.rs2_data = 64'h0000_0000_0005_0000;
      c.stride   = {16'd512, tmem_byte_stride[15:0]};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "tmem_misaligned_cfg");
      $display("[TMEM_MAP] tmem_byte_addr=0x%0h bank_idx=%0d spec_bank_local_byte=0x%0h current_cfg_dst=0x%0h current_cfg_dst_st1=0x%0h",
        tmem_byte_addr, exp_tmem_bank_idx(tmem_byte_addr), spec_bank_local_byte,
        {32'd0, cfg_regs_seen[0][DMA_R_DST_BASE_LO]},
        cfg_regs_seen[0][DMA_R_DST_ST1]);
      if ({32'd0, cfg_regs_seen[0][DMA_R_DST_BASE_LO]} !== spec_bank_local_byte)
        $fatal(1, "[tmem_misaligned_cfg] TMEM dst base mismatch: got=0x%0h exp=0x%0h",
          {32'd0, cfg_regs_seen[0][DMA_R_DST_BASE_LO]}, spec_bank_local_byte);
      // 2D form: ch_words=1 -> fallback. DST_ST1 is MEM_BLOCK_SIZE regardless
      // of the user s0 stride. (Legacy routing of s0 into ST1 is removed.)
      expect_cfg_reg(0, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_misaligned_cfg");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "tmem_misaligned_cfg");
    end

    begin
      gemm_unified_cmd_t c;
      logic [63:0] tmem_byte_addr;
      logic [63:0] spec_bank_local_byte;
      logic [31:0] tmem_byte_stride;
      int          exp_ch;
      clear_cfg_scoreboard();
      // ST-direction variant of the misaligned base-address remap check.
      // With the 2D burst-reorder form, user s0 no longer maps to SRC_ST1;
      // SRC_ST1 is MEM_BLOCK_SIZE in fallback mode (bank stride in TMEM).
      tmem_byte_addr         = 64'h0000_0000_0000_0243;
      tmem_byte_stride       = 32'h0000_0243;
      spec_bank_local_byte   = exp_tmem_bank_local_byte_addr(tmem_byte_addr);
      exp_ch = exp_tmem_bank_idx(tmem_byte_addr);
      c = '0;
      c.instr    = make_instr(OP_DMA_ST, 28'd64);
      c.rs1_data = 64'h0000_0000_0006_0000;
      c.rs2_data = tmem_byte_addr;
      c.stride   = {16'd512, tmem_byte_stride[15:0]};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "tmem_store_misaligned_cfg");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, (ch == exp_ch), "tmem_store_misaligned_cfg");
      $display("[TMEM_MAP_ST] tmem_byte_addr=0x%0h bank_idx=%0d spec_bank_local_byte=0x%0h current_cfg_src=0x%0h current_cfg_src_st1=0x%0h",
        tmem_byte_addr, exp_tmem_bank_idx(tmem_byte_addr), spec_bank_local_byte,
        {32'd0, cfg_regs_seen[exp_ch][DMA_R_SRC_BASE_LO]},
        cfg_regs_seen[exp_ch][DMA_R_SRC_ST1]);
      if ({32'd0, cfg_regs_seen[exp_ch][DMA_R_SRC_BASE_LO]} !== spec_bank_local_byte)
        $fatal(1, "[tmem_store_misaligned_cfg] TMEM src base mismatch: got=0x%0h exp=0x%0h",
          {32'd0, cfg_regs_seen[exp_ch][DMA_R_SRC_BASE_LO]}, spec_bank_local_byte);
      // 2D form: ch_words=1 -> fallback. SRC_ST1 (TMEM side in ST dir) is
      // MEM_BLOCK_SIZE regardless of user s0.
      expect_cfg_reg(exp_ch, DMA_R_SRC_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_store_misaligned_cfg");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "tmem_store_misaligned_cfg");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      clear_mock_mem();
      init_hbm_pattern(64'h0000_0000_0007_0000, 512);
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd512);
      c.rs1_data = 64'h0000_0000_0000_0200;
      c.rs2_data = 64'h0000_0000_0007_0000;
      c.stride   = {16'd512, 16'd64};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(8, "mock_ld_aligned");
      exec_cfg_to_mock_mem("mock_ld_aligned");
      expect_tmem_matches_hbm(64'h0000_0000_0007_0000, 64'h0000_0000_0000_0200, 512, "mock_ld_aligned");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "mock_ld_aligned");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      clear_mock_mem();
      init_tmem_global_pattern(64'h0000_0000_0000_0243, 64);
      c = '0;
      c.instr    = make_instr(OP_DMA_ST, 28'd64);
      c.rs1_data = 64'h0000_0000_0008_0043;
      c.rs2_data = 64'h0000_0000_0000_0243;
      c.stride   = {16'd512, 16'h0243};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "mock_st_misaligned");
      exec_cfg_to_mock_mem("mock_st_misaligned");
      expect_hbm_matches_tmem(64'h0000_0000_0008_0043, 64'h0000_0000_0000_0243, 64, "mock_st_misaligned");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "mock_st_misaligned");
    end

    $display("All VX_gemm_tmem_dma_ctrl tests passed");
    $finish;
  end
endmodule

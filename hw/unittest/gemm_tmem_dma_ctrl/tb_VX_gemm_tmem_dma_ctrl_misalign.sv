`timescale 1ns/1ps

// The 2D burst-reorder form in VX_gemm_tmem_dma_ctrl requires
// PLATFORM_MEMORY_NUM_BANKS >= NUM_CHANNELS. Default VX_config.vh value
// is 2, which would trigger the `$fatal` elaboration guard. Pin it to 32
// here (the production value from hw_config.sh) so that
// NUM_BURST_GROUPS == PLATFORM_MEMORY_NUM_BANKS / NUM_CHANNELS == 4.
`ifndef PLATFORM_MEMORY_NUM_BANKS
  `define PLATFORM_MEMORY_NUM_BANKS 32
`endif

`include "VX_define.vh"

module tb_VX_gemm_tmem_dma_ctrl_misalign;
  import VX_gpu_pkg::*;

  localparam int CLK_PERIOD_NS = 10;
  localparam int NUM_CHANNELS  = 8;
  localparam int CFG_NUM       = `DMA_CFG_REG_NUM;

  localparam int DMA_R_DST_BASE_LO = 1;
  localparam int DMA_R_SRC_BASE_LO = 3;
  localparam int DMA_R_SRC_ST0     = 5;
  localparam int DMA_R_DST_ST0     = 6;
  localparam int DMA_R_SRC_ST1     = 7;
  localparam int DMA_R_DST_ST1     = 8;
  localparam int DMA_R_BND0        = 11;
  localparam int DMA_R_BND1        = 12;
  localparam int DMA_R_SEG_SIZE    = 14;
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

  VX_gemm_tmem_dma_ctrl #(
    .INSTANCE_ID("tb_misalign"),
    .NUM_CHANNELS(NUM_CHANNELS)
  ) dut (
    .clk(clk),
    .reset(reset),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .store_done(),
    .gemm_sync_if(gemm_sync_if),
    .cfg_reg_if(cfg_reg_if),
    .done_if(done_if)
  );

  logic [NUM_CHANNELS-1:0]                     cfg_seen;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_seen;
  logic [NUM_CHANNELS-1:0]                     cfg_valid_s;
  logic [NUM_CHANNELS-1:0]                     cfg_ready_s;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_s;
  logic [NUM_CHANNELS-1:0]                     done_valid_s;
  logic [NUM_CHANNELS-1:0][31:0]               done_entry_s;
  logic                                        notify_seen;
  logic [31:0]                                 notify_reg_seen;
  logic [31:0]                                 notify_val_seen;

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

  task automatic clear_done_inputs;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      done_valid_s[ch] = 1'b0;
      done_entry_s[ch] = '0;
    end
  endtask

  task automatic clear_cfg_scoreboard;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      cfg_seen[ch]      = 1'b0;
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
    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
      if (cfg_seen[ch])
        got_count++;
    if (got_count != exp_count)
      $fatal(1, "[%s] cfg count mismatch: got=%0d exp=%0d", tag, got_count, exp_count);
  endtask

  task automatic expect_channel_active(input int ch, input bit exp_active, input string tag);
    if (cfg_seen[ch] !== exp_active)
      $fatal(1, "[%s] ch%0d active mismatch: got=%0b exp=%0b", tag, ch, cfg_seen[ch], exp_active);
  endtask

  task automatic expect_cfg_reg(input int ch, input int reg_idx, input logic [31:0] exp, input string tag);
    logic [31:0] got;
    got = cfg_regs_seen[ch][reg_idx];
    if (got !== exp)
      $fatal(1, "[%s] ch%0d reg[%0d] mismatch: got=0x%08x exp=0x%08x", tag, ch, reg_idx, got, exp);
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
    if (reset) begin
      clear_cfg_scoreboard();
      clear_notify_scoreboard();
    end else begin
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        if (cfg_valid_s[ch] && cfg_ready_s[ch]) begin
          cfg_seen[ch]      <= 1'b1;
          cfg_regs_seen[ch] <= cfg_regs_s[ch];
          $display("[%0t] CFG_FIRE ch=%0d src=0x%08x dst=0x%08x bnd0=%0d seg=%0d dir=%0d",
            $time, ch,
            cfg_regs_s[ch][DMA_R_SRC_BASE_LO],
            cfg_regs_s[ch][DMA_R_DST_BASE_LO],
            cfg_regs_s[ch][DMA_R_BND0],
            cfg_regs_s[ch][DMA_R_SEG_SIZE],
            cfg_regs_s[ch][DMA_R_DIR]);
        end
      end
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
      expect_cfg_reg(0, DMA_R_SRC_BASE_LO, 32'h0001_0000, "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_BASE_LO, 32'h0000_0000, "ld_single_word");
      // ch_words=1 -> fallback (BND0=1, BND1=1, ST0=0, ST1 = HBM_BUS_STRIDE / MEM_BLOCK_SIZE).
      expect_cfg_reg(0, DMA_R_BND0,    32'd1, "ld_single_word");
      expect_cfg_reg(0, DMA_R_BND1,    32'd1, "ld_single_word");
      expect_cfg_reg(0, DMA_R_SRC_ST0, 32'd0, "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_ST0, 32'd0, "ld_single_word");
      expect_cfg_reg(0, DMA_R_SRC_ST1, 32'(`HBM_BUS_STRIDE), "ld_single_word");
      expect_cfg_reg(0, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "ld_single_word");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "ld_single_word");
    end

    begin
      gemm_unified_cmd_t c;
      clear_cfg_scoreboard();
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd512);
      c.rs1_data = 64'h0000_0000_0000_0200;
      c.rs2_data = 64'h0000_0000_0002_0200;
      c.stride   = {16'd512, 16'd64};
      // 2D burst-reorder SVA requires cmd.bound == 1.
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(8, "ld_full_8ch");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expect_channel_active(ch, 1'b1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_BASE_LO, 32'h0002_0200 + ch * 32'd64, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_BASE_LO, 32'h0000_0040, "ld_full_8ch");
        // ch_words=1 per channel -> fallback.
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "ld_full_8ch");
      end
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "ld_full_8ch");
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
        expect_channel_active(ch, 1'b1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_DIR, 32'd1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_BASE_LO, 32'h0000_0100, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_BASE_LO, 32'h0004_0000 + ch * 32'd64, "st_full_8ch");
        // ch_words=1 per channel -> fallback. ST dir: SRC=TMEM, DST=HBM.
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "st_full_8ch");
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "st_full_8ch");
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
        $fatal(1, "[notify] mismatch seen=%0b reg=0x%08x val=0x%08x", notify_seen, notify_reg_seen, notify_val_seen);
    end

    begin
      gemm_unified_cmd_t c;
      logic [63:0] tmem_byte_addr;
      logic [63:0] hbm_byte_addr;
      logic [63:0] spec_bank_local_byte;
      logic [31:0] tmem_byte_stride;
      int          exp_ch;
      clear_cfg_scoreboard();
      // Verifies that a misaligned TMEM base address is still remapped to
      // its bank-local offset and that only the single bank indexed by
      // byte_addr[8:6] is active. In the 2D burst-reorder form, user s0 is
      // no longer routed to DMA_R_DST_ST1 -- DST_ST1 is MEM_BLOCK_SIZE.
      tmem_byte_addr         = 64'h0000_0000_0000_0043;
      hbm_byte_addr          = 64'h0000_0000_0005_0043;
      tmem_byte_stride       = 32'h0000_0043;
      spec_bank_local_byte   = exp_tmem_bank_local_byte_addr(tmem_byte_addr);
      exp_ch = exp_tmem_bank_idx(tmem_byte_addr);
      c = '0;
      c.instr    = make_instr(OP_DMA_LD, 28'd64);
      c.rs1_data = tmem_byte_addr;
      c.rs2_data = hbm_byte_addr;
      c.stride   = {16'h0243, tmem_byte_stride[15:0]};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "tmem_misaligned_ld_cfg");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, (ch == exp_ch), "tmem_misaligned_ld_cfg");
      expect_cfg_reg(exp_ch, DMA_R_SRC_BASE_LO, hbm_byte_addr[31:0], "tmem_misaligned_ld_cfg");
      expect_cfg_reg(exp_ch, DMA_R_DST_BASE_LO, spec_bank_local_byte[31:0], "tmem_misaligned_ld_cfg");
      // 2D form: fallback DST_ST1 is MEM_BLOCK_SIZE (TMEM bank stride),
      // independent of user s0.
      expect_cfg_reg(exp_ch, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_misaligned_ld_cfg");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "tmem_misaligned_ld_cfg");
    end

    begin
      gemm_unified_cmd_t c;
      logic [63:0] tmem_byte_addr;
      logic [63:0] hbm_byte_addr;
      logic [63:0] spec_bank_local_byte;
      logic [31:0] tmem_byte_stride;
      int          exp_ch;
      clear_cfg_scoreboard();
      // ST-direction counterpart. In the 2D burst-reorder form, user s0 is
      // no longer routed to DMA_R_SRC_ST1 -- SRC_ST1 is MEM_BLOCK_SIZE
      // (bank stride in TMEM space).
      tmem_byte_addr         = 64'h0000_0000_0000_0243;
      hbm_byte_addr          = 64'h0000_0000_0006_0243;
      tmem_byte_stride       = 32'h0000_0243;
      spec_bank_local_byte   = exp_tmem_bank_local_byte_addr(tmem_byte_addr);
      exp_ch = exp_tmem_bank_idx(tmem_byte_addr);
      c = '0;
      c.instr    = make_instr(OP_DMA_ST, 28'd64);
      c.rs1_data = hbm_byte_addr;
      c.rs2_data = tmem_byte_addr;
      c.stride   = {16'd512, tmem_byte_stride[15:0]};
      c.bound    = 16'd1;
      gemm_dma_ctrl_if.cmd = c;
      pulse_start();
      repeat (3) @(posedge clk);
      expect_cfg_count(1, "tmem_misaligned_st_cfg");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, (ch == exp_ch), "tmem_misaligned_st_cfg");
      expect_cfg_reg(exp_ch, DMA_R_SRC_BASE_LO, spec_bank_local_byte[31:0], "tmem_misaligned_st_cfg");
      expect_cfg_reg(exp_ch, DMA_R_DST_BASE_LO, hbm_byte_addr[31:0], "tmem_misaligned_st_cfg");
      // 2D form: fallback SRC_ST1 is MEM_BLOCK_SIZE, independent of user s0.
      expect_cfg_reg(exp_ch, DMA_R_SRC_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_misaligned_st_cfg");
      drive_done_for_active_channels();
      wait_done_or_timeout(100, "tmem_misaligned_st_cfg");
    end

    $display("All VX_gemm_tmem_dma_ctrl misalign tests passed");
    $finish;
  end
endmodule

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

module tb_VX_gemm_tmem_dma_ctrl_misalign #(
  parameter int TB_PENDING_DEPTH = 4
);
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
  localparam int DMA_R_SRC_ST2     = 9;
  localparam int DMA_R_DST_ST2     = 10;
  localparam int DMA_R_BND0        = 11;
  localparam int DMA_R_BND1        = 12;
  localparam int DMA_R_BND2        = 13;
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
  logic store_done;

  VX_gemm_tmem_dma_ctrl #(
    .INSTANCE_ID("tb_misalign"),
    .NUM_CHANNELS(NUM_CHANNELS),
    .PENDING_DEPTH(TB_PENDING_DEPTH)
  ) dut (
    .clk(clk),
    .reset(reset),
    .compute_active_i(1'b0),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .store_done(store_done),
    .gemm_sync_if(gemm_sync_if),
    .cfg_reg_if(cfg_reg_if),
    .done_if(done_if)
  );

  logic [NUM_CHANNELS-1:0]                     cfg_seen;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_seen;
  logic [NUM_CHANNELS-1:0]                     cfg_valid_s;
  logic [NUM_CHANNELS-1:0]                     cfg_ready_s;
  logic [NUM_CHANNELS-1:0]                     cfg_ready_drive;
  logic [NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0] cfg_regs_s;
  logic [NUM_CHANNELS-1:0]                     done_valid_s;
  logic [NUM_CHANNELS-1:0][31:0]               done_entry_s;
  logic                                        notify_seen;
  logic [31:0]                                 notify_reg_seen;
  logic [31:0]                                 notify_val_seen;
  integer dma_done_pulse_count;
  integer store_done_pulse_count;
  logic dma_done_prev;
  logic [GEMM_DMA_TAG_WIDTH-1:0] next_cmd_tag;
  integer descriptor_issue_count;
  logic [127:0][NUM_CHANNELS-1:0] descriptor_active;
  logic [127:0][NUM_CHANNELS-1:0][CFG_NUM-1:0][31:0]
    descriptor_regs;

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
    begin
      @(negedge clk);
      gemm_dma_ctrl_if.cmd.dma_priority =
        (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_LD);
      gemm_dma_ctrl_if.cmd.dma_max_chunk_log2p1 =
        (gemm_dma_ctrl_if.cmd.instr[3:0] == OP_DMA_ST) ? 4'd4 : 4'd0;
      gemm_dma_ctrl_if.cmd_tag = next_cmd_tag;
      gemm_dma_ctrl_if.start = 1'b1;
      gemm_dma_ctrl_if.cmd_valid = 1'b1;
      do @(posedge clk); while (!gemm_dma_ctrl_if.cmd_ready);
      next_cmd_tag++;
      @(negedge clk);
      gemm_dma_ctrl_if.start = 1'b0;
      gemm_dma_ctrl_if.cmd_valid = 1'b0;
    end
  endtask

  task automatic complete_active_channels_exact(
    input bit expect_store,
    input string tag
  );
    int final_ch;
    int active_count;
    int done_before;
    int store_before;
    int wait_cycles;
    final_ch = -1;
    active_count = 0;
    done_before = dma_done_pulse_count;
    store_before = store_done_pulse_count;
    for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
      if (cfg_seen[ch]) begin
        final_ch = ch;
        active_count++;
      end
    end
    if (final_ch < 0)
      $fatal(1, "[%s] no active channel to complete", tag);

    // Make every channel except the final one sticky first.
    @(negedge clk);
    for (int ch = 0; ch < NUM_CHANNELS; ++ch)
      done_valid_s[ch] = cfg_seen[ch] && (ch != final_ch);
    #1;
    if (active_count > 1 && gemm_dma_ctrl_if.done)
      $fatal(1, "[%s] DMA completed before final channel", tag);
    @(posedge clk);

    // The final channel completion must be visible combinationally in this
    // same cycle through done_sticky | done_or_inactive.
    @(negedge clk);
    clear_done_inputs();
    done_valid_s[final_ch] = 1'b1;
    #1;
    if (!dut.done_all_valid || !gemm_dma_ctrl_if.done)
      $fatal(1, "[%s] current-cycle final channel did not assert DMA done", tag);
    if (store_done !== expect_store)
      $fatal(1, "[%s] store_done mismatch got=%0b expected=%0b",
             tag, store_done, expect_store);
    @(posedge clk);
    #1;
    clear_done_inputs();
    if (gemm_dma_ctrl_if.done || store_done)
      $fatal(1, "[%s] completion pulse repeated after one cycle", tag);

    wait_cycles = 0;
    while (!gemm_dma_ctrl_if.idle && wait_cycles < 20) begin
      @(posedge clk);
      wait_cycles++;
    end
    if (!gemm_dma_ctrl_if.idle)
      $fatal(1, "[%s] controller did not return idle", tag);
    if (dma_done_pulse_count != done_before + 1)
      $fatal(1, "[%s] DMA done pulse count mismatch", tag);
    if (store_done_pulse_count != store_before + (expect_store ? 1 : 0))
      $fatal(1, "[%s] store_done pulse count mismatch", tag);
    $display("TMEM_DMA_CURRENT_CYCLE_PASS tag=%s active_channels=%0d store=%0d one_pulse=1",
             tag, active_count, expect_store);
  endtask

  task automatic expect_cfg_count(input int exp_count, input string tag);
    int got_count;
    #1;
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

  function automatic gemm_unified_cmd_t make_dma_cmd(
    input logic [3:0] op,
    input logic [27:0] size_bytes,
    input logic [63:0] dst_addr,
    input logic [63:0] src_addr,
    input logic [3:0] max_chunk_log2p1
  );
    gemm_unified_cmd_t c;
    begin
      c = '0;
      c.instr = make_instr(op, size_bytes);
      c.rs1_data = dst_addr;
      c.rs2_data = src_addr;
      c.bound = 16'd1;
      c.dma_priority = (op == OP_DMA_LD);
      c.dma_max_chunk_log2p1 = (op == OP_DMA_ST)
        ? max_chunk_log2p1 : 4'd0;
      return c;
    end
  endfunction

  task automatic send_tagged_cmd(
    input gemm_unified_cmd_t c,
    input logic [GEMM_DMA_TAG_WIDTH-1:0] tag
  );
    begin
      @(negedge clk);
      gemm_dma_ctrl_if.cmd = c;
      gemm_dma_ctrl_if.cmd_tag = tag;
      gemm_dma_ctrl_if.start = 1'b1;
      gemm_dma_ctrl_if.cmd_valid = 1'b1;
      do @(posedge clk); while (!gemm_dma_ctrl_if.cmd_ready);
      @(negedge clk);
      gemm_dma_ctrl_if.start = 1'b0;
      gemm_dma_ctrl_if.cmd_valid = 1'b0;
    end
  endtask

  task automatic wait_descriptor(
    input int target_count,
    input string tag
  );
    int cycles;
    begin
      cycles = 0;
      while ((descriptor_issue_count < target_count) && (cycles < 100)) begin
        @(posedge clk);
        #1;
        cycles++;
      end
      if (descriptor_issue_count < target_count)
        $fatal(1, "[%s] descriptor issue timeout target=%0d got=%0d",
               tag, target_count, descriptor_issue_count);
    end
  endtask

  task automatic complete_descriptor(
    input int issue_idx,
    input bit expect_logical_done,
    input bit expect_store_done,
    input logic [GEMM_DMA_TAG_WIDTH-1:0] expected_tag,
    input string tag
  );
    int cycles;
    begin
      cycles = 0;
      while (!done_if[0].ready && cycles < 20) begin
        @(posedge clk);
        cycles++;
      end
      if (!done_if[0].ready)
        $fatal(1, "[%s] descriptor never entered WAIT_DONE", tag);
      @(negedge clk);
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        done_valid_s[ch] = descriptor_active[issue_idx][ch];
      #1;
      if (gemm_dma_ctrl_if.done !== expect_logical_done)
        $fatal(1, "[%s] logical done mismatch got=%0b expected=%0b",
               tag, gemm_dma_ctrl_if.done, expect_logical_done);
      if (store_done !== expect_store_done)
        $fatal(1, "[%s] store done mismatch got=%0b expected=%0b",
               tag, store_done, expect_store_done);
      if (expect_logical_done && gemm_dma_ctrl_if.done_tag !== expected_tag)
        $fatal(1, "[%s] done tag mismatch got=%0d expected=%0d",
               tag, gemm_dma_ctrl_if.done_tag, expected_tag);
      @(posedge clk);
      @(negedge clk);
      clear_done_inputs();
    end
  endtask

  task automatic check_chunk_address_set(
    input int first_issue,
    input int chunk_count,
    input logic [63:0] orig_src_base,
    input logic [63:0] orig_dst_base,
    input string tag
  );
    integer src_hits [longint unsigned];
    integer dst_hits [longint unsigned];
    longint unsigned key;
    longint unsigned addr;
    int total;
    begin
      src_hits.delete();
      dst_hits.delete();
      total = 0;
      for (int n = 0; n < chunk_count; ++n) begin
        int issue_idx;
        issue_idx = first_issue + n;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
          if (!descriptor_active[issue_idx][ch])
            $fatal(1, "[%s] chunk %0d channel %0d unexpectedly inactive",
                   tag, n, ch);
          for (int i2 = 0;
               i2 < descriptor_regs[issue_idx][ch][DMA_R_BND2]; ++i2) begin
            for (int i1 = 0;
                 i1 < descriptor_regs[issue_idx][ch][DMA_R_BND1]; ++i1) begin
              for (int i0 = 0;
                   i0 < descriptor_regs[issue_idx][ch][DMA_R_BND0]; ++i0) begin
                addr = descriptor_regs[issue_idx][ch][DMA_R_SRC_BASE_LO]
                     + i0 * descriptor_regs[issue_idx][ch][DMA_R_SRC_ST0]
                     + i1 * descriptor_regs[issue_idx][ch][DMA_R_SRC_ST1]
                     + i2 * descriptor_regs[issue_idx][ch][DMA_R_SRC_ST2];
                key = (longint'(ch) << 56) | addr;
                src_hits[key]++;
                addr = descriptor_regs[issue_idx][ch][DMA_R_DST_BASE_LO]
                     + i0 * descriptor_regs[issue_idx][ch][DMA_R_DST_ST0]
                     + i1 * descriptor_regs[issue_idx][ch][DMA_R_DST_ST1]
                     + i2 * descriptor_regs[issue_idx][ch][DMA_R_DST_ST2];
                key = (longint'(ch) << 56) | addr;
                dst_hits[key]++;
                total++;
              end
            end
          end
        end
      end
      if (total != 576)
        $fatal(1, "[%s] chunk transfer count got=%0d expected=576", tag, total);
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        for (int i2 = 0; i2 < 4; ++i2) begin
          for (int i1 = 0; i1 < 9; ++i1) begin
            for (int i0 = 0; i0 < 2; ++i0) begin
              addr = orig_src_base + i0 * 256 + i1 * 512 + i2 * 64;
              key = (longint'(ch) << 56) | addr;
              if (src_hits[key] != 1)
                $fatal(1, "[%s] source address multiplicity ch=%0d addr=0x%0h hits=%0d",
                       tag, ch, addr, src_hits[key]);
              addr = orig_dst_base + ch * 64
                   + i0 * 2048 + i1 * 4096 + i2 * 512;
              key = (longint'(ch) << 56) | addr;
              if (dst_hits[key] != 1)
                $fatal(1, "[%s] destination address multiplicity ch=%0d addr=0x%0h hits=%0d",
                       tag, ch, addr, dst_hits[key]);
            end
          end
        end
      end
    end
  endtask

  task automatic wait_idle(input string tag);
    int cycles;
    begin
      cycles = 0;
      while (!gemm_dma_ctrl_if.idle && cycles < 100) begin
        @(posedge clk);
        cycles++;
      end
      if (!gemm_dma_ctrl_if.idle)
        $fatal(1, "[%s] idle timeout", tag);
    end
  endtask

  task automatic run_chunk_case(
    input int max_chunk_beats,
    input logic [3:0] chunk_encoding,
    input logic [GEMM_DMA_TAG_WIDTH-1:0] tag
  );
    gemm_unified_cmd_t c;
    int first_issue;
    int expected_chunks;
    int cursor;
    int remaining;
    int bank_budget;
    int exp_bnd0;
    int exp_bnd1;
    int chunk_bpb;
    string case_tag;
    begin
      case_tag = $sformatf("chunk_%0d", max_chunk_beats);
      case (max_chunk_beats)
        4: expected_chunks = 18;
        8: expected_chunks = 9;
        16: expected_chunks = 5;
        32: expected_chunks = 3;
        default: $fatal(1, "unsupported directed chunk size %0d",
                        max_chunk_beats);
      endcase
      first_issue = descriptor_issue_count;
      c = make_dma_cmd(OP_DMA_ST, 28'd36864,
                       64'h0000_0000_0010_1000,
                       64'h0000_0000_0000_0000,
                       chunk_encoding);
      send_tagged_cmd(c, tag);
      cursor = 0;
      remaining = 18;
      bank_budget = max_chunk_beats / 4;
      for (int n = 0; n < expected_chunks; ++n) begin
        wait_descriptor(first_issue + n + 1, case_tag);
        if (bank_budget >= 2) begin
          exp_bnd0 = 2;
          exp_bnd1 = ((remaining / 2) <= (bank_budget / 2))
                   ? (remaining / 2) : (bank_budget / 2);
        end else begin
          exp_bnd0 = bank_budget;
          exp_bnd1 = 1;
        end
        chunk_bpb = exp_bnd0 * exp_bnd1;
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
          if (descriptor_regs[first_issue+n][ch][DMA_R_BND0] != exp_bnd0
           || descriptor_regs[first_issue+n][ch][DMA_R_BND1] != exp_bnd1
           || descriptor_regs[first_issue+n][ch][DMA_R_BND2] != 4)
            $fatal(1, "[%s] chunk %0d bounds mismatch ch=%0d got=%0d/%0d/%0d exp=%0d/%0d/4",
                   case_tag, n, ch,
                   descriptor_regs[first_issue+n][ch][DMA_R_BND0],
                   descriptor_regs[first_issue+n][ch][DMA_R_BND1],
                   descriptor_regs[first_issue+n][ch][DMA_R_BND2],
                   exp_bnd0, exp_bnd1);
          if (descriptor_regs[first_issue+n][ch][DMA_R_SRC_BASE_LO]
                != cursor * 256
           || descriptor_regs[first_issue+n][ch][DMA_R_DST_BASE_LO]
                != 32'h0010_1000 + ch * 64 + cursor * 2048)
            $fatal(1, "[%s] chunk %0d base cursor mismatch ch=%0d cursor=%0d",
                   case_tag, n, ch, cursor);
        end
        complete_descriptor(first_issue+n, n == expected_chunks-1,
                            n == expected_chunks-1, tag, case_tag);
        cursor += chunk_bpb;
        remaining -= chunk_bpb;
      end
      if (remaining != 0 || cursor != 18)
        $fatal(1, "[%s] cursor completion mismatch cursor=%0d rem=%0d",
               case_tag, cursor, remaining);
      check_chunk_address_set(first_issue, expected_chunks,
                              64'h0, 64'h0010_1000, case_tag);
      wait_idle(case_tag);
      $display("TMEM_DMA_CHUNK_PASS max=%0d chunks=%0d address_set=exact logical_done=1",
               max_chunk_beats, expected_chunks);
    end
  endtask

  task automatic run_nonchunkable_cases;
    gemm_unified_cmd_t c;
    int issue_idx;
    begin
      issue_idx = descriptor_issue_count;
      c = make_dma_cmd(OP_DMA_ST, 28'd256,
                       64'h0000_0000_0020_0000,
                       64'h0000_0000_0000_0000, 4'd3);
      send_tagged_cmd(c, 3'd5);
      wait_descriptor(issue_idx + 1, "fallback_256");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        if (descriptor_active[issue_idx][ch] !== (ch < 4))
          $fatal(1, "[fallback_256] active mask mismatch ch=%0d", ch);
        if (ch < 4
         && (descriptor_regs[issue_idx][ch][DMA_R_BND0] != 1
          || descriptor_regs[issue_idx][ch][DMA_R_BND1] != 1
          || descriptor_regs[issue_idx][ch][DMA_R_BND2] != 1))
          $fatal(1, "[fallback_256] descriptor mismatch ch=%0d", ch);
      end
      complete_descriptor(issue_idx, 1'b1, 1'b1, 3'd5,
                          "fallback_256");
      wait_idle("fallback_256");

      issue_idx = descriptor_issue_count;
      c = make_dma_cmd(OP_DMA_ST, 28'd2112,
                       64'h0000_0000_0030_1000,
                       64'h0000_0000_0000_0000, 4'd3);
      send_tagged_cmd(c, 3'd6);
      wait_descriptor(issue_idx + 1, "mixed_33_beats");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        if (!descriptor_active[issue_idx][ch])
          $fatal(1, "[mixed_33_beats] inactive channel %0d", ch);
        if (ch == 0) begin
          if (descriptor_regs[issue_idx][ch][DMA_R_BND0] != 1
           || descriptor_regs[issue_idx][ch][DMA_R_BND1] != 5
           || descriptor_regs[issue_idx][ch][DMA_R_BND2] != 1)
            $fatal(1, "[mixed_33_beats] fallback channel changed");
        end else begin
          if (descriptor_regs[issue_idx][ch][DMA_R_BND0] != 1
           || descriptor_regs[issue_idx][ch][DMA_R_BND1] != 1
           || descriptor_regs[issue_idx][ch][DMA_R_BND2] != 4)
            $fatal(1, "[mixed_33_beats] burst channel %0d changed", ch);
        end
      end
      complete_descriptor(issue_idx, 1'b1, 1'b1, 3'd6,
                          "mixed_33_beats");
      wait_idle("mixed_33_beats");
      $display("TMEM_DMA_NONCHUNK_PASS fallback_256=exact mixed=exact issues=1");
    end
  endtask

  task automatic run_priority_pause_case;
    gemm_unified_cmd_t c;
    gemm_unified_cmd_t held_cmd;
    int first_issue;
    begin
      first_issue = descriptor_issue_count;
      c = make_dma_cmd(OP_DMA_ST, 28'd8192,
                       64'h0000_0000_0040_1000,
                       64'h0000_0000_0000_0000, 4'd4);
      send_tagged_cmd(c, 3'd0);
      wait_descriptor(first_issue + 1, "priority_store_first");

      for (int j = 1; j <= 4; ++j) begin
        c = make_dma_cmd(OP_DMA_LD, 28'd64,
                         64'(j * 32'h200),
                         64'h0000_0000_0050_0000 + j * 32'h1000, 4'd0);
        send_tagged_cmd(c, GEMM_DMA_TAG_WIDTH'(j));
      end
      #1;
      if (dut.pending_count_q != TB_PENDING_DEPTH || gemm_dma_ctrl_if.cmd_ready)
        $fatal(1, "[priority_pause] pending queue did not reach full");

      c = make_dma_cmd(OP_DMA_LD, 28'd64,
                       64'h0000_0000_0000_0a00,
                       64'h0000_0000_0050_5000, 4'd0);
      @(negedge clk);
      gemm_dma_ctrl_if.cmd = c;
      gemm_dma_ctrl_if.cmd_tag = 3'd5;
      gemm_dma_ctrl_if.start = 1'b1;
      gemm_dma_ctrl_if.cmd_valid = 1'b1;
      held_cmd = gemm_dma_ctrl_if.cmd;
      repeat (3) begin
        @(posedge clk);
        #1;
        if (gemm_dma_ctrl_if.cmd_ready
         || gemm_dma_ctrl_if.cmd !== held_cmd
         || gemm_dma_ctrl_if.cmd_tag !== 3'd5)
          $fatal(1, "[priority_pause] queue-full command/tag not retained");
      end

      complete_descriptor(first_issue, 1'b0, 1'b0, 3'd0,
                          "priority_store_pause");
      do @(posedge clk); while (!gemm_dma_ctrl_if.cmd_ready);
      @(negedge clk);
      gemm_dma_ctrl_if.start = 1'b0;
      gemm_dma_ctrl_if.cmd_valid = 1'b0;

      for (int j = 1; j <= 5; ++j) begin
        wait_descriptor(first_issue + j + 1, "priority_load_fifo");
        if (descriptor_regs[first_issue+j][0][DMA_R_SRC_BASE_LO]
              != 32'h0050_0000 + j * 32'h1000)
          $fatal(1, "[priority_load_fifo] order mismatch j=%0d src=0x%0h",
                 j, descriptor_regs[first_issue+j][0][DMA_R_SRC_BASE_LO]);
        complete_descriptor(first_issue+j, 1'b1, 1'b0,
                            GEMM_DMA_TAG_WIDTH'(j), "priority_load_fifo");
      end

      wait_descriptor(first_issue + 7, "priority_store_resume");
      if (descriptor_regs[first_issue+6][0][DMA_R_SRC_BASE_LO] != 32'd512
       || descriptor_regs[first_issue+6][0][DMA_R_DST_BASE_LO]
            != 32'h0040_2000)
        $fatal(1, "[priority_store_resume] paused cursor not preserved");
      complete_descriptor(first_issue+6, 1'b1, 1'b1, 3'd0,
                          "priority_store_resume");
      wait_idle("priority_store_resume");
      $display("TMEM_DMA_PRIORITY_PASS store_paused=1 high_fifo=5 queue_full=1 stable=1 resumed=1");
    end
  endtask

  task automatic run_cfg_backpressure_case;
    gemm_unified_cmd_t c;
    int issue_idx;
    logic [CFG_NUM-1:0][31:0] held_regs;
    begin
      issue_idx = descriptor_issue_count;
      cfg_ready_drive = '0;
      c = make_dma_cmd(OP_DMA_LD, 28'd512,
                       64'h0000_0000_0000_0000,
                       64'h0000_0000_0060_0000, 4'd0);
      send_tagged_cmd(c, 3'd7);
      while (!cfg_reg_if[0].valid) @(posedge clk);
      held_regs = cfg_reg_if[0].regs;
      repeat (3) begin
        @(posedge clk);
        #1;
        if (!cfg_reg_if[0].valid || cfg_reg_if[0].regs !== held_regs
         || gemm_dma_ctrl_if.idle)
          $fatal(1, "[cfg_backpressure] descriptor not stable or idle early");
      end
      @(negedge clk);
      cfg_ready_drive = '1;
      wait_descriptor(issue_idx + 1, "cfg_backpressure");
      complete_descriptor(issue_idx, 1'b1, 1'b0, 3'd7,
                          "cfg_backpressure");
      wait_idle("cfg_backpressure");
      $display("TMEM_DMA_BACKPRESSURE_PASS cfg_stable_cycles=3 idle_drain=1");
    end
  endtask

  task automatic run_pending_depth_smoke;
    gemm_unified_cmd_t c;
    int first_issue;
    begin
      first_issue = descriptor_issue_count;
      c = make_dma_cmd(OP_DMA_LD, 28'd64,
                       64'h0000_0000_0000_0000,
                       64'h0000_0000_0070_0000, 4'd0);
      send_tagged_cmd(c, 3'd0);
      wait_descriptor(first_issue + 1, "depth_active");
      for (int j = 1; j <= TB_PENDING_DEPTH; ++j) begin
        c = make_dma_cmd(OP_DMA_LD, 28'd64,
                         64'(j * 32'h200),
                         64'h0000_0000_0070_0000 + j * 32'h1000, 4'd0);
        send_tagged_cmd(c, GEMM_DMA_TAG_WIDTH'(j));
      end
      #1;
      if (dut.pending_count_q != TB_PENDING_DEPTH || gemm_dma_ctrl_if.cmd_ready)
        $fatal(1, "[depth_%0d] queue full contract mismatch", TB_PENDING_DEPTH);
      complete_descriptor(first_issue, 1'b1, 1'b0, 3'd0, "depth_active");
      for (int j = 1; j <= TB_PENDING_DEPTH; ++j) begin
        wait_descriptor(first_issue + j + 1, "depth_fifo");
        complete_descriptor(first_issue+j, 1'b1, 1'b0,
                            GEMM_DMA_TAG_WIDTH'(j), "depth_fifo");
      end
      wait_idle("depth_fifo");
      $display("TMEM_DMA_DEPTH_PASS depth=%0d full=1 fifo=1 drain=1",
               TB_PENDING_DEPTH);
    end
  endtask

  task automatic run_multiple_low_store_order_case;
    gemm_unified_cmd_t c;
    int first_issue;
    int done_before;
    int store_done_before;
    begin
      first_issue = descriptor_issue_count;
      done_before = dma_done_pulse_count;
      store_done_before = store_done_pulse_count;

      // Hold the executor with one active load while three low-priority stores
      // accumulate in the pending queue.
      c = make_dma_cmd(OP_DMA_LD, 28'd64,
                       64'h0000_0000_0000_0000,
                       64'h0000_0000_0080_0000, 4'd0);
      send_tagged_cmd(c, 3'd0);
      wait_descriptor(first_issue + 1, "multi_low_active_load");
      for (int j = 1; j <= 3; ++j) begin
        c = make_dma_cmd(OP_DMA_ST, 28'd256,
                         64'h0000_0000_0080_0000 + j * 32'h1000,
                         64'(j * 32'h200), 4'd4);
        send_tagged_cmd(c, GEMM_DMA_TAG_WIDTH'(j));
      end
      if (dut.pending_count_q != 3)
        $fatal(1, "[multi_low] expected three queued stores, got %0d",
               dut.pending_count_q);

      complete_descriptor(first_issue, 1'b1, 1'b0, 3'd0,
                          "multi_low_active_load");
      for (int j = 1; j <= 3; ++j) begin
        wait_descriptor(first_issue + j + 1, "multi_low_store_fifo");
        if (descriptor_regs[first_issue+j][0][DMA_R_DST_BASE_LO]
              != 32'h0080_0000 + j * 32'h1000)
          $fatal(1, "[multi_low] issue order mismatch j=%0d dst=0x%0h",
                 j, descriptor_regs[first_issue+j][0][DMA_R_DST_BASE_LO]);
        complete_descriptor(first_issue+j, 1'b1, 1'b1,
                            GEMM_DMA_TAG_WIDTH'(j),
                            "multi_low_store_fifo");
      end
      wait_idle("multi_low_store_fifo");
      if (dma_done_pulse_count != done_before + 4
       || store_done_pulse_count != store_done_before + 3)
        $fatal(1, "[multi_low] completion counts reordered/lost done=%0d store=%0d",
               dma_done_pulse_count - done_before,
               store_done_pulse_count - store_done_before);
      $display("TMEM_DMA_MULTI_LOW_STORE_ORDER_PASS queued=3 issue_order=1 completion_tags=1,2,3 logical_once=1");
    end
  endtask

  task automatic run_nonchunkable_pending_load_case;
    gemm_unified_cmd_t c;
    int first_issue;
    int done_before;
    int store_done_before;
    int final_ch;
    begin
      first_issue = descriptor_issue_count;
      done_before = dma_done_pulse_count;
      store_done_before = store_done_pulse_count;

      // A 256-byte store activates four channels and is non-chunkable.
      c = make_dma_cmd(OP_DMA_ST, 28'd256,
                       64'h0000_0000_0090_0000,
                       64'h0000_0000_0000_0000, 4'd3);
      send_tagged_cmd(c, 3'd4);
      wait_descriptor(first_issue + 1, "nonchunk_pending_store");

      c = make_dma_cmd(OP_DMA_LD, 28'd64,
                       64'h0000_0000_0000_0200,
                       64'h0000_0000_0091_0000, 4'd0);
      send_tagged_cmd(c, 3'd5);
      c = make_dma_cmd(OP_DMA_ST, 28'd256,
                       64'h0000_0000_0092_0000,
                       64'h0000_0000_0000_0400, 4'd4);
      send_tagged_cmd(c, 3'd6);
      if (dut.pending_count_q != 2)
        $fatal(1, "[nonchunk_pending] pending load/store count mismatch");

      // Retire all but the final active channel, then hold the final response.
      // The high load must remain queued and no descriptor may be reissued.
      final_ch = 3;
      while (!done_if[0].ready) @(posedge clk);
      @(negedge clk);
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        done_valid_s[ch] = descriptor_active[first_issue][ch]
                         && (ch != final_ch);
      @(posedge clk);
      @(negedge clk);
      clear_done_inputs();
      repeat (4) begin
        @(posedge clk);
        #1;
        if (descriptor_issue_count != first_issue + 1
         || dut.pending_count_q != 2
         || gemm_dma_ctrl_if.done || store_done || gemm_dma_ctrl_if.idle)
          $fatal(1, "[nonchunk_pending] arbitration escaped before final response drain");
      end

      @(negedge clk);
      done_valid_s[final_ch] = 1'b1;
      #1;
      if (!gemm_dma_ctrl_if.done || !store_done
       || gemm_dma_ctrl_if.done_tag != 3'd4)
        $fatal(1, "[nonchunk_pending] store tagged completion mismatch");
      @(posedge clk);
      @(negedge clk);
      clear_done_inputs();

      // The queued high-priority load must beat the later low store.
      wait_descriptor(first_issue + 2, "nonchunk_pending_load");
      if (descriptor_regs[first_issue+1][0][DMA_R_SRC_BASE_LO]
            != 32'h0091_0000)
        $fatal(1, "[nonchunk_pending] high load was not selected first");
      complete_descriptor(first_issue+1, 1'b1, 1'b0, 3'd5,
                          "nonchunk_pending_load");
      wait_descriptor(first_issue + 3, "nonchunk_pending_later_store");
      if (descriptor_regs[first_issue+2][0][DMA_R_DST_BASE_LO]
            != 32'h0092_0000)
        $fatal(1, "[nonchunk_pending] later low store descriptor mismatch");
      complete_descriptor(first_issue+2, 1'b1, 1'b1, 3'd6,
                          "nonchunk_pending_later_store");
      wait_idle("nonchunk_pending_later_store");

      if (dma_done_pulse_count != done_before + 3
       || store_done_pulse_count != store_done_before + 2)
        $fatal(1, "[nonchunk_pending] logical completion multiplicity mismatch");
      $display("TMEM_DMA_NONCHUNK_PENDING_LOAD_PASS fallback=256 response_hold=4 load_first=1 later_low_store=1 tags=4,5,6 logical_once=1");
    end
  endtask

  task automatic check_sched_perf_counters;
`ifdef DBG_TRACE_GEMM
    int observed_store_descriptors;
    begin
      observed_store_descriptors = 0;
      for (int issue = 0; issue < descriptor_issue_count; ++issue) begin
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
          if (descriptor_active[issue][ch]) begin
            if (descriptor_regs[issue][ch][DMA_R_DIR] == 1)
              observed_store_descriptors++;
            break;
          end
        end
      end
      repeat (2) @(posedge clk);
      #1;
      if (!gemm_dma_ctrl_if.idle)
        $fatal(1, "[sched_perf] final counter check was not idle");
      if (dut.dbg_cmd_accept_count_q != dma_done_pulse_count
       || dut.dbg_logical_complete_count_q != dma_done_pulse_count)
        $fatal(1, "[sched_perf] logical counts mismatch accept=%0d complete=%0d observed=%0d",
               dut.dbg_cmd_accept_count_q,
               dut.dbg_logical_complete_count_q, dma_done_pulse_count);
      if (dut.dbg_descriptor_issue_count_q != descriptor_issue_count
       || dut.dbg_descriptor_complete_count_q != descriptor_issue_count)
        $fatal(1, "[sched_perf] descriptor counts mismatch issue=%0d complete=%0d observed=%0d",
               dut.dbg_descriptor_issue_count_q,
               dut.dbg_descriptor_complete_count_q,
               descriptor_issue_count);
      if (dut.dbg_store_chunk_issue_count_q != observed_store_descriptors
       || dut.dbg_store_chunk_complete_count_q != observed_store_descriptors)
        $fatal(1, "[sched_perf] store descriptor counts mismatch issue=%0d complete=%0d observed=%0d",
               dut.dbg_store_chunk_issue_count_q,
               dut.dbg_store_chunk_complete_count_q,
               observed_store_descriptors);
      if (dut.dbg_pending_occupancy_max_q != TB_PENDING_DEPTH
       || dut.dbg_pending_occupancy_samples_q == 0
       || dut.dbg_pending_occupancy_sum_q < TB_PENDING_DEPTH)
        $fatal(1, "[sched_perf] pending occupancy mismatch samples=%0d sum=%0d max=%0d depth=%0d",
               dut.dbg_pending_occupancy_samples_q,
               dut.dbg_pending_occupancy_sum_q,
               dut.dbg_pending_occupancy_max_q, TB_PENDING_DEPTH);
      if (TB_PENDING_DEPTH == 4) begin
        if (dut.dbg_store_to_load_switch_count_q != 1
         || dut.dbg_switch_latency_count_q != 1
         || dut.dbg_switch_latency_sum_q == 0
         || dut.dbg_switch_latency_max_q != dut.dbg_switch_latency_sum_q)
          $fatal(1, "[sched_perf] store/load switch mismatch switches=%0d latency_count=%0d sum=%0d max=%0d",
                 dut.dbg_store_to_load_switch_count_q,
                 dut.dbg_switch_latency_count_q,
                 dut.dbg_switch_latency_sum_q,
                 dut.dbg_switch_latency_max_q);
      end else begin
        if (dut.dbg_store_to_load_switch_count_q != 0
         || dut.dbg_switch_latency_count_q != 0
         || dut.dbg_switch_latency_sum_q != 0
         || dut.dbg_switch_latency_max_q != 0)
          $fatal(1, "[sched_perf] unexpected switch in depth-only run");
      end
      $display("TMEM_DMA_SCHED_PERF_CHECK_PASS depth=%0d accepted=%0d descriptors=%0d stores=%0d logical=%0d pending_max=%0d switches=%0d latency_count=%0d latency_sum=%0d latency_max=%0d final_idle=1",
               TB_PENDING_DEPTH, dut.dbg_cmd_accept_count_q,
               dut.dbg_descriptor_issue_count_q,
               dut.dbg_store_chunk_issue_count_q,
               dut.dbg_logical_complete_count_q,
               dut.dbg_pending_occupancy_max_q,
               dut.dbg_store_to_load_switch_count_q,
               dut.dbg_switch_latency_count_q,
               dut.dbg_switch_latency_sum_q,
               dut.dbg_switch_latency_max_q);
    end
`else
    begin
      $fatal(1, "scheduler performance counter test requires DBG_TRACE_GEMM");
    end
`endif
  endtask

  for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_if
    assign cfg_reg_if[ch].ready = cfg_ready_drive[ch];
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
      dma_done_pulse_count = 0;
      store_done_pulse_count = 0;
      dma_done_prev = 1'b0;
      descriptor_issue_count = 0;
      descriptor_active = '0;
      descriptor_regs = '0;
    end else begin
      if (gemm_dma_ctrl_if.done) begin
        if (dma_done_prev)
          $fatal(1, "DMA done remained asserted for more than one cycle");
        dma_done_pulse_count++;
      end
      if (store_done)
        store_done_pulse_count++;
      dma_done_prev = gemm_dma_ctrl_if.done;
      if (|(cfg_valid_s & cfg_ready_s)) begin
        if (descriptor_issue_count >= 128)
          $fatal(1, "descriptor capture overflow");
        for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
          descriptor_active[descriptor_issue_count][ch] =
            cfg_valid_s[ch] && cfg_ready_s[ch];
          if (cfg_valid_s[ch] && cfg_ready_s[ch])
            descriptor_regs[descriptor_issue_count][ch] = cfg_regs_s[ch];
        end
        descriptor_issue_count++;
      end
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
    gemm_dma_ctrl_if.cmd_valid = 1'b0;
    gemm_dma_ctrl_if.cmd_tag = '0;
    gemm_dma_ctrl_if.cmd   = '0;
    next_cmd_tag = '0;

    reset = 1'b1;
    cfg_ready_drive = '1;
    clear_done_inputs();
    clear_cfg_scoreboard();
    clear_notify_scoreboard();

    repeat (5) @(posedge clk);
    reset = 1'b0;
    repeat (2) @(posedge clk);

    if ($test$plusargs("EXPECT_NOTIFY_FATAL")) begin
      gemm_unified_cmd_t c;
      c = '0;
      c.instr = make_instr(OP_NOTIFY, 28'd0);
      gemm_dma_ctrl_if.cmd = c;
      $display("EXPECT_TMEM_NOTIFY_FATAL_ARMED opcode=3");
      pulse_start();
      repeat (4) @(posedge clk);
      $fatal(1, "EXPECT_NOTIFY_FATAL intended assertion did not fire");
    end

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
      repeat (4) @(posedge clk);
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
      complete_active_channels_exact(1'b0, "ld_single_word");
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
      repeat (4) @(posedge clk);
      expect_cfg_count(8, "ld_full_8ch");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch) begin
        expect_channel_active(ch, 1'b1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_SRC_BASE_LO, 32'h0002_0200 + ch * 32'd64, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_DST_BASE_LO, 32'h0000_0040, "ld_full_8ch");
        // ch_words=1 per channel -> fallback.
        expect_cfg_reg(ch, DMA_R_BND0, 32'd1, "ld_full_8ch");
        expect_cfg_reg(ch, DMA_R_BND1, 32'd1, "ld_full_8ch");
      end
      complete_active_channels_exact(1'b0, "ld_full_8ch");
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
      repeat (4) @(posedge clk);
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
      complete_active_channels_exact(1'b1, "st_full_8ch");
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
      repeat (4) @(posedge clk);
      expect_cfg_count(1, "tmem_misaligned_ld_cfg");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, (ch == exp_ch), "tmem_misaligned_ld_cfg");
      expect_cfg_reg(exp_ch, DMA_R_SRC_BASE_LO, hbm_byte_addr[31:0], "tmem_misaligned_ld_cfg");
      expect_cfg_reg(exp_ch, DMA_R_DST_BASE_LO, spec_bank_local_byte[31:0], "tmem_misaligned_ld_cfg");
      // 2D form: fallback DST_ST1 is MEM_BLOCK_SIZE (TMEM bank stride),
      // independent of user s0.
      expect_cfg_reg(exp_ch, DMA_R_DST_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_misaligned_ld_cfg");
      complete_active_channels_exact(1'b0, "tmem_misaligned_ld_cfg");
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
      repeat (4) @(posedge clk);
      expect_cfg_count(1, "tmem_misaligned_st_cfg");
      for (int ch = 0; ch < NUM_CHANNELS; ++ch)
        expect_channel_active(ch, (ch == exp_ch), "tmem_misaligned_st_cfg");
      expect_cfg_reg(exp_ch, DMA_R_SRC_BASE_LO, spec_bank_local_byte[31:0], "tmem_misaligned_st_cfg");
      expect_cfg_reg(exp_ch, DMA_R_DST_BASE_LO, hbm_byte_addr[31:0], "tmem_misaligned_st_cfg");
      // 2D form: fallback SRC_ST1 is MEM_BLOCK_SIZE, independent of user s0.
      expect_cfg_reg(exp_ch, DMA_R_SRC_ST1, 32'(`MEM_BLOCK_SIZE), "tmem_misaligned_st_cfg");
      complete_active_channels_exact(1'b1, "tmem_misaligned_st_cfg");
    end

    run_pending_depth_smoke();

    if (TB_PENDING_DEPTH == 4) begin
      run_chunk_case(4, 4'd3, 3'd0);
      run_chunk_case(8, 4'd4, 3'd1);
      run_chunk_case(16, 4'd5, 3'd2);
      run_chunk_case(32, 4'd6, 3'd3);
      run_nonchunkable_cases();
      run_priority_pause_case();
      run_multiple_low_store_order_case();
      run_nonchunkable_pending_load_case();
      run_cfg_backpressure_case();
    end

    check_sched_perf_counters();

    $display("TMEM_DMA_EXACT_COMPLETION_PASS dma_done_pulses=%0d store_done_pulses=%0d notify_removed=1",
             dma_done_pulse_count, store_done_pulse_count);
    $display("All VX_gemm_tmem_dma_ctrl misalign tests passed");
    $display("TEST PASSED");
    $finish;
  end
endmodule

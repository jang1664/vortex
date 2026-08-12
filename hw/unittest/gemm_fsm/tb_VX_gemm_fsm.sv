// tb_VX_gemm_fsm.sv
`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_fsm import VX_gpu_pkg::*; #(
  parameter int TB_DMA_STORE_MAX_CHUNK_BEATS =
      `GEMM_DMA_STORE_MAX_CHUNK_BEATS
) ();

  parameter string TB_NAME  = "tb_VX_gemm_fsm";
  parameter real   PERIOD   = 10.0;

  // DUT uses cfg_reg_if.regs[0..28]
  parameter int CFG_NUM = `GEMM_CFG_REG_NUM;
  parameter int CFG_DW  = 32;

  // -----------------------------
  // Clock / Reset
  // -----------------------------
  logic clk, reset;

  initial begin
    clk = 1'b0;
    forever #(PERIOD/2.0) clk = ~clk;
  end

  initial begin
    reset = 1'b1;
    repeat (10) @(posedge clk);
    reset = 1'b0;
  end

  // -----------------------------
  // Interface instances
  // -----------------------------
  VX_config_reg_if #(
    .NUM(CFG_NUM),
    .DW (CFG_DW)
  ) cfg_reg_if();

  VX_gemm_fsm_if gemm_fsm_if();
  logic gemm_start;
  logic fsm_idle;
  logic pending_work;
  logic [2:0] pending_child;
  logic [31:0] completed_output_store_count;

  localparam int unsigned TB_ACC_DBUF_STRIDE
      = `GEMM_ACC_MEM_DEPTH * (4 * 2 * `MXU_COL);
  // Keep this value synchronized with the DUT state_t declaration.  The
  // directed final-drain stimulus intentionally observes this internal state.
  localparam logic [7:0] DUT_S_O_WAIT_LMEM2DRAM_FINAL = 8'd36;

  // -----------------------------
  // DUT
  // -----------------------------
  VX_gemm_fsm #(
    .INSTANCE_ID("gemm_fsm"),
    .DMA_STORE_MAX_CHUNK_BEATS(TB_DMA_STORE_MAX_CHUNK_BEATS)
  ) dut (
    .clk        (clk),
    .reset      (reset),
    .completed_output_store_count_i (completed_output_store_count),
    .cfg_reg_if (cfg_reg_if),
    .gemm_fsm_if(gemm_fsm_if),
    .gemm_start_o(gemm_start),
    .fsm_idle_o(fsm_idle),
    .pending_work_o(pending_work),
    .pending_child_o(pending_child)
  );

  // -----------------------------
  // Downstream "queue model":
  // allow DUT to emit whenever it wants (after reset deassert)
  // -----------------------------
  initial begin
    completed_output_store_count = 32'd0;
    gemm_fsm_if.flag.idle = 1'b0;
    gemm_fsm_if.flag.done = 1'b1;
    gemm_fsm_if.flag.child_ready = '0;
    wait (reset == 1'b0);
    gemm_fsm_if.flag.idle = 1'b1;
    gemm_fsm_if.flag.child_ready = '1;
  end

  // -----------------------------
  // Strong init for cfg interface during reset
  // (prevents X leakage into DUT sampling)
  // -----------------------------
  initial begin
    cfg_reg_if.valid = 1'b0;
    cfg_reg_if.entry_id   = '0;
    for (int i = 0; i < CFG_NUM; i++) cfg_reg_if.regs[i] = '0;

    // keep stable until reset is released
    wait (reset == 1'b0);
  end

  // -----------------------------
  // Helpers to decode cmd
  // instr[ 3:0] = opcode
  // instr[31:4] = size_bytes
  // -----------------------------
  function automatic logic [3:0]  get_op   (input gemm_unified_cmd_t c); return c.instr[3:0];   endfunction
  function automatic logic [7:0]  get_flags(input gemm_unified_cmd_t c); return c.flags;  endfunction
  function automatic int unsigned get_size (input gemm_unified_cmd_t c); return c.instr[31:4]; endfunction

  // Opcode map (keep consistent with your FSM)
  localparam logic [3:0] OP_DMA_LD      = 4'd1;
  localparam logic [3:0] OP_DMA_ST      = 4'd2;
  localparam logic [3:0] OP_NOTIFY      = 4'd3;
  localparam logic [3:0] OP_WAIT        = 4'd4;
  localparam logic [3:0] OP_W_LDMA_MXU  = 4'd5;
  localparam logic [3:0] OP_SC_LDMA_MXU = GEMM_OP_SC_LDMA_MXU;
  localparam logic [3:0] OP_ZP_LDMA_MXU = GEMM_OP_ZP_LDMA_MXU;
  localparam logic [3:0] OP_I_LDMA_ARM  = 4'd7;
  localparam logic [3:0] OP_O_ACC2LMEM  = 4'd8;
  localparam logic [3:0] OP_CLEAR       = 4'd9;

  typedef struct packed {
    logic [3:0]  op;
    logic [7:0]  flags;
    int unsigned size;
    logic [63:0] rs1;
    logic [63:0] rs2;
    logic [4:0]  rd;
    gemm_wait_meta_t [GEMM_MAX_WAIT_DEPS-1:0] waits;
    gemm_wait_meta_t [3:0] input_admit_waits;
    gemm_wait_meta_t writer_wait;
    gemm_notify_meta_t notify;
    gemm_prepare_meta_t prepare;
    logic dma_priority;
    logic [GEMM_DMA_MAX_CHUNK_LOG2P1_WIDTH-1:0]
      dma_max_chunk_log2p1;
  } cmd_rec_t;

  cmd_rec_t cmd_log[$];

  task automatic log_cmd(input gemm_unified_cmd_t c);
    cmd_rec_t r;
    begin
      r.op    = get_op(c);
      r.flags = get_flags(c);
      r.size  = get_size(c);
      r.rs1   = c.rs1_data[`XLEN-1:0];
      r.rs2   = c.rs2_data[`XLEN-1:0];
      r.rd    = c.rd;
      r.waits = c.waits;
      r.input_admit_waits = c.input_admit_waits;
      r.writer_wait = c.writer_wait;
      r.notify = c.notify;
      r.prepare = c.prepare;
      r.dma_priority = c.dma_priority;
      r.dma_max_chunk_log2p1 = c.dma_max_chunk_log2p1;
      cmd_log.push_back(r);

      $display("[%0t] CMD #%0d op=0x%02h flags=0x%02h size=%0d rs1=0x%016h rs2=0x%016h",
               $time, cmd_log.size()-1, r.op, r.flags, r.size, r.rs1, r.rs2);
    end
  endtask

  // Capture emitted commands
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (gemm_fsm_if.ctrl.start) begin
        log_cmd(gemm_fsm_if.ctrl.cmd);
      end
    end
  end

  // -----------------------------
  // Drive config (TB is cfg_reg_if master)
  //
  // Fix: two-phase handshake
  //  1) wait ready
  //  2) set regs with blocking assignments (stable now)
  //  3) wait 1 cycle
  //  4) pulse valid for 1 cycle
  // -----------------------------
  task automatic drive_cfg_once(
    input logic [63:0] input_base,
    input logic [63:0] weight_base,
    input logic [63:0] output_base,
    input logic [63:0] scale_base,
    input logic [63:0] zp_base,

    input logic [63:0] lmem_ibuf0_base,  //lmem
    input logic [63:0] lmem_ibuf1_base,
    input logic [63:0] lmem_wbuf0_base,
    input logic [63:0] lmem_wbuf1_base,
    input logic [63:0] lmem_scbuf0_base,
    input logic [63:0] lmem_scbuf1_base,
    input logic [63:0] lmem_zpbuf0_base,
    input logic [63:0] lmem_zpbuf1_base,
    input logic [63:0] lmem_obuf_base,

    input int unsigned M,
    input int unsigned N,
    input int unsigned K,
    input int unsigned qblk
  );
    begin
      // 0) wait until ready is 1 at a posedge boundary
      do @(posedge clk); while (!cfg_reg_if.ready);

      // 1) drive regs at negedge so they are stable before next posedge
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;
      cfg_reg_if.entry_id   = 32'd0;

      for (int i = 0; i < CFG_NUM; i++) cfg_reg_if.regs[i] = '0;
      
      // [0] CONTROL (bit0=start)
      cfg_reg_if.regs[0] = 32'h1;

      // 64-bit bases as {HI,LO} in 32-bit regs
      cfg_reg_if.regs[1]  = input_base[31:0];   // INPUT_BASE_LO
      cfg_reg_if.regs[2]  = input_base[63:32];  // INPUT_BASE_HI

      cfg_reg_if.regs[3]  = weight_base[31:0];  // WEIGHT_BASE_LO
      cfg_reg_if.regs[4]  = weight_base[63:32]; // WEIGHT_BASE_HI

      cfg_reg_if.regs[5]  = output_base[31:0];  // OUTPUT_BASE_LO
      cfg_reg_if.regs[6]  = output_base[63:32]; // OUTPUT_BASE_HI

      cfg_reg_if.regs[7]  = scale_base[31:0];   // SCALE_BASE_LO
      cfg_reg_if.regs[8]  = scale_base[63:32];  // SCALE_BASE_HI

      cfg_reg_if.regs[9]  = zp_base[31:0];      // ZP_BASE_LO
      cfg_reg_if.regs[10] = zp_base[63:32];     // ZP_BASE_HI

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

      // scalar dims (32-bit regs)
      cfg_reg_if.regs[29] = M[31:0];
      cfg_reg_if.regs[30] = N[31:0];
      cfg_reg_if.regs[31] = K[31:0];
      cfg_reg_if.regs[32] = qblk[31:0];
      cfg_reg_if.regs[33] = M[31:0];
      cfg_reg_if.regs[34] = N[31:0];
      cfg_reg_if.regs[35] = K[31:0];
      cfg_reg_if.regs[36] = 32'd0;
      cfg_reg_if.regs[37] = 32'd0;
      cfg_reg_if.regs[38] = 32'd0;
      cfg_reg_if.regs[39] = 32'd1; // QDIR=1 directed metadata matrix
      cfg_reg_if.regs[40] = 32'd7;
      cfg_reg_if.regs[41] = 32'd7;
      cfg_reg_if.regs[42] = 32'd7;

      // 2) assert valid BEFORE the sampling edge (use blocking)
      //    -> now at next posedge, DUT definitely sees valid=1
      cfg_reg_if.valid = 1'b1;

      @(posedge clk); // handshake edge (DUT samples here)

      // 3) deassert valid, but keep regs stable for 1 more cycle
      @(negedge clk);
      cfg_reg_if.valid = 1'b0;

      @(posedge clk); // regs hold cycle (prevents X leak into job_q on next FF stage)
    end
  endtask

  // -----------------------------
  // Basic sanity checks
  // -----------------------------
  task automatic sanity_check(
    input bit expect_three_tile_edge_reuse,
    input int unsigned expected_output_tiles
  );
    int n_dma_ld, n_dma_st, n_w, n_sc, n_zp;
    int n_arm, n_acc2lmem, n_wait, n_ntf;
    int unsigned g_expected_count [2];
    int unsigned w_consume_count [4];
    int unsigned sc_consume_count [2];
    int unsigned zp_consume_count [2];
    int unsigned tile_target [2];
    int unsigned w_target [4];
    int unsigned sc_target [2];
    int unsigned zp_target [2];
    int unsigned output_store_issue;
    int unsigned acc_copy_target [2];
    bit first_arm_seen [2];
    bit owner_valid [2];
    int unsigned owner_target [2];
    int unsigned owner_arm_count [2];
    int unsigned owner_count [2];
    bit owner_seen_nonaccum [2];
    bit owner_seen_accum [2];
    int unsigned directed_owner_arm_count [3];
    bit pending_copy_valid;
    int unsigned pending_copy_group;
    int unsigned pending_copy_target;
    int final_arm_count;
    int dma_prior_g_count;
    int w_consume_wait_count;
    int sc_consume_wait_count;
    int zp_consume_wait_count;
    int arm_split_wait_count;
    begin
      n_dma_ld   = 0;
      n_dma_st   = 0;
      n_w        = 0;
      n_sc       = 0;
      n_zp       = 0;
      n_arm      = 0;
      n_acc2lmem = 0;
      n_wait     = 0;
      n_ntf      = 0;
      for (int bank = 0; bank < 2; bank++) begin
        g_expected_count[bank] = 0;
        sc_consume_count[bank] = 0;
        zp_consume_count[bank] = 0;
        sc_target[bank] = 0;
        zp_target[bank] = 0;
      end
      for (int bank = 0; bank < 4; bank++) begin
        w_consume_count[bank] = 0;
        w_target[bank] = 0;
      end
      tile_target[0] = 0;
      tile_target[1] = 0;
      output_store_issue = 0;
      acc_copy_target[0] = 0;
      acc_copy_target[1] = 0;
      first_arm_seen[0] = 1'b0;
      first_arm_seen[1] = 1'b0;
      owner_valid[0] = 1'b0;
      owner_valid[1] = 1'b0;
      owner_target[0] = 0;
      owner_target[1] = 0;
      owner_arm_count[0] = 0;
      owner_arm_count[1] = 0;
      owner_count[0] = 0;
      owner_count[1] = 0;
      owner_seen_nonaccum[0] = 1'b0;
      owner_seen_nonaccum[1] = 1'b0;
      owner_seen_accum[0] = 1'b0;
      owner_seen_accum[1] = 1'b0;
      directed_owner_arm_count[0] = 0;
      directed_owner_arm_count[1] = 0;
      directed_owner_arm_count[2] = 0;
      pending_copy_valid = 1'b0;
      pending_copy_group = 0;
      pending_copy_target = 0;
      final_arm_count = 0;
      dma_prior_g_count = 0;
      w_consume_wait_count = 0;
      sc_consume_wait_count = 0;
      zp_consume_wait_count = 0;
      arm_split_wait_count = 0;

      foreach (cmd_log[i]) begin
        unique case (cmd_log[i].op)
          OP_DMA_LD:     n_dma_ld++;
          OP_DMA_ST:     n_dma_st++;
          OP_W_LDMA_MXU: n_w++;
          OP_SC_LDMA_MXU: n_sc++;
          OP_ZP_LDMA_MXU: n_zp++;
          OP_I_LDMA_ARM: n_arm++;
          OP_O_ACC2LMEM: n_acc2lmem++;
          OP_WAIT:       n_wait++;
          OP_NOTIFY:     n_ntf++;
          default: ;
        endcase

        if (!(cmd_log[i].op inside {OP_DMA_LD, OP_DMA_ST,
                                     OP_W_LDMA_MXU, OP_SC_LDMA_MXU,
                                     OP_ZP_LDMA_MXU,
                                     OP_I_LDMA_ARM, OP_O_ACC2LMEM}))
          $fatal(1, "Removed or invalid opcode emitted at command %0d: op=%0d",
                 i, cmd_log[i].op);
        for (int dep = 0; dep < GEMM_MAX_WAIT_DEPS; dep++) begin
          if (cmd_log[i].waits[dep].valid
              && cmd_log[i].waits[dep].reg_id >= GEMM_NUM_SYNC_REGS)
            $fatal(1, "Command %0d wait %0d has invalid RID %0d",
                   i, dep, cmd_log[i].waits[dep].reg_id);
        end
        if (cmd_log[i].notify.valid
            && cmd_log[i].notify.reg_id >= GEMM_NUM_SYNC_REGS)
          $fatal(1, "Command %0d notify has invalid RID %0d",
                 i, cmd_log[i].notify.reg_id);
        if (cmd_log[i].writer_wait.valid
            && cmd_log[i].writer_wait.reg_id >= GEMM_NUM_SYNC_REGS)
          $fatal(1, "Command %0d writer wait has invalid RID %0d",
                 i, cmd_log[i].writer_wait.reg_id);
        unique case (cmd_log[i].op)
          OP_DMA_LD: begin
            if (!cmd_log[i].prepare.valid
                || cmd_log[i].prepare.mode != GEMM_PREPARE_SOURCE_READ
                || cmd_log[i].prepare.max_beats
                   != GEMM_TILE_DMA_PREFETCH_MAX_BEATS)
              $fatal(1, "DMA load #%0d prepare credit mismatch got=%0d expected=%0d",
                     i, cmd_log[i].prepare.max_beats,
                     GEMM_TILE_DMA_PREFETCH_MAX_BEATS);
          end
          OP_W_LDMA_MXU: begin
            if (!cmd_log[i].prepare.valid
                || cmd_log[i].prepare.mode != GEMM_PREPARE_SOURCE_READ
                || cmd_log[i].prepare.max_beats
                   != GEMM_WEIGHT_LDMA_PREFETCH_MAX_BEATS)
              $fatal(1, "Weight load #%0d prepare credit mismatch got=%0d expected=%0d",
                     i, cmd_log[i].prepare.max_beats,
                     GEMM_WEIGHT_LDMA_PREFETCH_MAX_BEATS);
          end
          OP_SC_LDMA_MXU: begin
            if (!cmd_log[i].prepare.valid
                || cmd_log[i].prepare.mode != GEMM_PREPARE_SOURCE_READ
                || cmd_log[i].prepare.max_beats
                   != GEMM_SCALE_LDMA_PREFETCH_MAX_BEATS)
              $fatal(1, "Scale load #%0d prepare credit mismatch got=%0d expected=%0d",
                     i, cmd_log[i].prepare.max_beats,
                     GEMM_SCALE_LDMA_PREFETCH_MAX_BEATS);
          end
          OP_ZP_LDMA_MXU: begin
            if (!cmd_log[i].prepare.valid
                || cmd_log[i].prepare.mode != GEMM_PREPARE_SOURCE_READ
                || cmd_log[i].prepare.max_beats
                   != GEMM_ZERO_POINT_LDMA_PREFETCH_MAX_BEATS)
              $fatal(1, "Zero-point load #%0d prepare credit mismatch got=%0d expected=%0d",
                     i, cmd_log[i].prepare.max_beats,
                     GEMM_ZERO_POINT_LDMA_PREFETCH_MAX_BEATS);
          end
          OP_I_LDMA_ARM: begin
            if (!cmd_log[i].prepare.valid
                || cmd_log[i].prepare.mode != GEMM_PREPARE_SOURCE_READ
                || cmd_log[i].prepare.max_beats
                   != GEMM_INPUT_LDMA_PREFETCH_MAX_BEATS)
              $fatal(1, "Input load #%0d prepare credit mismatch got=%0d expected=%0d",
                     i, cmd_log[i].prepare.max_beats,
                     GEMM_INPUT_LDMA_PREFETCH_MAX_BEATS);
          end
          OP_DMA_ST, OP_O_ACC2LMEM: begin
            if (cmd_log[i].prepare.valid)
              $fatal(1, "Output/store command #%0d unexpectedly enables prepare", i);
          end
          default: ;
        endcase
        if (cmd_log[i].op == OP_DMA_LD
            && (!cmd_log[i].dma_priority
                || cmd_log[i].dma_max_chunk_log2p1 != 0))
          $fatal(1, "DMA load #%0d priority/chunk mismatch got=%0d/%0d expected=1/0",
                 i, cmd_log[i].dma_priority,
                 cmd_log[i].dma_max_chunk_log2p1);
        if (cmd_log[i].op == OP_DMA_ST
            && (cmd_log[i].dma_priority
                || cmd_log[i].dma_max_chunk_log2p1
                   != ($clog2(TB_DMA_STORE_MAX_CHUNK_BEATS) + 1)))
          $fatal(1, "DMA store #%0d priority/chunk mismatch got=%0d/%0d expected=0/%0d",
                 i, cmd_log[i].dma_priority,
                 cmd_log[i].dma_max_chunk_log2p1,
                 $clog2(TB_DMA_STORE_MAX_CHUNK_BEATS) + 1);
      end

      $display("---- Sanity summary ----");
      $display("  total cmds   = %0d", cmd_log.size());
      $display("  DMA_LD       = %0d", n_dma_ld);
      $display("  DMA_ST       = %0d", n_dma_st);
      $display("  W_LDMA       = %0d", n_w);
      $display("  SC_LDMA      = %0d", n_sc);
      $display("  ZP_LDMA      = %0d", n_zp);
      $display("  GEMM_ARM(I)  = %0d", n_arm);
      $display("  ACC2LMEM     = %0d", n_acc2lmem);
      $display("  WAIT         = %0d", n_wait);
      $display("  NOTIFY       = %0d", n_ntf);
      $display("------------------------");

      if (n_dma_ld < 4)   $error("Expected >=4 DMA_LD (I/W/SC/ZP preload). Got %0d", n_dma_ld);
      if (n_arm < 1)      $error("Expected >=1 OP_I_LDMA_ARM. Got %0d", n_arm);
      if (n_acc2lmem < 1) $error("Expected >=1 OP_O_ACC2LMEM. Got %0d", n_acc2lmem);
      if (n_dma_st < 1)   $error("Expected >=1 DMA_ST. Got %0d", n_dma_st);

      if (n_wait != 0 || n_ntf != 0)
        $fatal(1, "FSM emitted removed sync commands: WAIT=%0d NOTIFY=%0d",
               n_wait, n_ntf);

      foreach (cmd_log[i]) begin
        int unsigned cmd_buf;
        int unsigned wait_buf;
        unique case (cmd_log[i].op)
          OP_DMA_LD: begin
            cmd_buf = cmd_log[i].flags[0];
            if (cmd_log[i].rd > 3)
              $fatal(1, "DMA load #%0d has invalid role rd=%0d", i, cmd_log[i].rd);
            if (cmd_log[i].rd == 3) begin
              if (!cmd_log[i].notify.valid
                  || !cmd_log[i].notify.set_mode
                  || cmd_log[i].notify.reg_id != (cmd_buf ? 5 : 0)
                  || cmd_log[i].notify.value <= tile_target[cmd_buf])
                $fatal(1, "Tile-final ZP DMA #%0d has incoherent RID_TILE SET", i);
              tile_target[cmd_buf] = cmd_log[i].notify.value;
            end else if (cmd_log[i].notify.valid) begin
              $fatal(1, "Non-final tile DMA role rd=%0d unexpectedly notifies", cmd_log[i].rd);
            end

            if (cmd_log[i].rd == 0 && g_expected_count[cmd_buf] != 0
                && !cmd_log[i].waits[0].valid)
              $fatal(1, "Post-warmup input DMA #%0d lacks required prior-G wait", i);
            if (cmd_log[i].rd == 0 && cmd_log[i].waits[0].valid) begin
              if (!(cmd_log[i].waits[0].reg_id inside {4'd3, 4'd8}))
                $fatal(1, "Buffer-reuse DMA #%0d waits on non-G RID", i);
              wait_buf = (cmd_log[i].waits[0].reg_id == 8);
              if (g_expected_count[wait_buf] == 0
                  || cmd_log[i].waits[0].target != g_expected_count[wait_buf])
                $fatal(1, "Buffer-reuse DMA #%0d has stale compute target", i);
              dma_prior_g_count++;
            end else if (cmd_log[i].waits[0].valid) begin
              $fatal(1, "DMA role rd=%0d unexpectedly carries a wait", cmd_log[i].rd);
            end
            if (cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "DMA load #%0d uses wait slot beyond expected count", i);
          end

          OP_W_LDMA_MXU: begin
            logic [GEMM_SYNC_REG_ID_WIDTH-1:0] expected_w_rid;
            logic [GEMM_SYNC_REG_ID_WIDTH-1:0] expected_w_consume_rid;
            cmd_buf = cmd_log[i].flags[1:0];
            unique case (cmd_buf)
              0: begin
                expected_w_rid = 5'(1);
                expected_w_consume_rid = GEMM_RID_W_CONSUME0;
              end
              1: begin
                expected_w_rid = 5'(6);
                expected_w_consume_rid = GEMM_RID_W_CONSUME1;
              end
              2: begin
                expected_w_rid = GEMM_RID_W2;
                expected_w_consume_rid = GEMM_RID_W_CONSUME2;
              end
              default: begin
                expected_w_rid = GEMM_RID_W3;
                expected_w_consume_rid = GEMM_RID_W_CONSUME3;
              end
            endcase
            if (!cmd_log[i].waits[0].valid
                || !(cmd_log[i].waits[0].reg_id inside {4'd0, 4'd5}))
              $fatal(1, "W load #%0d lacks tile-ready wait", i);
            wait_buf = (cmd_log[i].waits[0].reg_id == 5);
            if (tile_target[wait_buf] == 0
                || cmd_log[i].waits[0].target != tile_target[wait_buf])
              $fatal(1, "W load #%0d tile target is not latest SET", i);
            if (w_consume_count[cmd_buf] != 0
                && !cmd_log[i].writer_wait.valid)
              $fatal(1, "W load #%0d lacks required writer consume wait", i);
            if (cmd_log[i].writer_wait.valid) begin
              if (cmd_log[i].writer_wait.reg_id != expected_w_consume_rid
                  || w_consume_count[cmd_buf] == 0
                  || cmd_log[i].writer_wait.target
                     != w_consume_count[cmd_buf])
                $fatal(1, "W load #%0d writer RID/target mismatch", i);
              w_consume_wait_count++;
            end
            if (cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "W load #%0d consume dependency remained in issue waits", i);
            if (!cmd_log[i].notify.valid
                || !cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != expected_w_rid
                || cmd_log[i].notify.value <= w_target[cmd_buf])
              $fatal(1, "W load #%0d has incoherent RID_W SET", i);
            w_target[cmd_buf] = cmd_log[i].notify.value;
          end

          OP_SC_LDMA_MXU, OP_ZP_LDMA_MXU: begin
            bit is_scale;
            logic [GEMM_SYNC_REG_ID_WIDTH-1:0] expected_qparam_rid;
            logic [GEMM_SYNC_REG_ID_WIDTH-1:0] expected_consume_rid;

            is_scale = (cmd_log[i].op == OP_SC_LDMA_MXU);
            cmd_buf = cmd_log[i].flags[1];
            if (!cmd_log[i].waits[0].valid
                || !(cmd_log[i].waits[0].reg_id inside {4'd0, 4'd5}))
              $fatal(1, "SC/ZP load #%0d lacks tile-ready wait", i);
            wait_buf = (cmd_log[i].waits[0].reg_id == 5);
            if (tile_target[wait_buf] == 0
                || cmd_log[i].waits[0].target != tile_target[wait_buf])
              $fatal(1, "SC/ZP load #%0d tile target is not latest SET", i);
            if (!cmd_log[i].flags[2])
              $fatal(1, "QDIR=1 SC/ZP load #%0d lost quant-direction metadata", i);
            if ((is_scale ? sc_consume_count[cmd_buf]
                          : zp_consume_count[cmd_buf]) != 0
                && !cmd_log[i].writer_wait.valid)
              $fatal(1, "SC/ZP load #%0d lacks required writer consume wait", i);
            expected_consume_rid = is_scale
                ? (cmd_buf ? GEMM_RID_SC_CONSUME1
                           : GEMM_RID_SC_CONSUME0)
                : (cmd_buf ? GEMM_RID_ZP_CONSUME1
                           : GEMM_RID_ZP_CONSUME0);
            if (cmd_log[i].writer_wait.valid) begin
              if (cmd_log[i].writer_wait.reg_id != expected_consume_rid
                  || (is_scale ? sc_consume_count[cmd_buf]
                               : zp_consume_count[cmd_buf]) == 0
                  || cmd_log[i].writer_wait.target
                     != (is_scale ? sc_consume_count[cmd_buf]
                                  : zp_consume_count[cmd_buf]))
                $fatal(1, "SC/ZP load #%0d writer RID/target mismatch", i);
              if (is_scale) sc_consume_wait_count++;
              else          zp_consume_wait_count++;
            end
            if (cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "SC/ZP load #%0d consume dependency remained in issue waits", i);

            expected_qparam_rid = is_scale
                                ? (cmd_buf ? GEMM_RID_SC1 : GEMM_RID_SC0)
                                : (cmd_buf ? GEMM_RID_ZP1 : GEMM_RID_ZP0);
            if (!cmd_log[i].notify.valid
                || !cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != expected_qparam_rid)
              $fatal(1,
                     "SC/ZP load #%0d has incoherent physical RID notification",
                     i);

            if (is_scale) begin
              if ((i + 1) >= cmd_log.size()
                  || cmd_log[i+1].op != OP_ZP_LDMA_MXU
                  || !cmd_log[i+1].notify.valid
                  || cmd_log[i+1].flags != cmd_log[i].flags
                  || cmd_log[i+1].notify.value != cmd_log[i].notify.value)
                $fatal(1, "SC load #%0d is not followed by matching ZP load", i);
            end else begin
              if (cmd_log[i].notify.value <= zp_target[cmd_buf])
                $fatal(1, "ZP load #%0d has non-monotonic qparam sequence", i);
              zp_target[cmd_buf] = cmd_log[i].notify.value;
            end
            if (is_scale)
              sc_target[cmd_buf] = cmd_log[i].notify.value;
          end

          OP_I_LDMA_ARM: begin
            int unsigned acc_group;
            int unsigned reuse_target;
            int unsigned w_bank;
            int unsigned s_bank;
            int unsigned z_bank;
            int unsigned g_bank;
            logic [GEMM_SYNC_REG_ID_WIDTH-1:0] expected_w_rid;

            w_bank = cmd_log[i].flags[3:2];
            s_bank = cmd_log[i].flags[1];
            z_bank = cmd_log[i].flags[0];
            unique case (w_bank)
              0: expected_w_rid = 5'(1);
              1: expected_w_rid = 5'(6);
              2: expected_w_rid = GEMM_RID_W2;
              default: expected_w_rid = GEMM_RID_W3;
            endcase
            acc_group = (cmd_log[i].rs1 >= TB_ACC_DBUF_STRIDE);
            reuse_target = cmd_log[i].input_admit_waits[3].target;
            if (!cmd_log[i].flags[6])
              $fatal(1, "QDIR=1 ARM #%0d lost quant-direction metadata", i);
            if (!cmd_log[i].notify.valid
                || !(cmd_log[i].notify.reg_id inside {5'd3, 5'd8})
                || cmd_log[i].notify.set_mode
                || cmd_log[i].notify.value != 32'd1)
              $fatal(1, "ARM #%0d lacks embedded RID_G PLUS-1", i);
            g_bank = (cmd_log[i].notify.reg_id == 5'd8);
            if (!cmd_log[i].waits[0].valid
                || !(cmd_log[i].waits[0].reg_id inside {5'd0, 5'd5}))
              $fatal(1, "ARM #%0d lacks exact tile-ready source wait", i);
            wait_buf = (cmd_log[i].waits[0].reg_id == 5'd5);
            if (tile_target[wait_buf] == 0
                || cmd_log[i].waits[0].target != tile_target[wait_buf])
              $fatal(1, "ARM #%0d tile-ready source target is not latest", i);
            if (cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "ARM #%0d retained a non-tile source dependency", i);

            if (!cmd_log[i].input_admit_waits[0].valid
                || cmd_log[i].input_admit_waits[0].reg_id != expected_w_rid
                || cmd_log[i].input_admit_waits[0].target
                   != w_target[w_bank]
                || !cmd_log[i].input_admit_waits[1].valid
                || cmd_log[i].input_admit_waits[1].reg_id
                   != (s_bank ? GEMM_RID_SC1 : GEMM_RID_SC0)
                || cmd_log[i].input_admit_waits[1].target
                   != sc_target[s_bank]
                || !cmd_log[i].input_admit_waits[2].valid
                || cmd_log[i].input_admit_waits[2].reg_id
                   != (z_bank ? GEMM_RID_ZP1 : GEMM_RID_ZP0)
                || cmd_log[i].input_admit_waits[2].target
                   != zp_target[z_bank])
              $fatal(1, "ARM #%0d independent W/SC/Z admission dependencies are incoherent", i);
            if (!cmd_log[i].input_admit_waits[3].valid
                || cmd_log[i].input_admit_waits[3].reg_id
                   != (acc_group ? 10 : 9)
                || reuse_target != acc_copy_target[acc_group])
              $fatal(1, "ARM #%0d ACC admission group/reuse dependency mismatch group=%0d rid=%0d target=%0d expected=%0d",
                     i, acc_group,
                     cmd_log[i].input_admit_waits[3].reg_id,
                     reuse_target, acc_copy_target[acc_group]);
            arm_split_wait_count++;

            if (!first_arm_seen[acc_group]) begin
              if (reuse_target != 0)
                $fatal(1, "First owner of ACC group %0d has nonzero target %0d",
                       acc_group, reuse_target);
              first_arm_seen[acc_group] = 1'b1;
            end

            if (!owner_valid[acc_group]) begin
              owner_valid[acc_group] = 1'b1;
              owner_target[acc_group] = reuse_target;
              owner_arm_count[acc_group] = 0;
              owner_seen_nonaccum[acc_group] = 1'b0;
              owner_seen_accum[acc_group] = 1'b0;
              owner_count[acc_group]++;
            end else if (reuse_target != owner_target[acc_group]) begin
              if (!owner_seen_nonaccum[acc_group]
                  || !owner_seen_accum[acc_group])
                $fatal(1, "ACC group %0d owner target %0d did not preserve capture across K accumulation",
                       acc_group, owner_target[acc_group]);
              owner_target[acc_group] = reuse_target;
              owner_arm_count[acc_group] = 0;
              owner_seen_nonaccum[acc_group] = 1'b0;
              owner_seen_accum[acc_group] = 1'b0;
              owner_count[acc_group]++;
            end
            owner_arm_count[acc_group]++;
            if (cmd_log[i].flags[4]) owner_seen_accum[acc_group] = 1'b1;
            else                     owner_seen_nonaccum[acc_group] = 1'b1;

            if (expect_three_tile_edge_reuse) begin
              if (acc_group == 0 && reuse_target == 0)
                directed_owner_arm_count[0]++;
              else if (acc_group == 1 && reuse_target == 0)
                directed_owner_arm_count[1]++;
              else if (acc_group == 0 && reuse_target == 4)
                directed_owner_arm_count[2]++;
              else
                $fatal(1, "Unexpected directed owner signature group=%0d target=%0d",
                       acc_group, reuse_target);
            end
            g_expected_count[g_bank]++;
            w_consume_count[w_bank]++;
            sc_consume_count[s_bank]++;
            zp_consume_count[z_bank]++;
            if (cmd_log[i].flags[5]) begin
              final_arm_count++;
            end
          end

          OP_O_ACC2LMEM: begin
            int unsigned acc_group;
            int unsigned copy_target;

            acc_group = (cmd_log[i].rs2 >= (TB_ACC_DBUF_STRIDE >> 1));
            copy_target = acc_copy_target[acc_group] + 1;
            if (pending_copy_valid)
              $fatal(1, "ACC2LMEM #%0d issued before prior copy was paired with DMA_ST", i);
            if (!cmd_log[i].waits[0].valid
                || cmd_log[i].waits[0].reg_id != 4
                || cmd_log[i].waits[0].target != output_store_issue
                || !cmd_log[i].waits[1].valid
                || !(cmd_log[i].waits[1].reg_id inside {4'd3, 4'd8}))
              $fatal(1, "ACC2LMEM #%0d lacks issued-store/current-compute waits", i);
            wait_buf = (cmd_log[i].waits[1].reg_id == 8);
            if (cmd_log[i].waits[1].target != g_expected_count[wait_buf])
              $fatal(1, "ACC2LMEM #%0d current-compute target is not latest", i);
            if (cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "ACC2LMEM #%0d uses wait slot beyond expected count", i);
            if (!cmd_log[i].notify.valid
                || !cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != (acc_group ? 10 : 9)
                || cmd_log[i].notify.value != copy_target
                || cmd_log[i].notify.value <= acc_copy_target[acc_group])
              $fatal(1, "ACC2LMEM #%0d lacks strictly increasing group-local SET", i);
            acc_copy_target[acc_group] = copy_target;
            pending_copy_valid = 1'b1;
            pending_copy_group = acc_group;
            pending_copy_target = copy_target;
          end

          OP_DMA_ST: begin
            if (!pending_copy_valid
                || !cmd_log[i].waits[0].valid
                || cmd_log[i].waits[0].reg_id
                   != (pending_copy_group ? 10 : 9)
                || cmd_log[i].waits[0].target != pending_copy_target
                || cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid
                || cmd_log[i].waits[4].valid)
              $fatal(1, "DMA store #%0d does not wait for its paired ACC group target", i);
            if (!cmd_log[i].notify.valid
                || cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != 4
                || cmd_log[i].notify.value != 1)
              $fatal(1, "DMA store #%0d lacks RID_O PLUS-1", i);
            pending_copy_valid = 1'b0;
            output_store_issue++;
          end
          default: ;
        endcase
      end

      for (int group_idx = 0; group_idx < 2; group_idx++) begin
        if (owner_valid[group_idx]
            && (!owner_seen_nonaccum[group_idx]
                || !owner_seen_accum[group_idx]))
          $fatal(1, "ACC group %0d final owner target %0d did not preserve capture across K accumulation",
                 group_idx, owner_target[group_idx]);
      end
      if (pending_copy_valid)
        $fatal(1, "Final ACC2LMEM was not paired with a DMA store");
      if (final_arm_count != expected_output_tiles)
        $fatal(1, "Expected %0d writeback-qualified ARM commands, got %0d",
               expected_output_tiles, final_arm_count);
      if (n_w == 0 || n_sc == 0 || n_zp == 0
          || output_store_issue != n_dma_st
          || n_acc2lmem != n_dma_st)
        $fatal(1, "Full command matrix coverage counters are incomplete");
      if (!first_arm_seen[0])
        $fatal(1, "Invocation did not exercise ACC group 0 first-owner target");
      if (expect_three_tile_edge_reuse) begin
        int unsigned full_owner_arms;
        int unsigned edge_owner_arms;

        full_owner_arms = (128 / `MXU_COL) * (384 / `MXU_ROW);
        edge_owner_arms = ((32 + `MXU_COL - 1) / `MXU_COL)
                        * (384 / `MXU_ROW);
        if (!first_arm_seen[1]
            || (owner_count[0] + owner_count[1]) < 3
            || owner_count[0] < 2
            || acc_copy_target[0] != 5
            || acc_copy_target[1] != 4
            || output_store_issue != 9)
          $fatal(1, "Three-tile edge/reuse coverage incomplete owners={%0d,%0d} copies={%0d,%0d} stores=%0d",
                 owner_count[0], owner_count[1],
                 acc_copy_target[0], acc_copy_target[1],
                 output_store_issue);
        if (directed_owner_arm_count[0] != full_owner_arms
            || directed_owner_arm_count[1] != full_owner_arms
            || directed_owner_arm_count[2] != edge_owner_arms)
          $fatal(1, "Multi-K/edge ARM coverage mismatch got={%0d,%0d,%0d} expected={%0d,%0d,%0d}",
                 directed_owner_arm_count[0], directed_owner_arm_count[1],
                 directed_owner_arm_count[2], full_owner_arms,
                 full_owner_arms, edge_owner_arms);
      end
      if (dma_prior_g_count == 0 || w_consume_wait_count == 0
          || sc_consume_wait_count == 0 || zp_consume_wait_count == 0
          || arm_split_wait_count == 0)
        $fatal(1, "QDIR=1 did not exercise retained waits and split Input admission dma_prior_g=%0d w=%0d sc=%0d zp=%0d input_split=%0d",
               dma_prior_g_count, w_consume_wait_count,
               sc_consume_wait_count, zp_consume_wait_count,
               arm_split_wait_count);
      $display("FSM_FULL_METADATA_MATRIX_PASS qdir=1 dma_ld=%0d w=%0d sc=%0d zp=%0d arm=%0d acc=%0d dma_st=%0d store_issue=%0d acc_copy={%0d,%0d} owners={%0d,%0d} prior_g={dma:%0d,acc2lmem:%0d} input_split=%0d consume={w:%0d,sc:%0d,zp:%0d}",
               n_dma_ld, n_w, n_sc, n_zp, n_arm, n_acc2lmem,
               n_dma_st, output_store_issue,
               acc_copy_target[0], acc_copy_target[1],
               owner_count[0], owner_count[1],
               dma_prior_g_count, n_acc2lmem, arm_split_wait_count,
               w_consume_wait_count, sc_consume_wait_count,
               zp_consume_wait_count);
      $display("FSM_DMA_CHUNK_ENCODING_PASS beats=%0d store_log2p1=%0d load_log2p1=0 priorities=store0_load1",
               TB_DMA_STORE_MAX_CHUNK_BEATS,
               $clog2(TB_DMA_STORE_MAX_CHUNK_BEATS) + 1);
      $display("FSM_PREFETCH_CREDIT_POLICY_PASS input=%0d weight=%0d scale=%0d zp=%0d tile=%0d output_store_disabled=1",
               GEMM_INPUT_LDMA_PREFETCH_MAX_BEATS,
               GEMM_WEIGHT_LDMA_PREFETCH_MAX_BEATS,
               GEMM_SCALE_LDMA_PREFETCH_MAX_BEATS,
               GEMM_ZERO_POINT_LDMA_PREFETCH_MAX_BEATS,
               GEMM_TILE_DMA_PREFETCH_MAX_BEATS);
    end
  endtask

  task automatic hold_and_release_final_drain(
    output int unsigned issued_store_count
  );
    int unsigned timeout_cycles;
    begin
      timeout_cycles = 0;
      while (dut.state_q != DUT_S_O_WAIT_LMEM2DRAM_FINAL) begin
        @(posedge clk);
        timeout_cycles++;
        if (timeout_cycles > 200000)
          $fatal(1, "TIMEOUT waiting for S_O_WAIT_LMEM2DRAM_FINAL");
      end

      issued_store_count = dut.o_store_issue_q;
      if (issued_store_count == 0)
        $fatal(1, "Final drain reached without an issued DMA store");

      // Exercise the exact boundary: the FSM must remain in final wait at
      // target-1, then leave only when the completed count reaches target.
      @(negedge clk);
      completed_output_store_count = issued_store_count - 1;
      repeat (6) begin
        @(posedge clk);
        #1;
        if (dut.state_q != DUT_S_O_WAIT_LMEM2DRAM_FINAL || fsm_idle)
          $fatal(1, "Final drain released below target completed=%0d issued=%0d",
                 completed_output_store_count, issued_store_count);
      end

      @(negedge clk);
      completed_output_store_count = issued_store_count;
      @(posedge clk);
      #1;
      if (dut.state_q == DUT_S_O_WAIT_LMEM2DRAM_FINAL)
        $fatal(1, "Final drain did not release at exact equality target=%0d",
               issued_store_count);

      timeout_cycles = 0;
      while (!fsm_idle) begin
        @(posedge clk);
        timeout_cycles++;
        if (timeout_cycles > 4)
          $fatal(1, "FSM did not return idle after final drain equality");
      end
    end
  endtask

  // -----------------------------
  // Run
  // -----------------------------
  initial begin : RUN
    int unsigned first_store_count;
    int unsigned second_store_count;

    $display("TB_NAME=%s starting...", TB_NAME);

    @(negedge reset);
    repeat (5) @(posedge clk);

    if (dut.o_store_issue_q != 0
        || dut.acc_copy_issue_q[0] != 0
        || dut.acc_copy_issue_q[1] != 0
        || dut.tile_acc_group_q != 0
        || dut.tile_acc_reuse_target_q != 0)
      $fatal(1, "Output dependency state did not reset to zero");

    // Three output tiles: full N tiles 0/1 own groups 0/1, then the 32-wide
    // edge tile reuses group 0.  K=384 creates three K tiles while the tile's
    // captured accumulator reuse target must remain unchanged.
    drive_cfg_once(
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

      128,           // M
      288,           // N = 128 + 128 + 32 edge
      384,           // K
      5              // log2(qblk=32)
    );

    hold_and_release_final_drain(first_store_count);
    sanity_check(1'b1, 3);
    if (first_store_count != 9)
      $fatal(1, "Directed three-tile invocation issued %0d stores, expected 9",
             first_store_count);

    // A new accepted invocation must restart all issue-side and captured
    // dependency state.  Use another multi-K job so the reset metadata is
    // checked through the same prior-G paths, not only by hierarchy.
    cmd_log.delete();
    @(negedge clk);
    completed_output_store_count = 0;
    drive_cfg_once(
      64'h1100_0000, 64'h2100_0000, 64'h3100_0000,
      64'h4100_0000, 64'h5100_0000,
      64'h6100_0000, 64'h7100_0000,
      64'h8100_0000, 64'h9100_0000,
      64'hA100_0000, 64'hB100_0000,
      64'hC100_0000, 64'hD100_0000,
      64'hE100_0000,
      64, 32, 384, 5
    );

    if (dut.o_store_issue_q != 0
        || dut.acc_copy_issue_q[0] != 0
        || dut.acc_copy_issue_q[1] != 0
        || dut.tile_acc_reuse_target_q != 0)
      $fatal(1, "New invocation did not clear output dependency state");

    hold_and_release_final_drain(second_store_count);
    sanity_check(1'b0, 1);
    if (second_store_count != 1)
      $fatal(1, "Reset-check invocation issued %0d stores, expected 1",
             second_store_count);

    $display("FSM_OUTPUT_DOUBLE_BUFFER_METADATA_PASS first_stores=%0d second_stores=%0d",
             first_store_count, second_store_count);
    $display("TEST PASSED: GEMM FSM output dependency checks completed");
    $finish;
  end

endmodule

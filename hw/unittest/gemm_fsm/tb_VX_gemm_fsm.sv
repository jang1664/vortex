// tb_VX_gemm_fsm.sv
`timescale 1ns/1ps
`include "VX_define.vh"

module tb_VX_gemm_fsm import VX_gpu_pkg::*; ();

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

  // -----------------------------
  // DUT
  // -----------------------------
  VX_gemm_fsm #(
    .INSTANCE_ID("gemm_fsm")
  ) dut (
    .clk        (clk),
    .reset      (reset),
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
    gemm_fsm_if.flag.idle = 1'b0;
    gemm_fsm_if.flag.done = 1'b1;
    gemm_fsm_if.flag.child_ready = '0;
    wait (reset == 1'b0);
    gemm_fsm_if.flag.idle = 1'b1;
    gemm_fsm_if.flag.child_ready = 5'b1_1111;
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
  localparam logic [3:0] OP_SZ_LDMA_MXU = 4'd6;
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
    gemm_notify_meta_t notify;
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
      r.notify = c.notify;
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
  task automatic sanity_check();
    int n_dma_ld, n_dma_st, n_w, n_sc, n_zp;
    int n_arm, n_acc2lmem, n_wait, n_ntf;
    int unsigned expected_count [2];
    int unsigned tile_target [2];
    int unsigned w_target [2];
    int unsigned sz_target [2];
    int unsigned o_even_target;
    int final_arm_count;
    int final_wait_index;
    int first_acc2lmem_index;
    int dma_prior_g_count;
    int w_prior_g_count;
    int sz_prior_g_count;
    int arm_prior_g_count;
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
      expected_count[0] = 0;
      expected_count[1] = 0;
      tile_target[0] = 0;
      tile_target[1] = 0;
      w_target[0] = 0;
      w_target[1] = 0;
      sz_target[0] = 0;
      sz_target[1] = 0;
      o_even_target = 0;
      final_arm_count = 0;
      final_wait_index = -1;
      first_acc2lmem_index = -1;
      dma_prior_g_count = 0;
      w_prior_g_count = 0;
      sz_prior_g_count = 0;
      arm_prior_g_count = 0;

      foreach (cmd_log[i]) begin
        unique case (cmd_log[i].op)
          OP_DMA_LD:     n_dma_ld++;
          OP_DMA_ST:     n_dma_st++;
          OP_W_LDMA_MXU: n_w++;
          OP_SZ_LDMA_MXU: begin
            if (cmd_log[i].notify.valid) n_zp++;
            else                         n_sc++;
          end
          OP_I_LDMA_ARM: n_arm++;
          OP_O_ACC2LMEM: begin
            n_acc2lmem++;
            if (first_acc2lmem_index < 0)
              first_acc2lmem_index = i;
          end
          OP_WAIT:       n_wait++;
          OP_NOTIFY:     n_ntf++;
          default: ;
        endcase

        if (!(cmd_log[i].op inside {OP_DMA_LD, OP_DMA_ST,
                                     OP_W_LDMA_MXU, OP_SZ_LDMA_MXU,
                                     OP_I_LDMA_ARM, OP_O_ACC2LMEM}))
          $fatal(1, "Removed or invalid opcode emitted at command %0d: op=%0d",
                 i, cmd_log[i].op);
        for (int dep = 0; dep < GEMM_MAX_WAIT_DEPS; dep++) begin
          if (cmd_log[i].waits[dep].valid
              && cmd_log[i].waits[dep].reg_id >= 11)
            $fatal(1, "Command %0d wait %0d has invalid RID %0d",
                   i, dep, cmd_log[i].waits[dep].reg_id);
          if ((dep > 0) && cmd_log[i].waits[dep].valid
              && !cmd_log[i].waits[dep-1].valid)
            $fatal(1, "Command %0d has non-contiguous wait slot %0d", i, dep);
        end
        if (cmd_log[i].notify.valid && cmd_log[i].notify.reg_id >= 11)
          $fatal(1, "Command %0d notify has invalid RID %0d",
                 i, cmd_log[i].notify.reg_id);
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

            if (cmd_log[i].rd == 0 && expected_count[cmd_buf] != 0
                && !cmd_log[i].waits[0].valid)
              $fatal(1, "Post-warmup input DMA #%0d lacks required prior-G wait", i);
            if (cmd_log[i].rd == 0 && cmd_log[i].waits[0].valid) begin
              if (!(cmd_log[i].waits[0].reg_id inside {4'd3, 4'd8}))
                $fatal(1, "Buffer-reuse DMA #%0d waits on non-G RID", i);
              wait_buf = (cmd_log[i].waits[0].reg_id == 8);
              if (expected_count[wait_buf] == 0
                  || cmd_log[i].waits[0].target != expected_count[wait_buf])
                $fatal(1, "Buffer-reuse DMA #%0d has stale compute target", i);
              dma_prior_g_count++;
            end else if (cmd_log[i].waits[0].valid) begin
              $fatal(1, "DMA role rd=%0d unexpectedly carries a wait", cmd_log[i].rd);
            end
            if (cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid)
              $fatal(1, "DMA load #%0d uses wait slot beyond expected count", i);
          end

          OP_W_LDMA_MXU: begin
            cmd_buf = cmd_log[i].flags[0];
            if (!cmd_log[i].waits[0].valid
                || !(cmd_log[i].waits[0].reg_id inside {4'd0, 4'd5}))
              $fatal(1, "W load #%0d lacks tile-ready wait", i);
            wait_buf = (cmd_log[i].waits[0].reg_id == 5);
            if (tile_target[wait_buf] == 0
                || cmd_log[i].waits[0].target != tile_target[wait_buf])
              $fatal(1, "W load #%0d tile target is not latest SET", i);
            if (expected_count[cmd_buf] != 0 && !cmd_log[i].waits[1].valid)
              $fatal(1, "W load #%0d lacks required prior-G wait", i);
            if (cmd_log[i].waits[1].valid) begin
              if (!(cmd_log[i].waits[1].reg_id inside {4'd3, 4'd8}))
                $fatal(1, "W load #%0d prior-compute wait has wrong RID", i);
              wait_buf = (cmd_log[i].waits[1].reg_id == 8);
              if (expected_count[wait_buf] == 0
                  || cmd_log[i].waits[1].target != expected_count[wait_buf])
                $fatal(1, "W load #%0d prior-compute target is not latest", i);
              w_prior_g_count++;
            end
            if (cmd_log[i].waits[2].valid || cmd_log[i].waits[3].valid)
              $fatal(1, "W load #%0d uses wait slot beyond expected count", i);
            if (!cmd_log[i].notify.valid
                || !cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != (cmd_buf ? 6 : 1)
                || cmd_log[i].notify.value <= w_target[cmd_buf])
              $fatal(1, "W load #%0d has incoherent RID_W SET", i);
            w_target[cmd_buf] = cmd_log[i].notify.value;
          end

          OP_SZ_LDMA_MXU: begin
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
            if (expected_count[cmd_buf] != 0 && !cmd_log[i].waits[1].valid)
              $fatal(1, "SC/ZP load #%0d lacks required prior-G wait", i);
            if (cmd_log[i].waits[1].valid) begin
              if (!(cmd_log[i].waits[1].reg_id inside {4'd3, 4'd8}))
                $fatal(1, "SC/ZP load #%0d prior-compute wait has wrong RID", i);
              wait_buf = (cmd_log[i].waits[1].reg_id == 8);
              if (expected_count[wait_buf] == 0
                  || cmd_log[i].waits[1].target != expected_count[wait_buf])
                $fatal(1, "SC/ZP load #%0d prior-compute target is not latest", i);
              sz_prior_g_count++;
            end
            if (cmd_log[i].waits[2].valid || cmd_log[i].waits[3].valid)
              $fatal(1, "SC/ZP load #%0d uses wait slot beyond expected count", i);

            if (!cmd_log[i].notify.valid) begin
              if ((i + 1) >= cmd_log.size()
                  || cmd_log[i+1].op != OP_SZ_LDMA_MXU
                  || !cmd_log[i+1].notify.valid
                  || cmd_log[i+1].flags != cmd_log[i].flags
                  || cmd_log[i+1].waits != cmd_log[i].waits)
                $fatal(1, "SC load #%0d is not followed by matching ZP load", i);
            end else begin
              if (!cmd_log[i].notify.set_mode
                  || cmd_log[i].notify.reg_id != (cmd_buf ? 7 : 2)
                  || cmd_log[i].notify.value <= sz_target[cmd_buf])
                $fatal(1, "ZP load #%0d has incoherent RID_SZ SET", i);
              sz_target[cmd_buf] = cmd_log[i].notify.value;
            end
          end

          OP_I_LDMA_ARM: begin
            cmd_buf = cmd_log[i].flags[2];
            if (!cmd_log[i].flags[5])
              $fatal(1, "QDIR=1 ARM #%0d lost quant-direction metadata", i);
            if (!cmd_log[i].notify.valid
                || cmd_log[i].notify.reg_id != (cmd_buf ? 8 : 3)
                || cmd_log[i].notify.set_mode
                || cmd_log[i].notify.value != 32'd1)
              $fatal(1, "ARM #%0d lacks embedded RID_G PLUS-1", i);
            if (!cmd_log[i].waits[0].valid
                || cmd_log[i].waits[0].reg_id != (cmd_buf ? 6 : 1)
                || cmd_log[i].waits[0].target != w_target[cmd_buf]
                || !cmd_log[i].waits[1].valid
                || cmd_log[i].waits[1].reg_id != (cmd_buf ? 7 : 2)
                || cmd_log[i].waits[1].target != sz_target[cmd_buf]
                || w_target[cmd_buf] != sz_target[cmd_buf])
              $fatal(1, "ARM #%0d W/SZ dependencies are incoherent", i);
            if (expected_count[cmd_buf] != 0 && !cmd_log[i].waits[2].valid)
              $fatal(1, "ARM #%0d lacks required prior-G wait", i);
            if (cmd_log[i].waits[2].valid) begin
              if (!(cmd_log[i].waits[2].reg_id inside {4'd3, 4'd8}))
                $fatal(1, "ARM #%0d prior-compute wait has wrong RID", i);
              wait_buf = (cmd_log[i].waits[2].reg_id == 8);
              if (expected_count[wait_buf] == 0
                  || cmd_log[i].waits[2].target != expected_count[wait_buf])
                $fatal(1, "ARM #%0d prior-compute target is not latest", i);
              arm_prior_g_count++;
            end
            if (cmd_log[i].waits[3].valid)
              $fatal(1, "ARM #%0d uses wait slot beyond expected count", i);
            expected_count[cmd_buf]++;
            if (cmd_log[i].flags[4]) begin
              final_arm_count++;
              final_wait_index = i;
            end
          end

          OP_O_ACC2LMEM: begin
            if (!cmd_log[i].waits[0].valid
                || cmd_log[i].waits[0].reg_id != 4
                || cmd_log[i].waits[0].target != o_even_target
                || !cmd_log[i].waits[1].valid
                || !(cmd_log[i].waits[1].reg_id inside {4'd3, 4'd8}))
              $fatal(1, "ACC2LMEM #%0d lacks RID_O-even/current-compute waits", i);
            wait_buf = (cmd_log[i].waits[1].reg_id == 8);
            if (cmd_log[i].waits[1].target != expected_count[wait_buf])
              $fatal(1, "ACC2LMEM #%0d current-compute target is not latest", i);
            if (cmd_log[i].waits[2].valid || cmd_log[i].waits[3].valid)
              $fatal(1, "ACC2LMEM #%0d uses wait slot beyond expected count", i);
            if (!cmd_log[i].notify.valid
                || !cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != 4
                || cmd_log[i].notify.value != o_even_target + 1)
              $fatal(1, "ACC2LMEM #%0d lacks RID_O odd SET", i);
          end

          OP_DMA_ST: begin
            if (!cmd_log[i].waits[0].valid
                || cmd_log[i].waits[0].reg_id != 4
                || cmd_log[i].waits[0].target != o_even_target + 1
                || cmd_log[i].waits[1].valid
                || cmd_log[i].waits[2].valid
                || cmd_log[i].waits[3].valid)
              $fatal(1, "DMA store #%0d lacks sole RID_O odd wait", i);
            if (!cmd_log[i].notify.valid
                || cmd_log[i].notify.set_mode
                || cmd_log[i].notify.reg_id != 4
                || cmd_log[i].notify.value != 1)
              $fatal(1, "DMA store #%0d lacks RID_O PLUS-1", i);
            o_even_target += 2;
          end
          default: ;
        endcase
      end

      if (final_arm_count != 1)
        $fatal(1, "Expected exactly one writeback-qualified ARM, got %0d",
               final_arm_count);
      if (first_acc2lmem_index <= final_wait_index)
        $fatal(1, "ACC2LMEM issued before final paired NOTIFY/WAIT");
      if (n_w == 0 || n_sc == 0 || n_zp == 0
          || o_even_target != (2 * n_dma_st))
        $fatal(1, "Full command matrix coverage counters are incomplete");
      if (dma_prior_g_count == 0 || w_prior_g_count == 0
          || sz_prior_g_count == 0 || arm_prior_g_count == 0)
        $fatal(1, "QDIR=1 did not exercise every required prior-G wait path dma=%0d w=%0d sz=%0d arm=%0d",
               dma_prior_g_count, w_prior_g_count,
               sz_prior_g_count, arm_prior_g_count);
      $display("FSM_FULL_METADATA_MATRIX_PASS qdir=1 dma_ld=%0d w=%0d sc=%0d zp=%0d arm=%0d acc=%0d dma_st=%0d rid_o_even=%0d prior_g={dma:%0d,w:%0d,sz:%0d,arm:%0d}",
               n_dma_ld, n_w, n_sc, n_zp, n_arm, n_acc2lmem,
               n_dma_st, o_even_target, dma_prior_g_count, w_prior_g_count,
               sz_prior_g_count, arm_prior_g_count);
    end
  endtask

  // -----------------------------
  // Run
  // -----------------------------
  initial begin : RUN
    int unsigned quiet;

    $display("TB_NAME=%s starting...", TB_NAME);

    @(negedge reset);
    repeat (5) @(posedge clk);

    // Small deterministic job
    // M=N=128 => 1 tile in M,N
    // K=384 => three DMA K tiles, covering the post-warmup buffer-reuse path.
    // qblk=32 => groups = 4
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
      128,           // N
      384,           // K
      5              // log2(qblk=32)
    );

    // Wait until no commands for a while
    quiet = 0;
    while (1) begin
      @(posedge clk);

      if (gemm_fsm_if.ctrl.start) quiet = 0;
      else                        quiet++;

      if ((cmd_log.size() > 0) && (quiet > 80)) begin
        $display("[%0t] No cmds for %0d cycles -> done.", $time, quiet);
        break;
      end

      if ($time > 2_000_000) begin
        $fatal(1, "TIMEOUT: no completion");
      end
    end

    sanity_check();
    $display("TEST PASSED: GEMM FSM command stream sanity checks completed");
    $finish;
  end

endmodule

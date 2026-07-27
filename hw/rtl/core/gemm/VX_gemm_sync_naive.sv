// Derived from origin/fpint_naive (ffb5aecb3); namespaced for dual-backend builds.
`include "VX_define.vh"

`ifdef GEMM_NAIVE

module VX_gemm_sync_naive import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_CHILDREN    = 5,
    parameter int N_NODE        = 5,
    parameter int NUM_SYNC_REGS = 9
) (
    input  wire               clk,
    input  wire               reset,

    VX_gemm_fsm_naive_if.slave       gemm_fsm_slv_if,
    VX_gemm_fsm_naive_if.master      gemm_fsm_mas_if[N_CHILDREN],
    VX_gemm_sync_if.slave      gemm_sync_slv_if[N_NODE],
    input logic                gemm_start_i
);

  initial begin
    if (N_CHILDREN != 5) $fatal(1, "%s: This version assumes N_CHILDREN=5", INSTANCE_ID);
    if (N_NODE     != 5) $fatal(1, "%s: This version assumes N_NODE=5", INSTANCE_ID);
  end

  // --------------------------------------------------------------------------
  // Opcodes
  // --------------------------------------------------------------------------
  localparam logic [7:0] OP_WAIT          = 8'hF0;
  localparam logic [7:0] OP_NOTIFY        = 8'hF1;
  localparam logic [7:0] OP_DMA_LD        = 8'h10;
  localparam logic [7:0] OP_DMA_ST        = 8'h11;
  localparam logic [7:0] OP_W_LDMA_MXU    = 8'h20;
  localparam logic [7:0] OP_SC_LDMA_MXU   = 8'h21;
  localparam logic [7:0] OP_ZP_LDMA_MXU   = 8'h24;
  localparam logic [7:0] OP_I_LDMA_ARM    = 8'h22;


  // --------------------------------------------------------------------------
  // Sync registers
  // --------------------------------------------------------------------------
  logic [31:0] sync_regs [NUM_SYNC_REGS];

  // --------------------------------------------------------------------------
  // Decode incoming command
  // --------------------------------------------------------------------------
  wire        in_valid = gemm_fsm_slv_if.ctrl.start;
  wire [7:0]  opcode   = gemm_fsm_slv_if.ctrl.cmd.instr[7:0];

  wire is_wait   = (opcode == OP_WAIT);
  wire is_notify = (opcode == OP_NOTIFY);

  wire [7:0]  wait_reg_id = gemm_fsm_slv_if.ctrl.cmd.rs1_data[7:0];
  wire [31:0] wait_target = gemm_fsm_slv_if.ctrl.cmd.rs2_data[31:0];

  wire        wait_reg_in_range = (wait_reg_id < NUM_SYNC_REGS);
  wire [31:0] wait_reg_val      = wait_reg_in_range ? sync_regs[wait_reg_id] : 32'd0;
  wire        wait_satisfied    = (!wait_reg_in_range) ? 1'b1 : (wait_reg_val >= wait_target);

  // --------------------------------------------------------------------------
  // Route decode (0:i,1:w,2:sz,3:o,4:dma)
  // --------------------------------------------------------------------------
  localparam int ROUTE_W = 3;
  logic [ROUTE_W-1:0] cmd_route;
  logic               cmd_valid;

  always_comb begin
    cmd_route = '0;
    cmd_valid = 1'b0;

    if (!is_wait && !is_notify) begin
      cmd_valid = 1'b1;
      unique case (opcode)
        OP_I_LDMA_ARM:   cmd_route = 3'd0;
        OP_W_LDMA_MXU:   cmd_route = 3'd1;
        OP_SC_LDMA_MXU,
        OP_ZP_LDMA_MXU:  cmd_route = 3'd2;
        OP_DMA_LD,
        OP_DMA_ST:       cmd_route = 3'd4;
        default: begin
          cmd_valid = 1'b0;
          cmd_route = 3'd0;
        end
      endcase
    end
  end

  logic [ROUTE_W-1:0] last_cmd_route;
  logic [ROUTE_W-1:0] route_eff;

  always_comb begin
    route_eff = cmd_route;
    if (is_notify) route_eff = last_cmd_route;
  end

  // --------------------------------------------------------------------------
  // Child idle select (NO iface_array[var])
  // --------------------------------------------------------------------------
  logic child_idle_sel;

  always_comb begin
    unique case (route_eff)
      3'd0: child_idle_sel = gemm_fsm_mas_if[0].flag.idle;
      3'd1: child_idle_sel = gemm_fsm_mas_if[1].flag.idle;
      3'd2: child_idle_sel = gemm_fsm_mas_if[2].flag.idle;
      3'd3: child_idle_sel = gemm_fsm_mas_if[3].flag.idle;
      3'd4: child_idle_sel = gemm_fsm_mas_if[4].flag.idle;
      default: child_idle_sel = 1'b0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Backpressure / accept condition
  //
  // Contract:
  //  - WAIT: consumed internally by sync
  //    * if not satisfied: stall parent (idle/ready=0), do NOT forward to child
  //    * if satisfied    : accept (idle/ready=1), still do NOT forward to child
  //  - NOTIFY: forwarded to the route of the last normal cmd (route_eff)
  //  - Normal cmd: forwarded to decoded route (route_eff==cmd_route)
  // --------------------------------------------------------------------------
  logic can_accept;

  always_comb begin
    // IMPORTANT:
    // can_accept must not depend on in_valid for decoded commands.
    // Otherwise, if parent start depends on idle(=can_accept), a comb loop can form.
    if (is_wait) begin
      can_accept = wait_satisfied;       // only gating is the sync condition
    end else if (is_notify) begin
      can_accept = child_idle_sel;       // must be able to enqueue notify
    end else if (cmd_valid) begin
      can_accept = child_idle_sel;       // must be able to enqueue cmd
    end else if (in_valid) begin
      can_accept = 1'b0;                 // unknown opcode while parent drives valid
    end else begin
      can_accept = 1'b1;                 // no active cmd; report ready
    end
  end

  // Parent flags (idle used as READY)
  // - When WAIT not satisfied: idle=0 => parent stops issuing new cmds
  // - When satisfied or no input: idle=1
  always_comb begin
    gemm_fsm_slv_if.flag.idle = can_accept;
    gemm_fsm_slv_if.flag.done = 1'b0;
  end

  // --------------------------------------------------------------------------
  // Drive child queues (start only when accepted)
  //  - WAIT is NEVER forwarded to any child (start stays 0 for all children)
  // --------------------------------------------------------------------------
  genvar gi;
  generate
    for (gi = 0; gi < N_CHILDREN; gi++) begin : g_child
      always_comb begin
        gemm_fsm_mas_if[gi].ctrl.cmd   = gemm_fsm_slv_if.ctrl.cmd;
        gemm_fsm_mas_if[gi].ctrl.start = 1'b0;

        if (in_valid && can_accept) begin
          // WAIT is consumed internally: do not forward
          if (is_notify) begin
            gemm_fsm_mas_if[gi].ctrl.start = (gi == route_eff);
          end else if (cmd_valid) begin
            gemm_fsm_mas_if[gi].ctrl.start = (gi == route_eff);
          end
        end
      end
    end
  endgenerate

  // Update last_cmd_route only when a normal cmd is accepted
  always_ff @(posedge clk) begin
    if (reset) begin
      last_cmd_route <= '0;
    end else if (in_valid && can_accept) begin
      if (!is_wait && !is_notify && cmd_valid) begin
        last_cmd_route <= cmd_route;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Sync ready: always 1 (unrolled)
  // --------------------------------------------------------------------------
  assign gemm_sync_slv_if[0].ready = 1'b1;
  assign gemm_sync_slv_if[1].ready = 1'b1;
  assign gemm_sync_slv_if[2].ready = 1'b1;
  assign gemm_sync_slv_if[3].ready = 1'b1;
  assign gemm_sync_slv_if[4].ready = 1'b1;

  // --------------------------------------------------------------------------
  // Sync updates from nodes (unrolled, NO iface_array[var])
  //  policy:
  //    value[31]==1 -> set (= value[30:0])
  //    else         -> add (+= value)
  // --------------------------------------------------------------------------
  wire [7:0] rid0 = gemm_sync_slv_if[0].reg_idx[7:0];
  wire [7:0] rid1 = gemm_sync_slv_if[1].reg_idx[7:0];
  wire [7:0] rid2 = gemm_sync_slv_if[2].reg_idx[7:0];
  wire [7:0] rid3 = gemm_sync_slv_if[3].reg_idx[7:0];
  wire [7:0] rid4 = gemm_sync_slv_if[4].reg_idx[7:0];

  wire [31:0] val0 = gemm_sync_slv_if[0].value;
  wire [31:0] val1 = gemm_sync_slv_if[1].value;
  wire [31:0] val2 = gemm_sync_slv_if[2].value;
  wire [31:0] val3 = gemm_sync_slv_if[3].value;
  wire [31:0] val4 = gemm_sync_slv_if[4].value;

  wire upd0_valid = gemm_sync_slv_if[0].valid && (rid0 < NUM_SYNC_REGS);
  wire upd1_valid = gemm_sync_slv_if[1].valid && (rid1 < NUM_SYNC_REGS);
  wire upd2_valid = gemm_sync_slv_if[2].valid && (rid2 < NUM_SYNC_REGS);
  wire upd3_valid = gemm_sync_slv_if[3].valid && (rid3 < NUM_SYNC_REGS);
  wire upd4_valid = gemm_sync_slv_if[4].valid && (rid4 < NUM_SYNC_REGS);

  logic [31:0] sync_regs_n [NUM_SYNC_REGS];

  function automatic [31:0] reduce_updates(
    input logic [31:0] cur,
    input logic [7:0]  reg_id
  );
    logic hit0, hit1, hit2, hit3, hit4;
    logic set0, set1, set2, set3, set4;
    logic [31:0] base;
    logic [31:0] add0, add1, add2, add3, add4;
    logic [31:0] sum01, sum23, sum4base;
    begin
      hit0 = upd0_valid && (rid0 == reg_id);
      hit1 = upd1_valid && (rid1 == reg_id);
      hit2 = upd2_valid && (rid2 == reg_id);
      hit3 = upd3_valid && (rid3 == reg_id);
      hit4 = upd4_valid && (rid4 == reg_id);

      set0 = hit0 && val0[31];
      set1 = hit1 && val1[31];
      set2 = hit2 && val2[31];
      set3 = hit3 && val3[31];
      set4 = hit4 && val4[31];

      base = cur;
      if (set0) base = {1'b0, val0[30:0]};
      if (set1) base = {1'b0, val1[30:0]};
      if (set2) base = {1'b0, val2[30:0]};
      if (set3) base = {1'b0, val3[30:0]};
      if (set4) base = {1'b0, val4[30:0]};

      // An add contributes only when no later node overwrites it with SET.
      add0 = (hit0 && !val0[31] && !(set1 || set2 || set3 || set4)) ? val0 : 32'd0;
      add1 = (hit1 && !val1[31] && !(set2 || set3 || set4)) ? val1 : 32'd0;
      add2 = (hit2 && !val2[31] && !(set3 || set4)) ? val2 : 32'd0;
      add3 = (hit3 && !val3[31] && !set4) ? val3 : 32'd0;
      add4 = (hit4 && !val4[31]) ? val4 : 32'd0;

      // Six operands reduce through three balanced 32-bit adder levels.
      sum01 = add0 + add1;
      sum23 = add2 + add3;
      sum4base = add4 + base;
      reduce_updates = (sum01 + sum23) + sum4base;
    end
  endfunction

  always_comb begin
    for (int k = 0; k < NUM_SYNC_REGS; k++) begin
      sync_regs_n[k] = reduce_updates(sync_regs[k], 8'(k));
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      for (int k = 0; k < NUM_SYNC_REGS; k++) begin
        sync_regs[k] <= 32'd0;
      end
    end else if (gemm_start_i) begin
      // Clear all sync registers at the start of GEMM (optional, depends on SW contract)
      for (int k = 0; k < NUM_SYNC_REGS; k++) begin
        sync_regs[k] <= 32'd0;
      end
    end else begin
      for (int k = 0; k < NUM_SYNC_REGS; k++) begin
        sync_regs[k] <= sync_regs_n[k];
      end
    end
  end

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
  localparam int DBG_BIT_W    = $bits(logic);
  localparam int DBG_WORD_W   = $bits(logic [31:0]);
  localparam int DBG_OPCODE_W = $bits(opcode);
  localparam int DBG_ROUTE_W  = $bits(cmd_route);

  localparam int DBG_GEMM_SYNC_P0_W = ((12 + (2 * N_CHILDREN) + N_NODE) * DBG_BIT_W) + DBG_OPCODE_W + (3 * DBG_ROUTE_W);
  localparam int DBG_GEMM_SYNC_P1_W = ((3 + NUM_SYNC_REGS) * DBG_WORD_W);
  localparam int DBG_GEMM_SYNC_P2_W = ((2 * N_NODE) * DBG_WORD_W);
  localparam int DBG_GEMM_SYNC_P3_W = (NUM_SYNC_REGS * DBG_WORD_W);

  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_SYNC_P0_W-1:0] dbg_gemm_sync_probe0 = {
      reset,
      gemm_start_i,
      in_valid,
      can_accept,
      cmd_valid,
      is_wait,
      is_notify,
      wait_reg_in_range,
      wait_satisfied,
      child_idle_sel,
      opcode,
      cmd_route,
      route_eff,
      last_cmd_route,
      gemm_fsm_slv_if.ctrl.start,
      gemm_sync_slv_if[0].valid,
      gemm_fsm_mas_if[0].ctrl.start,
      gemm_fsm_mas_if[1].ctrl.start,
      gemm_fsm_mas_if[2].ctrl.start,
      gemm_fsm_mas_if[3].ctrl.start,
      gemm_fsm_mas_if[4].ctrl.start,
      gemm_fsm_mas_if[0].flag.idle,
      gemm_fsm_mas_if[1].flag.idle,
      gemm_fsm_mas_if[2].flag.idle,
      gemm_fsm_mas_if[3].flag.idle,
      gemm_fsm_mas_if[4].flag.idle,
      upd0_valid,
      upd1_valid,
      upd2_valid,
      upd3_valid,
      upd4_valid
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_SYNC_P1_W-1:0] dbg_gemm_sync_probe1 = {
      32'(wait_reg_id),
      wait_target,
      wait_reg_val,
      sync_regs[0],
      sync_regs[1],
      sync_regs[2],
      sync_regs[3],
      sync_regs[4],
      sync_regs[5],
      sync_regs[6],
      sync_regs[7],
      sync_regs[8]
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_SYNC_P2_W-1:0] dbg_gemm_sync_probe2 = {
      32'(gemm_sync_slv_if[0].reg_idx),
      gemm_sync_slv_if[0].value,
      32'(gemm_sync_slv_if[1].reg_idx),
      gemm_sync_slv_if[1].value,
      32'(gemm_sync_slv_if[2].reg_idx),
      gemm_sync_slv_if[2].value,
      32'(gemm_sync_slv_if[3].reg_idx),
      gemm_sync_slv_if[3].value,
      32'(gemm_sync_slv_if[4].reg_idx),
      gemm_sync_slv_if[4].value
  };
  (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_SYNC_P3_W-1:0] dbg_gemm_sync_probe3 = {
      sync_regs_n[0],
      sync_regs_n[1],
      sync_regs_n[2],
      sync_regs_n[3],
      sync_regs_n[4],
      sync_regs_n[5],
      sync_regs_n[6],
      sync_regs_n[7],
      sync_regs_n[8]
  };

  ila_gemm_sync ila_gemm_sync_inst (
    .clk    (clk),
    .probe0 (dbg_gemm_sync_probe0),
    .probe1 (dbg_gemm_sync_probe1),
    .probe2 (dbg_gemm_sync_probe2),
    .probe3 (dbg_gemm_sync_probe3)
  );
`endif
`endif

`ifdef DBG_TRACE_GEMM_CTRL
  always_ff @(posedge clk) begin
    if (!reset) begin
      if (upd0_valid)
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_UPD | {inst=%s, node=0, reg_id=%0d, value=0x%08h, next_val=%0d}\n",
                 $time, INSTANCE_ID, rid0, gemm_sync_slv_if[0].value, sync_regs_n[rid0]))
      if (upd1_valid)
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_UPD | {inst=%s, node=1, reg_id=%0d, value=0x%08h, next_val=%0d}\n",
                 $time, INSTANCE_ID, rid1, gemm_sync_slv_if[1].value, sync_regs_n[rid1]))
      if (upd2_valid)
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_UPD | {inst=%s, node=2, reg_id=%0d, value=0x%08h, next_val=%0d}\n",
                 $time, INSTANCE_ID, rid2, gemm_sync_slv_if[2].value, sync_regs_n[rid2]))
      if (upd3_valid)
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_UPD | {inst=%s, node=3, reg_id=%0d, value=0x%08h, next_val=%0d}\n",
                 $time, INSTANCE_ID, rid3, gemm_sync_slv_if[3].value, sync_regs_n[rid3]))
      if (upd4_valid)
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_UPD | {inst=%s, node=4, reg_id=%0d, value=0x%08h, next_val=%0d}\n",
                 $time, INSTANCE_ID, rid4, gemm_sync_slv_if[4].value, sync_regs_n[rid4]))
    end
  end
`endif

// --------------------------------------------------------------------------
  // Runtime Assertion: Unknown Opcode Check
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset===0 && in_valid===1) begin
      if (!is_wait && !is_notify && !cmd_valid) begin
        $display("%t %s: [ERROR] Unknown Opcode detected! Opcode=0x%02h", $time, INSTANCE_ID, opcode);
        // $fatal(1, "%s: Simulation stopped due to unknown opcode 0x%02h", INSTANCE_ID, opcode);
      end
    end
  end

`ifdef DBG_TRACE_GEMM_CTRL
  always_ff @(posedge clk) begin
    if (!reset && in_valid) begin
      if (is_wait) begin
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_WAIT | {inst=%s, reg_id=%0d, reg_val=%0d, target=%0d, satisfied=%0d, can_accept=%0d}\n",
                 $time, INSTANCE_ID, wait_reg_id, wait_reg_val, wait_target, wait_satisfied, can_accept))
      end else if (is_notify) begin
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_NOTIFY | {inst=%s, route_eff=%0d, child_idle_sel=%0d, can_accept=%0d}\n",
                 $time, INSTANCE_ID, route_eff, child_idle_sel, can_accept))
      end else begin
        `TRACE(3, ("%m : [%0t] | GEMM_SYNC_CMD | {inst=%s, opcode=0x%02h, route_eff=%0d, cmd_valid=%0d, child_idle_sel=%0d, can_accept=%0d}\n",
                 $time, INSTANCE_ID, opcode, route_eff, cmd_valid, child_idle_sel, can_accept))
      end
    end
  end
`endif

endmodule

`endif // GEMM_NAIVE

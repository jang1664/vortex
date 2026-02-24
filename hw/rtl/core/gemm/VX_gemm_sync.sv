`include "VX_define.vh"

module VX_gemm_sync import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_CHILDREN    = 5,
    parameter int N_NODE        = 5,
    parameter int NUM_SYNC_REGS = 9
) (
    input  wire               clk,
    input  wire               reset,

    VX_gemm_fsm_if.slave       gemm_fsm_slv_if,
    VX_gemm_fsm_if.master      gemm_fsm_mas_if[N_CHILDREN],
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
  localparam logic [7:0] OP_O_ACC2LMEM    = 8'h23;


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
        OP_O_ACC2LMEM:   cmd_route = 3'd3;
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
    can_accept = 1'b1;

    if (in_valid) begin
      if (is_wait) begin
        can_accept = wait_satisfied;     // only gating is the sync condition
      end else if (is_notify) begin
        can_accept = child_idle_sel;     // must be able to enqueue notify
      end else if (cmd_valid) begin
        can_accept = child_idle_sel;     // must be able to enqueue cmd
      end else begin
        can_accept = 1'b0;
      end
    end
  end

  // Parent flags (idle used as READY)
  // - When WAIT not satisfied: idle=0 => parent stops issuing new cmds
  // - When satisfied or no input: idle=1
  always_comb begin
    gemm_fsm_slv_if.flag.idle = (!in_valid) ? 1'b1 : can_accept;
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
  function automatic [31:0] apply_update(input [31:0] cur, input [31:0] v);
    begin
      if (v[31]) apply_update = {1'b0, v[30:0]}; // set
      else      apply_update = cur + {1'b0, v[30:0]}; // add
    end
  endfunction

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
      // node 0
      if (gemm_sync_slv_if[0].valid) begin
        logic [7:0] rid0;
        rid0 = gemm_sync_slv_if[0].reg_idx[7:0];
        if (rid0 < NUM_SYNC_REGS)
          sync_regs[rid0] <= apply_update(sync_regs[rid0], gemm_sync_slv_if[0].value);
      end
      // node 1
      if (gemm_sync_slv_if[1].valid) begin
        logic [7:0] rid1;
        rid1 = gemm_sync_slv_if[1].reg_idx[7:0];
        if (rid1 < NUM_SYNC_REGS)
          sync_regs[rid1] <= apply_update(sync_regs[rid1], gemm_sync_slv_if[1].value);
      end
      // node 2
      if (gemm_sync_slv_if[2].valid) begin
        logic [7:0] rid2;
        rid2 = gemm_sync_slv_if[2].reg_idx[7:0];
        if (rid2 < NUM_SYNC_REGS)
          sync_regs[rid2] <= apply_update(sync_regs[rid2], gemm_sync_slv_if[2].value);
      end
      // node 3
      if (gemm_sync_slv_if[3].valid) begin
        logic [7:0] rid3;
        rid3 = gemm_sync_slv_if[3].reg_idx[7:0];
        if (rid3 < NUM_SYNC_REGS)
          sync_regs[rid3] <= apply_update(sync_regs[rid3], gemm_sync_slv_if[3].value);
      end
      // node 4
      if (gemm_sync_slv_if[4].valid) begin
        logic [7:0] rid4;
        rid4 = gemm_sync_slv_if[4].reg_idx[7:0];
        if (rid4 < NUM_SYNC_REGS)
          sync_regs[rid4] <= apply_update(sync_regs[rid4], gemm_sync_slv_if[4].value);
      end
    end
  end

// --------------------------------------------------------------------------
  // Runtime Assertion: Unknown Opcode Check
  // --------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset && in_valid) begin
      // 입력은 유효한데(Wait/Notify 아님), 디코딩 로직(case문)에서 cmd_valid를 1로 만들지 못한 경우
      if (!is_wait && !is_notify && !cmd_valid) begin
        $error("%t %s: [ERROR] Unknown Opcode detected! Opcode=0x%02h", $time, INSTANCE_ID, opcode);
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

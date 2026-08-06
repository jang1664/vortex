`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_CHILDREN = 5,
    parameter int N_NODE     = 5,
    parameter int CHILD_QUEUE_DEPTH = 4,
    parameter int DMA_CHILD_QUEUE_DEPTH = 8
) (
    input  wire                   clk,
    input  wire                   reset,

    VX_config_reg_if.slave        cfg_reg_if,
    VX_gemm_ctrl_if.master        gemm_ctrl_if,
    VX_node_done_if.master        done_if,
    VX_gemm_sync_if.slave         gemm_sync_slv_if[N_NODE],
    input  wire                   output_store_done_i,
    output wire                   progress_update_valid_o,
    output wire [`JOB_MMIO_ENTRYID_W-1:0] progress_update_entry_id_o,
    output wire [31:0]            progress_update_value_o
`ifdef PERF_ENABLE
    ,input  logic                 gemm_unit_computing
    ,output gemm_node_perf_t      perf
`endif
);

    localparam int NUM_SYNC_REGS = 11;
    localparam int CHILD_QUEUE_DATAW = $bits(gemm_unified_cmd_t);
    localparam int INFLIGHT_DATAW = $bits(gemm_notify_meta_t);

    VX_gemm_fsm_if gemm_fsm_if ();
    VX_gemm_fsm_if gemm_cqueue_out[N_CHILDREN] ();

    logic [N_CHILDREN-1:0] child_q_empty_v;
    logic [N_CHILDREN-1:0] child_q_full_v;
    logic [N_CHILDREN-1:0] child_q_push_v;
    logic [N_CHILDREN-1:0] child_q_pop_v;
    logic [N_CHILDREN-1:0] child_deps_ready_v;
    logic [N_CHILDREN-1:0] child_dependency_eligible_v;
    logic [N_CHILDREN-1:0] child_issue_fire_v;
    logic [N_CHILDREN-1:0] child_inflight_empty_v;
    logic [N_CHILDREN-1:0] child_inflight_full_v;
    logic [N_CHILDREN-1:0] child_inflight_can_accept_v;
    logic [N_CHILDREN-1:0] child_single_active_ready_v;
    logic [N_CHILDREN-1:0] child_completion_pop_v;
    gemm_unified_cmd_t child_q_cmd[N_CHILDREN];
    gemm_notify_meta_t child_inflight_head[N_CHILDREN];

    logic [31:0] sync_regs_q[NUM_SYNC_REGS];
    logic [31:0] effective_sync[NUM_SYNC_REGS];

    logic fsm_idle;
    logic fsm_pending_work;
    logic [2:0] fsm_pending_child;
    logic invocation_active_q;
    logic done_valid_q;
    logic [31:0] active_entry_id_q;
    logic [31:0] done_entry_id_q;
    logic [31:0] output_progress_q;

    wire scheduler_quiescent = (&child_q_empty_v)
                             && (&child_inflight_empty_v);
    wire new_invocation_ready = fsm_idle && scheduler_quiescent;
    wire cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;
    wire invocation_complete = invocation_active_q
                            && fsm_idle
                            && scheduler_quiescent;
    wire done_fire = done_if.valid && done_if.ready;

    // VX_gemm_fsm applies its own fsm_idle term to cfg_reg_if.ready, yielding
    // exactly: new_invocation_ready = fsm_idle && scheduler_quiescent.
    assign gemm_fsm_if.flag.done = scheduler_quiescent;
    assign gemm_fsm_if.flag.idle = 1'b1;
    assign gemm_fsm_if.flag.child_ready = ~child_q_full_v;

    VX_gemm_fsm #(
      .INSTANCE_ID (INSTANCE_ID)
    ) u_VX_gemm_fsm (
      .clk          (clk),
      .reset        (reset),
      .cfg_reg_if   (cfg_reg_if),
      .gemm_fsm_if  (gemm_fsm_if),
      .gemm_start_o (),
      .fsm_idle_o   (fsm_idle),
      .pending_work_o (fsm_pending_work),
      .pending_child_o (fsm_pending_child)
    );

    function automatic logic [2:0] command_child(
        input gemm_unified_cmd_t cmd
    );
      unique case (cmd.instr[3:0])
        4'd7: command_child = 3'd0;
        4'd5: command_child = 3'd1;
        4'd6: command_child = 3'd2;
        4'd8: command_child = 3'd3;
        4'd1,
        4'd2: command_child = 3'd4;
        default: command_child = 3'd7;
      endcase
    endfunction

    wire [2:0] fsm_target_child = command_child(gemm_fsm_if.ctrl.cmd);
    wire fsm_target_valid = (fsm_target_child < N_CHILDREN);

    always_comb begin
      child_q_push_v = '0;
      if (gemm_fsm_if.ctrl.start && fsm_target_valid)
        child_q_push_v[fsm_target_child] = 1'b1;
    end

    // Apply architectural completion updates before dependency comparison.
    // Pairwise collision assertions below make this reduction deterministic.
    always_comb begin
      for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
        effective_sync[rid] = sync_regs_q[rid];

      for (int child = 0; child < N_CHILDREN; ++child) begin
        if (child_completion_pop_v[child]
         && child_inflight_head[child].valid) begin
          if (child_inflight_head[child].set_mode) begin
            effective_sync[child_inflight_head[child].reg_id]
                = child_inflight_head[child].value;
          end else begin
            effective_sync[child_inflight_head[child].reg_id]
                = effective_sync[child_inflight_head[child].reg_id]
                + child_inflight_head[child].value;
          end
        end
      end
    end

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
          sync_regs_q[rid] <= 32'd0;
      end else begin
        for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
          sync_regs_q[rid] <= effective_sync[rid];
      end
    end

    generate
      for (genvar i = 0; i < N_CHILDREN; ++i) begin : g_child_scheduler
        wire [CHILD_QUEUE_DATAW-1:0] child_q_dout;
        wire [INFLIGHT_DATAW-1:0] inflight_dout;
        localparam int THIS_CHILD_QUEUE_DEPTH
            = (i == 4) ? DMA_CHILD_QUEUE_DEPTH : CHILD_QUEUE_DEPTH;
        logic deps_ready;

        assign child_q_cmd[i] = child_q_dout;
        assign child_inflight_head[i] = inflight_dout;
        assign child_completion_pop_v[i]
            = gemm_cqueue_out[i].flag.done
           && !child_inflight_empty_v[i];
        assign child_inflight_can_accept_v[i]
            = !child_inflight_full_v[i] || child_completion_pop_v[i];
        // Current executors accept at most one active command.  Keep the
        // 2-entry metadata FIFO as the in-order completion boundary, while
        // permitting only empty->push or same-cycle oldest pop/new push today.
        assign child_single_active_ready_v[i]
            = child_inflight_empty_v[i] || child_completion_pop_v[i];

        always_comb begin
          deps_ready = 1'b1;
          for (int dep = 0; dep < GEMM_MAX_WAIT_DEPS; ++dep) begin
            if (child_q_cmd[i].waits[dep].valid) begin
              deps_ready &= (child_q_cmd[i].waits[dep].reg_id
                             < NUM_SYNC_REGS)
                         && (effective_sync[
                               child_q_cmd[i].waits[dep].reg_id]
                             >= child_q_cmd[i].waits[dep].target);
            end
          end
        end

        assign child_deps_ready_v[i] = deps_ready;
        assign child_dependency_eligible_v[i]
            = !child_q_empty_v[i] && deps_ready;
        assign gemm_cqueue_out[i].ctrl.cmd = child_q_cmd[i];
        assign gemm_cqueue_out[i].ctrl.start
            = child_dependency_eligible_v[i]
           && child_inflight_can_accept_v[i]
           && child_single_active_ready_v[i]
           && gemm_cqueue_out[i].flag.idle;
        assign child_issue_fire_v[i] = gemm_cqueue_out[i].ctrl.start;
        assign child_q_pop_v[i] = child_issue_fire_v[i];

        VX_fifo_queue #(
          .DATAW (CHILD_QUEUE_DATAW),
          .DEPTH (THIS_CHILD_QUEUE_DEPTH)
        ) u_child_cmd_queue (
          .clk       (clk),
          .reset     (reset),
          .push      (child_q_push_v[i]),
          .pop       (child_q_pop_v[i]),
          .data_in   (gemm_fsm_if.ctrl.cmd),
          .data_out  (child_q_dout),
          .empty     (child_q_empty_v[i]),
          .full      (child_q_full_v[i]),
          .alm_empty (),
          .alm_full  (),
          .size      ()
        );

        VX_fifo_queue #(
          .DATAW (INFLIGHT_DATAW),
          .DEPTH (2)
        ) u_child_inflight_queue (
          .clk       (clk),
          .reset     (reset),
          .push      (child_issue_fire_v[i]),
          .pop       (child_completion_pop_v[i]),
          .data_in   (child_q_cmd[i].notify),
          .data_out  (inflight_dout),
          .empty     (child_inflight_empty_v[i]),
          .full      (child_inflight_full_v[i]),
          .alm_empty (),
          .alm_full  (),
          .size      ()
        );

`ifndef SYNTHESIS
        logic [31:0] dbg_child_empty_cycles_q;
        logic [31:0] dbg_child_fallthrough_opportunity_q;
        logic [31:0] dbg_child_full_block_cycles_q;

        wire incoming_deps_ready = (gemm_fsm_if.ctrl.cmd.waits[0].valid
              ? (effective_sync[gemm_fsm_if.ctrl.cmd.waits[0].reg_id]
                 >= gemm_fsm_if.ctrl.cmd.waits[0].target) : 1'b1)
          && (gemm_fsm_if.ctrl.cmd.waits[1].valid
              ? (effective_sync[gemm_fsm_if.ctrl.cmd.waits[1].reg_id]
                 >= gemm_fsm_if.ctrl.cmd.waits[1].target) : 1'b1)
          && (gemm_fsm_if.ctrl.cmd.waits[2].valid
              ? (effective_sync[gemm_fsm_if.ctrl.cmd.waits[2].reg_id]
                 >= gemm_fsm_if.ctrl.cmd.waits[2].target) : 1'b1)
          && (gemm_fsm_if.ctrl.cmd.waits[3].valid
              ? (effective_sync[gemm_fsm_if.ctrl.cmd.waits[3].reg_id]
                 >= gemm_fsm_if.ctrl.cmd.waits[3].target) : 1'b1);

        always_ff @(posedge clk) begin
          if (reset || cfg_fire) begin
            dbg_child_empty_cycles_q <= '0;
            dbg_child_fallthrough_opportunity_q <= '0;
            dbg_child_full_block_cycles_q <= '0;
          end else if (invocation_active_q) begin
            if (child_q_empty_v[i])
              dbg_child_empty_cycles_q <= dbg_child_empty_cycles_q + 1;
            if (child_q_empty_v[i]
             && child_q_push_v[i]
             && incoming_deps_ready
             && child_inflight_can_accept_v[i]
             && gemm_cqueue_out[i].flag.idle)
              dbg_child_fallthrough_opportunity_q
                  <= dbg_child_fallthrough_opportunity_q + 1;
            if (fsm_pending_work
             && child_q_full_v[i]
             && (fsm_pending_child == i))
              dbg_child_full_block_cycles_q
                  <= dbg_child_full_block_cycles_q + 1;
          end
        end

        always_ff @(posedge clk) begin
          if (!reset) begin
            assert (!(gemm_cqueue_out[i].flag.done
                   && child_inflight_empty_v[i]))
              else $fatal(1, "%s: stray completion from child %0d",
                          INSTANCE_ID, i);
            assert (!(child_issue_fire_v[i]
                   && child_inflight_full_v[i]
                   && !child_completion_pop_v[i]))
              else $fatal(1, "%s: inflight overflow for child %0d",
                          INSTANCE_ID, i);
            assert (!(!child_deps_ready_v[i]
                   && gemm_cqueue_out[i].ctrl.start))
              else $fatal(1, "%s: unresolved child %0d dependency issued",
                          INSTANCE_ID, i);
            assert (child_q_pop_v[i] == child_issue_fire_v[i])
              else $fatal(1, "%s: child %0d pop/start mismatch",
                          INSTANCE_ID, i);
            assert (!(child_issue_fire_v[i]
                   && !child_inflight_empty_v[i]
                   && !child_completion_pop_v[i]))
              else $fatal(1, "%s: child %0d accepted multiple active commands",
                          INSTANCE_ID, i);
          end
        end
`endif
      end
    endgenerate

    // Child-to-executor mapping. Executor done signals are architectural
    // completion events and retire the oldest metadata entry for that child.
    assign gemm_ctrl_if.input_read_ctrl.cmd = gemm_cqueue_out[0].ctrl.cmd;
    assign gemm_ctrl_if.input_read_ctrl.start = gemm_cqueue_out[0].ctrl.start;
    assign gemm_cqueue_out[0].flag.idle = gemm_ctrl_if.input_read_flag.idle;
    assign gemm_cqueue_out[0].flag.done = gemm_ctrl_if.input_read_flag.done;

    assign gemm_ctrl_if.weight_read_ctrl.cmd = gemm_cqueue_out[1].ctrl.cmd;
    assign gemm_ctrl_if.weight_read_ctrl.start = gemm_cqueue_out[1].ctrl.start;
    assign gemm_cqueue_out[1].flag.idle = gemm_ctrl_if.weight_read_flag.idle;
    assign gemm_cqueue_out[1].flag.done = gemm_ctrl_if.weight_read_flag.done;

    assign gemm_ctrl_if.quant_param_read_ctrl.cmd = gemm_cqueue_out[2].ctrl.cmd;
    assign gemm_ctrl_if.quant_param_read_ctrl.start = gemm_cqueue_out[2].ctrl.start;
    assign gemm_cqueue_out[2].flag.idle = gemm_ctrl_if.quant_param_read_flag.idle;
    assign gemm_cqueue_out[2].flag.done = gemm_ctrl_if.quant_param_read_flag.done;

    assign gemm_ctrl_if.output_write_ctrl.cmd = gemm_cqueue_out[3].ctrl.cmd;
    assign gemm_ctrl_if.output_write_ctrl.start = gemm_cqueue_out[3].ctrl.start;
    assign gemm_cqueue_out[3].flag.idle = gemm_ctrl_if.output_write_flag.idle;
    assign gemm_cqueue_out[3].flag.done = gemm_ctrl_if.output_write_flag.done;

    assign gemm_ctrl_if.dma_ctrl.cmd = gemm_cqueue_out[4].ctrl.cmd;
    assign gemm_ctrl_if.dma_ctrl.start = gemm_cqueue_out[4].ctrl.start;
    assign gemm_cqueue_out[4].flag.idle = gemm_ctrl_if.dma_flag.idle;
    assign gemm_cqueue_out[4].flag.done = gemm_ctrl_if.dma_flag.done;

    for (genvar n = 0; n < N_NODE; ++n) begin : g_unused_legacy_sync
      assign gemm_sync_slv_if[n].ready = 1'b1;
    end

    always_ff @(posedge clk) begin
      if (reset) begin
        invocation_active_q <= 1'b0;
        done_valid_q <= 1'b0;
        active_entry_id_q <= '0;
        done_entry_id_q <= '0;
        output_progress_q <= '0;
      end else begin
        if (cfg_fire) begin
          invocation_active_q <= 1'b1;
          active_entry_id_q <= cfg_reg_if.entry_id;
          output_progress_q <= '0;
        end else if (output_store_done_i) begin
          output_progress_q <= output_progress_q + 32'd1;
        end

        if (invocation_complete) begin
          done_valid_q <= 1'b1;
          done_entry_id_q <= active_entry_id_q;
        end else if (done_fire) begin
          done_valid_q <= 1'b0;
        end

        if (!cfg_fire && invocation_complete)
          invocation_active_q <= 1'b0;
      end
    end

    assign done_if.valid = done_valid_q;
    assign done_if.entry_id = done_entry_id_q;
    assign progress_update_valid_o = output_store_done_i;
    assign progress_update_entry_id_o
        = active_entry_id_q[`JOB_MMIO_ENTRYID_W-1:0];
    assign progress_update_value_o = output_progress_q + 32'd1;

`ifndef SYNTHESIS
    logic [31:0] dbg_invocation_active_cycles_q;
    logic [31:0] dbg_fifo_full_blocks_ready_other_child_q;

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        dbg_invocation_active_cycles_q <= '0;
        dbg_fifo_full_blocks_ready_other_child_q <= '0;
      end else if (invocation_active_q) begin
        dbg_invocation_active_cycles_q
            <= dbg_invocation_active_cycles_q + 1;
        if (fsm_pending_work
         && child_q_full_v[fsm_pending_child]
         && (|(child_q_empty_v & ~child_q_full_v))) begin
          dbg_fifo_full_blocks_ready_other_child_q
              <= dbg_fifo_full_blocks_ready_other_child_q + 1;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!reset) begin
        assert (!(cfg_fire && !scheduler_quiescent))
          else $fatal(1, "%s: config accepted before scheduler quiescence",
                      INSTANCE_ID);
        assert (cfg_reg_if.ready == new_invocation_ready)
          else $fatal(1, "%s: new invocation readiness is not strict quiescence",
                      INSTANCE_ID);
        assert (!(invocation_complete && done_valid_q && !done_fire))
          else $fatal(1, "%s: invocation completion overwrote pending done",
                      INSTANCE_ID);
        assert (!(cfg_fire && (|child_completion_pop_v)))
          else $fatal(1, "%s: implicit clear overlapped completion",
                      INSTANCE_ID);
        assert (!(gemm_fsm_if.ctrl.start && !fsm_target_valid))
          else $fatal(1, "%s: FSM emitted removed or invalid opcode 0x%0h",
                      INSTANCE_ID, gemm_fsm_if.ctrl.cmd.instr[3:0]);

        for (int lhs = 0; lhs < N_CHILDREN; ++lhs) begin
          for (int rhs = lhs + 1; rhs < N_CHILDREN; ++rhs) begin
            assert (!(child_completion_pop_v[lhs]
                   && child_completion_pop_v[rhs]
                   && child_inflight_head[lhs].valid
                   && child_inflight_head[rhs].valid
                   && (child_inflight_head[lhs].reg_id
                       == child_inflight_head[rhs].reg_id)))
              else $fatal(1, "%s: simultaneous sync collision children %0d/%0d rid=%0d",
                          INSTANCE_ID, lhs, rhs,
                          child_inflight_head[lhs].reg_id);
          end
        end
      end
    end
`endif

`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_total_cycles_r;
    always_ff @(posedge clk) begin
      if (reset)
        perf_total_cycles_r <= '0;
      else if (invocation_active_q || gemm_unit_computing)
        perf_total_cycles_r <= perf_total_cycles_r + PERF_CTR_BITS'(1);
    end
    assign perf.total_cycles  = perf_total_cycles_r;
    assign perf.lmem_rd_bytes = '0;
    assign perf.lmem_wr_bytes = '0;
`endif

    `VX_STATIC_ASSERT(N_CHILDREN == 5,
      ("VX_gemm_ctrl command schedule requires five children"));
    `VX_STATIC_ASSERT(N_NODE == 5,
      ("VX_gemm_ctrl command schedule requires five completion sources"));
    `VX_STATIC_ASSERT(CHILD_QUEUE_DEPTH >= 2,
      ("VX_gemm_ctrl child queue depth must be at least two"));
    `VX_STATIC_ASSERT(DMA_CHILD_QUEUE_DEPTH >= CHILD_QUEUE_DEPTH,
      ("VX_gemm_ctrl DMA child queue must not be shallower than peers"));

endmodule

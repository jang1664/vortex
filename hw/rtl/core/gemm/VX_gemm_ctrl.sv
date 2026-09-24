`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_CHILDREN = 6,
    parameter int N_NODE     = 6,
    parameter int CHILD_QUEUE_DEPTH = 4,
    parameter int DMA_CHILD_QUEUE_DEPTH = 8,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        `GEMM_DMA_STORE_MAX_CHUNK_BEATS
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
    output wire [31:0]            progress_update_value_o,
    // Same-cycle architectural Weight-consume levels.  Each Weight executor
    // FIFO entry compares its own writer_wait RID/target against these levels;
    // they are not untagged head-release pulses.
    output wire [31:0]            weight_consume_value0_o,
    output wire [31:0]            weight_consume_value1_o,
    // Qparam consumers directly read their register on the consumer edge, so
    // their same-cycle effective levels permit the next exact generation to
    // overwrite on that edge after the old value has been captured.
    output wire [31:0]            scale_consume_value0_o,
    output wire [31:0]            scale_consume_value1_o,
    output wire [31:0]            zero_point_consume_value0_o,
    output wire [31:0]            zero_point_consume_value1_o,
    input wire [3:0]              sched_source_valid_i,
    input wire [31:0]             sched_source_work_seq_i [4],
    input wire [31:0]             sched_source_total_beats_i [4],
    input wire [31:0]             sched_source_request_beats_i [4],
    input wire [31:0]             sched_source_response_beats_i [4],
    input wire [31:0]             sched_source_writer_beats_i [4],
    input wire [3:0]              sched_input_slot_occupancy_i,
    input wire                    sched_input_ahead_credit_i,
    input wire                    sched_input_admit_valid_i,
    input wire [31:0]             sched_input_admit_work_seq_i,
    input wire [3:0]              sched_fetch_complete_i,
    input wire [31:0]             sched_fetch_complete_work_seq_i [4],
    input wire                    consumer_block_valid_i,
    input wire [1:0]              consumer_block_resource_i,
    input wire [31:0]             consumer_block_work_seq_i,
    input wire                    consumer_block_bank_i,
    input wire [31:0]             consumer_block_target_i,
    output wire [GEMM_SCHED_PRIORITY_WIDTH-1:0]
                                   sched_source_priority_o [4],
    output wire                    sched_input_source_enable_o
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
    ,input wire                   dbg_compute_active_i
`endif
`endif
`ifdef PERF_ENABLE
    ,input  logic                 gemm_unit_computing
    ,output gemm_node_perf_t      perf
`endif
);

    localparam int NUM_SYNC_REGS = GEMM_NUM_SYNC_REGS;
    localparam int RID_T0 = GEMM_RID_T0;
    localparam int RID_W0 = GEMM_RID_W0;
    localparam int RID_SZ0 = GEMM_RID_SZ0;
    localparam int RID_G0 = GEMM_RID_G0;
    localparam int RID_O = GEMM_RID_O;
    localparam int RID_T1 = GEMM_RID_T1;
    localparam int RID_W1 = GEMM_RID_W1;
    localparam int RID_SZ1 = GEMM_RID_SZ1;
    localparam int RID_G1 = GEMM_RID_G1;
    localparam int RID_ACC_FREE0 = GEMM_RID_ACC_FREE0;
    localparam int RID_ACC_FREE1 = GEMM_RID_ACC_FREE1;
    localparam int RID_SC0 = GEMM_RID_SC0;
    localparam int RID_ZP0 = GEMM_RID_ZP0;
    localparam int RID_SC1 = GEMM_RID_SC1;
    localparam int RID_ZP1 = GEMM_RID_ZP1;
    localparam int RID_W_CONSUME0 = GEMM_RID_W_CONSUME0;
    localparam int RID_W_CONSUME1 = GEMM_RID_W_CONSUME1;
    localparam int RID_SC_CONSUME0 = GEMM_RID_SC_CONSUME0;
    localparam int RID_SC_CONSUME1 = GEMM_RID_SC_CONSUME1;
    localparam int RID_ZP_CONSUME0 = GEMM_RID_ZP_CONSUME0;
    localparam int RID_ZP_CONSUME1 = GEMM_RID_ZP_CONSUME1;
    localparam int WEIGHT_CHILD_INDEX = 1;
    localparam int SCALE_CHILD_INDEX = 2;
    localparam int ZP_CHILD_INDEX = 3;
    localparam int OUTPUT_CHILD_INDEX = 4;
    localparam int DMA_CHILD_INDEX = 5;
    localparam int DMA_INFLIGHT_DEPTH = 1 << GEMM_DMA_TAG_WIDTH;
    localparam int CHILD_QUEUE_DATAW = $bits(gemm_unified_cmd_t);
    typedef struct packed {
      logic valid;
      logic [GEMM_SYNC_REG_ID_WIDTH-1:0] reg_id;
      logic set_mode;
      logic [31:0] value;
      logic [31:0] work_seq;
    } child_inflight_meta_t;
    localparam int INFLIGHT_DATAW = $bits(child_inflight_meta_t);

    VX_gemm_fsm_if gemm_fsm_if ();
    VX_gemm_fsm_if gemm_cqueue_out[N_CHILDREN] ();

    logic [N_CHILDREN-1:0] child_q_empty_v;
    logic [N_CHILDREN-1:0] child_q_full_v;
    logic [N_CHILDREN-1:0] child_q_push_v;
    logic [N_CHILDREN-1:0] child_q_pop_v;
    logic [N_CHILDREN-1:0] child_deps_ready_v;
    logic [N_CHILDREN-1:0] child_prepare_deps_ready_v;
    logic [N_CHILDREN-1:0] child_prepare_eligible_v;
    logic [N_CHILDREN-1:0] child_prepare_valid_v;
    logic [N_CHILDREN-1:0] child_prepare_ready_v;
    logic [N_CHILDREN-1:0] child_prepare_fire_v;
    logic [N_CHILDREN-1:0] child_prepare_sent_q;
    logic [N_CHILDREN-1:0] child_dependency_eligible_v;
    logic [N_CHILDREN-1:0] child_issue_fire_v;
    logic [N_CHILDREN-1:0] child_inflight_empty_v;
    logic [N_CHILDREN-1:0] child_inflight_full_v;
    logic [N_CHILDREN-1:0] child_inflight_can_accept_v;
    logic [N_CHILDREN-1:0] child_single_active_ready_v;
    logic [N_CHILDREN-1:0] child_completion_pop_v;
    gemm_unified_cmd_t child_q_cmd[N_CHILDREN];
    child_inflight_meta_t child_inflight_head[N_CHILDREN];

    logic [DMA_INFLIGHT_DEPTH-1:0] dma_inflight_valid_q;
    child_inflight_meta_t dma_inflight_meta_q[DMA_INFLIGHT_DEPTH];
    logic dma_issue_tag_reserved_q;
    logic [GEMM_DMA_TAG_WIDTH-1:0] dma_issue_tag_q;
    logic dma_free_tag_valid;
    logic [GEMM_DMA_TAG_WIDTH-1:0] dma_free_tag;
    logic [GEMM_DMA_TAG_WIDTH-1:0] dma_issue_tag;
    logic dma_prepare_valid_q;
    gemm_unified_cmd_t dma_prepare_cmd_q;

    logic [31:0] sync_regs_q[NUM_SYNC_REGS];
    logic [31:0] effective_sync[NUM_SYNC_REGS];

    logic cmd_stage_valid_q;
    logic [2:0] cmd_stage_child_q;
    gemm_unified_cmd_t cmd_stage_cmd_q;
    logic cmd_stage_drain;
    logic cmd_stage_ready;

    logic fsm_idle;
    logic fsm_pending_work;
    logic [2:0] fsm_pending_child;
    logic fsm_pending_scheduler_work;
    logic [31:0] fsm_pending_work_seq;
    logic scheduler_probe_ready;
    logic [GEMM_SCHED_PRIORITY_WIDTH-1:0]
        scheduler_source_priority[4];
    gemm_wait_meta_t scheduler_input_waits[4];
    logic scheduler_input_source_enable;
    logic [$clog2(4+1)-1:0] scheduler_entry_count;
    logic invocation_active_q;
    logic done_valid_q;
    logic [31:0] active_entry_id_q;
    logic [31:0] done_entry_id_q;
    logic [31:0] output_progress_q;

    for (genvar sched_wait = 0; sched_wait < 4; ++sched_wait) begin : g_sched_input_waits
      assign scheduler_input_waits[sched_wait]
          = cmd_stage_cmd_q.input_admit_waits[sched_wait];
    end

`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
    logic        dbg_fsm_meta_valid;
    logic [7:0]  dbg_fsm_meta_state;
    logic [3:0]  dbg_fsm_meta_phase;
    logic [31:0] dbg_fsm_meta_tile;
    logic [31:0] dbg_fsm_meta_nt;
    logic [31:0] dbg_fsm_meta_mt;
    logic [31:0] dbg_fsm_meta_kt;
    logic [31:0] dbg_fsm_meta_mxu_nt;
    logic [31:0] dbg_fsm_meta_mxu_kt;
    logic        dbg_fsm_meta_tile_buf;
    logic        dbg_fsm_meta_mxu_buf;
    logic        dbg_fsm_meta_acc_group;
    logic [31:0] dbg_fsm_meta_generation;
`endif
`endif

    wire scheduler_quiescent = !cmd_stage_valid_q
                             && (&child_q_empty_v)
                             && (&child_inflight_empty_v);
    wire new_invocation_ready = fsm_idle && scheduler_quiescent;
    wire cfg_fire = cfg_reg_if.valid && cfg_reg_if.ready;
    wire invocation_complete = invocation_active_q
                            && fsm_idle
                            && scheduler_quiescent;
    wire done_fire = done_if.valid && done_if.ready;

    function automatic int rid_w_consume_for_idx(
        input gemm_wreg_idx_t idx
    );
      return idx ? RID_W_CONSUME1 : RID_W_CONSUME0;
    endfunction

    always_comb begin
      dma_free_tag_valid = 1'b0;
      dma_free_tag = '0;
      for (int slot = 0; slot < DMA_INFLIGHT_DEPTH; ++slot) begin
        if (!dma_free_tag_valid && !dma_inflight_valid_q[slot]) begin
          dma_free_tag_valid = 1'b1;
          dma_free_tag = GEMM_DMA_TAG_WIDTH'(slot);
        end
      end
    end

    assign dma_issue_tag = dma_issue_tag_reserved_q
                         ? dma_issue_tag_q : dma_free_tag;

    // VX_gemm_fsm applies its own fsm_idle term to cfg_reg_if.ready, yielding
    // exactly: new_invocation_ready = fsm_idle && scheduler_quiescent.
    assign gemm_fsm_if.flag.done = scheduler_quiescent;
    assign gemm_fsm_if.flag.idle = 1'b1;
    // The FSM only sees the elastic-stage acceptance condition.  Queue and
    // readiness-scoreboard backpressure act on the registered stage output,
    // keeping them out of the wide command-payload construction cone.
    assign gemm_fsm_if.flag.child_ready = {6{cmd_stage_ready}};
    assign sched_source_priority_o = scheduler_source_priority;
    assign sched_input_source_enable_o = scheduler_input_source_enable;

    VX_gemm_fsm #(
      .INSTANCE_ID (INSTANCE_ID),
      .DMA_STORE_MAX_CHUNK_BEATS (DMA_STORE_MAX_CHUNK_BEATS)
    ) u_VX_gemm_fsm (
      .clk          (clk),
      .reset        (reset),
      .completed_output_store_count_i (effective_sync[RID_O]),
      .cfg_reg_if   (cfg_reg_if),
      .gemm_fsm_if  (gemm_fsm_if),
      .gemm_start_o (),
      .fsm_idle_o   (fsm_idle),
      .pending_work_o (fsm_pending_work),
      .pending_child_o (fsm_pending_child),
      .pending_scheduler_work_o(fsm_pending_scheduler_work),
      .pending_work_seq_o(fsm_pending_work_seq)
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      ,.dbg_cmd_meta_valid_o (dbg_fsm_meta_valid)
      ,.dbg_cmd_meta_state_o (dbg_fsm_meta_state)
      ,.dbg_cmd_meta_phase_o (dbg_fsm_meta_phase)
      ,.dbg_cmd_meta_tile_o (dbg_fsm_meta_tile)
      ,.dbg_cmd_meta_nt_o (dbg_fsm_meta_nt)
      ,.dbg_cmd_meta_mt_o (dbg_fsm_meta_mt)
      ,.dbg_cmd_meta_kt_o (dbg_fsm_meta_kt)
      ,.dbg_cmd_meta_mxu_nt_o (dbg_fsm_meta_mxu_nt)
      ,.dbg_cmd_meta_mxu_kt_o (dbg_fsm_meta_mxu_kt)
      ,.dbg_cmd_meta_tile_buf_o (dbg_fsm_meta_tile_buf)
      ,.dbg_cmd_meta_mxu_buf_o (dbg_fsm_meta_mxu_buf)
      ,.dbg_cmd_meta_acc_group_o (dbg_fsm_meta_acc_group)
      ,.dbg_cmd_meta_generation_o (dbg_fsm_meta_generation)
`endif
`endif
    );

    function automatic logic [2:0] command_child(
        input gemm_unified_cmd_t cmd
    );
      unique case (cmd.instr[3:0])
        4'd7: command_child = 3'd0;
        4'd5: command_child = 3'd1;
        GEMM_OP_SC_LDMA_MXU: command_child = 3'd2;
        GEMM_OP_ZP_LDMA_MXU: command_child = 3'd3;
        4'd8: command_child = 3'd4;
        4'd1,
        4'd2: command_child = 3'd5;
        default: command_child = 3'd7;
      endcase
    endfunction

    wire [2:0] fsm_target_child = fsm_pending_child;
    wire fsm_target_valid = (fsm_target_child < N_CHILDREN);
    wire [2:0] fsm_decoded_child = command_child(gemm_fsm_if.ctrl.cmd);
    wire fsm_cmd_accept = gemm_fsm_if.ctrl.start && cmd_stage_ready;
    wire cmd_stage_target_valid = (cmd_stage_child_q < N_CHILDREN);
    wire scheduler_cmd_valid = cmd_stage_valid_q
        && cmd_stage_target_valid
        && (cmd_stage_child_q <= ZP_CHILD_INDEX);
    wire scheduler_cmd_fire = cmd_stage_drain && scheduler_cmd_valid;
    logic [1:0] scheduler_cmd_resource;
    logic scheduler_cmd_bank;

    always_comb begin
      scheduler_cmd_resource = GEMM_SCHED_RESOURCE_INPUT;
      scheduler_cmd_bank = 1'b0;
      unique case (cmd_stage_child_q)
        3'd0: begin
          scheduler_cmd_resource = GEMM_SCHED_RESOURCE_INPUT;
          scheduler_cmd_bank = cmd_stage_cmd_q.flags[2];
        end
        WEIGHT_CHILD_INDEX: begin
          scheduler_cmd_resource = GEMM_SCHED_RESOURCE_WEIGHT;
          scheduler_cmd_bank = cmd_stage_cmd_q.flags[0];
        end
        SCALE_CHILD_INDEX: begin
          scheduler_cmd_resource = GEMM_SCHED_RESOURCE_SCALE;
          scheduler_cmd_bank = cmd_stage_cmd_q.flags[1];
        end
        default: begin
          scheduler_cmd_resource = GEMM_SCHED_RESOURCE_ZP;
          scheduler_cmd_bank = cmd_stage_cmd_q.flags[1];
        end
      endcase
    end

    // Drain and refill may happen on the same edge.  The target child is
    // captured beside the payload so neither child selection nor scoreboard
    // admission can drift while downstream backpressure holds the stage.
    always_comb begin
      cmd_stage_drain = 1'b0;
      if (cmd_stage_valid_q && cmd_stage_target_valid) begin
        cmd_stage_drain = !child_q_full_v[cmd_stage_child_q]
                       && (!scheduler_cmd_valid || scheduler_probe_ready);
      end
      cmd_stage_ready = !cmd_stage_valid_q || cmd_stage_drain;
    end

    always_ff @(posedge clk) begin
      if (reset) begin
        cmd_stage_valid_q <= 1'b0;
        cmd_stage_child_q <= '0;
        cmd_stage_cmd_q <= '0;
      end else if (cmd_stage_ready) begin
        cmd_stage_valid_q <= gemm_fsm_if.ctrl.start;
        if (gemm_fsm_if.ctrl.start) begin
          cmd_stage_child_q <= fsm_target_child;
          cmd_stage_cmd_q <= gemm_fsm_if.ctrl.cmd;
        end
      end
    end

    VX_microtile_readiness_scheduler #(
      .INSTANCE_ID({INSTANCE_ID, ":readiness"}),
      .DEPTH(4),
      .INPUT_SLOTS(8)
    ) u_microtile_readiness_scheduler (
      .clk(clk),
      .reset(reset || cfg_fire),
      .probe_valid_i(scheduler_cmd_valid),
      .probe_work_seq_i(cmd_stage_cmd_q.work_seq),
      .probe_ready_o(scheduler_probe_ready),
      .cmd_fire_i(scheduler_cmd_fire),
      .cmd_resource_i(scheduler_cmd_resource),
      .cmd_work_seq_i(cmd_stage_cmd_q.work_seq),
      .cmd_bank_i(scheduler_cmd_bank),
      .cmd_target_i(cmd_stage_cmd_q.notify.value),
      .cmd_writer_wait_i(cmd_stage_cmd_q.writer_wait),
      .input_waits_i(scheduler_input_waits),
      .retire_valid_i(child_completion_pop_v[0]),
      .retire_work_seq_i(child_inflight_head[0].work_seq),
      .fetch_complete_valid_i(sched_fetch_complete_i),
      .fetch_complete_work_seq_i(sched_fetch_complete_work_seq_i),
      .block_valid_i(consumer_block_valid_i),
      .block_resource_i(consumer_block_resource_i),
      .block_work_seq_i(consumer_block_work_seq_i),
      .block_bank_i(consumer_block_bank_i),
      .block_target_i(consumer_block_target_i),
      .source_valid_i(sched_source_valid_i),
      .source_work_seq_i(sched_source_work_seq_i),
      .source_total_beats_i(sched_source_total_beats_i),
      .source_request_beats_i(sched_source_request_beats_i),
      .source_response_beats_i(sched_source_response_beats_i),
      .source_writer_beats_i(sched_source_writer_beats_i),
      .input_slot_occupancy_i(sched_input_slot_occupancy_i),
      .input_ahead_credit_i(sched_input_ahead_credit_i),
      .input_admit_valid_i(sched_input_admit_valid_i),
      .input_admit_work_seq_i(sched_input_admit_work_seq_i),
      .w_load_value_i(gemm_ctrl_if.input_w_load_value),
      .s_load_value_i(gemm_ctrl_if.input_sc_load_value),
      .z_load_value_i(gemm_ctrl_if.input_zp_load_value),
      .acc_free_value_i(gemm_ctrl_if.input_acc_free_value),
      .source_priority_o(scheduler_source_priority),
      .input_source_enable_o(scheduler_input_source_enable),
      .entry_count_o(scheduler_entry_count)
    );

    always_comb begin
      child_q_push_v = '0;
      if (cmd_stage_drain)
        child_q_push_v[cmd_stage_child_q] = 1'b1;
    end

    // Each completion source has a fixed architectural owner.  Build every
    // next value independently so simultaneous completions on different RIDs
    // remain parallel and cannot form a dynamic-index write chain.
    wire child0_done = child_completion_pop_v[0]
                    && child_inflight_head[0].valid;
    wire child1_done = child_completion_pop_v[1]
                    && child_inflight_head[1].valid;
    wire child2_done = child_completion_pop_v[2]
                    && child_inflight_head[2].valid;
    wire child3_done = child_completion_pop_v[3]
                    && child_inflight_head[3].valid;
    wire child4_done = child_completion_pop_v[4]
                    && child_inflight_head[4].valid;
    wire child5_done = child_completion_pop_v[5]
                    && child_inflight_head[5].valid;

    wire child0_g0 = child0_done
                  && (child_inflight_head[0].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_G0));
    wire child0_g1 = child0_done
                  && (child_inflight_head[0].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_G1));
    wire child1_w0 = child1_done
                  && (child_inflight_head[1].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_W0));
    wire child1_w1 = child1_done
                  && (child_inflight_head[1].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_W1));
    wire child2_sc0 = child2_done
                   && (child_inflight_head[2].reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(RID_SC0));
    wire child2_sc1 = child2_done
                   && (child_inflight_head[2].reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(RID_SC1));
    wire child3_zp0 = child3_done
                   && (child_inflight_head[3].reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP0));
    wire child3_zp1 = child3_done
                   && (child_inflight_head[3].reg_id
                       == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP1));
    wire child4_acc_free0 = child4_done
                         && (child_inflight_head[4].reg_id
                             == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE0));
    wire child4_acc_free1 = child4_done
                         && (child_inflight_head[4].reg_id
                             == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE1));
    wire child5_t0 = child5_done
                  && (child_inflight_head[5].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_T0));
    wire child5_t1 = child5_done
                  && (child_inflight_head[5].reg_id
                      == GEMM_SYNC_REG_ID_WIDTH'(RID_T1));
    wire child5_o = child5_done
                 && (child_inflight_head[5].reg_id
                     == GEMM_SYNC_REG_ID_WIDTH'(RID_O));

`ifndef SYNTHESIS
    wire child0_update_legal = !child0_done
        || ((child0_g0 || child0_g1)
         && !child_inflight_head[0].set_mode
         && (child_inflight_head[0].value == 32'd1));
    wire child1_update_legal = !child1_done
        || ((child1_w0 || child1_w1)
         && child_inflight_head[1].set_mode);
    wire child2_update_legal = !child2_done
        || ((child2_sc0 || child2_sc1)
         && child_inflight_head[2].set_mode);
    wire child3_update_legal = !child3_done
        || ((child3_zp0 || child3_zp1)
         && child_inflight_head[3].set_mode);
    wire child4_update_legal = !child4_done
        || ((child4_acc_free0 || child4_acc_free1)
         && child_inflight_head[4].set_mode);
    wire child5_update_legal = !child5_done
        || (((child5_t0 || child5_t1)
          && child_inflight_head[5].set_mode)
         || (child5_o
          && !child_inflight_head[5].set_mode
          && (child_inflight_head[5].value == 32'd1)));
`endif

    wire node1_w_consume0 = gemm_sync_slv_if[1].valid
                         && (gemm_sync_slv_if[1].reg_idx
                             == GEMM_SYNC_REG_ID_WIDTH'(RID_W_CONSUME0));
    wire node1_w_consume1 = gemm_sync_slv_if[1].valid
                         && (gemm_sync_slv_if[1].reg_idx
                             == GEMM_SYNC_REG_ID_WIDTH'(RID_W_CONSUME1));
    wire node2_sc_consume0 = gemm_sync_slv_if[2].valid
                          && (gemm_sync_slv_if[2].reg_idx
                              == GEMM_SYNC_REG_ID_WIDTH'(RID_SC_CONSUME0));
    wire node2_sc_consume1 = gemm_sync_slv_if[2].valid
                          && (gemm_sync_slv_if[2].reg_idx
                              == GEMM_SYNC_REG_ID_WIDTH'(RID_SC_CONSUME1));
    wire node3_zp_consume0 = gemm_sync_slv_if[3].valid
                          && (gemm_sync_slv_if[3].reg_idx
                              == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP_CONSUME0));
    wire node3_zp_consume1 = gemm_sync_slv_if[3].valid
                          && (gemm_sync_slv_if[3].reg_idx
                              == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP_CONSUME1));
`ifndef SYNTHESIS
    wire external_updates_legal
        = (!gemm_sync_slv_if[1].valid
        || ((node1_w_consume0 || node1_w_consume1)
         && (gemm_sync_slv_if[1].value == 32'd1)))
       && (!gemm_sync_slv_if[2].valid
        || ((node2_sc_consume0 || node2_sc_consume1)
         && (gemm_sync_slv_if[2].value == 32'd1)))
       && (!gemm_sync_slv_if[3].valid
        || ((node3_zp_consume0 || node3_zp_consume1)
         && (gemm_sync_slv_if[3].value == 32'd1)));
    wire sync_update_contract_legal = child0_update_legal
                                   && child1_update_legal
                                   && child2_update_legal
                                   && child3_update_legal
                                   && child4_update_legal
                                   && child5_update_legal
                                   && external_updates_legal;
`endif

    wire [31:0] sync_t0_next = child5_t0
        ? child_inflight_head[5].value : sync_regs_q[RID_T0];
    wire [31:0] sync_w0_next = child1_w0
        ? child_inflight_head[1].value : sync_regs_q[RID_W0];
    wire [31:0] sync_g0_next = sync_regs_q[RID_G0]
        + (child0_g0 ? child_inflight_head[0].value : 32'd0);
    wire [31:0] sync_o_next = sync_regs_q[RID_O]
        + (child5_o ? child_inflight_head[5].value : 32'd0);
    wire [31:0] sync_t1_next = child5_t1
        ? child_inflight_head[5].value : sync_regs_q[RID_T1];
    wire [31:0] sync_w1_next = child1_w1
        ? child_inflight_head[1].value : sync_regs_q[RID_W1];
    wire [31:0] sync_g1_next = sync_regs_q[RID_G1]
        + (child0_g1 ? child_inflight_head[0].value : 32'd0);
    wire [31:0] sync_acc_free0_next = child4_acc_free0
        ? child_inflight_head[4].value : sync_regs_q[RID_ACC_FREE0];
    wire [31:0] sync_acc_free1_next = child4_acc_free1
        ? child_inflight_head[4].value : sync_regs_q[RID_ACC_FREE1];
    wire [31:0] sync_sc0_next = child2_sc0
        ? child_inflight_head[2].value : sync_regs_q[RID_SC0];
    wire [31:0] sync_zp0_next = child3_zp0
        ? child_inflight_head[3].value : sync_regs_q[RID_ZP0];
    wire [31:0] sync_sc1_next = child2_sc1
        ? child_inflight_head[2].value : sync_regs_q[RID_SC1];
    wire [31:0] sync_zp1_next = child3_zp1
        ? child_inflight_head[3].value : sync_regs_q[RID_ZP1];
    wire [31:0] sync_sz0_next = (sync_sc0_next < sync_zp0_next)
        ? sync_sc0_next : sync_zp0_next;
    wire [31:0] sync_sz1_next = (sync_sc1_next < sync_zp1_next)
        ? sync_sc1_next : sync_zp1_next;
    wire [31:0] sync_w_consume0_next = sync_regs_q[RID_W_CONSUME0]
        + (node1_w_consume0 ? gemm_sync_slv_if[1].value : 32'd0);
    wire [31:0] sync_w_consume1_next = sync_regs_q[RID_W_CONSUME1]
        + (node1_w_consume1 ? gemm_sync_slv_if[1].value : 32'd0);
    wire [31:0] sync_sc_consume0_next = sync_regs_q[RID_SC_CONSUME0]
        + (node2_sc_consume0 ? gemm_sync_slv_if[2].value : 32'd0);
    wire [31:0] sync_sc_consume1_next = sync_regs_q[RID_SC_CONSUME1]
        + (node2_sc_consume1 ? gemm_sync_slv_if[2].value : 32'd0);
    wire [31:0] sync_zp_consume0_next = sync_regs_q[RID_ZP_CONSUME0]
        + (node3_zp_consume0 ? gemm_sync_slv_if[3].value : 32'd0);
    wire [31:0] sync_zp_consume1_next = sync_regs_q[RID_ZP_CONSUME1]
        + (node3_zp_consume1 ? gemm_sync_slv_if[3].value : 32'd0);

    always_comb begin
      effective_sync[RID_T0] = sync_t0_next;
      effective_sync[RID_W0] = sync_w0_next;
      effective_sync[RID_SZ0] = sync_sz0_next;
      effective_sync[RID_G0] = sync_g0_next;
      effective_sync[RID_O] = sync_o_next;
      effective_sync[RID_T1] = sync_t1_next;
      effective_sync[RID_W1] = sync_w1_next;
      effective_sync[RID_SZ1] = sync_sz1_next;
      effective_sync[RID_G1] = sync_g1_next;
      effective_sync[RID_ACC_FREE0] = sync_acc_free0_next;
      effective_sync[RID_ACC_FREE1] = sync_acc_free1_next;
      effective_sync[RID_SC0] = sync_sc0_next;
      effective_sync[RID_ZP0] = sync_zp0_next;
      effective_sync[RID_SC1] = sync_sc1_next;
      effective_sync[RID_ZP1] = sync_zp1_next;
      effective_sync[RID_W_CONSUME0] = sync_w_consume0_next;
      effective_sync[RID_W_CONSUME1] = sync_w_consume1_next;
      effective_sync[RID_SC_CONSUME0] = sync_sc_consume0_next;
      effective_sync[RID_SC_CONSUME1] = sync_sc_consume1_next;
      effective_sync[RID_ZP_CONSUME0] = sync_zp_consume0_next;
      effective_sync[RID_ZP_CONSUME1] = sync_zp_consume1_next;
    end

`ifndef SYNTHESIS
    // Keep the previous serial reducer as a simulation-only executable
    // specification.  Every legal owner event must remain bit- and
    // cycle-identical while synthesis sees only the parallel implementation.
    logic [31:0] effective_sync_legacy[NUM_SYNC_REGS];

    always_comb begin
      for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
        effective_sync_legacy[rid] = sync_regs_q[rid];

      for (int child = 0; child < N_CHILDREN; ++child) begin
        if (child_completion_pop_v[child]
         && child_inflight_head[child].valid) begin
          if (child_inflight_head[child].set_mode) begin
            effective_sync_legacy[child_inflight_head[child].reg_id]
                = child_inflight_head[child].value;
          end else begin
            effective_sync_legacy[child_inflight_head[child].reg_id]
                = effective_sync_legacy[
                    child_inflight_head[child].reg_id]
                + child_inflight_head[child].value;
          end
        end
      end

      if (gemm_sync_slv_if[1].valid
       && (gemm_sync_slv_if[1].reg_idx < NUM_SYNC_REGS)) begin
        effective_sync_legacy[gemm_sync_slv_if[1].reg_idx]
            = effective_sync_legacy[gemm_sync_slv_if[1].reg_idx]
            + gemm_sync_slv_if[1].value;
      end
      if (gemm_sync_slv_if[2].valid
       && (gemm_sync_slv_if[2].reg_idx < NUM_SYNC_REGS)) begin
        effective_sync_legacy[gemm_sync_slv_if[2].reg_idx]
            = effective_sync_legacy[gemm_sync_slv_if[2].reg_idx]
            + gemm_sync_slv_if[2].value;
      end
      if (gemm_sync_slv_if[3].valid
       && (gemm_sync_slv_if[3].reg_idx < NUM_SYNC_REGS)) begin
        effective_sync_legacy[gemm_sync_slv_if[3].reg_idx]
            = effective_sync_legacy[gemm_sync_slv_if[3].reg_idx]
            + gemm_sync_slv_if[3].value;
      end

      effective_sync_legacy[RID_SZ0]
          = (effective_sync_legacy[RID_SC0]
             < effective_sync_legacy[RID_ZP0])
          ? effective_sync_legacy[RID_SC0]
          : effective_sync_legacy[RID_ZP0];
      effective_sync_legacy[RID_SZ1]
          = (effective_sync_legacy[RID_SC1]
             < effective_sync_legacy[RID_ZP1])
          ? effective_sync_legacy[RID_SC1]
          : effective_sync_legacy[RID_ZP1];
    end

    always_ff @(posedge clk) begin
      if (!reset && sync_update_contract_legal) begin
        for (int rid = 0; rid < NUM_SYNC_REGS; ++rid) begin
          assert (effective_sync[rid] == effective_sync_legacy[rid])
            else $fatal(1,
                "%s: parallel sync reducer diverged at RID %0d: new=%0d legacy=%0d",
                INSTANCE_ID, rid, effective_sync[rid],
                effective_sync_legacy[rid]);
        end
      end
    end
`endif

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
          sync_regs_q[rid] <= 32'd0;
      end else begin
        for (int rid = 0; rid < NUM_SYNC_REGS; ++rid)
          sync_regs_q[rid] <= effective_sync[rid];
      end
    end

    // Keep the Weight-DMA writer fence on the registered synchronization
    // boundary.  A consume update becomes visible one cycle later, avoiding a
    // compute-result -> sync reduction -> DMA scheduling path in one cycle.
    assign weight_consume_value0_o = sync_regs_q[RID_W_CONSUME0];
    assign weight_consume_value1_o = sync_regs_q[RID_W_CONSUME1];
    assign scale_consume_value0_o = sync_sc_consume0_next;
    assign scale_consume_value1_o = sync_sc_consume1_next;
    assign zero_point_consume_value0_o = sync_zp_consume0_next;
    assign zero_point_consume_value1_o = sync_zp_consume1_next;

    // Registered operand completion makes a final register write consumable
    // only on the following cycle for all W/S/Z resources.
    assign gemm_ctrl_if.input_w_load_value[0] = sync_regs_q[RID_W0];
    assign gemm_ctrl_if.input_w_load_value[1] = sync_regs_q[RID_W1];
    assign gemm_ctrl_if.input_sc_load_value[0] = sync_regs_q[RID_SC0];
    assign gemm_ctrl_if.input_sc_load_value[1] = sync_regs_q[RID_SC1];
    assign gemm_ctrl_if.input_zp_load_value[0] = sync_regs_q[RID_ZP0];
    assign gemm_ctrl_if.input_zp_load_value[1] = sync_regs_q[RID_ZP1];
    assign gemm_ctrl_if.input_acc_free_value[0] = sync_acc_free0_next;
    assign gemm_ctrl_if.input_acc_free_value[1] = sync_acc_free1_next;

    generate
      for (genvar i = 0; i < N_CHILDREN; ++i) begin : g_child_scheduler
        wire [CHILD_QUEUE_DATAW-1:0] child_q_dout;
        wire [INFLIGHT_DATAW-1:0] inflight_dout;
        localparam int THIS_CHILD_QUEUE_DEPTH
            = (i == DMA_CHILD_INDEX) ? DMA_CHILD_QUEUE_DEPTH : CHILD_QUEUE_DEPTH;
        logic deps_ready;
        logic prepare_deps_ready;

        assign child_q_cmd[i] = child_q_dout;

        if (i == DMA_CHILD_INDEX) begin : g_dma_dependency_check
          logic dma_wait_supported;
          logic [31:0] dma_wait_value;

          always_comb begin
            dma_wait_supported = 1'b1;
            case (child_q_cmd[i].waits[0].reg_id)
              GEMM_SYNC_REG_ID_WIDTH'(RID_G0):
                dma_wait_value = sync_g0_next;
              GEMM_SYNC_REG_ID_WIDTH'(RID_G1):
                dma_wait_value = sync_g1_next;
              GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE0):
                dma_wait_value = sync_acc_free0_next;
              GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE1):
                dma_wait_value = sync_acc_free1_next;
              default: begin
                dma_wait_supported = 1'b0;
                dma_wait_value = 32'd0;
              end
            endcase
          end

          assign deps_ready = !child_q_cmd[i].waits[0].valid
                           || (dma_wait_supported
                            && (dma_wait_value
                                >= child_q_cmd[i].waits[0].target));
          // DMA source preparation has no architectural dependency.  This is
          // an explicit producer contract, checked in simulation below.
          assign prepare_deps_ready = 1'b1;
        end else begin : g_generic_dependency_check
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

          always_comb begin
            prepare_deps_ready = 1'b1;
            for (int dep = 0; dep < GEMM_MAX_PREPARE_WAIT_DEPS; ++dep) begin
              if (child_q_cmd[i].prepare.waits[dep].valid) begin
                prepare_deps_ready
                    &= (child_q_cmd[i].prepare.waits[dep].reg_id
                        < NUM_SYNC_REGS)
                    && (effective_sync[
                          child_q_cmd[i].prepare.waits[dep].reg_id]
                        >= child_q_cmd[i].prepare.waits[dep].target);
              end
            end
          end
        end

        assign child_deps_ready_v[i] = deps_ready;
        assign child_prepare_deps_ready_v[i] = prepare_deps_ready;
        assign child_prepare_eligible_v[i]
            = !child_q_empty_v[i]
           && child_q_cmd[i].prepare.valid
           && (child_q_cmd[i].prepare.mode == GEMM_PREPARE_SOURCE_READ)
           && prepare_deps_ready
           && !child_deps_ready_v[i]
           && !child_prepare_sent_q[i];
        // The DMA child crosses a wide controller boundary.  Register only
        // that speculative offer; the other local children retain their
        // existing same-cycle prepare behavior.
        assign child_prepare_valid_v[i] = (i == DMA_CHILD_INDEX)
                                        ? dma_prepare_valid_q
                                        : child_prepare_eligible_v[i];
        assign child_prepare_fire_v[i]
            = child_prepare_valid_v[i] && child_prepare_ready_v[i];
        assign child_dependency_eligible_v[i]
            = !child_q_empty_v[i] && deps_ready;
        assign gemm_cqueue_out[i].ctrl.cmd = child_q_cmd[i];

        VX_fifo_queue #(
          .DATAW (CHILD_QUEUE_DATAW),
          .DEPTH (THIS_CHILD_QUEUE_DEPTH)
        ) u_child_cmd_queue (
          .clk       (clk),
          .reset     (reset),
          .push      (child_q_push_v[i]),
          .pop       (child_q_pop_v[i]),
          .data_in   (cmd_stage_cmd_q),
          .data_out  (child_q_dout),
          .empty     (child_q_empty_v[i]),
          .full      (child_q_full_v[i]),
          .alm_empty (),
          .alm_full  (),
          .size      ()
        );

        if (i == DMA_CHILD_INDEX) begin : g_dma_child
          assign inflight_dout = '0;
          assign child_inflight_head[i]
              = dma_inflight_meta_q[gemm_ctrl_if.dma_flag.done_tag];
          assign child_completion_pop_v[i]
              = gemm_cqueue_out[i].flag.done
             && dma_inflight_valid_q[gemm_ctrl_if.dma_flag.done_tag];
          assign child_inflight_empty_v[i] = !(|dma_inflight_valid_q);
          assign child_inflight_full_v[i] = &dma_inflight_valid_q;
          // A slot released by completion remains unavailable until the next
          // cycle.  The allocator therefore considers only registered valid
          // bits and never folds the current completion into can_accept.
          assign child_inflight_can_accept_v[i]
              = !child_inflight_full_v[i];
          assign child_single_active_ready_v[i] = 1'b1;
          assign gemm_cqueue_out[i].ctrl.start
              = child_single_active_ready_v[i]
             && !dma_prepare_valid_q
             && (dma_issue_tag_reserved_q
              || (child_dependency_eligible_v[i] && dma_free_tag_valid));
          assign child_issue_fire_v[i]
              = gemm_cqueue_out[i].ctrl.start
             && gemm_ctrl_if.dma_flag.cmd_ready;
          assign child_q_pop_v[i] = child_issue_fire_v[i];
        end else begin : g_inorder_child
          assign child_inflight_head[i] = inflight_dout;
          assign child_completion_pop_v[i]
              = gemm_cqueue_out[i].flag.done
             && !child_inflight_empty_v[i];
          assign child_inflight_can_accept_v[i]
              = !child_inflight_full_v[i] || child_completion_pop_v[i];
          // Input, Weight, Scale, and Zero-point have ordered multi-command
          // executors.  Their metadata FIFOs still retire notify records
          // strictly in issue order.  Other local executors retain their
          // single-active contract.
          assign child_single_active_ready_v[i]
              = ((i == 0) || (i == WEIGHT_CHILD_INDEX)
              || (i == SCALE_CHILD_INDEX) || (i == ZP_CHILD_INDEX))
              ? 1'b1
              : (child_inflight_empty_v[i] || child_completion_pop_v[i]);
          assign gemm_cqueue_out[i].ctrl.start
              = child_dependency_eligible_v[i]
             && child_inflight_can_accept_v[i]
             && child_single_active_ready_v[i]
             && gemm_cqueue_out[i].flag.idle;
          assign child_issue_fire_v[i] = gemm_cqueue_out[i].ctrl.start;
          assign child_q_pop_v[i] = child_issue_fire_v[i];

          VX_fifo_queue #(
            .DATAW (INFLIGHT_DATAW),
            .DEPTH (((i == 0) || (i == WEIGHT_CHILD_INDEX)
                  || (i == SCALE_CHILD_INDEX)
                  || (i == ZP_CHILD_INDEX)) ? 4 : 2)
          ) u_child_inflight_queue (
            .clk       (clk),
            .reset     (reset),
            .push      (child_issue_fire_v[i]),
            .pop       (child_completion_pop_v[i]),
            .data_in   ({child_q_cmd[i].notify,
                         child_q_cmd[i].work_seq}),
            .data_out  (inflight_dout),
            .empty     (child_inflight_empty_v[i]),
            .full      (child_inflight_full_v[i]),
            .alm_empty (),
            .alm_full  (),
            .size      ()
          );
        end

`ifndef SYNTHESIS
        logic [31:0] dbg_child_empty_cycles_q;
        logic [31:0] dbg_child_fallthrough_opportunity_q;
        logic [31:0] dbg_child_full_block_cycles_q;

        wire incoming_deps_ready = (cmd_stage_cmd_q.waits[0].valid
              ? (effective_sync[cmd_stage_cmd_q.waits[0].reg_id]
                 >= cmd_stage_cmd_q.waits[0].target) : 1'b1)
          && (cmd_stage_cmd_q.waits[1].valid
              ? (effective_sync[cmd_stage_cmd_q.waits[1].reg_id]
                 >= cmd_stage_cmd_q.waits[1].target) : 1'b1)
          && (cmd_stage_cmd_q.waits[2].valid
              ? (effective_sync[cmd_stage_cmd_q.waits[2].reg_id]
                 >= cmd_stage_cmd_q.waits[2].target) : 1'b1)
          && (cmd_stage_cmd_q.waits[3].valid
              ? (effective_sync[cmd_stage_cmd_q.waits[3].reg_id]
                 >= cmd_stage_cmd_q.waits[3].target) : 1'b1)
          && (cmd_stage_cmd_q.waits[4].valid
              ? (effective_sync[cmd_stage_cmd_q.waits[4].reg_id]
                 >= cmd_stage_cmd_q.waits[4].target) : 1'b1);

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
            if (child_prepare_fire_v[i]) begin
              assert (!child_q_pop_v[i]
                   && !child_issue_fire_v[i]
                   && !gemm_cqueue_out[i].ctrl.start)
                else $fatal(1,
                    "%s: child %0d prepare changed architectural issue state",
                    INSTANCE_ID, i);
              assert (child_q_cmd[i].prepare.valid
                   && (child_q_cmd[i].prepare.mode
                       == GEMM_PREPARE_SOURCE_READ)
                   && (child_q_cmd[i].prepare.max_beats != 0))
                else $fatal(1, "%s: child %0d invalid prepare metadata",
                            INSTANCE_ID, i);
              if (i == 0)
                assert (child_q_cmd[i].instr[3:0] == 4'd7)
                  else $fatal(1, "%s: non-input command prepared on child 0",
                              INSTANCE_ID);
              else if (i == 1)
                assert (child_q_cmd[i].instr[3:0] == 4'd5)
                  else $fatal(1, "%s: non-weight command prepared on child 1",
                              INSTANCE_ID);
              else if (i == SCALE_CHILD_INDEX)
                assert (child_q_cmd[i].instr[3:0] == GEMM_OP_SC_LDMA_MXU)
                  else $fatal(1, "%s: non-scale command prepared", INSTANCE_ID);
              else if (i == ZP_CHILD_INDEX)
                assert (child_q_cmd[i].instr[3:0] == GEMM_OP_ZP_LDMA_MXU)
                  else $fatal(1, "%s: non-zero-point command prepared", INSTANCE_ID);
              else if (i == DMA_CHILD_INDEX)
                assert ((child_q_cmd[i].instr[3:0] == 4'd1)
                     && (child_q_cmd[i].rd <= 3))
                  else $fatal(1, "%s: non-pure tile load prepared", INSTANCE_ID);
              else
                $fatal(1, "%s: output child must never prepare", INSTANCE_ID);
            end
            if (i == DMA_CHILD_INDEX) begin
              if (dma_prepare_valid_q) begin
                assert (!child_q_empty_v[i]
                     && (dma_prepare_cmd_q == child_q_cmd[i]))
                  else $fatal(1,
                      "%s: registered DMA prepare owner changed before acceptance",
                      INSTANCE_ID);
              end
              if (!child_q_empty_v[i]) begin
                assert (!child_q_cmd[i].waits[1].valid
                     && !child_q_cmd[i].waits[2].valid
                     && !child_q_cmd[i].waits[3].valid
                     && !child_q_cmd[i].waits[4].valid)
                  else $fatal(1,
                      "%s: DMA child used dependency slots above waits[0]",
                      INSTANCE_ID);
                assert (!child_q_cmd[i].prepare.waits[0].valid)
                  else $fatal(1,
                      "%s: DMA child used a prepare dependency",
                      INSTANCE_ID);
                if (child_q_cmd[i].waits[0].valid) begin
                  assert ((child_q_cmd[i].waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_G0))
                       || (child_q_cmd[i].waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_G1))
                       || (child_q_cmd[i].waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE0))
                       || (child_q_cmd[i].waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE1)))
                    else $fatal(1,
                        "%s: DMA child used unsupported waits[0] RID %0d",
                        INSTANCE_ID, child_q_cmd[i].waits[0].reg_id);
                end
              end
              assert (!(gemm_cqueue_out[i].flag.done
                     && !dma_inflight_valid_q[
                          gemm_ctrl_if.dma_flag.done_tag]))
                else $fatal(1, "%s: stray DMA completion tag %0d",
                            INSTANCE_ID, gemm_ctrl_if.dma_flag.done_tag);
              assert (!(child_issue_fire_v[i]
                     && child_inflight_full_v[i]))
                else $fatal(1, "%s: DMA inflight scoreboard overflow",
                            INSTANCE_ID);
              assert (!(!child_deps_ready_v[i]
                     && gemm_cqueue_out[i].ctrl.start
                     && !dma_issue_tag_reserved_q))
                else $fatal(1, "%s: unresolved DMA dependency issued",
                            INSTANCE_ID);
              assert (!(dma_prepare_valid_q
                     && gemm_cqueue_out[i].ctrl.start))
                else $fatal(1,
                    "%s: DMA child issued before registered prepare acceptance",
                    INSTANCE_ID);
              assert (child_q_pop_v[i] == child_issue_fire_v[i])
                else $fatal(1, "%s: DMA child pop/handshake mismatch",
                            INSTANCE_ID);
            end else begin
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
              if ((i != 0) && (i != WEIGHT_CHILD_INDEX)
               && (i != SCALE_CHILD_INDEX) && (i != ZP_CHILD_INDEX)) begin
                assert (!(child_issue_fire_v[i]
                       && !child_inflight_empty_v[i]
                       && !child_completion_pop_v[i]))
                  else $fatal(1, "%s: child %0d accepted multiple active commands",
                              INSTANCE_ID, i);
              end else if ((i == 0) && child_issue_fire_v[i]) begin
                assert ((child_q_cmd[i].instr[3:0] == 4'd7)
                     && child_q_cmd[i].waits[0].valid
                     && ((child_q_cmd[i].waits[0].reg_id
                          == GEMM_SYNC_REG_ID_WIDTH'(RID_T0))
                      || (child_q_cmd[i].waits[0].reg_id
                          == GEMM_SYNC_REG_ID_WIDTH'(RID_T1)))
                     && !child_q_cmd[i].waits[1].valid
                     && !child_q_cmd[i].waits[2].valid
                     && !child_q_cmd[i].waits[3].valid
                     && !child_q_cmd[i].waits[4].valid)
                  else $fatal(1,
                      "%s: Input source issue is not tile-ready-only",
                      INSTANCE_ID);
                assert (child_q_cmd[i].input_admit_waits[0].valid
                     && child_q_cmd[i].input_admit_waits[1].valid
                     && child_q_cmd[i].input_admit_waits[2].valid
                     && child_q_cmd[i].input_admit_waits[3].valid
                     && !child_q_cmd[i].flags[3]
                     && (((child_q_cmd[i].flags[2] == 1'b0)
                       && (child_q_cmd[i].input_admit_waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W0)))
                      || ((child_q_cmd[i].flags[2] == 1'b1)
                       && (child_q_cmd[i].input_admit_waits[0].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W1))))
                     && (child_q_cmd[i].input_admit_waits[1].reg_id
                         == GEMM_SYNC_REG_ID_WIDTH'(
                              child_q_cmd[i].flags[1]
                              ? RID_SC1 : RID_SC0))
                     && (child_q_cmd[i].input_admit_waits[2].reg_id
                         == GEMM_SYNC_REG_ID_WIDTH'(
                              child_q_cmd[i].flags[0]
                              ? RID_ZP1 : RID_ZP0))
                     && ((child_q_cmd[i].input_admit_waits[3].reg_id
                          == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE0))
                      || (child_q_cmd[i].input_admit_waits[3].reg_id
                          == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE1))))
                  else $fatal(1,
                      "%s: Input command admission metadata is invalid",
                      INSTANCE_ID);
              end else if ((i == WEIGHT_CHILD_INDEX)
                        && child_issue_fire_v[i]) begin
                assert (child_q_cmd[i].instr[3:0] == 4'd5)
                  else $fatal(1, "%s: non-Weight command entered Weight overlap FIFO",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W_CONSUME0))
                          && (child_q_cmd[i].flags[0] == 1'b0))
                      || ((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W_CONSUME1))
                          && (child_q_cmd[i].flags[0] == 1'b1))))
                  else $fatal(1,
                      "%s: Weight command writer RID/buffer mismatch",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (child_q_cmd[i].writer_wait.target != 0))
                  else $fatal(1, "%s: Weight command has zero writer target",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].waits[1].valid
                     && !child_q_cmd[i].waits[2].valid
                     && !child_q_cmd[i].waits[3].valid
                     && !child_q_cmd[i].waits[4].valid)
                  else $fatal(1,
                      "%s: Weight consume dependency remained in issue waits",
                      INSTANCE_ID);
              end else if ((i == SCALE_CHILD_INDEX)
                        && child_issue_fire_v[i]) begin
                assert (child_q_cmd[i].instr[3:0] == GEMM_OP_SC_LDMA_MXU)
                  else $fatal(1, "%s: non-Scale command entered Scale overlap FIFO",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_SC_CONSUME0))
                          && !child_q_cmd[i].flags[1])
                      || ((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_SC_CONSUME1))
                          && child_q_cmd[i].flags[1])))
                  else $fatal(1, "%s: Scale writer RID/buffer mismatch",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (child_q_cmd[i].writer_wait.target != 0))
                  else $fatal(1, "%s: Scale command has zero writer target",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].waits[1].valid
                     && !child_q_cmd[i].waits[2].valid
                     && !child_q_cmd[i].waits[3].valid
                     && !child_q_cmd[i].waits[4].valid)
                  else $fatal(1,
                      "%s: Scale consume dependency remained in issue waits",
                      INSTANCE_ID);
              end else if ((i == ZP_CHILD_INDEX)
                        && child_issue_fire_v[i]) begin
                assert (child_q_cmd[i].instr[3:0] == GEMM_OP_ZP_LDMA_MXU)
                  else $fatal(1, "%s: non-ZP command entered ZP overlap FIFO",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP_CONSUME0))
                          && !child_q_cmd[i].flags[1])
                      || ((child_q_cmd[i].writer_wait.reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP_CONSUME1))
                          && child_q_cmd[i].flags[1])))
                  else $fatal(1, "%s: ZP writer RID/buffer mismatch",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].writer_wait.valid
                     || (child_q_cmd[i].writer_wait.target != 0))
                  else $fatal(1, "%s: ZP command has zero writer target",
                              INSTANCE_ID);
                assert (!child_q_cmd[i].waits[1].valid
                     && !child_q_cmd[i].waits[2].valid
                     && !child_q_cmd[i].waits[3].valid
                     && !child_q_cmd[i].waits[4].valid)
                  else $fatal(1,
                      "%s: ZP consume dependency remained in issue waits",
                      INSTANCE_ID);
              end
            end
          end
        end
`endif
      end
    endgenerate

    // Capture the DMA queue head together with its offer.  While valid, issue
    // is blocked above, so the ordered queue head cannot advance before the
    // TMEM DMA controller accepts this registered command.
    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        dma_prepare_valid_q <= 1'b0;
        dma_prepare_cmd_q <= '0;
      end else begin
        if (dma_prepare_valid_q && child_prepare_ready_v[DMA_CHILD_INDEX]) begin
          dma_prepare_valid_q <= 1'b0;
        end else if (!dma_prepare_valid_q
                  && child_prepare_eligible_v[DMA_CHILD_INDEX]) begin
          dma_prepare_valid_q <= 1'b1;
          dma_prepare_cmd_q <= child_q_cmd[DMA_CHILD_INDEX];
        end
      end
    end

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        child_prepare_sent_q <= '0;
      end else begin
        for (int child = 0; child < N_CHILDREN; ++child) begin
          if (child_q_pop_v[child])
            child_prepare_sent_q[child] <= 1'b0;
          else if (child_prepare_fire_v[child])
            child_prepare_sent_q[child] <= 1'b1;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        dma_inflight_valid_q <= '0;
        dma_issue_tag_reserved_q <= 1'b0;
        dma_issue_tag_q <= '0;
        for (int slot = 0; slot < DMA_INFLIGHT_DEPTH; ++slot)
          dma_inflight_meta_q[slot] <= '0;
      end else begin
        if (child_completion_pop_v[DMA_CHILD_INDEX]) begin
          dma_inflight_valid_q[gemm_ctrl_if.dma_flag.done_tag] <= 1'b0;
        end

        if (child_issue_fire_v[DMA_CHILD_INDEX]) begin
          dma_inflight_valid_q[dma_issue_tag] <= 1'b1;
          dma_inflight_meta_q[dma_issue_tag]
              <= {child_q_cmd[DMA_CHILD_INDEX].notify,
                  child_q_cmd[DMA_CHILD_INDEX].work_seq};
        end

        if (child_issue_fire_v[DMA_CHILD_INDEX]) begin
          dma_issue_tag_reserved_q <= 1'b0;
        end else if (gemm_cqueue_out[DMA_CHILD_INDEX].ctrl.start
                  && !gemm_ctrl_if.dma_flag.cmd_ready
                  && !dma_issue_tag_reserved_q) begin
          dma_issue_tag_reserved_q <= 1'b1;
          dma_issue_tag_q <= dma_free_tag;
        end
      end
    end

    // Child-to-executor mapping. Non-DMA children retire in order; the DMA
    // child returns a tag that selects its completion metadata slot.
    assign gemm_ctrl_if.input_read_ctrl.cmd = gemm_cqueue_out[0].ctrl.cmd;
    assign gemm_ctrl_if.input_read_ctrl.start = gemm_cqueue_out[0].ctrl.start;
    assign gemm_ctrl_if.input_read_ctrl.prepare = child_prepare_valid_v[0];
    assign child_prepare_ready_v[0]
        = gemm_ctrl_if.input_read_flag.prepare_ready;
    assign gemm_cqueue_out[0].flag.idle = gemm_ctrl_if.input_read_flag.idle;
    assign gemm_cqueue_out[0].flag.done = gemm_ctrl_if.input_read_flag.done;

    assign gemm_ctrl_if.weight_read_ctrl.cmd = gemm_cqueue_out[1].ctrl.cmd;
    assign gemm_ctrl_if.weight_read_ctrl.start = gemm_cqueue_out[1].ctrl.start;
    assign gemm_ctrl_if.weight_read_ctrl.prepare = child_prepare_valid_v[1];
    assign child_prepare_ready_v[1]
        = gemm_ctrl_if.weight_read_flag.prepare_ready;
    assign gemm_cqueue_out[1].flag.idle = gemm_ctrl_if.weight_read_flag.idle;
    assign gemm_cqueue_out[1].flag.done = gemm_ctrl_if.weight_read_flag.done;

    assign gemm_ctrl_if.scale_read_ctrl.cmd
        = gemm_cqueue_out[SCALE_CHILD_INDEX].ctrl.cmd;
    assign gemm_ctrl_if.scale_read_ctrl.start
        = gemm_cqueue_out[SCALE_CHILD_INDEX].ctrl.start;
    assign gemm_ctrl_if.scale_read_ctrl.prepare
        = child_prepare_valid_v[SCALE_CHILD_INDEX];
    assign child_prepare_ready_v[SCALE_CHILD_INDEX]
        = gemm_ctrl_if.scale_read_flag.prepare_ready;
    assign gemm_cqueue_out[SCALE_CHILD_INDEX].flag.idle
        = gemm_ctrl_if.scale_read_flag.idle;
    assign gemm_cqueue_out[SCALE_CHILD_INDEX].flag.done
        = gemm_ctrl_if.scale_read_flag.done;

    assign gemm_ctrl_if.zero_point_read_ctrl.cmd
        = gemm_cqueue_out[ZP_CHILD_INDEX].ctrl.cmd;
    assign gemm_ctrl_if.zero_point_read_ctrl.start
        = gemm_cqueue_out[ZP_CHILD_INDEX].ctrl.start;
    assign gemm_ctrl_if.zero_point_read_ctrl.prepare
        = child_prepare_valid_v[ZP_CHILD_INDEX];
    assign child_prepare_ready_v[ZP_CHILD_INDEX]
        = gemm_ctrl_if.zero_point_read_flag.prepare_ready;
    assign gemm_cqueue_out[ZP_CHILD_INDEX].flag.idle
        = gemm_ctrl_if.zero_point_read_flag.idle;
    assign gemm_cqueue_out[ZP_CHILD_INDEX].flag.done
        = gemm_ctrl_if.zero_point_read_flag.done;

    assign gemm_ctrl_if.quant_param_read_ctrl = '0;

    assign gemm_ctrl_if.output_write_ctrl.cmd
        = gemm_cqueue_out[OUTPUT_CHILD_INDEX].ctrl.cmd;
    assign gemm_ctrl_if.output_write_ctrl.start
        = gemm_cqueue_out[OUTPUT_CHILD_INDEX].ctrl.start;
    assign gemm_ctrl_if.output_write_ctrl.prepare = 1'b0;
    assign child_prepare_ready_v[OUTPUT_CHILD_INDEX] = 1'b0;
    assign gemm_cqueue_out[OUTPUT_CHILD_INDEX].flag.idle
        = gemm_ctrl_if.output_write_flag.idle;
    assign gemm_cqueue_out[OUTPUT_CHILD_INDEX].flag.done
        = gemm_ctrl_if.output_write_flag.done;

    assign gemm_ctrl_if.dma_ctrl.cmd = gemm_cqueue_out[DMA_CHILD_INDEX].ctrl.cmd;
    assign gemm_ctrl_if.dma_ctrl.start
        = gemm_cqueue_out[DMA_CHILD_INDEX].ctrl.start;
    assign gemm_ctrl_if.dma_ctrl.cmd_valid
        = gemm_cqueue_out[DMA_CHILD_INDEX].ctrl.start;
    assign gemm_ctrl_if.dma_ctrl.cmd_tag = dma_issue_tag;
    assign gemm_ctrl_if.dma_ctrl.prepare_valid
        = child_prepare_valid_v[DMA_CHILD_INDEX];
    assign gemm_ctrl_if.dma_ctrl.prepare_cmd
        = dma_prepare_cmd_q;
    assign child_prepare_ready_v[DMA_CHILD_INDEX]
        = gemm_ctrl_if.dma_flag.prepare_ready;
    assign gemm_cqueue_out[DMA_CHILD_INDEX].flag.idle
        = gemm_ctrl_if.dma_flag.cmd_ready;
    assign gemm_cqueue_out[DMA_CHILD_INDEX].flag.done
        = gemm_ctrl_if.dma_flag.done;

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
`ifdef DBG_TRACE_GEMM_CMD_PERF
`ifdef DBG_GEMM_CMD_MAX
    localparam int DBG_CMD_MAX = `DBG_GEMM_CMD_MAX;
`else
    localparam int DBG_CMD_MAX = 4096;
`endif
`ifdef DBG_GEMM_TILE_MAX
    localparam int DBG_TILE_MAX = `DBG_GEMM_TILE_MAX;
`else
    localparam int DBG_TILE_MAX = 256;
`endif
    localparam int DBG_CLASS_COUNT = 10;
    localparam int DBG_QUEUE_DEPTH = DMA_CHILD_QUEUE_DEPTH + 1;
    localparam logic [3:0] DBG_C_DRAM_INPUT_LOAD  = 4'd0;
    localparam logic [3:0] DBG_C_DRAM_WEIGHT_LOAD = 4'd1;
    localparam logic [3:0] DBG_C_DRAM_SCALE_LOAD  = 4'd2;
    localparam logic [3:0] DBG_C_DRAM_ZP_LOAD     = 4'd3;
    localparam logic [3:0] DBG_C_DRAM_OUTPUT_STORE = 4'd4;
    localparam logic [3:0] DBG_C_MXU_WEIGHT_LOAD  = 4'd5;
    localparam logic [3:0] DBG_C_MXU_SCALE_LOAD   = 4'd6;
    localparam logic [3:0] DBG_C_MXU_ZP_LOAD      = 4'd7;
    localparam logic [3:0] DBG_C_COMPUTE_ARM      = 4'd8;
    localparam logic [3:0] DBG_C_ACCUM_TO_LMEM    = 4'd9;

    typedef struct {
      bit emitted;
      bit issued;
      bit completed;
      logic [3:0] class_id;
      logic [2:0] child;
      logic [7:0] state;
      logic [3:0] phase;
      logic [31:0] tile;
      logic [31:0] nt;
      logic [31:0] mt;
      logic [31:0] kt;
      logic [31:0] mxu_nt;
      logic [31:0] mxu_kt;
      logic tile_buf;
      logic mxu_buf;
      logic acc_group;
      logic [31:0] generation;
      logic [GEMM_DMA_TAG_WIDTH-1:0] dma_tag;
      gemm_unified_cmd_t cmd;
      longint unsigned emit_cycle;
      longint unsigned issue_cycle;
      longint unsigned done_cycle;
      longint unsigned dependency_blocked_cycles;
      longint unsigned executor_blocked_cycles;
      longint unsigned overlap_any_cycles;
      longint unsigned overlap_compute_pipeline_cycles;
      longint unsigned overlap_later_tile_load_cycles;
      longint unsigned overlap_later_tile_compute_cycles;
    } dbg_cmd_record_t;

    dbg_cmd_record_t dbg_cmd_record[DBG_CMD_MAX];
    longint unsigned dbg_overlap_class[DBG_CMD_MAX][DBG_CLASS_COUNT];
    int unsigned dbg_q_uid[N_CHILDREN][DBG_QUEUE_DEPTH];
    int unsigned dbg_q_head[N_CHILDREN];
    int unsigned dbg_q_tail[N_CHILDREN];
    int unsigned dbg_q_count[N_CHILDREN];
    int unsigned dbg_active_uid[N_CHILDREN];
    bit dbg_active_uid_valid[N_CHILDREN];
    int unsigned dbg_dma_uid_by_tag[DMA_INFLIGHT_DEPTH];
    bit dbg_dma_uid_valid[DMA_INFLIGHT_DEPTH];

    longint unsigned dbg_cycle_q;
    longint unsigned dbg_job_seq_q;
    int unsigned dbg_record_count_q;
    int unsigned dbg_issue_count_q;
    int unsigned dbg_done_count_q;
    int unsigned dbg_max_concurrent_q;
    int unsigned dbg_max_tile_q;
    longint unsigned dbg_compute_pipeline_cycles_q;
    longint unsigned dbg_class_active_cycles_q[DBG_CLASS_COUNT];

    bit dbg_preload_seen[DBG_TILE_MAX];
    bit dbg_compute_seen[DBG_TILE_MAX];
    bit dbg_store_seen[DBG_TILE_MAX];
    longint unsigned dbg_preload_issue_cycle[DBG_TILE_MAX];
    longint unsigned dbg_preload_done_cycle[DBG_TILE_MAX];
    longint unsigned dbg_compute_issue_cycle[DBG_TILE_MAX];
    longint unsigned dbg_compute_done_cycle[DBG_TILE_MAX];
    longint unsigned dbg_store_issue_cycle[DBG_TILE_MAX];
    longint unsigned dbg_store_done_cycle[DBG_TILE_MAX];
    longint unsigned dbg_tile_compute_pipeline_cycles[DBG_TILE_MAX];
    longint unsigned dbg_tile_preload_compute_overlap[DBG_TILE_MAX];
    longint unsigned dbg_tile_store_next_compute_overlap[DBG_TILE_MAX];
    longint unsigned dbg_tile_store_next_load_overlap[DBG_TILE_MAX];
    longint unsigned dbg_tile_store_later_load_overlap[DBG_TILE_MAX];

    function automatic int unsigned dbg_child_depth(input int child);
      return (child == DMA_CHILD_INDEX)
          ? (DMA_CHILD_QUEUE_DEPTH + 1) : (CHILD_QUEUE_DEPTH + 1);
    endfunction

    function automatic logic [3:0] dbg_command_class(
        input gemm_unified_cmd_t cmd
    );
      unique case (cmd.instr[3:0])
        4'd1: begin
          unique case (cmd.rd)
            0: dbg_command_class = DBG_C_DRAM_INPUT_LOAD;
            1: dbg_command_class = DBG_C_DRAM_WEIGHT_LOAD;
            2: dbg_command_class = DBG_C_DRAM_SCALE_LOAD;
            default: dbg_command_class = DBG_C_DRAM_ZP_LOAD;
          endcase
        end
        4'd2: dbg_command_class = DBG_C_DRAM_OUTPUT_STORE;
        4'd5: dbg_command_class = DBG_C_MXU_WEIGHT_LOAD;
        GEMM_OP_SC_LDMA_MXU: dbg_command_class = DBG_C_MXU_SCALE_LOAD;
        GEMM_OP_ZP_LDMA_MXU: dbg_command_class = DBG_C_MXU_ZP_LOAD;
        4'd7: dbg_command_class = DBG_C_COMPUTE_ARM;
        default: dbg_command_class = DBG_C_ACCUM_TO_LMEM;
      endcase
    endfunction

    function automatic bit dbg_is_dram_load(input logic [3:0] class_id);
      return class_id <= DBG_C_DRAM_ZP_LOAD;
    endfunction

    function automatic string dbg_class_name(input logic [3:0] class_id);
      case (class_id)
        DBG_C_DRAM_INPUT_LOAD:   return "DRAM_INPUT_LOAD";
        DBG_C_DRAM_WEIGHT_LOAD:  return "DRAM_WEIGHT_LOAD";
        DBG_C_DRAM_SCALE_LOAD:   return "DRAM_SCALE_LOAD";
        DBG_C_DRAM_ZP_LOAD:      return "DRAM_ZP_LOAD";
        DBG_C_DRAM_OUTPUT_STORE: return "DRAM_OUTPUT_STORE";
        DBG_C_MXU_WEIGHT_LOAD:   return "MXU_WEIGHT_LOAD";
        DBG_C_MXU_SCALE_LOAD:    return "MXU_SCALE_LOAD";
        DBG_C_MXU_ZP_LOAD:       return "MXU_ZP_LOAD";
        DBG_C_COMPUTE_ARM:       return "COMPUTE_ARM";
        default:                 return "ACCUM_TO_LMEM";
      endcase
    endfunction

    function automatic longint unsigned dbg_interval_overlap(
        input longint unsigned start_a,
        input longint unsigned end_a,
        input longint unsigned start_b,
        input longint unsigned end_b
    );
      longint unsigned overlap_start;
      longint unsigned overlap_end;
      begin
        overlap_start = (start_a > start_b) ? start_a : start_b;
        overlap_end = (end_a < end_b) ? end_a : end_b;
        return (overlap_end > overlap_start)
            ? (overlap_end - overlap_start) : 0;
      end
    endfunction

    task automatic dbg_dump_invocation;
      int incomplete;
      longint unsigned class_count;
      longint unsigned class_queue;
      longint unsigned class_service;
      longint unsigned pair_overlap;
      longint unsigned preload_tail;
      longint unsigned ready_slack;
      longint unsigned store_tail;
      longint unsigned final_store_drain;
      begin
        incomplete = 0;
        for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
          if (!dbg_cmd_record[uid].completed)
            incomplete++;
        end

        $display("GEMM_CMD_PERF_SUMMARY | {inst=%s, job=%0d, entry=%0d, cycles=%0d, emitted=%0d, issued=%0d, completed=%0d, incomplete=%0d, max_concurrent=%0d, compute_pipeline_cycles=%0d}",
                 INSTANCE_ID, dbg_job_seq_q, active_entry_id_q,
                 dbg_cycle_q, dbg_record_count_q, dbg_issue_count_q,
                 dbg_done_count_q, incomplete, dbg_max_concurrent_q,
                 dbg_compute_pipeline_cycles_q);

        for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id) begin
          class_count = 0;
          class_queue = 0;
          class_service = 0;
          for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
            if (dbg_cmd_record[uid].class_id == class_id) begin
              class_count++;
              class_queue += dbg_cmd_record[uid].issue_cycle
                           - dbg_cmd_record[uid].emit_cycle;
              class_service += dbg_cmd_record[uid].done_cycle
                             - dbg_cmd_record[uid].issue_cycle;
            end
          end
          $display("GEMM_CMD_CLASS_SUMMARY | {inst=%s, job=%0d, class=%s, count=%0d, queue_cycles=%0d, service_cycles=%0d, class_active_cycles=%0d}",
                   INSTANCE_ID, dbg_job_seq_q,
                   dbg_class_name(4'(class_id)), class_count,
                   class_queue, class_service,
                   dbg_class_active_cycles_q[class_id]);
        end

        for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
          $display("GEMM_CMD_TIMELINE | {inst=%s, job=%0d, entry=%0d, uid=%0d, class=%s, child=%0d, op=0x%0h, state=%0d, phase=%0d, tile=%0d, nt=%0d, mt=%0d, kt=%0d, mxu_nt=%0d, mxu_kt=%0d, tile_buf=%0d, mxu_buf=%0d, acc_group=%0d, generation=%0d, dma_tag=%0d, size=%0d, src=0x%0h, dst=0x%0h, notify_valid=%0d, notify_rid=%0d, notify_value=%0d, emit=%0d, issue=%0d, done=%0d, queue=%0d, service=%0d, total=%0d, dependency_blocked=%0d, executor_blocked=%0d, overlap_any=%0d, overlap_compute=%0d, overlap_later_load=%0d, overlap_later_compute=%0d}",
                   INSTANCE_ID, dbg_job_seq_q, active_entry_id_q, uid,
                   dbg_class_name(dbg_cmd_record[uid].class_id),
                   dbg_cmd_record[uid].child,
                   dbg_cmd_record[uid].cmd.instr[3:0],
                   dbg_cmd_record[uid].state,
                   dbg_cmd_record[uid].phase,
                   dbg_cmd_record[uid].tile,
                   dbg_cmd_record[uid].nt,
                   dbg_cmd_record[uid].mt,
                   dbg_cmd_record[uid].kt,
                   dbg_cmd_record[uid].mxu_nt,
                   dbg_cmd_record[uid].mxu_kt,
                   dbg_cmd_record[uid].tile_buf,
                   dbg_cmd_record[uid].mxu_buf,
                   dbg_cmd_record[uid].acc_group,
                   dbg_cmd_record[uid].generation,
                   dbg_cmd_record[uid].dma_tag,
                   dbg_cmd_record[uid].cmd.instr[31:4],
                   dbg_cmd_record[uid].cmd.rs2_data,
                   dbg_cmd_record[uid].cmd.rs1_data,
                   dbg_cmd_record[uid].cmd.notify.valid,
                   dbg_cmd_record[uid].cmd.notify.reg_id,
                   dbg_cmd_record[uid].cmd.notify.value,
                   dbg_cmd_record[uid].emit_cycle,
                   dbg_cmd_record[uid].issue_cycle,
                   dbg_cmd_record[uid].done_cycle,
                   dbg_cmd_record[uid].issue_cycle
                     - dbg_cmd_record[uid].emit_cycle,
                   dbg_cmd_record[uid].done_cycle
                     - dbg_cmd_record[uid].issue_cycle,
                   dbg_cmd_record[uid].done_cycle
                     - dbg_cmd_record[uid].emit_cycle,
                   dbg_cmd_record[uid].dependency_blocked_cycles,
                   dbg_cmd_record[uid].executor_blocked_cycles,
                   dbg_cmd_record[uid].overlap_any_cycles,
                   dbg_cmd_record[uid].overlap_compute_pipeline_cycles,
                   dbg_cmd_record[uid].overlap_later_tile_load_cycles,
                   dbg_cmd_record[uid].overlap_later_tile_compute_cycles);
          for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id) begin
            if (dbg_overlap_class[uid][class_id] != 0) begin
              $display("GEMM_CMD_OVERLAP_PAIR | {inst=%s, job=%0d, uid=%0d, peer_class=%s, cycles=%0d}",
                       INSTANCE_ID, dbg_job_seq_q, uid,
                       dbg_class_name(4'(class_id)),
                       dbg_overlap_class[uid][class_id]);
            end
          end
        end

        for (int lhs = 0; lhs < dbg_record_count_q; ++lhs) begin
          for (int rhs = lhs + 1; rhs < dbg_record_count_q; ++rhs) begin
            pair_overlap = dbg_interval_overlap(
                dbg_cmd_record[lhs].issue_cycle,
                dbg_cmd_record[lhs].done_cycle,
                dbg_cmd_record[rhs].issue_cycle,
                dbg_cmd_record[rhs].done_cycle);
            if (pair_overlap != 0) begin
              $display("GEMM_CMD_OVERLAP_PAIR | {inst=%s, job=%0d, uid_a=%0d, class_a=%s, tile_a=%0d, uid_b=%0d, class_b=%s, tile_b=%0d, cycles=%0d}",
                       INSTANCE_ID, dbg_job_seq_q, lhs,
                       dbg_class_name(dbg_cmd_record[lhs].class_id),
                       dbg_cmd_record[lhs].tile, rhs,
                       dbg_class_name(dbg_cmd_record[rhs].class_id),
                       dbg_cmd_record[rhs].tile, pair_overlap);
            end
          end
        end

        for (int tile = 0; tile <= dbg_max_tile_q; ++tile) begin
          preload_tail = 0;
          ready_slack = 0;
          store_tail = 0;
          final_store_drain = 0;
          if ((tile + 1 < DBG_TILE_MAX)
           && dbg_preload_seen[tile + 1]
           && dbg_compute_seen[tile]) begin
            if (dbg_preload_done_cycle[tile + 1]
                > dbg_compute_done_cycle[tile])
              preload_tail = dbg_preload_done_cycle[tile + 1]
                           - dbg_compute_done_cycle[tile];
            if (dbg_compute_seen[tile + 1]
             && (dbg_compute_issue_cycle[tile + 1]
                 > dbg_preload_done_cycle[tile + 1]))
              ready_slack = dbg_compute_issue_cycle[tile + 1]
                          - dbg_preload_done_cycle[tile + 1];
          end
          if ((tile + 1 < DBG_TILE_MAX)
           && dbg_store_seen[tile]
           && dbg_compute_seen[tile + 1]
           && (dbg_store_done_cycle[tile]
               > dbg_compute_done_cycle[tile + 1]))
            store_tail = dbg_store_done_cycle[tile]
                       - dbg_compute_done_cycle[tile + 1];
          if ((tile == dbg_max_tile_q) && dbg_store_seen[tile]
           && dbg_compute_seen[tile]
           && (dbg_store_done_cycle[tile] > dbg_compute_done_cycle[tile]))
            final_store_drain = dbg_store_done_cycle[tile]
                              - dbg_compute_done_cycle[tile];

          $display("GEMM_TILE_OVERLAP | {inst=%s, job=%0d, tile=%0d, preload_next_compute=%0d, preload_hidden=%0d, preload_tail=%0d, tile_ready_slack=%0d, store_next_compute=%0d, store_next_load=%0d, store_later_load=%0d, store_hidden=%0d, store_tail=%0d, compute_pipeline_cycles=%0d, final_store_drain=%0d}",
                   INSTANCE_ID, dbg_job_seq_q, tile,
                   dbg_tile_preload_compute_overlap[tile],
                   dbg_tile_preload_compute_overlap[tile], preload_tail,
                   ready_slack, dbg_tile_store_next_compute_overlap[tile],
                   dbg_tile_store_next_load_overlap[tile],
                   dbg_tile_store_later_load_overlap[tile],
                   dbg_tile_store_next_compute_overlap[tile], store_tail,
                   dbg_tile_compute_pipeline_cycles[tile], final_store_drain);
        end
      end
    endtask

    always @(posedge clk) begin : dbg_command_lifecycle_ledger
      if (reset) begin
        dbg_cycle_q = 0;
        dbg_job_seq_q = 0;
        dbg_record_count_q = 0;
        dbg_issue_count_q = 0;
        dbg_done_count_q = 0;
        dbg_max_concurrent_q = 0;
        dbg_max_tile_q = 0;
        dbg_compute_pipeline_cycles_q = 0;
        for (int child = 0; child < N_CHILDREN; ++child) begin
          dbg_q_head[child] = 0;
          dbg_q_tail[child] = 0;
          dbg_q_count[child] = 0;
          dbg_active_uid[child] = 0;
          dbg_active_uid_valid[child] = 0;
        end
        for (int tag = 0; tag < DMA_INFLIGHT_DEPTH; ++tag) begin
          dbg_dma_uid_by_tag[tag] = 0;
          dbg_dma_uid_valid[tag] = 0;
        end
        for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id)
          dbg_class_active_cycles_q[class_id] = 0;
        for (int tile = 0; tile < DBG_TILE_MAX; ++tile) begin
          dbg_preload_seen[tile] = 0;
          dbg_compute_seen[tile] = 0;
          dbg_store_seen[tile] = 0;
          dbg_tile_compute_pipeline_cycles[tile] = 0;
          dbg_tile_preload_compute_overlap[tile] = 0;
          dbg_tile_store_next_compute_overlap[tile] = 0;
          dbg_tile_store_next_load_overlap[tile] = 0;
          dbg_tile_store_later_load_overlap[tile] = 0;
        end
      end else if (cfg_fire) begin
        dbg_cycle_q = 0;
        dbg_record_count_q = 0;
        dbg_issue_count_q = 0;
        dbg_done_count_q = 0;
        dbg_max_concurrent_q = 0;
        dbg_max_tile_q = 0;
        dbg_compute_pipeline_cycles_q = 0;
        for (int child = 0; child < N_CHILDREN; ++child) begin
          assert (dbg_q_count[child] == 0)
            else $fatal(1, "%s: debug command FIFO child %0d not empty at config",
                        INSTANCE_ID, child);
          dbg_q_head[child] = 0;
          dbg_q_tail[child] = 0;
          dbg_q_count[child] = 0;
          dbg_active_uid_valid[child] = 0;
        end
        for (int tag = 0; tag < DMA_INFLIGHT_DEPTH; ++tag)
          dbg_dma_uid_valid[tag] = 0;
        for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id)
          dbg_class_active_cycles_q[class_id] = 0;
        for (int tile = 0; tile < DBG_TILE_MAX; ++tile) begin
          dbg_preload_seen[tile] = 0;
          dbg_compute_seen[tile] = 0;
          dbg_store_seen[tile] = 0;
          dbg_preload_issue_cycle[tile] = 0;
          dbg_preload_done_cycle[tile] = 0;
          dbg_compute_issue_cycle[tile] = 0;
          dbg_compute_done_cycle[tile] = 0;
          dbg_store_issue_cycle[tile] = 0;
          dbg_store_done_cycle[tile] = 0;
          dbg_tile_compute_pipeline_cycles[tile] = 0;
          dbg_tile_preload_compute_overlap[tile] = 0;
          dbg_tile_store_next_compute_overlap[tile] = 0;
          dbg_tile_store_next_load_overlap[tile] = 0;
          dbg_tile_store_later_load_overlap[tile] = 0;
        end
      end else begin
        int active_count;
        bit class_mask[DBG_CLASS_COUNT];
        bit later_load;
        bit later_compute;
        bit preload_next_active;
        bit compute_this_active;
        bit compute_next_active;
        bit store_this_active;
        bit load_next_active;
        bit load_later_active;

        dbg_cycle_q++;

        // Sample the pre-edge active set.  A completion at this edge therefore
        // contributes the final cycle of [issue_cycle, done_cycle).
        active_count = 0;
        for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
          if (dbg_cmd_record[uid].issued
           && !dbg_cmd_record[uid].completed)
            active_count++;
        end
        if (active_count > dbg_max_concurrent_q)
          dbg_max_concurrent_q = active_count;
        if (dbg_compute_active_i === 1'b1)
          dbg_compute_pipeline_cycles_q++;

        for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id) begin
          class_mask[class_id] = 0;
          for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
            if (dbg_cmd_record[uid].issued
             && !dbg_cmd_record[uid].completed
             && (dbg_cmd_record[uid].class_id == class_id))
              class_mask[class_id] = 1;
          end
          if (class_mask[class_id])
            dbg_class_active_cycles_q[class_id]++;
        end

        for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
          if (dbg_cmd_record[uid].issued
           && !dbg_cmd_record[uid].completed) begin
            logic [DBG_CLASS_COUNT-1:0] peer_class_mask;
            peer_class_mask = '0;
            later_load = 0;
            later_compute = 0;
            for (int peer = 0; peer < dbg_record_count_q; ++peer) begin
              if ((peer != uid)
               && dbg_cmd_record[peer].issued
               && !dbg_cmd_record[peer].completed) begin
                peer_class_mask[dbg_cmd_record[peer].class_id] = 1'b1;
                if ((dbg_cmd_record[peer].tile > dbg_cmd_record[uid].tile)
                 && dbg_is_dram_load(dbg_cmd_record[peer].class_id))
                  later_load = 1;
                if ((dbg_cmd_record[peer].tile > dbg_cmd_record[uid].tile)
                 && (dbg_cmd_record[peer].class_id == DBG_C_COMPUTE_ARM))
                  later_compute = 1;
              end
            end
            if (|peer_class_mask)
              dbg_cmd_record[uid].overlap_any_cycles++;
            for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id) begin
              if (peer_class_mask[class_id])
                dbg_overlap_class[uid][class_id]++;
            end
            if (dbg_compute_active_i === 1'b1)
              dbg_cmd_record[uid].overlap_compute_pipeline_cycles++;
            if (later_load)
              dbg_cmd_record[uid].overlap_later_tile_load_cycles++;
            if (later_compute && (dbg_compute_active_i === 1'b1))
              dbg_cmd_record[uid].overlap_later_tile_compute_cycles++;
          end
        end

        for (int tile = 0; tile <= dbg_max_tile_q; ++tile) begin
          preload_next_active = 0;
          compute_this_active = 0;
          compute_next_active = 0;
          store_this_active = 0;
          load_next_active = 0;
          load_later_active = 0;
          for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
            if (dbg_cmd_record[uid].issued
             && !dbg_cmd_record[uid].completed) begin
              if (dbg_is_dram_load(dbg_cmd_record[uid].class_id)
               && (dbg_cmd_record[uid].tile == tile + 1)) begin
                preload_next_active = 1;
                load_next_active = 1;
              end
              if (dbg_is_dram_load(dbg_cmd_record[uid].class_id)
               && (dbg_cmd_record[uid].tile > tile))
                load_later_active = 1;
              if ((dbg_cmd_record[uid].class_id == DBG_C_COMPUTE_ARM)
               && (dbg_cmd_record[uid].tile == tile))
                compute_this_active = 1;
              if ((dbg_cmd_record[uid].class_id == DBG_C_COMPUTE_ARM)
               && (dbg_cmd_record[uid].tile == tile + 1))
                compute_next_active = 1;
              if ((dbg_cmd_record[uid].class_id == DBG_C_DRAM_OUTPUT_STORE)
               && (dbg_cmd_record[uid].tile == tile))
                store_this_active = 1;
            end
          end
          if (compute_this_active && (dbg_compute_active_i === 1'b1)) begin
            dbg_tile_compute_pipeline_cycles[tile]++;
            if (preload_next_active)
              dbg_tile_preload_compute_overlap[tile]++;
          end
          if (store_this_active && compute_next_active
           && (dbg_compute_active_i === 1'b1))
            dbg_tile_store_next_compute_overlap[tile]++;
          if (store_this_active && load_next_active)
            dbg_tile_store_next_load_overlap[tile]++;
          if (store_this_active && load_later_active)
            dbg_tile_store_later_load_overlap[tile]++;
        end

        for (int child = 0; child < N_CHILDREN; ++child) begin
          if (!child_q_empty_v[child] && !child_issue_fire_v[child]) begin
            int head_uid;
            head_uid = dbg_q_uid[child][dbg_q_head[child]];
            if (!child_deps_ready_v[child])
              dbg_cmd_record[head_uid].dependency_blocked_cycles++;
            else
              dbg_cmd_record[head_uid].executor_blocked_cycles++;
          end
        end

        // Retire first so a non-DMA child may complete and accept its next
        // in-order command on the same edge without losing the old UID.
        for (int child = 0; child < N_CHILDREN; ++child) begin
          if (child_completion_pop_v[child]) begin
            int uid;
            if (child == DMA_CHILD_INDEX) begin
              int tag;
              tag = gemm_ctrl_if.dma_flag.done_tag;
              assert (dbg_dma_uid_valid[tag])
                else $fatal(1, "%s: command ledger missing DMA tag %0d",
                            INSTANCE_ID, tag);
              uid = dbg_dma_uid_by_tag[tag];
              dbg_dma_uid_valid[tag] = 0;
            end else begin
              assert (dbg_active_uid_valid[child])
                else $fatal(1, "%s: command ledger missing active child %0d",
                            INSTANCE_ID, child);
              uid = dbg_active_uid[child];
              dbg_active_uid_valid[child] = 0;
            end
            assert (!dbg_cmd_record[uid].completed)
              else $fatal(1, "%s: command UID %0d completed twice",
                          INSTANCE_ID, uid);
            dbg_cmd_record[uid].completed = 1;
            dbg_cmd_record[uid].done_cycle = dbg_cycle_q;
            dbg_done_count_q++;
            if (dbg_is_dram_load(dbg_cmd_record[uid].class_id)) begin
              dbg_preload_done_cycle[dbg_cmd_record[uid].tile]
                  = dbg_cycle_q;
            end else if (dbg_cmd_record[uid].class_id == DBG_C_COMPUTE_ARM) begin
              dbg_compute_done_cycle[dbg_cmd_record[uid].tile]
                  = dbg_cycle_q;
            end else if (dbg_cmd_record[uid].class_id
                         == DBG_C_DRAM_OUTPUT_STORE) begin
              dbg_store_done_cycle[dbg_cmd_record[uid].tile]
                  = dbg_cycle_q;
            end
          end
        end

        for (int child = 0; child < N_CHILDREN; ++child) begin
          if (child_issue_fire_v[child]) begin
            int uid;
            uid = dbg_q_uid[child][dbg_q_head[child]];
            assert (dbg_q_count[child] != 0)
              else $fatal(1, "%s: debug command FIFO child %0d underflow",
                          INSTANCE_ID, child);
            assert (dbg_cmd_record[uid].emitted
                 && !dbg_cmd_record[uid].issued)
              else $fatal(1, "%s: command UID %0d issued twice or before emit",
                          INSTANCE_ID, uid);
            dbg_cmd_record[uid].issued = 1;
            dbg_cmd_record[uid].issue_cycle = dbg_cycle_q;
            dbg_issue_count_q++;
            if (child == DMA_CHILD_INDEX) begin
              int tag;
              tag = dma_issue_tag;
              assert (!dbg_dma_uid_valid[tag])
                else $fatal(1, "%s: DMA tag %0d reused before completion",
                            INSTANCE_ID, tag);
              dbg_dma_uid_valid[tag] = 1;
              dbg_dma_uid_by_tag[tag] = uid;
              dbg_cmd_record[uid].dma_tag = GEMM_DMA_TAG_WIDTH'(tag);
              $display("GEMM_CMD_DMA_MAP | {inst=%s, job=%0d, uid=%0d, tag=%0d, accept=%0d}",
                       INSTANCE_ID, dbg_job_seq_q, uid, tag, dbg_cycle_q);
            end else begin
              assert (!dbg_active_uid_valid[child])
                else $fatal(1, "%s: non-DMA child %0d has two active UIDs",
                            INSTANCE_ID, child);
              dbg_active_uid_valid[child] = 1;
              dbg_active_uid[child] = uid;
            end
            if (dbg_is_dram_load(dbg_cmd_record[uid].class_id)) begin
              if (!dbg_preload_seen[dbg_cmd_record[uid].tile]) begin
                dbg_preload_seen[dbg_cmd_record[uid].tile] = 1;
                dbg_preload_issue_cycle[dbg_cmd_record[uid].tile]
                    = dbg_cycle_q;
              end
            end else if (dbg_cmd_record[uid].class_id == DBG_C_COMPUTE_ARM) begin
              if (!dbg_compute_seen[dbg_cmd_record[uid].tile]) begin
                dbg_compute_seen[dbg_cmd_record[uid].tile] = 1;
                dbg_compute_issue_cycle[dbg_cmd_record[uid].tile]
                    = dbg_cycle_q;
              end
            end else if (dbg_cmd_record[uid].class_id
                         == DBG_C_DRAM_OUTPUT_STORE) begin
              if (!dbg_store_seen[dbg_cmd_record[uid].tile]) begin
                dbg_store_seen[dbg_cmd_record[uid].tile] = 1;
                dbg_store_issue_cycle[dbg_cmd_record[uid].tile]
                    = dbg_cycle_q;
              end
            end
            dbg_q_head[child]
                = (dbg_q_head[child] + 1 == dbg_child_depth(child))
                ? 0 : dbg_q_head[child] + 1;
          end
        end

        if (fsm_cmd_accept) begin
          int uid;
          int child;
          uid = dbg_record_count_q;
          child = fsm_target_child;
          assert (dbg_fsm_meta_valid)
            else $fatal(1, "%s: FSM command emitted without debug metadata",
                        INSTANCE_ID);
          assert (uid < DBG_CMD_MAX)
            else $fatal(1, "%s: command ledger overflow at %0d records",
                        INSTANCE_ID, uid);
          assert (dbg_fsm_meta_tile < DBG_TILE_MAX)
            else $fatal(1, "%s: tile metadata %0d exceeds DBG_TILE_MAX=%0d",
                        INSTANCE_ID, dbg_fsm_meta_tile, DBG_TILE_MAX);
          assert (dbg_q_count[child] < dbg_child_depth(child))
            else $fatal(1, "%s: debug command FIFO child %0d overflow",
                        INSTANCE_ID, child);

          dbg_cmd_record[uid].emitted = 1;
          dbg_cmd_record[uid].issued = 0;
          dbg_cmd_record[uid].completed = 0;
          dbg_cmd_record[uid].class_id
              = dbg_command_class(gemm_fsm_if.ctrl.cmd);
          dbg_cmd_record[uid].child = 3'(child);
          dbg_cmd_record[uid].state = dbg_fsm_meta_state;
          dbg_cmd_record[uid].phase = dbg_fsm_meta_phase;
          dbg_cmd_record[uid].tile = dbg_fsm_meta_tile;
          dbg_cmd_record[uid].nt = dbg_fsm_meta_nt;
          dbg_cmd_record[uid].mt = dbg_fsm_meta_mt;
          dbg_cmd_record[uid].kt = dbg_fsm_meta_kt;
          dbg_cmd_record[uid].mxu_nt = dbg_fsm_meta_mxu_nt;
          dbg_cmd_record[uid].mxu_kt = dbg_fsm_meta_mxu_kt;
          dbg_cmd_record[uid].tile_buf = dbg_fsm_meta_tile_buf;
          dbg_cmd_record[uid].mxu_buf = dbg_fsm_meta_mxu_buf;
          dbg_cmd_record[uid].acc_group = dbg_fsm_meta_acc_group;
          dbg_cmd_record[uid].generation = dbg_fsm_meta_generation;
          dbg_cmd_record[uid].dma_tag = '0;
          dbg_cmd_record[uid].cmd = gemm_fsm_if.ctrl.cmd;
          dbg_cmd_record[uid].emit_cycle = dbg_cycle_q;
          dbg_cmd_record[uid].issue_cycle = 0;
          dbg_cmd_record[uid].done_cycle = 0;
          dbg_cmd_record[uid].dependency_blocked_cycles = 0;
          dbg_cmd_record[uid].executor_blocked_cycles = 0;
          dbg_cmd_record[uid].overlap_any_cycles = 0;
          dbg_cmd_record[uid].overlap_compute_pipeline_cycles = 0;
          dbg_cmd_record[uid].overlap_later_tile_load_cycles = 0;
          dbg_cmd_record[uid].overlap_later_tile_compute_cycles = 0;
          for (int class_id = 0; class_id < DBG_CLASS_COUNT; ++class_id)
            dbg_overlap_class[uid][class_id] = 0;
          dbg_q_uid[child][dbg_q_tail[child]] = uid;
          dbg_q_tail[child]
              = (dbg_q_tail[child] + 1 == dbg_child_depth(child))
              ? 0 : dbg_q_tail[child] + 1;
          dbg_record_count_q++;
          if (dbg_fsm_meta_tile > dbg_max_tile_q)
            dbg_max_tile_q = dbg_fsm_meta_tile;
        end

        for (int child = 0; child < N_CHILDREN; ++child) begin
          unique case ({child_q_push_v[child], child_q_pop_v[child]})
            2'b10: dbg_q_count[child]++;
            2'b01: dbg_q_count[child]--;
            default: begin
            end
          endcase
        end

        if (invocation_complete) begin
          int incomplete;
          incomplete = 0;
          for (int uid = 0; uid < dbg_record_count_q; ++uid) begin
            assert (dbg_cmd_record[uid].emitted
                 && dbg_cmd_record[uid].issued
                 && dbg_cmd_record[uid].completed)
              else begin
                incomplete++;
                $error("%s: incomplete command UID %0d at invocation drain",
                       INSTANCE_ID, uid);
              end
            assert (dbg_cmd_record[uid].emit_cycle
                 <= dbg_cmd_record[uid].issue_cycle)
              else $fatal(1, "%s: UID %0d issue preceded emit", INSTANCE_ID, uid);
            assert (dbg_cmd_record[uid].issue_cycle
                 <= dbg_cmd_record[uid].done_cycle)
              else $fatal(1, "%s: UID %0d done preceded issue", INSTANCE_ID, uid);
            assert (dbg_cmd_record[uid].overlap_any_cycles
                 <= (dbg_cmd_record[uid].done_cycle
                    - dbg_cmd_record[uid].issue_cycle))
              else $fatal(1, "%s: UID %0d overlap exceeds service interval",
                          INSTANCE_ID, uid);
          end
          for (int child = 0; child < N_CHILDREN; ++child) begin
            assert ((dbg_q_count[child] == 0)
                 && !dbg_active_uid_valid[child])
              else $fatal(1, "%s: child %0d debug state not drained",
                          INSTANCE_ID, child);
          end
          assert (dbg_record_count_q == dbg_issue_count_q)
            else $fatal(1, "%s: emitted/issued count mismatch", INSTANCE_ID);
          assert (dbg_record_count_q == dbg_done_count_q)
            else $fatal(1, "%s: emitted/completed count mismatch", INSTANCE_ID);
          assert (incomplete == 0)
            else $fatal(1, "%s: invocation has %0d incomplete commands",
                        INSTANCE_ID, incomplete);
          dbg_dump_invocation();
          dbg_job_seq_q++;
        end
      end
    end
`endif
`endif

`ifndef SYNTHESIS
    logic [31:0] dbg_invocation_active_cycles_q;
    logic [31:0] dbg_fifo_full_blocks_ready_other_child_q;
    logic [31:0] dbg_w_arm_issued_q [2];
    logic [31:0] dbg_sc_arm_issued_q [2];
    logic [31:0] dbg_zp_arm_issued_q [2];
    logic dbg_cmd_stage_blocked_q;
    logic [2:0] dbg_cmd_stage_child_q;
    gemm_unified_cmd_t dbg_cmd_stage_cmd_q;

    always_ff @(posedge clk) begin
      if (reset || cfg_fire) begin
        dbg_invocation_active_cycles_q <= '0;
        dbg_fifo_full_blocks_ready_other_child_q <= '0;
        dbg_cmd_stage_blocked_q <= 1'b0;
        dbg_cmd_stage_child_q <= '0;
        dbg_cmd_stage_cmd_q <= '0;
        for (int bank = 0; bank < 2; ++bank)
          dbg_w_arm_issued_q[bank] <= 32'd0;
        for (int bank = 0; bank < 2; ++bank) begin
          dbg_sc_arm_issued_q[bank] <= 32'd0;
          dbg_zp_arm_issued_q[bank] <= 32'd0;
        end
      end else begin
        dbg_cmd_stage_blocked_q <= cmd_stage_valid_q && !cmd_stage_drain;
        dbg_cmd_stage_child_q <= cmd_stage_child_q;
        dbg_cmd_stage_cmd_q <= cmd_stage_cmd_q;
        if (invocation_active_q) begin
          dbg_invocation_active_cycles_q
              <= dbg_invocation_active_cycles_q + 1;
          if (fsm_pending_work
           && child_q_full_v[fsm_pending_child]
           && (|(child_q_empty_v & ~child_q_full_v))) begin
            dbg_fifo_full_blocks_ready_other_child_q
                <= dbg_fifo_full_blocks_ready_other_child_q + 1;
          end
          if (child_issue_fire_v[0]
           && (child_q_cmd[0].instr[3:0] == 4'd7)) begin
            dbg_w_arm_issued_q[child_q_cmd[0].flags[2]]
                <= dbg_w_arm_issued_q[child_q_cmd[0].flags[2]] + 32'd1;
            dbg_sc_arm_issued_q[child_q_cmd[0].flags[1]]
                <= dbg_sc_arm_issued_q[child_q_cmd[0].flags[1]] + 32'd1;
            dbg_zp_arm_issued_q[child_q_cmd[0].flags[0]]
                <= dbg_zp_arm_issued_q[child_q_cmd[0].flags[0]] + 32'd1;
          end
        end
      end
    end

    always_ff @(posedge clk) begin
      if (!reset) begin
        if (dbg_cmd_stage_blocked_q) begin
          assert (cmd_stage_valid_q
               && (cmd_stage_child_q == dbg_cmd_stage_child_q)
               && (cmd_stage_cmd_q == dbg_cmd_stage_cmd_q))
            else $fatal(1, "%s: blocked command stage payload changed",
                        INSTANCE_ID);
        end
        assert ((|child_q_push_v) == cmd_stage_drain)
          else $fatal(1, "%s: command-stage drain/push mismatch",
                      INSTANCE_ID);
        if (cmd_stage_drain) begin
          assert ($onehot(child_q_push_v)
               && cmd_stage_target_valid
               && child_q_push_v[cmd_stage_child_q])
            else $fatal(1, "%s: command-stage drain did not push exact child",
                        INSTANCE_ID);
          assert (scheduler_cmd_fire
               == (cmd_stage_child_q <= ZP_CHILD_INDEX))
            else $fatal(1,
                "%s: command-stage scheduler admission/drain mismatch",
                INSTANCE_ID);
        end
        assert ((weight_consume_value0_o
                  == sync_regs_q[RID_W_CONSUME0])
             && (weight_consume_value1_o
                  == sync_regs_q[RID_W_CONSUME1])
             && (scale_consume_value0_o
                  == effective_sync[RID_SC_CONSUME0])
             && (scale_consume_value1_o
                  == effective_sync[RID_SC_CONSUME1])
             && (zero_point_consume_value0_o
                  == effective_sync[RID_ZP_CONSUME0])
             && (zero_point_consume_value1_o
                  == effective_sync[RID_ZP_CONSUME1])
             && (gemm_ctrl_if.input_acc_free_value[0]
                  == effective_sync[RID_ACC_FREE0])
             && (gemm_ctrl_if.input_acc_free_value[1]
                  == effective_sync[RID_ACC_FREE1]))
          else $fatal(1, "%s: direct resource fold diverged from sync state",
                      INSTANCE_ID);
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
        if (gemm_fsm_if.ctrl.start) begin
          assert (fsm_target_valid
               && (fsm_decoded_child == fsm_target_child))
            else $fatal(1,
                "%s: FSM target/opcode mismatch child=%0d decoded=%0d op=0x%0h",
                INSTANCE_ID, fsm_target_child, fsm_decoded_child,
                gemm_fsm_if.ctrl.cmd.instr[3:0]);
        end

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


        if (gemm_sync_slv_if[1].valid) begin
          assert (gemm_sync_slv_if[1].ready)
            else $fatal(1, "%s: consume event node 1 backpressured",
                        INSTANCE_ID);
          assert (gemm_sync_slv_if[1].reg_idx < NUM_SYNC_REGS)
            else $fatal(1, "%s: consume event node 1 RID out of range: %0d",
                        INSTANCE_ID, gemm_sync_slv_if[1].reg_idx);
          assert (gemm_sync_slv_if[1].value == 32'd1)
            else $fatal(1, "%s: consume event node 1 value is not one",
                        INSTANCE_ID);
        end
        if (gemm_sync_slv_if[2].valid) begin
          assert (gemm_sync_slv_if[2].ready)
            else $fatal(1, "%s: consume event node 2 backpressured",
                        INSTANCE_ID);
          assert (gemm_sync_slv_if[2].reg_idx < NUM_SYNC_REGS)
            else $fatal(1, "%s: consume event node 2 RID out of range: %0d",
                        INSTANCE_ID, gemm_sync_slv_if[2].reg_idx);
          assert (gemm_sync_slv_if[2].value == 32'd1)
            else $fatal(1, "%s: consume event node 2 value is not one",
                        INSTANCE_ID);
        end
        if (gemm_sync_slv_if[3].valid) begin
          assert (gemm_sync_slv_if[3].ready)
            else $fatal(1, "%s: consume event node 3 backpressured",
                        INSTANCE_ID);
          assert (gemm_sync_slv_if[3].reg_idx < NUM_SYNC_REGS)
            else $fatal(1, "%s: consume event node 3 RID out of range: %0d",
                        INSTANCE_ID, gemm_sync_slv_if[3].reg_idx);
          assert (gemm_sync_slv_if[3].value == 32'd1)
            else $fatal(1, "%s: consume event node 3 value is not one",
                        INSTANCE_ID);
        end

        if (gemm_sync_slv_if[1].valid) begin
          assert ((gemm_sync_slv_if[1].reg_idx == RID_W_CONSUME0)
               || (gemm_sync_slv_if[1].reg_idx == RID_W_CONSUME1))
            else $fatal(1, "%s: weight consume event used RID %0d",
                        INSTANCE_ID, gemm_sync_slv_if[1].reg_idx);
        end
        if (gemm_sync_slv_if[2].valid) begin
          assert ((gemm_sync_slv_if[2].reg_idx == RID_SC_CONSUME0)
               || (gemm_sync_slv_if[2].reg_idx == RID_SC_CONSUME1))
            else $fatal(1, "%s: scale consume event used RID %0d",
                        INSTANCE_ID, gemm_sync_slv_if[2].reg_idx);
        end
        if (gemm_sync_slv_if[3].valid) begin
          assert ((gemm_sync_slv_if[3].reg_idx == RID_ZP_CONSUME0)
               || (gemm_sync_slv_if[3].reg_idx == RID_ZP_CONSUME1))
            else $fatal(1, "%s: zero-point consume event used RID %0d",
                        INSTANCE_ID, gemm_sync_slv_if[3].reg_idx);
        end

        assert (!(gemm_sync_slv_if[1].valid
               && gemm_sync_slv_if[2].valid
               && (gemm_sync_slv_if[1].reg_idx
                   == gemm_sync_slv_if[2].reg_idx)))
          else $fatal(1, "%s: simultaneous consume collision nodes 1/2 rid=%0d",
                      INSTANCE_ID, gemm_sync_slv_if[1].reg_idx);
        assert (!(gemm_sync_slv_if[1].valid
               && gemm_sync_slv_if[3].valid
               && (gemm_sync_slv_if[1].reg_idx
                   == gemm_sync_slv_if[3].reg_idx)))
          else $fatal(1, "%s: simultaneous consume collision nodes 1/3 rid=%0d",
                      INSTANCE_ID, gemm_sync_slv_if[1].reg_idx);
        assert (!(gemm_sync_slv_if[2].valid
               && gemm_sync_slv_if[3].valid
               && (gemm_sync_slv_if[2].reg_idx
                   == gemm_sync_slv_if[3].reg_idx)))
          else $fatal(1, "%s: simultaneous consume collision nodes 2/3 rid=%0d",
                      INSTANCE_ID, gemm_sync_slv_if[2].reg_idx);

        for (int child = 0; child < N_CHILDREN; ++child) begin
          if (child_completion_pop_v[child]
           && child_inflight_head[child].valid) begin
            unique case (child)
              0: assert (((child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_G0))
                       || (child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_G1)))
                      && !child_inflight_head[child].set_mode
                      && (child_inflight_head[child].value == 32'd1))
                else $fatal(1,
                    "%s: child 0 violated G0/G1 increment ownership",
                    INSTANCE_ID);
              1: assert (((child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W0))
                       || (child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_W1)))
                      && child_inflight_head[child].set_mode)
                else $fatal(1,
                    "%s: child 1 violated W0/W1 set ownership",
                    INSTANCE_ID);
              2: assert (((child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_SC0))
                       || (child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_SC1)))
                      && child_inflight_head[child].set_mode)
                else $fatal(1,
                    "%s: child 2 violated SC0/SC1 set ownership",
                    INSTANCE_ID);
              3: assert (((child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP0))
                       || (child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ZP1)))
                      && child_inflight_head[child].set_mode)
                else $fatal(1,
                    "%s: child 3 violated ZP0/ZP1 set ownership",
                    INSTANCE_ID);
              4: assert (((child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE0))
                       || (child_inflight_head[child].reg_id
                           == GEMM_SYNC_REG_ID_WIDTH'(RID_ACC_FREE1)))
                      && child_inflight_head[child].set_mode)
                else $fatal(1,
                    "%s: child 4 violated ACC_FREE0/1 set ownership",
                    INSTANCE_ID);
              5: assert ((((child_inflight_head[child].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(RID_T0))
                         || (child_inflight_head[child].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(RID_T1)))
                        && child_inflight_head[child].set_mode)
                       || ((child_inflight_head[child].reg_id
                            == GEMM_SYNC_REG_ID_WIDTH'(RID_O))
                        && !child_inflight_head[child].set_mode
                        && (child_inflight_head[child].value == 32'd1)))
                else $fatal(1,
                    "%s: child 5 violated T0/T1 set or O increment ownership",
                    INSTANCE_ID);
              default: $fatal(1,
                  "%s: completion from unsupported child %0d",
                  INSTANCE_ID, child);
            endcase
          end
        end
        assert (!(cfg_fire
               && (gemm_sync_slv_if[1].valid
                || gemm_sync_slv_if[2].valid
                || gemm_sync_slv_if[3].valid)))
          else $fatal(1, "%s: invocation clear overlapped consume event",
                      INSTANCE_ID);

        for (int bank = 0; bank < 2; ++bank) begin
          assert (effective_sync[rid_w_consume_for_idx(gemm_wreg_idx_t'(bank))]
               <= dbg_w_arm_issued_q[bank]
                + ((child_issue_fire_v[0]
                 && (child_q_cmd[0].instr[3:0] == 4'd7)
                 && (child_q_cmd[0].flags[2] == bank)) ? 32'd1 : 32'd0))
            else $fatal(1, "%s: weight consume count exceeded issued count for buffer %0d",
                        INSTANCE_ID, bank);
          if (invocation_complete) begin
            assert (effective_sync[
                     rid_w_consume_for_idx(gemm_wreg_idx_t'(bank))]
                    == dbg_w_arm_issued_q[bank])
              else $fatal(1,
                  "%s: invocation ended with incomplete Weight consume count for bank %0d",
                  INSTANCE_ID, bank);
          end
        end
        for (int bank = 0; bank < 2; ++bank) begin
          assert (effective_sync[bank ? RID_SC_CONSUME1 : RID_SC_CONSUME0]
               <= dbg_sc_arm_issued_q[bank]
                + ((child_issue_fire_v[0]
                 && (child_q_cmd[0].instr[3:0] == 4'd7)
                 && (child_q_cmd[0].flags[1] == bank)) ? 32'd1 : 32'd0))
            else $fatal(1, "%s: scale consume count exceeded issued count for buffer %0d",
                        INSTANCE_ID, bank);
          assert (effective_sync[bank ? RID_ZP_CONSUME1 : RID_ZP_CONSUME0]
               <= dbg_zp_arm_issued_q[bank]
                + ((child_issue_fire_v[0]
                 && (child_q_cmd[0].instr[3:0] == 4'd7)
                 && (child_q_cmd[0].flags[0] == bank)) ? 32'd1 : 32'd0))
            else $fatal(1, "%s: zero-point consume count exceeded issued count for buffer %0d",
                        INSTANCE_ID, bank);
          if (invocation_complete) begin
            assert ((effective_sync[bank ? RID_SC_CONSUME1 : RID_SC_CONSUME0]
                     == dbg_sc_arm_issued_q[bank])
                 && (effective_sync[bank ? RID_ZP_CONSUME1 : RID_ZP_CONSUME0]
                     == dbg_zp_arm_issued_q[bank]))
              else $fatal(1, "%s: invocation ended with incomplete consume counts for buffer %0d",
                          INSTANCE_ID, bank);
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

    `VX_STATIC_ASSERT(N_CHILDREN == 6,
      ("VX_gemm_ctrl command schedule requires six children"));
    `VX_STATIC_ASSERT(N_NODE == 6,
      ("VX_gemm_ctrl command schedule requires six completion sources"));
    `VX_STATIC_ASSERT(CHILD_QUEUE_DEPTH >= 2,
      ("VX_gemm_ctrl child queue depth must be at least two"));
    `VX_STATIC_ASSERT(DMA_CHILD_QUEUE_DEPTH == DMA_INFLIGHT_DEPTH,
      ("VX_gemm_ctrl DMA child queue and tag scoreboard must both have eight entries"));
    `VX_STATIC_ASSERT((RID_T0 == 0) && (RID_W0 == 1) && (RID_SZ0 == 2)
                   && (RID_G0 == 3) && (RID_O == 4) && (RID_T1 == 5)
                   && (RID_W1 == 6) && (RID_SZ1 == 7) && (RID_G1 == 8)
                   && (RID_ACC_FREE0 == 9) && (RID_ACC_FREE1 == 10)
                   && (RID_SC0 == 11) && (RID_ZP0 == 12)
                   && (RID_SC1 == 13) && (RID_ZP1 == 14)
                   && (RID_W_CONSUME0 == 15) && (RID_W_CONSUME1 == 16)
                   && (RID_SC_CONSUME0 == 17)
                   && (RID_SC_CONSUME1 == 18)
                   && (RID_ZP_CONSUME0 == 19)
                   && (RID_ZP_CONSUME1 == 20),
      ("VX_gemm_ctrl sync RID encoding changed"));

endmodule

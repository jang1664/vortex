module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter  INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 6,
    parameter NUM_TMEM_BANKS = 8,
    parameter NUM_DMA_CHANNELS = 4,
    parameter int INPUT_SLOTS = 8,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        8
) (
    input wire              clk,
    input wire              reset,
    VX_lsu_mem_if.slave     mmio_if[N_MASTER],
    AXI_BUS.Master          dma_axi_m [NUM_DMA_CHANNELS]
);
    localparam N_NODE   = 6;
    localparam bit SLR_ENABLE = 1'b1;
    localparam int DMA_LAUNCH_DEPTH = SLR_ENABLE ? 2
                                  : (1 ? 2 : 1);
    localparam int I_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int W_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int SZ_GEMM_TAG_WIDTH = GEMM_BASE_TAG_WIDTH;
    localparam int MXU_KT = 16;
    localparam int MXU_NT = 16;
    localparam int TMEM_PHYSICAL_DATA_SIZE = ((16/8)*16);
    localparam int INPUT_NOTIFY_ON_WRITEBACK_FLAG = 5;
    localparam int OUTPUT_PROGRESS_REG_IDX = 43;
    VX_mem_bus_if # (
      .DATA_SIZE(((16/8)*16)),
      .TAG_WIDTH(I_GEMM_TAG_WIDTH)
    ) i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*4*4)/8)),
      .TAG_WIDTH(W_GEMM_TAG_WIDTH)
    ) w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*16)/8)),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*16)/8)),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16/8)*16)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16/8)*16)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*4*4)/8)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*16)/8)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16*16)/8)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(((16/8)*16)),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_o_gemm_bus_if ();
    VX_gemm_unit_v2_if gemm_unit_v2_if ();
    typedef struct packed {
        logic                 valid;
        logic                 ingress_complete;
        logic [64-1:0]     acc_base;
        logic [20:0]          packet_count;
        logic [20:0]          packet_index;
        logic                 is_accum;
        logic                 notify_on_writeback;
        logic                 quant_dir;
        gemm_wreg_idx_t       wreg_use_idx;
        gemm_qreg_idx_t       sreg_use_idx;
        gemm_qreg_idx_t       zreg_use_idx;
        gemm_wait_meta_t [3:0] admit_waits;
        logic [31:0]          seq_id;
    } input_cmd_context_t;
    localparam int INPUT_CONTEXT_DEPTH = 4;
    localparam int INPUT_CONTEXT_PTR_BITS = $clog2(INPUT_CONTEXT_DEPTH);
    localparam int INPUT_CONTEXT_COUNT_BITS
        = $clog2(INPUT_CONTEXT_DEPTH + 1);
    input_cmd_context_t input_cmd_ctx_r[INPUT_CONTEXT_DEPTH];
    input_cmd_context_t input_cmd_ctx;
    logic [INPUT_CONTEXT_PTR_BITS-1:0] input_admit_ptr_r;
    logic [INPUT_CONTEXT_PTR_BITS-1:0] input_complete_ptr_r;
    logic [INPUT_CONTEXT_PTR_BITS-1:0] input_context_tail_r;
    logic [INPUT_CONTEXT_COUNT_BITS-1:0] input_context_count_r;
    logic [31:0] input_next_sequence_r;
    VX_gemm_ctrl_if gemm_ctrl_if ();
    wire [31:0] weight_consume_value0;
    wire [31:0] weight_consume_value1;
    wire [31:0] scale_consume_value0;
    wire [31:0] scale_consume_value1;
    wire [31:0] zero_point_consume_value0;
    wire [31:0] zero_point_consume_value1;
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0]
        sched_source_priority [4];
    wire sched_input_source_enable;
    wire [3:0] sched_source_valid;
    wire [31:0] sched_source_work_seq [4];
    wire [31:0] sched_source_total_beats [4];
    wire [31:0] sched_source_request_beats [4];
    wire [31:0] sched_source_response_beats [4];
    wire [31:0] sched_source_writer_beats [4];
    wire [$clog2(INPUT_SLOTS + 1)-1:0] sched_input_slot_occupancy;
    wire [3:0] sched_fetch_complete;
    wire [31:0] sched_fetch_complete_work_seq [4];
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if scale_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if zero_point_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();
    VX_gemm_dma_ctrl_if gemm_dma_ctrl_if ();
    localparam int WEIGHT_BOUNDARY_DEPTH = 4;
    localparam int WEIGHT_BOUNDARY_PTR_BITS =
        $clog2(WEIGHT_BOUNDARY_DEPTH);
    localparam int WEIGHT_BOUNDARY_COUNT_BITS =
        $clog2(WEIGHT_BOUNDARY_DEPTH + 1);
    localparam int QPARAM_BOUNDARY_DEPTH = 4;
    localparam int QPARAM_BOUNDARY_PTR_BITS =
        $clog2(QPARAM_BOUNDARY_DEPTH);
    localparam int QPARAM_BOUNDARY_COUNT_BITS =
        $clog2(QPARAM_BOUNDARY_DEPTH + 1);
    logic [WEIGHT_BOUNDARY_DEPTH-1:0] weight_boundary_valid_r;
    logic [WEIGHT_BOUNDARY_DEPTH-1:0] weight_boundary_bus_done_r;
    logic [63:0] weight_boundary_writes_remaining_r[WEIGHT_BOUNDARY_DEPTH];
    logic [WEIGHT_BOUNDARY_PTR_BITS-1:0] weight_boundary_head_r;
    logic [WEIGHT_BOUNDARY_PTR_BITS-1:0] weight_boundary_bus_done_ptr_r;
    logic [WEIGHT_BOUNDARY_PTR_BITS-1:0] weight_boundary_tail_r;
    logic [WEIGHT_BOUNDARY_COUNT_BITS-1:0] weight_boundary_count_r;
    logic [QPARAM_BOUNDARY_DEPTH-1:0] scale_boundary_valid_r;
    logic [63:0] scale_boundary_writes_remaining_r[QPARAM_BOUNDARY_DEPTH];
    logic [QPARAM_BOUNDARY_PTR_BITS-1:0] scale_boundary_head_r;
    logic [QPARAM_BOUNDARY_PTR_BITS-1:0] scale_boundary_tail_r;
    logic [QPARAM_BOUNDARY_COUNT_BITS-1:0] scale_boundary_count_r;
    logic [QPARAM_BOUNDARY_DEPTH-1:0] zero_point_boundary_valid_r;
    logic [63:0] zero_point_boundary_writes_remaining_r[QPARAM_BOUNDARY_DEPTH];
    logic [QPARAM_BOUNDARY_PTR_BITS-1:0] zero_point_boundary_head_r;
    logic [QPARAM_BOUNDARY_PTR_BITS-1:0] zero_point_boundary_tail_r;
    logic [QPARAM_BOUNDARY_COUNT_BITS-1:0] zero_point_boundary_count_r;
    logic scale_register_write_done_q;
    logic zero_point_register_write_done_q;
    logic        output_write_active_r;
    logic        output_write_done_q;
    wire weight_dma_start = gemm_ctrl_if.weight_read_ctrl.start;
    wire scale_dma_start = gemm_ctrl_if.scale_read_ctrl.start;
    wire zero_point_dma_start = gemm_ctrl_if.zero_point_read_ctrl.start;
    localparam int COMMAND_BOUND_WIDTH = 16;
    localparam int WEIGHT_BYTES_PER_BOUND = MXU_KT * (MXU_NT >> 1);
    localparam int WEIGHT_BYTES_CONST_WIDTH = $clog2(WEIGHT_BYTES_PER_BOUND + 1);
    localparam int QPARAM_BYTES_PER_BOUND = MXU_NT * 2;
    localparam int QPARAM_BYTES_CONST_WIDTH = $clog2(QPARAM_BYTES_PER_BOUND + 1);
    wire [COMMAND_BOUND_WIDTH+WEIGHT_BYTES_CONST_WIDTH-1:0]
        weight_command_bytes_native
        = gemm_ctrl_if.weight_read_ctrl.cmd.bound
        * WEIGHT_BYTES_CONST_WIDTH'(WEIGHT_BYTES_PER_BOUND);
    wire [63:0] weight_command_bytes = 64'(weight_command_bytes_native);
    wire [63:0] weight_command_writes
        = (weight_command_bytes + 64'(((16*4*4)/8)) - 1)
        / 64'(((16*4*4)/8));
    wire [COMMAND_BOUND_WIDTH+QPARAM_BYTES_CONST_WIDTH-1:0]
        scale_command_bytes_native
        = gemm_ctrl_if.scale_read_ctrl.cmd.bound
        * QPARAM_BYTES_CONST_WIDTH'(QPARAM_BYTES_PER_BOUND);
    wire [63:0] scale_command_bytes = 64'(scale_command_bytes_native);
    wire [63:0] scale_command_writes
        = (scale_command_bytes + 64'(((16*16)/8)) - 1)
        / 64'(((16*16)/8));
    wire [COMMAND_BOUND_WIDTH+QPARAM_BYTES_CONST_WIDTH-1:0]
        zero_point_command_bytes_native
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.bound
        * QPARAM_BYTES_CONST_WIDTH'(QPARAM_BYTES_PER_BOUND);
    wire [63:0] zero_point_command_bytes
        = 64'(zero_point_command_bytes_native);
    wire [63:0] zero_point_command_writes
        = (zero_point_command_bytes + 64'(((16*16)/8)) - 1)
        / 64'(((16*16)/8));
    wire weight_last_register_write
        = gemm_unit_v2_if.weight_register_write
       && weight_boundary_valid_r[weight_boundary_head_r]
       && (weight_boundary_writes_remaining_r[weight_boundary_head_r]
           == 64'd1);
    wire scale_last_register_write
        = gemm_unit_v2_if.scale_register_write
       && scale_boundary_valid_r[scale_boundary_head_r]
       && (scale_boundary_writes_remaining_r[scale_boundary_head_r]
           == 64'd1);
    wire zero_point_last_register_write
        = gemm_unit_v2_if.zero_point_register_write
       && zero_point_boundary_valid_r[zero_point_boundary_head_r]
       && (zero_point_boundary_writes_remaining_r[zero_point_boundary_head_r]
           == 64'd1);
    VX_gemm_sync_if gemm_sync_if[N_NODE] ();
    VX_config_reg_if #(
      .NUM(44),
      .DW (32)
    ) issue_if();
    VX_node_done_if done_if();
    wire output_store_done;
    wire progress_update_valid;
    wire [4-1:0] progress_update_entry_id;
    wire [31:0] progress_update_value;
    wire input_cmd_start = gemm_ctrl_if.input_read_ctrl.start;
    wire input_packet_fire = i_gemm_bus_if.req_valid
                           && i_gemm_bus_if.req_ready;
    wire input_last_admission = input_packet_fire
                              && gemm_unit_v2_if.packet_ctrl.last;
    wire input_context_full
        = input_context_count_r
       == INPUT_CONTEXT_COUNT_BITS'(INPUT_CONTEXT_DEPTH);
    wire input_admit_context_valid
        = input_cmd_ctx_r[input_admit_ptr_r].valid;
    wire input_completion_context_valid
        = input_cmd_ctx_r[input_complete_ptr_r].valid;
    wire completion_head_ingress_complete
        = input_cmd_ctx_r[input_complete_ptr_r].ingress_complete;
    wire normal_input_complete
        = input_completion_context_valid
       && !input_cmd_ctx_r[input_complete_ptr_r].notify_on_writeback
       && completion_head_ingress_complete;
    wire tagged_final_writeback
        = input_completion_context_valid
       && input_cmd_ctx_r[input_complete_ptr_r].notify_on_writeback
       && input_cmd_ctx_r[input_complete_ptr_r].ingress_complete
       && gemm_unit_v2_if.tagged_final_writeback;
    wire input_cmd_done = normal_input_complete || tagged_final_writeback;
    wire input_context_can_accept = !input_context_full || input_cmd_done;
    wire input_w_wait_rid_matches
        = ((!input_cmd_ctx.wreg_use_idx)
        && (input_cmd_ctx.admit_waits[0].reg_id
            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W0)))
       || ((input_cmd_ctx.wreg_use_idx)
        && (input_cmd_ctx.admit_waits[0].reg_id
            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_W1)));
    wire input_sc_wait_rid_matches
        = input_cmd_ctx.admit_waits[1].reg_id
       == GEMM_SYNC_REG_ID_WIDTH'(input_cmd_ctx.sreg_use_idx
                                  ? GEMM_RID_SC1 : GEMM_RID_SC0);
    wire input_zp_wait_rid_matches
        = input_cmd_ctx.admit_waits[2].reg_id
       == GEMM_SYNC_REG_ID_WIDTH'(input_cmd_ctx.zreg_use_idx
                                  ? GEMM_RID_ZP1 : GEMM_RID_ZP0);
    wire input_acc_wait_rid_matches
        = (input_cmd_ctx.admit_waits[3].reg_id
           == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE0))
       || (input_cmd_ctx.admit_waits[3].reg_id
           == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE1));
    wire [31:0] input_acc_free_value
        = gemm_ctrl_if.input_acc_free_value[
            input_cmd_ctx.admit_waits[3].reg_id
            == GEMM_SYNC_REG_ID_WIDTH'(GEMM_RID_ACC_FREE1)];
    wire input_acc_free_ready = input_cmd_ctx.admit_waits[3].valid
        && input_acc_wait_rid_matches
        && (input_acc_free_value >= input_cmd_ctx.admit_waits[3].target);
    wire input_admission_ready = input_admit_context_valid
        && input_cmd_ctx.admit_waits[0].valid
        && input_w_wait_rid_matches
        && input_cmd_ctx.admit_waits[1].valid
        && input_sc_wait_rid_matches
        && input_cmd_ctx.admit_waits[2].valid
        && input_zp_wait_rid_matches
        && input_acc_free_ready;
    wire [64-1:0] input_packet_addr_full
        = input_cmd_ctx.acc_base
        + 64'(input_cmd_ctx.packet_index * ((32/8)*16));
    wire [$clog2(((1024) * (((32/8)*16)) * 4))-1:0] input_packet_addr
        = input_packet_addr_full[$clog2(((1024) * (((32/8)*16)) * 4))-1:0];
    always_comb begin
        input_cmd_ctx = input_cmd_ctx_r[input_admit_ptr_r];
    end
    always_comb begin
        gemm_unit_v2_if.packet_ctrl = '0;
        gemm_unit_v2_if.packet_ctrl.valid = i_gemm_bus_if.req_valid;
        gemm_unit_v2_if.packet_ctrl.acc_rd_en = input_cmd_ctx.is_accum;
        gemm_unit_v2_if.packet_ctrl.acc_wr_en = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_rd_addr = input_packet_addr;
        gemm_unit_v2_if.packet_ctrl.acc_wr_addr = input_packet_addr;
        gemm_unit_v2_if.packet_ctrl.quant_dir = input_cmd_ctx.quant_dir;
        gemm_unit_v2_if.packet_ctrl.wreg_use_idx
            = input_cmd_ctx.wreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.sreg_use_idx
            = input_cmd_ctx.sreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.zreg_use_idx
            = input_cmd_ctx.zreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.w_load_target
            = input_cmd_ctx.admit_waits[0].target;
        gemm_unit_v2_if.packet_ctrl.s_load_target
            = input_cmd_ctx.admit_waits[1].target;
        gemm_unit_v2_if.packet_ctrl.z_load_target
            = input_cmd_ctx.admit_waits[2].target;
        gemm_unit_v2_if.packet_ctrl.work_seq = input_cmd_ctx.seq_id;
        gemm_unit_v2_if.packet_ctrl.is_load = !input_cmd_ctx.is_accum;
        gemm_unit_v2_if.packet_ctrl.notify_on_writeback
            = input_cmd_ctx.notify_on_writeback;
        gemm_unit_v2_if.packet_ctrl.last
            = (input_cmd_ctx.packet_count != 0)
           && (input_cmd_ctx.packet_index
            == input_cmd_ctx.packet_count - 1'b1);
        gemm_unit_v2_if.input_admission_ready = input_admission_ready;
        gemm_unit_v2_if.w_load_value = gemm_ctrl_if.input_w_load_value;
        gemm_unit_v2_if.s_load_value = gemm_ctrl_if.input_sc_load_value;
        gemm_unit_v2_if.z_load_value = gemm_ctrl_if.input_zp_load_value;
    end
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            input_admit_ptr_r <= '0;
            input_complete_ptr_r <= '0;
            input_context_tail_r <= '0;
            input_context_count_r <= '0;
            input_next_sequence_r <= '0;
            for (int ctx = 0; ctx < INPUT_CONTEXT_DEPTH; ++ctx)
                input_cmd_ctx_r[ctx] <= '0;
        end else begin
            unique case ({input_cmd_start, input_cmd_done})
                2'b10: input_context_count_r
                    <= input_context_count_r
                     + INPUT_CONTEXT_COUNT_BITS'(1);
                2'b01: input_context_count_r
                    <= input_context_count_r
                     - INPUT_CONTEXT_COUNT_BITS'(1);
                default:;
            endcase
            if (input_packet_fire) begin
                if (gemm_unit_v2_if.packet_ctrl.last) begin
                    input_cmd_ctx_r[input_admit_ptr_r].ingress_complete
                        <= 1'b1;
                    input_admit_ptr_r
                        <= input_admit_ptr_r + INPUT_CONTEXT_PTR_BITS'(1);
                end else begin
                    input_cmd_ctx_r[input_admit_ptr_r].packet_index
                        <= input_cmd_ctx_r[input_admit_ptr_r].packet_index
                         + 21'd1;
                end
            end
            if (input_cmd_done) begin
                input_cmd_ctx_r[input_complete_ptr_r] <= '0;
                input_complete_ptr_r
                    <= input_complete_ptr_r + INPUT_CONTEXT_PTR_BITS'(1);
            end
            if (input_cmd_start) begin
                input_cmd_ctx_r[input_context_tail_r].valid <= 1'b1;
                input_cmd_ctx_r[input_context_tail_r].ingress_complete
                    <= 1'b0;
                input_cmd_ctx_r[input_context_tail_r].acc_base
                    <= gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
                input_cmd_ctx_r[input_context_tail_r].packet_count
                    <= gemm_ctrl_if.input_read_ctrl.cmd.eff_mt;
                input_cmd_ctx_r[input_context_tail_r].packet_index <= '0;
                input_cmd_ctx_r[input_context_tail_r].is_accum
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[4];
                input_cmd_ctx_r[input_context_tail_r].notify_on_writeback
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[
                        INPUT_NOTIFY_ON_WRITEBACK_FLAG];
                input_cmd_ctx_r[input_context_tail_r].quant_dir
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[6];
                input_cmd_ctx_r[input_context_tail_r].wreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[2];
                input_cmd_ctx_r[input_context_tail_r].sreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
                input_cmd_ctx_r[input_context_tail_r].zreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[0];
                input_cmd_ctx_r[input_context_tail_r].admit_waits
                    <= gemm_ctrl_if.input_read_ctrl.cmd.input_admit_waits;
                input_cmd_ctx_r[input_context_tail_r].seq_id
                    <= gemm_ctrl_if.input_read_ctrl.cmd.work_seq;
                input_context_tail_r
                    <= input_context_tail_r + INPUT_CONTEXT_PTR_BITS'(1);
                input_next_sequence_r <= input_next_sequence_r + 32'd1;
            end
        end
    end
    assign input_dma_ctrl_if.start           = input_cmd_start;
    assign input_dma_ctrl_if.prepare         = gemm_ctrl_if.input_read_ctrl.prepare;
    assign input_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.input_read_ctrl.cmd.prepare.max_beats;
    assign input_dma_ctrl_if.src_base_addr   = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
    assign input_dma_ctrl_if.src_strides[0]  = gemm_ctrl_if.input_read_ctrl.cmd.stride;
    assign input_dma_ctrl_if.src_strides[1]  = 0;
    assign input_dma_ctrl_if.src_strides[2]  = 0;
    assign input_dma_ctrl_if.dst_base_addr   = '0;   
    assign input_dma_ctrl_if.dst_strides[0]  = 0;
    assign input_dma_ctrl_if.dst_strides[1]  = 0;
    assign input_dma_ctrl_if.dst_strides[2]  = 0;
    assign input_dma_ctrl_if.bounds[0]
        = 21'(gemm_ctrl_if.input_read_ctrl.cmd.bound);
    assign input_dma_ctrl_if.bounds[1]       = 21'(1);
    assign input_dma_ctrl_if.bounds[2]       = 21'(1);
    assign input_dma_ctrl_if.seg_size        = MXU_KT*2;   
    assign input_dma_ctrl_if.reg_idx = '0;
    assign input_dma_ctrl_if.reg_value = '0;
    assign input_dma_ctrl_if.scheduler_work_seq
        = gemm_ctrl_if.input_read_ctrl.cmd.work_seq;
    assign gemm_ctrl_if.input_read_flag.idle
        = input_context_can_accept && input_dma_ctrl_if.idle;
    assign gemm_ctrl_if.input_read_flag.done = input_cmd_done;
    assign gemm_ctrl_if.input_read_flag.prepare_ready
        = input_dma_ctrl_if.prepare_ready;
    assign gemm_sync_if[0].valid   = 1'b0;
    assign gemm_sync_if[0].reg_idx = 32'd0;
    assign gemm_sync_if[0].value   = 32'd0;
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start;
    assign weight_dma_ctrl_if.prepare        = gemm_ctrl_if.weight_read_ctrl.prepare;
    assign weight_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.weight_read_ctrl.cmd.prepare.max_beats;
    assign weight_dma_ctrl_if.src_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
    assign weight_dma_ctrl_if.src_strides[0] = gemm_ctrl_if.weight_read_ctrl.cmd.stride;
    assign weight_dma_ctrl_if.src_strides[1] = 0;
    assign weight_dma_ctrl_if.src_strides[2] = 0;
    assign weight_dma_ctrl_if.dst_base_addr
        = 64'(gemm_ctrl_if.weight_read_ctrl.cmd.flags[1:0])
       << $clog2(((16*4*4)/8));
    assign weight_dma_ctrl_if.dst_strides[0] = 0;
    assign weight_dma_ctrl_if.dst_strides[1] = 0;
    assign weight_dma_ctrl_if.dst_strides[2] = 0;
    assign weight_dma_ctrl_if.bounds[0]
        = 21'(gemm_ctrl_if.weight_read_ctrl.cmd.bound);
    assign weight_dma_ctrl_if.bounds[1]      = 21'(1);
    assign weight_dma_ctrl_if.bounds[2]      = 21'(1);
    assign weight_dma_ctrl_if.seg_size       = MXU_KT * (MXU_NT >> 1);   
    assign weight_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.reg_id
    };
    assign weight_dma_ctrl_if.reg_value
        = gemm_ctrl_if.weight_read_ctrl.cmd.notify.value;
    assign weight_dma_ctrl_if.scheduler_work_seq
        = gemm_ctrl_if.weight_read_ctrl.cmd.work_seq;
    assign gemm_ctrl_if.weight_read_flag.idle = weight_dma_ctrl_if.idle;
    assign gemm_ctrl_if.weight_read_flag.done = weight_last_register_write;
    assign gemm_ctrl_if.weight_read_flag.prepare_ready
        = weight_dma_ctrl_if.prepare_ready;
    assign gemm_sync_if[1].valid = gemm_unit_v2_if.weight_consume_valid;
    assign gemm_sync_if[1].reg_idx
        = gemm_unit_v2_if.weight_consume_idx
        ? 32'(GEMM_RID_W_CONSUME1) : 32'(GEMM_RID_W_CONSUME0);
    assign gemm_sync_if[1].value = 32'd1;
    always_ff @(posedge clk) begin
      if (reset) begin
        weight_boundary_valid_r <= '0;
        weight_boundary_bus_done_r <= '0;
        weight_boundary_head_r <= '0;
        weight_boundary_bus_done_ptr_r <= '0;
        weight_boundary_tail_r <= '0;
        weight_boundary_count_r <= '0;
        for (int cmd = 0; cmd < WEIGHT_BOUNDARY_DEPTH; ++cmd) begin
          weight_boundary_writes_remaining_r[cmd] <= '0;
        end
      end else begin
        unique case ({weight_dma_start, weight_last_register_write})
          2'b10: weight_boundary_count_r
              <= weight_boundary_count_r + WEIGHT_BOUNDARY_COUNT_BITS'(1);
          2'b01: weight_boundary_count_r
              <= weight_boundary_count_r - WEIGHT_BOUNDARY_COUNT_BITS'(1);
          default:;
        endcase
        if (weight_dma_ctrl_if.write_done) begin
          weight_boundary_bus_done_r[weight_boundary_bus_done_ptr_r] <= 1'b1;
          weight_boundary_bus_done_ptr_r
              <= weight_boundary_bus_done_ptr_r
               + WEIGHT_BOUNDARY_PTR_BITS'(1);
        end
        if (gemm_unit_v2_if.weight_register_write) begin
          if (weight_last_register_write) begin
            weight_boundary_valid_r[weight_boundary_head_r] <= 1'b0;
            weight_boundary_bus_done_r[weight_boundary_head_r] <= 1'b0;
            weight_boundary_writes_remaining_r[weight_boundary_head_r]
                <= '0;
            weight_boundary_head_r
                <= weight_boundary_head_r + WEIGHT_BOUNDARY_PTR_BITS'(1);
          end else begin
            weight_boundary_writes_remaining_r[weight_boundary_head_r]
                <= weight_boundary_writes_remaining_r[weight_boundary_head_r]
                 - 64'd1;
          end
        end
        if (weight_dma_start) begin
          weight_boundary_valid_r[weight_boundary_tail_r] <= 1'b1;
          weight_boundary_bus_done_r[weight_boundary_tail_r] <= 1'b0;
          weight_boundary_writes_remaining_r[weight_boundary_tail_r]
              <= weight_command_writes;
          weight_boundary_tail_r
              <= weight_boundary_tail_r + WEIGHT_BOUNDARY_PTR_BITS'(1);
        end
      end
    end
    assign scale_dma_ctrl_if.start = gemm_ctrl_if.scale_read_ctrl.start;
    assign scale_dma_ctrl_if.prepare = gemm_ctrl_if.scale_read_ctrl.prepare;
    assign scale_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.scale_read_ctrl.cmd.prepare.max_beats;
    assign scale_dma_ctrl_if.src_base_addr
        = gemm_ctrl_if.scale_read_ctrl.cmd.rs2_data;
    assign scale_dma_ctrl_if.src_strides[0]
        = gemm_ctrl_if.scale_read_ctrl.cmd.stride[31:16];
    assign scale_dma_ctrl_if.src_strides[1] = 0;
    assign scale_dma_ctrl_if.src_strides[2] = 0;
    assign scale_dma_ctrl_if.dst_base_addr
        = gemm_ctrl_if.scale_read_ctrl.cmd.rs1_data;
    assign scale_dma_ctrl_if.dst_strides[0]
        = gemm_ctrl_if.scale_read_ctrl.cmd.stride[15:0];
    assign scale_dma_ctrl_if.dst_strides[1] = 0;
    assign scale_dma_ctrl_if.dst_strides[2] = 0;
    assign scale_dma_ctrl_if.bounds[0]
        = 21'(gemm_ctrl_if.scale_read_ctrl.cmd.bound);
    assign scale_dma_ctrl_if.bounds[1] = 21'(1);
    assign scale_dma_ctrl_if.bounds[2] = 21'(1);
    assign scale_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign scale_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.reg_id
    };
    assign scale_dma_ctrl_if.reg_value
        = gemm_ctrl_if.scale_read_ctrl.cmd.notify.value;
    assign scale_dma_ctrl_if.scheduler_work_seq
        = gemm_ctrl_if.scale_read_ctrl.cmd.work_seq;
    assign gemm_ctrl_if.scale_read_flag.idle
        = scale_dma_ctrl_if.idle;
    assign gemm_ctrl_if.scale_read_flag.done = scale_register_write_done_q;
    assign gemm_ctrl_if.scale_read_flag.prepare_ready
        = scale_dma_ctrl_if.prepare_ready;
    assign zero_point_dma_ctrl_if.start
        = gemm_ctrl_if.zero_point_read_ctrl.start;
    assign zero_point_dma_ctrl_if.prepare
        = gemm_ctrl_if.zero_point_read_ctrl.prepare;
    assign zero_point_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.prepare.max_beats;
    assign zero_point_dma_ctrl_if.src_base_addr
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.rs2_data;
    assign zero_point_dma_ctrl_if.src_strides[0]
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.stride[31:16];
    assign zero_point_dma_ctrl_if.src_strides[1] = 0;
    assign zero_point_dma_ctrl_if.src_strides[2] = 0;
    assign zero_point_dma_ctrl_if.dst_base_addr
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.rs1_data;
    assign zero_point_dma_ctrl_if.dst_strides[0]
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.stride[15:0];
    assign zero_point_dma_ctrl_if.dst_strides[1] = 0;
    assign zero_point_dma_ctrl_if.dst_strides[2] = 0;
    assign zero_point_dma_ctrl_if.bounds[0]
        = 21'(gemm_ctrl_if.zero_point_read_ctrl.cmd.bound);
    assign zero_point_dma_ctrl_if.bounds[1] = 21'(1);
    assign zero_point_dma_ctrl_if.bounds[2] = 21'(1);
    assign zero_point_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign zero_point_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.reg_id
    };
    assign zero_point_dma_ctrl_if.reg_value
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.value;
    assign zero_point_dma_ctrl_if.scheduler_work_seq
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.work_seq;
    assign gemm_ctrl_if.zero_point_read_flag.idle
        = zero_point_dma_ctrl_if.idle;
    assign gemm_ctrl_if.zero_point_read_flag.done
        = zero_point_register_write_done_q;
    assign gemm_ctrl_if.zero_point_read_flag.prepare_ready
        = zero_point_dma_ctrl_if.prepare_ready;
    assign gemm_ctrl_if.quant_param_read_flag.idle = 1'b1;
    assign gemm_ctrl_if.quant_param_read_flag.done = 1'b0;
    assign gemm_ctrl_if.quant_param_read_flag.prepare_ready = 1'b0;
    always_ff @(posedge clk) begin
      if (reset) begin
        scale_boundary_valid_r <= '0;
        scale_boundary_head_r <= '0;
        scale_boundary_tail_r <= '0;
        scale_boundary_count_r <= '0;
        scale_register_write_done_q <= 1'b0;
        zero_point_boundary_valid_r <= '0;
        zero_point_boundary_head_r <= '0;
        zero_point_boundary_tail_r <= '0;
        zero_point_boundary_count_r <= '0;
        zero_point_register_write_done_q <= 1'b0;
        for (int entry = 0; entry < QPARAM_BOUNDARY_DEPTH; ++entry) begin
          scale_boundary_writes_remaining_r[entry] <= '0;
          zero_point_boundary_writes_remaining_r[entry] <= '0;
        end
      end else begin
        scale_register_write_done_q <= scale_last_register_write;
        zero_point_register_write_done_q
            <= zero_point_last_register_write;
        unique case ({scale_dma_start, scale_last_register_write})
          2'b10: scale_boundary_count_r
              <= scale_boundary_count_r + QPARAM_BOUNDARY_COUNT_BITS'(1);
          2'b01: scale_boundary_count_r
              <= scale_boundary_count_r - QPARAM_BOUNDARY_COUNT_BITS'(1);
          default:;
        endcase
        unique case ({zero_point_dma_start, zero_point_last_register_write})
          2'b10: zero_point_boundary_count_r
              <= zero_point_boundary_count_r + QPARAM_BOUNDARY_COUNT_BITS'(1);
          2'b01: zero_point_boundary_count_r
              <= zero_point_boundary_count_r - QPARAM_BOUNDARY_COUNT_BITS'(1);
          default:;
        endcase
        if (gemm_unit_v2_if.scale_register_write) begin
          scale_boundary_writes_remaining_r[scale_boundary_head_r]
              <= scale_boundary_writes_remaining_r[scale_boundary_head_r]
               - 64'd1;
          if (scale_last_register_write) begin
            scale_boundary_valid_r[scale_boundary_head_r] <= 1'b0;
            scale_boundary_head_r
                <= scale_boundary_head_r + QPARAM_BOUNDARY_PTR_BITS'(1);
          end
        end
        if (gemm_unit_v2_if.zero_point_register_write) begin
          zero_point_boundary_writes_remaining_r[zero_point_boundary_head_r]
              <= zero_point_boundary_writes_remaining_r[
                   zero_point_boundary_head_r] - 64'd1;
          if (zero_point_last_register_write) begin
            zero_point_boundary_valid_r[zero_point_boundary_head_r] <= 1'b0;
            zero_point_boundary_head_r
                <= zero_point_boundary_head_r + QPARAM_BOUNDARY_PTR_BITS'(1);
          end
        end
        if (scale_dma_start) begin
          scale_boundary_valid_r[scale_boundary_tail_r] <= 1'b1;
          scale_boundary_writes_remaining_r[scale_boundary_tail_r]
              <= scale_command_writes;
          scale_boundary_tail_r
              <= scale_boundary_tail_r + QPARAM_BOUNDARY_PTR_BITS'(1);
        end
        if (zero_point_dma_start) begin
          zero_point_boundary_valid_r[zero_point_boundary_tail_r] <= 1'b1;
          zero_point_boundary_writes_remaining_r[
              zero_point_boundary_tail_r] <= zero_point_command_writes;
          zero_point_boundary_tail_r
              <= zero_point_boundary_tail_r + QPARAM_BOUNDARY_PTR_BITS'(1);
        end
      end
    end
    assign gemm_sync_if[2].valid = gemm_unit_v2_if.scale_consume_valid;
    assign gemm_sync_if[2].reg_idx
        = gemm_unit_v2_if.scale_consume_idx
        ? 32'(GEMM_RID_SC_CONSUME1) : 32'(GEMM_RID_SC_CONSUME0);
    assign gemm_sync_if[2].value = 32'd1;
    assign gemm_sync_if[3].valid = gemm_unit_v2_if.zp_consume_valid;
    assign gemm_sync_if[3].reg_idx
        = gemm_unit_v2_if.zp_consume_idx
        ? 32'(GEMM_RID_ZP_CONSUME1) : 32'(GEMM_RID_ZP_CONSUME0);
    assign gemm_sync_if[3].value = 32'd1;
    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start;
    assign output_dma_ctrl_if.prepare       = 1'b0;
    assign output_dma_ctrl_if.prepare_max_beats = '0;
    assign output_dma_ctrl_if.src_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
    assign output_dma_ctrl_if.src_strides[0] = 0;
    assign output_dma_ctrl_if.src_strides[1] = 0;
    assign output_dma_ctrl_if.src_strides[2] = 0;
    assign output_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
    assign output_dma_ctrl_if.dst_strides[0] = gemm_ctrl_if.output_write_ctrl.cmd.stride;
    assign output_dma_ctrl_if.dst_strides[1] = 0;
    assign output_dma_ctrl_if.dst_strides[2] = 0;
    assign output_dma_ctrl_if.bounds[0] = 21'(1);
    assign output_dma_ctrl_if.bounds[1] = 21'(1);
    assign output_dma_ctrl_if.bounds[2] = 21'(1);
    assign output_dma_ctrl_if.seg_size         = MXU_NT * 2 * gemm_ctrl_if.output_write_ctrl.cmd.bound;   
    assign output_dma_ctrl_if.reg_idx = '0;
    assign output_dma_ctrl_if.reg_value = '0;
    assign output_dma_ctrl_if.scheduler_work_seq = '0;
    assign gemm_ctrl_if.output_write_flag.idle
        = output_dma_ctrl_if.idle
       && (!output_write_active_r || output_write_done_q);
    assign gemm_ctrl_if.output_write_flag.done = output_write_done_q;
    assign gemm_ctrl_if.output_write_flag.prepare_ready = 1'b0;
    always_ff @(posedge clk) begin
      if (reset) begin
        output_write_active_r <= 1'b0;
        output_write_done_q <= 1'b0;
      end else begin
        output_write_done_q <= output_dma_ctrl_if.write_done;
        if (gemm_ctrl_if.output_write_ctrl.start) begin
          output_write_active_r <= 1'b1;
        end else if (output_write_done_q) begin
          output_write_active_r <= 1'b0;
        end
      end
    end
    assign gemm_sync_if[4].valid   = 1'b0;
    assign gemm_sync_if[4].reg_idx = 32'd0;
    assign gemm_sync_if[4].value   = 32'd0;
    VX_gemm_sync_if backend_dma_sync_if ();
    wire backend_store_done;
    VX_gemm_dma_ctrl_if source_dma_ctrl_if ();
    assign source_dma_ctrl_if.start = gemm_ctrl_if.dma_ctrl.start;
    assign source_dma_ctrl_if.cmd_valid = gemm_ctrl_if.dma_ctrl.cmd_valid;
    assign source_dma_ctrl_if.cmd = gemm_ctrl_if.dma_ctrl.cmd;
    assign source_dma_ctrl_if.cmd_tag = gemm_ctrl_if.dma_ctrl.cmd_tag;
    assign source_dma_ctrl_if.prepare_valid
        = gemm_ctrl_if.dma_ctrl.prepare_valid;
    assign source_dma_ctrl_if.prepare_cmd = gemm_ctrl_if.dma_ctrl.prepare_cmd;
    assign gemm_ctrl_if.dma_flag.idle = source_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = source_dma_ctrl_if.done;
    assign gemm_ctrl_if.dma_flag.done_tag = source_dma_ctrl_if.done_tag;
    assign gemm_ctrl_if.dma_flag.cmd_ready = source_dma_ctrl_if.cmd_ready;
    assign gemm_ctrl_if.dma_flag.prepare_ready = source_dma_ctrl_if.prepare_ready;
    VX_gemm_dma_transport #(
        .INSTANCE_ID ({INSTANCE_ID, "_dma_transport"}),
        .SLR_ENABLE (SLR_ENABLE),
        .LAUNCH_DEPTH (DMA_LAUNCH_DEPTH)
    ) u_gemm_dma_transport (
        .clk (clk),
        .reset (reset),
        .source_if (source_dma_ctrl_if),
        .backend_if (gemm_dma_ctrl_if),
        .backend_store_done (backend_store_done),
        .source_store_done (output_store_done),
        .backend_sync_if (backend_dma_sync_if),
        .source_sync_if (gemm_sync_if[5])
    );
    VX_config_reg_if #(
        .NUM (18),
        .DW  (32)
    ) dma_cfg_if [NUM_DMA_CHANNELS] ();
    VX_node_done_if dma_done_if [NUM_DMA_CHANNELS] ();
    VX_dma_lookahead_if dma_lookahead_if [NUM_DMA_CHANNELS] ();
    VX_gemm_tmem_dma_ctrl #(
        .INSTANCE_ID  ({INSTANCE_ID, "_tmem_dma_ctrl"}),
        .NUM_CHANNELS (NUM_DMA_CHANNELS)
    ) u_tmem_dma_ctrl (
        .clk              (clk),
        .reset            (reset),
        .gemm_dma_ctrl_if (gemm_dma_ctrl_if),
        .store_done       (backend_store_done),
        .gemm_sync_if     (backend_dma_sync_if),
        .cfg_reg_if       (dma_cfg_if),
        .lookahead_if     (dma_lookahead_if),
        .done_if          (dma_done_if)
    );
    VX_job_frontend #(
      .INSTANCE_ID(INSTANCE_ID),
      .NUM_MASTERS(N_MASTER),
      .NUM_ENTRIES(1),
      .NUM_REGS32(44),
      .HW_WRITE_REG_IDX(OUTPUT_PROGRESS_REG_IDX),
      .CFG_BASE_ADDR(64'h0000_0000_0000_1080),
      .ONE_LANE_MMIO(1'b1)
    ) u_job_frontend (
      .clk(clk),
      .reset(reset),
      .mmio_if(mmio_if),
      .issue_if(issue_if),
      .done_if(done_if),
      .hw_write_valid_i(progress_update_valid),
      .hw_write_entry_id_i(progress_update_entry_id),
      .hw_write_value_i(progress_update_value)
    );
    VX_lmem_dma_ctrl_if tmem_ldma_ctrl_if [5] ();
    assign tmem_ldma_ctrl_if[0].start          = input_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[0].prepare        = input_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[0].prepare_max_beats
        = input_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[0].src_base_addr  = input_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[0].src_strides    = input_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[0].dst_base_addr  = input_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[0].dst_strides    = input_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[0].bounds         = input_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[0].seg_size       = input_dma_ctrl_if.seg_size;
    assign tmem_ldma_ctrl_if[0].reg_idx        = input_dma_ctrl_if.reg_idx;
    assign tmem_ldma_ctrl_if[0].reg_value      = input_dma_ctrl_if.reg_value;
    assign tmem_ldma_ctrl_if[0].scheduler_work_seq
        = input_dma_ctrl_if.scheduler_work_seq;
    assign input_dma_ctrl_if.idle              = tmem_ldma_ctrl_if[0].idle;
    assign input_dma_ctrl_if.done              = tmem_ldma_ctrl_if[0].done;
    assign input_dma_ctrl_if.write_done        = tmem_ldma_ctrl_if[0].write_done;
    assign input_dma_ctrl_if.prepare_ready     = tmem_ldma_ctrl_if[0].prepare_ready;
    assign tmem_ldma_ctrl_if[1].start          = weight_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[1].prepare        = weight_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[1].prepare_max_beats
        = weight_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[1].src_base_addr  = weight_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[1].src_strides    = weight_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[1].dst_base_addr  = weight_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[1].dst_strides    = weight_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[1].bounds         = weight_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[1].seg_size       = weight_dma_ctrl_if.seg_size;
    assign tmem_ldma_ctrl_if[1].reg_idx        = weight_dma_ctrl_if.reg_idx;
    assign tmem_ldma_ctrl_if[1].reg_value      = weight_dma_ctrl_if.reg_value;
    assign tmem_ldma_ctrl_if[1].scheduler_work_seq
        = weight_dma_ctrl_if.scheduler_work_seq;
    assign weight_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[1].idle;
    assign weight_dma_ctrl_if.done             = tmem_ldma_ctrl_if[1].done;
    assign weight_dma_ctrl_if.write_done       = tmem_ldma_ctrl_if[1].write_done;
    assign weight_dma_ctrl_if.prepare_ready    = tmem_ldma_ctrl_if[1].prepare_ready;
    assign tmem_ldma_ctrl_if[2].start          = scale_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[2].prepare        = scale_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[2].prepare_max_beats
        = scale_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[2].src_base_addr  = scale_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[2].src_strides    = scale_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[2].dst_base_addr  = scale_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[2].dst_strides    = scale_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[2].bounds         = scale_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[2].seg_size       = scale_dma_ctrl_if.seg_size;
    assign tmem_ldma_ctrl_if[2].reg_idx        = scale_dma_ctrl_if.reg_idx;
    assign tmem_ldma_ctrl_if[2].reg_value      = scale_dma_ctrl_if.reg_value;
    assign tmem_ldma_ctrl_if[2].scheduler_work_seq
        = scale_dma_ctrl_if.scheduler_work_seq;
    assign scale_dma_ctrl_if.idle              = tmem_ldma_ctrl_if[2].idle;
    assign scale_dma_ctrl_if.done              = tmem_ldma_ctrl_if[2].done;
    assign scale_dma_ctrl_if.write_done        = tmem_ldma_ctrl_if[2].write_done;
    assign scale_dma_ctrl_if.prepare_ready     = tmem_ldma_ctrl_if[2].prepare_ready;
    assign tmem_ldma_ctrl_if[3].start          = zero_point_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[3].prepare        = zero_point_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[3].prepare_max_beats
        = zero_point_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[3].src_base_addr  = zero_point_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[3].src_strides    = zero_point_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[3].dst_base_addr  = zero_point_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[3].dst_strides    = zero_point_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[3].bounds         = zero_point_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[3].seg_size       = zero_point_dma_ctrl_if.seg_size;
    assign tmem_ldma_ctrl_if[3].reg_idx        = zero_point_dma_ctrl_if.reg_idx;
    assign tmem_ldma_ctrl_if[3].reg_value      = zero_point_dma_ctrl_if.reg_value;
    assign tmem_ldma_ctrl_if[3].scheduler_work_seq
        = zero_point_dma_ctrl_if.scheduler_work_seq;
    assign zero_point_dma_ctrl_if.idle         = tmem_ldma_ctrl_if[3].idle;
    assign zero_point_dma_ctrl_if.done         = tmem_ldma_ctrl_if[3].done;
    assign zero_point_dma_ctrl_if.write_done   = tmem_ldma_ctrl_if[3].write_done;
    assign zero_point_dma_ctrl_if.prepare_ready = tmem_ldma_ctrl_if[3].prepare_ready;
    assign tmem_ldma_ctrl_if[4].start          = output_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[4].prepare        = 1'b0;
    assign tmem_ldma_ctrl_if[4].prepare_max_beats = '0;
    assign tmem_ldma_ctrl_if[4].src_base_addr  = output_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[4].src_strides    = output_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[4].dst_base_addr  = output_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[4].dst_strides    = output_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[4].bounds         = output_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[4].seg_size       = output_dma_ctrl_if.seg_size;
    assign tmem_ldma_ctrl_if[4].reg_idx        = output_dma_ctrl_if.reg_idx;
    assign tmem_ldma_ctrl_if[4].reg_value      = output_dma_ctrl_if.reg_value;
    assign tmem_ldma_ctrl_if[4].scheduler_work_seq = '0;
    assign output_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[4].idle;
    assign output_dma_ctrl_if.done             = tmem_ldma_ctrl_if[4].done;
    assign output_dma_ctrl_if.write_done       = tmem_ldma_ctrl_if[4].write_done;
    assign output_dma_ctrl_if.prepare_ready    = tmem_ldma_ctrl_if[4].prepare_ready;
    VX_tmem_subsystem #(
      .INSTANCE_ID    ({INSTANCE_ID, ":tmem"}),
      .NUM_BANKS      (NUM_TMEM_BANKS),
      .NUM_DMA_CHANNELS(NUM_DMA_CHANNELS),
      .BANK_SIZE      (65536),
      .DATA_SIZE      (TMEM_PHYSICAL_DATA_SIZE),
      .HBM_DMA_DATA_SIZE (64),
      .INPUT_DATA_SIZE (((16/8)*16)),
      .WEIGHT_DATA_SIZE (((16*4*4)/8)),
      .SCALE_ZERO_DATA_SIZE (((16*16)/8)),
      .OUTPUT_DATA_SIZE (((16/8)*16)),
      .TAG_WIDTH      (GEMM_BASE_TAG_WIDTH),
      .I_RD_OUTSTANDING(INPUT_SLOTS)
    ) u_tmem_subsystem (
      .clk            (clk),
      .reset          (reset),
      .dma_cfg_if     (dma_cfg_if),
      .dma_lookahead_if (dma_lookahead_if),
      .dma_done_if    (dma_done_if),
      .ldma_ctrl_if   (tmem_ldma_ctrl_if),
      .weight_writer_wait_i
                       (gemm_ctrl_if.weight_read_ctrl.cmd.writer_wait),
      .weight_consume_value0_i (weight_consume_value0),
      .weight_consume_value1_i (weight_consume_value1),
      .scale_writer_wait_i
                       (gemm_ctrl_if.scale_read_ctrl.cmd.writer_wait),
      .scale_consume_value0_i (scale_consume_value0),
      .scale_consume_value1_i (scale_consume_value1),
      .zero_point_writer_wait_i
                       (gemm_ctrl_if.zero_point_read_ctrl.cmd.writer_wait),
      .zero_point_consume_value0_i (zero_point_consume_value0),
      .zero_point_consume_value1_i (zero_point_consume_value1),
      .sched_source_priority_i(sched_source_priority),
      .sched_input_source_enable_i(sched_input_source_enable),
      .sched_source_valid_o(sched_source_valid),
      .sched_source_work_seq_o(sched_source_work_seq),
      .sched_source_total_beats_o(sched_source_total_beats),
      .sched_source_request_beats_o(sched_source_request_beats),
      .sched_source_response_beats_o(sched_source_response_beats),
      .sched_source_writer_beats_o(sched_source_writer_beats),
      .sched_input_slot_occupancy_o(sched_input_slot_occupancy),
      .sched_fetch_complete_o(sched_fetch_complete),
      .sched_fetch_complete_work_seq_o(sched_fetch_complete_work_seq),
      .axi_m          (dma_axi_m),
      .gemm_input_if  (tmem_i_gemm_bus_if),
      .gemm_weight_if (tmem_w_gemm_bus_if),
      .gemm_scale_if  (tmem_sc_gemm_bus_if),
      .gemm_zp_if     (tmem_zp_gemm_bus_if),
      .gemm_output_if (tmem_o_gemm_bus_if)
    );
    VX_gemm_unit_v2 #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_unit_v2 (
      .clk(clk),
      .reset(reset),
      .i_lmem_bus_if(i_gemm_bus_if),
      .w_lmem_bus_if(w_gemm_bus_if),
      .sc_lmem_bus_if(sc_gemm_bus_if),
      .zp_lmem_bus_if(zp_gemm_bus_if),
      .o_lmem_bus_if(o_gemm_bus_if),
      .gemm_unit_v2_if(gemm_unit_v2_if)
    );
    assign i_gemm_bus_if.req_valid  = tmem_i_gemm_bus_if.req_valid; 
    assign i_gemm_bus_if.req_data   = tmem_i_gemm_bus_if.req_data; 
    assign tmem_i_gemm_bus_if.req_ready  = i_gemm_bus_if.req_ready; 
    assign tmem_i_gemm_bus_if.rsp_valid  = i_gemm_bus_if.rsp_valid; 
    assign tmem_i_gemm_bus_if.rsp_data   = i_gemm_bus_if.rsp_data; 
    assign i_gemm_bus_if.rsp_ready  = tmem_i_gemm_bus_if.rsp_ready;
    assign w_gemm_bus_if.req_valid  = tmem_w_gemm_bus_if.req_valid; 
    assign w_gemm_bus_if.req_data   = tmem_w_gemm_bus_if.req_data; 
    assign tmem_w_gemm_bus_if.req_ready  = w_gemm_bus_if.req_ready; 
    assign tmem_w_gemm_bus_if.rsp_valid  = w_gemm_bus_if.rsp_valid; 
    assign tmem_w_gemm_bus_if.rsp_data   = w_gemm_bus_if.rsp_data; 
    assign w_gemm_bus_if.rsp_ready  = tmem_w_gemm_bus_if.rsp_ready;
    assign sc_gemm_bus_if.req_valid = tmem_sc_gemm_bus_if.req_valid;
    assign tmem_sc_gemm_bus_if.req_ready = sc_gemm_bus_if.req_ready;
    assign tmem_sc_gemm_bus_if.rsp_valid = sc_gemm_bus_if.rsp_valid;
    assign tmem_sc_gemm_bus_if.rsp_data = sc_gemm_bus_if.rsp_data;
    assign sc_gemm_bus_if.rsp_ready = tmem_sc_gemm_bus_if.rsp_ready;
    assign sc_gemm_bus_if.req_data.rw = tmem_sc_gemm_bus_if.req_data.rw;
    assign sc_gemm_bus_if.req_data.addr
        = tmem_sc_gemm_bus_if.req_data.addr
       << $clog2(((16*16)/8));
    assign sc_gemm_bus_if.req_data.data = tmem_sc_gemm_bus_if.req_data.data;
    assign sc_gemm_bus_if.req_data.byteen = tmem_sc_gemm_bus_if.req_data.byteen;
    assign sc_gemm_bus_if.req_data.flags = tmem_sc_gemm_bus_if.req_data.flags;
    assign sc_gemm_bus_if.req_data.tag = tmem_sc_gemm_bus_if.req_data.tag;
    assign zp_gemm_bus_if.req_valid = tmem_zp_gemm_bus_if.req_valid;
    assign tmem_zp_gemm_bus_if.req_ready = zp_gemm_bus_if.req_ready;
    assign tmem_zp_gemm_bus_if.rsp_valid = zp_gemm_bus_if.rsp_valid;
    assign tmem_zp_gemm_bus_if.rsp_data = zp_gemm_bus_if.rsp_data;
    assign zp_gemm_bus_if.rsp_ready = tmem_zp_gemm_bus_if.rsp_ready;
    assign zp_gemm_bus_if.req_data.rw = tmem_zp_gemm_bus_if.req_data.rw;
    assign zp_gemm_bus_if.req_data.addr
        = tmem_zp_gemm_bus_if.req_data.addr
       << $clog2(((16*16)/8));
    assign zp_gemm_bus_if.req_data.data = tmem_zp_gemm_bus_if.req_data.data;
    assign zp_gemm_bus_if.req_data.byteen = tmem_zp_gemm_bus_if.req_data.byteen;
    assign zp_gemm_bus_if.req_data.flags = tmem_zp_gemm_bus_if.req_data.flags;
    assign zp_gemm_bus_if.req_data.tag = tmem_zp_gemm_bus_if.req_data.tag;
    assign o_gemm_bus_if.req_valid  = tmem_o_gemm_bus_if.req_valid; 
    assign o_gemm_bus_if.req_data   = tmem_o_gemm_bus_if.req_data; 
    assign tmem_o_gemm_bus_if.req_ready  = o_gemm_bus_if.req_ready; 
    assign tmem_o_gemm_bus_if.rsp_valid  = o_gemm_bus_if.rsp_valid; 
    assign tmem_o_gemm_bus_if.rsp_data   = o_gemm_bus_if.rsp_data; 
    assign o_gemm_bus_if.rsp_ready  = tmem_o_gemm_bus_if.rsp_ready;
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE),
      .INPUT_SLOTS(INPUT_SLOTS),
      .DMA_STORE_MAX_CHUNK_BEATS(DMA_STORE_MAX_CHUNK_BEATS)
    ) u_VX_gemm_ctrl (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(issue_if),
      .gemm_ctrl_if(gemm_ctrl_if),
      .done_if(done_if),
      .gemm_sync_slv_if(gemm_sync_if),
      .output_store_done_i(output_store_done),
      .progress_update_valid_o(progress_update_valid),
      .progress_update_entry_id_o(progress_update_entry_id),
      .progress_update_value_o(progress_update_value),
      .weight_consume_value0_o(weight_consume_value0),
      .weight_consume_value1_o(weight_consume_value1)
      ,.scale_consume_value0_o(scale_consume_value0)
      ,.scale_consume_value1_o(scale_consume_value1)
      ,.zero_point_consume_value0_o(zero_point_consume_value0)
      ,.zero_point_consume_value1_o(zero_point_consume_value1)
      ,.sched_source_valid_i(sched_source_valid)
      ,.sched_source_work_seq_i(sched_source_work_seq)
      ,.sched_source_total_beats_i(sched_source_total_beats)
      ,.sched_source_request_beats_i(sched_source_request_beats)
      ,.sched_source_response_beats_i(sched_source_response_beats)
      ,.sched_source_writer_beats_i(sched_source_writer_beats)
      ,.sched_input_slot_occupancy_i(sched_input_slot_occupancy)
      ,.sched_input_ahead_credit_i(gemm_unit_v2_if.input_ahead_credit)
      ,.sched_input_admit_valid_i(gemm_unit_v2_if.input_admit_valid)
      ,.sched_input_admit_work_seq_i(gemm_unit_v2_if.input_admit_work_seq)
      ,.sched_fetch_complete_i(sched_fetch_complete)
      ,.sched_fetch_complete_work_seq_i(sched_fetch_complete_work_seq)
      ,.consumer_block_valid_i(gemm_unit_v2_if.consumer_block_valid)
      ,.consumer_block_resource_i(gemm_unit_v2_if.consumer_block_resource)
      ,.consumer_block_work_seq_i(gemm_unit_v2_if.consumer_block_work_seq)
      ,.consumer_block_bank_i(gemm_unit_v2_if.consumer_block_bank)
      ,.consumer_block_target_i(gemm_unit_v2_if.consumer_block_target)
      ,.sched_source_priority_o(sched_source_priority)
      ,.sched_input_source_enable_o(sched_input_source_enable)
    );
;
;
;
;
;
;
endmodule

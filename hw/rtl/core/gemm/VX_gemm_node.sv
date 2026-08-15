/*
  VX_gemm_node

  Top-level GEMM node that integrates:
    - job frontend (MMIO register file + dispatch),
    - GEMM controller / GEMM unit,
    - VX_tmem_subsystem (tensor memory with DMA engine, banks, local DMAs).

  Dataflow summary
    - Load paths (i/w/scale/zero-point):
        HBM -> DMA engine -> TMEM banks -> local DMAs -> GEMM unit
    - Output path:
        GEMM unit -> local DMA -> TMEM banks -> DMA engine -> HBM
*/
`include "VX_define.vh"

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 6,
    parameter NUM_TMEM_BANKS = `NUM_DMA_CHANNELS,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        `GEMM_DMA_STORE_MAX_CHUNK_BEATS
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     mmio_if[N_MASTER],

    // DMA engine AXI ports (pass through to VX_tmem_subsystem -> HBM)
    AXI_BUS.Master          dma_axi_m [NUM_TMEM_BANKS]
`ifdef ENABLE_HW_DEBUG_GEMM
    ,output gemm_unit_debug_t gemm_unit_debug
`endif
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t  gemm_unit_perf
    ,output gemm_node_perf_t  gemm_node_perf
    ,output hbm_dma_perf_t    hbm_dma_perf
    ,output dma_perf_t        lmem_dma_input_perf
    ,output dma_perf_t        lmem_dma_weight_perf
    ,output dma_perf_t        lmem_dma_sz_perf
    ,output dma_perf_t        lmem_dma_output_perf
`endif
);

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------

    // Number of child nodes synchronized by gemm_ctrl.
    localparam N_NODE   = 6;

    // Use GEMM-specific base tag width so adapter split tags stay valid even
    // when LMEM_TAG_WIDTH is reduced in NDEBUG builds.
    localparam int I_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int W_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int SZ_GEMM_TAG_WIDTH = GEMM_BASE_TAG_WIDTH;

    // DMA tile sizes
    // localparam int MT = `GEMM_FSM_MT;
    // localparam int NT = `GEMM_FSM_NT;
    // localparam int KT = `GEMM_FSM_KT;

    // MXU micro tile sizes
    localparam int MXU_KT = `MXU_ROW;
    localparam int MXU_NT = `MXU_COL;

    // localparam int ENTRYID_W  = `JOB_MMIO_ENTRYID_W;
    // localparam int OWNER_W    = `JOB_MMIO_OWNER_W;
    // localparam int GEN_W      = `JOB_MMIO_GEN_W;

    localparam int INPUT_NOTIFY_ON_WRITEBACK_FLAG = 5;
    localparam int OUTPUT_PROGRESS_REG_IDX = 43;

    // -------------------------------------------------------------------------
    // Data-path interfaces
    // -------------------------------------------------------------------------
    // GEMM-unit-facing buses (native GEMM widths)
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(I_GEMM_TAG_WIDTH)
    ) i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(W_GEMM_TAG_WIDTH)
    ) w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_gemm_bus_if ();

    // Intermediate buses from TMEM subsystem to address manipulation logic
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_o_gemm_bus_if ();

    // -------------------------------------------------------------------------
    // Control interfaces
    // -------------------------------------------------------------------------
    VX_gemm_unit_v2_if gemm_unit_v2_if ();

    typedef struct packed {
        logic                 valid;
        logic                 ingress_complete;
        logic [`XLEN-1:0]     acc_base;
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

    // LMEM DMA control interfaces (issued by gemm_ctrl)
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

    // The Weight executor retires its descriptor when the final destination
    // request is accepted.  WLOAD_AT_ONCE adds a register-write pipe after
    // that handshake, so architectural completion uses this ordered boundary
    // queue and waits for the corresponding final register write.
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

    wire weight_dma_start = gemm_ctrl_if.weight_read_ctrl.start;
    wire scale_dma_start = gemm_ctrl_if.scale_read_ctrl.start;
    wire zero_point_dma_start = gemm_ctrl_if.zero_point_read_ctrl.start;
    wire [63:0] weight_command_bytes
        = 64'(gemm_ctrl_if.weight_read_ctrl.cmd.bound)
        * 64'(MXU_KT * (MXU_NT >> 1));
    wire [63:0] weight_command_writes
        = (weight_command_bytes + 64'(`GEMM_WEIGHT_DATA_SIZE) - 1)
        / 64'(`GEMM_WEIGHT_DATA_SIZE);
    wire [63:0] scale_command_bytes
        = 64'(gemm_ctrl_if.scale_read_ctrl.cmd.bound)
        * 64'(MXU_NT * 2);
    wire [63:0] scale_command_writes
        = (scale_command_bytes + 64'(`GEMM_SCALE_ZERO_DATA_SIZE) - 1)
        / 64'(`GEMM_SCALE_ZERO_DATA_SIZE);
    wire [63:0] zero_point_command_bytes
        = 64'(gemm_ctrl_if.zero_point_read_ctrl.cmd.bound)
        * 64'(MXU_NT * 2);
    wire [63:0] zero_point_command_writes
        = (zero_point_command_bytes + 64'(`GEMM_SCALE_ZERO_DATA_SIZE) - 1)
        / 64'(`GEMM_SCALE_ZERO_DATA_SIZE);
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
`ifndef SYNTHESIS
    logic [31:0] dbg_cyc_q;
    always_ff @(posedge clk) begin
        if (reset) dbg_cyc_q <= 32'd0;
        else       dbg_cyc_q <= dbg_cyc_q + 32'd1;
    end

    logic        dbg_weight_dma_start;
    logic [31:0] dbg_weight_dma_start_cyc_q;
    assign dbg_weight_dma_start = weight_dma_start;
    always_ff @(posedge clk) begin
        if (reset)                  dbg_weight_dma_start_cyc_q <= 32'd0;
        else if (weight_dma_start)  dbg_weight_dma_start_cyc_q <= dbg_cyc_q;
    end
`endif

    // Resource consume events use the legacy weight/scale/zero sync channels.
    // Command completion remains owned by the controller's inflight metadata.
    VX_gemm_sync_if gemm_sync_if[N_NODE] ();

    // Job frontend dispatch/done handshake.
    VX_config_reg_if #(
      .NUM(`GEMM_CFG_REG_NUM),
      .DW (32)
    ) issue_if();

    VX_node_done_if done_if();
    wire output_store_done;
    wire progress_update_valid;
    wire [`JOB_MMIO_ENTRYID_W-1:0] progress_update_entry_id;
    wire [31:0] progress_update_value;

    // -------------------------------------------------------------------------
    // Control-plane wiring
    // -------------------------------------------------------------------------

    // Packet-level control for the stateless fixed-latency GEMM unit.
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
    // Retire normal Input commands from the registered final-admission state.
    // Folding the current input_fire directly into controller done creates a
    // hierarchy-wide combinational cycle through completion/effective_sync and
    // the accumulator admission level.  The registered cut preserves the
    // final actual admission as the completion source while reporting it on
    // the following cycle.
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

    wire [`XLEN-1:0] input_packet_addr_full
        = input_cmd_ctx.acc_base
        + `XLEN'(input_cmd_ctx.packet_index * `GEMM_PSUM_DATA_SIZE);
    wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] input_packet_addr
        = input_packet_addr_full[`GEMM_ACC_MEM_ADDR_WIDTH-1:0];

    always_comb begin
        input_cmd_ctx = input_cmd_ctx_r[input_admit_ptr_r];
    end

    always_comb begin
        gemm_unit_v2_if.packet_ctrl = '0;
        // packet_ctrl is the control half of the input ready/valid request.
        // Keep it valid and stable with the LDMA request until the GEMM unit
        // accepts both halves on input_packet_fire.
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

            // Enqueue last so a simultaneous ordered completion may recycle
            // the oldest context without exposing a transient invalid entry.
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
                    <= input_next_sequence_r;
                input_context_tail_r
                    <= input_context_tail_r + INPUT_CONTEXT_PTR_BITS'(1);
                input_next_sequence_r <= input_next_sequence_r + 32'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // Named integration probes used by node-level and XRT-VCS debug.
    logic        dbg_input_cmd_start;
    logic        dbg_input_admission;
    logic [20:0] dbg_input_packet_index;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] dbg_input_acc_addr;
    logic        dbg_input_acc_rd_en;
    logic        dbg_input_last_admission;
    logic        dbg_input_last_write;
    logic        dbg_input_cmd_done;

    assign dbg_input_cmd_start = input_cmd_start;
    assign dbg_input_admission = input_packet_fire;
    assign dbg_input_packet_index = input_cmd_ctx.packet_index;
    assign dbg_input_acc_addr = input_packet_addr;
    assign dbg_input_acc_rd_en = gemm_unit_v2_if.packet_ctrl.acc_rd_en;
    assign dbg_input_last_admission = input_last_admission;
    assign dbg_input_last_write = gemm_unit_v2_if.last_write;
    assign dbg_input_cmd_done = gemm_ctrl_if.input_read_flag.done;

    logic        input_ctx_sample_valid_r;
    logic [20:0] input_packet_index_sample_r;
    logic        input_packet_fire_sample_r;
    logic        input_cmd_start_sample_r;
    logic        input_last_write_sample_r;
    logic [31:0] input_cmd_count_r;
    logic [31:0] input_last_admission_count_r;
    logic [31:0] input_last_write_count_r;
    logic [31:0] input_done_count_r;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            input_ctx_sample_valid_r <= 1'b0;
            input_packet_index_sample_r <= '0;
            input_packet_fire_sample_r <= 1'b0;
            input_cmd_start_sample_r <= 1'b0;
            input_last_write_sample_r <= 1'b0;
            input_cmd_count_r <= '0;
            input_last_admission_count_r <= '0;
            input_last_write_count_r <= '0;
            input_done_count_r <= '0;
        end else begin
            input_ctx_sample_valid_r <= 1'b1;
            input_packet_index_sample_r <= input_cmd_ctx.packet_index;
            input_packet_fire_sample_r <= input_packet_fire;
            input_cmd_start_sample_r <= input_cmd_start;
            input_last_write_sample_r <= input_cmd_done;

            if (input_cmd_start)
                input_cmd_count_r <= input_cmd_count_r + 1'b1;
            if (input_last_admission)
                input_last_admission_count_r
                    <= input_last_admission_count_r + 1'b1;
            if (gemm_unit_v2_if.last_write)
                input_last_write_count_r <= input_last_write_count_r + 1'b1;
            if (gemm_ctrl_if.input_read_flag.done)
                input_done_count_r <= input_done_count_r + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset === 1'b0) begin
            assert (gemm_unit_v2_if.packet_ctrl.valid
                 == i_gemm_bus_if.req_valid)
                else $fatal(1, "GEMM node V2 packet/request valid mismatch");

            if (input_cmd_start) begin
                assert (input_context_can_accept)
                    else $fatal(1, "GEMM node V2 input context FIFO overflow");
                assert (gemm_ctrl_if.input_read_ctrl.cmd.eff_mt != 0)
                    else $fatal(1, "GEMM node V2 input command has zero packet count");
                assert (gemm_ctrl_if.input_read_ctrl.cmd.eff_mt
                     == {5'd0, gemm_ctrl_if.input_read_ctrl.cmd.bound})
                    else $fatal(1, "GEMM node V2 eff_mt/input LDMA bound mismatch");
            end

            if (input_packet_fire) begin
                assert (input_cmd_ctx.valid)
                    else $fatal(1, "GEMM node V2 admitted input without command context");
                assert (!input_cmd_ctx.ingress_complete)
                    else $fatal(1, "GEMM node V2 admitted input after last packet");
                assert (input_cmd_ctx.packet_count != 0)
                    else $fatal(1, "GEMM node V2 packet has zero command count");
                assert (input_cmd_ctx.packet_index < input_cmd_ctx.packet_count)
                    else $fatal(1, "GEMM node V2 packet index exceeds command count");
                assert (input_packet_addr_full[`CLOG2(`GEMM_PSUM_DATA_SIZE)-1:0]
                     == '0)
                    else $fatal(1, "GEMM node V2 accumulation address is not row aligned");
                assert ((input_packet_addr_full + `GEMM_PSUM_DATA_SIZE)
                     <= `GEMM_ACC_MEM_TOT_SIZE)
                    else $fatal(1, "GEMM node V2 accumulation address is out of range");
                assert (gemm_unit_v2_if.packet_ctrl.last
                     == (input_cmd_ctx.packet_index
                      == input_cmd_ctx.packet_count - 1'b1))
                    else $fatal(1, "GEMM node V2 last metadata mismatch");
                assert ((gemm_unit_v2_if.packet_ctrl.w_load_target
                          == input_cmd_ctx.admit_waits[0].target)
                     && (gemm_unit_v2_if.packet_ctrl.s_load_target
                          == input_cmd_ctx.admit_waits[1].target)
                     && (gemm_unit_v2_if.packet_ctrl.z_load_target
                          == input_cmd_ctx.admit_waits[2].target)
                     && (gemm_unit_v2_if.packet_ctrl.w_load_target != 0)
                     && (gemm_unit_v2_if.packet_ctrl.s_load_target != 0)
                     && (gemm_unit_v2_if.packet_ctrl.z_load_target != 0))
                    else $fatal(1, "GEMM node V2 lost exact W/S/Z generation metadata");
            end

            if (input_last_admission) begin
                assert (!input_cmd_ctx.ingress_complete)
                    else $fatal(1, "GEMM node V2 emitted duplicate last packet");
                assert (input_last_admission_count_r < input_cmd_count_r
                     || input_cmd_start)
                    else $fatal(1, "GEMM node V2 has multiple last packets per command");
                if ((input_admit_ptr_r == input_complete_ptr_r)
                 && !input_cmd_ctx.notify_on_writeback) begin
                    assert (!normal_input_complete)
                        else $fatal(1,
                            "GEMM node V2 normal completion bypassed registered ingress");
                end
            end

            if (gemm_unit_v2_if.last_write) begin
                assert (input_last_write_count_r < input_last_admission_count_r)
                    else $fatal(1, "GEMM node V2 emitted duplicate last_write");
            end

            if (gemm_unit_v2_if.tagged_final_writeback) begin
                assert (gemm_unit_v2_if.last_write)
                    else $fatal(1, "GEMM node V2 tagged writeback lacks last_write");
                assert (input_completion_context_valid
                     && input_cmd_ctx_r[input_complete_ptr_r].notify_on_writeback
                     && input_cmd_ctx_r[input_complete_ptr_r].ingress_complete)
                    else $fatal(1, "GEMM node V2 tagged writeback missed completion head");
            end

            if (gemm_ctrl_if.input_read_flag.done) begin
                assert (input_completion_context_valid
                     && completion_head_ingress_complete)
                    else $fatal(1, "GEMM node V2 command done lacks completed ingress");
                assert (input_cmd_ctx_r[input_complete_ptr_r].notify_on_writeback
                      ? tagged_final_writeback
                      : normal_input_complete)
                    else $fatal(1, "GEMM node V2 command done used the wrong completion source");
                assert (input_done_count_r < input_cmd_count_r)
                    else $fatal(1, "GEMM node V2 emitted duplicate command done");
            end

            if (input_ctx_sample_valid_r
             && !input_packet_fire_sample_r
             && !input_cmd_start_sample_r
             && !input_last_write_sample_r) begin
                assert (input_cmd_ctx.packet_index
                     == input_packet_index_sample_r)
                    else $fatal(1, "GEMM node V2 packet index changed without admission");
            end
        end
    end

`endif

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start           = input_cmd_start;
    assign input_dma_ctrl_if.prepare         = gemm_ctrl_if.input_read_ctrl.prepare;
    assign input_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.input_read_ctrl.cmd.prepare.max_beats;
    assign input_dma_ctrl_if.src_base_addr   = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
    assign input_dma_ctrl_if.src_strides[0]  = gemm_ctrl_if.input_read_ctrl.cmd.stride;
    assign input_dma_ctrl_if.src_strides[1]  = 0;
    assign input_dma_ctrl_if.src_strides[2]  = 0;

    assign input_dma_ctrl_if.dst_base_addr   = '0;  //gemm_unit 으로 들어가는 input activation의 주소는 안 중요함
    assign input_dma_ctrl_if.dst_strides[0]  = 0;
    assign input_dma_ctrl_if.dst_strides[1]  = 0;
    assign input_dma_ctrl_if.dst_strides[2]  = 0;

    assign input_dma_ctrl_if.bounds[0]       = gemm_ctrl_if.input_read_ctrl.cmd.bound;
    assign input_dma_ctrl_if.bounds[1]       = 32'd1;
    assign input_dma_ctrl_if.bounds[2]       = 32'd1;

    assign input_dma_ctrl_if.seg_size        = MXU_KT*2;  // one MXU_ROW of FP16 per segment (64 bytes)
    assign gemm_ctrl_if.input_read_flag.idle
        = input_context_can_accept && input_dma_ctrl_if.idle;
    assign gemm_ctrl_if.input_read_flag.done = input_cmd_done;
    assign gemm_ctrl_if.input_read_flag.prepare_ready
        = input_dma_ctrl_if.prepare_ready;

    assign gemm_sync_if[0].valid   = 1'b0;
    assign gemm_sync_if[0].reg_idx = 32'd0;
    assign gemm_sync_if[0].value   = 32'd0;

    // Weight load DMA command mapping.
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start;
    assign weight_dma_ctrl_if.prepare        = gemm_ctrl_if.weight_read_ctrl.prepare;
    assign weight_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.weight_read_ctrl.cmd.prepare.max_beats;
    assign weight_dma_ctrl_if.src_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
    assign weight_dma_ctrl_if.src_strides[0] = gemm_ctrl_if.weight_read_ctrl.cmd.stride;
    assign weight_dma_ctrl_if.src_strides[1] = 0;
    assign weight_dma_ctrl_if.src_strides[2] = 0;

    // Encode {load_dir, wreg_idx} above the Weight beat
    // alignment.  The Weight overlap executor stores this aligned byte address
    // per command and converts it back to the writer-head bus address.
    assign weight_dma_ctrl_if.dst_base_addr
        = 64'(gemm_ctrl_if.weight_read_ctrl.cmd.flags[1:0])
       << `CLOG2(`GEMM_WEIGHT_DATA_SIZE);
    assign weight_dma_ctrl_if.dst_strides[0] = 0;
    assign weight_dma_ctrl_if.dst_strides[1] = 0;
    assign weight_dma_ctrl_if.dst_strides[2] = 0;

    assign weight_dma_ctrl_if.bounds[0]      = gemm_ctrl_if.weight_read_ctrl.cmd.bound;
    assign weight_dma_ctrl_if.bounds[1]      = 32'd1;
    assign weight_dma_ctrl_if.bounds[2]      = 32'd1;

    assign weight_dma_ctrl_if.seg_size       = MXU_KT * (MXU_NT >> 1);  //int4, bytes
    // Preserve the command's architectural notify identity in the executor
    // entry for ordering assertions/debug.  Controller retirement remains
    // owned by its ordered inflight metadata FIFO.
    assign weight_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.weight_read_ctrl.cmd.notify.reg_id
    };
    assign weight_dma_ctrl_if.reg_value
        = gemm_ctrl_if.weight_read_ctrl.cmd.notify.value;
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

        // Enqueue last so same-cycle architectural completion can recycle the
        // oldest boundary entry for the next accepted Weight command.
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

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
	      if (reset === 1'b0) begin
	        if (input_cmd_start) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_CMD_START | {inst=%s, base=0x%0h, packets=%0d, flags=0x%0h}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.input_read_ctrl.cmd.rs1_data,
	              gemm_ctrl_if.input_read_ctrl.cmd.eff_mt,
	              gemm_ctrl_if.input_read_ctrl.cmd.flags))
	        end
	        if (input_packet_fire) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_PACKET | {inst=%s, index=%0d, addr=0x%0h, rd=%0d, wr=%0d, last=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx.packet_index,
	              input_packet_addr,
	              gemm_unit_v2_if.packet_ctrl.acc_rd_en,
	              gemm_unit_v2_if.packet_ctrl.acc_wr_en,
	              gemm_unit_v2_if.packet_ctrl.last))
	        end
	        if (input_dma_ctrl_if.done) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_DMA_DONE | {inst=%s, index=%0d, valid=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx.packet_index,
	              input_cmd_ctx.valid))
	        end
	        if (gemm_unit_v2_if.last_write) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_LAST_WRITE | {inst=%s, index=%0d, ingress_complete=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx_r[input_complete_ptr_r].packet_index,
	              input_cmd_ctx_r[input_complete_ptr_r].ingress_complete))
	        end
	        if (gemm_ctrl_if.input_read_flag.done) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_CMD_DONE | {inst=%s, index=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx_r[input_complete_ptr_r].packet_index))
	        end
	        if (weight_dma_start) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_WEIGHT_DMA_START | {inst=%s, src=0x%0h, stride=%0d, bound=%0d, flags=0x%0h, seg_size=%0d}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data,
	              gemm_ctrl_if.weight_read_ctrl.cmd.stride,
	              gemm_ctrl_if.weight_read_ctrl.cmd.bound,
	              gemm_ctrl_if.weight_read_ctrl.cmd.flags,
	              MXU_KT * (MXU_NT >> 1)))
	        end
	      end
	    end
`endif

    // Independent scale and zero-point local DMA command mappings.
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
        = gemm_ctrl_if.scale_read_ctrl.cmd.bound;
    assign scale_dma_ctrl_if.bounds[1] = 32'd1;
    assign scale_dma_ctrl_if.bounds[2] = 32'd1;
    assign scale_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign scale_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.scale_read_ctrl.cmd.notify.reg_id
    };
    assign scale_dma_ctrl_if.reg_value
        = gemm_ctrl_if.scale_read_ctrl.cmd.notify.value;
    assign gemm_ctrl_if.scale_read_flag.idle
        = scale_dma_ctrl_if.idle;
    // Completion is caused only by the final actual register write, but is
    // presented to the controller through a registered pulse.  This makes
    // qparam LOAD readiness visible on the next cycle and breaks the
    // GEMM-ready -> completion -> scheduler -> GEMM-ready delta-cycle loop.
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
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.bound;
    assign zero_point_dma_ctrl_if.bounds[1] = 32'd1;
    assign zero_point_dma_ctrl_if.bounds[2] = 32'd1;
    assign zero_point_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign zero_point_dma_ctrl_if.reg_idx = {
        25'd0,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.valid,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.set_mode,
        gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.reg_id
    };
    assign zero_point_dma_ctrl_if.reg_value
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.notify.value;
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

        // Enqueue last so a same-cycle final write can recycle the oldest
        // entry at the depth-four boundary without clearing the new owner.
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

    // Output store DMA command mapping.
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

    assign output_dma_ctrl_if.bounds[0] = 32'd1;
    assign output_dma_ctrl_if.bounds[1] = 32'd1;
    assign output_dma_ctrl_if.bounds[2] = 32'd1;

    assign output_dma_ctrl_if.seg_size         = MXU_NT * 2 * gemm_ctrl_if.output_write_ctrl.cmd.bound;  // all rows in one segment
    assign gemm_ctrl_if.output_write_flag.idle
        = output_dma_ctrl_if.idle && !output_write_active_r;
    assign gemm_ctrl_if.output_write_flag.done = output_dma_ctrl_if.write_done;
    assign gemm_ctrl_if.output_write_flag.prepare_ready = 1'b0;

    always_ff @(posedge clk) begin
      if (reset) begin
        output_write_active_r <= 1'b0;
      end else if (gemm_ctrl_if.output_write_ctrl.start) begin
        output_write_active_r <= 1'b1;
      end else if (output_dma_ctrl_if.write_done) begin
        output_write_active_r <= 1'b0;
      end
    end

    assign gemm_sync_if[4].valid   = 1'b0;
    assign gemm_sync_if[4].reg_idx = 32'd0;
    assign gemm_sync_if[4].value   = 32'd0;

`ifndef SYNTHESIS
    logic scale_last_register_write_prev_r;
    logic zero_point_last_register_write_prev_r;

    // Weight/output completion coincides with the terminal endpoint. Qparam
    // completion is the registered image of that endpoint and therefore
    // retires the controller entry exactly one cycle later.
    always_ff @(posedge clk) begin
      if (reset) begin
        scale_last_register_write_prev_r <= 1'b0;
        zero_point_last_register_write_prev_r <= 1'b0;
      end else begin
        scale_last_register_write_prev_r <= scale_last_register_write;
        zero_point_last_register_write_prev_r
            <= zero_point_last_register_write;
        if (weight_dma_start) begin
          assert ((weight_boundary_count_r
                   < WEIGHT_BOUNDARY_COUNT_BITS'(WEIGHT_BOUNDARY_DEPTH))
               || weight_last_register_write)
            else $fatal(1, "%s: Weight boundary FIFO overflow", INSTANCE_ID);
          assert ((weight_command_writes == `W_LMEM_DMA_CMD_BEATS)
               && (!weight_boundary_valid_r[weight_boundary_tail_r]
                || weight_last_register_write))
            else $fatal(1, "%s: invalid/overwriting Weight boundary entry",
                        INSTANCE_ID);
        end
        if (gemm_unit_v2_if.weight_register_write) begin
          assert (weight_boundary_valid_r[weight_boundary_head_r]
               && (weight_boundary_writes_remaining_r[
                     weight_boundary_head_r] != 0))
            else $fatal(1, "%s: early or duplicate weight register write", INSTANCE_ID);
        end
        if (weight_dma_ctrl_if.write_done) begin
          assert (weight_boundary_valid_r[weight_boundary_bus_done_ptr_r]
               && !weight_boundary_bus_done_r[
                    weight_boundary_bus_done_ptr_r])
            else $fatal(1, "%s: unordered/duplicate Weight bus completion",
                        INSTANCE_ID);
        end
        if (gemm_ctrl_if.weight_read_flag.done) begin
          assert (weight_last_register_write
               && (weight_boundary_bus_done_r[weight_boundary_head_r]
                || (weight_dma_ctrl_if.write_done
                 && (weight_boundary_bus_done_ptr_r
                     == weight_boundary_head_r))))
            else $fatal(1, "%s: weight done is not the final register write", INSTANCE_ID);
        end
        assert (gemm_ctrl_if.weight_read_flag.done
             == weight_last_register_write)
          else $fatal(1, "%s: Weight completion bypassed register-write boundary",
                      INSTANCE_ID);
        assert (weight_boundary_count_r
             <= WEIGHT_BOUNDARY_COUNT_BITS'(WEIGHT_BOUNDARY_DEPTH))
          else $fatal(1, "%s: Weight boundary count overflow", INSTANCE_ID);

        if (scale_dma_start) begin
          assert (((scale_boundary_count_r
                    < QPARAM_BOUNDARY_COUNT_BITS'(QPARAM_BOUNDARY_DEPTH))
                 || scale_last_register_write)
               && (scale_command_writes != 0)
               && (!scale_boundary_valid_r[scale_boundary_tail_r]
                || scale_last_register_write))
            else $fatal(1, "%s: invalid/overwriting Scale boundary entry",
                        INSTANCE_ID);
        end
        if (gemm_unit_v2_if.scale_register_write) begin
          assert (scale_boundary_valid_r[scale_boundary_head_r]
               && (scale_boundary_writes_remaining_r[
                     scale_boundary_head_r] != 0))
            else $fatal(1, "%s: early or duplicate scale register write", INSTANCE_ID);
        end
        assert (scale_dma_ctrl_if.write_done
             == scale_last_register_write)
          else $fatal(1, "%s: Scale DMA completion missed actual write",
                      INSTANCE_ID);
        assert (gemm_ctrl_if.scale_read_flag.done
             == scale_last_register_write_prev_r)
          else $fatal(1, "%s: Scale completion is not registered final write",
                      INSTANCE_ID);

        if (zero_point_dma_start) begin
          assert (((zero_point_boundary_count_r
                    < QPARAM_BOUNDARY_COUNT_BITS'(QPARAM_BOUNDARY_DEPTH))
                 || zero_point_last_register_write)
               && (zero_point_command_writes != 0)
               && (!zero_point_boundary_valid_r[
                     zero_point_boundary_tail_r]
                || zero_point_last_register_write))
            else $fatal(1, "%s: invalid/overwriting ZP boundary entry",
                        INSTANCE_ID);
        end
        if (gemm_unit_v2_if.zero_point_register_write) begin
          assert (zero_point_boundary_valid_r[zero_point_boundary_head_r]
               && (zero_point_boundary_writes_remaining_r[
                     zero_point_boundary_head_r] != 0))
            else $fatal(1, "%s: early or duplicate zero-point register write", INSTANCE_ID);
        end
        assert (zero_point_dma_ctrl_if.write_done
             == zero_point_last_register_write)
          else $fatal(1, "%s: ZP DMA completion missed actual write",
                      INSTANCE_ID);
        assert (gemm_ctrl_if.zero_point_read_flag.done
             == zero_point_last_register_write_prev_r)
          else $fatal(1, "%s: ZP completion is not registered final write",
                      INSTANCE_ID);
        assert (scale_boundary_count_r
             <= QPARAM_BOUNDARY_COUNT_BITS'(QPARAM_BOUNDARY_DEPTH))
          else $fatal(1, "%s: Scale boundary count overflow", INSTANCE_ID);
        assert (zero_point_boundary_count_r
             <= QPARAM_BOUNDARY_COUNT_BITS'(QPARAM_BOUNDARY_DEPTH))
          else $fatal(1, "%s: ZP boundary count overflow", INSTANCE_ID);

        if (gemm_ctrl_if.output_write_ctrl.start) begin
          assert (!output_write_active_r)
            else $fatal(1, "%s: overlapping output command", INSTANCE_ID);
        end
        if (output_dma_ctrl_if.write_done) begin
          assert (output_write_active_r)
            else $fatal(1, "%s: early or duplicate output destination write done",
                        INSTANCE_ID);
        end
        assert (gemm_ctrl_if.output_write_flag.done
             == output_dma_ctrl_if.write_done)
          else $fatal(1, "%s: output done is not direct final destination write",
                      INSTANCE_ID);

        if (gemm_unit_v2_if.weight_consume_valid) begin
          assert (gemm_sync_if[1].ready)
            else $fatal(1, "%s: weight consume event backpressured", INSTANCE_ID);
        end
        if (gemm_unit_v2_if.scale_consume_valid) begin
          assert (gemm_sync_if[2].ready)
            else $fatal(1, "%s: scale consume event backpressured", INSTANCE_ID);
        end
        if (gemm_unit_v2_if.zp_consume_valid) begin
          assert (gemm_sync_if[3].ready)
            else $fatal(1, "%s: zero-point consume event backpressured", INSTANCE_ID);
        end
      end
    end
`endif

    // External DMA control: VX_gemm_tmem_dma_ctrl translates GEMM DMA
    // commands into VX_config_reg_if writes for the DMA engine.
    assign gemm_dma_ctrl_if.start      = gemm_ctrl_if.dma_ctrl.start;
    assign gemm_dma_ctrl_if.cmd_valid  = gemm_ctrl_if.dma_ctrl.cmd_valid;
    assign gemm_dma_ctrl_if.cmd        = gemm_ctrl_if.dma_ctrl.cmd;
    assign gemm_dma_ctrl_if.cmd_tag    = gemm_ctrl_if.dma_ctrl.cmd_tag;
    assign gemm_dma_ctrl_if.prepare_valid
        = gemm_ctrl_if.dma_ctrl.prepare_valid;
    assign gemm_dma_ctrl_if.prepare_cmd = gemm_ctrl_if.dma_ctrl.prepare_cmd;

    assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;
    assign gemm_ctrl_if.dma_flag.cmd_ready = gemm_dma_ctrl_if.cmd_ready;
    assign gemm_ctrl_if.dma_flag.done_tag = gemm_dma_ctrl_if.done_tag;
    assign gemm_ctrl_if.dma_flag.prepare_ready
        = gemm_dma_ctrl_if.prepare_ready;

    // Internal DMA config/done interfaces (driven by tmem_dma_ctrl)
    VX_config_reg_if #(
        .NUM (`DMA_CFG_REG_NUM),
        .DW  (32)
    ) dma_cfg_if [NUM_TMEM_BANKS] ();

    VX_node_done_if dma_done_if [NUM_TMEM_BANKS] ();
    VX_dma_lookahead_if dma_lookahead_if [NUM_TMEM_BANKS] ();

    VX_gemm_tmem_dma_ctrl #(
        .INSTANCE_ID  ({INSTANCE_ID, "_tmem_dma_ctrl"}),
        .NUM_CHANNELS (NUM_TMEM_BANKS)
    ) u_tmem_dma_ctrl (
        .clk              (clk),
        .reset            (reset),
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM
        .compute_active_i (!gemm_unit_v2_if.pipeline_empty),
`endif
`endif
        .gemm_dma_ctrl_if (gemm_dma_ctrl_if),
        .store_done       (output_store_done),
        .gemm_sync_if     (gemm_sync_if[5]),
        .cfg_reg_if       (dma_cfg_if),
        .lookahead_if     (dma_lookahead_if),
        .done_if          (dma_done_if)
    );

    // -------------------------------------------------------------------------
    // Frontend
    // -------------------------------------------------------------------------

    // Job frontend: MMIO descriptor registers and issue/done interface.
    VX_job_frontend #(
      .INSTANCE_ID(INSTANCE_ID),
      .NUM_MASTERS(N_MASTER),
      .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES),
      .NUM_REGS32(`GEMM_CFG_REG_NUM),
      .HW_WRITE_REG_IDX(OUTPUT_PROGRESS_REG_IDX),
      .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR),
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

    // -------------------------------------------------------------------------
    // TMEM Subsystem
    // -------------------------------------------------------------------------
    // Replaces: LMEM arbiter, width adapters, LMEM DMAs, VX_gemm_dma_ctrl.
    // Contains: DMA engine (8ch AXI<->TMEM), TMEM banks, switches, local DMAs.

    VX_lmem_dma_ctrl_if tmem_ldma_ctrl_if [5] ();

    // Wire local DMA ctrl interfaces to the array expected by VX_tmem_subsystem
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
    assign output_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[4].idle;
    assign output_dma_ctrl_if.done             = tmem_ldma_ctrl_if[4].done;
    assign output_dma_ctrl_if.write_done       = tmem_ldma_ctrl_if[4].write_done;
    assign output_dma_ctrl_if.prepare_ready    = tmem_ldma_ctrl_if[4].prepare_ready;

    VX_tmem_subsystem #(
      .INSTANCE_ID    ({INSTANCE_ID, ":tmem"}),
      .NUM_BANKS      (NUM_TMEM_BANKS),
      .BANK_SIZE      (`TMEM_BANK_SIZE),
      .DATA_SIZE      (`MEM_BLOCK_SIZE),
      .GEMM_DATA_SIZE (`MEM_BLOCK_SIZE),
      .GEMM_WEIGHT_DATA_SIZE (`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH      (GEMM_BASE_TAG_WIDTH)
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
      .axi_m          (dma_axi_m),
      .gemm_input_if  (tmem_i_gemm_bus_if),
      .gemm_weight_if (tmem_w_gemm_bus_if),
      .gemm_scale_if  (tmem_sc_gemm_bus_if),
      .gemm_zp_if     (tmem_zp_gemm_bus_if),
      .gemm_output_if (tmem_o_gemm_bus_if)
`ifdef PERF_ENABLE
      ,.hbm_dma_perf         (hbm_dma_perf)
      ,.lmem_dma_input_perf  (lmem_dma_input_perf)
      ,.lmem_dma_weight_perf (lmem_dma_weight_perf)
      ,.lmem_dma_sz_perf     (lmem_dma_sz_perf)
      ,.lmem_dma_output_perf (lmem_dma_output_perf)
`endif
    );

    // -------------------------------------------------------------------------
    // GEMM compute/control instances
    // -------------------------------------------------------------------------

    // GEMM compute unit
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
`ifdef ENABLE_HW_DEBUG_GEMM
      ,.debug(gemm_unit_debug)
`endif
`ifdef PERF_ENABLE
      ,.perf(gemm_unit_perf)
`endif
    );

    // -------------------------------------------------------------------------
    // Address manipulation: TMEM subsystem outputs -> GEMM unit inputs
    // -------------------------------------------------------------------------

    // Input: direct connection (no addr manipulation)
    `ASSIGN_VX_MEM_BUS_IF(i_gemm_bus_if, tmem_i_gemm_bus_if);

    // Weight selector ownership now follows the overlap executor's writer
    // head, so no node-global start-time flag register is needed.
    `ASSIGN_VX_MEM_BUS_IF(w_gemm_bus_if, tmem_w_gemm_bus_if);

    // Scale and zero-point use independent ingress paths.  Both convert the
    // local DMA beat address back to the GEMM register byte address.
    assign sc_gemm_bus_if.req_valid = tmem_sc_gemm_bus_if.req_valid;
    assign tmem_sc_gemm_bus_if.req_ready = sc_gemm_bus_if.req_ready;
    assign tmem_sc_gemm_bus_if.rsp_valid = sc_gemm_bus_if.rsp_valid;
    assign tmem_sc_gemm_bus_if.rsp_data = sc_gemm_bus_if.rsp_data;
    assign sc_gemm_bus_if.rsp_ready = tmem_sc_gemm_bus_if.rsp_ready;
    assign sc_gemm_bus_if.req_data.rw = tmem_sc_gemm_bus_if.req_data.rw;
    assign sc_gemm_bus_if.req_data.addr
        = tmem_sc_gemm_bus_if.req_data.addr
       << `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
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
       << `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
    assign zp_gemm_bus_if.req_data.data = tmem_zp_gemm_bus_if.req_data.data;
    assign zp_gemm_bus_if.req_data.byteen = tmem_zp_gemm_bus_if.req_data.byteen;
    assign zp_gemm_bus_if.req_data.flags = tmem_zp_gemm_bus_if.req_data.flags;
    assign zp_gemm_bus_if.req_data.tag = tmem_zp_gemm_bus_if.req_data.tag;

    // Output: direct connection
    `ASSIGN_VX_MEM_BUS_IF(o_gemm_bus_if, tmem_o_gemm_bus_if);

`ifdef PERF_ENABLE
    gemm_node_perf_t gemm_ctrl_perf;
`endif

    // GEMM top controller
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE),
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
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      ,.dbg_compute_active_i(!gemm_unit_v2_if.pipeline_empty)
`endif
`endif
`ifdef PERF_ENABLE
      ,.gemm_unit_computing(gemm_unit_perf.computing)
      ,.perf(gemm_ctrl_perf)
`endif
    );

`ifdef PERF_ENABLE
    // Assemble gemm_node_perf:
    //   total_cycles  : forwarded from gemm_ctrl
    //   lmem_rd_bytes : deferred (tied to '0). The original 78ca77 design tapped
    //                   a single shared lmem_bus_if at the gemm_node boundary.
    //                   On fpint_improve that bus has been split into five
    //                   separate GEMM-unit-facing buses (i/w/sc/zp/o).
    //                   that flow through the TMEM subsystem's local DMAs. The
    //                   per-LDMA byte counts are already aggregated in
    //                   lmem_dma_agg_perf (rd_bytes/wr_bytes), and the per-port
    //                   fire counters in gemm_unit_perf cover the same traffic
    //                   from the MXU side. Adding a separate counter here would
    //                   double-count the same bytes. Defer to a follow-up patch
    //                   if a gemm_node-local LMEM byte counter is needed.
    assign gemm_node_perf.total_cycles  = gemm_ctrl_perf.total_cycles;
    assign gemm_node_perf.lmem_rd_bytes = '0;
    assign gemm_node_perf.lmem_wr_bytes = '0;
`endif

    // `UNUSED_VAR (weight_wtrans)
    // `UNUSED_PARAM (MT)
    // `UNUSED_PARAM (NT)
    // `UNUSED_PARAM (KT)
    // `UNUSED_PARAM (ENTRYID_W)
    // `UNUSED_PARAM (OWNER_W)
    // `UNUSED_PARAM (GEN_W)

endmodule

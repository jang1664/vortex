`include "VX_define.vh"

module VX_gemm_unit_v2 import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,

    VX_mem_bus_if.slave     i_lmem_bus_if,
    VX_mem_bus_if.slave     w_lmem_bus_if,
    VX_mem_bus_if.slave     sc_lmem_bus_if,
    VX_mem_bus_if.slave     zp_lmem_bus_if,
    VX_mem_bus_if.slave     o_lmem_bus_if,

    VX_gemm_unit_v2_if.slave gemm_unit_v2_if
`ifdef ENABLE_HW_DEBUG_GEMM
    ,output gemm_unit_debug_t debug
`endif
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t perf
`endif
);

    localparam FP32_WIDTH     = 32;
    localparam FP32_EXP_WIDTH = 8;
    localparam FP32_EXP_BIAS  = 127;
    localparam FP32_MAN_WIDTH = 23;
    localparam FP16_WIDTH     = 16;
    localparam FP16_EXP_WIDTH = 5;
    localparam FP16_EXP_BIAS  = 15;
    localparam FP16_MAN_WIDTH = 10;

    localparam SCALE_REG_SIZE  = `MAX(`MXU_ROW, `MXU_COL) * `SCALE_WIDTH / 8;
    localparam ZP_REG_SIZE     = `MAX(`MXU_ROW, `MXU_COL) * `ZP_WIDTH / 8;
    localparam SCALE_REG0_BASE = 0;
    localparam SCALE_REG1_BASE = SCALE_REG_SIZE;
    localparam ZP_REG0_BASE    = SCALE_REG_SIZE * 2;
    localparam ZP_REG1_BASE    = SCALE_REG_SIZE * 2 + ZP_REG_SIZE;

    localparam DEFAULT_OUT_DLY = 1;
    localparam INPUT_SCALE_DLY = 1;
    localparam PREALIGN_DLY = 3;
    localparam ACT_REDUCE_OUT_DLY = get_pipe_stage_num(`MXU_ROW, `ACT_REDUCE_PIPE_INTV);
    localparam ACT_REDUCE_PIPE_STAGES = get_pipe_stage_bitmask(`MXU_ROW, `ACT_REDUCE_PIPE_INTV);
    localparam BLK_IDX_DLY = DEFAULT_OUT_DLY;
    localparam MXU_OUT_DLY = (`MXU_PIPE_MUL_EN + `MXU_PIPE_ALIGN_EN + 1)
                           + get_pipe_stage_num(`MXU_ROW, `MXU_PIPE_ADD_INTV)
                           + ((`MXU_COL / `MXU_COL_TILE) - 1);
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY
                                - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;
`ifdef FPU_FPNEW
    // FPnew's input buffer supplies the fixed pipeline cycle at LATENCY=0.
    localparam FPU_OPERATOR_LATENCY = 0;
`else
    localparam FPU_OPERATOR_LATENCY = 1;
`endif
    localparam FP16_MUL_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP32_MUL_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP32_ADD_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP_SCALER_DLY = 1;
    localparam ACC_SRAM_RD_DLY = 1;
    localparam ACC_ADD_DLY = 1;
    localparam ACC_POST_DLY = 0;
    localparam TREE_PIPELINE_CAPACITY = MXU_OUT_DLY;
    localparam READY_FEEDBACK_LATENCY = 1;
    // FIFO pop is sampled directly by VX_pint2fp stage 0.  Unlike the old
    // registered merger output, that launch edge already consumes the first
    // of VX_pint2fp's two registers.
    localparam POST_LAUNCH_TO_INT2FP_CTRL_DLY
        = INTTOFP_OUT_DLY - DEFAULT_OUT_DLY;
    // Converter-result metadata starts at the same launch edge as valid_i and
    // therefore traverses both registered VX_pint2fp stages.  Keep this
    // distinct from POST_LAUNCH_TO_INT2FP_CTRL_DLY, which describes the
    // downstream ctrl_pipe path injected only after result-FIFO pop.
    localparam INT2FP_CONVERTER_META_DLY = INTTOFP_OUT_DLY;
    localparam MERGED_RESULT_FIFO_DEPTH
        = TREE_PIPELINE_CAPACITY + READY_FEEDBACK_LATENCY;
    localparam MERGED_FIFO_PTRW
        = `LOG2UP(MERGED_RESULT_FIFO_DEPTH);
    localparam MERGED_FIFO_COUNTW
        = `LOG2UP(MERGED_RESULT_FIFO_DEPTH + 1);
    // VX_pint2fp contains two always-accept pipeline registers and has no
    // output ready.  Reserve one result-FIFO entry per converter launch so an
    // arbitrary QCOL Scale stall can retain both consecutive in-flight
    // outputs without propagating ready through the converter.
    localparam INT2FP_RESULT_FIFO_DEPTH = INTTOFP_OUT_DLY;
    localparam INT2FP_RESULT_FIFO_PTRW
        = `LOG2UP(INT2FP_RESULT_FIFO_DEPTH);
    localparam INT2FP_RESULT_FIFO_COUNTW
        = `LOG2UP(INT2FP_RESULT_FIFO_DEPTH + 1);

    // ctrl_pipe[0] is the admission-edge ownership observation retained for
    // the resource fences and legacy debug contract.  The active payload is
    // held independently by u_in_pipe and advances only on elastic handshakes.
    localparam INPUT_CTRL_IDX = 0;
    localparam PREALIGN_INPUT_CTRL_IDX = INPUT_CTRL_IDX + INPUT_SCALE_DLY;
    localparam PREALIGN_CTRL_IDX = PREALIGN_INPUT_CTRL_IDX + PREALIGN_DLY;
    localparam QCOL_REDUCE_CTRL_IDX = PREALIGN_CTRL_IDX + ACT_REDUCE_OUT_DLY;
    localparam PREPROCESS_CTRL_IDX = QCOL_REDUCE_CTRL_IDX + DEFAULT_OUT_DLY;
    localparam MXU_CTRL_IDX = PREALIGN_CTRL_IDX + MXU_OUT_DLY;
    localparam MERGER_CTRL_IDX = MXU_CTRL_IDX + DEFAULT_OUT_DLY;
    localparam INT2FP_CTRL_IDX
        = MERGER_CTRL_IDX + POST_LAUNCH_TO_INT2FP_CTRL_DLY;
    localparam SCALER_CTRL_IDX = INT2FP_CTRL_IDX + FP_SCALER_DLY;
    localparam WRITE_CTRL_IDX = SCALER_CTRL_IDX + ACC_ADD_DLY + ACC_POST_DLY;
    // Post control is injected at MERGER_CTRL_IDX only when the converter
    // result FIFO pops.  The one-cycle scaler/QROW bypass output therefore
    // still observes that launch slot; a bounded common alignment pipe then
    // carries the data to the preserved Phase-1 ACC launch index.
    localparam SCALER_OUTPUT_CTRL_IDX = MERGER_CTRL_IDX;
    localparam POST_SCALER_ALIGN_DLY
        = SCALER_CTRL_IDX - SCALER_OUTPUT_CTRL_IDX;

    // The accepted-to-retired ownership counter covers state hidden inside
    // elastic submodules as well as the visible pipeline registers.  This is
    // a conservative bound over the input/branch/prealign storage, reserved
    // tree/FIFO results, fixed post stages, and a small allowance for the
    // QROW scaler and prealigner internals.
    localparam PIPELINE_OWNERSHIP_BOUND
        = DEFAULT_OUT_DLY + INPUT_SCALE_DLY + PREALIGN_DLY
        + MERGED_RESULT_FIFO_DEPTH
        + (WRITE_CTRL_IDX - MERGER_CTRL_IDX + 1) + 4;
    localparam PIPELINE_PENDING_COUNTW
        = `LOG2UP(PIPELINE_OWNERSHIP_BOUND + 1);

    localparam L_PRE = SCALER_CTRL_IDX + 1;
    localparam L_R = ACC_SRAM_RD_DLY;
    localparam L_A = ACC_ADD_DLY;
    localparam L_P = ACC_POST_DLY;
    localparam K_LOOKBACK = L_A + L_P + L_R;
    localparam NOMINAL_READ_DLY = L_PRE - L_R;
    localparam EARLY_READ_DLY = NOMINAL_READ_DLY - 1;
    localparam WRITE_DLY = L_PRE + L_A + L_P;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
    localparam GEMM_UNIT_FP16_OUT_SCALE = 1;
`else
    localparam GEMM_UNIT_FP16_OUT_SCALE = 0;
`endif

    `VX_STATIC_ASSERT(MXU_OUT_DLY >= ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY,
        ("MXU_OUT_DLY is too short for preprocessing"))
    `VX_STATIC_ASSERT(PRE_PROC_OUT_DLY >= 0, ("invalid preprocessing delay"))
    `VX_STATIC_ASSERT(POST_LAUNCH_TO_INT2FP_CTRL_DLY == 1,
        ("fall-through FIFO launch must align with VX_pint2fp stage 0"))
    `VX_STATIC_ASSERT(INT2FP_CONVERTER_META_DLY
                   == POST_LAUNCH_TO_INT2FP_CTRL_DLY + DEFAULT_OUT_DLY,
        ("converter metadata and post-pop control latencies were conflated"))
    `VX_STATIC_ASSERT(INT2FP_CONVERTER_META_DLY > 0,
        ("INT2FP converter metadata latency must be positive"))
    `VX_STATIC_ASSERT(L_PRE >= L_R + 1, ("L_PRE must cover SRAM read latency"))
    `VX_STATIC_ASSERT(K_LOOKBACK > 0, ("K lookback must be positive"))
    `VX_STATIC_ASSERT(EARLY_READ_DLY > 0, ("early read delay must be positive"))
    `VX_STATIC_ASSERT(WRITE_CTRL_IDX == WRITE_DLY - 1,
        ("write control index mismatch"))
    `VX_STATIC_ASSERT(WRITE_CTRL_IDX == SCALER_CTRL_IDX + 1,
        ("immediate forwarding requires concurrent prior writeback"))
    `VX_STATIC_ASSERT(SCALER_OUTPUT_CTRL_IDX == MERGER_CTRL_IDX,
        ("result-pop control must identify the fixed scaler output"))
    `VX_STATIC_ASSERT(POST_SCALER_ALIGN_DLY == 2,
        ("post-scaler alignment must preserve the Phase-1 ACC launch index"))
    `VX_STATIC_ASSERT(EARLY_READ_DLY - 1 == MERGER_CTRL_IDX,
        ("early ACC read must issue on the result-pop control slot"))
    `VX_STATIC_ASSERT(NOMINAL_READ_DLY - 1 == MERGER_CTRL_IDX + 1,
        ("nominal ACC read must issue one cycle after result pop"))
    `VX_STATIC_ASSERT(SCALER_CTRL_IDX == MERGER_CTRL_IDX + 2,
        ("ACC launch must retain the two-cycle post-pop schedule"))
    `VX_STATIC_ASSERT(L_R == 1 && L_A == 1 && L_P == 0,
        ("same-address history forwarding requires fixed 1/1/0 ACC latency"))
    `VX_STATIC_ASSERT(MXU_OUT_DLY == 5,
        ("GEMM-tree and correction latency contract must be five cycles"))
    `VX_STATIC_ASSERT(MERGED_RESULT_FIFO_DEPTH
                   >= TREE_PIPELINE_CAPACITY + READY_FEEDBACK_LATENCY,
        ("merged-result FIFO is too shallow for registered ready feedback"))
    `VX_STATIC_ASSERT(INT2FP_RESULT_FIFO_DEPTH >= INTTOFP_OUT_DLY,
        ("INT2FP result FIFO is too shallow for unstalled converter results"))
    `VX_STATIC_ASSERT(PIPELINE_OWNERSHIP_BOUND
                   < (1 << PIPELINE_PENDING_COUNTW),
        ("pipeline ownership counter is too narrow"))

    function automatic [1:0] get_acc_mem_idx(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        logic group;
        logic bank_offset;
        group = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
    endfunction

    function automatic logic get_acc_group(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        return addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] get_acc_mem_bank_addr(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        return {addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH:`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)+1],
                addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)-1:0]};
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0]
        get_acc_mem_bank_depth_addr(
            input logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] addr
        );
        return addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:`CLOG2(`GEMM_PSUM_DATA_SIZE)];
    endfunction

    // -------------------------------------------------------------------------
    // Scale and Zero Point Registers
    // -------------------------------------------------------------------------
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)-1:0][`SCALE_WIDTH-1:0] scale_regs;
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)-1:0][`ZP_WIDTH-1:0]    zero_regs;
    typedef logic [`MAX(`MXU_ROW, `MXU_COL)-1:0][`SCALE_WIDTH-1:0]
        scale_vector_t;
    typedef logic [`MAX(`MXU_ROW, `MXU_COL)-1:0][`ZP_WIDTH-1:0]
        zero_vector_t;

    typedef struct packed {
        logic [`MXU_ROW * `IFP_WIDTH-1:0] data;
        gemm_input_ctrl_t                  ctrl;
    } pre_input_payload_t;

    typedef struct packed {
        gemm_input_ctrl_t ctrl;
    } pre_meta_t;

    typedef struct packed {
        gemm_input_ctrl_t              ctrl;
        logic [`IFP_EXP_WIDTH-1:0]    max_exp;
    } tree_meta_t;

    typedef struct packed {
        logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0] data;
        logic [`IFP_EXP_WIDTH-1:0]               max_exp;
        gemm_input_ctrl_t                        ctrl;
    } merged_result_t;

    typedef struct packed {
`ifdef GEMM_UNIT_FP16_OUT_SCALE
        logic [`MXU_COL-1:0][FP16_WIDTH-1:0] data;
`else
        logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data;
`endif
        gemm_input_ctrl_t ctrl;
    } int2fp_result_t;

    // Independent scale and zero-point write control signals.
    logic                                            sc_req_hs;
    logic                                            sc_req_rw;
    logic [`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE*4)-1:0] sc_req_addr;
    logic [`GEMM_SCALE_ZERO_DATA_SIZE*8-1:0]         sc_req_data;
    logic                                            zp_req_hs;
    logic                                            zp_req_rw;
    logic [`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE*4)-1:0] zp_req_addr;
    logic [`GEMM_SCALE_ZERO_DATA_SIZE*8-1:0]         zp_req_data;
    logic                                            scale_reg_wr_en;
    logic                                            scale_reg_wr_req;
    logic                                            scale_reg_idx;
    logic                                            zp_reg_wr_en;
    logic                                            zp_reg_idx;
    logic                                            zp_reg_wr_req;

    // -------------------------------------------------------------------------
    // Input Pipeline Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW * `IFP_WIDTH-1:0]              in_pipe_data_out;
    logic                                          in_pipe_valid_out;
    logic                                          in_pipe_ready_in;
    pre_input_payload_t                            in_pipe_payload_in;
    pre_input_payload_t                            in_pipe_payload_out;
    gemm_input_ctrl_t                              admitted_ctrl;
    logic                                          input_stage_ready;
    logic                                          input_stage_fire;

    // -------------------------------------------------------------------------
    // Input Scaler Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW-1:0]                           in_scaler_a_ready;
    logic [`MXU_ROW-1:0]                           in_scaler_b_ready;
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0]           in_scaler_result_data;
    logic [`MXU_ROW-1:0]                           in_scaler_result_valid;
    logic [`MXU_ROW-1:0]                           in_scaler_result_ready;
    logic                                          qrow_scaler_issue;
    logic                                          qrow_scale_ready;
    logic                                          qrow_scaler_input_ready;
    logic                                          qrow_scaler_output_valid;
    logic                                          qrow_meta_ready_in;
    logic                                          qrow_meta_valid_out;
    pre_meta_t                                     qrow_meta_out;

    // -------------------------------------------------------------------------
    // Prealigner Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0]           prealigner_in_data;
    logic                                          prealigner_in_valid;
    logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0]     prealigner_int_data;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0]     prealigner_blk_idx;
    logic [`IFP_EXP_WIDTH-1:0]                     prealigner_max_exp;
    logic                                          prealigner_out_valid;
    logic                                          prealigner_ready_out;
    logic                                          prealign_issue;
    logic                                          pre_meta_ready_in;
    logic                                          pre_meta_valid_out;
    pre_meta_t                                     pre_meta_in;
    pre_meta_t                                     pre_meta_out;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0]     prealigner_blk_idx_q;
    logic                                          prealigner_pipe_out_valid;
    logic [`IFP_EXP_WIDTH-1:0]                     prealigner_max_exp_q;
    logic                                          prealigner_max_exp_q_valid;
    logic                                          qcol_branch_ready_in;
    logic                                          qcol_branch_valid_out;
    pre_input_payload_t                            qcol_branch_payload_out;
    logic                                          pre_branch_valid;
    logic                                          pre_branch_ready;
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0]           pre_branch_data;
    pre_meta_t                                     pre_branch_meta;

    // -------------------------------------------------------------------------
    // Pre-processor Output Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][`PRE_PROC_OUT_DW-1:0]     pre_proc_out;
    logic                                          pre_proc_in_valid;
    logic [`MXU_COL-1:0][`PRE_PROC_OUT_DW-1:0]     pre_proc_out_q;
    logic                                          pre_proc_out_valid;

    // -------------------------------------------------------------------------
    // MXU (GEMM Tree) Signals
    // -------------------------------------------------------------------------
    logic [`MXU_WLOAD_NUM-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]  mxu_weight;
`ifdef WLOAD_AT_ONCE
    // WLOAD_AT_ONCE: MXU_WLOAD_NUM = MXU_ROW (=32), so weight bus is 4096
    // bits wide and the 1-bit broadcasts below each fan out to ~4096
    // u_weight_regs cells. max_fanout = 32 forces Vivado to replicate the
    // u_mxu_weight_pipe source FFs (~128 copies) so the placer can co-locate
    // them with destination cell tiles. (mxu_weight itself is NOT decorated:
    // each data bit has fanout ~2, so replication would just bloat.)
    (* max_fanout = 32 *) logic                                 mxu_ready_weight;
`else
    logic                                                       mxu_ready_weight;
`endif
    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0]                      mxu_output;
    logic [`MXU_COL/`MXU_COL_TILE-1:0]                          mxu_output_valid;
    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0]                      mxu_output_dly;
    logic [`MXU_COL/`MXU_COL_TILE-1:0]                          mxu_output_valid_dly;
    logic                                                       compute_fire;
    logic                                                       compute_ready;
    logic                                                       weight_ready;
    logic                                                       zero_ready;
    tree_meta_t                                                 compute_meta;
    tree_meta_t                                                 tree_meta_pipe [0:MXU_OUT_DLY-1];
    logic [MXU_OUT_DLY-1:0]                                     tree_valid_pipe;
    logic [MERGED_FIFO_COUNTW-1:0]                              tree_credit_q;
    logic                                                       credit_return_q;
`ifdef WLOAD_AT_ONCE
    (* max_fanout = 32 *) gemm_wreg_idx_t wreg_wr_idx;
    (* max_fanout = 32 *) logic wreg_load_dir;
`else
    gemm_wreg_idx_t wreg_wr_idx;
    logic wreg_load_dir;
`endif

    // -------------------------------------------------------------------------
    // Merger Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0]        merger_out_data;
    logic                                          merger_in_valid;
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0]        merger_out_data_q;
    logic                                          merger_out_valid;
    merged_result_t                                merged_fifo_mem [0:MERGED_RESULT_FIFO_DEPTH-1];
    merged_result_t                                merged_fifo_data_in;
    merged_result_t                                merged_fifo_data_out;
    logic [MERGED_FIFO_PTRW-1:0]                   merged_fifo_wr_ptr;
    logic [MERGED_FIFO_PTRW-1:0]                   merged_fifo_rd_ptr;
    logic [MERGED_FIFO_COUNTW-1:0]                 merged_fifo_count;
    logic                                          merged_fifo_push;
    logic                                          merged_fifo_pop;
    logic                                          merged_fifo_empty;
    logic                                          merged_fifo_full;
    // This boundary is the registered-ready cut between post-process and the
    // fixed-latency tree island.  It is tied high architecturally.  A dedicated
    // simulation-only hook allows directed tests to apply arbitrary stalls
    // without adding a production interface or synthesis mux.
`ifdef SIMULATION
    logic                                          postprocess_ready_test;
    initial postprocess_ready_test = 1'b1;
    wire                                           postprocess_ready
        = postprocess_ready_test;
`else
    wire                                           postprocess_ready = 1'b1;
`endif

    // -------------------------------------------------------------------------
    // Int to FP Converter Signals
    // -------------------------------------------------------------------------
`ifdef GEMM_UNIT_FP16_OUT_SCALE
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           int2fp_out_data;
`else
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           int2fp_out_data;
`endif

    logic [`MXU_COL-1:0]                           int2fp_output_valid;
    gemm_input_ctrl_t                              int2fp_meta_pipe [0:INT2FP_CONVERTER_META_DLY-1];
    logic [INT2FP_CONVERTER_META_DLY-1:0]          int2fp_meta_valid_pipe;
    int2fp_result_t                                int2fp_result_mem [0:INT2FP_RESULT_FIFO_DEPTH-1];
    int2fp_result_t                                int2fp_result_data_in;
    int2fp_result_t                                int2fp_result_data_out;
    logic [INT2FP_RESULT_FIFO_PTRW-1:0]            int2fp_result_wr_ptr;
    logic [INT2FP_RESULT_FIFO_PTRW-1:0]            int2fp_result_rd_ptr;
    logic [INT2FP_RESULT_FIFO_COUNTW-1:0]          int2fp_result_count;
    logic [INT2FP_RESULT_FIFO_COUNTW-1:0]          int2fp_result_credit;
    logic                                          int2fp_result_push;
    logic                                          int2fp_result_pop;
    logic                                          int2fp_result_empty;
    logic                                          int2fp_result_full;
    logic                                          int2fp_launch_ready;
    logic                                          qcol_scale_ready;
    logic                                          scaler_consumer_fire;
    logic                                          qrow_scale_consumer_fire;
    logic                                          qcol_scale_consumer_fire;
    logic                                          qrow_zp_consumer_fire;
    logic                                          qcol_zp_consumer_fire;
    logic                                          qrow_scale_consume_last;
    logic                                          qcol_scale_consume_last;
    logic                                          qrow_zp_consume_last;
    logic                                          qcol_zp_consume_last;
    logic                                          scale_consume_channel_ready;
    logic                                          zp_consume_channel_ready;
    // These four controls name the transaction at its actual direct-register
    // read boundary.  Keep them distinct from the two last-event muxes below:
    // a non-final QCOL read may overlap unrelated QROW metadata upstream.
    gemm_input_ctrl_t                              qrow_scale_consumer_ctrl;
    gemm_input_ctrl_t                              qcol_scale_consumer_ctrl;
    gemm_input_ctrl_t                              qrow_zp_consumer_ctrl;
    gemm_input_ctrl_t                              qcol_zp_consumer_ctrl;
    gemm_qreg_idx_t                                scale_last_consume_idx;
    gemm_qreg_idx_t                                zp_last_consume_idx;

    // -------------------------------------------------------------------------
    // Output Scaler Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0]                           out_scaler_a_ready;
    logic [`MXU_COL-1:0]                           out_scaler_b_ready;
    logic                                          out_scaler_input_ready;
`ifdef GEMM_UNIT_FP16_OUT_SCALE
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           scaled_fp_out_data;
    logic [`MXU_COL-1:0]                           scaler_output_valid;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           scaler_bypass_data;
    logic                                          scaler_bypass_valid;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           final_scaled_fp_out_data;
    logic                                          final_scaler_output_valid;
`else
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           scaled_fp_out_data;
    logic [`MXU_COL-1:0]                           scaler_output_valid;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           scaler_bypass_data;
    logic                                          scaler_bypass_valid;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           final_scaled_fp_out_data;
    logic                                          final_scaler_output_valid;
`endif

    // -------------------------------------------------------------------------
    // scaled output to fp32
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           scaled_fp32_out_data;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           scaled_fp32_aligned_data;
    logic                                          scaled_fp32_aligned_valid;

    // -------------------------------------------------------------------------
    // Accumulator Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           acc_output_data;
    logic [`MXU_COL-1:0]                           acc_output_valid;
    logic [`MXU_COL-1:0]                           acc_in_data_valid;
    logic [`MXU_COL-1:0]                           acc_psum_data_valid;


    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] qcol_reduce_data_in;
    logic signed [`ACT_REDUCE_OUT_WIDTH-1:0] qcol_reduce_data_out;
    logic qcol_reduce_valid_out;
    logic [`MXU_COL-1:0][`ZP_MUL_OUT_WIDTH-1:0] qcol_zp_mul_data;
    logic [`MXU_COL-1:0][`ZP_MUL_OUT_WIDTH-1:0] qcol_zp_mul_data_q;
    logic qcol_zp_mul_valid;

    logic [`MXU_ROW-1:0][`ZP_MUL_OUT_WIDTH-1:0] qrow_zp_mul_data;
    logic [`MXU_ROW-1:0][`ZP_MUL_OUT_WIDTH-1:0] qrow_zp_mul_data_q;
    logic qrow_zp_mul_valid;
    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] qrow_reduce_data_in;
    logic signed [`ACT_REDUCE_OUT_WIDTH-1:0] qrow_reduce_data_out;
    logic qrow_reduce_valid_out;

    gemm_input_ctrl_t ctrl_pipe [0:WRITE_CTRL_IDX];
    logic [WRITE_CTRL_IDX:0] early_pipe;
    logic [WRITE_CTRL_IDX:0] forward_pipe;
    logic [WRITE_CTRL_IDX:0] history_forward_pipe;

    logic [3:0] early_read_req;
    logic [3:0] nominal_read_req;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_req_addr;
    logic [3:0] early_rsp_pending;
    logic [3:0] early_hold_valid;
    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0] early_hold_data;

    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0] acc_mem_out_data;
    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0] acc_mem_in_data;
    logic [3:0][`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] acc_mem_addr;
    logic [3:0] acc_mem_rd_en;
    logic [3:0] acc_mem_wr_en;

    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] selected_psum_data;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] load_result_data;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] writeback_result_data;
    logic writeback_history_valid;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] writeback_history_addr;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0] writeback_history_data;
    logic load_result_valid;
    logic acc_write_fire;
    logic [1:0] write_bank;
    logic [1:0] accum_bank;
    logic [1:0] output_read_bank;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_read_addr;
    logic output_read_fire;
    logic output_read_valid;
    logic [1:0] compute_group_busy;
    logic output_group_conflict;
    logic [3:0] compute_bank_read_req;
    logic [3:0] output_bank_read_req;
    logic [1:0] output_read_bank_q;
    logic [$bits(o_lmem_bus_if.req_data.tag)-1:0] output_read_tag_q;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] fp16_out_data;
    logic [`MXU_COL-1:0] fp16_out_valid;
    logic [1:0] wreg_busy;
    logic [1:0] wreg_preconsume_busy;
    logic [1:0] sreg_busy;
    logic [1:0] zreg_busy;
    logic [1:0] sreg_preconsume_busy;
    logic [1:0] zreg_preconsume_busy;
    logic pipeline_busy;
    logic pre_region_busy;
    logic tree_region_busy;
    logic post_region_busy;
    logic acc_pending_busy;
    logic resource_ownership_busy;
    logic pipeline_retire;
    logic [PIPELINE_PENDING_COUNTW-1:0] pipeline_pending_count;
    logic [7:0] zreg_pending_count [0:1];
    logic [7:0] compute_group_pending_count [0:1];
    logic post_launch_forward;
    logic post_launch_history_forward;
    logic post_launch_early;

    wire input_fire = i_lmem_bus_if.req_valid
                    && i_lmem_bus_if.req_ready;
    wire input_stage_is_qcol
        = in_pipe_payload_out.ctrl.quant_dir == `QDIR_COL;
    wire prealign_stage_out_is_qcol
        = pre_meta_out.ctrl.quant_dir == `QDIR_COL;
    wire preprocess_out_is_qcol
        = tree_meta_pipe[PREPROCESS_CTRL_IDX-PREALIGN_CTRL_IDX-1]
            .ctrl.quant_dir == `QDIR_COL;
    wire scaler_stage_is_qcol
        = ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].quant_dir == `QDIR_COL;

    always_comb begin
        admitted_ctrl = gemm_unit_v2_if.packet_ctrl;
        admitted_ctrl.valid = input_fire;
        in_pipe_payload_in.data = i_lmem_bus_if.req_data.data;
        in_pipe_payload_in.ctrl = admitted_ctrl;
    end

    assign i_lmem_bus_if.req_ready
        = gemm_unit_v2_if.input_admission_ready && in_pipe_ready_in;
    assign i_lmem_bus_if.rsp_valid = 1'b0;
    assign gemm_unit_v2_if.last_write = acc_write_fire
                                      && ctrl_pipe[WRITE_CTRL_IDX].last;
    assign gemm_unit_v2_if.tagged_final_writeback
        = gemm_unit_v2_if.last_write
       && ctrl_pipe[WRITE_CTRL_IDX].notify_on_writeback;
    // Architectural executor completion endpoints.  These pulses are taken
    // after the unit's own acceptance/pipeline logic, at the cycles in which
    // the selected weight or scale/zero register is actually written.
    assign gemm_unit_v2_if.weight_register_write = mxu_ready_weight;
    assign gemm_unit_v2_if.scale_register_write = scale_reg_wr_en;
    assign gemm_unit_v2_if.zero_point_register_write = zp_reg_wr_en;
    assign gemm_unit_v2_if.quant_register_write
        = scale_reg_wr_en || zp_reg_wr_en;
    assign qrow_scale_consumer_ctrl = in_pipe_payload_out.ctrl;
    assign qcol_scale_consumer_ctrl = int2fp_result_data_out.ctrl;
    assign qrow_zp_consumer_ctrl = pre_meta_out.ctrl;
    assign qcol_zp_consumer_ctrl
        = tree_meta_pipe[ACT_REDUCE_OUT_DLY-1].ctrl;
    assign qrow_scale_consumer_fire
        = qrow_scaler_issue;
    assign qcol_scale_consumer_fire
        = scaler_consumer_fire
       && (qcol_scale_consumer_ctrl.quant_dir == `QDIR_COL);
    assign qrow_scale_consume_last
        = qrow_scale_consumer_fire && qrow_scale_consumer_ctrl.last;
    assign qcol_scale_consume_last
        = qcol_scale_consumer_fire && qcol_scale_consumer_ctrl.last;
    assign scale_last_consume_idx = qcol_scale_consume_last
        ? qcol_scale_consumer_ctrl.sreg_use_idx
        : qrow_scale_consumer_ctrl.sreg_use_idx;
    assign gemm_unit_v2_if.scale_consume_valid
        = qrow_scale_consume_last || qcol_scale_consume_last;
    assign gemm_unit_v2_if.scale_consume_idx = scale_last_consume_idx;

    assign qrow_zp_consumer_fire
        = compute_fire
       && (qrow_zp_consumer_ctrl.quant_dir == `QDIR_ROW);
    assign qcol_zp_consumer_fire = qcol_reduce_valid_out;
    assign qrow_zp_consume_last
        = qrow_zp_consumer_fire && qrow_zp_consumer_ctrl.last;
    assign qcol_zp_consume_last
        = qcol_zp_consumer_fire
       && qcol_zp_consumer_ctrl.last;
    assign zp_last_consume_idx = qcol_zp_consume_last
        ? qcol_zp_consumer_ctrl.zreg_use_idx
        : qrow_zp_consumer_ctrl.zreg_use_idx;
    assign gemm_unit_v2_if.zp_consume_valid
        = qrow_zp_consume_last || qcol_zp_consume_last;
    assign gemm_unit_v2_if.zp_consume_idx = zp_last_consume_idx;
    assign gemm_unit_v2_if.weight_consume_valid
        = compute_fire && pre_meta_out.ctrl.last;
    assign gemm_unit_v2_if.weight_consume_idx
        = pre_meta_out.ctrl.wreg_use_idx;
    // A packet retires only when its final control reaches the commit edge.
    // Write packets additionally require the aligned datapath result to fire;
    // a missing result therefore cannot create a false-empty indication.
    assign pipeline_retire
        = ctrl_pipe[WRITE_CTRL_IDX].valid
       && (!ctrl_pipe[WRITE_CTRL_IDX].acc_wr_en || acc_write_fire);
    assign gemm_unit_v2_if.pipeline_empty
        = !(i_lmem_bus_if.req_valid
          || (pipeline_pending_count != 0)
          || pipeline_busy);

    assign post_launch_forward
        = int2fp_result_pop
       && int2fp_result_data_out.ctrl.acc_rd_en
       && ctrl_pipe[MERGER_CTRL_IDX].valid
       && ctrl_pipe[MERGER_CTRL_IDX].acc_wr_en
       && (ctrl_pipe[MERGER_CTRL_IDX].acc_wr_addr
        == int2fp_result_data_out.ctrl.acc_rd_addr);
    assign post_launch_history_forward
        = int2fp_result_pop
       && int2fp_result_data_out.ctrl.acc_rd_en
       && !post_launch_forward
       && ctrl_pipe[MERGER_CTRL_IDX+1].valid
       && ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_en
       && (ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_addr
        == int2fp_result_data_out.ctrl.acc_rd_addr);
    assign post_launch_early
        = int2fp_result_pop
       && int2fp_result_data_out.ctrl.acc_rd_en
       && !post_launch_forward
       && !post_launch_history_forward
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].valid
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_en
       && (get_acc_mem_idx(
               ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_addr)
        == get_acc_mem_idx(int2fp_result_data_out.ctrl.acc_rd_addr));

    // Control before the tree follows the elastic transaction, control in the
    // tree is a fixed five-cycle shift, and post control starts only when the
    // corresponding merged FIFO head is launched.  This makes the old
    // distance-based ACC classification local to the fixed post island.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int i = 0; i <= WRITE_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= '0;
                early_pipe[i] <= 1'b0;
                forward_pipe[i] <= 1'b0;
                history_forward_pipe[i] <= 1'b0;
            end
        end else begin
            // Admission ownership is observable immediately after the
            // accepting edge.  This is not the active u_in_pipe payload and
            // is never used to advance the elastic pre-process datapath.
            ctrl_pipe[INPUT_CTRL_IDX] <= admitted_ctrl;
            ctrl_pipe[INPUT_CTRL_IDX].valid <= input_fire;
            ctrl_pipe[PREALIGN_INPUT_CTRL_IDX] <= pre_branch_meta.ctrl;
            ctrl_pipe[PREALIGN_INPUT_CTRL_IDX].valid <= pre_branch_valid;
            for (int i = PREALIGN_INPUT_CTRL_IDX + 1;
                 i < PREALIGN_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= '0;
            end
            ctrl_pipe[PREALIGN_CTRL_IDX] <= pre_meta_out.ctrl;
            ctrl_pipe[PREALIGN_CTRL_IDX].valid <= pre_meta_valid_out;
            ctrl_pipe[PREALIGN_CTRL_IDX+1] <= compute_meta.ctrl;
            ctrl_pipe[PREALIGN_CTRL_IDX+1].valid <= compute_fire;
            for (int i = PREALIGN_CTRL_IDX + 2;
                 i <= MXU_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= ctrl_pipe[i-1];
            end
            ctrl_pipe[MERGER_CTRL_IDX] <= int2fp_result_data_out.ctrl;
            ctrl_pipe[MERGER_CTRL_IDX].valid <= int2fp_result_pop;
            for (int i = MERGER_CTRL_IDX + 1;
                 i <= WRITE_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= ctrl_pipe[i-1];
            end

            for (int i = 0; i < MERGER_CTRL_IDX; ++i) begin
                early_pipe[i] <= 1'b0;
                forward_pipe[i] <= 1'b0;
                history_forward_pipe[i] <= 1'b0;
            end
            early_pipe[MERGER_CTRL_IDX] <= post_launch_early;
            forward_pipe[MERGER_CTRL_IDX] <= post_launch_forward;
            history_forward_pipe[MERGER_CTRL_IDX]
                <= post_launch_history_forward;
            for (int i = MERGER_CTRL_IDX + 1;
                 i <= WRITE_CTRL_IDX; ++i) begin
                early_pipe[i] <= early_pipe[i-1];
                forward_pipe[i] <= forward_pipe[i-1];
                history_forward_pipe[i] <= history_forward_pipe[i-1];
            end
        end
    end

    always_comb begin
        // Future-version waiters do not own the currently loaded bank.  The
        // exact LDMA writer_wait is the architectural W/S/Z overwrite fence.
        // Only QCOL Z has a multi-cycle direct-register read lifetime after
        // its common-fork readiness check.
        wreg_busy = '0;
        wreg_preconsume_busy = '0;
        sreg_busy = '0;
        sreg_preconsume_busy = '0;
        for (int i = 0; i < 2; ++i) begin
            zreg_busy[i] = (zreg_pending_count[i] != 0);
            zreg_preconsume_busy[i]
                = (compute_fire
                && (qrow_zp_consumer_ctrl.quant_dir == `QDIR_COL)
                && (qrow_zp_consumer_ctrl.zreg_use_idx
                    == gemm_qreg_idx_t'(i)))
               || (zreg_pending_count[i] > 1)
               || ((zreg_pending_count[i] == 1)
                && !(qcol_zp_consumer_fire
                  && (qcol_zp_consumer_ctrl.zreg_use_idx
                      == gemm_qreg_idx_t'(i))));
        end
        compute_group_busy[0] = (compute_group_pending_count[0] != 0);
        compute_group_busy[1] = (compute_group_pending_count[1] != 0);
        // Visible ownership is split by region for waveform/debug clarity.
        // pipeline_pending_count is the authoritative cover for opaque valid
        // state inside the elastic scaler and prealigner submodules.
        pre_region_busy = in_pipe_valid_out
                       || qcol_branch_valid_out
                       || qrow_meta_valid_out
                       || qrow_scaler_output_valid
                       || (|in_scaler_result_valid)
                       || pre_branch_valid
                       || pre_meta_valid_out
                       || prealigner_out_valid;
        tree_region_busy = (|tree_valid_pipe)
                        || qcol_reduce_valid_out
                        || qcol_zp_mul_valid
                        || qrow_zp_mul_valid
                        || qrow_reduce_valid_out
                        || pre_proc_in_valid
                        || pre_proc_out_valid
                        || merger_in_valid
                        || merged_fifo_push
                        || !merged_fifo_empty
                        || (tree_credit_q
                         != MERGED_FIFO_COUNTW'(
                                MERGED_RESULT_FIFO_DEPTH))
                        || credit_return_q;
        post_region_busy = merged_fifo_pop
                        || merger_out_valid
                        || (|int2fp_output_valid)
                        || (|int2fp_meta_valid_pipe)
                        || !int2fp_result_empty
                        || int2fp_result_push
                        || int2fp_result_pop
                        || (|scaler_output_valid)
                        || scaler_bypass_valid
                        || final_scaler_output_valid
                        || scaled_fp32_aligned_valid
                        || load_result_valid
                        || (|acc_output_valid)
                        || acc_write_fire;
        acc_pending_busy = (|early_read_req)
                        || (|nominal_read_req)
                        || (|early_rsp_pending)
                        || (|early_hold_valid)
                        || (|early_pipe)
                        || (|forward_pipe)
                        || (|history_forward_pipe);
        resource_ownership_busy = (pipeline_pending_count != 0);
        for (int i = 0; i < 2; ++i) begin
            resource_ownership_busy
                |= (zreg_pending_count[i] != 0);
        end
        for (int i = 0; i < 2; ++i)
            resource_ownership_busy
                |= (compute_group_pending_count[i] != 0);
        pipeline_busy = pre_region_busy
                     || tree_region_busy
                     || post_region_busy
                     || acc_pending_busy
                     || resource_ownership_busy;
        for (int i = 0; i <= WRITE_CTRL_IDX; ++i)
            pipeline_busy |= ctrl_pipe[i].valid;
    end

    always_ff @(posedge clk or posedge reset) begin : pending_ownership
        if (reset) begin
            pipeline_pending_count <= '0;
            for (int i = 0; i < 2; ++i) begin
                zreg_pending_count[i] <= '0;
            end
            for (int i = 0; i < 2; ++i)
                compute_group_pending_count[i] <= '0;
        end else begin
            case ({input_fire, pipeline_retire})
                2'b10: pipeline_pending_count
                    <= pipeline_pending_count + 1'b1;
                2'b01: pipeline_pending_count
                    <= pipeline_pending_count - 1'b1;
                default: begin end
            endcase
            for (int i = 0; i < 2; ++i) begin
                case ({compute_fire
                       && (qrow_zp_consumer_ctrl.quant_dir == `QDIR_COL)
                       && (qrow_zp_consumer_ctrl.zreg_use_idx
                           == gemm_qreg_idx_t'(i)),
                       qcol_zp_consumer_fire
                       && (qcol_zp_consumer_ctrl.zreg_use_idx
                           == gemm_qreg_idx_t'(i))})
                    2'b10: zreg_pending_count[i]
                        <= zreg_pending_count[i] + 1'b1;
                    2'b01: zreg_pending_count[i]
                        <= zreg_pending_count[i] - 1'b1;
                    default: begin end
                endcase
            end
            for (int i = 0; i < 2; ++i) begin
                case ({input_fire
                       && ((gemm_unit_v2_if.packet_ctrl.acc_rd_en
                         && (get_acc_group(
                              gemm_unit_v2_if.packet_ctrl.acc_rd_addr)
                             == logic'(i)))
                        || (gemm_unit_v2_if.packet_ctrl.acc_wr_en
                         && (get_acc_group(
                              gemm_unit_v2_if.packet_ctrl.acc_wr_addr)
                             == logic'(i)))),
                       pipeline_retire
                       && ((ctrl_pipe[WRITE_CTRL_IDX].acc_rd_en
                         && (get_acc_group(
                              ctrl_pipe[WRITE_CTRL_IDX].acc_rd_addr)
                             == logic'(i)))
                        || (ctrl_pipe[WRITE_CTRL_IDX].acc_wr_en
                         && (get_acc_group(
                              ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr)
                             == logic'(i))))})
                    2'b10: compute_group_pending_count[i]
                        <= compute_group_pending_count[i] + 1'b1;
                    2'b01: compute_group_pending_count[i]
                        <= compute_group_pending_count[i] - 1'b1;
                    default: begin end
                endcase
            end
        end
    end

`ifdef WLOAD_AT_ONCE
    wire mxu_w_pipe_valid_out;
    // The PREALIGN final consumer captures the old Weight value on this edge.
    // A matching staged writer may update the same bank on the edge only when
    // no incoming or earlier pipeline entry can still consume that version.
    wire same_cycle_weight_release
        = gemm_unit_v2_if.weight_consume_valid
       && (gemm_unit_v2_if.weight_consume_idx == wreg_wr_idx)
       && !wreg_preconsume_busy[wreg_wr_idx];
    wire mxu_w_pipe_ready_out = !wreg_busy[wreg_wr_idx]
                              || same_cycle_weight_release;

    VX_pipe_buffer #(
        .DATAW (`MXU_WLOAD_NUM * `MXU_COL * `W_BIT_WIDTH + 2),
        .DEPTH (1)
    ) u_mxu_weight_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (w_lmem_bus_if.req_valid),
        .ready_in  (w_lmem_bus_if.req_ready),
        .data_in   ({w_lmem_bus_if.req_data.data,
                     w_lmem_bus_if.req_data.addr[1:0]}),
        .ready_out (mxu_w_pipe_ready_out),
        .data_out  ({mxu_weight, wreg_load_dir, wreg_wr_idx}),
        .valid_out (mxu_w_pipe_valid_out)
    );
    assign mxu_ready_weight = mxu_w_pipe_valid_out && mxu_w_pipe_ready_out;
`else
    assign mxu_weight = w_lmem_bus_if.req_data.data;
    assign wreg_wr_idx = w_lmem_bus_if.req_data.addr[0];
    assign wreg_load_dir = w_lmem_bus_if.req_data.addr[1];
    wire same_cycle_weight_release
        = gemm_unit_v2_if.weight_consume_valid
       && (gemm_unit_v2_if.weight_consume_idx == wreg_wr_idx)
       && !wreg_preconsume_busy[wreg_wr_idx];
    assign w_lmem_bus_if.req_ready = !wreg_busy[wreg_wr_idx]
                                   || same_cycle_weight_release;
    assign mxu_ready_weight = w_lmem_bus_if.req_valid
                            && w_lmem_bus_if.req_ready;
`endif
    assign w_lmem_bus_if.rsp_valid = 1'b0;

    assign sc_req_hs = sc_lmem_bus_if.req_valid && sc_lmem_bus_if.req_ready;
    assign sc_req_rw = sc_lmem_bus_if.req_data.rw;
    assign sc_req_addr = $bits(sc_req_addr)'(sc_lmem_bus_if.req_data.addr);
    assign sc_req_data = sc_lmem_bus_if.req_data.data;
    wire same_cycle_scale_release
        = ((qrow_scale_consumer_fire
         && (qrow_scale_consumer_ctrl.sreg_use_idx == scale_reg_idx))
        || (qcol_scale_consumer_fire
         && (qcol_scale_consumer_ctrl.sreg_use_idx == scale_reg_idx)))
       && !sreg_preconsume_busy[scale_reg_idx];
    assign sc_lmem_bus_if.req_ready
        = scale_reg_wr_req
        ? (!sreg_busy[scale_reg_idx] || same_cycle_scale_release) : 1'b1;
    assign sc_lmem_bus_if.rsp_valid = 1'b0;

    assign zp_req_hs = zp_lmem_bus_if.req_valid && zp_lmem_bus_if.req_ready;
    assign zp_req_rw = zp_lmem_bus_if.req_data.rw;
    assign zp_req_addr = $bits(zp_req_addr)'(zp_lmem_bus_if.req_data.addr);
    assign zp_req_data = zp_lmem_bus_if.req_data.data;
    wire same_cycle_zp_release
        = ((qrow_zp_consumer_fire
         && (qrow_zp_consumer_ctrl.zreg_use_idx == zp_reg_idx))
        || (qcol_zp_consumer_fire
         && (qcol_zp_consumer_ctrl.zreg_use_idx == zp_reg_idx)))
       && !zreg_preconsume_busy[zp_reg_idx];
    assign zp_lmem_bus_if.req_ready
        = zp_reg_wr_req
        ? (!zreg_busy[zp_reg_idx] || same_cycle_zp_release) : 1'b1;
    assign zp_lmem_bus_if.rsp_valid = 1'b0;

    // =========================================================================
    // Scale/Zero Register Write Logic
    // =========================================================================
    // Address map:
    //   [0, MAX_DIM*SCALE_WIDTH/8)         : scale_regs[0]
    //   [MAX_DIM*SCALE_WIDTH/8, 2*...)     : scale_regs[1]
    //   [2*..., 2*...+MAX_DIM*ZP_WIDTH/8)  : zero_regs[0]
    //   [2*...+..., ...)                   : zero_regs[1]

    // ----- Decode which register to write -----
    always_comb begin
        scale_reg_idx   = 0;
        zp_reg_idx      = 0;
        scale_reg_wr_req = 0;
        zp_reg_wr_req    = 0;

        if (sc_lmem_bus_if.req_valid && sc_req_rw) begin
            scale_reg_idx = (sc_req_addr >= SCALE_REG1_BASE);
            scale_reg_wr_req = (sc_req_addr < ZP_REG0_BASE);
        end

        if (zp_lmem_bus_if.req_valid && zp_req_rw) begin
            zp_reg_idx = (zp_req_addr >= ZP_REG1_BASE);
            zp_reg_wr_req = (zp_req_addr >= ZP_REG0_BASE);
        end

    end

    assign scale_reg_wr_en = sc_req_hs && scale_reg_wr_req;
    assign zp_reg_wr_en = zp_req_hs && zp_reg_wr_req;

    // ----- Write to scale registers (byte-enable masked) -----
    wire [`GEMM_SCALE_ZERO_DATA_SIZE-1:0] sc_req_byteen
        = sc_lmem_bus_if.req_data.byteen;
    wire [`GEMM_SCALE_ZERO_DATA_SIZE-1:0] zp_req_byteen
        = zp_lmem_bus_if.req_data.byteen;

    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            scale_regs <= '0;
        end else begin
            if (scale_reg_wr_en) begin
                for (int i = 0; i < `MAX(`MXU_ROW, `MXU_COL); i++) begin
                    if (sc_req_byteen[i * (`SCALE_WIDTH/8) +: (`SCALE_WIDTH/8)] != '0) begin
                        scale_regs[scale_reg_idx][i] <= sc_req_data[i * `SCALE_WIDTH +: `SCALE_WIDTH];
                    end
                end
            end
        end
    end

    // ----- Write to zero point registers (byte-enable masked) -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            zero_regs <= '0;
        end else begin
            if (zp_reg_wr_en) begin
                for (int i = 0; i < `MAX(`MXU_ROW, `MXU_COL); i++) begin
                    if (zp_req_byteen[i * (`ZP_WIDTH/8) +: (`ZP_WIDTH/8)] != '0) begin
                        zero_regs[zp_reg_idx][i] <= -1*signed'(zp_req_data[i*`ZP_WIDTH +: `ZP_WIDTH]);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Datapath Combinational Logic
    // =========================================================================

    // ----- Prealigner Input Selection -----
    assign prealigner_in_data = pre_branch_data;
    assign prealigner_in_valid = prealign_issue;

    // ----- Merger Input Valid -----
    assign merger_in_valid = &mxu_output_valid_dly;

    // =========================================================================
    // Sub-module Instantiations
    // =========================================================================

    // -------------------------------------------------------------------------
    // Input Pipeline and QCOL/QROW Alignment
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW ($bits(pre_input_payload_t)),
        .DEPTH (DEFAULT_OUT_DLY)
    ) u_in_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (input_fire),
        .ready_in  (in_pipe_ready_in),
        .data_in   (in_pipe_payload_in),
        .data_out  (in_pipe_payload_out),
        .ready_out (input_stage_ready),
        .valid_out (in_pipe_valid_out)
    );
    assign in_pipe_data_out = in_pipe_payload_out.data;

    // The QCOL bypass and QROW multiplier are parallel physical paths but
    // share one ordered output.  Do not admit the opposite QDIR while an item
    // is resident in either branch; otherwise a downstream stall could make
    // both branches valid and consume two inputs as one transaction.
    assign input_stage_ready = input_stage_is_qcol
                             ? (qcol_branch_ready_in
                             && !qrow_meta_valid_out)
                             : (qrow_scaler_input_ready
                             && !qcol_branch_valid_out);
    assign input_stage_fire = in_pipe_valid_out && input_stage_ready;

    VX_pipe_buffer #(
        .DATAW ($bits(pre_input_payload_t)),
        .DEPTH (INPUT_SCALE_DLY)
    ) u_qcol_input_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (input_stage_fire && input_stage_is_qcol),
        .ready_in  (qcol_branch_ready_in),
        .data_in   (in_pipe_payload_out),
        .data_out  (qcol_branch_payload_out),
        .ready_out (pre_branch_ready),
        .valid_out (qcol_branch_valid_out)
    );
    assign qrow_scaler_input_ready
        = qrow_meta_ready_in
       && (&in_scaler_a_ready)
       && (&in_scaler_b_ready)
       && qrow_scale_ready
       && scale_consume_channel_ready;
    assign qrow_scale_ready
        = gemm_unit_v2_if.s_load_value[
              qrow_scale_consumer_ctrl.sreg_use_idx]
       == qrow_scale_consumer_ctrl.s_load_target;
    // A resource has one architectural consume event channel.  If an older
    // QCOL final result consumes Scale on this cycle, hold a QROW-final input
    // for one cycle; non-final direct reads remain freely concurrent.
    assign scale_consume_channel_ready
        = !(in_pipe_payload_out.ctrl.last && qcol_scale_consume_last);
    assign qrow_scaler_issue
        = input_stage_fire && !input_stage_is_qcol;

    VX_pipe_buffer #(
        .DATAW ($bits(pre_meta_t)),
        .DEPTH (INPUT_SCALE_DLY)
    ) u_qrow_input_meta (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (qrow_scaler_issue),
        .ready_in  (qrow_meta_ready_in),
        .data_in   (in_pipe_payload_out.ctrl),
        .data_out  (qrow_meta_out),
        .ready_out (pre_branch_ready && qrow_scaler_output_valid),
        .valid_out (qrow_meta_valid_out)
    );

    // -------------------------------------------------------------------------
    // Input Scalers
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : gen_in_scaler
            logic activated;
            logic a_valid, b_valid;
            logic [`IFP_WIDTH-1:0] a_data, b_data;

            assign activated = !input_stage_is_qcol;
            assign a_valid   = qrow_scaler_issue;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[`IFP_WIDTH*i +: `IFP_WIDTH] : '0;
            assign b_data    = activated
                ? scale_regs[qrow_scale_consumer_ctrl.sreg_use_idx][i]
                : '0;

            VX_fp16_mul #(
                .LATENCY        (FP16_MUL_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_in_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (in_scaler_a_ready[i]),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (in_scaler_b_ready[i]),
                .b_data       (b_data),
                .result_valid (in_scaler_result_valid[i]),
                .result_ready (in_scaler_result_ready[i]),
                .result_data  (in_scaler_result_data[i])
            );

            assign in_scaler_result_ready[i]
                = pre_branch_ready
               && qrow_meta_valid_out
               && (&in_scaler_result_valid);
        end
    endgenerate

    assign qrow_scaler_output_valid
        = qrow_meta_valid_out && (&in_scaler_result_valid);
    assign pre_branch_valid
        = qcol_branch_valid_out || qrow_scaler_output_valid;
    assign pre_branch_data
        = qcol_branch_valid_out
        ? qcol_branch_payload_out.data : in_scaler_result_data;
    always_comb begin
        if (qcol_branch_valid_out) begin
            pre_branch_meta.ctrl = qcol_branch_payload_out.ctrl;
        end else begin
            pre_branch_meta = qrow_meta_out;
        end
    end

    assign pre_branch_ready = prealigner_ready_out && pre_meta_ready_in;
    assign prealign_issue = pre_branch_valid && pre_branch_ready;
    assign pre_meta_in = pre_branch_meta;

    VX_pipe_buffer #(
        .DATAW ($bits(pre_meta_t)),
        .DEPTH (PREALIGN_DLY)
    ) u_prealign_meta_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (prealign_issue),
        .ready_in  (pre_meta_ready_in),
        .data_in   (pre_meta_in),
        .data_out  (pre_meta_out),
        .ready_out (prealigner_out_valid && compute_ready),
        .valid_out (pre_meta_valid_out)
    );

    // -------------------------------------------------------------------------
    // Prealigner
    // -------------------------------------------------------------------------
    VX_prealigner #(
        .NUM_UNIT(`MXU_ROW)
    ) u_prealigner (
        .clk_i      (clk),
        .resetn_i   (~reset),
        .fp_data_i  (prealigner_in_data),
        .valid_i    (prealigner_in_valid),
        .ready_o    (prealigner_ready_out),
        .int_data_o (prealigner_int_data),
        .blk_idx_o  (prealigner_blk_idx),
        .max_exp_o  (prealigner_max_exp),
        .valid_o    (prealigner_out_valid),
        .ready_i    (pre_meta_valid_out && compute_ready)
    );

    VX_pipe_buffer #(
        .DATAW (`MXU_ROW * `BLOCK_IDX_WIDTH),
        .DEPTH (BLK_IDX_DLY)
    ) u_prealign_blk_idx_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (compute_fire),
        .ready_in  (),
        .data_in   (prealigner_blk_idx),
        .data_out  (prealigner_blk_idx_q),
        .ready_out (1'b1),
        .valid_out (prealigner_pipe_out_valid)
    );

    assign prealigner_max_exp_q = merged_fifo_data_out.max_exp;
    assign prealigner_max_exp_q_valid = merged_fifo_pop;

    // -------------------------------------------------------------------------
    // Parallel QCOL/QROW Pre-processing
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : g_preprocess_inputs
            assign qcol_reduce_data_in[i]
                = `ACT_REDUCE_IN_WIDTH'(signed'(prealigner_int_data[i]))
                <<< (`BLOCK_SIZE * prealigner_blk_idx[i]);
            assign qrow_zp_mul_data[i]
                = signed'(prealigner_int_data[i])
                * signed'(zero_regs[qrow_zp_consumer_ctrl.zreg_use_idx][i]);
            assign qcol_zp_mul_data[i]
                = signed'(qcol_reduce_data_out)
                * signed'(zero_regs[qcol_zp_consumer_ctrl.zreg_use_idx][i]);
        end
    endgenerate

    VX_reduce_tree_pipelined_v2 #(
        .IN_W            (`ACT_REDUCE_IN_WIDTH),
        .OUT_W           (`ACT_REDUCE_OUT_WIDTH),
        .N               (`MXU_ROW),
        .OP              ("+"),
        .PIPELINE_STAGES (ACT_REDUCE_PIPE_STAGES)
    ) u_qcol_act_reduce (
        .clk       (clk),
        .reset     (reset),
        .data_in   (qcol_reduce_data_in),
        .valid_in  (compute_fire && prealign_stage_out_is_qcol),
        .data_out  (qcol_reduce_data_out),
        .valid_out (qcol_reduce_valid_out)
    );

    VX_pipe_buffer #(
        .DATAW (`MXU_COL * `ZP_MUL_OUT_WIDTH),
        .DEPTH (DEFAULT_OUT_DLY)
    ) u_qcol_zp_mul_out (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (qcol_reduce_valid_out),
        .ready_in  (),
        .data_in   (qcol_zp_mul_data),
        .data_out  (qcol_zp_mul_data_q),
        .ready_out (1'b1),
        .valid_out (qcol_zp_mul_valid)
    );

    VX_pipe_buffer #(
        .DATAW (`MXU_ROW * `ZP_MUL_OUT_WIDTH),
        .DEPTH (DEFAULT_OUT_DLY)
    ) u_qrow_zp_mul_out (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (compute_fire && !prealign_stage_out_is_qcol),
        .ready_in  (),
        .data_in   (qrow_zp_mul_data),
        .data_out  (qrow_zp_mul_data_q),
        .ready_out (1'b1),
        .valid_out (qrow_zp_mul_valid)
    );

    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : g_qrow_reduce_inputs
            assign qrow_reduce_data_in[i]
                = `ACT_REDUCE_IN_WIDTH'(signed'(qrow_zp_mul_data_q[i]))
                <<< (`BLOCK_SIZE * prealigner_blk_idx_q[i]);
        end
    endgenerate

    VX_reduce_tree_pipelined_v2 #(
        .IN_W            (`ACT_REDUCE_IN_WIDTH),
        .OUT_W           (`ACT_REDUCE_OUT_WIDTH),
        .N               (`MXU_ROW),
        .OP              ("+"),
        .PIPELINE_STAGES (ACT_REDUCE_PIPE_STAGES)
    ) u_qrow_act_reduce (
        .clk       (clk),
        .reset     (reset),
        .data_in   (qrow_reduce_data_in),
        .valid_in  (qrow_zp_mul_valid),
        .data_out  (qrow_reduce_data_out),
        .valid_out (qrow_reduce_valid_out)
    );

    // -------------------------------------------------------------------------
    // Pre-processor Output
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_pre_proc_out
            assign pre_proc_out[i] = preprocess_out_is_qcol
                                   ? signed'(qcol_zp_mul_data_q[i])
                                   : qrow_reduce_data_out;
        end
    endgenerate
    assign pre_proc_in_valid = preprocess_out_is_qcol
                             ? qcol_zp_mul_valid
                             : qrow_reduce_valid_out;

    VX_pipe_buffer #(
        .DATAW (`MXU_COL * `PRE_PROC_OUT_DW),
        .DEPTH (PRE_PROC_OUT_DLY)
    ) u_pre_proc_pipe_buffer (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (pre_proc_in_valid),
        .ready_in  (),
        .data_in   (pre_proc_out),
        .data_out  (pre_proc_out_q),
        .ready_out (1'b1),
        .valid_out (pre_proc_out_valid)
    );

    // -------------------------------------------------------------------------
    // GEMM Tree (MXU)
    // -------------------------------------------------------------------------
    VX_gemm_tree_v1 u_mxu (
        .clk_i            (clk),
        .resetn_i         (~reset),
        .ifmap_i          (prealigner_int_data),
        .weight_i         (mxu_weight),
        .in_weight_sel_i  (wreg_wr_idx),
        .out_weight_sel_i (pre_meta_out.ctrl.wreg_use_idx),
        .ready_weight_i   (mxu_ready_weight),
        .input_valid_i    (compute_fire),
        .weight_load_dir_i(wreg_load_dir),
        .blk_sidx_i       (prealigner_blk_idx),
        .ps_o             (mxu_output),
        .output_valid_o   (mxu_output_valid)
    );

    // -------------------------------------------------------------------------
    // MXU Output Delay Alignment
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < (`MXU_COL/`MXU_COL_TILE); i++) begin : gen_mxu_output_dly
            VX_pipe_buffer #(
                .DATAW (`MXU_COL_TILE * `O_BIT_WIDTH),
                .DEPTH ((`MXU_COL/`MXU_COL_TILE) - 1 - i)
            ) u_mxu_output_dly_pipe (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (mxu_output_valid[i]),
                .ready_in  (),
                .data_in   (mxu_output[`MXU_COL_TILE*i +: `MXU_COL_TILE]),
                .data_out  (mxu_output_dly[`MXU_COL_TILE*i +: `MXU_COL_TILE]),
                .ready_out (1'b1),
                .valid_out (mxu_output_valid_dly[i])
            );
        end
    endgenerate

    always_comb begin
        compute_meta.ctrl = pre_meta_out.ctrl;
        compute_meta.ctrl.valid = compute_fire;
        compute_meta.max_exp = prealigner_max_exp;
    end

    // The return itself is registered to cut the post-process ready path.  A
    // returned credit can be consumed in the same cycle that it is observed;
    // otherwise a continuously draining FIFO would introduce an unnecessary
    // bubble every time the outstanding count reaches the exact capacity.
    assign weight_ready
        = gemm_unit_v2_if.w_load_value[pre_meta_out.ctrl.wreg_use_idx]
       == pre_meta_out.ctrl.w_load_target;
    assign zero_ready
        = gemm_unit_v2_if.z_load_value[pre_meta_out.ctrl.zreg_use_idx]
       == pre_meta_out.ctrl.z_load_target;
    assign compute_ready
        = ((tree_credit_q != 0) || credit_return_q)
       && weight_ready
       && zero_ready
       && zp_consume_channel_ready;
    // QCOL owns the single Zero-point consume channel on a collision.  The
    // QROW final fork is elastic and retries on the next cycle.
    assign zp_consume_channel_ready
        = !((pre_meta_out.ctrl.quant_dir == `QDIR_ROW)
         && pre_meta_out.ctrl.last
         && qcol_zp_consume_last);
    assign compute_fire = prealigner_out_valid
                       && pre_meta_valid_out
                       && compute_ready;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            tree_valid_pipe <= '0;
            for (int i = 0; i < MXU_OUT_DLY; ++i)
                tree_meta_pipe[i] <= '0;
        end else begin
            tree_valid_pipe[0] <= compute_fire;
            tree_meta_pipe[0] <= compute_meta;
            for (int i = 1; i < MXU_OUT_DLY; ++i) begin
                tree_valid_pipe[i] <= tree_valid_pipe[i-1];
                tree_meta_pipe[i] <= tree_meta_pipe[i-1];
            end
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            tree_credit_q <= MERGED_FIFO_COUNTW'(MERGED_RESULT_FIFO_DEPTH);
            credit_return_q <= 1'b0;
        end else begin
            credit_return_q <= merged_fifo_pop;
            case ({compute_fire, credit_return_q})
                2'b10: tree_credit_q <= tree_credit_q - 1'b1;
                2'b01: tree_credit_q <= tree_credit_q + 1'b1;
                default: begin end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Merger
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_merger
            assign merger_out_data[i]
                = `MERGE_OUT_BW'(signed'(mxu_output_dly[i]))
                + `MERGE_OUT_BW'(signed'(pre_proc_out_q[i]));
        end
    endgenerate

    always_comb begin
        merged_fifo_data_in.data = merger_out_data;
        merged_fifo_data_in.max_exp
            = tree_meta_pipe[MXU_OUT_DLY-1].max_exp;
        merged_fifo_data_in.ctrl
            = tree_meta_pipe[MXU_OUT_DLY-1].ctrl;
    end

    assign merged_fifo_empty = (merged_fifo_count == 0);
    assign merged_fifo_full
        = (merged_fifo_count
        == MERGED_FIFO_COUNTW'(MERGED_RESULT_FIFO_DEPTH));
    assign merged_fifo_push = merger_in_valid && pre_proc_out_valid;
    // Fall through when empty so this FIFO replaces the former merge output
    // register rather than adding another no-stall pipeline cycle.  A direct
    // push/pop still advances both pointers while leaving count at zero.
    assign merged_fifo_data_out
        = merged_fifo_empty
        ? merged_fifo_data_in
        : merged_fifo_mem[merged_fifo_rd_ptr];
    assign merged_fifo_pop
        = (!merged_fifo_empty || merged_fifo_push)
       && postprocess_ready
       && int2fp_launch_ready;
    assign merger_out_data_q = merged_fifo_data_out.data;
    assign merger_out_valid = merged_fifo_pop;

    function automatic [MERGED_FIFO_PTRW-1:0] merged_fifo_ptr_next(
        input logic [MERGED_FIFO_PTRW-1:0] ptr
    );
        return (ptr == MERGED_FIFO_PTRW'(MERGED_RESULT_FIFO_DEPTH-1))
             ? '0 : ptr + 1'b1;
    endfunction

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            merged_fifo_wr_ptr <= '0;
            merged_fifo_rd_ptr <= '0;
            merged_fifo_count <= '0;
            for (int i = 0; i < MERGED_RESULT_FIFO_DEPTH; ++i)
                merged_fifo_mem[i] <= '0;
        end else begin
            if (merged_fifo_push) begin
                merged_fifo_mem[merged_fifo_wr_ptr]
                    <= merged_fifo_data_in;
                merged_fifo_wr_ptr
                    <= merged_fifo_ptr_next(merged_fifo_wr_ptr);
            end
            if (merged_fifo_pop)
                merged_fifo_rd_ptr
                    <= merged_fifo_ptr_next(merged_fifo_rd_ptr);
            case ({merged_fifo_push, merged_fifo_pop})
                2'b10: merged_fifo_count <= merged_fifo_count + 1'b1;
                2'b01: merged_fifo_count <= merged_fifo_count - 1'b1;
                default: begin end
            endcase
        end
    end

    // Reserve output storage before launching the no-ready VX_pint2fp
    // pipeline.  The reservation spans converter in-flight state and the
    // result FIFO, so an arbitrary Scale stall cannot overflow either.
    assign int2fp_launch_ready
        = (int2fp_result_credit != 0) || int2fp_result_pop;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            int2fp_result_credit
                <= INT2FP_RESULT_FIFO_COUNTW'(INT2FP_RESULT_FIFO_DEPTH);
            int2fp_meta_valid_pipe <= '0;
            for (int i = 0; i < INT2FP_CONVERTER_META_DLY; ++i)
                int2fp_meta_pipe[i] <= '0;
        end else begin
            case ({merged_fifo_pop, int2fp_result_pop})
                2'b10: int2fp_result_credit <= int2fp_result_credit - 1'b1;
                2'b01: int2fp_result_credit <= int2fp_result_credit + 1'b1;
                default: begin end
            endcase
            int2fp_meta_valid_pipe[0] <= merged_fifo_pop;
            int2fp_meta_pipe[0] <= merged_fifo_data_out.ctrl;
            for (int i = 1; i < INT2FP_CONVERTER_META_DLY; ++i) begin
                int2fp_meta_valid_pipe[i] <= int2fp_meta_valid_pipe[i-1];
                int2fp_meta_pipe[i] <= int2fp_meta_pipe[i-1];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Integer to FP32 Converters
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_int2fp
            VX_pint2fp #(
                .IN_DW             (`MERGE_OUT_BW),
                .OUT_DW            (GEMM_UNIT_FP16_OUT_SCALE ? FP16_WIDTH : FP32_WIDTH),
                .IN_EXP_WIDTH      (FP16_EXP_WIDTH),
                .OUT_EXP_WIDTH     (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_WIDTH : FP32_EXP_WIDTH),
                .IN_EXP_BIAS       (FP16_EXP_BIAS),
                .OUT_EXP_BIAS      (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_BIAS : FP32_EXP_BIAS),
                .OUT_MANTISSA_WIDTH(GEMM_UNIT_FP16_OUT_SCALE ? FP16_MAN_WIDTH : FP32_MAN_WIDTH),
                .SCALE             (FP16_MAN_WIDTH + `EXTRA_BIT_WIDTH) // extra bit already reflect FP16 and FP32 mantissa diff
            ) u_int2fp (
                .clk_i      (clk),
                .resetn_i   (~reset),
                .int_data_i (merger_out_data_q[i]),
                .max_exp_i  (prealigner_max_exp_q),
                .valid_i    (merger_out_valid),
                .fp_data_o  (int2fp_out_data[i]),
                .valid_o    (int2fp_output_valid[i])
            );
        end
    endgenerate

    always_comb begin
        int2fp_result_data_in.data = int2fp_out_data;
        int2fp_result_data_in.ctrl
            = int2fp_meta_pipe[INT2FP_CONVERTER_META_DLY-1];
        int2fp_result_data_in.ctrl.valid = int2fp_result_push;
    end
    assign int2fp_result_push = &int2fp_output_valid;
    assign int2fp_result_empty = (int2fp_result_count == 0);
    assign int2fp_result_full
        = (int2fp_result_count
        == INT2FP_RESULT_FIFO_COUNTW'(INT2FP_RESULT_FIFO_DEPTH));
    assign int2fp_result_data_out = int2fp_result_empty
        ? int2fp_result_data_in
        : int2fp_result_mem[int2fp_result_rd_ptr];
    assign qcol_scale_ready
        = gemm_unit_v2_if.s_load_value[
              qcol_scale_consumer_ctrl.sreg_use_idx]
       == qcol_scale_consumer_ctrl.s_load_target;
    assign out_scaler_input_ready
        = (&out_scaler_a_ready) && (&out_scaler_b_ready);
    assign int2fp_result_pop
        = (!int2fp_result_empty || int2fp_result_push)
       && ((int2fp_result_data_out.ctrl.quant_dir == `QDIR_ROW)
        || (qcol_scale_ready && out_scaler_input_ready));
    assign scaler_consumer_fire = int2fp_result_pop;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            int2fp_result_wr_ptr <= '0;
            int2fp_result_rd_ptr <= '0;
            int2fp_result_count <= '0;
            for (int i = 0; i < INT2FP_RESULT_FIFO_DEPTH; ++i)
                int2fp_result_mem[i] <= '0;
        end else begin
            if (int2fp_result_push) begin
                int2fp_result_mem[int2fp_result_wr_ptr]
                    <= int2fp_result_data_in;
                int2fp_result_wr_ptr <= int2fp_result_wr_ptr + 1'b1;
            end
            if (int2fp_result_pop)
                int2fp_result_rd_ptr <= int2fp_result_rd_ptr + 1'b1;
            case ({int2fp_result_push, int2fp_result_pop})
                2'b10: int2fp_result_count <= int2fp_result_count + 1'b1;
                2'b01: int2fp_result_count <= int2fp_result_count - 1'b1;
                default: begin end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Output Scalers (with QROW bypass)
    // -------------------------------------------------------------------------
    // QCOL: output needs scaling (use VX_fp16_mul)
    // QROW: output already scaled at input, bypass the scaler
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_out_scaler
`ifndef SYNTHESIS
            localparam int LANE_ID = i;
`endif
            logic a_valid, b_valid;
            logic a_ready, b_ready;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            logic [FP16_WIDTH-1:0] a_data, b_data;
`else
            logic [FP32_WIDTH-1:0] a_data, b_data;
            logic [FP16_EXP_WIDTH-1:0] exp;
`endif

            assign a_valid = int2fp_result_pop
                           & (int2fp_result_data_out.ctrl.quant_dir
                              == `QDIR_COL);
            assign b_valid = a_valid;
            assign a_data  = a_valid ? int2fp_result_data_out.data[i] : '0;
            assign out_scaler_a_ready[i] = a_ready;
            assign out_scaler_b_ready[i] = b_ready;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            assign b_data  = a_valid
                ? scale_regs[qcol_scale_consumer_ctrl.sreg_use_idx][i]
                : '0;
`else
            assign b_data[31]  = a_valid
                ? scale_regs[qcol_scale_consumer_ctrl.sreg_use_idx][i][15]
                : '0;
            assign exp = scale_regs[
                qcol_scale_consumer_ctrl.sreg_use_idx][i][14:10];
            assign b_data[30:23]
                = a_valid
                ? (&exp == 1'b1
                 ? '1
                 : FP32_EXP_WIDTH'(exp) + FP32_EXP_WIDTH'(FP32_EXP_BIAS - FP16_EXP_BIAS))
                : '0;
            assign b_data[22:0]  = a_valid
                ? {scale_regs[
                    qcol_scale_consumer_ctrl.sreg_use_idx][i][9:0],
                    13'b0}
                : '0;
`endif

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            VX_fp16_mul #(
                .LATENCY        (FP16_MUL_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_out_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (a_ready),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (b_ready),
                .b_data       (b_data),
                .result_valid (scaler_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (scaled_fp_out_data[i])
            );
`ifndef SYNTHESIS
            always @(posedge clk) begin
                if ((reset === 1'b0)
                 && (a_valid === 1'b1)
                 && (a_ready !== 1'b1)) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if ((reset === 1'b0)
                 && (b_valid === 1'b1)
                 && (b_ready !== 1'b1)) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while b_valid is asserted",
                           $time, LANE_ID);
                end
            end
`endif
        end
`else
            VX_fp32_mul #(
                .LATENCY        (FP32_MUL_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_out_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (a_ready),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (b_ready),
                .b_data       (b_data),
                .result_valid (scaler_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (scaled_fp_out_data[i])
            );
`ifndef SYNTHESIS
            always @(posedge clk) begin
                if ((reset === 1'b0)
                 && (a_valid === 1'b1)
                 && (a_ready !== 1'b1)) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if ((reset === 1'b0)
                 && (b_valid === 1'b1)
                 && (b_ready !== 1'b1)) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while b_valid is asserted",
                           $time, LANE_ID);
                end
            end
`endif
        end
`endif
    endgenerate

    // Bypass pipe buffer for QROW mode (1 cycle delay to match scaler latency)
    VX_pipe_buffer #(
`ifdef GEMM_UNIT_FP16_OUT_SCALE
        .DATAW (`MXU_COL * FP16_WIDTH),
`else
        .DATAW (`MXU_COL * FP32_WIDTH),
`endif
        .DEPTH (1)
    ) u_scaler_bypass_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (int2fp_result_pop
                 && (int2fp_result_data_out.ctrl.quant_dir == `QDIR_ROW)),
        .ready_in  (),
        .data_in   (int2fp_result_data_out.data),
        .data_out  (scaler_bypass_data),
        .ready_out (1'b1),
        .valid_out (scaler_bypass_valid)
    );

    // Mux between scaled output (QCOL) and bypassed output (QROW)
    assign final_scaled_fp_out_data  = scaler_stage_is_qcol ? scaled_fp_out_data : scaler_bypass_data;
    assign final_scaler_output_valid = scaler_stage_is_qcol ? scaler_output_valid[0] : scaler_bypass_valid;
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_f16_to_f32
`ifdef GEMM_UNIT_FP16_OUT_SCALE
            logic [FP16_EXP_WIDTH-1:0] exp;
            logic inf;
            assign exp = final_scaled_fp_out_data[i][14:10];
            assign inf = &exp;
            assign scaled_fp32_out_data[i][31] = final_scaled_fp_out_data[i][15];
            assign scaled_fp32_out_data[i][30:23] = inf ? '1 : exp + (FP32_EXP_BIAS - FP16_EXP_BIAS);
            assign scaled_fp32_out_data[i][22:0] = {final_scaled_fp_out_data[i][9:0], 13'b0};
`else
            assign scaled_fp32_out_data[i] = final_scaled_fp_out_data[i];
`endif
        end
    endgenerate

    // QCOL Scale is now consumed after conversion.  Post control starts at
    // result-FIFO pop, so two bounded common registers are required after the
    // scaler/QROW-bypass mux to reach the proven Phase-1 ACC launch index.
    VX_pipe_buffer #(
        .DATAW (`MXU_COL * FP32_WIDTH),
        .DEPTH (POST_SCALER_ALIGN_DLY)
    ) u_scaled_fp32_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (final_scaler_output_valid),
        .ready_in  (),
        .data_in   (scaled_fp32_out_data),
        .data_out  (scaled_fp32_aligned_data),
        .ready_out (1'b1),
        .valid_out (scaled_fp32_aligned_valid)
    );


    // -------------------------------------------------------------------------
    // Load/accumulate latency alignment
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW (`MXU_COL * FP32_WIDTH),
        .DEPTH (ACC_ADD_DLY)
    ) u_load_result_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (scaled_fp32_aligned_valid
                 && ctrl_pipe[SCALER_CTRL_IDX].valid
                 && ctrl_pipe[SCALER_CTRL_IDX].is_load),
        .ready_in  (),
        .data_in   (scaled_fp32_aligned_data),
        .data_out  (load_result_data),
        .ready_out (1'b1),
        .valid_out (load_result_valid)
    );

    assign accum_bank
        = get_acc_mem_idx(ctrl_pipe[SCALER_CTRL_IDX].acc_rd_addr);
    always_comb begin
        selected_psum_data = acc_mem_out_data[accum_bank];
        if (forward_pipe[SCALER_CTRL_IDX]) begin
            selected_psum_data = writeback_result_data;
        end else if (history_forward_pipe[SCALER_CTRL_IDX]) begin
            selected_psum_data = writeback_history_data;
        end else if (early_pipe[SCALER_CTRL_IDX]) begin
            selected_psum_data = early_hold_data[accum_bank];
        end
    end

    generate
        for (genvar i = 0; i < `MXU_COL; ++i) begin : gen_accumulator
            logic a_ready;
            logic b_ready;

            assign acc_in_data_valid[i]
                = scaled_fp32_aligned_valid
               && ctrl_pipe[SCALER_CTRL_IDX].valid
               && ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en;
            assign acc_psum_data_valid[i] = acc_in_data_valid[i];

            VX_fp32_add #(
                .LATENCY         (FP32_ADD_LATENCY),
                .OUT_BUF         (0),
                .USE_LATENCY1_IP (1)
            ) u_accumulator (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (acc_in_data_valid[i]),
                .a_ready      (a_ready),
                .a_data       (scaled_fp32_aligned_data[i]),
                .b_valid      (acc_psum_data_valid[i]),
                .b_ready      (b_ready),
                .b_data       (selected_psum_data[i]),
                .result_valid (acc_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (acc_output_data[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // One-cycle-early per-bank ACC read scheduler
    // -------------------------------------------------------------------------
    always_comb begin
        early_read_req = '0;
        nominal_read_req = '0;
        read_req_addr = '0;

        if (ctrl_pipe[EARLY_READ_DLY-1].valid
         && ctrl_pipe[EARLY_READ_DLY-1].acc_rd_en
         && !forward_pipe[EARLY_READ_DLY-1]
         && !history_forward_pipe[EARLY_READ_DLY-1]
         && early_pipe[EARLY_READ_DLY-1]) begin
            early_read_req[
                get_acc_mem_idx(ctrl_pipe[EARLY_READ_DLY-1].acc_rd_addr)
            ] = 1'b1;
            read_req_addr[
                get_acc_mem_idx(ctrl_pipe[EARLY_READ_DLY-1].acc_rd_addr)
            ] = ctrl_pipe[EARLY_READ_DLY-1].acc_rd_addr;
        end

        if (ctrl_pipe[NOMINAL_READ_DLY-1].valid
         && ctrl_pipe[NOMINAL_READ_DLY-1].acc_rd_en
         && !forward_pipe[NOMINAL_READ_DLY-1]
         && !history_forward_pipe[NOMINAL_READ_DLY-1]
         && !early_pipe[NOMINAL_READ_DLY-1]) begin
            nominal_read_req[
                get_acc_mem_idx(ctrl_pipe[NOMINAL_READ_DLY-1].acc_rd_addr)
            ] = 1'b1;
            read_req_addr[
                get_acc_mem_idx(ctrl_pipe[NOMINAL_READ_DLY-1].acc_rd_addr)
            ] = ctrl_pipe[NOMINAL_READ_DLY-1].acc_rd_addr;
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            early_rsp_pending <= '0;
            early_hold_valid <= '0;
            early_hold_data <= '0;
        end else begin
            early_rsp_pending <= early_read_req;
            early_hold_valid <= early_rsp_pending;
            for (int i = 0; i < 4; ++i) begin
                if (early_rsp_pending[i]) begin
                    early_hold_data[i] <= acc_mem_out_data[i];
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // ACC writeback and single-port bank integration
    // -------------------------------------------------------------------------
    assign write_bank
        = get_acc_mem_idx(ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr);
    assign acc_write_fire
        = ctrl_pipe[WRITE_CTRL_IDX].valid
       && ctrl_pipe[WRITE_CTRL_IDX].acc_wr_en
       && (ctrl_pipe[WRITE_CTRL_IDX].is_load
         ? load_result_valid : acc_output_valid[0]);
    assign writeback_result_data
        = ctrl_pipe[WRITE_CTRL_IDX].is_load
        ? load_result_data : acc_output_data;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            writeback_history_valid <= 1'b0;
            writeback_history_addr <= '0;
            writeback_history_data <= '0;
        end else if (acc_write_fire) begin
            writeback_history_valid <= 1'b1;
            writeback_history_addr
                <= ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr;
            writeback_history_data <= writeback_result_data;
        end
    end

    assign output_read_addr
        = `GEMM_ACC_MEM_ADDR_WIDTH'(
            o_lmem_bus_if.req_data.addr << `CLOG2(`GEMM_PSUM_DATA_SIZE));
    assign output_read_bank = get_acc_mem_idx(output_read_addr);
    assign output_group_conflict
        = o_lmem_bus_if.req_valid
       && compute_group_busy[output_read_bank[1]];
    assign o_lmem_bus_if.req_ready
        = !output_read_valid && !output_group_conflict;
    assign output_read_fire
        = o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready
       && !o_lmem_bus_if.req_data.rw;
    assign compute_bank_read_req = early_read_req | nominal_read_req;
    assign output_bank_read_req
        = output_read_fire ? (4'b0001 << output_read_bank) : '0;
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data.data = fp16_out_data;
    assign o_lmem_bus_if.rsp_data.tag = output_read_tag_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            output_read_valid <= 1'b0;
            output_read_bank_q <= '0;
            output_read_tag_q <= '0;
        end else begin
            if (output_read_fire) begin
                output_read_valid <= 1'b1;
                output_read_bank_q <= output_read_bank;
                output_read_tag_q <= o_lmem_bus_if.req_data.tag;
            end else if (fp16_out_valid[0] && o_lmem_bus_if.rsp_ready) begin
                output_read_valid <= 1'b0;
            end
        end
    end

    generate
        for (genvar i = 0; i < 4; ++i) begin : gen_acc_mem
            logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] selected_addr;

            assign acc_mem_wr_en[i] = acc_write_fire && (write_bank == i);
            assign acc_mem_rd_en[i] = early_read_req[i]
                                    || nominal_read_req[i]
                                    || (output_read_fire
                                     && (output_read_bank == i));
            assign selected_addr = acc_mem_wr_en[i]
                                 ? ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr
                                 : (output_read_fire && (output_read_bank == i))
                                 ? output_read_addr : read_req_addr[i];
            assign acc_mem_addr[i] = get_acc_mem_bank_depth_addr(
                get_acc_mem_bank_addr(selected_addr));
            assign acc_mem_in_data[i]
                = writeback_result_data;

            VX_sp_ram #(
                .DATAW    (`MXU_COL * FP32_WIDTH),
                .SIZE     (`GEMM_ACC_MEM_DEPTH),
                .OUT_REG  (1),
                .USE_URAM (1),
                .RDW_MODE ("R")
            ) VX_sp_ram_instance (
                .clk   (clk),
                .reset (reset),
                .read  (acc_mem_rd_en[i]),
                .write (acc_mem_wr_en[i]),
                .wren  (1'b1),
                .addr  (acc_mem_addr[i]),
                .wdata (acc_mem_in_data[i]),
                .rdata (acc_mem_out_data[i])
            );
        end
    endgenerate

`ifdef SIMULATION
`ifndef SYNTHESIS
    task initialize_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr,
        input int size,
        input logic [`MXU_COL-1:0][FP32_WIDTH-1:0] init_value = '0
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] depth_addr;
        logic [1:0] bank_idx;
        for (int i = 0; i < size; ++i) begin
            bank_idx = get_acc_mem_idx(
                base_addr + `GEMM_ACC_MEM_ADDR_WIDTH'(i * `GEMM_PSUM_DATA_SIZE));
            bank_addr = get_acc_mem_bank_addr(
                base_addr + `GEMM_ACC_MEM_ADDR_WIDTH'(i * `GEMM_PSUM_DATA_SIZE));
            depth_addr = get_acc_mem_bank_depth_addr(bank_addr);
            case (bank_idx)
                2'd0: gen_acc_mem[0].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd1: gen_acc_mem[1].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd2: gen_acc_mem[2].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd3: gen_acc_mem[3].VX_sp_ram_instance.ram[depth_addr] = init_value;
                default: begin end
            endcase
        end
    endtask

    task read_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        output logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] depth_addr;
        logic [1:0] bank_idx;
        bank_idx = get_acc_mem_idx(addr);
        depth_addr = get_acc_mem_bank_depth_addr(get_acc_mem_bank_addr(addr));
        case (bank_idx)
            2'd0: data = gen_acc_mem[0].VX_sp_ram_instance.ram[depth_addr];
            2'd1: data = gen_acc_mem[1].VX_sp_ram_instance.ram[depth_addr];
            2'd2: data = gen_acc_mem[2].VX_sp_ram_instance.ram[depth_addr];
            2'd3: data = gen_acc_mem[3].VX_sp_ram_instance.ram[depth_addr];
            default: data = '0;
        endcase
    endtask
`endif
`endif

    generate
        for (genvar i = 0; i < `MXU_COL; ++i) begin : gen_fp32_to_fp16
            VX_f32_to_f16 u_f32_to_f16 (
                .clk_i    (clk),
                .resetn_i (~reset),
                .data_i   (acc_mem_out_data[output_read_bank_q][i]),
                .valid_i  (output_read_valid),
                .data_o   (fp16_out_data[i]),
                .valid_o  (fp16_out_valid[i])
            );
        end
    endgenerate

`ifndef SYNTHESIS
    logic stream_address_valid;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] stream_rd_addr_q;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] stream_wr_addr_q;
    logic admission_fire_probe_q;
    gemm_input_ctrl_t admission_ctrl_probe_q;
    logic input_stall_probe_q;
    logic [$bits(i_lmem_bus_if.req_data)-1:0] input_req_stall_data_q;
    gemm_input_ctrl_t input_ctrl_stall_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            stream_address_valid <= 1'b0;
            stream_rd_addr_q <= '0;
            stream_wr_addr_q <= '0;
            admission_fire_probe_q <= 1'b0;
            admission_ctrl_probe_q <= '0;
            input_stall_probe_q <= 1'b0;
            input_req_stall_data_q <= '0;
            input_ctrl_stall_q <= '0;
        end else begin
            admission_fire_probe_q <= input_fire;
            admission_ctrl_probe_q <= admitted_ctrl;
            input_stall_probe_q
                <= i_lmem_bus_if.req_valid && !i_lmem_bus_if.req_ready;
            if (i_lmem_bus_if.req_valid && !i_lmem_bus_if.req_ready) begin
                input_req_stall_data_q <= i_lmem_bus_if.req_data;
                input_ctrl_stall_q <= gemm_unit_v2_if.packet_ctrl;
            end
            if (input_fire) begin
                stream_address_valid <= !gemm_unit_v2_if.packet_ctrl.last;
                stream_rd_addr_q <= gemm_unit_v2_if.packet_ctrl.acc_rd_addr;
                stream_wr_addr_q <= gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
            end
        end
    end

    always @(posedge clk) begin
        if (reset === 1'b0) begin
            assert (gemm_unit_v2_if.packet_ctrl.valid
                 == i_lmem_bus_if.req_valid)
                else $fatal(1, "GEMM v2 packet/request valid mismatch");
            if (input_stall_probe_q) begin
                assert (i_lmem_bus_if.req_valid
                     && gemm_unit_v2_if.packet_ctrl.valid)
                    else $fatal(1, "GEMM v2 input valid dropped before acceptance");
                assert (i_lmem_bus_if.req_data == input_req_stall_data_q)
                    else $fatal(1, "GEMM v2 input request changed while stalled");
                assert (gemm_unit_v2_if.packet_ctrl == input_ctrl_stall_q)
                    else $fatal(1, "GEMM v2 input control changed while stalled");
            end
            if (i_lmem_bus_if.req_valid && !i_lmem_bus_if.req_ready) begin
                assert (!input_fire)
                    else $fatal(1, "GEMM v2 stalled input advanced admission state");
            end
            assert (ctrl_pipe[INPUT_CTRL_IDX].valid
                 == admission_fire_probe_q)
                else $fatal(1, "GEMM v2 admission ownership probe mismatch");
            if (admission_fire_probe_q) begin
                assert (ctrl_pipe[INPUT_CTRL_IDX]
                     == admission_ctrl_probe_q)
                    else $fatal(1, "GEMM v2 admission control changed before ctrl_pipe[0]");
            end
            assert (pipeline_pending_count
                 <= PIPELINE_PENDING_COUNTW'(PIPELINE_OWNERSHIP_BOUND))
                else $fatal(1, "GEMM v2 pipeline ownership counter overflow");
            if (pipeline_retire) begin
                assert ((pipeline_pending_count != 0) || input_fire)
                    else $fatal(1, "GEMM v2 retired an unowned transaction");
            end
            if (pipeline_pending_count != 0) begin
                assert (!gemm_unit_v2_if.pipeline_empty)
                    else $fatal(1, "GEMM v2 pipeline became empty with accepted ownership");
            end
            if (gemm_unit_v2_if.pipeline_empty) begin
                assert ((pipeline_pending_count == 0)
                     && !pre_region_busy
                     && !tree_region_busy
                     && !post_region_busy
                     && !acc_pending_busy
                     && !resource_ownership_busy
                     && !(|compute_group_busy)
                     && !(|wreg_busy))
                    else $fatal(1, "GEMM v2 pipeline_empty omitted bounded ownership");
            end
            if (ctrl_pipe[INPUT_CTRL_IDX].valid) begin
                if (ctrl_pipe[INPUT_CTRL_IDX].acc_rd_en) begin
                    assert (compute_group_busy[get_acc_group(
                        ctrl_pipe[INPUT_CTRL_IDX].acc_rd_addr)])
                        else $fatal(1, "GEMM v2 accepted ACC read group is not fenced");
                end
                if (ctrl_pipe[INPUT_CTRL_IDX].acc_wr_en) begin
                    assert (compute_group_busy[get_acc_group(
                        ctrl_pipe[INPUT_CTRL_IDX].acc_wr_addr)])
                        else $fatal(1, "GEMM v2 accepted ACC write group is not fenced");
                end
            end
            for (int i = 0; i < 2; ++i) begin
                assert (zreg_pending_count[i]
                     <= 8'(pipeline_pending_count))
                    else $fatal(1, "GEMM v2 Zero-point ownership exceeds pipeline ownership");
            end
            for (int i = 0; i < 2; ++i) begin
                assert (compute_group_pending_count[i]
                     <= 8'(pipeline_pending_count))
                    else $fatal(1, "GEMM v2 ACC-group ownership exceeds pipeline ownership");
            end
            assert ((early_read_req & nominal_read_req) == '0)
                else $fatal(1, "GEMM v2 same-bank read/read collision");
            assert ((acc_mem_wr_en & acc_mem_rd_en) == '0)
                else $fatal(1, "GEMM v2 same-bank read/write collision");
            assert ((compute_bank_read_req & output_bank_read_req) == '0)
                else $fatal(1, "GEMM v2 compute/output selected the same ACC read bank");
            assert ((acc_mem_wr_en & output_bank_read_req) == '0)
                else $fatal(1, "GEMM v2 compute write/output read selected the same ACC bank");
            assert ((early_rsp_pending & early_hold_valid) == '0)
                else $fatal(1, "GEMM v2 early hold overwrite");
            assert (prealigner_out_valid == pre_meta_valid_out)
                else $fatal(1, "GEMM v2 prealign data/metadata valid mismatch");
            assert (!(qcol_branch_valid_out && qrow_scaler_output_valid))
                else $fatal(1, "GEMM v2 QCOL/QROW pre-process reorder");
            assert (qrow_meta_valid_out == (&in_scaler_result_valid))
                else $fatal(1, "GEMM v2 QROW scaler data/metadata valid mismatch");
            assert ((&mxu_output_valid_dly) == tree_valid_pipe[MXU_OUT_DLY-1])
                else $fatal(1, "GEMM v2 tree data/metadata valid mismatch");
            assert (pre_proc_out_valid == tree_valid_pipe[MXU_OUT_DLY-1])
                else $fatal(1, "GEMM v2 correction/tree valid mismatch");
            assert (prealigner_max_exp_q_valid == merger_out_valid)
                else $fatal(1, "GEMM v2 FIFO data/max-exp launch mismatch");
            assert ((|int2fp_output_valid) == (&int2fp_output_valid))
                else $fatal(1, "GEMM v2 INT2FP lane-valid mismatch");
            assert ((&int2fp_output_valid)
                 == int2fp_meta_valid_pipe[
                      INT2FP_CONVERTER_META_DLY-1])
                else $fatal(1, "GEMM v2 INT2FP metadata/data latency mismatch");
            assert (final_scaler_output_valid
                 == ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].valid)
                else $fatal(1, "GEMM v2 scaler control/data latency mismatch");
            assert (scaled_fp32_aligned_valid
                 == ctrl_pipe[SCALER_CTRL_IDX].valid)
                else $fatal(1, "GEMM v2 post-scaler alignment mismatch");
            assert (load_result_valid
                 == (ctrl_pipe[WRITE_CTRL_IDX].valid
                  && ctrl_pipe[WRITE_CTRL_IDX].is_load))
                else $fatal(1, "GEMM v2 load-result control/data latency mismatch");
            if (ctrl_pipe[WRITE_CTRL_IDX].valid
             && ctrl_pipe[WRITE_CTRL_IDX].acc_rd_en) begin
                assert (&acc_output_valid)
                    else $fatal(1, "GEMM v2 accumulator control/data latency mismatch");
            end
            assert (tree_credit_q
                 <= MERGED_FIFO_COUNTW'(MERGED_RESULT_FIFO_DEPTH))
                else $fatal(1, "GEMM v2 tree credit overflow");
            assert (merged_fifo_count
                 <= MERGED_FIFO_COUNTW'(MERGED_RESULT_FIFO_DEPTH))
                else $fatal(1, "GEMM v2 merged FIFO count overflow");
            assert (int2fp_result_count
                 <= INT2FP_RESULT_FIFO_COUNTW'(INT2FP_RESULT_FIFO_DEPTH))
                else $fatal(1, "GEMM v2 INT2FP result FIFO count overflow");
            assert (int2fp_result_credit
                 <= INT2FP_RESULT_FIFO_COUNTW'(INT2FP_RESULT_FIFO_DEPTH))
                else $fatal(1, "GEMM v2 INT2FP result credit overflow");
            assert (($countones(tree_valid_pipe)
                   + 32'(merged_fifo_count))
                 <= MERGED_RESULT_FIFO_DEPTH)
                else $fatal(1, "GEMM v2 reserved tree/FIFO capacity overflow");
            if (merged_fifo_push) begin
                assert (!merged_fifo_full || merged_fifo_pop)
                    else $fatal(1, "GEMM v2 merged FIFO overflow");
            end
            if (int2fp_result_push) begin
                assert (!int2fp_result_full || int2fp_result_pop)
                    else $fatal(1, "GEMM v2 INT2FP result FIFO overflow");
            end
            if (merged_fifo_pop) begin
                assert ((int2fp_result_credit != 0) || int2fp_result_pop)
                    else $fatal(1, "GEMM v2 INT2FP launched without reserved result space");
            end
            if (compute_fire) begin
                assert ((tree_credit_q != 0) || credit_return_q)
                    else $fatal(1, "GEMM v2 compute launched without credit");
                assert (pre_meta_out.ctrl.w_load_target != 0
                     && gemm_unit_v2_if.w_load_value[
                          pre_meta_out.ctrl.wreg_use_idx]
                        == pre_meta_out.ctrl.w_load_target)
                    else $fatal(1, "GEMM v2 Weight consumer used the wrong generation");
                assert (pre_meta_out.ctrl.z_load_target != 0
                     && gemm_unit_v2_if.z_load_value[
                          pre_meta_out.ctrl.zreg_use_idx]
                        == pre_meta_out.ctrl.z_load_target)
                    else $fatal(1, "GEMM v2 Zero-point fork used the wrong generation");
            end
            if (qrow_scale_consumer_fire) begin
                assert (qrow_scale_consumer_ctrl.quant_dir == `QDIR_ROW
                     && qrow_scale_consumer_ctrl.s_load_target != 0
                     && gemm_unit_v2_if.s_load_value[
                          qrow_scale_consumer_ctrl.sreg_use_idx]
                        == qrow_scale_consumer_ctrl.s_load_target)
                    else $fatal(1, "GEMM v2 QROW Scale consumer used the wrong generation");
            end
            if (qcol_zp_consumer_fire) begin
                assert (qcol_zp_consumer_ctrl.quant_dir == `QDIR_COL
                     && qcol_zp_consumer_ctrl.valid
                     && qcol_zp_consumer_ctrl.z_load_target != 0
                     && gemm_unit_v2_if.z_load_value[
                          qcol_zp_consumer_ctrl.zreg_use_idx]
                        == qcol_zp_consumer_ctrl.z_load_target)
                    else $fatal(1, "GEMM v2 QCOL Zero-point direct read lost its generation");
                assert (zreg_pending_count[
                          qcol_zp_consumer_ctrl.zreg_use_idx] != 0)
                    else $fatal(1, "GEMM v2 QCOL Zero-point direct read had no owned lifetime");
            end
            if (qcol_scale_consumer_fire) begin
                assert (qcol_scale_consumer_ctrl.quant_dir == `QDIR_COL
                     && qcol_scale_consumer_ctrl.valid
                     && qcol_scale_consumer_ctrl.s_load_target != 0
                     && gemm_unit_v2_if.s_load_value[
                          qcol_scale_consumer_ctrl.sreg_use_idx]
                        == qcol_scale_consumer_ctrl.s_load_target)
                    else $fatal(1, "GEMM v2 QCOL Scale consumer used the wrong generation");
            end
            assert (gemm_unit_v2_if.scale_consume_valid
                 == (qrow_scale_consume_last || qcol_scale_consume_last))
                else $fatal(1, "GEMM v2 scale consume pulse misaligned");
            assert (gemm_unit_v2_if.zp_consume_valid
                 == (qrow_zp_consume_last || qcol_zp_consume_last))
                else $fatal(1, "GEMM v2 zero-point consume pulse misaligned");
            assert (!(qrow_scale_consume_last && qcol_scale_consume_last))
                else $fatal(1, "GEMM v2 collided two Scale consume events");
            assert (!(qrow_zp_consume_last && qcol_zp_consume_last))
                else $fatal(1, "GEMM v2 collided two Zero-point consume events");
            if (qrow_scale_consume_last) begin
                assert (gemm_unit_v2_if.scale_consume_idx
                     == qrow_scale_consumer_ctrl.sreg_use_idx)
                    else $fatal(1, "GEMM v2 QROW Scale last consume selected unrelated metadata");
            end
            if (qcol_scale_consume_last) begin
                assert (gemm_unit_v2_if.scale_consume_idx
                     == qcol_scale_consumer_ctrl.sreg_use_idx)
                    else $fatal(1, "GEMM v2 QCOL Scale last consume selected unrelated metadata");
            end
            if (qrow_zp_consume_last) begin
                assert (gemm_unit_v2_if.zp_consume_idx
                     == qrow_zp_consumer_ctrl.zreg_use_idx)
                    else $fatal(1, "GEMM v2 QROW Zero-point last consume selected unrelated metadata");
            end
            if (qcol_zp_consume_last) begin
                assert (gemm_unit_v2_if.zp_consume_idx
                     == qcol_zp_consumer_ctrl.zreg_use_idx)
                    else $fatal(1, "GEMM v2 QCOL Zero-point last consume selected unrelated metadata");
            end
            assert (gemm_unit_v2_if.weight_consume_valid
                 == (compute_fire && pre_meta_out.ctrl.last))
                else $fatal(1, "GEMM v2 weight consume pulse misaligned");
            if (mxu_ready_weight) begin
                assert (!wreg_busy[wreg_wr_idx]
                    || same_cycle_weight_release)
                    else $fatal(1, "GEMM v2 accepted a busy weight-register write");
                if (wreg_busy[wreg_wr_idx]) begin
                    assert (gemm_unit_v2_if.weight_consume_valid
                         && (gemm_unit_v2_if.weight_consume_idx == wreg_wr_idx)
                         && !wreg_preconsume_busy[wreg_wr_idx])
                      else $fatal(1,
                          "GEMM v2 invalid same-cycle Weight overwrite");
                end
            end
            if (scale_reg_wr_en) begin
                assert (!sreg_busy[scale_reg_idx]
                    || same_cycle_scale_release)
                    else $fatal(1, "GEMM v2 accepted a busy scale-register write");
            end
            if (zp_reg_wr_en) begin
                assert (!zreg_busy[zp_reg_idx]
                    || same_cycle_zp_release)
                    else $fatal(1, "GEMM v2 accepted a busy zero-register write");
            end
            if (w_lmem_bus_if.req_valid) begin
                assert (w_lmem_bus_if.req_ready)
                    else $fatal(1, "GEMM v2 future Weight waiter blocked a register write");
            end
            if (scale_reg_wr_req) begin
                assert (sc_lmem_bus_if.req_ready)
                    else $fatal(1, "GEMM v2 future Scale waiter blocked a register write");
            end
            if (zp_reg_wr_req && (zreg_pending_count[zp_reg_idx] == 0)) begin
                assert (zp_lmem_bus_if.req_ready)
                    else $fatal(1, "GEMM v2 future Zero-point waiter blocked a register write");
            end
            if (output_read_fire === 1'b1) begin
                assert (!compute_group_busy[output_read_bank[1]])
                    else $fatal(1, "GEMM v2 same-group output read fired during compute");
            end
            if ((o_lmem_bus_if.req_valid === 1'b1)
             && (o_lmem_bus_if.req_data.rw === 1'b0)
             && (output_read_valid === 1'b0)
             && ((|compute_group_busy) === 1'b1)
             && (compute_group_busy[output_read_bank[1]] === 1'b0)) begin
                assert (o_lmem_bus_if.req_ready && output_read_fire)
                    else $fatal(1, "GEMM v2 different-group output read was over-constrained");
            end
            if ((input_fire === 1'b1)
             && (stream_address_valid === 1'b1)) begin
                assert ((gemm_unit_v2_if.packet_ctrl.acc_rd_addr
                       == stream_rd_addr_q + `GEMM_PSUM_DATA_SIZE
                      && gemm_unit_v2_if.packet_ctrl.acc_wr_addr
                       == stream_wr_addr_q + `GEMM_PSUM_DATA_SIZE)
                     || (gemm_unit_v2_if.packet_ctrl.acc_rd_en
                      && gemm_unit_v2_if.packet_ctrl.acc_rd_addr
                       == stream_wr_addr_q
                      && gemm_unit_v2_if.packet_ctrl.acc_wr_addr
                       == stream_wr_addr_q))
                    else $fatal(1, "GEMM v2 address is neither strict progression nor a same-address accumulation");
            end
            if (post_launch_forward === 1'b1) begin
                assert (ctrl_pipe[MERGER_CTRL_IDX].valid
                     && ctrl_pipe[MERGER_CTRL_IDX].acc_wr_en)
                    else $fatal(1, "GEMM v2 post-launch forwarding has no prior writer");
                assert (ctrl_pipe[MERGER_CTRL_IDX].acc_wr_addr
                     == int2fp_result_data_out.ctrl.acc_rd_addr)
                    else $fatal(1, "GEMM v2 post-launch forwarding address mismatch");
            end
            if (post_launch_history_forward === 1'b1) begin
                assert (!post_launch_forward)
                    else $fatal(1, "GEMM v2 immediate/history forwarding overlap");
                assert (ctrl_pipe[MERGER_CTRL_IDX+1].valid
                     && ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_en)
                    else $fatal(1, "GEMM v2 history forwarding dependency has no d=2 writer");
                assert (ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_addr
                     == int2fp_result_data_out.ctrl.acc_rd_addr)
                    else $fatal(1, "GEMM v2 history forwarding launch address mismatch");
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             && (ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en === 1'b1)
             && (early_pipe[SCALER_CTRL_IDX] === 1'b1)) begin
                assert (early_hold_valid[accum_bank])
                    else $fatal(1, "GEMM v2 missing early PSUM");
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             && (forward_pipe[SCALER_CTRL_IDX] === 1'b1)) begin
                assert (ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en)
                    else $fatal(1, "GEMM v2 forwarding packet is not accumulating");
                assert (acc_write_fire)
                    else $fatal(1, "GEMM v2 forwarding source writeback is invalid");
                assert (ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr
                     == ctrl_pipe[SCALER_CTRL_IDX].acc_rd_addr)
                    else $fatal(1, "GEMM v2 forwarding consume address mismatch");
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             && (history_forward_pipe[SCALER_CTRL_IDX] === 1'b1)) begin
                assert (ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en)
                    else $fatal(1, "GEMM v2 history forwarding packet is not accumulating");
                assert (!forward_pipe[SCALER_CTRL_IDX])
                    else $fatal(1, "GEMM v2 immediate/history forwarding consume overlap");
                assert (writeback_history_valid)
                    else $fatal(1, "GEMM v2 history forwarding source is invalid");
                assert (writeback_history_addr
                     == ctrl_pipe[SCALER_CTRL_IDX].acc_rd_addr)
                    else $fatal(1, "GEMM v2 history forwarding consume address mismatch");
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             && (ctrl_pipe[SCALER_CTRL_IDX].is_load === 1'b1)) begin
                assert (scaled_fp32_aligned_valid === 1'b1)
                    else $fatal(1, "GEMM v2 load control/data latency mismatch");
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             && (ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en === 1'b1)) begin
                assert (scaled_fp32_aligned_valid)
                    else $fatal(1, "GEMM v2 control/data latency mismatch");
            end
        end
    end
`endif

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (reset === 1'b0) begin
            if ((input_fire === 1'b1)
             || (pipeline_retire === 1'b1)) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_OWNERSHIP | {inst=%s, accept=%0d, retire=%0d, pending=%0d, pre=%0d, tree=%0d, post=%0d, acc=%0d, resource=%0d, empty=%0d}\n",
                    $time, INSTANCE_ID,
                    input_fire,
                    pipeline_retire,
                    pipeline_pending_count,
                    pre_region_busy,
                    tree_region_busy,
                    post_region_busy,
                    acc_pending_busy,
                    resource_ownership_busy,
                    gemm_unit_v2_if.pipeline_empty))
            end
            if (compute_fire === 1'b1) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_COMPUTE_FIRE | {inst=%s, credit=%0d, wreg=%0d, addr=0x%0h, last=%0d}\n",
                    $time, INSTANCE_ID,
                    tree_credit_q,
                    pre_meta_out.ctrl.wreg_use_idx,
                    pre_meta_out.ctrl.acc_wr_addr,
                    pre_meta_out.ctrl.last))
            end
            if ((merged_fifo_push === 1'b1)
             || (merged_fifo_pop === 1'b1)
             || (credit_return_q === 1'b1)) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_MERGED_FIFO | {inst=%s, push=%0d, pop=%0d, count=%0d, credit=%0d, credit_return=%0d, post_ready=%0d}\n",
                    $time, INSTANCE_ID,
                    merged_fifo_push,
                    merged_fifo_pop,
                    merged_fifo_count,
                    tree_credit_q,
                    credit_return_q,
                    postprocess_ready))
            end
            if ((ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].valid === 1'b1)
             || (final_scaler_output_valid === 1'b1)) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_SCALER_OUTPUT | {inst=%s, ctrl_valid=%0d, data_valid=%0d, load=%0d, rd=%0d, addr=0x%0h, last=%0d}\n",
                    $time, INSTANCE_ID,
                    ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].valid,
                    final_scaler_output_valid,
                    ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].is_load,
                    ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].acc_rd_en,
                    ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].acc_wr_addr,
                    ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].last))
            end
            if ((ctrl_pipe[SCALER_CTRL_IDX].valid === 1'b1)
             || (scaled_fp32_aligned_valid === 1'b1)) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_ACC_LAUNCH | {inst=%s, ctrl_valid=%0d, data_valid=%0d, load=%0d, rd=%0d, addr=0x%0h, last=%0d}\n",
                    $time, INSTANCE_ID,
                    ctrl_pipe[SCALER_CTRL_IDX].valid,
                    scaled_fp32_aligned_valid,
                    ctrl_pipe[SCALER_CTRL_IDX].is_load,
                    ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en,
                    ctrl_pipe[SCALER_CTRL_IDX].acc_wr_addr,
                    ctrl_pipe[SCALER_CTRL_IDX].last))
            end
            if ((load_result_valid === 1'b1)
             || ((ctrl_pipe[WRITE_CTRL_IDX].valid === 1'b1)
              && (ctrl_pipe[WRITE_CTRL_IDX].is_load === 1'b1))) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_LOAD_ALIGN | {inst=%s, ctrl_valid=%0d, data_valid=%0d, addr=0x%0h, last=%0d}\n",
                    $time, INSTANCE_ID,
                    ctrl_pipe[WRITE_CTRL_IDX].valid,
                    load_result_valid,
                    ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr,
                    ctrl_pipe[WRITE_CTRL_IDX].last))
            end
            if (acc_write_fire === 1'b1) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_WRITE_FIRE | {inst=%s, bank=%0d, addr=0x%0h, load=%0d, last=%0d}\n",
                    $time, INSTANCE_ID,
                    write_bank,
                    ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr,
                    ctrl_pipe[WRITE_CTRL_IDX].is_load,
                    ctrl_pipe[WRITE_CTRL_IDX].last))
            end
            if (gemm_unit_v2_if.scale_consume_valid) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_SCALE_CONSUME | {inst=%s, buf=%0d}\n",
                    $time, INSTANCE_ID,
                    gemm_unit_v2_if.scale_consume_idx))
            end
            if (gemm_unit_v2_if.zp_consume_valid) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_ZP_CONSUME | {inst=%s, buf=%0d}\n",
                    $time, INSTANCE_ID,
                    gemm_unit_v2_if.zp_consume_idx))
            end
            if (gemm_unit_v2_if.weight_consume_valid) begin
                `TRACE(1, ("%m : [%0t] | GEMM_V2_WEIGHT_CONSUME | {inst=%s, buf=%0d}\n",
                    $time, INSTANCE_ID,
                    gemm_unit_v2_if.weight_consume_idx))
            end
        end
    end
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
    (* keep = "true", mark_debug = "true" *)
    wire [31:0] dbg_gemm_unit_v2 = {
        8'(early_read_req),
        8'(nominal_read_req),
        8'(acc_mem_wr_en),
        5'(WRITE_DLY),
        gemm_unit_v2_if.last_write,
        gemm_unit_v2_if.pipeline_empty,
        input_fire
    };
`endif
`endif

`ifdef ENABLE_HW_DEBUG_GEMM
    always_comb begin
        debug = '0;
        debug.valid = 1'b1;
        debug.computing = !gemm_unit_v2_if.pipeline_empty;
        debug.idle = gemm_unit_v2_if.pipeline_empty;
        debug.done = gemm_unit_v2_if.last_write;
        debug.is_load = ctrl_pipe[WRITE_CTRL_IDX].is_load;
        debug.is_qcol = scaler_stage_is_qcol;
        debug.rd_req = |(early_read_req | nominal_read_req);
        debug.rd_accept = |(early_read_req | nominal_read_req);
        debug.wr_req = acc_write_fire;
        debug.wr_fire = acc_write_fire;
        debug.final_scaler_valid = final_scaler_output_valid;
        debug.acc_in_valid = acc_in_data_valid[0];
        debug.psum_valid = acc_psum_data_valid[0];
        debug.acc_output_valid = acc_output_valid[0];
        debug.rd_bank = accum_bank;
        debug.wr_bank = write_bank;
        debug.rd_addr = ctrl_pipe[SCALER_CTRL_IDX].acc_rd_addr;
        debug.wr_addr = ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr;
    end
`endif

`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_input_fire_r;
    reg [PERF_CTR_BITS-1:0] perf_weight_fire_r;
    reg [PERF_CTR_BITS-1:0] perf_output_fire_r;
    reg [PERF_CTR_BITS-1:0] perf_accum_rd_accept_r;
    reg [PERF_CTR_BITS-1:0] perf_accum_wr_fire_r;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            perf_input_fire_r <= '0;
            perf_weight_fire_r <= '0;
            perf_output_fire_r <= '0;
            perf_accum_rd_accept_r <= '0;
            perf_accum_wr_fire_r <= '0;
        end else begin
            if (input_fire)
                perf_input_fire_r <= perf_input_fire_r + PERF_CTR_BITS'(1);
            if (w_lmem_bus_if.req_valid && w_lmem_bus_if.req_ready)
                perf_weight_fire_r <= perf_weight_fire_r + PERF_CTR_BITS'(1);
            if (o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready)
                perf_output_fire_r <= perf_output_fire_r + PERF_CTR_BITS'(1);
            if (|(early_read_req | nominal_read_req))
                perf_accum_rd_accept_r <= perf_accum_rd_accept_r + PERF_CTR_BITS'(1);
            if (acc_write_fire)
                perf_accum_wr_fire_r <= perf_accum_wr_fire_r + PERF_CTR_BITS'(1);
        end
    end

    always_comb begin
        perf = '0;
        perf.job_count = perf_accum_wr_fire_r;
        perf.input_fire = perf_input_fire_r;
        perf.weight_fire = perf_weight_fire_r;
        perf.output_fire = perf_output_fire_r;
        perf.accum_rd_accept = perf_accum_rd_accept_r;
        perf.accum_wr_fire = perf_accum_wr_fire_r;
        perf.scaler_valid = perf_input_fire_r;
        perf.acc_output_valid = perf_accum_wr_fire_r;
        perf.computing = !gemm_unit_v2_if.pipeline_empty;
    end
`endif

    `UNUSED_VAR (prealigner_pipe_out_valid)
    `UNUSED_VAR (prealigner_max_exp_q_valid)

endmodule

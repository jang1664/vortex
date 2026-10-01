module VX_gemm_compute_core import VX_gpu_pkg::*; #(
    parameter  INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,
    VX_mem_bus_if.slave     input_bus_if,
    VX_mem_bus_if.slave     weight_bus_if,
    VX_mem_bus_if.slave     scale_bus_if,
    VX_mem_bus_if.slave     zero_bus_if,
    VX_gemm_unit_v2_if.slave gemm_unit_if,
    VX_gemm_acc_if.core      acc_if,
    input wire               postprocess_ready
);
    localparam FP32_WIDTH     = 32;
    localparam FP32_EXP_WIDTH = 8;
    localparam FP32_EXP_BIAS  = 127;
    localparam FP32_MAN_WIDTH = 23;
    localparam FP16_WIDTH     = 16;
    localparam FP16_EXP_WIDTH = 5;
    localparam FP16_EXP_BIAS  = 15;
    localparam FP16_MAN_WIDTH = 10;
    localparam SCALE_REG_SIZE  = (((16) > (16)) ? (16) : (16)) * 16 / 8;
    localparam ZP_REG_SIZE     = (((16) > (16)) ? (16) : (16)) * 16 / 8;
    localparam SCALE_REG0_BASE = 0;
    localparam SCALE_REG1_BASE = SCALE_REG_SIZE;
    localparam ZP_REG0_BASE    = SCALE_REG_SIZE * 2;
    localparam ZP_REG1_BASE    = SCALE_REG_SIZE * 2 + ZP_REG_SIZE;
    localparam DEFAULT_OUT_DLY = 1;
    localparam INPUT_SCALE_DLY = 1;
    localparam PREALIGN_DLY = 3;
    localparam ACT_REDUCE_OUT_DLY = get_pipe_stage_num(16, 2);
    localparam ACT_REDUCE_PIPE_STAGES = get_pipe_stage_bitmask(16, 2);
    localparam BLK_IDX_DLY = DEFAULT_OUT_DLY;
    localparam MXU_BASE_OUT_DLY = (1 + 1 + 1)
                           + get_pipe_stage_num(16, 2)
                           + ((16 / 16) - 1);
    localparam MXU_INPUT_TRANSPORT_DLY = 2;
    localparam MXU_OUTPUT_TRANSPORT_DLY = 2;
    localparam MXU_OUT_DLY = MXU_BASE_OUT_DLY
                          + MXU_INPUT_TRANSPORT_DLY
                          + MXU_OUTPUT_TRANSPORT_DLY;
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY
                                - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;
    localparam FPU_OPERATOR_LATENCY = 1;
    localparam FP16_MUL_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP32_MUL_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP32_ADD_LATENCY = FPU_OPERATOR_LATENCY;
    localparam FP_SCALER_DLY = 1;
    localparam ACC_READ_RESPONSE_DLY = 1;
    localparam ACC_ADD_DLY = 1;
    localparam ACC_POST_DLY = 0;
    localparam TREE_PIPELINE_CAPACITY = MXU_OUT_DLY;
    localparam READY_FEEDBACK_LATENCY = 1;
    localparam POST_LAUNCH_TO_INT2FP_CTRL_DLY
        = INTTOFP_OUT_DLY - DEFAULT_OUT_DLY;
    localparam INT2FP_CONVERTER_META_DLY = INTTOFP_OUT_DLY;
    localparam MERGED_RESULT_FIFO_DEPTH
        = TREE_PIPELINE_CAPACITY + READY_FEEDBACK_LATENCY;
    localparam MERGED_FIFO_PTRW
        = (((MERGED_RESULT_FIFO_DEPTH) > 1) ? $clog2(MERGED_RESULT_FIFO_DEPTH) : 1);
    localparam MERGED_FIFO_COUNTW
        = (((MERGED_RESULT_FIFO_DEPTH + 1) > 1) ? $clog2(MERGED_RESULT_FIFO_DEPTH + 1) : 1);
    localparam INT2FP_RESULT_FIFO_DEPTH = INTTOFP_OUT_DLY;
    localparam INT2FP_RESULT_FIFO_PTRW
        = (((INT2FP_RESULT_FIFO_DEPTH) > 1) ? $clog2(INT2FP_RESULT_FIFO_DEPTH) : 1);
    localparam INT2FP_RESULT_FIFO_COUNTW
        = (((INT2FP_RESULT_FIFO_DEPTH + 1) > 1) ? $clog2(INT2FP_RESULT_FIFO_DEPTH + 1) : 1);
    localparam POST_TXN_DEPTH = 4;
    localparam POST_TXN_PTRW = (((POST_TXN_DEPTH) > 1) ? $clog2(POST_TXN_DEPTH) : 1);
    localparam POST_TXN_COUNTW = (((POST_TXN_DEPTH + 1) > 1) ? $clog2(POST_TXN_DEPTH + 1) : 1);
    localparam ACC_RESULT_DEPTH = ACC_ADD_DLY + 1;
    localparam ACC_RESULT_PTRW = (((ACC_RESULT_DEPTH) > 1) ? $clog2(ACC_RESULT_DEPTH) : 1);
    localparam ACC_RESULT_COUNTW = (((ACC_RESULT_DEPTH + 1) > 1) ? $clog2(ACC_RESULT_DEPTH + 1) : 1);
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
    localparam SCALER_OUTPUT_CTRL_IDX = MERGER_CTRL_IDX;
    localparam POST_SCALER_ALIGN_DLY
        = SCALER_CTRL_IDX - SCALER_OUTPUT_CTRL_IDX;
    localparam PIPELINE_OWNERSHIP_BOUND
        = DEFAULT_OUT_DLY + INPUT_SCALE_DLY + PREALIGN_DLY
        + MERGED_RESULT_FIFO_DEPTH
        + (WRITE_CTRL_IDX - MERGER_CTRL_IDX + 1) + 4;
    localparam PIPELINE_PENDING_COUNTW
        = (((PIPELINE_OWNERSHIP_BOUND + 1) > 1) ? $clog2(PIPELINE_OWNERSHIP_BOUND + 1) : 1);
    localparam L_PRE = SCALER_CTRL_IDX + 1;
    localparam L_R = ACC_READ_RESPONSE_DLY;
    localparam L_A = ACC_ADD_DLY;
    localparam L_P = ACC_POST_DLY;
    localparam K_LOOKBACK = L_A + L_P + L_R;
    localparam NOMINAL_READ_DLY = L_PRE - L_R;
    localparam EARLY_READ_DLY = NOMINAL_READ_DLY - 1;
    localparam WRITE_DLY = L_PRE + L_A + L_P;
    localparam GEMM_UNIT_FP16_OUT_SCALE = 0;
    logic [1:0][(((16) > (16)) ? (16) : (16))-1:0][16-1:0] scale_regs;
    logic [1:0][(((16) > (16)) ? (16) : (16))-1:0][16-1:0]    zero_regs;
    typedef logic [(((16) > (16)) ? (16) : (16))-1:0][16-1:0]
        scale_vector_t;
    typedef logic [(((16) > (16)) ? (16) : (16))-1:0][16-1:0]
        zero_vector_t;
    typedef struct packed {
        logic [16 * 16-1:0] data;
        gemm_input_ctrl_t                  ctrl;
    } pre_input_payload_t;
    typedef struct packed {
        gemm_input_ctrl_t ctrl;
    } pre_meta_t;
    typedef struct packed {
        gemm_input_ctrl_t              ctrl;
        logic [5-1:0]    max_exp;
    } tree_meta_t;
    typedef struct packed {
        logic [16-1:0][(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)-1:0] data;
        logic [5-1:0]               max_exp;
        gemm_input_ctrl_t                        ctrl;
    } merged_result_t;
    typedef struct packed {
        logic [16-1:0][FP32_WIDTH-1:0] data;
        gemm_input_ctrl_t ctrl;
    } int2fp_result_t;
    typedef struct packed {
        gemm_input_ctrl_t ctrl;
        logic [16-1:0][FP32_WIDTH-1:0] data;
    } acc_result_t;
    logic                                            sc_req_hs;
    logic                                            sc_req_rw;
    logic [$clog2(((16*16)/8)*4)-1:0] sc_req_addr;
    logic [((16*16)/8)*8-1:0]         sc_req_data;
    logic                                            zp_req_hs;
    logic                                            zp_req_rw;
    logic [$clog2(((16*16)/8)*4)-1:0] zp_req_addr;
    logic [((16*16)/8)*8-1:0]         zp_req_data;
    logic                                            scale_reg_wr_en;
    logic                                            scale_reg_wr_req;
    logic                                            scale_reg_idx;
    logic                                            zp_reg_wr_en;
    logic                                            zp_reg_idx;
    logic                                            zp_reg_wr_req;
    logic [16 * 16-1:0]              in_pipe_data_out;
    logic                                          in_pipe_valid_out;
    logic                                          in_pipe_ready_in;
    pre_input_payload_t                            in_pipe_payload_in;
    pre_input_payload_t                            in_pipe_payload_out;
    gemm_input_ctrl_t                              admitted_ctrl;
    logic [31:0]                                   acc_txn_tag_q;
    logic                                          input_stage_ready;
    logic                                          input_stage_fire;
    logic [16-1:0]                           in_scaler_a_ready;
    logic [16-1:0]                           in_scaler_b_ready;
    logic [16-1:0][16-1:0]           in_scaler_result_data;
    logic [16-1:0]                           in_scaler_result_valid;
    logic [16-1:0]                           in_scaler_result_ready;
    logic                                          qrow_scaler_issue;
    logic                                          qrow_scale_ready;
    logic                                          qrow_scaler_input_ready;
    logic                                          qrow_scaler_output_valid;
    logic                                          qrow_meta_ready_in;
    logic                                          qrow_meta_valid_out;
    pre_meta_t                                     qrow_meta_out;
    logic [16-1:0][16-1:0]           prealigner_in_data;
    logic                                          prealigner_in_valid;
    logic [16-1:0][(((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1)-1:0]     prealigner_int_data;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]     prealigner_blk_idx;
    logic [5-1:0]                     prealigner_max_exp;
    logic                                          prealigner_out_valid;
    logic                                          prealigner_ready_out;
    logic                                          prealign_issue;
    logic                                          pre_meta_ready_in;
    logic                                          pre_meta_valid_out;
    pre_meta_t                                     pre_meta_in;
    pre_meta_t                                     pre_meta_out;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]     prealigner_blk_idx_q;
    logic                                          prealigner_pipe_out_valid;
    logic [5-1:0]                     prealigner_max_exp_q;
    logic                                          prealigner_max_exp_q_valid;
    logic                                          qcol_branch_ready_in;
    logic                                          qcol_branch_valid_out;
    pre_input_payload_t                            qcol_branch_payload_out;
    logic                                          pre_branch_valid;
    logic                                          pre_branch_ready;
    logic [16-1:0][16-1:0]           pre_branch_data;
    pre_meta_t                                     pre_branch_meta;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))-1:0]     pre_proc_out;
    logic                                          pre_proc_in_valid;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))-1:0]     pre_proc_out_q;
    logic                                          pre_proc_out_valid;
    logic [4-1:0][16-1:0][4-1:0]  mxu_weight;
    logic                                                       mxu_ready_weight;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0]                      mxu_output;
    logic [16/16-1:0]                          mxu_output_valid;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0]                      mxu_output_dly;
    logic [16/16-1:0]                          mxu_output_valid_dly;
    logic [16-1:0][(((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1)-1:0]                  mxu_input_capture;
    logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0]                  mxu_blk_capture;
    gemm_wreg_idx_t                                            mxu_weight_use_capture;
    logic                                                      mxu_input_valid_capture;
    logic [4-1:0][16-1:0][4-1:0]  mxu_weight_capture;
    gemm_wreg_idx_t                                            mxu_weight_write_capture;
    logic                                                      mxu_weight_dir_capture;
    logic                                                      mxu_weight_valid_capture;
    logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0]                      mxu_output_capture;
    logic [16/16-1:0]                          mxu_output_valid_capture;
    logic                                                      mxu_transport_busy;
    logic                                                       compute_fire;
    logic                                                       compute_ready;
    logic                                                       weight_ready;
    logic                                                       zero_ready;
    tree_meta_t                                                 compute_meta;
    tree_meta_t                                                 tree_meta_pipe [0:MXU_OUT_DLY-1];
    logic [MXU_OUT_DLY-1:0]                                     tree_valid_pipe;
    logic [MERGED_FIFO_COUNTW-1:0]                              tree_credit_q;
    logic                                                       credit_return_q;
    gemm_wreg_idx_t wreg_wr_idx;
    logic wreg_load_dir;
    logic [16-1:0][(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)-1:0]        merger_out_data;
    logic                                          merger_in_valid;
    logic [16-1:0][(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)-1:0]        merger_out_data_q;
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
    logic [16-1:0][FP32_WIDTH-1:0]           int2fp_out_data;
    logic [16-1:0]                           int2fp_output_valid;
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
    gemm_input_ctrl_t                              post_txn_ctrl [0:POST_TXN_DEPTH-1];
    logic [POST_TXN_DEPTH-1:0]                    post_txn_valid;
    logic [POST_TXN_DEPTH-1:0]                    post_txn_scaled_valid;
    logic [POST_TXN_DEPTH-1:0]                    post_txn_rsp_valid;
    logic [POST_TXN_DEPTH-1:0]                    post_txn_rd_issued;
    logic [POST_TXN_DEPTH-1:0]                    post_txn_forward;
    logic [POST_TXN_DEPTH-1:0][31:0]              post_txn_forward_tag;
    logic [POST_TXN_DEPTH-1:0][16-1:0][FP32_WIDTH-1:0]
                                                   post_txn_scaled_data;
    logic [POST_TXN_DEPTH-1:0][16-1:0][FP32_WIDTH-1:0]
                                                   post_txn_rsp_data;
    logic [POST_TXN_PTRW-1:0]                     post_txn_wr_ptr;
    logic [POST_TXN_PTRW-1:0]                     post_txn_rd_ptr;
    logic [POST_TXN_COUNTW-1:0]                   post_txn_count;
    logic                                          post_txn_launch;
    logic                                          post_txn_space;
    logic                                          post_head_scaled_ready;
    logic                                          post_head_psum_ready;
    gemm_input_ctrl_t                              post_head_ctrl;
    logic [16-1:0][FP32_WIDTH-1:0]           post_head_scaled_data;
    logic [16-1:0][FP32_WIDTH-1:0]           post_head_psum_data;
    logic                                          rd_hold_valid;
    logic [POST_TXN_PTRW-1:0]                     rd_hold_slot;
    logic [31:0]                                   rd_hold_tag;
    logic [34-1:0]                    rd_hold_addr;
    logic                                          rd_hold_dependency_valid;
    logic [34-1:0]                    rd_hold_dependency_addr;
    logic                                          rd_rsp_match_valid;
    logic [POST_TXN_PTRW-1:0]                     rd_rsp_match_slot;
    logic                                          scaled_match_valid;
    logic [POST_TXN_PTRW-1:0]                     scaled_match_slot;
    logic                                          post_new_backend_read;
    logic                                          qcol_scale_ready;
    logic                                          scaler_consumer_fire;
    logic                                          qrow_scale_consumer_fire;
    logic                                          qcol_scale_consumer_fire;
    logic                                          qrow_zp_consumer_fire;
    logic                                          qcol_zp_consumer_fire;
    logic                                          consumer_block_raw_valid;
    logic [1:0]                                    consumer_block_raw_resource;
    logic [31:0]                                   consumer_block_raw_work_seq;
    logic                                          consumer_block_raw_bank;
    logic [31:0]                                   consumer_block_raw_target;
    logic                                          qrow_scale_consume_last;
    logic                                          qcol_scale_consume_last;
    logic                                          qrow_zp_consume_last;
    logic                                          qcol_zp_consume_last;
    logic                                          scale_consume_channel_ready;
    logic                                          zp_consume_channel_ready;
    gemm_input_ctrl_t                              qrow_scale_consumer_ctrl;
    gemm_input_ctrl_t                              qcol_scale_consumer_ctrl;
    gemm_input_ctrl_t                              qrow_zp_consumer_ctrl;
    gemm_input_ctrl_t                              qcol_zp_consumer_ctrl;
    gemm_qreg_idx_t                                scale_last_consume_idx;
    gemm_qreg_idx_t                                zp_last_consume_idx;
    logic [16-1:0]                           out_scaler_a_ready;
    logic [16-1:0]                           out_scaler_b_ready;
    logic                                          out_scaler_input_ready;
    logic [16-1:0][FP32_WIDTH-1:0]           scaled_fp_out_data;
    logic [16-1:0]                           scaler_output_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           scaler_bypass_data;
    logic                                          scaler_bypass_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           final_scaled_fp_out_data;
    logic                                          final_scaler_output_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           scaled_fp32_out_data;
    logic [16-1:0][FP32_WIDTH-1:0]           scaled_fp32_aligned_data;
    logic                                          scaled_fp32_aligned_valid;
    logic [16-1:0][FP32_WIDTH-1:0]           acc_output_data;
    logic [16-1:0]                           acc_output_valid;
    logic [16-1:0]                           acc_in_data_valid;
    logic [16-1:0]                           acc_psum_data_valid;
    logic [16-1:0][(((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)-1:0] qcol_reduce_data_in;
    logic signed [((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))-1:0] qcol_reduce_data_out;
    logic qcol_reduce_valid_out;
    logic [16-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] qcol_zp_mul_data;
    logic [16-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] qcol_zp_mul_data_q;
    logic qcol_zp_mul_valid;
    logic [16-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] qrow_zp_mul_data;
    logic [16-1:0][((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)-1:0] qrow_zp_mul_data_q;
    logic qrow_zp_mul_valid;
    logic [16-1:0][(((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)-1:0] qrow_reduce_data_in;
    logic signed [((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))-1:0] qrow_reduce_data_out;
    logic qrow_reduce_valid_out;
    gemm_input_ctrl_t ctrl_pipe [0:WRITE_CTRL_IDX];
    logic [WRITE_CTRL_IDX:0] early_pipe;
    logic [WRITE_CTRL_IDX:0] forward_pipe;
    logic [WRITE_CTRL_IDX:0] history_forward_pipe;
    logic [16-1:0][FP32_WIDTH-1:0] selected_psum_data;
    logic [16-1:0][FP32_WIDTH-1:0] load_result_data;
    logic [16-1:0][FP32_WIDTH-1:0] writeback_result_data;
    logic writeback_history_valid;
    logic [34-1:0] writeback_history_addr;
    logic [16-1:0][FP32_WIDTH-1:0] writeback_history_data;
    logic [31:0] writeback_history_tag;
    logic writeback_history2_valid;
    logic [31:0] writeback_history2_tag;
    logic [34-1:0] writeback_history2_addr;
    logic [16-1:0][FP32_WIDTH-1:0] writeback_history2_data;
    logic load_result_valid;
    logic acc_write_valid;
    logic acc_write_fire;
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
    logic post_launch_forward;
    logic post_launch_history_forward;
    logic post_head_d3_raw_stall;
    logic post_launch_early;
    gemm_input_ctrl_t acc_launch_ctrl_q;
    logic acc_launch_valid_q;
    acc_result_t acc_result_mem [0:ACC_RESULT_DEPTH-1];
    logic [ACC_RESULT_DEPTH-1:0] acc_result_mem_valid;
    logic [ACC_RESULT_PTRW-1:0] acc_result_wr_ptr;
    logic [ACC_RESULT_PTRW-1:0] acc_result_rd_ptr;
    logic [ACC_RESULT_COUNTW-1:0] acc_result_count;
    logic [ACC_RESULT_COUNTW-1:0] acc_result_credit;
    acc_result_t acc_result_data_in;
    acc_result_t acc_result_data_out;
    logic acc_result_push;
    logic acc_result_commit;
    logic acc_result_empty;
    logic forward_match_valid;
    logic [16-1:0][FP32_WIDTH-1:0] forward_match_data;
    wire input_fire = input_bus_if.req_valid
                    && input_bus_if.req_ready;
    wire input_stage_is_qcol
        = in_pipe_payload_out.ctrl.quant_dir == 0;
    wire prealign_stage_out_is_qcol
        = pre_meta_out.ctrl.quant_dir == 0;
    wire preprocess_out_is_qcol
        = tree_meta_pipe[PREPROCESS_CTRL_IDX-PREALIGN_CTRL_IDX-1]
            .ctrl.quant_dir == 0;
    wire scaler_stage_is_qcol
        = ctrl_pipe[SCALER_OUTPUT_CTRL_IDX].quant_dir == 0;
    always_comb begin
        admitted_ctrl = gemm_unit_if.packet_ctrl;
        admitted_ctrl.valid = input_fire;
        admitted_ctrl.acc_txn_tag = acc_txn_tag_q;
        in_pipe_payload_in.data = input_bus_if.req_data.data;
        in_pipe_payload_in.ctrl = admitted_ctrl;
    end
    always_ff @(posedge clk or posedge reset) begin
        if (reset)
            acc_txn_tag_q <= '0;
        else if (input_fire)
            acc_txn_tag_q <= acc_txn_tag_q + 1'b1;
    end
    assign input_bus_if.req_ready
        = gemm_unit_if.input_admission_ready && in_pipe_ready_in;
    assign input_bus_if.rsp_valid = 1'b0;
    assign gemm_unit_if.last_write = acc_write_fire
                                      && acc_result_data_out.ctrl.last;
    assign gemm_unit_if.tagged_writeback
        = acc_write_fire
       && acc_result_data_out.ctrl.notify_on_writeback;
    assign gemm_unit_if.tagged_writeback_work_seq
        = acc_result_data_out.ctrl.work_seq;
    assign gemm_unit_if.tagged_final_writeback
        = gemm_unit_if.last_write
       && acc_result_data_out.ctrl.notify_on_writeback;
    assign gemm_unit_if.scale_register_write = scale_reg_wr_en;
    assign gemm_unit_if.zero_point_register_write = zp_reg_wr_en;
    assign gemm_unit_if.quant_register_write
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
       && (qcol_scale_consumer_ctrl.quant_dir == 0);
    assign qrow_scale_consume_last
        = qrow_scale_consumer_fire && qrow_scale_consumer_ctrl.last;
    assign qcol_scale_consume_last
        = qcol_scale_consumer_fire && qcol_scale_consumer_ctrl.last;
    assign scale_last_consume_idx = qcol_scale_consume_last
        ? qcol_scale_consumer_ctrl.sreg_use_idx
        : qrow_scale_consumer_ctrl.sreg_use_idx;
    assign gemm_unit_if.scale_consume_valid
        = qrow_scale_consume_last || qcol_scale_consume_last;
    assign gemm_unit_if.scale_consume_idx = scale_last_consume_idx;
    assign qrow_zp_consumer_fire
        = compute_fire
       && (qrow_zp_consumer_ctrl.quant_dir == 1);
    assign qcol_zp_consumer_fire = qcol_reduce_valid_out;
    assign qrow_zp_consume_last
        = qrow_zp_consumer_fire && qrow_zp_consumer_ctrl.last;
    assign qcol_zp_consume_last
        = qcol_zp_consumer_fire
       && qcol_zp_consumer_ctrl.last;
    assign zp_last_consume_idx = qcol_zp_consume_last
        ? qcol_zp_consumer_ctrl.zreg_use_idx
        : qrow_zp_consumer_ctrl.zreg_use_idx;
    assign gemm_unit_if.zp_consume_valid
        = qrow_zp_consume_last || qcol_zp_consume_last;
    assign gemm_unit_if.zp_consume_idx = zp_last_consume_idx;
    always_comb begin
        consumer_block_raw_valid = 1'b0;
        consumer_block_raw_resource = GEMM_SCHED_RESOURCE_INPUT;
        consumer_block_raw_work_seq = '0;
        consumer_block_raw_bank = 1'b0;
        consumer_block_raw_target = '0;
        if (pre_meta_valid_out && prealigner_out_valid && !weight_ready) begin
            consumer_block_raw_valid = 1'b1;
            consumer_block_raw_resource = GEMM_SCHED_RESOURCE_WEIGHT;
            consumer_block_raw_work_seq = pre_meta_out.ctrl.work_seq;
            consumer_block_raw_bank = pre_meta_out.ctrl.wreg_use_idx;
            consumer_block_raw_target = pre_meta_out.ctrl.w_load_target;
        end else if (in_pipe_valid_out && !input_stage_is_qcol
                  && !qrow_scale_ready) begin
            consumer_block_raw_valid = 1'b1;
            consumer_block_raw_resource = GEMM_SCHED_RESOURCE_SCALE;
            consumer_block_raw_work_seq
                = qrow_scale_consumer_ctrl.work_seq;
            consumer_block_raw_bank = qrow_scale_consumer_ctrl.sreg_use_idx;
            consumer_block_raw_target
                = qrow_scale_consumer_ctrl.s_load_target;
        end else if (pre_meta_valid_out && prealigner_out_valid
                  && weight_ready && !zero_ready) begin
            consumer_block_raw_valid = 1'b1;
            consumer_block_raw_resource = GEMM_SCHED_RESOURCE_ZP;
            consumer_block_raw_work_seq = pre_meta_out.ctrl.work_seq;
            consumer_block_raw_bank = pre_meta_out.ctrl.zreg_use_idx;
            consumer_block_raw_target = pre_meta_out.ctrl.z_load_target;
        end else if ((!int2fp_result_empty || int2fp_result_push)
                  && (qcol_scale_consumer_ctrl.quant_dir == 0)
                  && !qcol_scale_ready) begin
            consumer_block_raw_valid = 1'b1;
            consumer_block_raw_resource = GEMM_SCHED_RESOURCE_SCALE;
            consumer_block_raw_work_seq
                = qcol_scale_consumer_ctrl.work_seq;
            consumer_block_raw_bank = qcol_scale_consumer_ctrl.sreg_use_idx;
            consumer_block_raw_target
                = qcol_scale_consumer_ctrl.s_load_target;
        end
    end
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            gemm_unit_if.consumer_block_valid <= 1'b0;
            gemm_unit_if.consumer_block_resource <= '0;
            gemm_unit_if.consumer_block_work_seq <= '0;
            gemm_unit_if.consumer_block_bank <= 1'b0;
            gemm_unit_if.consumer_block_target <= '0;
        end else begin
            gemm_unit_if.consumer_block_valid
                <= consumer_block_raw_valid;
            gemm_unit_if.consumer_block_resource
                <= consumer_block_raw_resource;
            gemm_unit_if.consumer_block_work_seq
                <= consumer_block_raw_work_seq;
            gemm_unit_if.consumer_block_bank
                <= consumer_block_raw_bank;
            gemm_unit_if.consumer_block_target
                <= consumer_block_raw_target;
        end
    end
    assign pipeline_retire = acc_result_commit;
    assign acc_if.txn_accept_valid = input_fire;
    assign acc_if.txn_accept_tag = admitted_ctrl.acc_txn_tag;
    assign acc_if.txn_accept_rd_en = gemm_unit_if.packet_ctrl.acc_rd_en;
    assign acc_if.txn_accept_wr_en = gemm_unit_if.packet_ctrl.acc_wr_en;
    assign acc_if.txn_accept_rd_addr
        = $bits(acc_if.txn_accept_rd_addr)'(
            gemm_unit_if.packet_ctrl.acc_rd_addr);
    assign acc_if.txn_accept_wr_addr
        = $bits(acc_if.txn_accept_wr_addr)'(
            gemm_unit_if.packet_ctrl.acc_wr_addr);
    assign acc_if.txn_retire_valid = pipeline_retire;
    assign acc_if.txn_retire_tag = acc_result_data_out.ctrl.acc_txn_tag;
    assign acc_if.txn_retire_rd_en = acc_result_data_out.ctrl.acc_rd_en;
    assign acc_if.txn_retire_wr_en = acc_result_data_out.ctrl.acc_wr_en;
    assign acc_if.txn_retire_rd_addr
        = $bits(acc_if.txn_retire_rd_addr)'(
            acc_result_data_out.ctrl.acc_rd_addr);
    assign acc_if.txn_retire_wr_addr
        = $bits(acc_if.txn_retire_wr_addr)'(
            acc_result_data_out.ctrl.acc_wr_addr);
    assign gemm_unit_if.pipeline_empty
        = !(input_bus_if.req_valid
          || (pipeline_pending_count != 0)
          || pipeline_busy);
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            gemm_unit_if.input_ahead_credit <= 1'b0;
            gemm_unit_if.input_admit_valid <= 1'b0;
            gemm_unit_if.input_admit_work_seq <= '0;
        end else begin
            gemm_unit_if.input_ahead_credit
                <= in_pipe_ready_in && (tree_credit_q != 0);
            gemm_unit_if.input_admit_valid <= input_fire;
            if (input_fire)
                gemm_unit_if.input_admit_work_seq
                    <= admitted_ctrl.work_seq;
        end
    end
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
    assign post_head_d3_raw_stall
        = (!int2fp_result_empty || int2fp_result_push)
       && int2fp_result_data_out.ctrl.acc_rd_en
       && !(ctrl_pipe[MERGER_CTRL_IDX].valid
         && ctrl_pipe[MERGER_CTRL_IDX].acc_wr_en
         && (ctrl_pipe[MERGER_CTRL_IDX].acc_wr_addr
          == int2fp_result_data_out.ctrl.acc_rd_addr))
       && !(ctrl_pipe[MERGER_CTRL_IDX+1].valid
         && ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_en
         && (ctrl_pipe[MERGER_CTRL_IDX+1].acc_wr_addr
          == int2fp_result_data_out.ctrl.acc_rd_addr))
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].valid
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_en
       && ({ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_addr[
                  ($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))+1],
             ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_addr[
                  $clog2((16 * 4))]}
        == {int2fp_result_data_out.ctrl.acc_rd_addr[
                  ($clog2(((1024) * (((32/8)*16)) * 4)) - $clog2(4))+1],
             int2fp_result_data_out.ctrl.acc_rd_addr[
                  $clog2((16 * 4))]})
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK].valid
       && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK].acc_wr_en
       && (ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK].acc_wr_addr
        == int2fp_result_data_out.ctrl.acc_rd_addr);
    assign post_new_backend_read
        = int2fp_result_pop
       && int2fp_result_data_out.ctrl.acc_rd_en
       && !post_launch_forward
       && !post_launch_history_forward;
    assign acc_if.rd_req_valid = rd_hold_valid || post_new_backend_read;
    assign acc_if.rd_req_tag = rd_hold_valid
        ? rd_hold_tag : int2fp_result_data_out.ctrl.acc_txn_tag;
    assign acc_if.rd_req_addr = $bits(acc_if.rd_req_addr)'(
        rd_hold_valid
        ? rd_hold_addr : int2fp_result_data_out.ctrl.acc_rd_addr);
    assign acc_if.rd_dependency_valid = rd_hold_valid
        ? rd_hold_dependency_valid
        : (ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].valid
        && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_en);
    assign acc_if.rd_dependency_addr = $bits(acc_if.rd_dependency_addr)'(
        rd_hold_valid
        ? rd_hold_dependency_addr
        : ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_addr);
    assign acc_if.rd_rsp_ready = rd_rsp_match_valid;
    assign post_launch_early = acc_if.rd_req_early;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int i = 0; i <= WRITE_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= '0;
                early_pipe[i] <= 1'b0;
                forward_pipe[i] <= 1'b0;
                history_forward_pipe[i] <= 1'b0;
            end
        end else begin
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
        wreg_busy = '0;
        wreg_preconsume_busy = '0;
        sreg_busy = '0;
        sreg_preconsume_busy = '0;
        for (int i = 0; i < 2; ++i) begin
            zreg_busy[i] = (zreg_pending_count[i] != 0);
            zreg_preconsume_busy[i]
                = (compute_fire
                && (qrow_zp_consumer_ctrl.quant_dir == 0)
                && (qrow_zp_consumer_ctrl.zreg_use_idx
                    == gemm_qreg_idx_t'(i)))
               || (zreg_pending_count[i] > 1)
               || ((zreg_pending_count[i] == 1)
                && !(qcol_zp_consumer_fire
                  && (qcol_zp_consumer_ctrl.zreg_use_idx
                      == gemm_qreg_idx_t'(i))));
        end
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
                        || (post_txn_count != 0)
                        || rd_hold_valid
                        || post_txn_launch
                        || load_result_valid
                        || (|acc_output_valid)
                        || acc_launch_valid_q
                        || (acc_result_count != 0)
                        || (acc_result_credit
                         != ACC_RESULT_COUNTW'(ACC_RESULT_DEPTH))
                        || acc_write_fire;
        acc_pending_busy = acc_if.rd_req_valid
                        || acc_if.rd_rsp_valid
                        || acc_if.wr_req_valid
                        || (|early_pipe)
                        || (|forward_pipe)
                        || (|history_forward_pipe);
        resource_ownership_busy = (pipeline_pending_count != 0);
        for (int i = 0; i < 2; ++i) begin
            resource_ownership_busy
                |= (zreg_pending_count[i] != 0);
        end
        pipeline_busy = pre_region_busy
                     || tree_region_busy
                     || post_region_busy
                     || acc_pending_busy
                     || resource_ownership_busy
                     || mxu_transport_busy;
        for (int i = 0; i <= WRITE_CTRL_IDX; ++i)
            pipeline_busy |= ctrl_pipe[i].valid;
    end
    always_ff @(posedge clk or posedge reset) begin : pending_ownership
        if (reset) begin
            pipeline_pending_count <= '0;
            for (int i = 0; i < 2; ++i) begin
                zreg_pending_count[i] <= '0;
            end
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
                       && (qrow_zp_consumer_ctrl.quant_dir == 0)
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
        end
    end
    assign mxu_weight = weight_bus_if.req_data.data;
    assign wreg_wr_idx = weight_bus_if.req_data.addr[0];
    assign wreg_load_dir = weight_bus_if.req_data.addr[1];
    wire same_cycle_weight_release
        = gemm_unit_if.weight_consume_valid
       && (gemm_unit_if.weight_consume_idx == wreg_wr_idx)
       && !wreg_preconsume_busy[wreg_wr_idx];
    assign weight_bus_if.req_ready = !wreg_busy[wreg_wr_idx]
                                   || same_cycle_weight_release;
    assign mxu_ready_weight = weight_bus_if.req_valid
                            && weight_bus_if.req_ready;
    assign weight_bus_if.rsp_valid = 1'b0;
    assign sc_req_hs = scale_bus_if.req_valid && scale_bus_if.req_ready;
    assign sc_req_rw = scale_bus_if.req_data.rw;
    assign sc_req_addr = $bits(sc_req_addr)'(scale_bus_if.req_data.addr);
    assign sc_req_data = scale_bus_if.req_data.data;
    wire same_cycle_scale_release
        = ((qrow_scale_consumer_fire
         && (qrow_scale_consumer_ctrl.sreg_use_idx == scale_reg_idx))
        || (qcol_scale_consumer_fire
         && (qcol_scale_consumer_ctrl.sreg_use_idx == scale_reg_idx)))
       && !sreg_preconsume_busy[scale_reg_idx];
    assign scale_bus_if.req_ready
        = scale_reg_wr_req
        ? (!sreg_busy[scale_reg_idx] || same_cycle_scale_release) : 1'b1;
    assign scale_bus_if.rsp_valid = 1'b0;
    assign zp_req_hs = zero_bus_if.req_valid && zero_bus_if.req_ready;
    assign zp_req_rw = zero_bus_if.req_data.rw;
    assign zp_req_addr = $bits(zp_req_addr)'(zero_bus_if.req_data.addr);
    assign zp_req_data = zero_bus_if.req_data.data;
    wire same_cycle_zp_release
        = ((qrow_zp_consumer_fire
         && (qrow_zp_consumer_ctrl.zreg_use_idx == zp_reg_idx))
        || (qcol_zp_consumer_fire
         && (qcol_zp_consumer_ctrl.zreg_use_idx == zp_reg_idx)))
       && !zreg_preconsume_busy[zp_reg_idx];
    assign zero_bus_if.req_ready
        = zp_reg_wr_req
        ? (!zreg_busy[zp_reg_idx] || same_cycle_zp_release) : 1'b1;
    assign zero_bus_if.rsp_valid = 1'b0;
    always_comb begin
        scale_reg_idx   = 0;
        zp_reg_idx      = 0;
        scale_reg_wr_req = 0;
        zp_reg_wr_req    = 0;
        if (scale_bus_if.req_valid && sc_req_rw) begin
            scale_reg_idx = (sc_req_addr >= SCALE_REG1_BASE);
            scale_reg_wr_req = 1'b1;
        end
        if (zero_bus_if.req_valid && zp_req_rw) begin
            zp_reg_idx = (zp_req_addr >= ZP_REG1_BASE);
            zp_reg_wr_req = 1'b1;
        end
    end
    assign scale_reg_wr_en = sc_req_hs && scale_reg_wr_req;
    assign zp_reg_wr_en = zp_req_hs && zp_reg_wr_req;
    wire [((16*16)/8)-1:0] sc_req_byteen
        = scale_bus_if.req_data.byteen;
    wire [((16*16)/8)-1:0] zp_req_byteen
        = zero_bus_if.req_data.byteen;
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            scale_regs <= '0;
        end else begin
            if (scale_reg_wr_en) begin
                for (int i = 0; i < (((16) > (16)) ? (16) : (16)); i++) begin
                    if (sc_req_byteen[i * (16/8) +: (16/8)] != '0) begin
                        scale_regs[scale_reg_idx][i] <= sc_req_data[i * 16 +: 16];
                    end
                end
            end
        end
    end
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            zero_regs <= '0;
        end else begin
            if (zp_reg_wr_en) begin
                for (int i = 0; i < (((16) > (16)) ? (16) : (16)); i++) begin
                    if (zp_req_byteen[i * (16/8) +: (16/8)] != '0) begin
                        zero_regs[zp_reg_idx][i] <= -1*signed'(zp_req_data[i*16 +: 16]);
                    end
                end
            end
        end
    end
    assign prealigner_in_data = pre_branch_data;
    assign prealigner_in_valid = prealign_issue;
    assign merger_in_valid = &mxu_output_valid_dly;
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
        = gemm_unit_if.s_load_value[
              qrow_scale_consumer_ctrl.sreg_use_idx]
       == qrow_scale_consumer_ctrl.s_load_target;
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
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_in_scaler
            logic activated;
            logic a_valid, b_valid;
            logic [16-1:0] a_data, b_data;
            assign activated = !input_stage_is_qcol;
            assign a_valid   = qrow_scaler_issue;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[16*i +: 16] : '0;
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
    VX_prealigner #(
        .NUM_UNIT(16)
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
    if (1) begin : g_local_prealign_blk_idx
        (* DONT_TOUCH = "TRUE", SHREG_EXTRACT = "NO" *)
        logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0] data_q;
        logic valid_q;
        always_ff @(posedge clk) begin
            data_q <= prealigner_blk_idx;
            if (reset)
                valid_q <= 1'b0;
            else
                valid_q <= compute_fire;
        end
        assign prealigner_blk_idx_q = data_q;
        assign prealigner_pipe_out_valid = valid_q;
    end
    assign prealigner_max_exp_q = merged_fifo_data_out.max_exp;
    assign prealigner_max_exp_q_valid = merged_fifo_pop;
    generate
        for (genvar i = 0; i < 16; i++) begin : g_preprocess_inputs
            assign qcol_reduce_data_in[i]
                = (((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)'(signed'(prealigner_int_data[i]))
                <<< (1 * prealigner_blk_idx[i]);
            assign qrow_zp_mul_data[i]
                = signed'(prealigner_int_data[i])
                * signed'(zero_regs[qrow_zp_consumer_ctrl.zreg_use_idx][i]);
            assign qcol_zp_mul_data[i]
                = signed'(qcol_reduce_data_out)
                * signed'(zero_regs[qcol_zp_consumer_ctrl.zreg_use_idx][i]);
        end
    endgenerate
    VX_reduce_tree_pipelined_v2 #(
        .IN_W            ((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)),
        .OUT_W           (((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))),
        .N               (16),
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
        .DATAW (16 * ((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)),
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
        .DATAW (16 * ((((1 + 10 + (4 + 2 + (23-10))) + 1) + $clog2(16)) + 16)),
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
        for (genvar i = 0; i < 16; i++) begin : g_qrow_reduce_inputs
            assign qrow_reduce_data_in[i]
                = (((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)'(signed'(qrow_zp_mul_data_q[i]))
                <<< (1 * prealigner_blk_idx_q[i]);
        end
    endgenerate
    VX_reduce_tree_pipelined_v2 #(
        .IN_W            ((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16)),
        .OUT_W           (((((1 + 10 + (4 + 2 + (23-10))) + 1) + 16) + $clog2(16))),
        .N               (16),
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
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_pre_proc_out
            assign pre_proc_out[i] = preprocess_out_is_qcol
                                   ? signed'(qcol_zp_mul_data_q[i])
                                   : qrow_reduce_data_out;
        end
    endgenerate
    assign pre_proc_in_valid = preprocess_out_is_qcol
                             ? qcol_zp_mul_valid
                             : qrow_reduce_valid_out;
    VX_pipe_buffer #(
        .DATAW (16 * ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 16 + $clog2(16))),
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
    typedef struct packed {
        logic valid;
        logic [16-1:0][(((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) * 1 + 1)-1:0] data;
        logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0] block_idx;
        gemm_wreg_idx_t weight_sel;
    } mxu_input_transport_t;
    typedef struct packed {
        logic valid;
        logic [16-1:0][$clog2(((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) / 1) - ((((1 + 10) + 1 - 1) / 1) + ((1 == 1) ? 0 : 1)) + 1))-1:0] block_idx;
        gemm_wreg_idx_t weight_sel;
    } mxu_input_control_transport_t;
    typedef struct packed {
        logic valid;
        logic [4-1:0][16-1:0][4-1:0] data;
        gemm_wreg_idx_t weight_sel;
        logic direction;
    } mxu_weight_transport_t;
    typedef struct packed {
        logic [16/16-1:0] valid;
        logic [16-1:0][((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))-1:0] data;
    } mxu_output_transport_t;
    if (1) begin : g_slr_mxu_input_tx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", DONT_TOUCH = "TRUE" *)
        mxu_input_control_transport_t control_q;
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", DONT_TOUCH = "TRUE" *)
        logic [$bits(prealigner_int_data)-1:0] data_q;
        mxu_input_transport_t payload_q;
        assign payload_q = {control_q.valid, data_q,
                            control_q.block_idx, control_q.weight_sel};
        always_ff @(posedge clk) begin
            control_q <= {compute_fire && !reset, prealigner_blk_idx,
                          pre_meta_out.ctrl.wreg_use_idx};
            data_q <= prealigner_int_data;
        end
    end
    if (1) begin : g_slr_mxu_input_rx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        mxu_input_control_transport_t control_q;
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", DONT_TOUCH = "TRUE" *)
        logic [$bits(prealigner_int_data)-1:0] data_q;
        mxu_input_transport_t payload_q;
        assign payload_q = {control_q.valid, data_q,
                            control_q.block_idx, control_q.weight_sel};
        always_ff @(posedge clk) begin
            control_q <= g_slr_mxu_input_tx.control_q;
            data_q <= g_slr_mxu_input_tx.data_q;
            if (reset)
                control_q.valid <= 1'b0;
        end
        assign {mxu_input_valid_capture, mxu_input_capture, mxu_blk_capture,
                mxu_weight_use_capture} = payload_q;
    end
    if (1) begin : g_slr_mxu_weight_tx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO" *)
        mxu_weight_transport_t payload_q;
        always_ff @(posedge clk) begin
            payload_q <= {mxu_ready_weight && !reset, mxu_weight,
                          wreg_wr_idx, wreg_load_dir};
        end
    end
    if (1) begin : g_slr_mxu_weight_rx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        mxu_weight_transport_t payload_q;
        always_ff @(posedge clk) begin
            payload_q <= g_slr_mxu_weight_tx.payload_q;
            if (reset)
                payload_q.valid <= 1'b0;
        end
        assign {mxu_weight_valid_capture, mxu_weight_capture,
                mxu_weight_write_capture, mxu_weight_dir_capture} = payload_q;
    end
    if (1) begin : g_slr_mxu_output_tx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        mxu_output_transport_t payload_q;
        always_ff @(posedge clk) begin
            payload_q <= {mxu_output_valid, mxu_output};
            if (reset)
                payload_q.valid <= '0;
        end
    end
    if (1) begin : g_slr_mxu_output_rx
        (* USER_SLL_REG = "TRUE", SHREG_EXTRACT = "NO", EXTRACT_RESET = "yes" *)
        mxu_output_transport_t payload_q;
        always_ff @(posedge clk) begin
            payload_q <= g_slr_mxu_output_tx.payload_q;
            if (reset)
                payload_q.valid <= '0;
        end
        assign {mxu_output_valid_capture, mxu_output_capture} = payload_q;
    end
    if (1) begin : g_slr_mxu_local_ownership
        (* DONT_TOUCH = "TRUE", SHREG_EXTRACT = "NO" *)
        logic [MXU_INPUT_TRANSPORT_DLY-1:0] install_valid_q;
        (* DONT_TOUCH = "TRUE", SHREG_EXTRACT = "NO" *)
        logic [MXU_INPUT_TRANSPORT_DLY-1:0] consume_valid_q;
        (* DONT_TOUCH = "TRUE", SHREG_EXTRACT = "NO" *)
        gemm_wreg_idx_t consume_idx_q [MXU_INPUT_TRANSPORT_DLY];
        always_ff @(posedge clk) begin
            install_valid_q[0] <= mxu_ready_weight && !reset;
            consume_valid_q[0]
                <= compute_fire && pre_meta_out.ctrl.last && !reset;
            consume_idx_q[0] <= pre_meta_out.ctrl.wreg_use_idx;
            for (int i = 1; i < MXU_INPUT_TRANSPORT_DLY; ++i) begin
                install_valid_q[i] <= install_valid_q[i-1];
                consume_valid_q[i] <= consume_valid_q[i-1];
                consume_idx_q[i] <= consume_idx_q[i-1];
            end
            if (reset) begin
                install_valid_q <= '0;
                consume_valid_q <= '0;
            end
        end
        assign gemm_unit_if.weight_register_write
            = install_valid_q[MXU_INPUT_TRANSPORT_DLY-1];
        assign gemm_unit_if.weight_consume_valid
            = consume_valid_q[MXU_INPUT_TRANSPORT_DLY-1];
        assign gemm_unit_if.weight_consume_idx
            = consume_idx_q[MXU_INPUT_TRANSPORT_DLY-1];
        assign mxu_transport_busy = |install_valid_q;
    end
    VX_gemm_tree_v1 u_mxu (
        .clk_i            (clk),
        .resetn_i         (~reset),
        .ifmap_i          (mxu_input_capture),
        .weight_i         (mxu_weight_capture),
        .in_weight_sel_i  (mxu_weight_write_capture),
        .out_weight_sel_i (mxu_weight_use_capture),
        .ready_weight_i   (mxu_weight_valid_capture),
        .input_valid_i    (mxu_input_valid_capture),
        .weight_load_dir_i(mxu_weight_dir_capture),
        .blk_sidx_i       (mxu_blk_capture),
        .ps_o             (mxu_output),
        .output_valid_o   (mxu_output_valid)
    );
    generate
        for (genvar i = 0; i < (16/16); i++) begin : gen_mxu_output_dly
            VX_pipe_buffer #(
                .DATAW (16 * ((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16))),
                .DEPTH ((16/16) - 1 - i)
            ) u_mxu_output_dly_pipe (
                .clk       (clk),
                .reset     (reset),
                .valid_in  (mxu_output_valid_capture[i]),
                .ready_in  (),
                .data_in   (mxu_output_capture[16*i +: 16]),
                .data_out  (mxu_output_dly[16*i +: 16]),
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
    assign weight_ready
        = gemm_unit_if.w_load_value[pre_meta_out.ctrl.wreg_use_idx]
       == pre_meta_out.ctrl.w_load_target;
    assign zero_ready
        = gemm_unit_if.z_load_value[pre_meta_out.ctrl.zreg_use_idx]
       == pre_meta_out.ctrl.z_load_target;
    assign compute_ready
        = ((tree_credit_q != 0) || credit_return_q)
       && weight_ready
       && zero_ready
       && zp_consume_channel_ready;
    assign zp_consume_channel_ready
        = !((pre_meta_out.ctrl.quant_dir == 1)
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
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_merger
            assign merger_out_data[i]
                = (((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)'(signed'(mxu_output_dly[i]))
                + (((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)'(signed'(pre_proc_out_q[i]));
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
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_int2fp
            VX_pint2fp #(
                .IN_DW             ((((((((1 + 10 + (4 + 2 + (23-10))) + 1 - 1) / 1) * 1) + 1) + 4 + $clog2(16)) + 1)),
                .OUT_DW            (GEMM_UNIT_FP16_OUT_SCALE ? FP16_WIDTH : FP32_WIDTH),
                .IN_EXP_WIDTH      (FP16_EXP_WIDTH),
                .OUT_EXP_WIDTH     (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_WIDTH : FP32_EXP_WIDTH),
                .IN_EXP_BIAS       (FP16_EXP_BIAS),
                .OUT_EXP_BIAS      (GEMM_UNIT_FP16_OUT_SCALE ? FP16_EXP_BIAS : FP32_EXP_BIAS),
                .OUT_MANTISSA_WIDTH(GEMM_UNIT_FP16_OUT_SCALE ? FP16_MAN_WIDTH : FP32_MAN_WIDTH),
                .SCALE             (FP16_MAN_WIDTH + (4 + 2 + (23-10)))  
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
        = gemm_unit_if.s_load_value[
              qcol_scale_consumer_ctrl.sreg_use_idx]
       == qcol_scale_consumer_ctrl.s_load_target;
    assign out_scaler_input_ready
        = (&out_scaler_a_ready) && (&out_scaler_b_ready);
    assign int2fp_result_pop
        = (!int2fp_result_empty || int2fp_result_push)
       && post_txn_space
       && !rd_hold_valid
       && !post_head_d3_raw_stall
       && ((int2fp_result_data_out.ctrl.quant_dir == 1)
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
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_out_scaler
            logic a_valid, b_valid;
            logic a_ready, b_ready;
            logic [FP32_WIDTH-1:0] a_data, b_data;
            logic [FP16_EXP_WIDTH-1:0] exp;
            assign a_valid = int2fp_result_pop
                           & (int2fp_result_data_out.ctrl.quant_dir
                              == 0);
            assign b_valid = a_valid;
            assign a_data  = a_valid ? int2fp_result_data_out.data[i] : '0;
            assign out_scaler_a_ready[i] = a_ready;
            assign out_scaler_b_ready[i] = b_ready;
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
        end
    endgenerate
    VX_pipe_buffer #(
        .DATAW (16 * FP32_WIDTH),
        .DEPTH (1)
    ) u_scaler_bypass_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (int2fp_result_pop
                 && (int2fp_result_data_out.ctrl.quant_dir == 1)),
        .ready_in  (),
        .data_in   (int2fp_result_data_out.data),
        .data_out  (scaler_bypass_data),
        .ready_out (1'b1),
        .valid_out (scaler_bypass_valid)
    );
    assign final_scaled_fp_out_data  = scaler_stage_is_qcol ? scaled_fp_out_data : scaler_bypass_data;
    assign final_scaler_output_valid = scaler_stage_is_qcol ? scaler_output_valid[0] : scaler_bypass_valid;
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_f16_to_f32
            assign scaled_fp32_out_data[i] = final_scaled_fp_out_data[i];
        end
    endgenerate
    VX_pipe_buffer #(
        .DATAW (16 * FP32_WIDTH),
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
    assign post_txn_space
        = post_txn_count < POST_TXN_COUNTW'(POST_TXN_DEPTH);
    assign post_head_ctrl = post_txn_ctrl[post_txn_rd_ptr];
    always_comb begin
        scaled_match_valid = 1'b0;
        scaled_match_slot = '0;
        rd_rsp_match_valid = 1'b0;
        rd_rsp_match_slot = '0;
        for (int i = 0; i < POST_TXN_DEPTH; ++i) begin
            if (post_txn_valid[i]
             && ctrl_pipe[SCALER_CTRL_IDX].valid
             && (post_txn_ctrl[i].acc_txn_tag
              == ctrl_pipe[SCALER_CTRL_IDX].acc_txn_tag)) begin
                scaled_match_valid = 1'b1;
                scaled_match_slot = POST_TXN_PTRW'(i);
            end
            if (post_txn_valid[i]
             && post_txn_rd_issued[i]
             && !post_txn_rsp_valid[i]
             && acc_if.rd_rsp_valid
             && (post_txn_ctrl[i].acc_txn_tag == acc_if.rd_rsp_tag)) begin
                rd_rsp_match_valid = 1'b1;
                rd_rsp_match_slot = POST_TXN_PTRW'(i);
            end
        end
    end
    always_comb begin
        forward_match_valid = 1'b0;
        forward_match_data = '0;
        if (acc_result_push
         && (acc_result_data_in.ctrl.acc_txn_tag
          == post_txn_forward_tag[post_txn_rd_ptr])) begin
            forward_match_valid = 1'b1;
            forward_match_data = acc_result_data_in.data;
        end
        for (int i = 0; i < ACC_RESULT_DEPTH; ++i) begin
            if (acc_result_mem_valid[i]
             && (acc_result_mem[i].ctrl.acc_txn_tag
              == post_txn_forward_tag[post_txn_rd_ptr])) begin
                forward_match_valid = 1'b1;
                forward_match_data = acc_result_mem[i].data;
            end
        end
        if (writeback_history_valid
         && (writeback_history_tag
          == post_txn_forward_tag[post_txn_rd_ptr])) begin
            forward_match_valid = 1'b1;
            forward_match_data = writeback_history_data;
        end
        if (writeback_history2_valid
         && (writeback_history2_tag
          == post_txn_forward_tag[post_txn_rd_ptr])) begin
            forward_match_valid = 1'b1;
            forward_match_data = writeback_history2_data;
        end
    end
    always_comb begin
        post_head_scaled_ready = post_txn_scaled_valid[post_txn_rd_ptr];
        post_head_scaled_data = post_txn_scaled_data[post_txn_rd_ptr];
        if (scaled_fp32_aligned_valid && scaled_match_valid
         && (scaled_match_slot == post_txn_rd_ptr)) begin
            post_head_scaled_ready = 1'b1;
            post_head_scaled_data = scaled_fp32_aligned_data;
        end
        post_head_psum_ready = !post_head_ctrl.acc_rd_en;
        post_head_psum_data = '0;
        if (post_txn_forward[post_txn_rd_ptr]) begin
            post_head_psum_ready = forward_match_valid;
            post_head_psum_data = forward_match_data;
        end else if (post_txn_rsp_valid[post_txn_rd_ptr]) begin
            post_head_psum_ready = 1'b1;
            post_head_psum_data = post_txn_rsp_data[post_txn_rd_ptr];
        end else if (acc_if.rd_rsp_valid && rd_rsp_match_valid
                  && (rd_rsp_match_slot == post_txn_rd_ptr)) begin
            post_head_psum_ready = 1'b1;
            post_head_psum_data = acc_if.rd_rsp_data;
        end
    end
    assign post_txn_launch
        = (post_txn_count != 0)
       && post_head_scaled_ready
       && post_head_psum_ready
       && ((acc_result_credit != 0) || acc_result_commit);
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            post_txn_valid <= '0;
            post_txn_scaled_valid <= '0;
            post_txn_rsp_valid <= '0;
            post_txn_rd_issued <= '0;
            post_txn_forward <= '0;
            post_txn_forward_tag <= '0;
            post_txn_scaled_data <= '0;
            post_txn_rsp_data <= '0;
            post_txn_ctrl <= '{default:'0};
            post_txn_wr_ptr <= '0;
            post_txn_rd_ptr <= '0;
            post_txn_count <= '0;
            rd_hold_valid <= 1'b0;
            rd_hold_slot <= '0;
            rd_hold_tag <= '0;
            rd_hold_addr <= '0;
            rd_hold_dependency_valid <= 1'b0;
            rd_hold_dependency_addr <= '0;
        end else begin
            if (scaled_fp32_aligned_valid && scaled_match_valid) begin
                post_txn_scaled_valid[scaled_match_slot] <= 1'b1;
                post_txn_scaled_data[scaled_match_slot]
                    <= scaled_fp32_aligned_data;
            end
            if (acc_if.rd_rsp_valid && rd_rsp_match_valid) begin
                post_txn_rsp_valid[rd_rsp_match_slot] <= 1'b1;
                post_txn_rsp_data[rd_rsp_match_slot] <= acc_if.rd_rsp_data;
            end
            if (rd_hold_valid && acc_if.rd_req_ready) begin
                post_txn_rd_issued[rd_hold_slot] <= 1'b1;
                rd_hold_valid <= 1'b0;
            end
            if (int2fp_result_pop) begin
                post_txn_valid[post_txn_wr_ptr] <= 1'b1;
                post_txn_scaled_valid[post_txn_wr_ptr] <= 1'b0;
                post_txn_rsp_valid[post_txn_wr_ptr] <= 1'b0;
                post_txn_ctrl[post_txn_wr_ptr]
                    <= int2fp_result_data_out.ctrl;
                post_txn_forward[post_txn_wr_ptr]
                    <= post_launch_forward || post_launch_history_forward;
                post_txn_forward_tag[post_txn_wr_ptr]
                    <= post_launch_forward
                     ? ctrl_pipe[MERGER_CTRL_IDX].acc_txn_tag
                     : ctrl_pipe[MERGER_CTRL_IDX+1].acc_txn_tag;
                post_txn_rd_issued[post_txn_wr_ptr]
                    <= post_new_backend_read && acc_if.rd_req_ready;
                post_txn_wr_ptr <= post_txn_wr_ptr + 1'b1;
                if (post_new_backend_read && !acc_if.rd_req_ready) begin
                    rd_hold_valid <= 1'b1;
                    rd_hold_slot <= post_txn_wr_ptr;
                    rd_hold_tag <= int2fp_result_data_out.ctrl.acc_txn_tag;
                    rd_hold_addr <= int2fp_result_data_out.ctrl.acc_rd_addr;
                    rd_hold_dependency_valid
                        <= ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].valid
                        && ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_en;
                    rd_hold_dependency_addr
                        <= ctrl_pipe[MERGER_CTRL_IDX+K_LOOKBACK-1].acc_wr_addr;
                end
            end
            if (post_txn_launch) begin
                post_txn_valid[post_txn_rd_ptr] <= 1'b0;
                post_txn_scaled_valid[post_txn_rd_ptr] <= 1'b0;
                post_txn_rsp_valid[post_txn_rd_ptr] <= 1'b0;
                post_txn_rd_issued[post_txn_rd_ptr] <= 1'b0;
                post_txn_forward[post_txn_rd_ptr] <= 1'b0;
                post_txn_rd_ptr <= post_txn_rd_ptr + 1'b1;
            end
            case ({int2fp_result_pop, post_txn_launch})
                2'b10: post_txn_count <= post_txn_count + 1'b1;
                2'b01: post_txn_count <= post_txn_count - 1'b1;
                default: begin end
            endcase
        end
    end
    VX_pipe_buffer #(
        .DATAW (16 * FP32_WIDTH),
        .DEPTH (ACC_ADD_DLY)
    ) u_load_result_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (post_txn_launch && post_head_ctrl.is_load),
        .ready_in  (),
        .data_in   (post_head_scaled_data),
        .data_out  (load_result_data),
        .ready_out (1'b1),
        .valid_out (load_result_valid)
    );
    assign selected_psum_data = post_head_psum_data;
    generate
        for (genvar i = 0; i < 16; ++i) begin : gen_accumulator
            logic a_ready;
            logic b_ready;
            assign acc_in_data_valid[i]
                = post_txn_launch && post_head_ctrl.acc_rd_en;
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
                .a_data       (post_head_scaled_data[i]),
                .b_valid      (acc_psum_data_valid[i]),
                .b_ready      (b_ready),
                .b_data       (selected_psum_data[i]),
                .result_valid (acc_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (acc_output_data[i])
            );
        end
    endgenerate
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            acc_launch_ctrl_q <= '0;
            acc_launch_valid_q <= 1'b0;
        end else begin
            acc_launch_ctrl_q <= post_head_ctrl;
            acc_launch_valid_q <= post_txn_launch;
        end
    end
    always_comb begin
        acc_result_data_in.ctrl = acc_launch_ctrl_q;
        acc_result_data_in.data = acc_launch_ctrl_q.is_load
            ? load_result_data : acc_output_data;
    end
    assign acc_result_push
        = acc_launch_valid_q
       && (!acc_launch_ctrl_q.acc_wr_en
        || (acc_launch_ctrl_q.is_load
         ? load_result_valid : acc_output_valid[0]));
    assign acc_result_empty = (acc_result_count == 0);
    assign acc_result_data_out = acc_result_empty
        ? acc_result_data_in : acc_result_mem[acc_result_rd_ptr];
    assign acc_if.wr_req_valid
        = (!acc_result_empty || acc_result_push)
       && acc_result_data_out.ctrl.acc_wr_en;
    assign acc_if.wr_req_tag = acc_result_data_out.ctrl.acc_txn_tag;
    assign acc_if.wr_req_addr
        = $bits(acc_if.wr_req_addr)'(
            acc_result_data_out.ctrl.acc_wr_addr);
    assign acc_if.wr_req_data = acc_result_data_out.data;
    assign acc_if.wr_req_final_output = acc_result_data_out.ctrl.last;
    assign acc_if.wr_req_last = acc_result_data_out.ctrl.last;
    assign acc_write_fire = acc_if.wr_req_valid && acc_if.wr_req_ready;
    assign acc_write_valid = acc_if.wr_req_valid;
    assign acc_result_commit
        = (!acc_result_empty || acc_result_push)
       && (!acc_result_data_out.ctrl.acc_wr_en || acc_if.wr_req_ready);
    assign writeback_result_data = acc_result_data_out.data;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            acc_result_mem_valid <= '0;
            acc_result_mem <= '{default:'0};
            acc_result_wr_ptr <= '0;
            acc_result_rd_ptr <= '0;
            acc_result_count <= '0;
            acc_result_credit <= ACC_RESULT_COUNTW'(ACC_RESULT_DEPTH);
        end else begin
            if (acc_result_push && !(acc_result_empty && acc_result_commit)) begin
                acc_result_mem[acc_result_wr_ptr] <= acc_result_data_in;
                acc_result_mem_valid[acc_result_wr_ptr] <= 1'b1;
            end
            if (acc_result_commit && !acc_result_empty)
                acc_result_mem_valid[acc_result_rd_ptr] <= 1'b0;
            if (acc_result_push)
                acc_result_wr_ptr <= acc_result_wr_ptr + 1'b1;
            if (acc_result_commit)
                acc_result_rd_ptr <= acc_result_rd_ptr + 1'b1;
            case ({acc_result_push, acc_result_commit})
                2'b10: acc_result_count <= acc_result_count + 1'b1;
                2'b01: acc_result_count <= acc_result_count - 1'b1;
                default: begin end
            endcase
            case ({post_txn_launch, acc_result_commit})
                2'b10: acc_result_credit <= acc_result_credit - 1'b1;
                2'b01: acc_result_credit <= acc_result_credit + 1'b1;
                default: begin end
            endcase
        end
    end
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            writeback_history_valid <= 1'b0;
            writeback_history_tag <= '0;
            writeback_history_addr <= '0;
            writeback_history_data <= '0;
            writeback_history2_valid <= 1'b0;
            writeback_history2_tag <= '0;
            writeback_history2_addr <= '0;
            writeback_history2_data <= '0;
        end else if (acc_write_fire) begin
            writeback_history2_valid <= writeback_history_valid;
            writeback_history2_tag <= writeback_history_tag;
            writeback_history2_addr <= writeback_history_addr;
            writeback_history2_data <= writeback_history_data;
            writeback_history_valid <= 1'b1;
            writeback_history_tag <= acc_result_data_out.ctrl.acc_txn_tag;
            writeback_history_addr
                <= acc_result_data_out.ctrl.acc_wr_addr;
            writeback_history_data <= writeback_result_data;
        end
    end
endmodule

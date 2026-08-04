`include "VX_define.vh"

module VX_gemm_unit_v2 import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire              clk,
    input wire              reset,

    VX_mem_bus_if.slave     i_lmem_bus_if,
    VX_mem_bus_if.slave     w_lmem_bus_if,
    VX_mem_bus_if.slave     sz_lmem_bus_if,
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
    localparam MAX_EXP_IN_DELAY = MXU_OUT_DLY + DEFAULT_OUT_DLY;
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY
                                - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;
    localparam FP16_MUL_LATENCY = 0;
    localparam FP32_MUL_LATENCY = 0;
    localparam FP32_ADD_LATENCY = 0;
    localparam FP_SCALER_DLY = 1;
    localparam ACC_SRAM_RD_DLY = 1;
    localparam ACC_ADD_DLY = 1;
    localparam ACC_POST_DLY = 0;

    // ctrl_pipe[0] aligns with the one-cycle input pipe output.
    localparam INPUT_CTRL_IDX = 0;
    localparam PREALIGN_INPUT_CTRL_IDX = INPUT_CTRL_IDX + INPUT_SCALE_DLY;
    localparam PREALIGN_CTRL_IDX = PREALIGN_INPUT_CTRL_IDX + PREALIGN_DLY;
    localparam QCOL_REDUCE_CTRL_IDX = PREALIGN_CTRL_IDX + ACT_REDUCE_OUT_DLY;
    localparam PREPROCESS_CTRL_IDX = QCOL_REDUCE_CTRL_IDX + DEFAULT_OUT_DLY;
    localparam MXU_CTRL_IDX = PREALIGN_CTRL_IDX + MXU_OUT_DLY;
    localparam MERGER_CTRL_IDX = MXU_CTRL_IDX + DEFAULT_OUT_DLY;
    localparam INT2FP_CTRL_IDX = MERGER_CTRL_IDX + INTTOFP_OUT_DLY;
    localparam SCALER_CTRL_IDX = INT2FP_CTRL_IDX + FP_SCALER_DLY;
    localparam WRITE_CTRL_IDX = SCALER_CTRL_IDX + ACC_ADD_DLY + ACC_POST_DLY;

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
    `VX_STATIC_ASSERT(L_PRE >= L_R + 1, ("L_PRE must cover SRAM read latency"))
    `VX_STATIC_ASSERT(K_LOOKBACK > 0, ("K lookback must be positive"))
    `VX_STATIC_ASSERT(EARLY_READ_DLY > 0, ("early read delay must be positive"))
    `VX_STATIC_ASSERT(WRITE_CTRL_IDX == WRITE_DLY - 1,
        ("write control index mismatch"))
    `VX_STATIC_ASSERT(WRITE_CTRL_IDX == SCALER_CTRL_IDX + 1,
        ("immediate forwarding requires concurrent prior writeback"))

    function automatic [1:0] get_acc_mem_idx(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        logic group;
        logic bank_offset;
        group = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
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

    // Scale/Zero write control signals
    logic                                            sz_req_hs;
    logic                                            sz_req_rw;
    logic [`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE*4)-1:0] sz_req_addr;
    logic [`GEMM_SCALE_ZERO_DATA_SIZE*8-1:0]         sz_req_data;
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

    // -------------------------------------------------------------------------
    // Input Scaler Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW-1:0]                           in_scaler_a_ready;
    logic [`MXU_ROW-1:0]                           in_scaler_b_ready;
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0]           in_scaler_result_data;
    logic [`MXU_ROW-1:0]                           in_scaler_result_valid;

    // -------------------------------------------------------------------------
    // Prealigner Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0]           prealigner_in_data;
    logic                                          prealigner_in_valid;
    logic [`MXU_ROW-1:0][`SEL_BLOCK_WIDTH-1:0]     prealigner_int_data;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0]     prealigner_blk_idx;
    logic [`IFP_EXP_WIDTH-1:0]                     prealigner_max_exp;
    logic                                          prealigner_out_valid;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0]     prealigner_blk_idx_q;
    logic                                          prealigner_pipe_out_valid;
    logic [`IFP_EXP_WIDTH-1:0]                     prealigner_max_exp_q;
    logic                                          prealigner_max_exp_q_valid;

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
`ifdef WLOAD_AT_ONCE
    (* max_fanout = 32 *) logic wreg_wr_idx;
    (* max_fanout = 32 *) logic wreg_load_dir;
`else
    logic wreg_wr_idx;
    logic wreg_load_dir;
`endif

    // -------------------------------------------------------------------------
    // Merger Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0]        merger_out_data;
    logic                                          merger_in_valid;
    logic [`MXU_COL-1:0][`MERGE_OUT_BW-1:0]        merger_out_data_q;
    logic                                          merger_out_valid;

    // -------------------------------------------------------------------------
    // Int to FP Converter Signals
    // -------------------------------------------------------------------------
`ifdef GEMM_UNIT_FP16_OUT_SCALE
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           int2fp_out_data;
`else
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           int2fp_out_data;
`endif

    logic [`MXU_COL-1:0]                           int2fp_output_valid;

    // -------------------------------------------------------------------------
    // Output Scaler Signals
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // Accumulator Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           acc_output_data;
    logic [`MXU_COL-1:0]                           acc_output_valid;
    logic [`MXU_COL-1:0]                           acc_in_data_valid;
    logic [`MXU_COL-1:0]                           acc_psum_data_valid;


    logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] qcol_input_data;
    logic qcol_input_valid;

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
    logic load_result_valid;
    logic acc_write_fire;
    logic [1:0] write_bank;
    logic [1:0] accum_bank;
    logic [1:0] output_read_bank;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_read_addr;
    logic output_read_fire;
    logic output_read_valid;
    logic [1:0] output_read_bank_q;
    logic [$bits(o_lmem_bus_if.req_data.tag)-1:0] output_read_tag_q;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] fp16_out_data;
    logic [`MXU_COL-1:0] fp16_out_valid;
    logic [1:0] wreg_busy;
    logic [1:0] sreg_busy;
    logic [1:0] zreg_busy;
    logic pipeline_busy;

    wire input_fire = i_lmem_bus_if.req_valid;
    wire admission_forward
        = input_fire
       && gemm_unit_v2_if.packet_ctrl.acc_rd_en
       && ctrl_pipe[0].valid
       && ctrl_pipe[0].acc_wr_en
       && (ctrl_pipe[0].acc_wr_addr
        == gemm_unit_v2_if.packet_ctrl.acc_rd_addr);
    wire input_stage_is_qcol
        = ctrl_pipe[INPUT_CTRL_IDX].quant_dir == `QDIR_COL;
    wire prealign_stage_is_qcol
        = ctrl_pipe[PREALIGN_INPUT_CTRL_IDX].quant_dir == `QDIR_COL;
    wire prealign_stage_out_is_qcol
        = ctrl_pipe[PREALIGN_CTRL_IDX].quant_dir == `QDIR_COL;
    wire preprocess_out_is_qcol
        = ctrl_pipe[PREPROCESS_CTRL_IDX].quant_dir == `QDIR_COL;
    wire int2fp_stage_is_qcol
        = ctrl_pipe[INT2FP_CTRL_IDX].quant_dir == `QDIR_COL;
    wire scaler_stage_is_qcol
        = ctrl_pipe[SCALER_CTRL_IDX].quant_dir == `QDIR_COL;

    assign i_lmem_bus_if.req_ready = 1'b1;
    assign i_lmem_bus_if.rsp_valid = 1'b0;
    assign gemm_unit_v2_if.last_write = acc_write_fire
                                      && ctrl_pipe[WRITE_CTRL_IDX].last;
    assign gemm_unit_v2_if.pipeline_empty
        = !(i_lmem_bus_if.req_valid
          || (|early_rsp_pending)
          || (|early_hold_valid)
          || pipeline_busy);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int i = 0; i <= WRITE_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= '0;
                early_pipe[i] <= 1'b0;
                forward_pipe[i] <= 1'b0;
            end
        end else begin
            ctrl_pipe[0] <= gemm_unit_v2_if.packet_ctrl;
            ctrl_pipe[0].valid <= input_fire;
            forward_pipe[0] <= admission_forward;
            early_pipe[0] <= input_fire
                          && gemm_unit_v2_if.packet_ctrl.acc_rd_en
                          && !admission_forward
                          && ctrl_pipe[K_LOOKBACK-1].valid
                          && ctrl_pipe[K_LOOKBACK-1].acc_wr_en
                          && (get_acc_mem_idx(ctrl_pipe[K_LOOKBACK-1].acc_wr_addr)
                           == get_acc_mem_idx(gemm_unit_v2_if.packet_ctrl.acc_rd_addr));
            for (int i = 1; i <= WRITE_CTRL_IDX; ++i) begin
                ctrl_pipe[i] <= ctrl_pipe[i-1];
                early_pipe[i] <= early_pipe[i-1];
                forward_pipe[i] <= forward_pipe[i-1];
            end
        end
    end

    always_comb begin
        wreg_busy = '0;
        sreg_busy = '0;
        zreg_busy = '0;
        pipeline_busy = 1'b0;
        for (int i = 0; i <= WRITE_CTRL_IDX; ++i) begin
            if (ctrl_pipe[i].valid) begin
                pipeline_busy = 1'b1;
                wreg_busy[ctrl_pipe[i].wreg_use_idx] = 1'b1;
                sreg_busy[ctrl_pipe[i].sreg_use_idx] = 1'b1;
                zreg_busy[ctrl_pipe[i].zreg_use_idx] = 1'b1;
            end
        end
        if (input_fire) begin
            wreg_busy[gemm_unit_v2_if.packet_ctrl.wreg_use_idx] = 1'b1;
            sreg_busy[gemm_unit_v2_if.packet_ctrl.sreg_use_idx] = 1'b1;
            zreg_busy[gemm_unit_v2_if.packet_ctrl.zreg_use_idx] = 1'b1;
        end
    end

`ifdef WLOAD_AT_ONCE
    wire mxu_w_pipe_valid_out;
    wire mxu_w_pipe_ready_out = !wreg_busy[wreg_wr_idx];

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
    assign w_lmem_bus_if.req_ready = !wreg_busy[wreg_wr_idx];
    assign mxu_ready_weight = w_lmem_bus_if.req_valid
                            && w_lmem_bus_if.req_ready;
`endif
    assign w_lmem_bus_if.rsp_valid = 1'b0;

    assign sz_req_hs = sz_lmem_bus_if.req_valid && sz_lmem_bus_if.req_ready;
    assign sz_req_rw = sz_lmem_bus_if.req_data.rw;
    assign sz_req_addr = $bits(sz_req_addr)'(sz_lmem_bus_if.req_data.addr);
    assign sz_req_data = sz_lmem_bus_if.req_data.data;
    assign sz_lmem_bus_if.req_ready
        = zp_reg_wr_req ? !zreg_busy[zp_reg_idx]
        : scale_reg_wr_req ? !sreg_busy[scale_reg_idx]
        : 1'b1;
    assign sz_lmem_bus_if.rsp_valid = 1'b0;

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

        if(sz_lmem_bus_if.req_valid && sz_req_rw) begin
            if (sz_req_addr >= SCALE_REG0_BASE && sz_req_addr < SCALE_REG1_BASE) begin
                scale_reg_idx   = 1'b0;
                scale_reg_wr_req = 1'b1;
            end else if (sz_req_addr >= SCALE_REG1_BASE && sz_req_addr < ZP_REG0_BASE) begin
                scale_reg_idx   = 1'b1;
                scale_reg_wr_req = 1'b1;
            end else if (sz_req_addr >= ZP_REG0_BASE && sz_req_addr < ZP_REG1_BASE) begin
                zp_reg_idx      = 1'b0;
                zp_reg_wr_req    = 1'b1;
            end else if (sz_req_addr >= ZP_REG1_BASE) begin
                zp_reg_idx      = 1'b1;
                zp_reg_wr_req    = 1'b1;
            end
        end

    end

    assign scale_reg_wr_en = sz_req_hs && scale_reg_wr_req;
    assign zp_reg_wr_en = sz_req_hs && zp_reg_wr_req;

    // ----- Write to scale registers (byte-enable masked) -----
    wire [`GEMM_SCALE_ZERO_DATA_SIZE-1:0] sz_req_byteen = sz_lmem_bus_if.req_data.byteen;

    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            scale_regs <= '0;
        end else begin
            if (scale_reg_wr_en) begin
                for (int i = 0; i < `MAX(`MXU_ROW, `MXU_COL); i++) begin
                    if (sz_req_byteen[i * (`SCALE_WIDTH/8) +: (`SCALE_WIDTH/8)] != '0) begin
                        scale_regs[scale_reg_idx][i] <= sz_req_data[i * `SCALE_WIDTH +: `SCALE_WIDTH];
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
                    if (sz_req_byteen[i * (`ZP_WIDTH/8) +: (`ZP_WIDTH/8)] != '0) begin
                        zero_regs[zp_reg_idx][i] <= -1*signed'(sz_req_data[i*`ZP_WIDTH +: `ZP_WIDTH]);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Datapath Combinational Logic
    // =========================================================================

    // ----- Prealigner Input Selection -----
    assign prealigner_in_data  = prealign_stage_is_qcol ? qcol_input_data : in_scaler_result_data;
    assign prealigner_in_valid = prealign_stage_is_qcol ? qcol_input_valid : in_scaler_result_valid[0];

    // ----- Merger Input Valid -----
    assign merger_in_valid = &mxu_output_valid_dly;

    // =========================================================================
    // Sub-module Instantiations
    // =========================================================================

    // -------------------------------------------------------------------------
    // Input Pipeline and QCOL/QROW Alignment
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW (`MXU_ROW * `IFP_WIDTH),
        .DEPTH (DEFAULT_OUT_DLY)
    ) u_in_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (input_fire),
        .ready_in  (),
        .data_in   (i_lmem_bus_if.req_data.data),
        .data_out  (in_pipe_data_out),
        .ready_out (1'b1),
        .valid_out (in_pipe_valid_out)
    );

    VX_pipe_buffer #(
        .DATAW (`MXU_ROW * `IFP_WIDTH),
        .DEPTH (INPUT_SCALE_DLY)
    ) u_qcol_input_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (in_pipe_valid_out && input_stage_is_qcol),
        .ready_in  (),
        .data_in   (in_pipe_data_out),
        .data_out  (qcol_input_data),
        .ready_out (1'b1),
        .valid_out (qcol_input_valid)
    );

    // -------------------------------------------------------------------------
    // Input Scalers
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : gen_in_scaler
`ifndef SYNTHESIS
            localparam int LANE_ID = i;
`endif
            logic activated;
            logic a_valid, b_valid;
            logic [`IFP_WIDTH-1:0] a_data, b_data;

            assign activated = (ctrl_pipe[INPUT_CTRL_IDX].quant_dir == `QDIR_ROW);
            assign a_valid   = in_pipe_valid_out & activated;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[`IFP_WIDTH*i +: `IFP_WIDTH] : '0;
            assign b_data    = activated ? scale_regs[ctrl_pipe[INPUT_CTRL_IDX].sreg_use_idx][i] : '0;

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
                .result_ready (1'b1),
                .result_data  (in_scaler_result_data[i])
            );

`ifndef SYNTHESIS
            always @(posedge clk) begin
                if (!reset && a_valid && !in_scaler_a_ready[i]) begin
                    $fatal(1, "[%0t] GEMM input scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !in_scaler_b_ready[i]) begin
                    $fatal(1, "[%0t] GEMM input scaler lane %0d backpressured while b_valid is asserted",
                           $time, LANE_ID);
                end
            end
`endif
        end
    endgenerate

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
        .ready_o    (),
        .int_data_o (prealigner_int_data),
        .blk_idx_o  (prealigner_blk_idx),
        .max_exp_o  (prealigner_max_exp),
        .valid_o    (prealigner_out_valid),
        .ready_i    (1'b1)
    );

    VX_pipe_buffer #(
        .DATAW (`MXU_ROW * `BLOCK_IDX_WIDTH),
        .DEPTH (BLK_IDX_DLY)
    ) u_prealign_blk_idx_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (prealigner_out_valid),
        .ready_in  (),
        .data_in   (prealigner_blk_idx),
        .data_out  (prealigner_blk_idx_q),
        .ready_out (1'b1),
        .valid_out (prealigner_pipe_out_valid)
    );

    VX_pipe_buffer #(
        .DATAW (`IFP_EXP_WIDTH),
        .DEPTH (MAX_EXP_IN_DELAY)
    ) u_prealign_max_exp_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (prealigner_out_valid),
        .ready_in  (),
        .data_in   (prealigner_max_exp),
        .data_out  (prealigner_max_exp_q),
        .ready_out (1'b1),
        .valid_out (prealigner_max_exp_q_valid)
    );

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
                * signed'(zero_regs[ctrl_pipe[PREALIGN_CTRL_IDX].zreg_use_idx][i]);
            assign qcol_zp_mul_data[i]
                = signed'(qcol_reduce_data_out)
                * signed'(zero_regs[ctrl_pipe[QCOL_REDUCE_CTRL_IDX].zreg_use_idx][i]);
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
        .valid_in  (prealigner_out_valid && prealign_stage_out_is_qcol),
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
        .valid_in  (prealigner_out_valid && !prealign_stage_out_is_qcol),
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
        .out_weight_sel_i (ctrl_pipe[PREALIGN_CTRL_IDX].wreg_use_idx),
        .ready_weight_i   (mxu_ready_weight),
        .input_valid_i    (prealigner_out_valid),
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

    VX_pipe_buffer #(
        .DATAW(`MERGE_OUT_BW * `MXU_COL),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_merge_out_reg (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (merger_in_valid),
        .ready_in  (),
        .data_in   (merger_out_data),
        .data_out  (merger_out_data_q),
        .ready_out (1'b1),
        .valid_out (merger_out_valid)
    );

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

            assign a_valid = int2fp_output_valid[i] & int2fp_stage_is_qcol;
            assign b_valid = int2fp_output_valid[i] & int2fp_stage_is_qcol;
            assign a_data  = (int2fp_output_valid[i] & int2fp_stage_is_qcol) ? int2fp_out_data[i] : '0;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            assign b_data  = (int2fp_output_valid[i] & int2fp_stage_is_qcol) ? scale_regs[ctrl_pipe[INT2FP_CTRL_IDX].sreg_use_idx][i] : '0;
`else
            assign b_data[31]  = (int2fp_output_valid[i] & int2fp_stage_is_qcol) ? scale_regs[ctrl_pipe[INT2FP_CTRL_IDX].sreg_use_idx][i][15] : '0;
            assign exp = scale_regs[ctrl_pipe[INT2FP_CTRL_IDX].sreg_use_idx][i][14:10];
            assign b_data[30:23]
                = (int2fp_output_valid[i] & int2fp_stage_is_qcol)
                ? (&exp == 1'b1
                 ? '1
                 : FP32_EXP_WIDTH'(exp) + FP32_EXP_WIDTH'(FP32_EXP_BIAS - FP16_EXP_BIAS))
                : '0;
            assign b_data[22:0]  = (int2fp_output_valid[i] & int2fp_stage_is_qcol) ? {scale_regs[ctrl_pipe[INT2FP_CTRL_IDX].sreg_use_idx][i][9:0], 13'b0} : '0;
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
                if (!reset && a_valid && !a_ready) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !b_ready) begin
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
                if (!reset && a_valid && !a_ready) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !b_ready) begin
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
        .valid_in  (int2fp_output_valid[0] & ~int2fp_stage_is_qcol),
        .ready_in  (),
        .data_in   (int2fp_out_data),
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


    // -------------------------------------------------------------------------
    // Load/accumulate latency alignment
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW (`MXU_COL * FP32_WIDTH),
        .DEPTH (ACC_ADD_DLY)
    ) u_load_result_align (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (final_scaler_output_valid
                 && ctrl_pipe[SCALER_CTRL_IDX].valid
                 && ctrl_pipe[SCALER_CTRL_IDX].is_load),
        .ready_in  (),
        .data_in   (scaled_fp32_out_data),
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
        end else if (early_pipe[SCALER_CTRL_IDX]) begin
            selected_psum_data = early_hold_data[accum_bank];
        end
    end

    generate
        for (genvar i = 0; i < `MXU_COL; ++i) begin : gen_accumulator
            logic a_ready;
            logic b_ready;

            assign acc_in_data_valid[i]
                = final_scaler_output_valid
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
                .a_data       (scaled_fp32_out_data[i]),
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

    assign output_read_addr
        = `GEMM_ACC_MEM_ADDR_WIDTH'(
            o_lmem_bus_if.req_data.addr << `CLOG2(`GEMM_PSUM_DATA_SIZE));
    assign output_read_bank = get_acc_mem_idx(output_read_addr);
    assign o_lmem_bus_if.req_ready
        = gemm_unit_v2_if.pipeline_empty && !output_read_valid;
    assign output_read_fire
        = o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready
       && !o_lmem_bus_if.req_data.rw;
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

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            stream_address_valid <= 1'b0;
            stream_rd_addr_q <= '0;
            stream_wr_addr_q <= '0;
        end else if (input_fire) begin
            stream_address_valid <= !gemm_unit_v2_if.packet_ctrl.last;
            stream_rd_addr_q <= gemm_unit_v2_if.packet_ctrl.acc_rd_addr;
            stream_wr_addr_q <= gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
        end
    end

    always @(posedge clk) begin
        if (!reset) begin
            assert (i_lmem_bus_if.req_ready)
                else $fatal(1, "GEMM v2 input ready deasserted");
            assert (gemm_unit_v2_if.packet_ctrl.valid
                 == i_lmem_bus_if.req_valid)
                else $fatal(1, "GEMM v2 packet valid mismatch");
            assert ((early_read_req & nominal_read_req) == '0)
                else $fatal(1, "GEMM v2 same-bank read/read collision");
            assert ((acc_mem_wr_en & acc_mem_rd_en) == '0)
                else $fatal(1, "GEMM v2 same-bank read/write collision");
            assert ((early_rsp_pending & early_hold_valid) == '0)
                else $fatal(1, "GEMM v2 early hold overwrite");
            if (input_fire && stream_address_valid) begin
                assert ((gemm_unit_v2_if.packet_ctrl.acc_rd_addr
                       == stream_rd_addr_q + `GEMM_PSUM_DATA_SIZE
                      && gemm_unit_v2_if.packet_ctrl.acc_wr_addr
                       == stream_wr_addr_q + `GEMM_PSUM_DATA_SIZE)
                     || (admission_forward
                      && gemm_unit_v2_if.packet_ctrl.acc_rd_addr
                       == stream_wr_addr_q
                      && gemm_unit_v2_if.packet_ctrl.acc_wr_addr
                       == stream_wr_addr_q))
                    else $fatal(1, "GEMM v2 address is neither strict progression nor immediate forwarding");
            end
            if (admission_forward) begin
                assert (ctrl_pipe[0].valid && ctrl_pipe[0].acc_wr_en)
                    else $fatal(1, "GEMM v2 forwarding dependency has no prior writer");
                assert (ctrl_pipe[0].acc_wr_addr
                     == gemm_unit_v2_if.packet_ctrl.acc_rd_addr)
                    else $fatal(1, "GEMM v2 forwarding admission address mismatch");
            end
            if (ctrl_pipe[SCALER_CTRL_IDX].valid
             && ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en
             && early_pipe[SCALER_CTRL_IDX]) begin
                assert (early_hold_valid[accum_bank])
                    else $fatal(1, "GEMM v2 missing early PSUM");
            end
            if (ctrl_pipe[SCALER_CTRL_IDX].valid
             && forward_pipe[SCALER_CTRL_IDX]) begin
                assert (ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en)
                    else $fatal(1, "GEMM v2 forwarding packet is not accumulating");
                assert (acc_write_fire)
                    else $fatal(1, "GEMM v2 forwarding source writeback is invalid");
                assert (ctrl_pipe[WRITE_CTRL_IDX].acc_wr_addr
                     == ctrl_pipe[SCALER_CTRL_IDX].acc_rd_addr)
                    else $fatal(1, "GEMM v2 forwarding consume address mismatch");
            end
            if (ctrl_pipe[SCALER_CTRL_IDX].valid
             && ctrl_pipe[SCALER_CTRL_IDX].acc_rd_en) begin
                assert (final_scaler_output_valid)
                    else $fatal(1, "GEMM v2 control/data latency mismatch");
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

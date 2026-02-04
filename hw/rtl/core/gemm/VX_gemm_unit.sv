`include "VX_define.vh"

/*
  - weight write features
    - addr[0]: wreg_wr_idx
    - addr[1]: weight_load_dir
    weights are written like fifo
*/

module VX_gemm_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    // Clock and Reset
    input wire              clk,
    input wire              reset,

    // Memory Bus Interfaces
    VX_mem_bus_if.slave     i_lmem_bus_if,    // for inputs
    VX_mem_bus_if.slave     w_lmem_bus_if,    // for weights
    VX_mem_bus_if.slave     sz_lmem_bus_if,   // for scale and zero params
    VX_mem_bus_if.slave     o_lmem_bus_if,    // for read output

    // Control Interface
    VX_gemm_unit_if.slave   gemm_unit_if      // for ctrl gemm
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam FP32_WIDTH     = 32;
    localparam FP32_EXP_WIDTH = 8;
    localparam FP32_EXP_BIAS  = 127;
    localparam FP32_MAN_WIDTH = 23;

    localparam FP16_WIDTH     = 16;
    localparam FP16_EXP_WIDTH = 5;
    localparam FP16_EXP_BIAS  = 15;
    localparam FP16_MAN_WIDTH = 10;

    // Scale/Zero register address map
    localparam SCALE_REG_SIZE  = `MAX(`MXU_ROW, `MXU_COL) * `SCALE_WIDTH / 8;
    localparam ZP_REG_SIZE     = `MAX(`MXU_ROW, `MXU_COL) * `ZP_WIDTH / 8;
    localparam SCALE_REG0_BASE = 0;
    localparam SCALE_REG1_BASE = SCALE_REG_SIZE;
    localparam ZP_REG0_BASE    = SCALE_REG_SIZE * 2;
    localparam ZP_REG1_BASE    = SCALE_REG_SIZE * 2 + ZP_REG_SIZE;

    // pipeline delays (reference point is prealigner output)
    localparam DEFAULT_OUT_DLY = 1;
    localparam ACT_REDUCE_OUT_DLY = get_pipe_stage_num(`MXU_ROW, `ACT_REDUCE_PIPE_INTV);
    localparam ACT_REDUCE_PIPE_STAGES = get_pipe_stage_bitmask(`MXU_ROW, `ACT_REDUCE_PIPE_INTV);
    localparam BLK_IDX_DLY = ACT_REDUCE_OUT_DLY;
    localparam MXU_OUT_DLY = (`MXU_PIPE_MUL_EN + `MXU_PIPE_ALIGN_EN + 1) + get_pipe_stage_num(`MXU_ROW, `MXU_PIPE_ADD_INTV) + ((`MXU_COL / `MXU_COL_TILE) - 1);
    localparam MAX_EXP_IN_DELAY = MXU_OUT_DLY + DEFAULT_OUT_DLY;
    `STATIC_ASSERT(MXU_OUT_DLY >= ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY, ("MXU_OUT_DLY must be >= ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY"));
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;

    // output scale config
`ifdef GEMM_UNIT_FP16_OUT_SCALE
    localparam GEMM_UNIT_FP16_OUT_SCALE = 1;
`else 
    localparam GEMM_UNIT_FP16_OUT_SCALE = 0;
`endif

    // =========================================================================
    // Type Definitions
    // =========================================================================
    typedef enum logic {
        IDLE,
        COMPUTE
    } gemm_state_t;

    typedef enum logic {
        ACCUM_RD_IDLE,
        ACCUM_RD_READ
    } acc_mem_accum_rd_state_t;

    typedef enum logic {
        ACCUM_WR_IDLE,
        ACCUM_WR_WRITE
    } acc_mem_accum_wr_state_t;

    // =========================================================================
    // Functions
    // =========================================================================
    function automatic [1:0] get_acc_mem_idx(input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr);
        logic group       = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        logic bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] get_acc_mem_bank_addr(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        return {addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1:`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)+1],
                addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)-1:0]};
    endfunction

    // =========================================================================
    // Signal Declarations
    // =========================================================================

    // -------------------------------------------------------------------------
    // Main FSM Signals
    // -------------------------------------------------------------------------
    gemm_state_t                state, next_state;
    gemm_unit_ctrl_t            gemm_unit_ctrl, next_gemm_unit_ctrl;
    logic                       in_flight;
    logic                       is_qcol;
    logic                       gemm_done;
    logic                       gemm_idle;

    // -------------------------------------------------------------------------
    // Scale and Zero Point Registers
    // -------------------------------------------------------------------------
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)-1:0][`SCALE_WIDTH-1:0] scale_regs;
    logic [1:0][`MAX(`MXU_ROW, `MXU_COL)-1:0][`ZP_WIDTH-1:0]    zero_regs;

    // Scale/Zero write control signals
    logic                                            sz_req_valid;
    logic                                            sz_req_rw;
    logic [`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE*4)-1:0] sz_req_addr;
    logic [`GEMM_SCALE_ZERO_DATA_SIZE*8-1:0]         sz_req_data;
    logic                                            scale_reg_wr_en;
    logic                                            scale_reg_idx;
    logic                                            zp_reg_wr_en;
    logic                                            zp_reg_idx;

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
    logic [`IFP_EXP_WIDTH-1:0]                     prealigner_max_exp_q_valid;

    // -------------------------------------------------------------------------
    // Activation Reduce and Zero Point Multiply Signals
    // -------------------------------------------------------------------------
    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] act_reduce_data_in;
    logic [`MXU_ROW-1:0][`BLOCK_IDX_WIDTH-1:0]     act_reduce_blk_idx;
    logic [`MXU_ROW-1:0][`ACT_REDUCE_IN_WIDTH-1:0] act_reduce_data_in_shifted;
    logic                                          act_reduce_valid_in;
    logic signed [`ACT_REDUCE_OUT_WIDTH-1:0]       act_reduce_data_out;
    logic                                          act_reduce_valid_out;

    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_IN_WIDTH-1:0]  zp_mul_in_data;
    logic                                           zp_mul_in_valid;
    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_OUT_WIDTH-1:0] zp_mul_out_data;
    logic [`MXU_MAX_DIM-1:0][`ZP_MUL_OUT_WIDTH-1:0] zp_mul_out_data_q;
    logic                                           zp_mul_out_valid;

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
    logic                                                       mxu_ready_weight;
    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0]                      mxu_output;
    logic [`MXU_COL/`MXU_COL_TILE-1:0]                          mxu_output_valid;
    logic [`MXU_COL-1:0][`O_BIT_WIDTH-1:0]                      mxu_output_dly;
    logic [`MXU_COL/`MXU_COL_TILE-1:0]                          mxu_output_valid_dly;
    logic wreg_wr_idx;
    logic wreg_load_dir;

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
    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0]      acc_mem_in_data;

    // -------------------------------------------------------------------------
    // Accumulator Memory Signals
    // -------------------------------------------------------------------------
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_accum_rd_addr;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_accum_wr_addr;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_out_rd_addr;

    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_accum_rd_bank_addr;
    logic [1:0]                                    acc_mem_accum_rd_bank;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_accum_wr_bank_addr;
    logic [1:0]                                    acc_mem_accum_wr_bank;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_out_rd_bank_addr;
    logic [1:0]                                    acc_mem_out_rd_bank;

    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0]      acc_mem_out_data;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]      acc_mem_wr_addr;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]      acc_mem_rd_addr;
    logic [3:0]                                    acc_mem_wr_en;
    logic [3:0]                                    acc_mem_rd_en;

    // -------------------------------------------------------------------------
    // Accumulator Read FSM Signals
    // -------------------------------------------------------------------------
    acc_mem_accum_rd_state_t                       acc_mem_accum_rd_state, acc_mem_accum_rd_state_next;
    logic                                          acc_mem_accum_rd_req;
    logic                                          acc_mem_accum_rd_cnt, acc_mem_accum_rd_cnt_next;
    logic                                          acc_rd_fifo_push, acc_rd_fifo_pop;
    logic                                          acc_rd_fifo_full, acc_rd_fifo_empty;
    logic                                          acc_mem_rd_data_valid;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           acc_rd_fifo_out_data;

    // -------------------------------------------------------------------------
    // Accumulator Write FSM Signals
    // -------------------------------------------------------------------------
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state, acc_mem_accum_wr_state_next;
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state_q;
    logic                                          acc_mem_accum_wr_req;
    logic [`GEMM_ACC_MAX_CNT-1:0]                  acc_mem_accum_wr_cnt, acc_mem_accum_wr_cnt_next;

    // -------------------------------------------------------------------------
    // FP32 to FP16 Output Signals
    // -------------------------------------------------------------------------
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0]           fp16_out_data;
    logic [`MXU_COL-1:0]                           fp16_out_valid;
    logic                                          acc_mem_rd_out_valid;

    // =========================================================================
    // Interface Signal Assignments
    // =========================================================================
    assign gemm_unit_if.done = gemm_done;
    assign gemm_unit_if.idle = gemm_idle;

    // ------------------------------------------------------------------------
    // input bus
    // ------------------------------------------------------------------------
    assign i_lmem_bus_if.rsp_valid = 1'b0;

    assign mxu_weight              = w_lmem_bus_if.req_data.data;
    assign w_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.wreg_use_idx != w_lmem_bus_if.req_data.addr[0]);
    assign mxu_ready_weight        = w_lmem_bus_if.req_valid & w_lmem_bus_if.req_ready;
    assign wreg_wr_idx             = w_lmem_bus_if.req_data.addr[0];
    assign wreg_load_dir           = w_lmem_bus_if.req_data.addr[1];
    assign w_lmem_bus_if.rsp_valid = 1'b0;

    assign sz_req_valid = sz_lmem_bus_if.req_valid & sz_lmem_bus_if.req_ready;
    assign sz_req_rw    = sz_lmem_bus_if.req_data.rw;
    assign sz_req_addr  = sz_lmem_bus_if.req_data.addr;
    assign sz_req_data  = sz_lmem_bus_if.req_data.data;
    always_comb begin
        if (~in_flight) begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end else if (zp_reg_wr_en) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.zreg_use_idx != zp_reg_idx);
        end else if (scale_reg_wr_en) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.sreg_use_idx != scale_reg_idx);
        end else begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end
    end
    assign sz_lmem_bus_if.rsp_valid = 1'b0;

    assign o_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_wr_bank) |
                                     (~gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_rd_bank && acc_mem_out_rd_bank != acc_mem_accum_wr_bank);
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data.data  = fp16_out_data;
    assign o_lmem_bus_if.rsp_data.tag  = '0;
    assign acc_mem_out_rd_addr = o_lmem_bus_if.req_data.addr;

    // =========================================================================
    // Accumulator Memory Bank Address Calculation
    // =========================================================================
    assign acc_mem_accum_rd_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_rd_addr);
    assign acc_mem_accum_rd_bank      = get_acc_mem_idx(acc_mem_accum_rd_addr);
    assign acc_mem_accum_wr_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_wr_addr);
    assign acc_mem_accum_wr_bank      = get_acc_mem_idx(acc_mem_accum_wr_addr);
    assign acc_mem_out_rd_bank_addr   = get_acc_mem_bank_addr(acc_mem_out_rd_addr);
    assign acc_mem_out_rd_bank        = get_acc_mem_idx(acc_mem_out_rd_addr);

    // =========================================================================
    // Done/Idle Signal Generation
    // =========================================================================
    assign gemm_done = (acc_mem_accum_wr_state_q == ACCUM_WR_WRITE) &&
                       (acc_mem_accum_wr_state == ACCUM_WR_IDLE);
    assign gemm_idle = (state == IDLE) &&
                       (acc_mem_accum_rd_state == ACCUM_RD_IDLE) &&
                       (acc_mem_accum_wr_state == ACCUM_WR_IDLE);

    // =========================================================================
    // Main FSM
    // =========================================================================

    // ----- Sequential Logic -----
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            gemm_unit_ctrl <= '0;
        end else begin
            state          <= next_state;
            gemm_unit_ctrl <= next_gemm_unit_ctrl;
        end
    end

    // ----- Combinational Logic -----
    always_comb begin
        in_flight = (state == COMPUTE);
        is_qcol   = (gemm_unit_ctrl.quant_dir == `QDIR_COL);

        next_state          = state;
        next_gemm_unit_ctrl = gemm_unit_ctrl;

        case (state)
            IDLE: begin
                if (gemm_unit_if.start) begin
                    next_state          = COMPUTE;
                    next_gemm_unit_ctrl = gemm_unit_if.gemm_unit_ctrl;
                end
            end

            COMPUTE: begin
                // Return to IDLE when write FSM completes
                if ((acc_mem_accum_wr_state == ACCUM_WR_WRITE) &&
                    (acc_mem_accum_wr_cnt == 1) && acc_mem_accum_wr_req) begin
                    next_state = IDLE;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // =========================================================================
    // Accumulator Read FSM
    // =========================================================================
    // Read from accumulation memory if ~is_load. We read psum and push it to
    // fifo just after start of FSM, because we need to wait for output from
    // mxu and input delivery speed from outside is hard to predict.
    // When output of mxu is arrived at input side of accum memory, psum should
    // be already read and ready to use. So we read psum first and store it in
    // fifo, then when mxu output is ready, we pop from fifo and do accumulation.

    // ----- Read Data Valid Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_data_valid <= '0;
        end else begin
            if (acc_mem_accum_rd_req) begin
                acc_mem_rd_data_valid <= 1'b1;
            end else if (acc_rd_fifo_push) begin
                acc_mem_rd_data_valid <= 1'b0;
            end
        end
    end

    // ----- Read Address Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_addr <= '0;
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_mem_accum_rd_addr <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr;
            end else if (acc_mem_accum_rd_req) begin
                acc_mem_accum_rd_addr <= acc_mem_accum_rd_addr + (`MXU_COL * (FP32_WIDTH/8));
            end
        end
    end

    // ----- Read FSM Combinational Logic -----
    always_comb begin
        acc_mem_accum_rd_req        = 0;
        acc_rd_fifo_push            = 0;
        acc_mem_accum_rd_state_next = acc_mem_accum_rd_state;
        acc_mem_accum_rd_cnt_next   = acc_mem_accum_rd_cnt;

        case (acc_mem_accum_rd_state)
            ACCUM_RD_IDLE: begin
                if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_READ;
                    acc_mem_accum_rd_cnt_next   = gemm_unit_if.gemm_unit_ctrl.acc_cnt;
                end else begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
                    acc_mem_accum_rd_cnt_next   = -1;
                end
            end

            ACCUM_RD_READ: begin
                if (acc_mem_accum_rd_cnt > 0) begin
                    acc_mem_accum_rd_req = ~acc_mem_rd_data_valid | acc_rd_fifo_push;
                    acc_rd_fifo_push     = acc_mem_rd_data_valid & ~acc_rd_fifo_full;
                    if (acc_rd_fifo_push) begin
                        acc_mem_accum_rd_cnt_next = acc_mem_accum_rd_cnt - 1;
                    end
                end else begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
                end
            end

            default: begin
                acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
            end
        endcase
    end

    // ----- Read FSM Sequential Logic -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_state <= ACCUM_RD_IDLE;
            acc_mem_accum_rd_cnt   <= '0;
        end else begin
            acc_mem_accum_rd_state <= acc_mem_accum_rd_state_next;
            acc_mem_accum_rd_cnt   <= acc_mem_accum_rd_cnt_next;
        end
    end

    // =========================================================================
    // Accumulator Write FSM
    // =========================================================================

    // ----- Write Address Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_addr <= '0;
        end else begin
            if (gemm_unit_if.start) begin
                acc_mem_accum_wr_addr <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr;
            end else if (acc_mem_accum_wr_req) begin
                acc_mem_accum_wr_addr <= acc_mem_accum_wr_addr + (`MXU_COL * (FP32_WIDTH/8));
            end
        end
    end

    // ----- Write FSM Combinational Logic -----
    always_comb begin
        acc_mem_accum_wr_req        = 0;
        acc_mem_accum_wr_state_next = acc_mem_accum_wr_state;
        acc_mem_accum_wr_cnt_next   = acc_mem_accum_wr_cnt;
        acc_rd_fifo_pop             = 0;

        case (acc_mem_accum_wr_state)
            ACCUM_WR_IDLE: begin
                if (gemm_unit_if.start) begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_WRITE;
                    acc_mem_accum_wr_cnt_next   = gemm_unit_if.gemm_unit_ctrl.acc_cnt;
                end else begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
                    acc_mem_accum_wr_cnt_next   = '0;
                end
            end

            ACCUM_WR_WRITE: begin
                if (acc_mem_accum_wr_cnt > 0) begin
                    // Write when accumulator output is valid (for accumulate mode)
                    // or when scaler output is valid (for load mode)
                    if (gemm_unit_ctrl.is_load) begin
                        acc_mem_accum_wr_req = final_scaler_output_valid;
                        if (final_scaler_output_valid) begin
                            acc_mem_accum_wr_cnt_next = acc_mem_accum_wr_cnt - 1;
                        end
                    end else begin
                        acc_mem_accum_wr_req = acc_output_valid[0];
                        acc_rd_fifo_pop      = acc_output_valid[0] & ~acc_rd_fifo_empty;
                        if (acc_output_valid[0]) begin
                            acc_mem_accum_wr_cnt_next = acc_mem_accum_wr_cnt - 1;
                        end
                    end
                end else begin
                    acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
                end
            end

            default: begin
                acc_mem_accum_wr_state_next = ACCUM_WR_IDLE;
            end
        endcase
    end

    // ----- Write FSM Sequential Logic -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_state <= ACCUM_WR_IDLE;
            acc_mem_accum_wr_cnt   <= '0;
        end else begin
            acc_mem_accum_wr_state <= acc_mem_accum_wr_state_next;
            acc_mem_accum_wr_cnt   <= acc_mem_accum_wr_cnt_next;
        end
    end

    // ----- Write State Delayed for Done Detection -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_wr_state_q <= ACCUM_WR_IDLE;
        end else begin
            acc_mem_accum_wr_state_q <= acc_mem_accum_wr_state;
        end
    end

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
        scale_reg_wr_en = 0;
        scale_reg_idx   = 0;
        zp_reg_wr_en    = 0;
        zp_reg_idx      = 0;

        if (sz_req_valid & sz_req_rw) begin
            if (sz_req_addr >= SCALE_REG0_BASE && sz_req_addr < SCALE_REG1_BASE) begin
                scale_reg_wr_en = 1'b1;
                scale_reg_idx   = 1'b0;
            end else if (sz_req_addr >= SCALE_REG1_BASE && sz_req_addr < ZP_REG0_BASE) begin
                scale_reg_wr_en = 1'b1;
                scale_reg_idx   = 1'b1;
            end else if (sz_req_addr >= ZP_REG0_BASE && sz_req_addr < ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
                zp_reg_idx      = 1'b0;
            end else if (sz_req_addr >= ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
                zp_reg_idx      = 1'b1;
            end
        end
    end

    // ----- Write to scale registers -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            scale_regs <= '0;
        end else begin
            if (scale_reg_wr_en) begin
                scale_regs[scale_reg_idx] <= sz_req_data;
            end
        end
    end

    // ----- Write to zero point registers -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            zero_regs <= '0;
        end else begin
            if (zp_reg_wr_en) begin
                for(int i=0; i<`MAX(`MXU_ROW, `MXU_COL); i++) begin
                  zero_regs[zp_reg_idx][i] <= -1*signed'(sz_req_data[i*`ZP_WIDTH +: `ZP_WIDTH]);
                end
            end
        end
    end

    // =========================================================================
    // FP32 to FP16 Output Control
    // =========================================================================
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_out_valid <= 1'b0;
        end else begin
            if (o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready & ~o_lmem_bus_if.req_data.rw) begin
                acc_mem_rd_out_valid <= 1'b1;
            end else if (fp16_out_valid[0] & o_lmem_bus_if.rsp_ready) begin
                acc_mem_rd_out_valid <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Datapath Combinational Logic
    // =========================================================================

    // ----- Prealigner Input Selection -----
    assign prealigner_in_data  = is_qcol ? in_pipe_data_out : in_scaler_result_data;
    assign prealigner_in_valid = is_qcol ? in_pipe_valid_out : in_scaler_result_valid[0];

    // ----- Merger Input Valid -----
    assign merger_in_valid = &mxu_output_valid_dly;

    // ----- Zero Point Multiply -----
    always_comb begin
        for (int i = 0; i < `MXU_MAX_DIM; i++) begin : gen_zp_mul
            zp_mul_out_data[i] = signed'(zp_mul_in_data[i]) * signed'(zero_regs[gemm_unit_ctrl.zreg_use_idx][i]);
        end
    end

    // =========================================================================
    // Sub-module Instantiations
    // =========================================================================

    // -------------------------------------------------------------------------
    // Input Pipeline Buffer
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW(`MXU_ROW * `IFP_WIDTH),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_in_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (i_lmem_bus_if.req_valid),
        .ready_in  (i_lmem_bus_if.req_ready),
        .data_in   (i_lmem_bus_if.req_data.data),
        .data_out  (in_pipe_data_out),
        .ready_out (in_flight),
        .valid_out (in_pipe_valid_out)
    );

    // -------------------------------------------------------------------------
    // Input Scalers
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : gen_in_scaler
            logic activated;
            logic a_valid, b_valid;
            logic [`IFP_WIDTH-1:0] a_data, b_data;

            assign activated = (gemm_unit_ctrl.quant_dir == `QDIR_ROW) & in_flight;
            assign a_valid   = in_pipe_valid_out & activated;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[`IFP_WIDTH*i +: `IFP_WIDTH] : '0;
            assign b_data    = activated ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i] : '0;

            VX_fp16_mul #(
                .LATENCY (2),
                .OUT_BUF (1)
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
    // Pre-processor Routing
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_ROW; i++) begin : gen_pre_proc_route
            assign act_reduce_data_in[i] = is_qcol ? signed'(prealigner_int_data[i]) :
                                                     signed'(zp_mul_out_data_q[i]);
            assign act_reduce_blk_idx[i] = is_qcol ? prealigner_blk_idx[i] :
                                                     prealigner_blk_idx_q[i];
            assign act_reduce_data_in_shifted[i] = act_reduce_data_in[i] <<< (`BLOCK_SIZE * act_reduce_blk_idx[i]);
            if(i == 0) begin
              assign act_reduce_valid_in = is_qcol ? prealigner_out_valid : zp_mul_out_valid; // only need to assign once
            end
            assign zp_mul_in_data[i] = is_qcol ? signed'(act_reduce_data_out) :
                                                 signed'(prealigner_int_data[i]);
            if(i == 0) begin
              assign zp_mul_in_valid = is_qcol ? act_reduce_valid_out : prealigner_out_valid;
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Activation Reduce Tree
    // -------------------------------------------------------------------------
    VX_reduce_tree_pipelined_v2 #(
        .IN_W            (`ACT_REDUCE_IN_WIDTH),
        .OUT_W           (`ACT_REDUCE_OUT_WIDTH),
        .N               (`MXU_ROW),
        .OP              ("+"),
        .PIPELINE_STAGES (ACT_REDUCE_PIPE_STAGES)
    ) u_act_reduce (
        .clk       (clk),
        .reset     (reset),
        .data_in   (act_reduce_data_in_shifted),
        .valid_in  (act_reduce_valid_in),
        .data_out  (act_reduce_data_out),
        .valid_out (act_reduce_valid_out)
    );

    // -------------------------------------------------------------------------
    // Zero Point Multiply Output Register
    // -------------------------------------------------------------------------
    VX_pipe_buffer #(
        .DATAW(`MXU_MAX_DIM * `ZP_MUL_OUT_WIDTH),
        .DEPTH(DEFAULT_OUT_DLY)
    ) u_zp_mul_out_reg (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (zp_mul_in_valid),
        .ready_in  (),
        .data_in   (zp_mul_out_data),
        .data_out  (zp_mul_out_data_q),
        .ready_out (1'b1),
        .valid_out (zp_mul_out_valid)
    );

    // -------------------------------------------------------------------------
    // Pre-processor Output
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_pre_proc_out
            assign pre_proc_out[i]    = is_qcol ? signed'(zp_mul_out_data_q[i]) : act_reduce_data_out;
            if(i == 0) begin
              assign pre_proc_in_valid  = is_qcol ? zp_mul_out_valid : act_reduce_valid_out;
            end
        end
    endgenerate

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
        .out_weight_sel_i (gemm_unit_ctrl.wreg_use_idx),
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
            assign merger_out_data[i] = signed'(mxu_output_dly[i]) + signed'(pre_proc_out_q[i]);
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
            logic a_valid, b_valid;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            logic [FP16_WIDTH-1:0] a_data, b_data;
`else
            logic [FP32_WIDTH-1:0] a_data, b_data;
            logic [FP16_EXP_WIDTH-1:0] exp;
`endif

            assign a_valid = int2fp_output_valid[i] & is_qcol;
            assign b_valid = int2fp_output_valid[i] & is_qcol;
            assign a_data  = (int2fp_output_valid[i] & is_qcol) ? int2fp_out_data[i] : '0;

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            assign b_data  = (int2fp_output_valid[i] & is_qcol) ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i] : '0;
`else
            assign b_data[31]  = (int2fp_output_valid[i] & is_qcol) ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i][15] : '0;
            assign exp = scale_regs[gemm_unit_ctrl.sreg_use_idx][i][14:10];
            assign b_data[30:23] = (int2fp_output_valid[i] & is_qcol) ? (&exp==1'b1 ? '1 : exp + (FP32_EXP_BIAS - FP16_EXP_BIAS)) : '0;
            assign b_data[22:0]  = (int2fp_output_valid[i] & is_qcol) ? {scale_regs[gemm_unit_ctrl.sreg_use_idx][i][9:0], 13'b0} : '0;
`endif

`ifdef GEMM_UNIT_FP16_OUT_SCALE
            VX_fp16_mul #(
                .LATENCY (0),
                .OUT_BUF (1)
            ) u_out_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (),
                .b_data       (b_data),
                .result_valid (scaler_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (scaled_fp_out_data[i])
            );
        end
`else
            VX_fp32_mul #(
                .LATENCY (0),
                .OUT_BUF (1)
            ) u_out_scaler (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (),
                .b_data       (b_data),
                .result_valid (scaler_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (scaled_fp_out_data[i])
            );
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
        .valid_in  (int2fp_output_valid[0] & ~is_qcol),
        .ready_in  (),
        .data_in   (int2fp_out_data),
        .data_out  (scaler_bypass_data),
        .ready_out (1'b1),
        .valid_out (scaler_bypass_valid)
    );

    // Mux between scaled output (QCOL) and bypassed output (QROW)
    assign final_scaled_fp_out_data  = is_qcol ? scaled_fp_out_data : scaler_bypass_data;
    assign final_scaler_output_valid = is_qcol ? scaler_output_valid[0] : scaler_bypass_valid;
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
    // Accumulators
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_accumulator
            logic a_valid, b_valid;
            logic [FP32_WIDTH-1:0] a_data;

            assign a_valid = final_scaler_output_valid & ~gemm_unit_ctrl.is_load;
            assign b_valid = a_valid;
            assign a_data  = final_scaler_output_valid ? scaled_fp32_out_data[i] : '0;

            VX_fp32_add #(
                .LATENCY (1),
                .OUT_BUF (1)
            ) u_accumulator (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (a_valid),
                .a_ready      (),
                .a_data       (a_data),
                .b_valid      (b_valid),
                .b_ready      (),
                .b_data       (acc_mem_out_data[acc_mem_accum_rd_bank][i]),
                .result_valid (acc_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (acc_output_data[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Accumulator Read FIFO
    // -------------------------------------------------------------------------
    VX_fifo_v2 #(
        .FALL_THROUGH (1),
        .DATA_WIDTH   (`MXU_COL * FP32_WIDTH),
        .DEPTH        (2)
    ) u_acc_rd_fifo (
        .clk_i       (clk),
        .rst_ni      (~reset),
        .flush_i     (1'b0),
        .testmode_i  (1'b0),
        .full_o      (acc_rd_fifo_full),
        .empty_o     (acc_rd_fifo_empty),
        .alm_full_o  (),
        .alm_empty_o (),
        .data_i      (acc_mem_out_data[acc_mem_accum_rd_bank]),
        .push_i      (acc_rd_fifo_push),
        .data_o      (acc_rd_fifo_out_data),
        .pop_i       (acc_rd_fifo_pop)
    );

    // -------------------------------------------------------------------------
    // Accumulator Memory Banks
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_acc_mem
            logic this_bank_accum_rd; 
            logic this_bank_out_rd; 
            logic this_bank_accum_wr; 

            assign this_bank_accum_rd = (~gemm_unit_ctrl.is_load && acc_mem_accum_rd_bank == i);
            assign this_bank_out_rd   = (acc_mem_out_rd_bank == i);
            assign this_bank_accum_wr = (acc_mem_accum_wr_bank == i);

            assign acc_mem_wr_en[i] = this_bank_accum_wr && (gemm_unit_ctrl.is_load ? final_scaler_output_valid : acc_output_valid[0]);
            assign acc_mem_rd_en[i] = this_bank_accum_rd ? acc_mem_accum_rd_req :
                                      this_bank_out_rd   ? (o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready) : 1'b0;
            assign acc_mem_wr_addr[i] = acc_mem_accum_wr_bank_addr;
            assign acc_mem_rd_addr[i] = this_bank_accum_rd ? acc_mem_accum_rd_bank_addr :
                                        this_bank_out_rd   ? acc_mem_out_rd_bank_addr : '0;
            assign acc_mem_in_data[i] = this_bank_accum_wr ? (gemm_unit_ctrl.is_load ? scaled_fp32_out_data : acc_output_data) : '0;

            VX_sp_ram #(
                .DATAW (`MXU_COL * FP32_WIDTH),
                .SIZE  (`GEMM_ACC_MEM_DEPTH * `MXU_COL * (FP32_WIDTH/8))
            ) VX_sp_ram_instance (
                .clk   (clk),
                .reset (reset),
                .read  (acc_mem_rd_en[i]),
                .write (acc_mem_wr_en[i]),
                .wren  (1'b1),
                .addr  (acc_mem_wr_en[i] ? acc_mem_wr_addr[i] : acc_mem_rd_addr[i]),
                .wdata (acc_mem_in_data[i]),
                .rdata (acc_mem_out_data[i])
            );
        end
    endgenerate

`ifdef SIMULATION
    task initialize_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr,
        input int size,
        input logic [`MXU_COL-1:0][FP32_WIDTH-1:0] init_value = '0
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [1:0] bank_idx;

        for (int i = 0; i < size; i++) begin
            automatic logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr;
            addr = base_addr + i * (`MXU_COL * (FP32_WIDTH/8));
            bank_idx  = get_acc_mem_idx(addr);
            bank_addr = get_acc_mem_bank_addr(addr);

            case (bank_idx)
                2'd0: gen_acc_mem[0].VX_sp_ram_instance.ram[bank_addr] = init_value;
                2'd1: gen_acc_mem[1].VX_sp_ram_instance.ram[bank_addr] = init_value;
                2'd2: gen_acc_mem[2].VX_sp_ram_instance.ram[bank_addr] = init_value;
                2'd3: gen_acc_mem[3].VX_sp_ram_instance.ram[bank_addr] = init_value;
            endcase
        end
    endtask

    task read_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        output logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [1:0] bank_idx;

        bank_idx  = get_acc_mem_idx(addr);
        bank_addr = get_acc_mem_bank_addr(addr);

        case (bank_idx)
            2'd0: data = gen_acc_mem[0].VX_sp_ram_instance.ram[bank_addr];
            2'd1: data = gen_acc_mem[1].VX_sp_ram_instance.ram[bank_addr];
            2'd2: data = gen_acc_mem[2].VX_sp_ram_instance.ram[bank_addr];
            2'd3: data = gen_acc_mem[3].VX_sp_ram_instance.ram[bank_addr];
        endcase
    endtask

    task write_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        input logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [1:0] bank_idx;

        bank_idx  = get_acc_mem_idx(addr);
        bank_addr = get_acc_mem_bank_addr(addr);

        case (bank_idx)
            2'd0: gen_acc_mem[0].VX_sp_ram_instance.ram[bank_addr] = data;
            2'd1: gen_acc_mem[1].VX_sp_ram_instance.ram[bank_addr] = data;
            2'd2: gen_acc_mem[2].VX_sp_ram_instance.ram[bank_addr] = data;
            2'd3: gen_acc_mem[3].VX_sp_ram_instance.ram[bank_addr] = data;
        endcase
    endtask
`endif

    // -------------------------------------------------------------------------
    // FP32 to FP16 Converters
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_fp32_to_fp16
            VX_f32_to_f16 u_f32_to_f16 (
                .clk_i    (clk),
                .resetn_i (~reset),
                .data_i   (acc_mem_out_data[acc_mem_out_rd_bank][i]),
                .valid_i  (acc_mem_rd_out_valid),
                .data_o   (fp16_out_data[i]),
                .valid_o  (fp16_out_valid[i])
            );
        end
    endgenerate

    // =========================================================================
    // Debug Tracing
    // =========================================================================
`ifdef DBG_TRACE_GEMM
    // FSM state names for debug
    function automatic string state_to_str(input gemm_state_t s);
        case (s)
            IDLE:    return "IDLE";
            COMPUTE: return "COMPUTE";
            default: return "UNKNOWN";
        endcase
    endfunction

    always @(posedge clk) begin
        if (~reset) begin
            // FSM state transition
            if (state != next_state) begin
                `TRACE(2, ("%t: %s: FSM state: %s -> %s\n", $time, INSTANCE_ID, state_to_str(state), state_to_str(next_state)))
            end

            // GEMM start event
            if (gemm_unit_if.start) begin
                `TRACE(1, ("%t: %s: GEMM START - is_load=%b, quant_dir=%b, acc_cnt=%0d, acc_base=0x%0h, wreg=%0d, sreg=%0d, zreg=%0d\n",
                    $time, INSTANCE_ID,
                    gemm_unit_if.gemm_unit_ctrl.is_load,
                    gemm_unit_if.gemm_unit_ctrl.quant_dir,
                    gemm_unit_if.gemm_unit_ctrl.acc_cnt,
                    gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr,
                    gemm_unit_if.gemm_unit_ctrl.wreg_use_idx,
                    gemm_unit_if.gemm_unit_ctrl.sreg_use_idx,
                    gemm_unit_if.gemm_unit_ctrl.zreg_use_idx))
            end

            // GEMM done event
            if (gemm_done) begin
                `TRACE(1, ("%t: %s: GEMM DONE\n", $time, INSTANCE_ID))
            end

            // Weight loading
            if (mxu_ready_weight) begin
                `TRACE(2, ("%t: %s: Weight load - wr_idx=%0d, load_dir=%0d\n",
                    $time, INSTANCE_ID, wreg_wr_idx, wreg_load_dir))
            end

            // Scale/Zero register writes
            if (scale_reg_wr_en) begin
                `TRACE(3, ("%t: %s: Scale reg[%0d] write: %s\n",
                    $time, INSTANCE_ID, scale_reg_idx, parseWordNoNormal(sz_req_data, `MAX(`MXU_ROW, `MXU_COL) * `SCALE_WIDTH, `SCALE_WIDTH, "fp")))
            end
            if (zp_reg_wr_en) begin
                `TRACE(3, ("%t: %s: ZP reg[%0d] write: %s\n",
                    $time, INSTANCE_ID, zp_reg_idx, parseWordNoNormal(sz_req_data, `MAX(`MXU_ROW, `MXU_COL) * `ZP_WIDTH, `ZP_WIDTH, "int")))
            end

            // Input data arrival
            if (in_pipe_valid_out & in_flight) begin
                `TRACE(3, ("%t: %s: Input valid - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(in_pipe_data_out, `MXU_ROW * `IFP_WIDTH, `IFP_WIDTH, "fp")))
            end

            if (in_scaler_result_valid) begin
                `TRACE(3, ("%t: %s: Input scaler result - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(in_scaler_result_data, `MXU_ROW * `IFP_WIDTH, `IFP_WIDTH, "fp")))
            end

            // Prealigner output
            if (prealigner_out_valid) begin
                `TRACE(3, ("%t: %s: Prealigner out - max_exp=0x%0h\n",
                    $time, INSTANCE_ID, prealigner_max_exp))
                `TRACE(3, ("%t: %s:   int_data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(prealigner_int_data, `MXU_ROW * `SEL_BLOCK_WIDTH, `SEL_BLOCK_WIDTH, "uint")))
                `TRACE(3, ("%t: %s:   blk_idx=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(prealigner_blk_idx, `MXU_ROW * `BLOCK_IDX_WIDTH, `BLOCK_IDX_WIDTH, "uint")))
            end

            if (act_reduce_valid_out) begin
                `TRACE(3, ("%t: %s: Act Reduce out - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(act_reduce_data_out, `ACT_REDUCE_OUT_WIDTH, `ACT_REDUCE_OUT_WIDTH, "int")));
            end

            if (zp_mul_out_valid) begin
                `TRACE(3, ("%t: %s: ZP Mul out - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(zp_mul_out_data_q, `MXU_COL * `ZP_MUL_OUT_WIDTH, `ZP_MUL_OUT_WIDTH, "int")));
            end

            if (pre_proc_out_valid) begin
                `TRACE(2, ("%t: %s: Pre-processor out - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(pre_proc_out_q, `MXU_COL * `PRE_PROC_OUT_DW, `PRE_PROC_OUT_DW, "int")))
            end

            // MXU output valid
            if (merger_in_valid) begin
                `TRACE(2, ("%t: %s: MXU output valid - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(mxu_output_dly, `MXU_ROW * `O_BIT_WIDTH, `O_BIT_WIDTH, "int")))
            end

            // Merger output
            if (merger_out_valid) begin
                `TRACE(3, ("%t: %s: Merger out - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(merger_out_data_q, `MXU_ROW * `MERGE_OUT_BW, `MERGE_OUT_BW, "int")))
            end

            // Int2FP output
`ifdef GEMM_UNIT_FP16_OUT_SCALE
            if (int2fp_output_valid[0]) begin
                `TRACE(3, ("%t: %s: Int2FP out - fp16=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(int2fp_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end

            // Scaler output (or bypass for QROW)
            if (final_scaler_output_valid) begin
                `TRACE(3, ("%t: %s: Scaler out (bypass=%b) - fp16=%s\n",
                    $time, INSTANCE_ID, ~is_qcol, parseWordNoNormal(final_scaled_fp_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end
`else
            if (int2fp_output_valid[0]) begin
                `TRACE(3, ("%t: %s: Int2FP out - fp32=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(int2fp_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // Scaler output (or bypass for QROW)
            if (final_scaler_output_valid) begin
                `TRACE(3, ("%t: %s: Scaler out (bypass=%b) - fp32=%s\n",
                    $time, INSTANCE_ID, ~is_qcol, parseWordNoNormal(final_scaled_fp_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end
`endif

            // Accumulator write
            if (acc_mem_accum_wr_req) begin
                `TRACE(2, ("%t: %s: Acc mem write accum - addr=0x%0h, bank=%0d, is_load=%b, cnt=%0d, data=%s\n",
                    $time, INSTANCE_ID, acc_mem_accum_wr_addr, acc_mem_accum_wr_bank,
                    gemm_unit_ctrl.is_load, acc_mem_accum_wr_cnt, parseWordNoNormal(acc_mem_in_data[acc_mem_accum_wr_bank], `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // Accumulator read
            if (acc_mem_accum_rd_req) begin
                `TRACE(3, ("%t: %s: Acc mem read accum - addr=0x%0h, bank=%0d, cnt=%0d\n",
                    $time, INSTANCE_ID, acc_mem_accum_rd_addr, acc_mem_accum_rd_bank, acc_mem_accum_rd_cnt))
            end

            // Accumulation mem read data
            if (acc_mem_rd_out_valid) begin
                `TRACE(2, ("%t: %s: Acc mem read out - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(acc_rd_fifo_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // FP16 output valid
            if (fp16_out_valid[0]) begin
                `TRACE(2, ("%t: %s: FP16 output - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(fp16_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end

            // o_lmem_bus
            if (o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready & ~o_lmem_bus_if.req_data.rw) begin
                `TRACE(1, ("%t: %s: Acc Mem OUT Read Request - addr=0x%0h, bank=%0d\n",
                    $time, INSTANCE_ID, o_lmem_bus_if.req_data.addr, acc_mem_out_rd_bank))
            end
            if (o_lmem_bus_if.rsp_valid & o_lmem_bus_if.rsp_ready) begin
                `TRACE(2, ("%t: %s: Acc Mem OUT Read Response - data=%s\n",
                    $time, INSTANCE_ID, parseWordNoNormal(o_lmem_bus_if.rsp_data.data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end
        end
    end

    always @(posedge clk) begin
      if(pre_proc_out_valid ^ mxu_output_valid_dly[`MXU_COL/`MXU_COL_TILE-1]) begin
        `ERROR(("%t: %s: ERROR - Pre-processor output valid and MXU output valid are not aligned! pre_proc_out_valid=%b, mxu_output_valid_dly=%b\n",
            $time, INSTANCE_ID, pre_proc_out_valid, mxu_output_valid_dly[`MXU_COL/`MXU_COL_TILE-1]));
      end

      if(merger_out_valid ^ prealigner_max_exp_q_valid) begin
        `ERROR(("%t: %s: ERROR - Merger output valid and Prealigner max exp valid are not aligned! merger_out_valid=%b, prealigner_max_exp_q_valid=%b\n",
            $time, INSTANCE_ID, merger_out_valid, prealigner_max_exp_q_valid));
      end
    end
`endif

endmodule

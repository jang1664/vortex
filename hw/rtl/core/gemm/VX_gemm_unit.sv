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
`ifdef ENABLE_HW_DEBUG_GEMM
    ,output gemm_unit_debug_t debug
`endif
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t perf
`endif
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
    localparam BLK_IDX_DLY = DEFAULT_OUT_DLY;
    localparam MXU_OUT_DLY = (`MXU_PIPE_MUL_EN + `MXU_PIPE_ALIGN_EN + 1) + get_pipe_stage_num(`MXU_ROW, `MXU_PIPE_ADD_INTV) + ((`MXU_COL / `MXU_COL_TILE) - 1);
    localparam MAX_EXP_IN_DELAY = MXU_OUT_DLY + DEFAULT_OUT_DLY;
    `VX_STATIC_ASSERT(MXU_OUT_DLY >= ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY, ("MXU_OUT_DLY must be >= ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY"));
    localparam PRE_PROC_OUT_DLY = MXU_OUT_DLY - (ACT_REDUCE_OUT_DLY + DEFAULT_OUT_DLY);
    localparam INTTOFP_OUT_DLY = 2;
    // FPNEW/DPI wrapper latency parameters are set so the effective latency
    // matches the generated Xilinx IP latency, accounting for the wrapper's
    // input and output buffers.
    // Xilinx latency-1 IP uses C_Latency=1. The wrappers model this with one
    // input buffer cycle and no output buffer cycle in FPNEW/DPI simulation.
    localparam FP16_MUL_LATENCY = 0;
    localparam FP32_MUL_LATENCY = 0;
    localparam FP32_ADD_LATENCY = 0;
    localparam int ACC_RD_FIFO_DEPTH = 4;
    localparam int ACC_RD_CREDIT_MAX = ACC_RD_FIFO_DEPTH;
    localparam int ACC_RD_CREDIT_W = `CLOG2(ACC_RD_CREDIT_MAX + 1);
    localparam int ACC_RD_ADDR_STEP = 2 * `GEMM_PSUM_DATA_SIZE;

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

    function automatic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] get_acc_mem_bank_depth_addr (
        input logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] addr
    );
        return addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:`CLOG2(`GEMM_PSUM_DATA_SIZE)];
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
    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0]      acc_mem_in_data;
    logic [`MXU_COL-1:0]                           acc_in_data_valid;
    logic [`MXU_COL-1:0]                           acc_psum_data_valid;

    // -------------------------------------------------------------------------
    // Accumulator fifo
    // -------------------------------------------------------------------------
    logic [1:0][`MXU_COL-1:0][FP32_WIDTH-1:0]      acc_rd_fifo_in_data_by_bank;

    // -------------------------------------------------------------------------
    // Accumulator Memory Signals
    // -------------------------------------------------------------------------
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_accum_rd_addr;
    logic [1:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]      acc_mem_accum_rd_addr_by_bank;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_accum_wr_addr;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_out_rd_addr;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]           acc_mem_out_rd_addr_q;

    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_accum_rd_bank_addr;
    logic [1:0]                                    acc_mem_accum_rd_bank;
    logic [1:0]                                    acc_mem_accum_rd_bank_q;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_accum_wr_bank_addr;
    logic [1:0]                                    acc_mem_accum_wr_bank;
    logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]      acc_mem_out_rd_bank_addr;
    logic [1:0]                                    acc_mem_out_rd_bank;
    logic [1:0]                                    acc_mem_out_rd_bank_q;
    logic [$bits(o_lmem_bus_if.req_data.tag)-1:0]  acc_mem_out_rd_tag_q;

    logic [3:0][`MXU_COL-1:0][FP32_WIDTH-1:0]            acc_mem_out_data;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]            acc_mem_wr_addr;
    logic [3:0][`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] acc_mem_rd_depth_addr;
    logic [3:0][`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] acc_mem_wr_depth_addr;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]            acc_mem_rd_addr;
    logic [3:0]                                          acc_mem_wr_en;
    logic [3:0]                                          acc_mem_rd_en;

    // -------------------------------------------------------------------------
    // Accumulator Read FSM Signals
    // -------------------------------------------------------------------------
    acc_mem_accum_rd_state_t                       acc_mem_accum_rd_state, acc_mem_accum_rd_state_next;
    logic                                          acc_mem_accum_rd_req;
    logic                                          acc_mem_accum_rd_accept;
    logic [`GEMM_ACC_MAX_CNT-1:0]                  acc_mem_accum_rd_cnt;
    logic [1:0][`GEMM_ACC_MAX_CNT-1:0]             acc_mem_accum_rd_cnt_by_bank;
    logic [1:0][`GEMM_ACC_MAX_CNT-1:0]             acc_mem_accum_rd_cnt_by_bank_next;
    logic                                          acc_rd_fifo_push, acc_rd_fifo_pop;
    logic                                          acc_rd_fifo_full, acc_rd_fifo_empty, acc_rd_fifo_alm_full;
    logic [1:0]                                    acc_rd_fifo_push_by_bank, acc_rd_fifo_pop_by_bank;
    logic [1:0]                                    acc_rd_fifo_pop_fire_by_bank;
    logic [1:0]                                    acc_rd_fifo_full_by_bank, acc_rd_fifo_empty_by_bank;
    logic [1:0]                                    acc_rd_fifo_alm_full_by_bank;
    logic                                          acc_mem_rd_data_valid;
    logic                                          acc_mem_rd_data_take;
    logic                                          acc_rd_fifo_pop_fire;
    logic                                          acc_mem_rd_rsp_can_push;
    logic [1:0][ACC_RD_CREDIT_W-1:0]               acc_rd_credit_count_by_bank;
    logic [ACC_RD_CREDIT_W:0]                      acc_rd_credit_count;
    logic [`MXU_COL-1:0][FP32_WIDTH-1:0]           acc_rd_fifo_out_data;
    logic [1:0][`MXU_COL-1:0][FP32_WIDTH-1:0]      acc_rd_fifo_out_data_by_bank;
    logic                                          acc_mem_accum_rd_group;
    logic                                          acc_mem_accum_rd_sel;
    logic                                          acc_mem_accum_rd_rr;
    logic                                          acc_rd_consume_bank;
    logic [1:0]                                    acc_mem_accum_rd_eligible;
    logic [1:0]                                    acc_mem_accum_start_bank;

    // -------------------------------------------------------------------------
    // Accumulator Write FSM Signals
    // -------------------------------------------------------------------------
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state, acc_mem_accum_wr_state_next;
    acc_mem_accum_wr_state_t                       acc_mem_accum_wr_state_q;
    logic                                          acc_mem_accum_wr_req;
    logic                                          acc_mem_accum_wr_fire;
    logic [`GEMM_ACC_MAX_CNT-1:0]                  acc_mem_accum_wr_cnt, acc_mem_accum_wr_cnt_next;
    logic                                          psum_underflow_event;
    logic                                          rd_wr_conflict_event;

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

`ifdef WLOAD_AT_ONCE
    // ====================================================================
    // MXU weight write register slice (timing fix, WLOAD_AT_ONCE only).
    //
    // With WLOAD_AT_ONCE the weight broadcast is 4096 bits wide
    // (u_ldma_weight slot mux -> req_data.data -> u_weight_regs.mem[row][col])
    // driving a 32x32x2x4 FF array spread across SLR1; post-route showed
    // 97% route delay on this path (logic 0.27ns / route 10.55ns ->
    // -1.13ns WNS at 100 MHz). One pipeline stage on the consumer side
    // lets the placer co-locate the registered driver with the destination
    // FFs.
    //
    // {data, addr[1], addr[0]} are bundled and delayed together so that
    // weight_i, weight_load_dir_i, in_weight_sel_i, and the implied write
    // enable stay aligned at the u_weight_regs clock edge. out_weight_sel_i
    // (read-side) is NOT delayed. The hazard interlock that prevents
    // writing the buffer currently being read now compares against the
    // BUFFERED wreg_wr_idx, so the actual write cycle still cannot collide.
    //
    // Without WLOAD_AT_ONCE the bus is only 512 bits (MXU_WLOAD_NUM=4) and
    // this extra stage is unnecessary, so we keep the original direct path.
    // ====================================================================
    wire mxu_w_pipe_valid_out;
    wire mxu_w_pipe_ready_out =
        ~in_flight | (gemm_unit_ctrl.wreg_use_idx != wreg_wr_idx);

    VX_pipe_buffer #(
        .DATAW (`MXU_WLOAD_NUM * `MXU_COL * `W_BIT_WIDTH + 2),
        .DEPTH (1)
    ) u_mxu_weight_pipe (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (w_lmem_bus_if.req_valid),
        .ready_in  (w_lmem_bus_if.req_ready),
        .data_in   ({w_lmem_bus_if.req_data.data, w_lmem_bus_if.req_data.addr[1:0]}),
        .ready_out (mxu_w_pipe_ready_out),
        .data_out  ({mxu_weight, wreg_load_dir, wreg_wr_idx}),
        .valid_out (mxu_w_pipe_valid_out)
    );

    assign mxu_ready_weight = mxu_w_pipe_valid_out & mxu_w_pipe_ready_out;
`else
    assign mxu_weight              = w_lmem_bus_if.req_data.data;
    assign w_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.wreg_use_idx != w_lmem_bus_if.req_data.addr[0]);
    assign mxu_ready_weight        = w_lmem_bus_if.req_valid & w_lmem_bus_if.req_ready;
    assign wreg_wr_idx             = w_lmem_bus_if.req_data.addr[0];
    assign wreg_load_dir           = w_lmem_bus_if.req_data.addr[1];
`endif
    assign w_lmem_bus_if.rsp_valid = 1'b0;

    assign sz_req_hs    = sz_lmem_bus_if.req_valid & sz_lmem_bus_if.req_ready;
    assign sz_req_rw    = sz_lmem_bus_if.req_data.rw;
    assign sz_req_addr  = sz_lmem_bus_if.req_data.addr;
    assign sz_req_data  = sz_lmem_bus_if.req_data.data;
    always_comb begin
        if (~in_flight) begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end else if (zp_reg_wr_req) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.zreg_use_idx != zp_reg_idx);
        end else if (scale_reg_wr_req) begin
            sz_lmem_bus_if.req_ready = (gemm_unit_ctrl.sreg_use_idx != scale_reg_idx);
        end else begin
            sz_lmem_bus_if.req_ready = 1'b1;
        end
    end
    assign sz_lmem_bus_if.rsp_valid = 1'b0;

    assign o_lmem_bus_if.req_ready = ~in_flight | (gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_wr_bank) |
                                     (~gemm_unit_ctrl.is_load && acc_mem_out_rd_bank != acc_mem_accum_rd_bank && acc_mem_out_rd_bank != acc_mem_accum_wr_bank);
    wire out_mem_rd_req_fire = o_lmem_bus_if.req_valid & o_lmem_bus_if.req_ready & ~o_lmem_bus_if.req_data.rw;
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data.data  = fp16_out_data;
    assign o_lmem_bus_if.rsp_data.tag  = acc_mem_out_rd_tag_q;
`ifdef GEMM_NAIVE
    assign acc_mem_out_rd_addr = o_lmem_bus_if.req_data.addr << `CLOG2(`GEMM_OUTPUT_DATA_SIZE);
`else
    assign acc_mem_out_rd_addr = o_lmem_bus_if.req_data.addr << `CLOG2(`GEMM_PSUM_DATA_SIZE);
`endif

    // =========================================================================
    // Accumulator Memory Bank Address Calculation
    // =========================================================================
    assign acc_mem_accum_rd_addr      = acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel];
    assign acc_mem_accum_rd_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_rd_addr);
    assign acc_mem_accum_rd_bank      = {acc_mem_accum_rd_group, acc_mem_accum_rd_sel};
    assign acc_mem_accum_wr_bank_addr = get_acc_mem_bank_addr(acc_mem_accum_wr_addr);
    assign acc_mem_accum_wr_bank      = get_acc_mem_idx(acc_mem_accum_wr_addr);
    assign acc_mem_out_rd_bank_addr   = get_acc_mem_bank_addr(acc_mem_out_rd_addr);
    assign acc_mem_out_rd_bank        = get_acc_mem_idx(acc_mem_out_rd_addr);
    assign acc_mem_accum_wr_fire      = acc_mem_accum_wr_req && in_flight
                                      && (gemm_unit_ctrl.is_load ? final_scaler_output_valid : acc_output_valid[0]);
    assign acc_mem_accum_rd_accept    = acc_mem_accum_rd_req && in_flight && ~gemm_unit_ctrl.is_load;
    assign psum_underflow_event       = ~gemm_unit_ctrl.is_load && final_scaler_output_valid && acc_rd_fifo_empty && in_flight;
    assign rd_wr_conflict_event       = acc_mem_accum_rd_req && in_flight && ~gemm_unit_ctrl.is_load
                                      && acc_mem_accum_wr_fire && (acc_mem_accum_rd_bank == acc_mem_accum_wr_bank);

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

    assign acc_mem_accum_start_bank = get_acc_mem_idx(gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr);
    assign acc_mem_accum_rd_cnt = acc_mem_accum_rd_cnt_by_bank[0] + acc_mem_accum_rd_cnt_by_bank[1];
    assign acc_rd_credit_count = acc_rd_credit_count_by_bank[0] + acc_rd_credit_count_by_bank[1];

    assign acc_rd_fifo_pop_by_bank[0] = acc_rd_fifo_pop && (acc_rd_consume_bank == 1'b0);
    assign acc_rd_fifo_pop_by_bank[1] = acc_rd_fifo_pop && (acc_rd_consume_bank == 1'b1);
    assign acc_rd_fifo_pop_fire_by_bank = acc_rd_fifo_pop_by_bank & ~acc_rd_fifo_empty_by_bank;
    assign acc_rd_fifo_pop_fire = |acc_rd_fifo_pop_fire_by_bank;

    assign acc_rd_fifo_empty = acc_rd_fifo_empty_by_bank[acc_rd_consume_bank];
    assign acc_rd_fifo_full = &acc_rd_fifo_full_by_bank;
    assign acc_rd_fifo_alm_full = &acc_rd_fifo_alm_full_by_bank;
    assign acc_rd_fifo_out_data = acc_rd_fifo_out_data_by_bank[acc_rd_consume_bank];

    always_comb begin
        acc_mem_rd_rsp_can_push = 1'b1;
        if (acc_mem_rd_data_valid) begin
            acc_mem_rd_rsp_can_push = ~acc_rd_fifo_full_by_bank[acc_mem_accum_rd_bank_q[0]]
                                    || acc_rd_fifo_pop_fire_by_bank[acc_mem_accum_rd_bank_q[0]];
        end
    end

    assign acc_mem_rd_data_take = acc_mem_rd_data_valid && acc_mem_rd_rsp_can_push;
    assign acc_rd_fifo_push_by_bank[0] = acc_mem_rd_data_take && (acc_mem_accum_rd_bank_q[0] == 1'b0);
    assign acc_rd_fifo_push_by_bank[1] = acc_mem_rd_data_take && (acc_mem_accum_rd_bank_q[0] == 1'b1);
    assign acc_rd_fifo_push = |acc_rd_fifo_push_by_bank;
    assign acc_rd_fifo_in_data_by_bank[0] = acc_mem_out_data[{acc_mem_accum_rd_bank_q[1], 1'b0}];
    assign acc_rd_fifo_in_data_by_bank[1] = acc_mem_out_data[{acc_mem_accum_rd_bank_q[1], 1'b1}];

    assign acc_mem_accum_rd_eligible[0] = (acc_mem_accum_rd_cnt_by_bank[0] != '0)
                                        && ((acc_rd_credit_count_by_bank[0] != '0)
                                         || acc_rd_fifo_pop_fire_by_bank[0]);
    assign acc_mem_accum_rd_eligible[1] = (acc_mem_accum_rd_cnt_by_bank[1] != '0)
                                        && ((acc_rd_credit_count_by_bank[1] != '0)
                                         || acc_rd_fifo_pop_fire_by_bank[1]);

    // ----- Read Data Valid Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_data_valid <= '0;
        end else begin
            if (gemm_unit_if.start) begin
                acc_mem_rd_data_valid <= 1'b0;
            end else if (acc_mem_accum_rd_accept) begin
                acc_mem_rd_data_valid <= 1'b1;
            end else if (acc_mem_rd_data_take) begin
                acc_mem_rd_data_valid <= 1'b0;
            end
        end
    end

    // ----- Read Credit Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_rd_credit_count_by_bank <= '{default: ACC_RD_CREDIT_W'(ACC_RD_CREDIT_MAX)};
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_rd_credit_count_by_bank <= '{default: ACC_RD_CREDIT_W'(ACC_RD_CREDIT_MAX)};
            end else begin
                for (int i = 0; i < 2; ++i) begin
                    case ({acc_mem_accum_rd_accept && (acc_mem_accum_rd_sel == i),
                           acc_rd_fifo_pop_fire_by_bank[i]})
                        2'b10: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i] - ACC_RD_CREDIT_W'(1);
                        2'b01: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i] + ACC_RD_CREDIT_W'(1);
                        default: acc_rd_credit_count_by_bank[i] <= acc_rd_credit_count_by_bank[i];
                    endcase
                end
            end
        end
    end

    // ----- Read Address Tracking -----
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_addr_by_bank <= '0;
            acc_mem_accum_rd_group <= 1'b0;
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_mem_accum_rd_group <= acc_mem_accum_start_bank[1];
                acc_mem_accum_rd_addr_by_bank[acc_mem_accum_start_bank[0]]
                    <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr;
                acc_mem_accum_rd_addr_by_bank[~acc_mem_accum_start_bank[0]]
                    <= gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr + `GEMM_PSUM_DATA_SIZE;
            end else if (acc_mem_accum_rd_accept) begin
                acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel]
                    <= acc_mem_accum_rd_addr_by_bank[acc_mem_accum_rd_sel] + ACC_RD_ADDR_STEP;
            end
        end
    end

    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_accum_rd_rr <= 1'b0;
            acc_rd_consume_bank <= 1'b0;
        end else begin
            if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                acc_mem_accum_rd_rr <= acc_mem_accum_start_bank[0];
                acc_rd_consume_bank <= acc_mem_accum_start_bank[0];
            end else begin
                if (acc_mem_accum_rd_accept)
                    acc_mem_accum_rd_rr <= ~acc_mem_accum_rd_sel;
                if (acc_rd_fifo_pop)
                    acc_rd_consume_bank <= ~acc_rd_consume_bank;
            end
        end
    end

    // ----- Read FSM Combinational Logic -----
    always_comb begin
        acc_mem_accum_rd_req        = 0;
        acc_mem_accum_rd_sel        = acc_mem_accum_rd_rr;
        acc_mem_accum_rd_state_next = acc_mem_accum_rd_state;
        acc_mem_accum_rd_cnt_by_bank_next = acc_mem_accum_rd_cnt_by_bank;

        case (acc_mem_accum_rd_state)
            ACCUM_RD_IDLE: begin
                if (gemm_unit_if.start & ~gemm_unit_if.gemm_unit_ctrl.is_load) begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_READ;
                    acc_mem_accum_rd_cnt_by_bank_next[acc_mem_accum_start_bank[0]]
                        = (gemm_unit_if.gemm_unit_ctrl.acc_cnt >> 1)
                        + gemm_unit_if.gemm_unit_ctrl.acc_cnt[0];
                    acc_mem_accum_rd_cnt_by_bank_next[~acc_mem_accum_start_bank[0]]
                        = gemm_unit_if.gemm_unit_ctrl.acc_cnt >> 1;
                end else begin
                    acc_mem_accum_rd_state_next = ACCUM_RD_IDLE;
                    acc_mem_accum_rd_cnt_by_bank_next = '0;
                end
            end

            ACCUM_RD_READ: begin
                if (acc_mem_accum_rd_cnt > 0) begin
                    if (acc_mem_accum_wr_fire) begin
                        acc_mem_accum_rd_sel = ~acc_mem_accum_wr_bank[0];
                        acc_mem_accum_rd_req = acc_mem_accum_rd_eligible[~acc_mem_accum_wr_bank[0]];
                    end else begin
                        case (acc_mem_accum_rd_eligible)
                            2'b01: begin
                                acc_mem_accum_rd_sel = 1'b0;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            2'b10: begin
                                acc_mem_accum_rd_sel = 1'b1;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            2'b11: begin
                                if (acc_rd_credit_count_by_bank[0] > acc_rd_credit_count_by_bank[1])
                                    acc_mem_accum_rd_sel = 1'b0;
                                else if (acc_rd_credit_count_by_bank[1] > acc_rd_credit_count_by_bank[0])
                                    acc_mem_accum_rd_sel = 1'b1;
                                acc_mem_accum_rd_req = 1'b1;
                            end
                            default: begin
                                acc_mem_accum_rd_req = 1'b0;
                            end
                        endcase
                    end
                    acc_mem_accum_rd_req = acc_mem_accum_rd_req
                                         && (~acc_mem_rd_data_valid || acc_mem_rd_data_take);
                    if (acc_mem_accum_rd_accept) begin
                        acc_mem_accum_rd_cnt_by_bank_next[acc_mem_accum_rd_sel]
                            = acc_mem_accum_rd_cnt_by_bank[acc_mem_accum_rd_sel] - 1;
                    end
                end else if (~acc_mem_rd_data_valid) begin
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
            acc_mem_accum_rd_cnt_by_bank <= '0;
        end else begin
            acc_mem_accum_rd_state <= acc_mem_accum_rd_state_next;
            acc_mem_accum_rd_cnt_by_bank <= acc_mem_accum_rd_cnt_by_bank_next;
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
                        // Pop psum when accumulator input is accepted (a_valid & b_valid).
                        // This keeps psum/input alignment even if FP adder latency changes.
                        acc_rd_fifo_pop      = acc_psum_data_valid[0];
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

        if (sz_req_hs & sz_req_rw) begin
            if (sz_req_addr >= SCALE_REG0_BASE && sz_req_addr < SCALE_REG1_BASE) begin
                scale_reg_wr_en = 1'b1;
            end else if (sz_req_addr >= SCALE_REG1_BASE && sz_req_addr < ZP_REG0_BASE) begin
                scale_reg_wr_en = 1'b1;
            end else if (sz_req_addr >= ZP_REG0_BASE && sz_req_addr < ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
            end else if (sz_req_addr >= ZP_REG1_BASE) begin
                zp_reg_wr_en    = 1'b1;
            end
        end
    end

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
    // FP32 to FP16 Output Control
    // =========================================================================
    always_ff @(posedge clk, posedge reset) begin
        if (reset) begin
            acc_mem_rd_out_valid <= 1'b0;
            acc_mem_out_rd_addr_q <= '0;
            acc_mem_out_rd_bank_q <= '0;
            acc_mem_out_rd_tag_q <= '0;
        end else begin
            if (out_mem_rd_req_fire) begin
                acc_mem_rd_out_valid <= 1'b1;
                acc_mem_out_rd_addr_q <= acc_mem_out_rd_addr;
                acc_mem_out_rd_bank_q <= acc_mem_out_rd_bank;
                acc_mem_out_rd_tag_q <= o_lmem_bus_if.req_data.tag;
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
`ifndef SYNTHESIS
            localparam int LANE_ID = i;
`endif
            logic activated;
            logic a_valid, b_valid;
            logic [`IFP_WIDTH-1:0] a_data, b_data;

            assign activated = (gemm_unit_ctrl.quant_dir == `QDIR_ROW) & in_flight;
            assign a_valid   = in_pipe_valid_out & activated;
            assign b_valid   = a_valid;
            assign a_data    = activated ? in_pipe_data_out[`IFP_WIDTH*i +: `IFP_WIDTH] : '0;
            assign b_data    = activated ? scale_regs[gemm_unit_ctrl.sreg_use_idx][i] : '0;

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
                if (!reset && a_valid && !in_scaler_a_ready[i] && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM input scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !in_scaler_b_ready[i] && in_flight===1) begin
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
                if (!reset && a_valid && !a_ready && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !b_ready && in_flight===1) begin
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
                if (!reset && a_valid && !a_ready && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM output scaler lane %0d backpressured while a_valid is asserted",
                           $time, LANE_ID);
                end
                if (!reset && b_valid && !b_ready && in_flight===1) begin
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
`ifndef SYNTHESIS
            localparam int LANE_ID = i;
`endif
            logic [FP32_WIDTH-1:0] a_data;
            logic [FP32_WIDTH-1:0] b_data;
            logic a_ready, b_ready;

            assign acc_in_data_valid[i] = final_scaler_output_valid & ~gemm_unit_ctrl.is_load;
            // assign acc_psum_data_valid[i] = ~acc_rd_fifo_empty & ~gemm_unit_ctrl.is_load & acc_in_data_valid[i];
            assign acc_psum_data_valid[i] = ~gemm_unit_ctrl.is_load & acc_in_data_valid[i]; // avoid deadlock.
            assign a_data  = final_scaler_output_valid ? scaled_fp32_out_data[i] : '0;
            assign b_data  = ~acc_rd_fifo_empty ? acc_rd_fifo_out_data[i] : '0;

            VX_fp32_add #(
                .LATENCY        (FP32_ADD_LATENCY),
                .OUT_BUF        (0),
                .USE_LATENCY1_IP(1)
            ) u_accumulator (
                .clk          (clk),
                .reset        (reset),
                .a_valid      (acc_in_data_valid[i]),
                .a_ready      (a_ready),
                .a_data       (a_data),
                .b_valid      (acc_psum_data_valid[i]),
                .b_ready      (b_ready),
                .b_data       (b_data),  // Use FIFO output, not direct memory read
                .result_valid (acc_output_valid[i]),
                .result_ready (1'b1),
                .result_data  (acc_output_data[i])
            );

`ifndef SYNTHESIS
            always @(posedge clk) begin
                if (!reset && acc_in_data_valid[i] && !a_ready && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM accumulator lane %0d backpressured while input data is valid",
                           $time, LANE_ID);
                end
                if (!reset && acc_psum_data_valid[i] && !b_ready && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM accumulator lane %0d backpressured while psum data is valid",
                           $time, LANE_ID);
                end
                if (!reset && acc_in_data_valid[i] && acc_rd_fifo_empty && in_flight===1) begin
                    $fatal(1, "[%0t] GEMM accumulator lane %0d input data valid but psum FIFO is empty",
                           $time, LANE_ID);
                end
            end
`endif
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Accumulator Read FIFO
    // -------------------------------------------------------------------------
    always_ff @(posedge clk, posedge reset) begin
      if(reset) begin
        acc_mem_accum_rd_bank_q <= '0;
      end else begin
        if(acc_mem_accum_rd_accept) begin
          acc_mem_accum_rd_bank_q <= acc_mem_accum_rd_bank;
        end
      end
    end
    generate
        for (genvar i = 0; i < 2; ++i) begin : gen_acc_rd_fifo
            VX_fifo_v2 #(
                .FALL_THROUGH (0),
                .DATA_WIDTH   (`MXU_COL * FP32_WIDTH),
                .DEPTH        (ACC_RD_FIFO_DEPTH),
                .ALM_FULL_TH  (ACC_RD_FIFO_DEPTH - 1)
            ) u_acc_rd_fifo (
                .clk_i       (clk),
                .rst_ni      (~reset),
                .flush_i     (gemm_unit_if.start),
                .testmode_i  (1'b0),
                .full_o      (acc_rd_fifo_full_by_bank[i]),
                .empty_o     (acc_rd_fifo_empty_by_bank[i]),
                .alm_full_o  (acc_rd_fifo_alm_full_by_bank[i]),
                .alm_empty_o (),
                .data_i      (acc_rd_fifo_in_data_by_bank[i]),
                .push_i      (acc_rd_fifo_push_by_bank[i]),
                .data_o      (acc_rd_fifo_out_data_by_bank[i]),
                .pop_i       (acc_rd_fifo_pop_fire_by_bank[i])
            );
        end
    endgenerate

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset && psum_underflow_event && in_flight===1) begin
            $fatal(1, "[%0t] GEMM accumulator psum FIFO empty when scaler output is valid: rd_cnt=%0d wr_cnt=%0d rd_addr=0x%0h wr_addr=0x%0h rd_state=%0d wr_state=%0d",
                   $time, acc_mem_accum_rd_cnt, acc_mem_accum_wr_cnt,
                   acc_mem_accum_rd_addr, acc_mem_accum_wr_addr,
                   acc_mem_accum_rd_state, acc_mem_accum_wr_state);
        end
        for (int i = 0; i < 2; ++i) begin
            if (!reset && in_flight===1 && acc_rd_fifo_push_by_bank[i]
                && acc_rd_fifo_full_by_bank[i] && !acc_rd_fifo_pop_fire_by_bank[i]) begin
                $fatal(1, "[%0t] GEMM accumulator read FIFO %0d full on push: rd_cnt=%0d wr_cnt=%0d rd_addr=0x%0h wr_addr=0x%0h",
                       $time, i, acc_mem_accum_rd_cnt, acc_mem_accum_wr_cnt,
                       acc_mem_accum_rd_addr, acc_mem_accum_wr_addr);
            end
            if (!reset && in_flight===1
                && acc_rd_credit_count_by_bank[i] > ACC_RD_CREDIT_W'(ACC_RD_CREDIT_MAX)) begin
                $fatal(1, "[%0t] GEMM accumulator read credit %0d out of range: credit=%0d max=%0d",
                       $time, i, acc_rd_credit_count_by_bank[i], ACC_RD_CREDIT_MAX);
            end
        end
        if (!reset && in_flight===1 && acc_mem_rd_data_valid && !acc_mem_rd_rsp_can_push) begin
            $fatal(1, "[%0t] GEMM accumulator read response has no reserved FIFO slot: rsp_bank=%0d rd_cnt=%0d wr_cnt=%0d credit={%0d,%0d}",
                   $time, acc_mem_accum_rd_bank_q, acc_mem_accum_rd_cnt, acc_mem_accum_wr_cnt,
                   acc_rd_credit_count_by_bank[1], acc_rd_credit_count_by_bank[0]);
        end
        if(!reset && in_flight===1 && acc_mem_accum_rd_accept && acc_mem_rd_data_valid && !acc_mem_rd_data_take) begin
            $fatal(1, "[%0t] GEMM accumulator read accepted while previous response was not accepted: rd_cnt=%0d wr_cnt=%0d rd_state=%0d wr_state=%0d credit={%0d,%0d}",
                   $time, acc_mem_accum_rd_cnt, acc_mem_accum_wr_cnt,
                   acc_mem_accum_rd_state, acc_mem_accum_wr_state,
                   acc_rd_credit_count_by_bank[1], acc_rd_credit_count_by_bank[0]);
        end
        if (!reset && in_flight===1 && acc_mem_accum_rd_accept
            && (get_acc_mem_idx(acc_mem_accum_rd_addr) != acc_mem_accum_rd_bank)) begin
            $fatal(1, "[%0t] GEMM accumulator read address left scheduled bank: addr=0x%0h decoded_bank=%0d scheduled_bank=%0d",
                   $time, acc_mem_accum_rd_addr, get_acc_mem_idx(acc_mem_accum_rd_addr),
                   acc_mem_accum_rd_bank);
        end
        if (!reset && in_flight===1 && rd_wr_conflict_event) begin
            $fatal(1, "[%0t] GEMM accumulator dual-bank scheduler issued conflicting read/write: rd_bank=%0d wr_bank=%0d",
                   $time, acc_mem_accum_rd_bank, acc_mem_accum_wr_bank);
        end
    end
`endif

    // -------------------------------------------------------------------------
    // Accumulator Memory Banks
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < 4; i++) begin : gen_acc_mem
            logic this_bank_accum_rd; 
            logic this_bank_out_rd; 
            logic this_bank_accum_wr; 

            assign this_bank_accum_rd = (acc_mem_accum_rd_bank == i && acc_mem_accum_rd_accept);
            assign this_bank_out_rd   = (acc_mem_out_rd_bank == i && out_mem_rd_req_fire);
            assign this_bank_accum_wr = (acc_mem_accum_wr_bank == i && acc_mem_accum_wr_req && in_flight);

            assign acc_mem_wr_en[i] = this_bank_accum_wr && (gemm_unit_ctrl.is_load ? final_scaler_output_valid : acc_output_valid[0]);
            assign acc_mem_rd_en[i] = this_bank_accum_rd ? acc_mem_accum_rd_accept :
                                      this_bank_out_rd   ? out_mem_rd_req_fire : 1'b0;
            assign acc_mem_wr_addr[i] = acc_mem_accum_wr_bank_addr;
            assign acc_mem_rd_addr[i] = this_bank_accum_rd ? acc_mem_accum_rd_bank_addr :
                                        this_bank_out_rd   ? acc_mem_out_rd_bank_addr : '0;
            assign acc_mem_in_data[i] = this_bank_accum_wr ? (gemm_unit_ctrl.is_load ? scaled_fp32_out_data : acc_output_data) : '0;

            assign acc_mem_wr_depth_addr[i] = get_acc_mem_bank_depth_addr(acc_mem_wr_addr[i]);
            assign acc_mem_rd_depth_addr[i] = get_acc_mem_bank_depth_addr(acc_mem_rd_addr[i]);

            VX_sp_ram #(
                .DATAW    (`MXU_COL * FP32_WIDTH),
                .SIZE     (`GEMM_ACC_MEM_DEPTH),
                .OUT_REG  (1),
                .USE_URAM (1),   // Force URAM after VX_sp_ram auto-infer removal
                .RDW_MODE ("R")  // Read-first required for URAM mapping
            ) VX_sp_ram_instance (
                .clk   (clk),
                .reset (reset),
                .read  (acc_mem_rd_en[i]),
                .write (acc_mem_wr_en[i]),
                .wren  (1'b1),
                .addr  (acc_mem_wr_en[i] ? acc_mem_wr_depth_addr[i] : acc_mem_rd_depth_addr[i]),
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
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] bank_depth_addr;
        logic [1:0] bank_idx;

        for (int i = 0; i < size; i++) begin
            automatic logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr;
            addr = base_addr + i * (`MXU_COL * (FP32_WIDTH/8));
            bank_idx  = get_acc_mem_idx(addr);
            bank_addr = get_acc_mem_bank_addr(addr);
            bank_depth_addr = get_acc_mem_bank_depth_addr(bank_addr);

            case (bank_idx)
                2'd0: gen_acc_mem[0].VX_sp_ram_instance.ram[bank_depth_addr] = init_value;
                2'd1: gen_acc_mem[1].VX_sp_ram_instance.ram[bank_depth_addr] = init_value;
                2'd2: gen_acc_mem[2].VX_sp_ram_instance.ram[bank_depth_addr] = init_value;
                2'd3: gen_acc_mem[3].VX_sp_ram_instance.ram[bank_depth_addr] = init_value;
            endcase
        end
    endtask

    task read_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        output logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] bank_depth_addr;
        logic [1:0] bank_idx;

        bank_idx  = get_acc_mem_idx(addr);
        bank_addr = get_acc_mem_bank_addr(addr);
        bank_depth_addr = get_acc_mem_bank_depth_addr(bank_addr);


        case (bank_idx)
            2'd0: data = gen_acc_mem[0].VX_sp_ram_instance.ram[bank_depth_addr];
            2'd1: data = gen_acc_mem[1].VX_sp_ram_instance.ram[bank_depth_addr];
            2'd2: data = gen_acc_mem[2].VX_sp_ram_instance.ram[bank_depth_addr];
            2'd3: data = gen_acc_mem[3].VX_sp_ram_instance.ram[bank_depth_addr];
        endcase
    endtask

    task write_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        input logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] bank_depth_addr;
        logic [1:0] bank_idx;

        bank_idx  = get_acc_mem_idx(addr);
        bank_addr = get_acc_mem_bank_addr(addr);
        bank_depth_addr = get_acc_mem_bank_depth_addr(bank_addr);

        case (bank_idx)
            2'd0: gen_acc_mem[0].VX_sp_ram_instance.ram[bank_depth_addr] = data;
            2'd1: gen_acc_mem[1].VX_sp_ram_instance.ram[bank_depth_addr] = data;
            2'd2: gen_acc_mem[2].VX_sp_ram_instance.ram[bank_depth_addr] = data;
            2'd3: gen_acc_mem[3].VX_sp_ram_instance.ram[bank_depth_addr] = data;
        endcase
    endtask
`endif
`endif

    // -------------------------------------------------------------------------
    // FP32 to FP16 Converters
    // -------------------------------------------------------------------------
    generate
        for (genvar i = 0; i < `MXU_COL; i++) begin : gen_fp32_to_fp16
            VX_f32_to_f16 u_f32_to_f16 (
                .clk_i    (clk),
                .resetn_i (~reset),
                .data_i   (acc_mem_out_data[acc_mem_out_rd_bank_q][i]),
                .valid_i  (acc_mem_rd_out_valid),
                .data_o   (fp16_out_data[i]),
                .valid_o  (fp16_out_valid[i])
            );
        end
    endgenerate

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_GEMM
    localparam int DBG_BIT_W      = $bits(logic);
    localparam int DBG_STATE_W    = $bits(gemm_state_t);
    localparam int DBG_RD_STATE_W = $bits(acc_mem_accum_rd_state_t);
    localparam int DBG_WR_STATE_W = $bits(acc_mem_accum_wr_state_t);
    localparam int DBG_WORD_W     = $bits(logic [31:0]);
    localparam int DBG_BANK_W     = $bits(acc_mem_accum_rd_bank);

    localparam int DBG_GEMM_UNIT_P0_W = (20 * DBG_BIT_W) + (2 * DBG_STATE_W) + (2 * DBG_RD_STATE_W) + (3 * DBG_WR_STATE_W);
    localparam int DBG_GEMM_UNIT_P1_W = (8 * DBG_WORD_W);
    localparam int DBG_GEMM_UNIT_P2_W = (5 * DBG_BANK_W) + (6 * DBG_WORD_W) + (4 * DBG_BIT_W);
    localparam int DBG_GEMM_UNIT_P3_W = (9 * DBG_WORD_W) + (14 * DBG_BIT_W);

    (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_UNIT_P0_W-1:0] dbg_gemm_unit_probe0 = {
        reset,
        gemm_unit_if.start,
        gemm_idle,
        gemm_done,
        in_flight,
        mxu_ready_weight,
        is_qcol,
        state,
        next_state,
        acc_mem_accum_rd_state,
        acc_mem_accum_rd_state_next,
        acc_mem_accum_wr_state,
        acc_mem_accum_wr_state_next,
        acc_mem_accum_wr_state_q,
        acc_mem_accum_rd_req,
        acc_mem_accum_wr_req,
        acc_rd_fifo_push,
        acc_rd_fifo_pop,
        acc_rd_fifo_full,
        acc_rd_fifo_empty,
        final_scaler_output_valid,
        acc_output_valid[0],
        acc_psum_data_valid[0],
        acc_in_data_valid[0],
        out_mem_rd_req_fire,
        acc_mem_rd_out_valid,
        fp16_out_valid[0]
    };
    (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_UNIT_P1_W-1:0] dbg_gemm_unit_probe1 = {
        32'(gemm_unit_if.gemm_unit_ctrl.acc_cnt),
        32'(gemm_unit_if.gemm_unit_ctrl.acc_mem_base_addr),
        32'(acc_mem_accum_rd_addr),
        32'(acc_mem_accum_wr_addr),
        32'(acc_mem_out_rd_addr),
        32'(acc_mem_out_rd_addr_q),
        32'(acc_mem_accum_rd_cnt),
        32'(acc_mem_accum_wr_cnt)
    };
    (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_UNIT_P2_W-1:0] dbg_gemm_unit_probe2 = {
        2'(acc_mem_accum_rd_bank),
        2'(acc_mem_accum_rd_bank_q),
        2'(acc_mem_accum_wr_bank),
        2'(acc_mem_out_rd_bank),
        2'(acc_mem_out_rd_bank_q),
        32'(acc_mem_accum_rd_bank_addr),
        32'(acc_mem_accum_wr_bank_addr),
        32'(acc_mem_out_rd_bank_addr),
        32'(acc_mem_rd_depth_addr[0]),
        32'(acc_mem_wr_depth_addr[0]),
        32'(o_lmem_bus_if.req_data.addr),
        o_lmem_bus_if.req_valid,
        o_lmem_bus_if.req_ready,
        o_lmem_bus_if.rsp_valid,
        o_lmem_bus_if.rsp_ready
    };
    (* keep = "true", mark_debug = "true" *) wire [DBG_GEMM_UNIT_P3_W-1:0] dbg_gemm_unit_probe3 = {
        i_lmem_bus_if.req_valid,
        i_lmem_bus_if.req_ready,
        w_lmem_bus_if.req_valid,
        w_lmem_bus_if.req_ready,
        sz_lmem_bus_if.req_valid,
        sz_lmem_bus_if.req_ready,
        o_lmem_bus_if.req_valid,
        o_lmem_bus_if.req_ready,
        32'(i_lmem_bus_if.req_data.addr),
        32'(w_lmem_bus_if.req_data.addr),
        32'(sz_lmem_bus_if.req_data.addr),
        32'(o_lmem_bus_if.req_data.addr),
        32'(sz_req_addr),
        sz_req_rw,
        scale_reg_wr_req,
        scale_reg_wr_en,
        zp_reg_wr_req,
        zp_reg_wr_en,
        is_qcol,
        32'(gemm_unit_ctrl.quant_dir),
        32'(gemm_unit_ctrl.wreg_use_idx),
        32'(gemm_unit_ctrl.sreg_use_idx),
        32'(gemm_unit_ctrl.zreg_use_idx)
    };

    ila_gemm_unit ila_gemm_unit_inst (
      .clk    (clk),
      .probe0 (dbg_gemm_unit_probe0),
      .probe1 (dbg_gemm_unit_probe1),
      .probe2 (dbg_gemm_unit_probe2),
      .probe3 (dbg_gemm_unit_probe3)
    );
`endif
`endif

    // =========================================================================
    // Debug Tracing
    // =========================================================================
`ifdef DBG_TRACE_GEMM_CTRL
    // FSM state names for debug
`ifndef SYNTHESIS
`define VX_GEMM_UNIT_STRING_HELPERS
`elsif SIMULATION
`define VX_GEMM_UNIT_STRING_HELPERS
`endif

`ifdef VX_GEMM_UNIT_STRING_HELPERS
    function automatic string state_to_str(input gemm_state_t s);
        case (s)
            IDLE:    return "IDLE";
            COMPUTE: return "COMPUTE";
            default: return "UNKNOWN";
        endcase
    endfunction
`endif // VX_GEMM_UNIT_STRING_HELPERS

`ifdef VX_GEMM_UNIT_STRING_HELPERS
`undef VX_GEMM_UNIT_STRING_HELPERS
`endif

    always @(posedge clk) begin
        if (~reset) begin
            // FSM state transition
            if (state != next_state) begin
                `TRACE(2, ("%m : [%0t] | GEMM_FSM_STATE_TRANSITION | {inst=%s, from_state=%s, to_state=%s}\n", $time, INSTANCE_ID, state_to_str(state), state_to_str(next_state)))
            end

            // GEMM start event
            if (gemm_unit_if.start) begin
                `TRACE(1, ("%m : [%0t] | GEMM_START | {inst=%s, is_load=%b, quant_dir=%b, acc_cnt=%0d, acc_base=0x%0h, wreg=%0d, sreg=%0d, zreg=%0d}\n",
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
                `TRACE(1, ("%m : [%0t] | GEMM_DONE | {inst=%s}\n", $time, INSTANCE_ID))
            end
        end
    end
`endif

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
        if (~reset) begin
            // Weight loading
            if (mxu_ready_weight) begin
                `TRACE(2, ("%m : [%0t] | GEMM_WEIGHT_LOAD | {inst=%s, wr_idx=%0d, load_dir=%0d}\n",
                    $time, INSTANCE_ID, wreg_wr_idx, wreg_load_dir))
            end

            // Scale/Zero register writes
            if (scale_reg_wr_en) begin
                `TRACE(3, ("%m : [%0t] | GEMM_SCALE_REG_WRITE | {inst=%s, reg_idx=%0d, data=%s}\n",
                    $time, INSTANCE_ID, scale_reg_idx, VX_utils_pkg::parseWordNoNormal(sz_req_data, `MAX(`MXU_ROW, `MXU_COL) * `SCALE_WIDTH, `SCALE_WIDTH, "fp")))
            end
            if (zp_reg_wr_en) begin
                `TRACE(3, ("%m : [%0t] | GEMM_ZP_REG_WRITE | {inst=%s, reg_idx=%0d, data=%s}\n",
                    $time, INSTANCE_ID, zp_reg_idx, VX_utils_pkg::parseWordNoNormal(sz_req_data, `MAX(`MXU_ROW, `MXU_COL) * `ZP_WIDTH, `ZP_WIDTH, "int")))
            end

            // Input data arrival
            if (in_pipe_valid_out & in_flight) begin
                `TRACE(3, ("%m : [%0t] | GEMM_INPUT_VALID | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(in_pipe_data_out, `MXU_ROW * `IFP_WIDTH, `IFP_WIDTH, "fp")))
            end

            if (in_scaler_result_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_INPUT_SCALER_RESULT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(in_scaler_result_data, `MXU_ROW * `IFP_WIDTH, `IFP_WIDTH, "fp")))
            end

            // Prealigner output
            if (prealigner_out_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_PREALIGNER_OUT | {inst=%s, max_exp=0x%0h}\n",
                    $time, INSTANCE_ID, prealigner_max_exp))
                `TRACE(3, ("%m : [%0t] | GEMM_PREALIGNER_INT_DATA | {inst=%s, int_data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(prealigner_int_data, `MXU_ROW * `SEL_BLOCK_WIDTH, `SEL_BLOCK_WIDTH, "uint")))
                `TRACE(3, ("%m : [%0t] | GEMM_PREALIGNER_BLK_IDX | {inst=%s, blk_idx=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(prealigner_blk_idx, `MXU_ROW * `BLOCK_IDX_WIDTH, `BLOCK_IDX_WIDTH, "uint")))
            end

            if (act_reduce_valid_out) begin
                `TRACE(3, ("%m : [%0t] | GEMM_ACT_REDUCE_OUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(act_reduce_data_out, `ACT_REDUCE_OUT_WIDTH, `ACT_REDUCE_OUT_WIDTH, "int")));
            end

            if (zp_mul_out_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_ZP_MUL_OUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(zp_mul_out_data_q, `MXU_COL * `ZP_MUL_OUT_WIDTH, `ZP_MUL_OUT_WIDTH, "int")));
            end

            if (pre_proc_out_valid) begin
                `TRACE(2, ("%m : [%0t] | GEMM_PREPROCESSOR_OUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(pre_proc_out_q, `MXU_COL * `PRE_PROC_OUT_DW, `PRE_PROC_OUT_DW, "int")))
            end

            // MXU output valid
            if (merger_in_valid) begin
                `TRACE(2, ("%m : [%0t] | GEMM_MXU_OUTPUT_VALID | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(mxu_output_dly, `MXU_COL * `O_BIT_WIDTH, `O_BIT_WIDTH, "int")))
            end

            // Merger output
            if (merger_out_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_MERGER_OUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(merger_out_data_q, `MXU_COL * `MERGE_OUT_BW, `MERGE_OUT_BW, "int")))
            end

            // Int2FP output
`ifdef GEMM_UNIT_FP16_OUT_SCALE
            if (int2fp_output_valid[0]) begin
                `TRACE(3, ("%m : [%0t] | GEMM_INT2FP_OUT | {inst=%s, fp16=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(int2fp_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end

            // Scaler output (or bypass for QROW)
            if (final_scaler_output_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_SCALER_OUT | {inst=%s, bypass=%b, fp16=%s}\n",
                    $time, INSTANCE_ID, ~is_qcol, VX_utils_pkg::parseWordNoNormal(final_scaled_fp_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end
`else
            if (int2fp_output_valid[0]) begin
                `TRACE(3, ("%m : [%0t] | GEMM_INT2FP_OUT | {inst=%s, fp32=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(int2fp_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // Scaler output (or bypass for QROW)
            if (final_scaler_output_valid) begin
                `TRACE(3, ("%m : [%0t] | GEMM_SCALER_OUT | {inst=%s, bypass=%b, fp32=%s}\n",
                    $time, INSTANCE_ID, ~is_qcol, VX_utils_pkg::parseWordNoNormal(final_scaled_fp_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end
`endif

            // Accumulator write
            if (acc_mem_accum_wr_req) begin
                `TRACE(2, ("%m : [%0t] | GEMM_ACC_MEM_WRITE_ACCUM | {inst=%s, addr=0x%0h, bank=%0d, is_load=%b, cnt=%0d, data=%s}\n",
                    $time, INSTANCE_ID, acc_mem_accum_wr_addr, acc_mem_accum_wr_bank,
                    gemm_unit_ctrl.is_load, acc_mem_accum_wr_cnt, VX_utils_pkg::parseWordNoNormal(acc_mem_in_data[acc_mem_accum_wr_bank], `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // Accumulator read
            if (acc_mem_accum_rd_accept) begin
                `TRACE(3, ("%m : [%0t] | GEMM_ACC_MEM_READ_ACCUM | {inst=%s, addr=0x%0h, bank=%0d, cnt=%0d}\n",
                    $time, INSTANCE_ID, acc_mem_accum_rd_addr, acc_mem_accum_rd_bank, acc_mem_accum_rd_cnt))
            end

            // FIFO push
            if (acc_rd_fifo_push) begin
                `TRACE(2, ("%m : [%0t] | GEMM_FIFO_PUSH | {inst=%s, bank=%0d, data=%s, full=%b, empty=%b}\n",
                    $time, INSTANCE_ID, acc_mem_accum_rd_bank_q[0],
                    VX_utils_pkg::parseWordNoNormal(acc_rd_fifo_in_data_by_bank[acc_mem_accum_rd_bank_q[0]], `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp"),
                    acc_rd_fifo_full_by_bank[acc_mem_accum_rd_bank_q[0]],
                    acc_rd_fifo_empty_by_bank[acc_mem_accum_rd_bank_q[0]]))
            end

            // FIFO pop
            if (acc_rd_fifo_pop) begin
                `TRACE(2, ("%m : [%0t] | GEMM_FIFO_POP | {inst=%s, bank=%0d, out_data=%s, full=%b, empty=%b}\n",
                    $time, INSTANCE_ID, acc_rd_consume_bank,
                    VX_utils_pkg::parseWordNoNormal(acc_rd_fifo_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp"),
                    acc_rd_fifo_full_by_bank[acc_rd_consume_bank], acc_rd_fifo_empty))
            end

            // Accumulator input (when not is_load)
            if (final_scaler_output_valid && ~gemm_unit_ctrl.is_load) begin
                `TRACE(2, ("%m : [%0t] | GEMM_ACCUM_INPUT | {inst=%s, a_data=%s, b_data_fifo=%s, fifo_empty=%b}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(scaled_fp32_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp"),
                    VX_utils_pkg::parseWordNoNormal(acc_rd_fifo_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp"),
                    acc_rd_fifo_empty))
            end

            // Accumulator output
            if (acc_output_valid[0] && ~gemm_unit_ctrl.is_load) begin
                `TRACE(2, ("%m : [%0t] | GEMM_ACCUM_OUTPUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(acc_output_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // Accumulation mem read data
            if (acc_mem_rd_out_valid) begin
                `TRACE(2, ("%m : [%0t] | GEMM_ACC_MEM_READ_OUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(acc_rd_fifo_out_data, `MXU_ROW * FP32_WIDTH, FP32_WIDTH, "fp")))
            end

            // FP16 output valid
            if (fp16_out_valid[0]) begin
                `TRACE(2, ("%m : [%0t] | GEMM_FP16_OUTPUT | {inst=%s, data=%s}\n",
                    $time, INSTANCE_ID, VX_utils_pkg::parseWordNoNormal(fp16_out_data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end

            // o_lmem_bus
            if (out_mem_rd_req_fire) begin
                `TRACE(1, ("%m : [%0t] | GEMM_ACC_MEM_OUT_READ_REQ | {inst=%s, addr=0x%0h, bank=%0d}\n",
                    $time, INSTANCE_ID, o_lmem_bus_if.req_data.addr, acc_mem_out_rd_bank))
            end
            if (o_lmem_bus_if.rsp_valid & o_lmem_bus_if.rsp_ready) begin
                `TRACE(2, ("%m : [%0t] | GEMM_ACC_MEM_OUT_READ_RSP | {inst=%s, addr=0x%0h, bank=%0d, data=%s}\n",
                    $time, INSTANCE_ID, acc_mem_out_rd_addr_q >> `CLOG2(`GEMM_PSUM_DATA_SIZE), acc_mem_out_rd_bank_q,
                    VX_utils_pkg::parseWordNoNormal(o_lmem_bus_if.rsp_data.data, `MXU_ROW * FP16_WIDTH, FP16_WIDTH, "fp")))
            end
        end
    end

    always @(posedge clk) begin
      // Ignore reset/startup transients; alignment checks are meaningful only
      // while a GEMM command is in flight.
      if (reset===0 && in_flight) begin
        if(pre_proc_out_valid ^ mxu_output_valid_dly[`MXU_COL/`MXU_COL_TILE-1]) begin
          `TRACE(2, ("%t: %s: WARN - Pre-processor output valid and MXU output valid are not aligned! pre_proc_out_valid=%b, mxu_output_valid_dly=%b\n",
              $time, INSTANCE_ID, pre_proc_out_valid, mxu_output_valid_dly[`MXU_COL/`MXU_COL_TILE-1]));
        end

        if(merger_out_valid ^ prealigner_max_exp_q_valid) begin
          `TRACE(2, ("%t: %s: WARN - Merger output valid and Prealigner max exp valid are not aligned! merger_out_valid=%b, prealigner_max_exp_q_valid=%b\n",
              $time, INSTANCE_ID, merger_out_valid, prealigner_max_exp_q_valid));
        end

        if(~gemm_unit_ctrl.is_load && (&acc_in_data_valid == 1 &&  &acc_psum_data_valid == 0)) begin
          `TRACE(2, ("%t: %s: WARN - Accumulator input data valid and psum data valid are not aligned! acc_in_data_valid=%b, acc_psum_data_valid=%b\n",
              $time, INSTANCE_ID, acc_in_data_valid, acc_psum_data_valid));
        end
      end
    end
`endif

`ifdef ENABLE_HW_DEBUG_GEMM
    reg [PERF_CTR_BITS-1:0] debug_rd_accept_count_r;
    reg [PERF_CTR_BITS-1:0] debug_wr_fire_count_r;
    reg [PERF_CTR_BITS-1:0] debug_scaler_valid_count_r;
    reg [PERF_CTR_BITS-1:0] debug_acc_output_count_r;
    reg [PERF_CTR_BITS-1:0] debug_psum_underflow_count_r;
    reg [PERF_CTR_BITS-1:0] debug_rd_wr_conflict_count_r;

    always @(posedge clk) begin
        if (reset) begin
            debug_rd_accept_count_r      <= '0;
            debug_wr_fire_count_r        <= '0;
            debug_scaler_valid_count_r   <= '0;
            debug_acc_output_count_r     <= '0;
            debug_psum_underflow_count_r <= '0;
            debug_rd_wr_conflict_count_r <= '0;
        end else begin
            if (acc_mem_accum_rd_accept)
                debug_rd_accept_count_r <= debug_rd_accept_count_r + PERF_CTR_BITS'(1);
            if (acc_mem_accum_wr_fire)
                debug_wr_fire_count_r <= debug_wr_fire_count_r + PERF_CTR_BITS'(1);
            if (final_scaler_output_valid && in_flight)
                debug_scaler_valid_count_r <= debug_scaler_valid_count_r + PERF_CTR_BITS'(1);
            if (acc_output_valid[0] && in_flight && ~gemm_unit_ctrl.is_load)
                debug_acc_output_count_r <= debug_acc_output_count_r + PERF_CTR_BITS'(1);
            if (psum_underflow_event)
                debug_psum_underflow_count_r <= debug_psum_underflow_count_r + PERF_CTR_BITS'(1);
            if (rd_wr_conflict_event)
                debug_rd_wr_conflict_count_r <= debug_rd_wr_conflict_count_r + PERF_CTR_BITS'(1);
        end
    end

    assign debug.valid                = 1'b1;
    assign debug.computing            = (state == COMPUTE);
    assign debug.idle                 = gemm_idle;
    assign debug.done                 = gemm_done;
    assign debug.is_load              = gemm_unit_ctrl.is_load;
    assign debug.is_qcol              = is_qcol;
    assign debug.rd_req               = acc_mem_accum_rd_req;
    assign debug.rd_accept            = acc_mem_accum_rd_accept;
    assign debug.rd_fifo_push         = acc_rd_fifo_push;
    assign debug.rd_fifo_pop          = acc_rd_fifo_pop;
    assign debug.rd_fifo_empty        = acc_rd_fifo_empty;
    assign debug.rd_fifo_full         = acc_rd_fifo_full;
    assign debug.rd_fifo_alm_full     = acc_rd_fifo_alm_full;
    assign debug.mem_rd_data_valid    = acc_mem_rd_data_valid;
    assign debug.wr_req               = acc_mem_accum_wr_req;
    assign debug.wr_fire              = acc_mem_accum_wr_fire;
    assign debug.final_scaler_valid   = final_scaler_output_valid;
    assign debug.acc_in_valid         = acc_in_data_valid[0];
    assign debug.psum_valid           = acc_psum_data_valid[0];
    assign debug.acc_output_valid     = acc_output_valid[0];
    assign debug.psum_underflow       = psum_underflow_event;
    assign debug.rd_wr_conflict       = rd_wr_conflict_event;
    assign debug.state                = 2'(state);
    assign debug.rd_state             = 2'(acc_mem_accum_rd_state);
    assign debug.wr_state             = 2'(acc_mem_accum_wr_state);
    assign debug.rd_bank              = acc_mem_accum_rd_bank;
    assign debug.wr_bank              = acc_mem_accum_wr_bank;
    assign debug.rd_cnt               = acc_mem_accum_rd_cnt;
    assign debug.wr_cnt               = acc_mem_accum_wr_cnt;
    assign debug.rd_addr              = acc_mem_accum_rd_addr;
    assign debug.wr_addr              = acc_mem_accum_wr_addr;
    assign debug.rd_accept_count      = debug_rd_accept_count_r;
    assign debug.wr_fire_count        = debug_wr_fire_count_r;
    assign debug.scaler_valid_count   = debug_scaler_valid_count_r;
    assign debug.acc_output_count     = debug_acc_output_count_r;
    assign debug.psum_underflow_count = debug_psum_underflow_count_r;
    assign debug.rd_wr_conflict_count = debug_rd_wr_conflict_count_r;
`endif

`ifdef PERF_ENABLE
    // -------------------------------------------------------------------------
    // Performance counters
    // -------------------------------------------------------------------------
    reg [PERF_CTR_BITS-1:0] perf_compute_r;
    reg [PERF_CTR_BITS-1:0] perf_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_jobs_r;
    reg [PERF_CTR_BITS-1:0] perf_mac_count_r;
    reg [PERF_CTR_BITS-1:0] perf_input_fire_r,  perf_input_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_weight_fire_r, perf_weight_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_psum_fire_r,   perf_psum_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_output_fire_r, perf_output_stall_r;
    reg [PERF_CTR_BITS-1:0] perf_accum_rd_accept_r, perf_accum_wr_fire_r;
    reg [PERF_CTR_BITS-1:0] perf_scaler_valid_r, perf_acc_output_valid_r;
    reg [PERF_CTR_BITS-1:0] perf_psum_underflow_r, perf_rd_wr_conflict_r;

    // Input: pipe buffer output valid-ready (ready = in_flight = COMPUTE)
    wire perf_input_fire  = in_pipe_valid_out && in_flight;
    wire perf_input_stall = in_pipe_valid_out && !in_flight;
    // Weight: LMEM bus request valid-ready
    wire perf_weight_fire  = w_lmem_bus_if.req_valid && w_lmem_bus_if.req_ready;
    wire perf_weight_stall = w_lmem_bus_if.req_valid && !w_lmem_bus_if.req_ready;
    // Psum: accumulator read FIFO push valid-ready
    wire perf_psum_fire  = acc_rd_fifo_push;
    wire perf_psum_stall = acc_mem_rd_data_valid && !acc_mem_rd_data_take;
    // Output: LMEM output bus fire / stall (actual data written out)
    wire perf_output_fire  = o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready;
    wire perf_output_stall = o_lmem_bus_if.req_valid && !o_lmem_bus_if.req_ready;
    wire perf_accum_rd_accept  = acc_mem_accum_rd_accept;
    wire perf_accum_wr_fire    = acc_mem_accum_wr_fire;
    wire perf_scaler_valid     = final_scaler_output_valid && in_flight;
    wire perf_acc_output_valid = acc_output_valid[0] && in_flight && ~gemm_unit_ctrl.is_load;
    wire perf_psum_underflow   = psum_underflow_event;
    wire perf_rd_wr_conflict   = rd_wr_conflict_event;

    // ------------------------------------------------------------
    // Perf-trigger register stage (timing fix).
    //
    // Decouples perf counter CEs from the FSM state and bus_if
    // handshake combinational fanout (w/o/i/sz LMEM buses plus
    // acc_mem read path). Telemetry-only path: every predicate is
    // delayed by exactly 1 cycle, so counter totals stay exact
    // (events slide together).
    // Cost: 11 flops per VX_gemm_unit instance, inside PERF_ENABLE.
    // ------------------------------------------------------------
    reg state_compute_q;
    reg state_stall_q;
    reg gemm_done_q;
    reg perf_input_fire_q,   perf_input_stall_q;
    reg perf_weight_fire_q,  perf_weight_stall_q;
    reg perf_psum_fire_q,    perf_psum_stall_q;
    reg perf_output_fire_q,  perf_output_stall_q;
    reg perf_accum_rd_accept_q, perf_accum_wr_fire_q;
    reg perf_scaler_valid_q, perf_acc_output_valid_q;
    reg perf_psum_underflow_q, perf_rd_wr_conflict_q;

    always @(posedge clk) begin
        if (reset) begin
            state_compute_q     <= 1'b0;
            state_stall_q       <= 1'b0;
            gemm_done_q         <= 1'b0;
            perf_input_fire_q   <= 1'b0;
            perf_input_stall_q  <= 1'b0;
            perf_weight_fire_q  <= 1'b0;
            perf_weight_stall_q <= 1'b0;
            perf_psum_fire_q    <= 1'b0;
            perf_psum_stall_q   <= 1'b0;
            perf_output_fire_q  <= 1'b0;
            perf_output_stall_q <= 1'b0;
            perf_accum_rd_accept_q <= 1'b0;
            perf_accum_wr_fire_q   <= 1'b0;
            perf_scaler_valid_q    <= 1'b0;
            perf_acc_output_valid_q <= 1'b0;
            perf_psum_underflow_q  <= 1'b0;
            perf_rd_wr_conflict_q  <= 1'b0;
        end else begin
            state_compute_q     <= (state == COMPUTE);
            state_stall_q       <= (state == IDLE) && !gemm_idle;
            gemm_done_q         <= gemm_done;
            perf_input_fire_q   <= perf_input_fire;
            perf_input_stall_q  <= perf_input_stall;
            perf_weight_fire_q  <= perf_weight_fire;
            perf_weight_stall_q <= perf_weight_stall;
            perf_psum_fire_q    <= perf_psum_fire;
            perf_psum_stall_q   <= perf_psum_stall;
            perf_output_fire_q  <= perf_output_fire;
            perf_output_stall_q <= perf_output_stall;
            perf_accum_rd_accept_q <= perf_accum_rd_accept;
            perf_accum_wr_fire_q   <= perf_accum_wr_fire;
            perf_scaler_valid_q    <= perf_scaler_valid;
            perf_acc_output_valid_q <= perf_acc_output_valid;
            perf_psum_underflow_q  <= perf_psum_underflow;
            perf_rd_wr_conflict_q  <= perf_rd_wr_conflict;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            perf_compute_r      <= '0;
            perf_stall_r        <= '0;
            perf_jobs_r         <= '0;
            perf_mac_count_r    <= '0;
            perf_input_fire_r   <= '0;
            perf_input_stall_r  <= '0;
            perf_weight_fire_r  <= '0;
            perf_weight_stall_r <= '0;
            perf_psum_fire_r    <= '0;
            perf_psum_stall_r   <= '0;
            perf_output_fire_r  <= '0;
            perf_output_stall_r <= '0;
            perf_accum_rd_accept_r <= '0;
            perf_accum_wr_fire_r   <= '0;
            perf_scaler_valid_r    <= '0;
            perf_acc_output_valid_r <= '0;
            perf_psum_underflow_r  <= '0;
            perf_rd_wr_conflict_r  <= '0;
        end else begin
            if (state_compute_q)
                perf_compute_r <= perf_compute_r + PERF_CTR_BITS'(1);
            if (state_stall_q)
                perf_stall_r <= perf_stall_r + PERF_CTR_BITS'(1);
            if (gemm_done_q)
                perf_jobs_r <= perf_jobs_r + PERF_CTR_BITS'(1);
            if (perf_output_fire_q)
                perf_mac_count_r <= perf_mac_count_r + PERF_CTR_BITS'(`MXU_ROW * `MXU_COL);
            if (perf_input_fire_q)
                perf_input_fire_r <= perf_input_fire_r + PERF_CTR_BITS'(1);
            if (perf_input_stall_q)
                perf_input_stall_r <= perf_input_stall_r + PERF_CTR_BITS'(1);
            if (perf_weight_fire_q)
                perf_weight_fire_r <= perf_weight_fire_r + PERF_CTR_BITS'(1);
            if (perf_weight_stall_q)
                perf_weight_stall_r <= perf_weight_stall_r + PERF_CTR_BITS'(1);
            if (perf_psum_fire_q)
                perf_psum_fire_r <= perf_psum_fire_r + PERF_CTR_BITS'(1);
            if (perf_psum_stall_q)
                perf_psum_stall_r <= perf_psum_stall_r + PERF_CTR_BITS'(1);
            if (perf_output_fire_q)
                perf_output_fire_r <= perf_output_fire_r + PERF_CTR_BITS'(1);
            if (perf_output_stall_q)
                perf_output_stall_r <= perf_output_stall_r + PERF_CTR_BITS'(1);
            if (perf_accum_rd_accept_q)
                perf_accum_rd_accept_r <= perf_accum_rd_accept_r + PERF_CTR_BITS'(1);
            if (perf_accum_wr_fire_q)
                perf_accum_wr_fire_r <= perf_accum_wr_fire_r + PERF_CTR_BITS'(1);
            if (perf_scaler_valid_q)
                perf_scaler_valid_r <= perf_scaler_valid_r + PERF_CTR_BITS'(1);
            if (perf_acc_output_valid_q)
                perf_acc_output_valid_r <= perf_acc_output_valid_r + PERF_CTR_BITS'(1);
            if (perf_psum_underflow_q)
                perf_psum_underflow_r <= perf_psum_underflow_r + PERF_CTR_BITS'(1);
            if (perf_rd_wr_conflict_q)
                perf_rd_wr_conflict_r <= perf_rd_wr_conflict_r + PERF_CTR_BITS'(1);
        end
    end

    assign perf.compute_cycles = perf_compute_r;
    assign perf.stall_cycles   = perf_stall_r;
    assign perf.job_count      = perf_jobs_r;
    assign perf.mac_count      = perf_mac_count_r;
    assign perf.input_fire     = perf_input_fire_r;
    assign perf.input_stall    = perf_input_stall_r;
    assign perf.weight_fire    = perf_weight_fire_r;
    assign perf.weight_stall   = perf_weight_stall_r;
    assign perf.psum_fire      = perf_psum_fire_r;
    assign perf.psum_stall     = perf_psum_stall_r;
    assign perf.output_fire    = perf_output_fire_r;
    assign perf.output_stall   = perf_output_stall_r;
    assign perf.accum_rd_accept = perf_accum_rd_accept_r;
    assign perf.accum_wr_fire   = perf_accum_wr_fire_r;
    assign perf.scaler_valid    = perf_scaler_valid_r;
    assign perf.acc_output_valid = perf_acc_output_valid_r;
    assign perf.psum_underflow  = perf_psum_underflow_r;
    assign perf.rd_wr_conflict  = perf_rd_wr_conflict_r;
    assign perf.computing      = (state == COMPUTE);
`endif

endmodule

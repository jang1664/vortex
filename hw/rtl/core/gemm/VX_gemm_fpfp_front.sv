`include "VX_define.vh"

`ifdef GEMM_NAIVE_FP16_ENABLE
// Naive FP16 operands, exact widening, FP32 product and adjacent-pair tree.
// Credits reserve result storage before the non-stallable arithmetic island.
// ACC ownership and final narrowing remain in VX_gemm_compute_core.
module VX_gemm_fpfp_front import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int ROWS = `FPFP_MXU_ROW,
    parameter int COLS = `FPFP_MXU_COL,
    parameter int LOAD_ROWS = `FPFP_MXU_WLOAD_NUM
) (
    input wire clk,
    input wire reset,
    input wire input_valid,
    output wire input_ready,
    input wire [ROWS-1:0][15:0] input_data,
    input gemm_input_ctrl_t input_ctrl,
    VX_mem_bus_if.slave weight_bus_if,
    output wire weight_install,
    output wire result_valid,
    input wire result_ready,
    output wire [COLS-1:0][31:0] result_data,
    output gemm_input_ctrl_t result_ctrl,
    output wire idle
);
    `include "VX_fp16_arith.vh"
    localparam int LEVELS = $clog2(ROWS);
    localparam int LATENCY = LEVELS + 1;
    localparam int DEPTH = 1 << $clog2(LATENCY + 2);
    localparam int PTRW = $clog2(DEPTH);
    localparam int COUNTW = $clog2(DEPTH + 1);
    logic [COUNTW-1:0] owned_q, count_q;
    logic [PTRW-1:0] wr_ptr_q, rd_ptr_q, admit_ptr_q;
    wire fire = input_valid && input_ready;
    wire pop = result_valid && result_ready;
    wire [ROWS-1:0][COLS-1:0][15:0] weights;
    wire [COLS-1:0][ROWS-1:0] product_ready;
    wire [COLS-1:0][ROWS-1:0][31:0] tree_data [LEVELS+1];
    wire [COLS-1:0][ROWS-1:0] tree_valid [LEVELS+1];
    logic [COLS-1:0][31:0] result_mem [DEPTH];
    gemm_input_ctrl_t ctrl_mem [DEPTH];
    wire push = tree_valid[LEVELS][0][0];

    `VX_STATIC_ASSERT(ROWS >= 1 && (ROWS & (ROWS-1)) == 0,
        ("FPFP reduction dimension must be a power of two"))
    `VX_STATIC_ASSERT(COLS >= 1 && (COLS & (COLS-1)) == 0,
        ("FPFP output dimension must be a power of two"))
    `VX_STATIC_ASSERT(LOAD_ROWS > 0 && ROWS % LOAD_ROWS == 0,
        ("FPFP weight load grouping must divide MXU_ROW"))
    assign input_ready = ((owned_q < COUNTW'(DEPTH)) || pop) && (&product_ready);
    assign result_valid = count_q != 0;
    assign result_data = result_mem[rd_ptr_q];
    assign result_ctrl = ctrl_mem[rd_ptr_q];
    assign idle = owned_q == 0;
    assign weight_bus_if.req_ready = 1'b1;
    assign weight_bus_if.rsp_valid = 1'b0;
    assign weight_bus_if.rsp_data = '0;
    assign weight_install = weight_bus_if.req_valid && weight_bus_if.req_ready;

    VX_gemm_weight_regs_v1 #(
        .ROW_SIZE(ROWS), .COL_SIZE(COLS), .WEIGHT_DW(16),
        .WEIGHT_LOAD_ROW_NUM(LOAD_ROWS), .WEIGHT_LOAD_COL_NUM(LOAD_ROWS),
        .ROW_ONLY(1)
    ) weight_regs (
        .clk_i(clk), .weight_i(weight_bus_if.req_data.data),
        .ready_weight_i(weight_install), .weight_load_dir_i(1'b0),
        .in_weight_sel_i(weight_bus_if.req_data.addr[0]),
        .out_weight_sel_i(input_ctrl.wreg_use_idx), .weight_o(weights)
    );

    for (genvar c = 0; c < COLS; ++c) begin : g_column
        for (genvar k = 0; k < ROWS; ++k) begin : g_product
            wire ar, br;
            assign product_ready[c][k] = ar && br;
            VX_fp32_mul #(.LATENCY(1), .OUT_BUF(0), .USE_LATENCY1_IP(1)) mul (
                .clk(clk), .reset(reset),
                .a_valid(fire), .a_ready(ar), .a_data(vx_fp16_to_fp32(input_data[k])),
                .b_valid(fire), .b_ready(br), .b_data(vx_fp16_to_fp32(weights[k][c])),
                .result_valid(tree_valid[0][c][k]), .result_ready(1'b1),
                .result_data(tree_data[0][c][k])
            );
`ifndef SYNTHESIS
            always_ff @(posedge clk) if (!reset && fire)
                assert (ar && br) else $fatal(1, "%s: FPFP multiplier stalled", INSTANCE_ID);
`endif
        end
        for (genvar l = 0; l < LEVELS; ++l) begin : g_level
            for (genvar k = 0; k < ROWS; ++k) begin : g_pair
                if (k < (ROWS >> (l+1))) begin : g_active
                    wire ar, br;
                    VX_fp32_add #(.LATENCY(1), .OUT_BUF(0), .USE_LATENCY1_IP(1)) add (
                        .clk(clk), .reset(reset),
                        .a_valid(tree_valid[l][c][2*k]), .a_ready(ar),
                        .a_data(tree_data[l][c][2*k]),
                        .b_valid(tree_valid[l][c][2*k+1]), .b_ready(br),
                        .b_data(tree_data[l][c][2*k+1]),
                        .result_valid(tree_valid[l+1][c][k]), .result_ready(1'b1),
                        .result_data(tree_data[l+1][c][k])
                    );
`ifndef SYNTHESIS
                    always_ff @(posedge clk) if (!reset && tree_valid[l][c][2*k])
                        assert (ar && br) else $fatal(1, "%s: FPFP adder stalled", INSTANCE_ID);
`endif
                end else begin : g_unused
                    assign tree_valid[l+1][c][k] = 1'b0;
                    assign tree_data[l+1][c][k] = '0;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            owned_q <= '0;
            count_q <= '0;
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            admit_ptr_q <= '0;
        end else begin
            // Operators preserve order; metadata follows admission sequence,
            // not a backend-specific guess at arithmetic latency.
            if (fire) begin
                ctrl_mem[admit_ptr_q] <= input_ctrl;
                admit_ptr_q <= admit_ptr_q + 1'b1;
            end
            case ({fire, pop})
                2'b10: owned_q <= owned_q + 1'b1;
                2'b01: owned_q <= owned_q - 1'b1;
                default:;
            endcase
            case ({push, pop})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default:;
            endcase
            if (push) begin
                for (int c = 0; c < COLS; ++c)
                    result_mem[wr_ptr_q][c] <= tree_data[LEVELS][c][0];
                wr_ptr_q <= wr_ptr_q + 1'b1;
            end
            if (pop) rd_ptr_q <= rd_ptr_q + 1'b1;
`ifndef SYNTHESIS
            for (int c = 0; c < COLS; ++c)
                assert (tree_valid[LEVELS][c][0] == push)
                    else $fatal(1, "%s: FPFP column-valid mismatch", INSTANCE_ID);
            assert (!push || count_q < DEPTH || pop)
                else $fatal(1, "%s: FPFP result FIFO full", INSTANCE_ID);
            assert (!push || owned_q > count_q)
                else $fatal(1, "%s: FPFP result has no admitted owner", INSTANCE_ID);
            assert (count_q <= owned_q && owned_q <= DEPTH)
                else $fatal(1, "%s: FPFP result credit overflow", INSTANCE_ID);
`endif
        end
    end
`ifdef DBG_TRACE_GEMM
    always_ff @(posedge clk) begin
        if (!reset && fire)
            `TRACE(2, ("%s: FPFP input work=%0d acc_tag=%0d bank=%0d\n",
                INSTANCE_ID, input_ctrl.work_seq, input_ctrl.acc_txn_tag, input_ctrl.wreg_use_idx))
        if (!reset && pop)
            `TRACE(2, ("%s: FPFP result work=%0d acc_tag=%0d\n",
                INSTANCE_ID, result_ctrl.work_seq, result_ctrl.acc_txn_tag))
    end
`endif
endmodule
`endif

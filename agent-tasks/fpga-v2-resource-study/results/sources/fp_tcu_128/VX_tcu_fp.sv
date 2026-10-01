module VX_tcu_fp import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter  INSTANCE_ID = ""
) (
    input wire          clk,
    input wire          reset,
    VX_execute_if.slave execute_if,
    VX_result_if.master result_if
);
    ;
    localparam MDATA_WIDTH = UUID_WIDTH + NW_WIDTH + PC_BITS + NUM_REGS_BITS;
    localparam FCVT_LATENCY = 1;
    localparam FMUL_LATENCY = 8;
    localparam FADD_LATENCY = 11;
    localparam FACC_LATENCY = $clog2(2 * TCU_TC_K + 1) * FADD_LATENCY;
    localparam FEDP_LATENCY = FCVT_LATENCY + FMUL_LATENCY + FACC_LATENCY;
    localparam PIPE_LATENCY = FEDP_LATENCY + 1;
    localparam MDATA_QUEUE_DEPTH = 1 << $clog2(PIPE_LATENCY);
    localparam LG_A_BS = $clog2(TCU_A_BLOCK_SIZE);
    localparam LG_B_BS = $clog2(TCU_B_BLOCK_SIZE);
    localparam OFF_W   = $clog2(TCU_BLOCK_CAP);
    wire [3:0] step_m = execute_if.data.op_args.tcu.step_m;
    wire [3:0] step_n = execute_if.data.op_args.tcu.step_n;
    wire [3:0] fmt_s = execute_if.data.op_args.tcu.fmt_s;
    wire [3:0] fmt_d = execute_if.data.op_args.tcu.fmt_d;
    ;
    wire [MDATA_WIDTH-1:0] mdata_queue_din, mdata_queue_dout;
    wire mdata_queue_full;
    assign mdata_queue_din = {
        execute_if.data.uuid,
        execute_if.data.wid,
        execute_if.data.PC,
        execute_if.data.rd
    };
    wire execute_fire = execute_if.valid && execute_if.ready;
    wire result_fire = result_if.valid && result_if.ready;
    wire fedp_enable, fedp_done;
    reg [PIPE_LATENCY-1:0] fedp_delay_pipe;
    always @(posedge clk) begin
        if (reset) begin
            fedp_delay_pipe <= '0;
        end else begin
            if (fedp_enable) begin
                fedp_delay_pipe <= fedp_delay_pipe >> 1;
            end
            if (execute_fire) begin
                fedp_delay_pipe[PIPE_LATENCY-1] <= 1;
            end
        end
    end
    assign fedp_done = fedp_delay_pipe[0];
    assign result_if.valid  = fedp_done;
    assign fedp_enable      = ~result_if.valid || result_if.ready;
    assign execute_if.ready = ~mdata_queue_full && fedp_enable;
    VX_fifo_queue #(
        .DATAW (MDATA_WIDTH),
        .DEPTH (MDATA_QUEUE_DEPTH),
        .OUT_REG (1)
    ) mdata_queue (
        .clk    (clk),
        .reset  (reset),
        .push   (execute_fire),
        .pop    (result_fire),
        .data_in(mdata_queue_din),
        .data_out(mdata_queue_dout),
        . empty (),
        . alm_empty (),
        .full   (mdata_queue_full),
        . alm_full (),
        . size ()
    );
    wire [OFF_W-1:0] a_off = (OFF_W'(step_m) & OFF_W'(TCU_A_SUB_BLOCKS-1)) << LG_A_BS;
    wire [OFF_W-1:0] b_off = (OFF_W'(step_n) & OFF_W'(TCU_B_SUB_BLOCKS-1)) << LG_B_BS;
    wire [TCU_TC_M-1:0][TCU_TC_N-1:0][64-1:0] d_val;
    for (genvar i = 0; i < TCU_TC_M; ++i) begin : g_i
        for (genvar j = 0; j < TCU_TC_N; ++j) begin : g_j
            wire [TCU_TC_K-1:0][64-1:0] a_row = execute_if.data.rs1_data[a_off + i * TCU_TC_K +: TCU_TC_K];
            wire [TCU_TC_K-1:0][64-1:0] b_col = execute_if.data.rs2_data[b_off + j * TCU_TC_K +: TCU_TC_K];
            wire [64-1:0] c_val = execute_if.data.rs3_data[i * TCU_TC_N + j];
            wire [2:0] fmt_s_r, fmt_d_r;
            wire [TCU_TC_K-1:0][64-1:0] a_row_r, b_col_r;
            wire [64-1:0] c_val_r;
    VX_pipe_register #( 
        .DATAW  ($bits({a_row_r, b_col_r, c_val_r, fmt_s_r,    fmt_d_r})), 
        .RESETW (0), 
        .DEPTH  (1) 
    ) __buffer_ex150 ( 
        .clk      (clk), 
        .reset    (reset), 
        .enable   (fedp_enable), 
        .data_in  ({a_row,   b_col,   c_val,   fmt_s[2:0], fmt_d[2:0]}), 
        .data_out ({a_row_r, b_col_r, c_val_r, fmt_s_r,    fmt_d_r}) 
    );
            VX_tcu_fedp_dsp #(
                .LATENCY (FEDP_LATENCY),
                .N (TCU_TC_K)
            ) fedp (
                .clk   (clk),
                .reset (reset),
                .enable(fedp_enable),
                .fmt_s (fmt_s_r),
                .fmt_d (fmt_d_r),
                .a_row (a_row_r),
                .b_col (b_col_r),
                .c_val (c_val_r),
                .d_val (d_val[i][j])
            );
        end
    end
    assign result_if.data.wb  = 1;
    assign result_if.data.tmask = {16{1'b1}};
    assign result_if.data.data  = d_val;
    assign result_if.data.pid = 0;
    assign result_if.data.sop = 1;
    assign result_if.data.eop = 1;
    assign {
        result_if.data.uuid,
        result_if.data.wid,
        result_if.data.PC,
        result_if.data.rd
    } = mdata_queue_dout;
endmodule

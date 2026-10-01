module VX_reduce_tree_pipelined_v2 #(
    parameter IN_W  = 1,
    parameter OUT_W = IN_W,
    parameter N     = 1,
    parameter  OP = "+",
    parameter PIPELINE_STAGES = 0,   
    parameter EB_SIZE = 1,           
    parameter EB_OUT_REG = 1         
) (
    input  wire clk,
    input  wire reset,
    input  wire [N-1:0][IN_W-1:0] data_in,
    input  wire valid_in,
    output wire [OUT_W-1:0] data_out,
    output wire valid_out
);
    localparam NUM_STAGES = (N > 1) ? $clog2(N) : 1;
    localparam MAX_N      = N;   
    if (N == 1) begin : g_passthru
        assign data_out  = OUT_W'(data_in[0]);
        assign valid_out = valid_in;
    end else begin : g_reduce
        wire [MAX_N-1:0][OUT_W-1:0] stage_data_in  [NUM_STAGES];
        wire [MAX_N-1:0][OUT_W-1:0] stage_data_out [NUM_STAGES];
        wire                        stage_valid_in [NUM_STAGES];
        wire                        stage_valid_out[NUM_STAGES];
        for (genvar i = 0; i < N; i++) begin : g_input
            assign stage_data_in[0][i] = OUT_W'($signed(data_in[i]));
        end
        for (genvar i = N; i < MAX_N; i++) begin : g_input_pad
            assign stage_data_in[0][i] = '0;
        end
        assign stage_valid_in[0] = valid_in;
        for (genvar s = 1; s < NUM_STAGES; s++) begin : g_connect
            for (genvar i = 0; i < MAX_N; i++) begin : g_connect_data
                assign stage_data_in[s][i] = stage_data_out[s-1][i];
            end
            assign stage_valid_in[s] = stage_valid_out[s-1];
        end
        for (genvar s = 0; s < NUM_STAGES; s++) begin : g_stage
            localparam int CURR_N = (N + (1 << s) - 1) >> s;   
            localparam int NEXT_N = (CURR_N + 1) >> 1;         
            wire [MAX_N-1:0][OUT_W-1:0] reduce_result;
            wire                        reduce_valid;
            for (genvar i = 0; i < CURR_N / 2; i++) begin : g_pair
                if (OP == "+") begin : g_op
                    (* use_dsp = "yes" *) logic signed [OUT_W-1:0] pair_sum;
                    assign pair_sum = signed'(stage_data_in[s][2*i]) + signed'(stage_data_in[s][2*i + 1]);
                    assign reduce_result[i] = pair_sum;
                end else if (OP == "^") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] ^ stage_data_in[s][2*i + 1];
                end else if (OP == "&") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] & stage_data_in[s][2*i + 1];
                end else if (OP == "|") begin : g_op
                    assign reduce_result[i] = stage_data_in[s][2*i] | stage_data_in[s][2*i + 1];
                end else begin : g_error
                    ;
                end
            end
            if (CURR_N % 2 == 1) begin : g_odd
                assign reduce_result[CURR_N / 2] = stage_data_in[s][CURR_N - 1];
            end
            for (genvar i = NEXT_N; i < MAX_N; i++) begin : g_pad
                assign reduce_result[i] = '0;
            end
            assign reduce_valid = stage_valid_in[s];
            if ((PIPELINE_STAGES & (1 << s)) != 0) begin : g_piped
                wire [NEXT_N * OUT_W - 1:0] pipe_data_in;
                wire [NEXT_N * OUT_W - 1:0] pipe_data_out;
                wire                        pipe_valid_out;
                for (genvar i = 0; i < NEXT_N; i++) begin : g_pack
                    assign pipe_data_in[i * OUT_W +: OUT_W] = reduce_result[i];
                end
                VX_elastic_buffer #(
                    .DATAW   (NEXT_N * OUT_W),
                    .SIZE    (EB_SIZE),
                    .OUT_REG (EB_OUT_REG),
                    .LUTRAM  (0)
                ) u_stage_pipe (
                    .clk       (clk),
                    .reset     (reset),
                    .valid_in  (reduce_valid),
                    .ready_in  ( ),
                    .data_in   (pipe_data_in),
                    .data_out  (pipe_data_out),
                    .ready_out (1'b1),
                    .valid_out (pipe_valid_out)
                );
                for (genvar i = 0; i < NEXT_N; i++) begin : g_unpack
                    assign stage_data_out[s][i] = pipe_data_out[i * OUT_W +: OUT_W];
                end
                for (genvar i = NEXT_N; i < MAX_N; i++) begin : g_unpack_pad
                    assign stage_data_out[s][i] = '0;
                end
                assign stage_valid_out[s] = pipe_valid_out;
            end else begin : g_bypass
                for (genvar i = 0; i < MAX_N; i++) begin : g_direct
                    assign stage_data_out[s][i] = reduce_result[i];
                end
                assign stage_valid_out[s] = reduce_valid;
            end
        end
        assign data_out  = stage_data_out[NUM_STAGES - 1][0];
        assign valid_out = stage_valid_out[NUM_STAGES - 1];
    end
endmodule

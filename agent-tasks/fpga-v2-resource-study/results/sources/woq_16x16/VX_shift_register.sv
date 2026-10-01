module VX_shift_register #(
    parameter DATAW      = 1,
    parameter RESETW     = 0,
    parameter DEPTH      = 1,
    parameter NUM_TAPS   = 1,
    parameter TAP_START  = (DEPTH-1),
    parameter TAP_STRIDE = 1,
    parameter [(((RESETW) > 0) ? (RESETW) : 1)-1:0] INIT_VALUE = {(((RESETW) > 0) ? (RESETW) : 1){1'b0}}
) (
    input wire                         clk,
    input wire                         reset,
    input wire                         enable,
    input wire [DATAW-1:0]             data_in,
    output wire [NUM_TAPS-1:0][DATAW-1:0] data_out
);
    ;
    if (DEPTH == 0) begin : g_passthru
        assign data_out = data_in;
    end else begin : g_shift
        logic [DEPTH-1:0][DATAW-1:0] pipe;
        if (RESETW == DATAW) begin : g_full_reset
            for (genvar i = 0; i < DEPTH; ++i) begin : g_stages
                if (i == 0) begin : g_stage_0
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            pipe[i] <= INIT_VALUE;
                        end else if (enable) begin
                            pipe[i] <= data_in;
                        end
                    end
                end else begin : g_stage_n
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            pipe[i] <= INIT_VALUE;
                        end else if (enable) begin
                            pipe[i] <= pipe[i-1];
                        end
                    end
                end
            end
        end else if (RESETW != 0) begin : g_partial_reset
            for (genvar i = 0; i < DEPTH; ++i) begin : g_stages
                if (i == 0) begin : g_stage_0
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            pipe[i][DATAW-1 : DATAW-RESETW] <= INIT_VALUE;
                        end else if (enable) begin
                            pipe[i][DATAW-1 : DATAW-RESETW] <= data_in[DATAW-1 : DATAW-RESETW];
                        end
                    end
                    always_ff @(posedge clk) begin
                        if (enable) begin
                            pipe[i][DATAW-RESETW-1 : 0] <= data_in[DATAW-RESETW-1 : 0];
                        end
                    end
                end else begin : g_stage_n
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            pipe[i][DATAW-1 : DATAW-RESETW] <= INIT_VALUE;
                        end else if (enable) begin
                            pipe[i][DATAW-1 : DATAW-RESETW] <= pipe[i-1][DATAW-1 : DATAW-RESETW];
                        end
                    end
                    always_ff @(posedge clk) begin
                        if (enable) begin
                            pipe[i][DATAW-RESETW-1 : 0] <= pipe[i-1][DATAW-RESETW-1 : 0];
                        end
                    end
                end
            end
        end else begin : g_no_reset
            for (genvar i = 0; i < DEPTH; ++i) begin : g_stages
                if (i == 0) begin : g_stage_0
                    always_ff @(posedge clk) begin
                        if (enable) begin
                            pipe[i] <= data_in;
                        end
                    end
                end else begin : g_stage_n
                    always_ff @(posedge clk) begin
                        if (enable) begin
                            pipe[i] <= pipe[i-1];
                        end
                    end
                end
            end
        end
        for (genvar i = 0; i < NUM_TAPS; ++i) begin : g_taps
            assign data_out[i] = pipe[i * TAP_STRIDE + TAP_START];
        end
    end
endmodule

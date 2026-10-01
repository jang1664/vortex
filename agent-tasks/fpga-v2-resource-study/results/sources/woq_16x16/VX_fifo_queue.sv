module VX_fifo_queue #(
    parameter DATAW     = 32,
    parameter DEPTH     = 32,
    parameter ALM_FULL  = (DEPTH - 1),
    parameter ALM_EMPTY = 1,
    parameter OUT_REG   = 0,
    parameter LUTRAM    = 0,
    parameter SIZEW     = $clog2(DEPTH+1)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             push,
    input  wire             pop,
    input  wire [DATAW-1:0] data_in,
    output wire [DATAW-1:0] data_out,
    output wire             empty,
    output wire             alm_empty,
    output wire             full,
    output wire             alm_full,
    output wire [SIZEW-1:0] size
);
    VX_pending_size #(
        .SIZE      (DEPTH),
        .ALM_EMPTY (ALM_EMPTY),
        .ALM_FULL  (ALM_FULL)
    ) pending_size (
        .clk   (clk),
        .reset (reset),
        .incr  (push),
        .decr  (pop),
        .empty (empty),
        .full  (full),
        .alm_empty(alm_empty),
        .alm_full(alm_full),
        .size  (size)
    );
    if (DEPTH == 1) begin : g_depth_1
        reg [DATAW-1:0] head_r;
        always @(posedge clk) begin
            if (push) begin
                head_r <= data_in;
            end
        end
        assign data_out = head_r;
    end else begin : g_depth_n
        localparam ADDRW = $clog2(DEPTH);
        wire [DATAW-1:0] data_out_w;
        reg [ADDRW-1:0] rd_ptr_r;
        reg [ADDRW-1:0] wr_ptr_r;
        always @(posedge clk) begin
            if (reset) begin
                wr_ptr_r <= '0;
                rd_ptr_r <= (OUT_REG != 0) ? 1 : 0;
            end else begin
                wr_ptr_r <= wr_ptr_r + ADDRW'(push);
                rd_ptr_r <= rd_ptr_r + ADDRW'(pop);
            end
        end
        VX_dp_ram #(
            .DATAW (DATAW),
            .SIZE  (DEPTH),
            .LUTRAM (LUTRAM),
            .RDW_MODE ("W"),
            .RADDR_REG (1),
            .RADDR_RESET (1)
        ) dp_ram (
            .clk   (clk),
            .reset (reset),
            .read  (1'b1),
            .write (push),
            .wren  (1'b1),
            .raddr (rd_ptr_r),
            .waddr (wr_ptr_r),
            .wdata (data_in),
            .rdata (data_out_w)
        );
        if (OUT_REG != 0) begin : g_out_reg
            reg [DATAW-1:0] data_out_r;
            wire going_empty = (ALM_EMPTY == 1) ? alm_empty : (size[ADDRW-1:0] == ADDRW'(1));
            wire bypass = push && (empty || (going_empty && pop));
            always @(posedge clk) begin
                if (bypass) begin
                    data_out_r <= data_in;
                end else if (pop) begin
                    data_out_r <= data_out_w;
                end
            end
            assign data_out = data_out_r;
        end else begin : g_no_out_reg
            assign data_out = data_out_w;
        end
    end
endmodule

`include "VX_define.vh"

`ifdef GEMM_SRAM_FUSION
// One vector request is owned locally while its active lanes access a scalar
// MMIO bus in ascending lane order. Only one read is outstanding; responses
// return as one-hot partial LSU packets, so no vector response buffer is needed.
module VX_mmio_serializer #(
    parameter `STRING INSTANCE_ID = "",
    parameter int NUM_LANES = `NUM_LSU_LANES
) (
    input wire clk,
    input wire reset,
    VX_lsu_mem_if.slave source_if,
    VX_lsu_mem_if.master scalar_if,
    output wire owned_o
);
    localparam int ADDRW = $bits(source_if.req_data.addr[0]);
    localparam int DATAW = $bits(source_if.req_data.data[0]);
    localparam int BYTEW = $bits(source_if.req_data.byteen[0]);
    localparam int FLAGW = $bits(source_if.req_data.flags[0]);
    localparam int TAGW = $bits(source_if.req_data.tag);
    localparam int LANEW = `LOG2UP(NUM_LANES);

    logic [NUM_LANES-1:0] pending_q;
    logic read_wait_q;
    logic write_q;
    logic [NUM_LANES-1:0][ADDRW-1:0] addr_q;
    logic [NUM_LANES-1:0][DATAW-1:0] data_q;
    logic [NUM_LANES-1:0][BYTEW-1:0] byteen_q;
    logic [NUM_LANES-1:0][FLAGW-1:0] flags_q;
    logic [TAGW-1:0] tag_q;
    wire [NUM_LANES-1:0] selected_mask;
    wire [LANEW-1:0] selected_lane;
    wire active;

    VX_priority_encoder #(.N(NUM_LANES)) u_lane_select (
        .data_in(pending_q), .onehot_out(selected_mask),
        .index_out(selected_lane), .valid_out(active)
    );

    assign source_if.req_ready = !reset && !active;
    assign scalar_if.req_valid = !reset && active && !read_wait_q;
    assign scalar_if.req_data.mask = 1'b1;
    assign scalar_if.req_data.rw = write_q;
    assign scalar_if.req_data.addr[0] = addr_q[selected_lane];
    assign scalar_if.req_data.data[0] = data_q[selected_lane];
    assign scalar_if.req_data.byteen[0] = byteen_q[selected_lane];
    assign scalar_if.req_data.flags[0] = flags_q[selected_lane];
    assign scalar_if.req_data.tag = tag_q;

    assign source_if.rsp_valid = !reset && read_wait_q && scalar_if.rsp_valid;
    assign source_if.rsp_data.mask = selected_mask;
    assign source_if.rsp_data.tag = tag_q;
    // Inactive response lanes are ignored under mask; broadcast avoids a wide
    // data demultiplexer and retains only the scalar payload across the link.
    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_response
        assign source_if.rsp_data.data[lane] = scalar_if.rsp_data.data[0];
    end
    assign scalar_if.rsp_ready = !reset && read_wait_q && source_if.rsp_ready;
    assign owned_o = !reset && (source_if.req_valid || active);

    wire capture = source_if.req_valid && source_if.req_ready;
    wire issue = scalar_if.req_valid && scalar_if.req_ready;
    wire respond = source_if.rsp_valid && source_if.rsp_ready;
    always_ff @(posedge clk) begin
        if (reset) begin
            pending_q <= '0;
            read_wait_q <= 1'b0;
        end else begin
            if (capture)
                pending_q <= source_if.req_data.mask;
            else if ((issue && write_q) || respond)
                pending_q <= pending_q & ~selected_mask;
            if (issue && !write_q)
                read_wait_q <= 1'b1;
            else if (respond)
                read_wait_q <= 1'b0;
        end
        if (capture) begin
            write_q <= source_if.req_data.rw;
            addr_q <= source_if.req_data.addr;
            data_q <= source_if.req_data.data;
            byteen_q <= source_if.req_data.byteen;
            flags_q <= source_if.req_data.flags;
            tag_q <= source_if.req_data.tag;
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert ($bits(source_if.req_data.mask) == NUM_LANES
             && $bits(scalar_if.req_data.mask) == 1
             && $bits(scalar_if.req_data.data[0]) == DATAW
             && $bits(scalar_if.req_data.tag) == TAGW)
            else $fatal(1, "%s: scalar MMIO interface width mismatch", INSTANCE_ID);
    end
    always_ff @(posedge clk) if (!reset && scalar_if.rsp_valid) begin
        assert (read_wait_q && scalar_if.rsp_data.mask == 1'b1
             && scalar_if.rsp_data.tag == tag_q)
            else $fatal(1, "%s: unexpected scalar MMIO response", INSTANCE_ID);
    end
`endif
    `UNUSED_SPARAM (INSTANCE_ID)
endmodule
`endif

`include "VX_define.vh"

`ifdef GEMM_NAIVE
// A finite join of producer closure and actual owned source-read completion.
// Each engine reports once per descriptor, in any response order, after every
// source response is in owned transport storage. Installation is independent.
module VX_naive_source_join import VX_gpu_pkg::*; (
    input wire clk,
    input wire reset,
    input wire invocation_start,
    input wire closed_valid,
    input wire closed_buffer,
    input wire [31:0] closed_generation,
    input wire [31:0] closed_count,
    input wire [3:0] read_done_valid,
    input wire [31:0] read_done_work_seq [4],
    output logic [1:0] source_free_valid,
    output wire [31:0] source_free_generation [2],
    output wire quiescent
);
    localparam int MAX_MICROS = (`GEMM_FSM_KT / `GEMM_FSM_MXU_KT)
                             * (`GEMM_FSM_NT / `GEMM_FSM_MXU_NT);
    localparam int COUNTW = $clog2(MAX_MICROS + 1);
    typedef struct packed {
        logic valid, closed, published;
        logic [31:0] generation;
        logic [COUNTW-1:0] expected;
        logic [3:0][MAX_MICROS-1:0] captured;
    } owner_t;
    owner_t owner_q [2], owner_next [2];
    logic closed_valid_q, closed_buffer_q;
    logic [31:0] closed_generation_q, closed_count_q;
    logic [3:0] read_done_valid_q;
    logic [31:0] read_done_work_seq_q [4];
    wire [31:0] read_tile [4];
    wire [COUNTW-1:0] read_index [4];
    wire [31:0] read_generation [4];
    wire [3:0] read_buffer;
    logic protocol_error;
    logic [1:0] publish;
    for (genvar e = 0; e < 4; ++e) begin : g_identity
        assign read_tile[e] = (read_done_work_seq_q[e] - 32'd1) / MAX_MICROS;
        assign read_index[e] = COUNTW'((read_done_work_seq_q[e] - 32'd1) % MAX_MICROS);
        assign read_generation[e] = (read_tile[e] >> 1) + 32'd1;
        assign read_buffer[e] = read_tile[e][0];
    end
    for (genvar b = 0; b < 2; ++b) begin : g_generation
        assign source_free_generation[b] = owner_q[b].generation;
    end
    assign quiescent = (!owner_q[0].valid || owner_q[0].published)
                    && (!owner_q[1].valid || owner_q[1].published)
                    && !(|source_free_valid)
                    && !closed_valid_q && !(|read_done_valid_q);

    // Delay closure and completion together, preserving same-cycle validation.
    // Keep the full count here so malformed values cannot truncate to legal ones.
    always_ff @(posedge clk) begin
        if (reset || invocation_start) begin
            closed_valid_q <= 1'b0;
            read_done_valid_q <= '0;
        end else begin
            closed_valid_q <= closed_valid;
            read_done_valid_q <= read_done_valid;
        end
        closed_buffer_q <= closed_buffer;
        closed_generation_q <= closed_generation;
        closed_count_q <= closed_count;
        read_done_work_seq_q <= read_done_work_seq;
    end

    always_comb begin
        protocol_error = 1'b0;
        publish = '0;
        for (int e = 0; e < 4; ++e) begin
            if (read_done_valid_q[e] && read_done_work_seq_q[e] == 0)
                protocol_error = 1'b1;
        end
        if (closed_valid_q && (closed_generation_q == 0 || closed_count_q == 0
            || closed_count_q > MAX_MICROS))
            protocol_error = 1'b1;
        for (int b = 0; b < 2; ++b) begin : g_update
            logic event_valid;
            logic [31:0] event_generation;
            logic complete;
            logic [MAX_MICROS-1:0] expected_mask;
            owner_next[b] = owner_q[b];
            event_valid = closed_valid_q && closed_buffer_q == 1'(b);
            event_generation = event_valid ? closed_generation_q : 32'd0;
            for (int e = 0; e < 4; ++e) begin
                if (read_done_valid_q[e] && read_buffer[e] == 1'(b)) begin
                    if (event_valid && event_generation != read_generation[e])
                        protocol_error = 1'b1;
                    event_valid = 1'b1;
                    event_generation = read_generation[e];
                end
            end
            if (event_valid) begin
                if (!owner_q[b].valid || owner_q[b].published) begin
                    if (event_generation != (owner_q[b].valid ? owner_q[b].generation + 32'd1 : 32'd1)
                        || (owner_q[b].valid && owner_q[b].generation == 32'hffffffff))
                        protocol_error = 1'b1;
                    owner_next[b] = '0;
                    owner_next[b].valid = 1'b1;
                    owner_next[b].generation = event_generation;
                end else if (event_generation != owner_q[b].generation) begin
                    protocol_error = 1'b1;
                end
                if (closed_valid_q && closed_buffer_q == 1'(b)) begin
                    if (owner_next[b].closed)
                        protocol_error = 1'b1;
                    owner_next[b].closed = 1'b1;
                    owner_next[b].expected = COUNTW'(closed_count_q);
                end
                for (int e = 0; e < 4; ++e) begin
                    if (read_done_valid_q[e] && read_buffer[e] == 1'(b)) begin
                        if (owner_next[b].captured[e][read_index[e]])
                            protocol_error = 1'b1;
                        owner_next[b].captured[e][read_index[e]] = 1'b1;
                    end
                end
            end
            complete = owner_next[b].valid && owner_next[b].closed && !owner_next[b].published;
            expected_mask = {MAX_MICROS{1'b1}} >> (MAX_MICROS - int'(owner_next[b].expected));
            for (int e = 0; e < 4; ++e) begin
                if (owner_next[b].closed && (|(owner_next[b].captured[e] & ~expected_mask)))
                    protocol_error = 1'b1;
                complete &= owner_next[b].captured[e] == expected_mask;
            end
            if (complete) begin
                owner_next[b].published = 1'b1;
                publish[b] = 1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (reset || invocation_start) begin
            owner_q <= '{default:'0};
            source_free_valid <= '0;
        end else begin
            // Malformed identities fail closed; assertions diagnose them in sim.
            source_free_valid <= protocol_error ? 2'b00 : publish;
            if (!protocol_error) begin
                owner_q <= owner_next;
            end
        end
`ifndef SYNTHESIS
        if (!reset) begin
            assert (!protocol_error) else $fatal(1, "Naive source join ownership/count violation");
            if (invocation_start)
                assert (quiescent && !closed_valid_q && !(|read_done_valid_q)
                    && !closed_valid && !(|read_done_valid))
                    else $fatal(1, "Naive source join invocation started before drain");
        end
`endif
    end
endmodule
`endif

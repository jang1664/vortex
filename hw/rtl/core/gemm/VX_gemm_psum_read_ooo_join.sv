// Copyright 2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0

`include "VX_define.vh"

// NAIVE PSUM read scatter and out-of-order lane-response join.
//
// Each accepted wide read owns one bounded physical response slot.  The slot
// ID, rather than the logical ACC tag, is sent to every LMEM lane.  Returning
// lanes therefore update a directly indexed slot/bitmap and cannot be mixed
// with lanes from another bank set.  A completed slot restores the original
// logical tag and enters a small response FIFO before the slot is reusable.
module VX_gemm_psum_read_ooo_join import VX_gpu_pkg::*; #(
    parameter NUM_LANES = 16,
    parameter LANE_DATA_SIZE = 8,
    parameter TAG_WIDTH = 1,
    parameter MEM_ADDR_WIDTH_P = `MEM_ADDR_WIDTH,
    parameter PHYS_RESPONSE_SLOTS = 4,
    parameter RESPONSE_FIFO_DEPTH = 2
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave wide_bus_if,
    VX_mem_bus_if.master lane_bus_if [NUM_LANES]
);
    localparam WIDE_DATA_SIZE = NUM_LANES * LANE_DATA_SIZE;
    localparam WIDE_DATA_W = WIDE_DATA_SIZE * 8;
    localparam LANE_DATA_W = LANE_DATA_SIZE * 8;
    localparam LANE_INDEX_W = `LOG2UP(NUM_LANES);
    localparam WIDE_ADDR_W = MEM_ADDR_WIDTH_P - `CLOG2(WIDE_DATA_SIZE);
    localparam LANE_ADDR_W = MEM_ADDR_WIDTH_P - `CLOG2(LANE_DATA_SIZE);
    localparam SLOT_W = `LOG2UP(PHYS_RESPONSE_SLOTS);
    localparam ORDER_W = SLOT_W + 1;
    localparam FIFO_DATA_W = TAG_WIDTH + WIDE_DATA_W;

    `VX_STATIC_ASSERT(NUM_LANES == 16,
        ("NAIVE PSUM OOO join requires sixteen physical lanes"))
    `VX_STATIC_ASSERT((NUM_LANES & (NUM_LANES - 1)) == 0,
        ("NAIVE PSUM OOO join lane count must be a power of two"))
    `VX_STATIC_ASSERT(PHYS_RESPONSE_SLOTS >= 2,
        ("NAIVE PSUM OOO join requires multiple response slots"))
    `VX_STATIC_ASSERT((PHYS_RESPONSE_SLOTS
                    & (PHYS_RESPONSE_SLOTS - 1)) == 0,
        ("NAIVE PSUM OOO join response slots must be a power of two"))
    `VX_STATIC_ASSERT(SLOT_W <= TAG_WIDTH,
        ("NAIVE PSUM OOO join slot ID does not fit the physical tag"))
    `VX_STATIC_ASSERT(RESPONSE_FIFO_DEPTH >= 2,
        ("NAIVE PSUM OOO join response FIFO depth must be at least two"))
    `VX_STATIC_ASSERT((RESPONSE_FIFO_DEPTH
                    & (RESPONSE_FIFO_DEPTH - 1)) == 0,
        ("NAIVE PSUM OOO join response FIFO depth must be a power of two"))

    logic [PHYS_RESPONSE_SLOTS-1:0] slot_valid;
    logic [PHYS_RESPONSE_SLOTS-1:0] slot_req_done;
    logic [PHYS_RESPONSE_SLOTS-1:0] slot_complete;
    logic [PHYS_RESPONSE_SLOTS-1:0] slot_set;
    logic [PHYS_RESPONSE_SLOTS-1:0][ORDER_W-1:0] slot_order;
    logic [PHYS_RESPONSE_SLOTS-1:0][WIDE_ADDR_W-1:0] slot_addr;
    logic [PHYS_RESPONSE_SLOTS-1:0][WIDE_DATA_W-1:0] slot_req_data;
    logic [PHYS_RESPONSE_SLOTS-1:0][WIDE_DATA_SIZE-1:0] slot_byteen;
    logic [PHYS_RESPONSE_SLOTS-1:0][MEM_FLAGS_WIDTH-1:0] slot_flags;
    logic [PHYS_RESPONSE_SLOTS-1:0][TAG_WIDTH-1:0] slot_logical_tag;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0] slot_req_pending;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0] slot_rsp_valid;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0][LANE_DATA_W-1:0]
        slot_rsp_data;

    logic [ORDER_W-1:0] alloc_order_r;
    logic [ORDER_W-1:0] issue_order_r;
    logic free_slot_valid;
    logic [SLOT_W-1:0] free_slot;
    logic issue_slot_valid;
    logic [SLOT_W-1:0] issue_slot;
    logic wide_req_fire;
    logic [NUM_LANES-1:0] lane_req_fire;
    logic issue_all_done;
    wire [NUM_LANES-1:0] lane_req_valid_mon;
    wire [NUM_LANES-1:0] lane_req_ready_mon;
    wire [NUM_LANES-1:0][LANE_ADDR_W-1:0] lane_req_addr_mon;
    wire [NUM_LANES-1:0][TAG_WIDTH-1:0] lane_req_tag_mon;
    wire [NUM_LANES-1:0] lane_rsp_valid_mon;
    wire [NUM_LANES-1:0][TAG_WIDTH-1:0] lane_rsp_tag_mon;
    wire [NUM_LANES-1:0][LANE_DATA_W-1:0] lane_rsp_data_mon;
    logic [NUM_LANES-1:0] lane_rsp_ready_int;

    always_comb begin
        free_slot_valid = 1'b0;
        free_slot = '0;
        issue_slot_valid = 1'b0;
        issue_slot = '0;
        for (int slot = 0; slot < PHYS_RESPONSE_SLOTS; ++slot) begin
            if (!free_slot_valid && !slot_valid[slot]) begin
                free_slot_valid = 1'b1;
                free_slot = SLOT_W'(slot);
            end
            if (!issue_slot_valid && slot_valid[slot]
             && !slot_req_done[slot]
             && (slot_order[slot] == issue_order_r)) begin
                issue_slot_valid = 1'b1;
                issue_slot = SLOT_W'(slot);
            end
        end
    end

    // A request is captured independently of physical lane ready.  This is a
    // registered capacity boundary, so LMEM ready cannot form a combinational
    // path back to the common-core Input admission path.
    assign wide_bus_if.req_ready = free_slot_valid
                                 && (wide_bus_if.req_valid
                                   ? !wide_bus_if.req_data.rw : 1'b1);
    assign wide_req_fire = wide_bus_if.req_valid && wide_bus_if.req_ready;

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_lane_req
        assign lane_bus_if[lane].req_valid
            = issue_slot_valid && slot_req_pending[issue_slot][lane];
        assign lane_bus_if[lane].req_data.rw = 1'b0;
        assign lane_bus_if[lane].req_data.addr
            = {slot_addr[issue_slot], LANE_INDEX_W'(lane)};
        assign lane_bus_if[lane].req_data.data
            = slot_req_data[issue_slot][lane*LANE_DATA_W +: LANE_DATA_W];
        assign lane_bus_if[lane].req_data.byteen
            = slot_byteen[issue_slot][lane*LANE_DATA_SIZE +: LANE_DATA_SIZE];
        assign lane_bus_if[lane].req_data.flags = slot_flags[issue_slot];
        assign lane_bus_if[lane].req_data.tag = TAG_WIDTH'(issue_slot);
        assign lane_req_fire[lane] = lane_bus_if[lane].req_valid
                                   && lane_bus_if[lane].req_ready;
        assign lane_req_valid_mon[lane] = lane_bus_if[lane].req_valid;
        assign lane_req_ready_mon[lane] = lane_bus_if[lane].req_ready;
        assign lane_req_addr_mon[lane] = lane_bus_if[lane].req_data.addr;
        assign lane_req_tag_mon[lane] = lane_bus_if[lane].req_data.tag;
        assign lane_rsp_valid_mon[lane] = lane_bus_if[lane].rsp_valid;
        assign lane_rsp_tag_mon[lane] = lane_bus_if[lane].rsp_data.tag;
        assign lane_rsp_data_mon[lane] = lane_bus_if[lane].rsp_data.data;
        assign lane_bus_if[lane].rsp_ready = lane_rsp_ready_int[lane];
    end
    assign issue_all_done = issue_slot_valid
                          && &(~slot_req_pending[issue_slot] | lane_req_fire);

    logic [NUM_LANES-1:0] lane_rsp_owned;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0] rsp_fire_by_slot;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0] slot_rsp_valid_next;
    logic [PHYS_RESPONSE_SLOTS-1:0][NUM_LANES-1:0][LANE_DATA_W-1:0]
        slot_rsp_data_next;

    always_comb begin
        lane_rsp_owned = '0;
        rsp_fire_by_slot = '0;
        slot_rsp_valid_next = slot_rsp_valid;
        slot_rsp_data_next = slot_rsp_data;

        for (int lane = 0; lane < NUM_LANES; ++lane) begin
            logic [SLOT_W-1:0] rsp_slot;
            logic lane_request_issued;
            rsp_slot = SLOT_W'(lane_rsp_tag_mon[lane]);
            // Physical lanes are independent: an accepted lane may respond
            // while other requests in the same wide slot remain stalled.
            // Include the request-fire cycle so a zero-latency lane backend
            // cannot lose a legitimately owned response.
            lane_request_issued
                = !slot_req_pending[rsp_slot][lane]
               || (issue_slot_valid
                && (issue_slot == rsp_slot)
                && lane_req_fire[lane]);
            if (lane_rsp_valid_mon[lane]) begin
                lane_rsp_owned[lane]
                    = (TAG_WIDTH'(rsp_slot) == lane_rsp_tag_mon[lane])
                   && slot_valid[rsp_slot]
                   && lane_request_issued
                   && !slot_complete[rsp_slot]
                   && !slot_rsp_valid[rsp_slot][lane];
                if (lane_rsp_owned[lane]) begin
                    rsp_fire_by_slot[rsp_slot][lane] = 1'b1;
                    slot_rsp_valid_next[rsp_slot][lane] = 1'b1;
                    slot_rsp_data_next[rsp_slot][lane]
                        = lane_rsp_data_mon[lane];
                end
            end
        end
    end

    assign lane_rsp_ready_int = lane_rsp_owned;

    logic complete_slot_valid;
    logic [SLOT_W-1:0] complete_slot;
    logic response_fifo_empty;
    logic response_fifo_full;
    logic response_fifo_push;
    logic response_fifo_pop;
    logic [FIFO_DATA_W-1:0] response_fifo_in;
    logic [FIFO_DATA_W-1:0] response_fifo_out;

    // A slot may enter the FIFO on the same cycle that its last skewed lane
    // arrives.  The next-value data array ensures that response payload is
    // included.  Slot state is cleared only by this successful FIFO push.
    always_comb begin
        complete_slot_valid = 1'b0;
        complete_slot = '0;
        for (int slot = 0; slot < PHYS_RESPONSE_SLOTS; ++slot) begin
            if (!complete_slot_valid && slot_valid[slot]
             && (slot_complete[slot] || (&slot_rsp_valid_next[slot]))) begin
                complete_slot_valid = 1'b1;
                complete_slot = SLOT_W'(slot);
            end
        end
    end

    assign response_fifo_pop = !response_fifo_empty && wide_bus_if.rsp_ready;
    assign response_fifo_push = complete_slot_valid
                              && (!response_fifo_full || response_fifo_pop);
    assign response_fifo_in = {
        slot_logical_tag[complete_slot],
        slot_rsp_data_next[complete_slot]
    };

    VX_fifo_queue #(
        .DATAW(FIFO_DATA_W),
        .DEPTH(RESPONSE_FIFO_DEPTH),
        .OUT_REG(1)
    ) response_fifo (
        .clk(clk),
        .reset(reset),
        .push(response_fifo_push),
        .pop(response_fifo_pop),
        .data_in(response_fifo_in),
        .data_out(response_fifo_out),
        .empty(response_fifo_empty),
        .alm_empty(),
        .full(response_fifo_full),
        .alm_full(),
        .size()
    );

    assign wide_bus_if.rsp_valid = !response_fifo_empty;
    assign {wide_bus_if.rsp_data.tag, wide_bus_if.rsp_data.data}
        = response_fifo_out;

    always_ff @(posedge clk) begin
        if (reset) begin
            slot_valid <= '0;
            slot_req_done <= '0;
            slot_complete <= '0;
            slot_set <= '0;
            slot_order <= '0;
            slot_addr <= '0;
            slot_req_data <= '0;
            slot_byteen <= '0;
            slot_flags <= '0;
            slot_logical_tag <= '0;
            slot_req_pending <= '0;
            slot_rsp_valid <= '0;
            slot_rsp_data <= '0;
            alloc_order_r <= '0;
            issue_order_r <= '0;
        end else begin
            if (wide_req_fire) begin
                slot_valid[free_slot] <= 1'b1;
                slot_req_done[free_slot] <= 1'b0;
                slot_complete[free_slot] <= 1'b0;
                slot_set[free_slot] <= wide_bus_if.req_data.addr[0];
                slot_order[free_slot] <= alloc_order_r;
                slot_addr[free_slot] <= wide_bus_if.req_data.addr;
                slot_req_data[free_slot] <= wide_bus_if.req_data.data;
                slot_byteen[free_slot] <= wide_bus_if.req_data.byteen;
                slot_flags[free_slot] <= wide_bus_if.req_data.flags;
                slot_logical_tag[free_slot] <= wide_bus_if.req_data.tag;
                slot_req_pending[free_slot] <= '1;
                slot_rsp_valid[free_slot] <= '0;
                slot_rsp_data[free_slot] <= '0;
                alloc_order_r <= alloc_order_r + 1'b1;
            end

            if (issue_slot_valid) begin
                slot_req_pending[issue_slot]
                    <= slot_req_pending[issue_slot] & ~lane_req_fire;
                if (issue_all_done) begin
                    slot_req_done[issue_slot] <= 1'b1;
                    issue_order_r <= issue_order_r + 1'b1;
                end
            end

            for (int slot = 0; slot < PHYS_RESPONSE_SLOTS; ++slot) begin
                if (|rsp_fire_by_slot[slot]) begin
                    slot_rsp_valid[slot] <= slot_rsp_valid_next[slot];
                    slot_rsp_data[slot] <= slot_rsp_data_next[slot];
                    if (&slot_rsp_valid_next[slot])
                        slot_complete[slot] <= 1'b1;
                end
            end

            if (response_fifo_push) begin
                slot_valid[complete_slot] <= 1'b0;
                slot_req_done[complete_slot] <= 1'b0;
                slot_complete[complete_slot] <= 1'b0;
                slot_req_pending[complete_slot] <= '0;
                slot_rsp_valid[complete_slot] <= '0;
                slot_rsp_data[complete_slot] <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    logic wide_rsp_stall_q;
    logic [TAG_WIDTH-1:0] wide_rsp_stall_tag_q;
    logic [WIDE_DATA_W-1:0] wide_rsp_stall_data_q;
    logic [NUM_LANES-1:0] lane_req_stall_q;
    logic [NUM_LANES-1:0][LANE_ADDR_W-1:0] lane_req_stall_addr_q;
    logic [NUM_LANES-1:0][TAG_WIDTH-1:0] lane_req_stall_tag_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            wide_rsp_stall_q <= 1'b0;
            wide_rsp_stall_tag_q <= '0;
            wide_rsp_stall_data_q <= '0;
            lane_req_stall_q <= '0;
            lane_req_stall_addr_q <= '0;
            lane_req_stall_tag_q <= '0;
        end else begin
            assert (!(wide_bus_if.req_valid && wide_bus_if.req_data.rw))
                else $fatal(1, "NAIVE PSUM OOO join accepted a write request");
            if (wide_req_fire) begin
                assert (&wide_bus_if.req_data.byteen)
                    else $fatal(1, "NAIVE PSUM OOO join requires all sixteen read lanes");
                assert (!slot_valid[free_slot])
                    else $fatal(1, "NAIVE PSUM OOO join reused a live slot");
            end
            if (issue_all_done) begin
                assert (slot_valid[issue_slot] && !slot_req_done[issue_slot])
                    else $fatal(1, "NAIVE PSUM OOO join request ownership lost");
            end
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                if (lane_rsp_valid_mon[lane]) begin
                    assert (lane_rsp_owned[lane])
                        else $fatal(1, "NAIVE PSUM OOO join duplicate/stale response lane=%0d tag=0x%0h",
                                    lane, lane_rsp_tag_mon[lane]);
                end
                if (lane_req_stall_q[lane]) begin
                    assert (lane_req_valid_mon[lane]
                         && (lane_req_addr_mon[lane]
                             == lane_req_stall_addr_q[lane])
                         && (lane_req_tag_mon[lane]
                             == lane_req_stall_tag_q[lane]))
                        else $fatal(1, "NAIVE PSUM OOO join lane request changed while held lane=%0d",
                                    lane);
                end
                lane_req_stall_q[lane] <= lane_req_valid_mon[lane]
                                       && !lane_req_ready_mon[lane];
                if (lane_req_valid_mon[lane]
                 && !lane_req_ready_mon[lane]) begin
                    lane_req_stall_addr_q[lane]
                        <= lane_req_addr_mon[lane];
                    lane_req_stall_tag_q[lane]
                        <= lane_req_tag_mon[lane];
                end
            end
            if (wide_rsp_stall_q) begin
                assert (wide_bus_if.rsp_valid
                     && (wide_bus_if.rsp_data.tag == wide_rsp_stall_tag_q)
                     && (wide_bus_if.rsp_data.data == wide_rsp_stall_data_q))
                    else $fatal(1, "NAIVE PSUM OOO join response changed while held");
            end
            wide_rsp_stall_q <= wide_bus_if.rsp_valid
                              && !wide_bus_if.rsp_ready;
            if (wide_bus_if.rsp_valid && !wide_bus_if.rsp_ready) begin
                wide_rsp_stall_tag_q <= wide_bus_if.rsp_data.tag;
                wide_rsp_stall_data_q <= wide_bus_if.rsp_data.data;
            end
            if (response_fifo_push) begin
                assert (slot_valid[complete_slot]
                     && (&slot_rsp_valid_next[complete_slot]))
                    else $fatal(1, "NAIVE PSUM OOO join pushed an incomplete slot");
                assert (slot_set[complete_slot]
                     == slot_addr[complete_slot][0])
                    else $fatal(1, "NAIVE PSUM OOO join slot set metadata changed");
            end
        end
    end
`endif

endmodule

`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_psum_read_ooo_join;
    localparam PERIOD = 10;
    localparam NUM_LANES = 16;
    localparam LANE_BYTES = 8;
    localparam WIDE_BYTES = NUM_LANES * LANE_BYTES;
    localparam TAGW = 16;
    localparam PHYS_SLOTS = 4;
    localparam FIFO_DEPTH = 2;
    localparam WIDE_ADDRW = `MEM_ADDR_WIDTH - `CLOG2(WIDE_BYTES);
    localparam LANE_ADDRW = `MEM_ADDR_WIDTH - `CLOG2(LANE_BYTES);

    logic clk;
    logic reset;

    VX_mem_bus_if #(
        .DATA_SIZE(WIDE_BYTES),
        .TAG_WIDTH(TAGW)
    ) wide_bus_if ();
    VX_mem_bus_if #(
        .DATA_SIZE(LANE_BYTES),
        .TAG_WIDTH(TAGW)
    ) lane_bus_if [NUM_LANES] ();

    logic [NUM_LANES-1:0] lane_req_ready_drv;
    logic [NUM_LANES-1:0] lane_rsp_valid_drv;
    logic [NUM_LANES-1:0][TAGW-1:0] lane_rsp_tag_drv;
    logic [NUM_LANES-1:0][LANE_BYTES*8-1:0] lane_rsp_data_drv;
    wire [NUM_LANES-1:0] lane_req_valid_mon;
    wire [NUM_LANES-1:0] lane_rsp_ready_mon;
    wire [NUM_LANES-1:0][LANE_ADDRW-1:0] lane_req_addr_mon;
    wire [NUM_LANES-1:0][TAGW-1:0] lane_req_tag_mon;

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_lane_tb_wiring
        assign lane_bus_if[lane].req_ready = lane_req_ready_drv[lane];
        assign lane_bus_if[lane].rsp_valid = lane_rsp_valid_drv[lane];
        assign lane_bus_if[lane].rsp_data.tag = lane_rsp_tag_drv[lane];
        assign lane_bus_if[lane].rsp_data.data = lane_rsp_data_drv[lane];
        assign lane_req_valid_mon[lane] = lane_bus_if[lane].req_valid;
        assign lane_req_addr_mon[lane] = lane_bus_if[lane].req_data.addr;
        assign lane_req_tag_mon[lane] = lane_bus_if[lane].req_data.tag;
        assign lane_rsp_ready_mon[lane] = lane_bus_if[lane].rsp_ready;
    end

    VX_gemm_psum_read_ooo_join #(
        .NUM_LANES(NUM_LANES),
        .LANE_DATA_SIZE(LANE_BYTES),
        .TAG_WIDTH(TAGW),
        .PHYS_RESPONSE_SLOTS(PHYS_SLOTS),
        .RESPONSE_FIFO_DEPTH(FIFO_DEPTH)
    ) u_dut (
        .clk(clk),
        .reset(reset),
        .wide_bus_if(wide_bus_if),
        .lane_bus_if(lane_bus_if)
    );

    initial clk = 1'b0;
    always #(PERIOD / 2) clk = ~clk;

    logic [PHYS_SLOTS-1:0][NUM_LANES-1:0] lane_req_seen;
    logic [PHYS_SLOTS-1:0][NUM_LANES-1:0][LANE_ADDRW-1:0]
        lane_req_addr;
    logic [31:0][WIDE_ADDRW-1:0] expected_addr;
    logic [31:0] expected_valid;
    logic [31:0] response_seen;
    int unsigned wide_req_count;
    int unsigned wide_rsp_count;

    function automatic logic [TAGW-1:0] logical_tag(input int index);
        return TAGW'(16'h0100 + index);
    endfunction

    function automatic logic [LANE_BYTES*8-1:0] lane_pattern(
        input logic [LANE_ADDRW-1:0] addr
    );
        return {32'h5a5a0000 | 32'(addr[15:0]), 32'(addr)};
    endfunction

    task automatic drive_defaults;
        wide_bus_if.req_valid = 1'b0;
        wide_bus_if.req_data = '0;
        wide_bus_if.rsp_ready = 1'b0;
        lane_req_ready_drv = '1;
        lane_rsp_valid_drv = '0;
        lane_rsp_tag_drv = '0;
        lane_rsp_data_drv = '0;
    endtask

    task automatic send_wide_read(
        input int index,
        input logic [WIDE_ADDRW-1:0] addr
    );
        @(negedge clk);
        wide_bus_if.req_valid = 1'b1;
        wide_bus_if.req_data.rw = 1'b0;
        wide_bus_if.req_data.addr = addr;
        wide_bus_if.req_data.data = '0;
        wide_bus_if.req_data.byteen = '1;
        wide_bus_if.req_data.flags = '0;
        wide_bus_if.req_data.tag = logical_tag(index);
        do @(posedge clk); while (!wide_bus_if.req_ready);
        expected_addr[index] = addr;
        expected_valid[index] = 1'b1;
        @(negedge clk);
        wide_bus_if.req_valid = 1'b0;
    endtask

    task automatic wait_slot_requests(input int slot);
        int unsigned timeout;
        timeout = 0;
        while (lane_req_seen[slot] != '1) begin
            @(posedge clk);
            timeout++;
            assert (timeout < 100)
                else $fatal(1, "timeout waiting for physical slot %0d requests", slot);
        end
    endtask

    task automatic respond_slot_mask(
        input int slot,
        input logic [NUM_LANES-1:0] lane_mask
    );
        @(negedge clk);
        for (int lane = 0; lane < NUM_LANES; ++lane) begin
            if (lane_mask[lane]) begin
                lane_rsp_valid_drv[lane] = 1'b1;
                lane_rsp_tag_drv[lane] = TAGW'(slot);
                lane_rsp_data_drv[lane]
                    = lane_pattern(lane_req_addr[slot][lane]);
            end
        end
        @(posedge clk);
        for (int lane = 0; lane < NUM_LANES; ++lane) begin
            if (lane_mask[lane]) begin
                assert (lane_rsp_ready_mon[lane])
                    else $fatal(1, "owned lane response was not accepted lane=%0d slot=%0d",
                                lane, slot);
            end
        end
        @(negedge clk);
        for (int lane = 0; lane < NUM_LANES; ++lane)
            lane_rsp_valid_drv[lane] = 1'b0;
    endtask

    task automatic respond_slot(input int slot);
        respond_slot_mask(slot, '1);
    endtask

    task automatic check_stale_not_ready(input int slot, input int lane);
        @(negedge clk);
        lane_rsp_valid_drv[lane] = 1'b1;
        lane_rsp_tag_drv[lane] = TAGW'(slot);
        lane_rsp_data_drv[lane] = '0;
        #1;
        assert (!lane_rsp_ready_mon[lane])
            else $fatal(1, "stale physical response was accepted");
        lane_rsp_valid_drv[lane] = 1'b0;
    endtask

    always @(posedge clk) begin
        if (reset) begin
            lane_req_seen <= '0;
            lane_req_addr <= '0;
            wide_req_count <= 0;
            wide_rsp_count <= 0;
        end else begin
            if (wide_bus_if.req_valid && wide_bus_if.req_ready)
                wide_req_count <= wide_req_count + 1;
            for (int lane = 0; lane < NUM_LANES; ++lane) begin
                if (lane_req_valid_mon[lane]
                 && lane_req_ready_drv[lane]) begin
                    int slot;
                    slot = int'(lane_req_tag_mon[lane]);
                    assert (slot < PHYS_SLOTS)
                        else $fatal(1, "physical slot tag out of range");
                    assert (!lane_req_seen[slot][lane])
                        else $fatal(1, "duplicate physical lane request");
                    lane_req_seen[slot][lane] <= 1'b1;
                    lane_req_addr[slot][lane]
                        <= lane_req_addr_mon[lane];
                end
            end
            if (wide_bus_if.rsp_valid && wide_bus_if.rsp_ready) begin
                int index;
                index = int'(wide_bus_if.rsp_data.tag) - 16'h0100;
                assert ((index >= 0) && (index < 32)
                     && expected_valid[index] && !response_seen[index])
                    else $fatal(1, "duplicate or unknown logical response tag=0x%0h",
                                wide_bus_if.rsp_data.tag);
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    logic [LANE_ADDRW-1:0] expected_lane_addr;
                    expected_lane_addr = {
                        expected_addr[index], `LOG2UP(NUM_LANES)'(lane)
                    };
                    assert (wide_bus_if.rsp_data.data[
                                lane*LANE_BYTES*8 +: LANE_BYTES*8]
                            == lane_pattern(expected_lane_addr))
                        else $fatal(1, "lane data mixed across slots tag=0x%0h lane=%0d",
                                    wide_bus_if.rsp_data.tag, lane);
                end
                response_seen[index] <= 1'b1;
                wide_rsp_count <= wide_rsp_count + 1;
            end
        end
    end

    initial begin
        drive_defaults();
        expected_addr = '0;
        expected_valid = '0;
        response_seen = '0;
        reset = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // Exercise request hold while one physical lane is backpressured.
        lane_req_ready_drv[5] = 1'b0;
        fork
            begin
                send_wide_read(0, WIDE_ADDRW'(16'h40));
                send_wide_read(1, WIDE_ADDRW'(16'h41));
                send_wide_read(2, WIDE_ADDRW'(16'h42));
                send_wide_read(3, WIDE_ADDRW'(16'h43));
            end
            begin
                repeat (5) @(posedge clk);
                @(negedge clk);
                lane_req_ready_drv[5] = 1'b1;
            end
        join

        // Four live slots must bound further acceptance before any completion.
        @(negedge clk);
        wide_bus_if.req_valid = 1'b1;
        wide_bus_if.req_data.rw = 1'b0;
        wide_bus_if.req_data.addr = WIDE_ADDRW'(16'h44);
        wide_bus_if.req_data.byteen = '1;
        wide_bus_if.req_data.tag = logical_tag(4);
        repeat (2) begin
            @(posedge clk);
            assert (!wide_bus_if.req_ready)
                else $fatal(1, "fifth request bypassed the four-slot bound");
        end
        @(negedge clk);
        wide_bus_if.req_valid = 1'b0;

        for (int slot = 0; slot < PHYS_SLOTS; ++slot)
            wait_slot_requests(slot);

        // Complete set-1 slots first. Slot 1 is deliberately lane-skewed; its
        // odd-lane arrival also exercises same-cycle complete/FIFO push.
        respond_slot_mask(1, 16'h5555);
        respond_slot_mask(1, 16'haaaa);
        respond_slot(3);

        // The FIFO is now full. Further complete slots must retain all data
        // until FIFO pop creates capacity.
        respond_slot(0);
        respond_slot(2);
        repeat (3) @(posedge clk);
        assert ($countones(u_dut.slot_complete) == 2)
            else $fatal(1, "completed slots were not retained behind FIFO backpressure");

        // A freed physical slot rejects stale/duplicate responses.
        check_stale_not_ready(1, 0);

        wide_bus_if.rsp_ready = 1'b1;
        wait (wide_rsp_count == 4);
        @(posedge clk);
        assert (&response_seen[3:0])
            else $fatal(1, "not all alternating-set responses retired");

        // Occupied reset must flush slot/FIFO ownership and reject a stale tag.
        @(negedge clk);
        lane_req_seen[0] = '0;
        send_wide_read(4, WIDE_ADDRW'(16'h44));
        wait_slot_requests(0);
        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        assert ((u_dut.slot_valid == '0) && !wide_bus_if.rsp_valid)
            else $fatal(1, "occupied reset left stale PSUM join ownership");
        check_stale_not_ready(0, 0);

        // A physical lane may respond before the other lanes in its wide
        // request have been accepted.  Hold lanes 0..7, return lanes 8..15,
        // then release and finish the slot.
        @(negedge clk);
        lane_req_ready_drv[7:0] = '0;
        send_wide_read(5, WIDE_ADDRW'(16'h45));
        wait (lane_req_seen[0][15:8] == 8'hff);
        respond_slot_mask(0, 16'hff00);
        assert ((u_dut.slot_rsp_valid[0] == 16'hff00)
             && !u_dut.slot_req_done[0]
             && !wide_bus_if.rsp_valid)
            else $fatal(1, "early lane responses did not remain owned by the partial request");
        @(negedge clk);
        lane_req_ready_drv[7:0] = '1;
        wait_slot_requests(0);
        respond_slot_mask(0, 16'h00ff);
        wait (response_seen[5]);

        $display("TEST PASSED: requests=%0d responses=%0d", wide_req_count, wide_rsp_count);
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "timeout");
    end

endmodule

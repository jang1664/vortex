`timescale 1ns/1ps

`include "VX_define.vh"

module tb_VX_tmem_dma_pair_adapter;
    import VX_gpu_pkg::*;
    localparam int HBM_DMA_DATA_SIZE = 64;
    localparam int DATA_SIZE = 32;
    localparam int DATA_WIDTH = DATA_SIZE * 8;
    localparam int TAG_WIDTH = 8;
    localparam int BANK_TAG_WIDTH = 12;
    localparam int MEM_ADDR_WIDTH = 34;
    localparam int DMA_ADDR_WIDTH = MEM_ADDR_WIDTH
                                  - $clog2(HBM_DMA_DATA_SIZE);
    localparam int BANK_ADDR_WIDTH = MEM_ADDR_WIDTH - $clog2(DATA_SIZE);

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #5 clk = ~clk;

    VX_mem_bus_if #(
        .DATA_SIZE      (HBM_DMA_DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) dma_if ();

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (BANK_TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) bank_if [2] ();

    logic [1:0] bank_req_ready;
    logic [1:0] bank_rsp_valid;
    logic [1:0][DATA_WIDTH-1:0] bank_rsp_data;
    logic [1:0][BANK_TAG_WIDTH-1:0] bank_rsp_tag;
    wire [1:0] bank_rsp_ready;
    int request_fire_count[2];

    logic [DMA_ADDR_WIDTH-1:0] expected_addr;
    logic [HBM_DMA_DATA_SIZE*8-1:0] expected_data;
    logic [HBM_DMA_DATA_SIZE-1:0] expected_byteen;
    logic [TAG_WIDTH-1:0] expected_tag;
    logic expected_rw;

    VX_tmem_dma_pair_adapter #(
        .INSTANCE_ID       ("tb"),
        .HBM_DMA_DATA_SIZE (HBM_DMA_DATA_SIZE),
        .DATA_SIZE         (DATA_SIZE),
        .TAG_WIDTH         (TAG_WIDTH),
        .BANK_TAG_WIDTH    (BANK_TAG_WIDTH),
        .MEM_ADDR_WIDTH    (MEM_ADDR_WIDTH),
        .RSP_FIFO_DEPTH    (2)
    ) dut (
        .clk         (clk),
        .reset       (reset),
        .dma_bus_if  (dma_if),
        .bank_bus_if (bank_if)
    );

    for (genvar lane = 0; lane < 2; ++lane) begin : g_bank_drive
        assign bank_if[lane].req_ready = bank_req_ready[lane];
        assign bank_if[lane].rsp_valid = bank_rsp_valid[lane];
        assign bank_if[lane].rsp_data.data = bank_rsp_data[lane];
        assign bank_if[lane].rsp_data.tag = bank_rsp_tag[lane];
        assign bank_rsp_ready[lane] = bank_if[lane].rsp_ready;

        always_ff @(posedge clk) begin
            if (reset) begin
                request_fire_count[lane] <= 0;
            end else if (bank_if[lane].req_valid
                      && bank_if[lane].req_ready) begin
                request_fire_count[lane] <= request_fire_count[lane] + 1;
                assert (bank_if[lane].req_data.rw == expected_rw)
                    else $fatal(1, "lane %0d rw mismatch", lane);
                assert (bank_if[lane].req_data.addr
                     == BANK_ADDR_WIDTH'(expected_addr))
                    else $fatal(1, "lane %0d address mismatch", lane);
                assert (bank_if[lane].req_data.data
                     == expected_data[lane*DATA_WIDTH +: DATA_WIDTH])
                    else $fatal(1, "lane %0d data slice mismatch", lane);
                assert (bank_if[lane].req_data.byteen
                     == expected_byteen[lane*DATA_SIZE +: DATA_SIZE])
                    else $fatal(1, "lane %0d byte-enable slice mismatch", lane);
                assert (bank_if[lane].req_data.tag
                     == BANK_TAG_WIDTH'(expected_tag))
                    else $fatal(1, "lane %0d tag mismatch", lane);
            end
        end
    end

    function automatic logic [HBM_DMA_DATA_SIZE*8-1:0] data_pattern(
        input int seed
    );
        logic [HBM_DMA_DATA_SIZE*8-1:0] value;
        for (int byte_idx = 0; byte_idx < HBM_DMA_DATA_SIZE; ++byte_idx)
            value[byte_idx*8 +: 8] = 8'(seed + byte_idx * 3);
        return value;
    endfunction

    task automatic drive_request(
        input logic [1:0] first_ready,
        input logic rw,
        input logic [DMA_ADDR_WIDTH-1:0] addr,
        input logic [TAG_WIDTH-1:0] tag,
        input int seed
    );
        logic [1:0] remaining_ready;
        int before_count[2];
        begin
            before_count[0] = request_fire_count[0];
            before_count[1] = request_fire_count[1];
            expected_rw = rw;
            expected_addr = addr;
            expected_data = data_pattern(seed);
            expected_byteen = {
                DATA_SIZE'(32'hf0ff_0ff0),
                DATA_SIZE'(32'h55aa_a55a)
            };
            expected_tag = tag;

            @(negedge clk);
            dma_if.req_valid = 1'b1;
            dma_if.req_data.rw = expected_rw;
            dma_if.req_data.addr = expected_addr;
            dma_if.req_data.data = expected_data;
            dma_if.req_data.byteen = expected_byteen;
            dma_if.req_data.flags = MEM_FLAGS_WIDTH'(1);
            dma_if.req_data.tag = expected_tag;
            bank_req_ready = first_ready;
            #1;
            assert (bank_if[0].req_valid && bank_if[1].req_valid)
                else $fatal(1, "both request lanes must start active");
            assert (bank_if[0].req_data.addr == bank_if[1].req_data.addr)
                else $fatal(1, "pair request addresses differ");

            if (first_ready == 2'b11) begin
                assert (dma_if.req_ready)
                    else $fatal(1, "simultaneous bank acceptance not completed");
                @(posedge clk);
            end else begin
                assert (!dma_if.req_ready)
                    else $fatal(1, "partial bank acceptance completed early");
                @(posedge clk);
                #1;
                assert (bank_if[0].req_valid == !first_ready[0])
                    else $fatal(1, "lane 0 sent-state mismatch");
                assert (bank_if[1].req_valid == !first_ready[1])
                    else $fatal(1, "lane 1 sent-state mismatch");
                remaining_ready = ~first_ready;
                @(negedge clk);
                bank_req_ready = remaining_ready;
                #1;
                assert (dma_if.req_ready)
                    else $fatal(1, "pair request did not complete on second lane");
                @(posedge clk);
            end

            @(negedge clk);
            dma_if.req_valid = 1'b0;
            bank_req_ready = 2'b00;
            #1;
            assert ((request_fire_count[0] == before_count[0] + 1)
                 && (request_fire_count[1] == before_count[1] + 1))
                else $fatal(1, "request was not accepted exactly once per lane");
        end
    endtask

    task automatic drive_back_to_back_requests;
        int before_count[2];
        begin
            before_count[0] = request_fire_count[0];
            before_count[1] = request_fire_count[1];

            bank_req_ready = 2'b11;
            @(negedge clk);
            for (int beat = 0; beat < 3; ++beat) begin
                expected_rw = 1'b1;
                expected_addr = DMA_ADDR_WIDTH'(61 + beat);
                expected_data = data_pattern(211 + 17 * beat);
                expected_tag = TAG_WIDTH'(8'ha1 + beat);
                unique case (beat)
                    0: expected_byteen = 64'hffff_0000_aaaa_5555;
                    1: expected_byteen = 64'h0ff0_f00f_33cc_cc33;
                    default: expected_byteen = 64'h55aa_a55a_c3c3_3c3c;
                endcase

                dma_if.req_valid = 1'b1;
                dma_if.req_data.rw = expected_rw;
                dma_if.req_data.addr = expected_addr;
                dma_if.req_data.data = expected_data;
                dma_if.req_data.byteen = expected_byteen;
                dma_if.req_data.flags = MEM_FLAGS_WIDTH'(beat + 1);
                dma_if.req_data.tag = expected_tag;
                #1;
                assert (dma_if.req_ready
                     && bank_if[0].req_valid && bank_if[1].req_valid)
                    else $fatal(1,
                        "back-to-back beat %0d did not accept both lanes", beat);

                @(posedge clk);
                #1;
                assert ((request_fire_count[0] == before_count[0] + beat + 1)
                     && (request_fire_count[1] == before_count[1] + beat + 1))
                    else $fatal(1,
                        "back-to-back beat %0d was not accepted exactly once per lane",
                        beat);
                if (beat != 2)
                    @(negedge clk);
            end

            @(negedge clk);
            dma_if.req_valid = 1'b0;
            bank_req_ready = 2'b00;
            #1;
            assert ((request_fire_count[0] == before_count[0] + 3)
                 && (request_fire_count[1] == before_count[1] + 3))
                else $fatal(1,
                    "back-to-back sequence replayed or dropped a physical lane");
            $display("COVERAGE: pair_adapter_back_to_back_3");
        end
    endtask

    task automatic push_response0(
        input logic [TAG_WIDTH-1:0] tag,
        input logic [DATA_WIDTH-1:0] data
    );
        begin
            @(negedge clk);
            bank_rsp_valid[0] = 1'b1;
            bank_rsp_tag[0] = BANK_TAG_WIDTH'(tag);
            bank_rsp_data[0] = data;
            #1;
            assert (bank_rsp_ready[0])
                else $fatal(1, "lane 0 response FIFO unexpectedly full");
            @(posedge clk);
            @(negedge clk);
            bank_rsp_valid[0] = 1'b0;
        end
    endtask

    task automatic push_response1(
        input logic [TAG_WIDTH-1:0] tag,
        input logic [DATA_WIDTH-1:0] data
    );
        begin
            @(negedge clk);
            bank_rsp_valid[1] = 1'b1;
            bank_rsp_tag[1] = BANK_TAG_WIDTH'(tag);
            bank_rsp_data[1] = data;
            #1;
            assert (bank_rsp_ready[1])
                else $fatal(1, "lane 1 response FIFO unexpectedly full");
            @(posedge clk);
            @(negedge clk);
            bank_rsp_valid[1] = 1'b0;
        end
    endtask

    task automatic consume_response(
        input logic [TAG_WIDTH-1:0] tag,
        input logic [DATA_WIDTH-1:0] low_data,
        input logic [DATA_WIDTH-1:0] high_data
    );
        begin
            #1;
            assert (dma_if.rsp_valid)
                else $fatal(1, "joined response missing");
            assert (dma_if.rsp_data.tag == tag)
                else $fatal(1, "joined response tag mismatch");
            assert (dma_if.rsp_data.data == {high_data, low_data})
                else $fatal(1, "joined response data mismatch");
            dma_if.rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            dma_if.rsp_ready = 1'b0;
        end
    endtask

    initial begin
        logic [DATA_WIDTH-1:0] low_a;
        logic [DATA_WIDTH-1:0] high_a;
        logic [DATA_WIDTH-1:0] low_b;
        logic [DATA_WIDTH-1:0] high_b;
        logic [DATA_WIDTH-1:0] low_c;
        logic [DATA_WIDTH-1:0] high_c;
        logic [HBM_DMA_DATA_SIZE*8-1:0] data_a;
        logic [HBM_DMA_DATA_SIZE*8-1:0] data_b;
        logic [HBM_DMA_DATA_SIZE*8-1:0] data_c;

        dma_if.req_valid = 1'b0;
        dma_if.req_data = '0;
        dma_if.rsp_ready = 1'b0;
        bank_req_ready = '0;
        bank_rsp_valid = '0;
        bank_rsp_data = '0;
        bank_rsp_tag = '0;
        expected_addr = '0;
        expected_data = '0;
        expected_byteen = '0;
        expected_tag = '0;
        expected_rw = 1'b0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        drive_request(2'b01, 1'b0, DMA_ADDR_WIDTH'(17), 8'h31, 5);
        drive_request(2'b10, 1'b1, DMA_ADDR_WIDTH'(29), 8'h52, 19);
        drive_request(2'b11, 1'b0, DMA_ADDR_WIDTH'(41), 8'h73, 37);

        data_a = data_pattern(71);
        data_b = data_pattern(103);
        data_c = data_pattern(149);
        low_a = data_a[DATA_WIDTH-1:0];
        high_a = data_a[2*DATA_WIDTH-1:DATA_WIDTH];
        low_b = data_b[DATA_WIDTH-1:0];
        high_b = data_b[2*DATA_WIDTH-1:DATA_WIDTH];
        low_c = data_c[DATA_WIDTH-1:0];
        high_c = data_c[2*DATA_WIDTH-1:DATA_WIDTH];

        // Fill the low-lane FIFO first to exercise response skew and ensure
        // no aggregate response escapes without the matching high half.
        push_response0(8'h31, low_a);
        push_response0(8'h52, low_b);
        #1;
        assert (!bank_rsp_ready[0] && !dma_if.rsp_valid)
            else $fatal(1, "skewed response handling violated FIFO/join rules");

        push_response1(8'h31, high_a);
        consume_response(8'h31, low_a, high_a);
        #1;
        assert (bank_rsp_ready[0])
            else $fatal(1, "response pop did not expose low-lane FIFO space");

        push_response1(8'h52, high_b);
        consume_response(8'h52, low_b, high_b);

        push_response0(8'h73, low_c);
        push_response1(8'h73, high_c);
        consume_response(8'h73, low_c, high_c);

        // With both physical banks ready, the adapter must preserve the
        // aggregate 64-byte request throughput without bubbles.
        drive_back_to_back_requests();

        $display("TEST PASSED: VX_tmem_dma_pair_adapter");
        $finish;
    end

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "timeout");
    end

endmodule

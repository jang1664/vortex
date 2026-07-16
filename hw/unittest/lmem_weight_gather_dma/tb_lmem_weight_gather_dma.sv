`timescale 1ns/1ps
`include "VX_define.vh"

module tb_lmem_weight_gather_dma;
    import VX_gpu_pkg::*;
    localparam int NUM_LANES = 8;
    localparam int TAG_WIDTH = GEMM_BASE_TAG_WIDTH;
    localparam int DEPTH = 4;
    localparam logic [63:0] SRC_BASE = 64'h1000;
    localparam logic [31:0] SRC_STRIDE = 32'd64;

    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;

    VX_lmem_dma_ctrl_if ctrl_if();
    VX_mem_bus_if #(.DATA_SIZE(8), .TAG_WIDTH(TAG_WIDTH)) lmem_if[NUM_LANES]();
    VX_mem_bus_if #(.DATA_SIZE(64), .TAG_WIDTH(TAG_WIDTH)) gemm_if();

    VX_lmem_weight_gather_dma #(
        .INSTANCE_ID("weight_gather_test"),
        .NUM_LANES(NUM_LANES),
        .TAG_WIDTH(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .reset(reset),
        .ctrl_if(ctrl_if),
        .lmem_bus_if(lmem_if),
        .gemm_bus_if(gemm_if)
    );

    for (genvar lane = 0; lane < NUM_LANES; ++lane) begin : g_mem
        logic [63:0] rsp_data_fifo[8];
        logic [TAG_WIDTH-1:0] rsp_tag_fifo[8];
        logic [3:0] rsp_delay_fifo[8];
        logic [2:0] rsp_wr_ptr;
        logic [2:0] rsp_rd_ptr;
        logic [3:0] rsp_count;
        wire push = lmem_if[lane].req_valid && lmem_if[lane].req_ready;
        wire launch = !lmem_if[lane].rsp_valid
                   && (rsp_count != 0)
                   && (rsp_delay_fifo[rsp_rd_ptr] == 0);

        assign lmem_if[lane].req_ready = (rsp_count != 8);

        always_ff @(posedge clk) begin
            if (reset) begin
                rsp_wr_ptr <= '0;
                rsp_rd_ptr <= '0;
                rsp_count <= '0;
                lmem_if[lane].rsp_valid <= 1'b0;
                lmem_if[lane].rsp_data  <= '0;
            end else begin
                if (lmem_if[lane].rsp_valid && lmem_if[lane].rsp_ready) begin
                    lmem_if[lane].rsp_valid <= 1'b0;
                end

                if (push) begin
                    rsp_data_fifo[rsp_wr_ptr] <= 64'(lmem_if[lane].req_data.addr) << 3;
                    rsp_tag_fifo[rsp_wr_ptr] <= lmem_if[lane].req_data.tag;
                    rsp_delay_fifo[rsp_wr_ptr] <= 2 + ((NUM_LANES - lane) % 5);
                    rsp_wr_ptr <= rsp_wr_ptr + 1'b1;
                end

                if (launch) begin
                    lmem_if[lane].rsp_valid <= 1'b1;
                    lmem_if[lane].rsp_data.data <= rsp_data_fifo[rsp_rd_ptr];
                    lmem_if[lane].rsp_data.tag  <= rsp_tag_fifo[rsp_rd_ptr];
                    rsp_rd_ptr <= rsp_rd_ptr + 1'b1;
                end else if (!lmem_if[lane].rsp_valid && (rsp_count != 0)) begin
                    rsp_delay_fifo[rsp_rd_ptr] <= rsp_delay_fifo[rsp_rd_ptr] - 1'b1;
                end

                case ({push, launch})
                    2'b10: rsp_count <= rsp_count + 1'b1;
                    2'b01: rsp_count <= rsp_count - 1'b1;
                    default: rsp_count <= rsp_count;
                endcase
            end
        end
    end

    logic [31:0] cycle_r;
    int output_count;
    bit saw_full_prefetch;

    assign gemm_if.req_ready = (cycle_r[1:0] != 2'b00);
    assign gemm_if.rsp_valid = 1'b0;
    assign gemm_if.rsp_data  = '0;

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_r <= '0;
            output_count <= 0;
            saw_full_prefetch <= 0;
        end else begin
            cycle_r <= cycle_r + 1'b1;
            if (dut.slot_busy_r == 4'hf)
                saw_full_prefetch <= 1;

            if (gemm_if.req_valid && gemm_if.req_ready) begin
                for (int lane = 0; lane < NUM_LANES; ++lane) begin
                    logic [63:0] expected;
                    expected = SRC_BASE
                             + (output_count * 4 * SRC_STRIDE)
                             + ((lane / 2) * SRC_STRIDE)
                             + ((lane % 2) * 8);
                    if (gemm_if.req_data.data[lane * 64 +: 64] !== expected) begin
                        $fatal(1, "group=%0d lane=%0d got=%h expected=%h",
                               output_count, lane,
                               gemm_if.req_data.data[lane * 64 +: 64], expected);
                    end
                end
                output_count <= output_count + 1;
            end
        end
    end

    initial begin
        ctrl_if.start = 0;
        ctrl_if.src_base_addr = SRC_BASE;
        ctrl_if.dst_base_addr = 0;
        ctrl_if.src_strides[0] = SRC_STRIDE;
        ctrl_if.src_strides[1] = 0;
        ctrl_if.src_strides[2] = 0;
        ctrl_if.dst_strides[0] = 0;
        ctrl_if.dst_strides[1] = 0;
        ctrl_if.dst_strides[2] = 0;
        ctrl_if.bounds[0] = 32;
        ctrl_if.bounds[1] = 1;
        ctrl_if.bounds[2] = 1;
        ctrl_if.seg_size = 16;
        ctrl_if.reg_idx = 0;
        ctrl_if.reg_value = 0;

        repeat (5) @(posedge clk);
        reset = 0;
        repeat (2) @(posedge clk);
        ctrl_if.start = 1;
        @(posedge clk);
        ctrl_if.start = 0;

        fork
            begin
                wait (ctrl_if.done);
                @(posedge clk);
                if (output_count != 8)
                    $fatal(1, "expected 8 output groups, got %0d", output_count);
                if (!saw_full_prefetch)
                    $fatal(1, "four gather slots were never occupied together");
                $display("TEST PASSED: strided WLOAD4 gather with depth-4 prefetch");
                $finish;
            end
            begin
                repeat (1000) @(posedge clk);
                $fatal(1, "timeout");
            end
        join_any
    end
endmodule

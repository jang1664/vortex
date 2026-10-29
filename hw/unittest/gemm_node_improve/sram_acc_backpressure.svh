// Independent endpoint fixture: exercise captured FP32 halves while unrelated
// compute reads change the SRAM output register. Main tests supply arithmetic
// coverage through the complete GEMM node; this fixture supplies controlled
// response backpressure that cannot be imposed through node MMIO.
VX_gemm_acc_if #(.TAGW(32)) fusion_acc_test_if();
VX_mem_bus_if #(.DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE), .TAG_WIDTH(32))
    fusion_acc_test_output_if();
logic fusion_acc_test_fp32 = 1;
VX_gemm_acc_internal #(.INSTANCE_ID("fp32_export_stall_fixture"), .TAGW(32))
    fusion_acc_test (
        .clk(clk), .reset(reset), .acc_if(fusion_acc_test_if),
        .o_lmem_bus_if(fusion_acc_test_output_if),
        .output_fp32_i(fusion_acc_test_fp32)
    );

initial begin
    fusion_acc_test_if.rd_req_valid = 0;
    fusion_acc_test_if.rd_req_addr = 0;
    fusion_acc_test_if.rd_req_tag = 0;
    fusion_acc_test_if.rd_dependency_valid = 0;
    fusion_acc_test_if.rd_dependency_addr = 0;
    fusion_acc_test_if.rd_rsp_ready = 1;
    fusion_acc_test_if.wr_req_valid = 0;
    fusion_acc_test_if.wr_req_addr = 0;
    fusion_acc_test_if.wr_req_tag = 0;
    fusion_acc_test_if.wr_req_data = 0;
    fusion_acc_test_if.wr_req_final_output = 0;
    fusion_acc_test_if.wr_req_last = 0;
    fusion_acc_test_if.txn_accept_valid = 0;
    fusion_acc_test_if.txn_accept_tag = 0;
    fusion_acc_test_if.txn_accept_rd_en = 0;
    fusion_acc_test_if.txn_accept_wr_en = 0;
    fusion_acc_test_if.txn_accept_rd_addr = 0;
    fusion_acc_test_if.txn_accept_wr_addr = 0;
    fusion_acc_test_if.txn_retire_valid = 0;
    fusion_acc_test_if.txn_retire_tag = 0;
    fusion_acc_test_if.txn_retire_rd_en = 0;
    fusion_acc_test_if.txn_retire_wr_en = 0;
    fusion_acc_test_if.txn_retire_rd_addr = 0;
    fusion_acc_test_if.txn_retire_wr_addr = 0;
    fusion_acc_test_output_if.req_valid = 0;
    fusion_acc_test_output_if.req_data = 0;
    fusion_acc_test_output_if.rsp_ready = 0;
end

function automatic logic [511:0] fusion_acc_pattern(input int row);
    logic [511:0] data;
    for (int col = 0; col < 16; ++col)
        data[col*32 +: 32] = $shortrealtobits(shortreal'(
            (70000 + row*10000 + col*32) * ((row%2) ? -1 : 1)));
    return data;
endfunction

task automatic fusion_acc_write(input int row, input logic [511:0] data);
    @(negedge clk);
    fusion_acc_test_if.wr_req_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(row*64);
    fusion_acc_test_if.wr_req_data = data;
    fusion_acc_test_if.wr_req_valid = 1;
    @(posedge clk);
    assert (fusion_acc_test_if.wr_req_ready)
        else $fatal(1,"ACC fixture write unexpectedly blocked");
    @(negedge clk);
    fusion_acc_test_if.wr_req_valid = 0;
endtask

task automatic fusion_acc_check_stall;
    logic [511:0] row_data, fp16_row;
    logic [255:0] expected, held;
    logic [31:0] expected_tag;
    int waits, displaced_responses;
    for (int row = 0; row < 4; ++row)
        fusion_acc_write(row,fusion_acc_pattern(row));
    for (int row = 0; row < 4; ++row)
        for (int half_index = 0; half_index < 2; ++half_index) begin
            row_data = fusion_acc_pattern(row);
            expected = row_data[half_index*256 +: 256];
            expected_tag = 32'h8000 + row*2 + half_index;
            @(negedge clk);
            fusion_acc_test_fp32 = 1;
            fusion_acc_test_output_if.req_data = 0;
            fusion_acc_test_output_if.req_data.addr = row*2+half_index;
            fusion_acc_test_output_if.req_data.tag = expected_tag;
            fusion_acc_test_output_if.req_valid = 1;
            waits = 0;
            do begin
                @(posedge clk);
                if (++waits > 20) $fatal(1,"ACC fixture request timed out");
            end while (!fusion_acc_test_output_if.req_ready);
            @(negedge clk);
            fusion_acc_test_output_if.req_valid = 0;
            fusion_acc_test_output_if.req_data.addr = '1;
            fusion_acc_test_fp32 = 0; // Captured mode and half must stay intact.
            waits = 0;
            while (!fusion_acc_test_output_if.rsp_valid) begin
                @(negedge clk);
                if (++waits > 20) $fatal(1,"ACC fixture response timed out");
            end
            held = fusion_acc_test_output_if.rsp_data.data;
            assert (held === expected)
                else $fatal(1,"ACC half order mismatch row=%0d half=%0d actual=%h expected=%h",
                    row,half_index,held,expected);
            // A different row in the same bank overwrites its synchronous
            // read register while the output consumer remains stalled.
            fusion_acc_test_if.rd_req_valid = 1;
            fusion_acc_test_if.rd_req_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(((row+2)%4)*64);
            @(posedge clk);
            assert (fusion_acc_test_if.rd_req_ready)
                else $fatal(1,"ACC fixture compute read blocked");
            @(negedge clk);
            fusion_acc_test_if.rd_req_valid = 0;
            displaced_responses = 0;
            repeat (7) begin
                @(negedge clk);
                assert (fusion_acc_test_output_if.rsp_valid
                    && fusion_acc_test_output_if.rsp_data.data === held
                    && fusion_acc_test_output_if.rsp_data.tag === expected_tag)
                    else $fatal(1,"ACC FP32 payload/tag changed while response stalled");
                if (fusion_acc_test_if.rd_rsp_valid) begin
                    assert (fusion_acc_test_if.rd_rsp_data === fusion_acc_pattern((row+2)%4))
                        else $fatal(1,"ACC fixture competing read returned wrong row");
                    ++displaced_responses;
                end
            end
            assert (displaced_responses == 1)
                else $fatal(1,"ACC fixture failed to cover competing SRAM response");
            fusion_acc_test_output_if.rsp_ready = 1;
            @(posedge clk);
            @(negedge clk);
            fusion_acc_test_output_if.rsp_ready = 0;
        end
    // Return to FP16 on the same instance, with representable exact values.
    for (int col = 0; col < 16; ++col) begin
        fp16_row[col*32 +: 32] = 32'h3f800000 + (col << 16);
        expected[col*16 +: 16] = 16'h3c00 + 16'(col*8);
    end
    fusion_acc_write(0,fp16_row);
    @(negedge clk);
    fusion_acc_test_fp32 = 0;
    fusion_acc_test_output_if.req_data = 0;
    fusion_acc_test_output_if.req_valid = 1;
    @(posedge clk);
    assert (fusion_acc_test_output_if.req_ready);
    @(negedge clk);
    fusion_acc_test_output_if.req_valid = 0;
    waits = 0;
    while (!fusion_acc_test_output_if.rsp_valid) begin
        @(negedge clk);
        if (++waits > 30) $fatal(1,"ACC fixture FP16 response timed out");
    end
    repeat (4) begin
        assert (fusion_acc_test_output_if.rsp_valid
            && fusion_acc_test_output_if.rsp_data.data === expected)
            else $fatal(1,"ACC FP16 response changed after FP32 mode");
        @(negedge clk);
    end
    fusion_acc_test_output_if.rsp_ready = 1;
    @(posedge clk);
    @(negedge clk);
    fusion_acc_test_output_if.rsp_ready = 0;
    $display("ACC_FP32_BACKPRESSURE PASSED halves=8 competing_reads=8 stalled_cycles=56 mode_switch=FP16");
endtask

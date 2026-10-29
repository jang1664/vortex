`include "VX_define.vh"
// Actual C4 lane and bank transport, common core reset, no reset relay model.
module tb_sram_direct_core_reset;
    import VX_gpu_pkg::*;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    logic bank_valid = 0, bank_ready_out = 0;
    logic [31:0] bank_data = 0;
    wire bank_ready, bank_out, bank_idle;
    wire [31:0] bank_result;
    VX_sram_bank_slice_transport #(.DATAW(32)) bank (
        .clk(clk), .reset(reset), .valid_in(bank_valid), .ready_in(bank_ready),
        .data_in(bank_data), .valid_out(bank_out), .ready_out(bank_ready_out),
        .data_out(bank_result), .idle_o(bank_idle)
    );
    VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH)) cpu[2]();
    VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH+1)) memory[1]();
    VX_mem_arb #(.NUM_INPUTS(2), .NUM_OUTPUTS(1), .DATA_SIZE(LSU_WORD_SIZE),
        .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH), .TAG_SEL_IDX(GEMM_LMEM_TAG_WIDTH-UUID_WIDTH),
        .REQ_OUT_BUF(3), .RSP_OUT_BUF(3), .ARBITER("P"), .FUSION_LANE_REQUEST_LINK(1)) lane (
        .clk(clk), .reset(reset), .bus_in_if(cpu), .bus_out_if(memory)
    );
    int immediate = 0, bank_received = 0, lane_received = 0;
    logic [31:0] expected_bank;
    logic [63:0] expected_lane;
    always @(posedge clk) begin
        if (reset) begin
            if (bank_ready || bank_out || cpu[0].req_ready || memory[0].req_valid)
                $fatal(1, "Core reset did not gate request handshakes");
        end else begin
            if (bank_out && bank_ready_out) begin
                if (bank_result !== expected_bank) $fatal(1, "Old bank epoch/payload escaped");
                bank_received++;
            end
            if (memory[0].req_valid && memory[0].req_ready) begin
                if (memory[0].req_data.data !== expected_lane) $fatal(1, "Old lane epoch/payload escaped");
                lane_received++;
            end
        end
    end
    task automatic assert_reset;
        @(negedge clk); reset = 1;
        bank_valid = 0; bank_ready_out = 0;
        cpu[0].req_valid = 0; cpu[0].rsp_ready = 0;
        memory[0].req_ready = 0; memory[0].rsp_valid = 0;
        repeat (3) @(negedge clk);
        if (cpu[0].rsp_valid || bank_out || !bank_idle)
            $fatal(1, "Reset did not clear response/credit state");
    endtask
    task automatic release_with_request(input int id);
        // Data is offered before the first edge after core-reset deassertion.
        bank_data = 32'(id); bank_valid = 1;
        cpu[0].req_data = '0; cpu[0].req_data.data = 64'(id);
        cpu[0].req_data.byteen = '1; cpu[0].req_data.tag = GEMM_LMEM_TAG_WIDTH'(id);
        cpu[0].req_valid = 1; reset = 0;
        #1;
        if (!bank_ready || !cpu[0].req_ready) $fatal(1, "Added reset-release holdoff");
        @(posedge clk); immediate++;
        @(negedge clk); bank_valid = 0; cpu[0].req_valid = 0;
    endtask
    task automatic bank_send(input int id);
        @(negedge clk); bank_data = 32'(id); bank_valid = 1;
        do @(posedge clk); while (!bank_ready);
        @(negedge clk); bank_valid = 0;
    endtask
    initial begin
        cpu[0].req_valid = 0; cpu[0].req_data = '0; cpu[0].rsp_ready = 0;
        cpu[1].req_valid = 0; cpu[1].req_data = '0; cpu[1].rsp_ready = 1;
        memory[0].req_ready = 0; memory[0].rsp_valid = 0; memory[0].rsp_data = '0;
        assert_reset(); release_with_request(11);
        bank_send(12); bank_send(13); bank_send(14);
        repeat (5) @(negedge clk);
        if (bank_ready || bank_idle || !bank_out || !memory[0].req_valid)
            $fatal(1, "Missing full-credit/stalled-request reset witness");
        assert_reset(); release_with_request(21);
        expected_bank = 21; expected_lane = 21;
        while (!bank_out || !memory[0].req_valid) @(negedge clk);
        // Capture the real inserted response tag before resetting the lane.
        memory[0].rsp_data.tag = memory[0].req_data.tag;
        memory[0].rsp_data.data = 64'h12345678;
        bank_ready_out = 1; memory[0].req_ready = 1;
        @(negedge clk); bank_ready_out = 0; memory[0].req_ready = 0;
        if (!bank.u_rx.credit_tx_q) $fatal(1, "Missing in-flight return-credit witness");
        memory[0].rsp_valid = 1;
        do @(posedge clk); while (!memory[0].rsp_ready);
        @(negedge clk); memory[0].rsp_valid = 0;
        while (!cpu[0].rsp_valid) @(negedge clk);
        if (cpu[0].rsp_data.data !== 64'h12345678) $fatal(1, "Response payload mismatch");
        // Reset the backpressured response and all request/credit state.
        assert_reset(); release_with_request(31);
        expected_bank = 31; expected_lane = 31;
        bank_ready_out = 1; memory[0].req_ready = 1;
        repeat (15) begin
            @(negedge clk);
            if (cpu[0].rsp_valid) $fatal(1, "Old response survived core reset");
        end
        if (!bank_idle || bank_out || memory[0].req_valid || immediate != 3
         || bank_received != 2 || lane_received != 2)
            $fatal(1, "Missing reset/first-edge/drain witness");
        // A credit in transit is itself flushed, without ghost capacity/work.
        bank_ready_out = 0; bank_send(41); expected_bank = 41;
        while (!bank_out) @(negedge clk);
        bank_ready_out = 1;
        @(negedge clk); bank_ready_out = 0;
        if (!bank.u_rx.credit_tx_q) $fatal(1, "Missing reset-during-credit witness");
        reset = 1;
        repeat (3) @(negedge clk);
        reset = 0; #1;
        if (!bank_ready || !bank_idle || bank_out) $fatal(1, "Credit reset did not restore empty capacity");
        repeat (8) @(negedge clk);
        if (!bank_idle || bank_out) $fatal(1, "Stale credit created work");
        $display("TEST PASSED direct_core_reset immediate=%0d bank=%0d lane=%0d", immediate, bank_received, lane_received);
        $finish;
    end
    initial begin #2000000; $fatal(1, "Direct reset watchdog"); end
endmodule

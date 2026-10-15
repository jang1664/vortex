`include "VX_define.vh"

module tb_gemm_fpfp_front;
    import VX_gpu_pkg::*;
    localparam int COUNT = 40;
    localparam int WEIGHT_BYTES = `FPFP_MXU_COL * `FPFP_MXU_WLOAD_NUM * 2;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    logic input_valid = 0, result_ready = 0;
    wire input_ready, result_valid, idle, weight_install;
    logic [`FPFP_MXU_ROW-1:0][15:0] input_data;
    wire [`FPFP_MXU_COL-1:0][31:0] result_data;
    gemm_input_ctrl_t input_ctrl, result_ctrl;
    VX_mem_bus_if #(.DATA_SIZE(WEIGHT_BYTES), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) weight_bus_if ();
    int sent = 0, received = 0, cycles = 0;
    VX_gemm_fpfp_front #(.INSTANCE_ID("test")) dut (
        .clk(clk), .reset(reset), .input_valid(input_valid), .input_ready(input_ready),
        .input_data(input_data), .input_ctrl(input_ctrl), .weight_bus_if(weight_bus_if),
        .weight_install(weight_install), .result_valid(result_valid),
        .result_ready(result_ready), .result_data(result_data), .result_ctrl(result_ctrl), .idle(idle)
    );
    function automatic logic [31:0] expected(input int index, input int column);
        int dot_sum;
        shortreal value;
        // Distinct reduction-row and output-column patterns catch axis swaps.
        // All values are exact powers-of-two multiples, including subnormals.
        dot_sum = 0;
        for (int k = 0; k < `FPFP_MXU_ROW; ++k)
            dot_sum += ((k % 3 == 0) ? 2 : 1) * ((k % 2) ? 2 : 1);
        value = dot_sum * (1 << ((index % 2) + (column % 3)));
        if (index % 3 == 0) value /= 16777216.0;
        if (column % 2) value = -value;
        return $shortrealtobits(value);
    endfunction
    initial begin
        input_ctrl = '0;
        input_data = '0;
        weight_bus_if.req_valid = 0;
        weight_bus_if.req_data = '0;
        weight_bus_if.rsp_ready = 1;
        repeat (8) @(negedge clk);
        reset = 0;
        for (int bank = 0; bank < 2; ++bank) begin
            for (int group_id = 0; group_id < `FPFP_MXU_ROW / `FPFP_MXU_WLOAD_NUM; ++group_id) begin
                @(negedge clk);
                weight_bus_if.req_valid = 1;
                weight_bus_if.req_data.rw = 1;
                weight_bus_if.req_data.addr = bank;
                weight_bus_if.req_data.byteen = '1;
                for (int j = 0; j < WEIGHT_BYTES/2; ++j) begin
                    int row, column, exponent;
                    row = group_id * `FPFP_MXU_WLOAD_NUM + j / `FPFP_MXU_COL;
                    column = j % `FPFP_MXU_COL;
                    exponent = 15 + bank + (column % 3) + ((row % 3 == 0) ? 1 : 0);
                    weight_bus_if.req_data.data[j*16+:16] = {1'(column % 2), 5'(exponent), 10'b0};
                end
                @(posedge clk);
                if (!weight_bus_if.req_ready) $fatal(1, "Weight install stalled");
            end
        end
        @(negedge clk);
        weight_bus_if.req_valid = 0;
        while (received < COUNT) begin
            input_valid = sent < COUNT;
            input_ctrl = '0;
            input_ctrl.valid = input_valid;
            input_ctrl.wreg_use_idx = 1'(sent % 2);
            input_ctrl.work_seq = 32'(sent + 1);
            input_ctrl.acc_txn_tag = 32'(sent + 100);
            for (int k = 0; k < `FPFP_MXU_ROW; ++k)
                input_data[k] = (sent % 3 == 0)
                    ? ((k % 2) ? 16'h0002 : 16'h0001)
                    : ((k % 2) ? 16'h4000 : 16'h3c00);
            // Force a sustained full FIFO, then varied short stalls.
            result_ready = cycles > 32 && (cycles % 7 < 4);
            @(posedge clk);
            if (input_valid && input_ready) sent++;
            if (result_valid && result_ready) begin
                if (result_ctrl.work_seq !== 32'(received+1)
                 || result_ctrl.acc_txn_tag !== 32'(received+100))
                    $fatal(1, "Metadata order lost at output %0d", received);
                for (int c = 0; c < `FPFP_MXU_COL; ++c)
                    if (result_data[c] !== expected(received, c))
                        $fatal(1, "FPFP output %0d column %0d got=%h expected=%h", received,c,result_data[c],expected(received,c));
                received++;
            end
            cycles++;
            @(negedge clk);
        end
        input_valid = 0;
        if (!idle) $fatal(1, "FPFP did not drain");
        $display("FPFP FRONT TEST PASSED ROW=%0d COL=%0d WLOAD=%0d transactions=%0d cycles=%0d", `FPFP_MXU_ROW, `FPFP_MXU_COL, `FPFP_MXU_WLOAD_NUM, received, cycles);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "FPFP front timeout");
    end
endmodule

config tb_gemm_fpfp_front_cfg;
    design work.tb_gemm_fpfp_front;
    default liblist work xil_defaultlib;
endconfig

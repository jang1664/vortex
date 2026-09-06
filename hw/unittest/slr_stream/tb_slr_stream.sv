`timescale 1ns/1ps

module slr_stream_case #(parameter int DATAW = 256) (
    output logic done = 0
);
    logic clk = 0;
    always #5 clk = !clk;
    logic reset = 1;
    logic valid_in = 0, ready_out = 0;
    wire ready_in, valid_out, idle_out;
    wire [DATAW-1:0] data_in, data_out;
    integer sent = 0, received = 0, cycle = 0;
    logic [31:0] random_q = 32'h13579bdf ^ DATAW;
    function automatic logic [DATAW-1:0] pattern(input integer seq);
        for (int i = 0; i < DATAW; i++)
            pattern[i] = ((32'(seq) * 32'h9e3779b9 + 32'(i/32)) >> (i % 32)) & 1;
    endfunction
    assign data_in = pattern(sent);
    VX_slr_stream #(.INSTANCE_ID ("test"), .DATAW (DATAW), .DEPTH (4)) dut (.*);

    always @(negedge clk) begin
        if (cycle >= 4) reset = 0;
        if (!reset && !done) begin
            // First fill and completely stall, then full-rate recovery, then
            // long bursts, random stalls and complete drain.
            ready_out = (cycle < 40) ? 0 :
                        (cycle < 250 || sent >= 2000) ? 1 :
                        ((cycle % 97) < 30 ? 0 : random_q[4]);
            if (!valid_in || ready_in)
                valid_in = sent < 2000 && (cycle < 250 || random_q[1]);
        end
    end
    always @(posedge clk) begin
        cycle <= cycle + 1;
        random_q <= {random_q[30:0], random_q[31]^random_q[21]^random_q[1]^random_q[0]};
        if (!reset && !done) begin
            if (valid_in && ready_in) sent <= sent + 1;
            if (valid_out && ready_out) begin
                assert (data_out === pattern(received))
                    else $fatal(1, "DATAW=%0d ordering/data mismatch at %0d", DATAW, received);
                received <= received + 1;
            end
            if (cycle > 60 && cycle < 240)
                assert (valid_out && ready_in)
                    else $fatal(1, "DATAW=%0d full-rate throughput bubble", DATAW);
            if (received == 2000 && idle_out) begin
                assert (sent == received && !valid_out)
                    else $fatal(1, "DATAW=%0d drain accounting", DATAW);
                done <= 1;
            end
            assert (cycle < 30000) else $fatal(1, "stream timeout");
        end
    end
endmodule

module tb_slr_stream;
    wire done32, done64;
    // Include representative request/tag/provenance sidebands as well as data.
    slr_stream_case #(.DATAW (256+96)) c32 (.done (done32));
    slr_stream_case #(.DATAW (512+96)) c64 (.done (done64));
    initial begin
        wait (done32 && done64);
        $display("TEST PASSED: SLR streams 32B/64B, 4000 ordered transactions, sustained rate, backpressure, drain");
        $finish;
    end
endmodule

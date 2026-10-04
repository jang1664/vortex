`timescale 1ns/1ps
// Reuse the production adapter's identity, address, AW/W pairing, credit and
// drain scoreboards. One physical port, continuous writes, fixed B latency.
module tb_write_depth_sweep;
    wire [7:0] done;
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(16), .RAW_ONLY(8),.FULL_SUITE(0)) d16(done[0]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(32), .RAW_ONLY(8),.FULL_SUITE(0)) d32(done[1]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(64), .RAW_ONLY(8),.FULL_SUITE(0)) d64(done[2]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(128),.RAW_ONLY(8),.FULL_SUITE(0)) d128(done[3]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(256),.RAW_ONLY(8),.FULL_SUITE(0)) d256(done[4]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(512),.RAW_ONLY(8),.FULL_SUITE(0)) d512(done[5]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(129),.RAW_ONLY(8),.FULL_SUITE(0)) d129(done[6]);
    axi_adapter_case #(.P(1),.H(1),.K(1),.TAGO(13),.WRITE_SLOTS(130),.RAW_ONLY(8),.FULL_SUITE(0)) d130(done[7]);
    initial begin
        wait (&done);
        $display("TEST PASSED: RAM write-depth sweep identity, saturation and steady throughput");
        $finish;
    end
endmodule

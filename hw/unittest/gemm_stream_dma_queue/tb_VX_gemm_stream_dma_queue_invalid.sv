`timescale 1ns/1ps

// Expected-failure elaboration/startup tests. The runner must require the
// corresponding DUT diagnostic, not merely a nonzero simulation return code.
module tb_VX_gemm_stream_dma_queue_invalid #(
    parameter int NEGATIVE_MODE = 1
);
    tb_stream_dma_queue_case #(
        .DEPTH(2), .DATAW(512), .SLOTS(8), .FETCH_TAGW(3),
        .RING_MODE(NEGATIVE_MODE != 4), .SINK_PIPE(1'b1),
        .RESPONSE_DATA_RAM(NEGATIVE_MODE != 3),
        .EARLY_SLOT_RELEASE(NEGATIVE_MODE != 2),
        .RESPONSE_STAGE_BYPASS(NEGATIVE_MODE != 1),
        .SINK_ELASTIC(NEGATIVE_MODE == 1),
        .EXPECT_SLOT_RECYCLE(1'b0)
    ) invalid_case (.done(), .compare_active(), .compare_bus());

    initial begin
        #1;
        $fatal(1, "INVALID_CONFIGURATION_WAS_ACCEPTED mode=%0d", NEGATIVE_MODE);
    end
endmodule

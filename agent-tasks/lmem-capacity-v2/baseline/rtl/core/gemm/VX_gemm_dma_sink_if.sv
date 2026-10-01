`include "VX_define.vh"

// Backend-independent ordered destination/install contract for a bounded
// GEMM operand DMA.  Writer-release is explicit so physical destination
// acceptance cannot be mistaken for fetch completion or generation install.
interface VX_gemm_dma_sink_if #(
    parameter `STRING INSTANCE_ID = "",
    parameter int PAYLOADW = 1,
    parameter int TAGW = 1,
    parameter int COUNTW = 32
) (
    input wire clk,
    input wire reset
);

    logic                write_valid;
    logic                write_ready;
    logic [TAGW-1:0]     write_tag;
    logic [PAYLOADW-1:0] write_payload;
    logic                write_owned;
    logic                writer_released;
    logic                write_last;

    logic                progress_valid;
    logic [COUNTW-1:0]   progress_total_beats;
    logic [COUNTW-1:0]   progress_write_beats;
    logic                install_complete;

    modport queue (
        output write_valid,
        input  write_ready,
        output write_tag,
        output write_payload,
        output write_owned,
        output writer_released,
        output write_last,
        output progress_valid,
        output progress_total_beats,
        output progress_write_beats,
        output install_complete
    );

    modport sink (
        input  write_valid,
        output write_ready,
        input  write_tag,
        input  write_payload
    );

    modport monitor (
        input write_valid,
        input write_ready,
        input write_tag,
        input write_payload,
        input write_owned,
        input writer_released,
        input write_last,
        input progress_valid,
        input progress_total_beats,
        input progress_write_beats,
        input install_complete
    );

    initial begin
        if ((PAYLOADW < 1) || (TAGW < 1) || (COUNTW < 1))
            $fatal(1, "%s: invalid GEMM DMA sink interface parameters",
                   INSTANCE_ID);
    end

`ifndef SYNTHESIS
    logic write_stall_r;
    logic [TAGW-1:0] write_stall_tag_r;
    logic [PAYLOADW-1:0] write_stall_payload_r;
    logic write_stall_owned_r;
    logic write_stall_released_r;
    logic write_stall_last_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            write_stall_r <= 1'b0;
            write_stall_tag_r <= '0;
            write_stall_payload_r <= '0;
            write_stall_owned_r <= 1'b0;
            write_stall_released_r <= 1'b0;
            write_stall_last_r <= 1'b0;
        end else begin
            if (write_stall_r) begin
                assert (write_valid
                     && (write_tag == write_stall_tag_r)
                     && (write_payload == write_stall_payload_r)
                     && (write_owned == write_stall_owned_r)
                     && (writer_released == write_stall_released_r)
                     && (write_last == write_stall_last_r))
                    else $fatal(1, "%s: DMA sink write changed while held",
                                INSTANCE_ID);
            end
            if (write_valid && write_ready) begin
                assert (write_owned && writer_released)
                    else $fatal(1, "%s: DMA sink accepted an unowned or fenced write tag=%0h",
                                INSTANCE_ID, write_tag);
            end
            assert (install_complete
                 == (write_valid && write_ready && write_owned
                  && writer_released && write_last))
                else $fatal(1, "%s: DMA install completion did not match final destination write",
                            INSTANCE_ID);
            if (progress_valid) begin
                assert ((progress_total_beats != 0)
                     && (progress_write_beats < progress_total_beats))
                    else $fatal(1, "%s: DMA sink progress escaped descriptor bounds",
                                INSTANCE_ID);
            end

            write_stall_r <= write_valid && !write_ready;
            if (write_valid && !write_ready) begin
                write_stall_tag_r <= write_tag;
                write_stall_payload_r <= write_payload;
                write_stall_owned_r <= write_owned;
                write_stall_released_r <= writer_released;
                write_stall_last_r <= write_last;
            end
        end
    end
`endif

endinterface

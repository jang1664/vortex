`include "VX_define.vh"
`ifdef GEMM_NAIVE
// No response payload returns: classify the actual committed bank write.
module VX_naive_lmem_commit_decode import VX_gpu_pkg::*; #(
    parameter TAGW = LMEM_LOCAL_TAG_WIDTH + 1,
    parameter PORTW = `LOG2UP(`LMEM_NUM_PORTS),
    parameter ADDRW = `LMEM_LOG_SIZE - `CLOG2(LSU_WORD_SIZE)
) (
    input wire write_fire,
    input wire [TAGW-1:0] tag,
    input wire [PORTW-1:0] port_id,
    input wire [ADDRW-1:0] word_addr,
    output logic [2:0] commit
);
    localparam PSUM_LANES = `GEMM_PSUM_DATA_SIZE / LSU_WORD_SIZE;
    localparam FINAL_LANES = `GEMM_OUTPUT_DATA_SIZE / LSU_WORD_SIZE;
    localparam PRIORITY_BIT = LMEM_LOCAL_TAG_WIDTH - UUID_WIDTH;
    localparam NORMAL_ROUTE_BIT = GEMM_LMEM_TAG_WIDTH - UUID_WIDTH;
    localparam WRITE_ROUTE_BIT = GEMM_BASE_TAG_WIDTH - UUID_WIDTH;
    wire [PORTW:0] write_lane = {1'b0, port_id} - (PORTW+1)'(NAIVE_LMEM_PW_OFFSET);
    always_comb begin
        commit = '0;
        if (write_fire) begin
            if (tag[PRIORITY_BIT]) begin
                if (tag[NORMAL_ROUTE_BIT +: `ARB_SEL_BITS(3, 1)] == 1)
                    commit = {2'b11, 1'b0};
            end else if (int'(port_id) >= NAIVE_LMEM_PW_OFFSET
                && int'(port_id) < NAIVE_LMEM_PW_OFFSET + PSUM_LANES) begin
                case (tag[WRITE_ROUTE_BIT +: `ARB_SEL_BITS(3, 1)])
                    0: commit = {2'b01, word_addr[`CLOG2(PSUM_LANES)]};
                    1: if (int'(write_lane) + `LMEM_NUM_PORTS < PSUM_LANES)
                        commit = {2'b01, word_addr[`CLOG2(PSUM_LANES)]};
                    2: if (int'(write_lane) < FINAL_LANES)
                        commit = {2'b10, 1'b0};
                    default: begin end
                endcase
            end
        end
    end
endmodule
`endif

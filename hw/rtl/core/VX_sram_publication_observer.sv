`include "VX_define.vh"
`ifdef GEMM_SRAM_FUSION
// Original before-buffer LSU admission predicate and all-pending-zero rule,
// kept together on SLR0. The only changed arithmetic input is a delayed,
// lossless physical commit count. Reset is the ORIGINAL global epoch.
module VX_sram_publication_observer import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter logic [63:0] GEMM_MMIO_SIZE = 64'd1024,
    parameter logic [63:0] DMA_MMIO_SIZE = 64'd1024
) (
    input wire clk,
    input wire reset,
    input wire [`NUM_LSU_BLOCKS-1:0] valid_i,
    input wire [`NUM_LSU_BLOCKS-1:0] ready_i,
    input wire [`NUM_LSU_BLOCKS-1:0] write_i,
    input wire [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0] mask_i,
    input wire [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0][`MEM_ADDR_WIDTH-$clog2(LSU_WORD_SIZE)-1:0] addr_i,
    input wire [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0][MEM_FLAGS_WIDTH-1:0] flags_i,
    input wire [$clog2(`LMEM_NUM_BANKS+1)-1:0] committed_count_i,
    output wire published_o,
    output wire [31:0] pending_o
);
    wire [`NUM_LSU_BLOCKS-1:0][`NUM_LSU_LANES-1:0] store_admit;
    wire [31:0] admitted_count = 32'($countones(store_admit));
    logic [31:0] pending_q;
    for (genvar b=0; b<`NUM_LSU_BLOCKS; ++b) begin : g_block
        for (genvar lane=0; lane<`NUM_LSU_LANES; ++lane) begin : g_lane
            wire [63:0] byte_addr = 64'(addr_i[b][lane]) << $clog2(LSU_WORD_SIZE);
            wire mmio_addr = ((byte_addr >= `GEMM_REG_BASE_ADDR)
                           && (byte_addr < `GEMM_REG_BASE_ADDR + GEMM_MMIO_SIZE))
                          || ((byte_addr >= `DMA_REG_BASE_ADDR)
                           && (byte_addr < `DMA_REG_BASE_ADDR + DMA_MMIO_SIZE));
            assign store_admit[b][lane] = valid_i[b] && ready_i[b] && write_i[b]
                && mask_i[b][lane] && flags_i[b][lane][MEM_REQ_FLAG_LOCAL] && !mmio_addr;
        end
    end
    always_ff @(posedge clk) begin
        if (reset) pending_q <= '0;
        else pending_q <= pending_q + admitted_count - 32'(committed_count_i);
    end
    assign published_o = (pending_q == 0) && (admitted_count == 0);
    assign pending_o = pending_q;
`ifndef SYNTHESIS
    always @(posedge clk) if (!reset)
        assert (32'(committed_count_i) <= pending_q + admitted_count)
            else $fatal(1,"%s: LMEM publication commit underflow",INSTANCE_ID);
`endif
endmodule
`endif

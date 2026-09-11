`include "VX_define.vh"
// Static elaboration probe: exact baseline dedicated Input/quant DMA + splitter.
// No clock generator, stimulus, runtime assertions, or functional simulation.
module p0_storage_probe import VX_gpu_pkg::*; (input wire clk, reset);
  for (genvar channel = 0; channel < 2; ++channel) begin : g_channel
    localparam BYTES = channel == 0 ? `GEMM_INPUT_DATA_SIZE : `GEMM_SCALE_ZERO_DATA_SIZE;
    localparam SLOTS = channel == 0 ? `I_LMEM_DMA_RD_OUTSTANDING_SLOTS : `SZ_LMEM_DMA_RD_OUTSTANDING_SLOTS;
    VX_lmem_dma_ctrl_if ctrl_if();
    VX_gemm_sync_if sync_if();
    VX_mem_bus_if #(.DATA_SIZE(BYTES), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) source_if(), sink_if();
    VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) lanes[BYTES/LSU_WORD_SIZE]();
    VX_lmem_dma_misal #(
      .INSTANCE_ID("storage"), .MAX_DIMS(1), .DIR(0), .TAG_WIDTH(GEMM_BASE_TAG_WIDTH),
      .LMEM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(BYTES)),
      .GEMM_ADDR_WIDTH_P(`MEM_ADDR_WIDTH - `CLOG2(BYTES)),
      .LMEM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH), .GEMM_TAG_WIDTH_P(GEMM_BASE_TAG_WIDTH),
      .RD_PREFETCH_DEPTH(SLOTS), .RD_OUTSTANDING(SLOTS), .ENABLE_MISALIGN(1'b1)
    ) dma (.clk(clk), .reset(reset), .ctrl_if(ctrl_if), .gemm_sync_if(sync_if),
           .lmem_bus_if(source_if), .gemm_bus_if(sink_if));
    VX_mem_bus_split #(.NUM_LANES(BYTES/LSU_WORD_SIZE), .LANE_DATA_SIZE(LSU_WORD_SIZE),
                       .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)) split
      (.clk(clk), .reset(reset), .wide_bus_if(source_if), .lane_bus_if(lanes));
  end
endmodule

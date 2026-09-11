`include "VX_define.vh"
// Static declaration elaboration only; no stimulus or functional simulation.
module p4_boundary_storage_probe import VX_gpu_pkg::*; (input wire clk, reset);
  VX_lsu_mem_if #(.NUM_LANES(`NUM_LSU_LANES), .DATA_SIZE(LSU_WORD_SIZE),
                  .TAG_WIDTH(LSU_TAG_WIDTH)) mmio[`NUM_LSU_BLOCKS](), dma();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH))
    ordinary[`LMEM_NUM_PORTS]();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(PSUM_LMEM_TAG_WIDTH))
    reads[`LMEM_NUM_PORTS]();
  VX_mem_bus_if #(.DATA_SIZE(LSU_WORD_SIZE), .TAG_WIDTH(PSUM_ARB_TAG_WIDTH))
    writes[`LMEM_NUM_PORTS]();
  VX_gemm_node_naive #(.N_MASTER(`NUM_LSU_BLOCKS), .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES)) node
    (.clk(clk), .reset(reset), .mmio_if(mmio), .dma_if(dma),
     .lmem_bus_if(ordinary), .psum_rd_lmem_bus_if(reads), .psum_wr_lmem_bus_if(writes), .naive_write_commit('0));
endmodule

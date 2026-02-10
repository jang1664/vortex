/*
  - Assumptions:
    - seg_size에 대한 어떠한 제한도 없다. DCACHE_BYTES 의 배수일 필요도 없고 LMEM_BYTES 보다 작아도 된다.
    - DCACHE_BYTES는 LMEM_BYTES의 배수라고 가정
    - control register에 start bit와 direction bit가 있다고 가정
    - bound는 loop을 도는 횟수라고 가정, src/dst가 동일한 횟수를 돌아야 하므로 bound는 3차원 하나만 존재 (src와 dst가 공유)
    - dma가 한 번에 연속적인 1D vector를 가져오는데, seg_size는 그 사이즈(바이트)이고 padding은 끝에서 몇 바이트가 zero padding인지 나타냄 (이것도 src와 dst가 공유)
    - zero padding은 끝에서 이만큼 0으로 채워서 쓴다고 가정 (seg_size보다 padding이 클 수 없음)
*/

`include "VX_define.vh"

module VX_gemm_dma_ctrl_with_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = ""
) (
  input wire clk,
  input wire reset,

  VX_gemm_dma_ctrl_if.slave gemm_dma_ctrl_if,     // from gemm_ctrl

  VX_mem_bus_if.master    dcache_bus_if, // to dcache
  VX_mem_bus_if.master    lmem_bus_if,   // to local memory
  VX_gemm_sync_if.master  gemm_sync_if
);
  // ------------------------------------------------------------
  // Descriptor layout
  // ------------------------------------------------------------
  localparam int NUM_REGS     = 16;
  localparam int REGS_DW      = 32;
  localparam int NDIM         = 3;
  localparam int NUM_ENTRIES  = 4;
  localparam int ENTRYID_W    = 4;

  localparam int CFG_NUM_LANES = 4;
  localparam int CFG_DATA_SIZE = 16; // bytes

  VX_lsu_mem_if #(
    .NUM_LANES(CFG_NUM_LANES),
    .DATA_SIZE(CFG_DATA_SIZE),
    .TAG_WIDTH(45)
  ) dma_if();

  VX_config_entry_alloc_if #(
    .OWNER_W(32),
    .ENTRYID_W(ENTRYID_W)
  ) alloc_if();

  VX_config_reg_if #(
    .NUM(NUM_REGS),
    .DW(REGS_DW)
  ) config_reg_if();

  VX_node_done_if node_done_if();

  initial begin
    if (config_reg_if.DW != REGS_DW) $fatal(1, "config_reg_if.DW must be 32");
    if (config_reg_if.NUM < NUM_REGS) $fatal(1, "config_reg_if.NUM(%0d) < NUM_REGS(%0d)", config_reg_if.NUM, NUM_REGS);
  end


  VX_gemm_dma_ctrl #(
    .DMA_CFG_STRIDE_BYTES(REGS_DW/8),
    .DMA_ENTRY_STRIDE_BYTES(NUM_REGS*REGS_DW/8),
    .ENTRYID_W(ENTRYID_W),
    .POLL_GAP_CYCLES(1),
    .ALLOC_RETRY_GAP_CYCLES(0)
  ) gemm_dma_ctrl (
    .clk(clk),
    .reset(reset),

    .alloc_if(alloc_if.master),
    .gemm_dma_ctrl_if(gemm_dma_ctrl_if),
    .gemm_sync_if(gemm_sync_if),
    .dma_if(dma_if.master)
  );

  VX_config_registers #(
    .NUM_ENTRIES(NUM_ENTRIES),
    .NUM_REGS32(NUM_REGS),
    .ENTRYID_W(ENTRYID_W)
  ) config_register (
    .clk(clk),
    .reset(reset),

    .alloc_if(alloc_if.slave),
    .mmio_if(dma_if.slave),
    .dma_issue_if(config_reg_if.master),
    .dma_done_if(node_done_if.slave)
  );

  VX_dma_node_misal #(.INSTANCE_ID("dma0")) dma_node (
    .clk          (clk),
    .reset        (reset),
    .cfg_reg_if   (config_reg_if.slave),
    .dcache_bus_if(dcache_bus_if),
    .lmem_bus_if  (lmem_bus_if),
    .done_if      (node_done_if.master)
  );


endmodule

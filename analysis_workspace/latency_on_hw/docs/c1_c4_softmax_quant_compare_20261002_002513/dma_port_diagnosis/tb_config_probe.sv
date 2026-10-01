`include "VX_define.vh"
module tb_config_probe import VX_gpu_pkg::*; ();
 initial begin
  $display("CONFIG_PROBE cpu_ports=%0d dcache_banks=%0d l1_mem_ports=%0d dma_ports=%0d lsu_lanes=%0d lsu_blocks=%0d line_bytes=%0d", DCACHE_NUM_REQS, `DCACHE_NUM_BANKS, `L1_MEM_PORTS, `DMA_DCACHE_PORTS, `NUM_LSU_LANES, `NUM_LSU_BLOCKS, DCACHE_WORD_SIZE);
  $finish;
 end
endmodule

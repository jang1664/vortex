`include "VX_define.vh"
// Flattened full naive node boundary; all protocol signals remain live.
module p4_naive_ooc import VX_gpu_pkg::*; #(
parameter N_MASTER=`NUM_LSU_BLOCKS,
parameter LANES=`NUM_LSU_LANES,
parameter WORD=LSU_WORD_SIZE,
parameter ADDRW=`MEM_ADDR_WIDTH-`CLOG2(WORD),
parameter LSU_REQW=LANES+1+LANES*(ADDRW+WORD*8+WORD+MEM_FLAGS_WIDTH)+LSU_TAG_WIDTH,
parameter LSU_RSPW=LANES+LANES*WORD*8+LSU_TAG_WIDTH,
parameter ORD_REQW=1+ADDRW+WORD*8+WORD+MEM_FLAGS_WIDTH+GEMM_LMEM_TAG_WIDTH,
parameter ORD_RSPW=WORD*8+GEMM_LMEM_TAG_WIDTH,
parameter RD_REQW=1+ADDRW+WORD*8+WORD+MEM_FLAGS_WIDTH+PSUM_LMEM_TAG_WIDTH,
parameter RD_RSPW=WORD*8+PSUM_LMEM_TAG_WIDTH,
parameter WR_REQW=1+ADDRW+WORD*8+WORD+MEM_FLAGS_WIDTH+PSUM_ARB_TAG_WIDTH,
parameter WR_RSPW=WORD*8+PSUM_ARB_TAG_WIDTH
)(
input wire clk, reset,
input wire [`LMEM_NUM_BANKS-1:0][2:0] write_commit,
input wire [N_MASTER-1:0] mmio_req_valid,
input wire [N_MASTER-1:0][LSU_REQW-1:0] mmio_req_data,
output wire [N_MASTER-1:0] mmio_req_ready,
output wire [N_MASTER-1:0] mmio_rsp_valid,
output wire [N_MASTER-1:0][LSU_RSPW-1:0] mmio_rsp_data,
input wire [N_MASTER-1:0] mmio_rsp_ready,
output wire [1-1:0] dma_req_valid,
output wire [1-1:0][LSU_REQW-1:0] dma_req_data,
input wire [1-1:0] dma_req_ready,
input wire [1-1:0] dma_rsp_valid,
input wire [1-1:0][LSU_RSPW-1:0] dma_rsp_data,
output wire [1-1:0] dma_rsp_ready,
output wire [`LMEM_NUM_PORTS-1:0] ordinary_req_valid,
output wire [`LMEM_NUM_PORTS-1:0][ORD_REQW-1:0] ordinary_req_data,
input wire [`LMEM_NUM_PORTS-1:0] ordinary_req_ready,
input wire [`LMEM_NUM_PORTS-1:0] ordinary_rsp_valid,
input wire [`LMEM_NUM_PORTS-1:0][ORD_RSPW-1:0] ordinary_rsp_data,
output wire [`LMEM_NUM_PORTS-1:0] ordinary_rsp_ready,
output wire [`LMEM_NUM_PORTS-1:0] reads_req_valid,
output wire [`LMEM_NUM_PORTS-1:0][RD_REQW-1:0] reads_req_data,
input wire [`LMEM_NUM_PORTS-1:0] reads_req_ready,
input wire [`LMEM_NUM_PORTS-1:0] reads_rsp_valid,
input wire [`LMEM_NUM_PORTS-1:0][RD_RSPW-1:0] reads_rsp_data,
output wire [`LMEM_NUM_PORTS-1:0] reads_rsp_ready,
output wire [`LMEM_NUM_PORTS-1:0] writes_req_valid,
output wire [`LMEM_NUM_PORTS-1:0][WR_REQW-1:0] writes_req_data,
input wire [`LMEM_NUM_PORTS-1:0] writes_req_ready,
input wire [`LMEM_NUM_PORTS-1:0] writes_rsp_valid,
input wire [`LMEM_NUM_PORTS-1:0][WR_RSPW-1:0] writes_rsp_data,
output wire [`LMEM_NUM_PORTS-1:0] writes_rsp_ready
);
VX_lsu_mem_if #(.NUM_LANES(LANES), .DATA_SIZE(WORD), .TAG_WIDTH(LSU_TAG_WIDTH)) mmio_if[N_MASTER]();
for (genvar i=0;i<N_MASTER;++i) begin : g_mmio
  assign mmio_if[i].req_valid = mmio_req_valid[i];
  assign mmio_if[i].req_data = mmio_req_data[i];
  assign mmio_req_ready[i] = mmio_if[i].req_ready;
  assign mmio_rsp_valid[i] = mmio_if[i].rsp_valid;
  assign mmio_rsp_data[i] = mmio_if[i].rsp_data;
  assign mmio_if[i].rsp_ready = mmio_rsp_ready[i];
end
initial begin
  assert ($bits(mmio_if[0].req_data)==LSU_REQW);
  assert ($bits(mmio_if[0].rsp_data)==LSU_RSPW);
end
VX_lsu_mem_if #(.NUM_LANES(LANES), .DATA_SIZE(WORD), .TAG_WIDTH(LSU_TAG_WIDTH)) dma_if[1]();
for (genvar i=0;i<1;++i) begin : g_dma
  assign dma_req_valid[i] = dma_if[i].req_valid;
  assign dma_req_data[i] = dma_if[i].req_data;
  assign dma_if[i].req_ready = dma_req_ready[i];
  assign dma_if[i].rsp_valid = dma_rsp_valid[i];
  assign dma_if[i].rsp_data = dma_rsp_data[i];
  assign dma_rsp_ready[i] = dma_if[i].rsp_ready;
end
initial begin
  assert ($bits(dma_if[0].req_data)==LSU_REQW);
  assert ($bits(dma_if[0].rsp_data)==LSU_RSPW);
end
VX_mem_bus_if #(.DATA_SIZE(WORD), .TAG_WIDTH(GEMM_LMEM_TAG_WIDTH)) ordinary_if[`LMEM_NUM_PORTS]();
for (genvar i=0;i<`LMEM_NUM_PORTS;++i) begin : g_ordinary
  assign ordinary_req_valid[i] = ordinary_if[i].req_valid;
  assign ordinary_req_data[i] = ordinary_if[i].req_data;
  assign ordinary_if[i].req_ready = ordinary_req_ready[i];
  assign ordinary_if[i].rsp_valid = ordinary_rsp_valid[i];
  assign ordinary_if[i].rsp_data = ordinary_rsp_data[i];
  assign ordinary_rsp_ready[i] = ordinary_if[i].rsp_ready;
end
initial begin
  assert ($bits(ordinary_if[0].req_data)==ORD_REQW);
  assert ($bits(ordinary_if[0].rsp_data)==ORD_RSPW);
end
VX_mem_bus_if #(.DATA_SIZE(WORD), .TAG_WIDTH(PSUM_LMEM_TAG_WIDTH)) reads_if[`LMEM_NUM_PORTS]();
for (genvar i=0;i<`LMEM_NUM_PORTS;++i) begin : g_reads
  assign reads_req_valid[i] = reads_if[i].req_valid;
  assign reads_req_data[i] = reads_if[i].req_data;
  assign reads_if[i].req_ready = reads_req_ready[i];
  assign reads_if[i].rsp_valid = reads_rsp_valid[i];
  assign reads_if[i].rsp_data = reads_rsp_data[i];
  assign reads_rsp_ready[i] = reads_if[i].rsp_ready;
end
initial begin
  assert ($bits(reads_if[0].req_data)==RD_REQW);
  assert ($bits(reads_if[0].rsp_data)==RD_RSPW);
end
VX_mem_bus_if #(.DATA_SIZE(WORD), .TAG_WIDTH(PSUM_ARB_TAG_WIDTH)) writes_if[`LMEM_NUM_PORTS]();
for (genvar i=0;i<`LMEM_NUM_PORTS;++i) begin : g_writes
  assign writes_req_valid[i] = writes_if[i].req_valid;
  assign writes_req_data[i] = writes_if[i].req_data;
  assign writes_if[i].req_ready = writes_req_ready[i];
  assign writes_if[i].rsp_valid = writes_rsp_valid[i];
  assign writes_if[i].rsp_data = writes_rsp_data[i];
  assign writes_rsp_ready[i] = writes_if[i].rsp_ready;
end
initial begin
  assert ($bits(writes_if[0].req_data)==WR_REQW);
  assert ($bits(writes_if[0].rsp_data)==WR_RSPW);
end
VX_gemm_node_naive #(.N_MASTER(N_MASTER), .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES)) node (
 .clk(clk),.reset(reset),.mmio_if(mmio_if),.dma_if(dma_if[0]),
 .lmem_bus_if(ordinary_if),.psum_rd_lmem_bus_if(reads_if),.psum_wr_lmem_bus_if(writes_if)
`ifndef P4_BASELINE_OOC
 ,.naive_write_commit(write_commit)
`endif
);
endmodule

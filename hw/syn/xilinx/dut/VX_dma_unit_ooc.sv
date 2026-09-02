`include "VX_define.vh"

// Out-of-context wrapper for the DMA-node backend.  The default port widths
// match VX_dma_node in VX_core: one cache-line-wide DCache port and one
// aggregate NUM_LSU_LANES-wide LMEM port.
module VX_dma_unit_ooc import VX_gpu_pkg::*; #(
    parameter int DCACHE_DATA_SIZE = DCACHE_WORD_SIZE,
    parameter int LMEM_DATA_SIZE   = `NUM_LSU_LANES * LSU_WORD_SIZE,
    parameter int DCACHE_TAG_WIDTH_P = DCACHE_TAG_WIDTH,
    parameter int LMEM_TAG_WIDTH_P   = LMEM_TAG_WIDTH,
    parameter int CFG_REGS = `DMA_CFG_REG_NUM,
    parameter int MISALIGN_PACK_BYTES = `MISALIGN_PACK_BYTES,
    parameter int RD_OUTSTANDING = `DMA_NODE_RD_OUTSTANDING_SLOT,
    parameter int FIXED_DIR = -1,
    parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
    parameter int MAX_DIMS = 3,
    parameter int DCACHE_ADDR_WIDTH = `MEM_ADDR_WIDTH - `CLOG2(DCACHE_DATA_SIZE),
    parameter int LMEM_ADDR_WIDTH   = `MEM_ADDR_WIDTH - `CLOG2(LMEM_DATA_SIZE)
) (
    input wire clk,
    input wire reset,

    input  wire [CFG_REGS-1:0][31:0] cfg_regs,
    input  wire [31:0] cfg_entry_id,
    input  wire cfg_valid,
    output wire cfg_ready,

    output wire done_valid,
    output wire [31:0] done_entry_id,
    input  wire done_ready,

    output wire dcache_req_valid,
    input  wire dcache_req_ready,
    output wire dcache_req_rw,
    output wire [DCACHE_ADDR_WIDTH-1:0] dcache_req_addr,
    output wire [DCACHE_DATA_SIZE*8-1:0] dcache_req_data,
    output wire [DCACHE_DATA_SIZE-1:0] dcache_req_byteen,
    output wire [MEM_FLAGS_WIDTH-1:0] dcache_req_flags,
    output wire [DCACHE_TAG_WIDTH_P-1:0] dcache_req_tag,
    input  wire dcache_rsp_valid,
    output wire dcache_rsp_ready,
    input  wire [DCACHE_DATA_SIZE*8-1:0] dcache_rsp_data,
    input  wire [DCACHE_TAG_WIDTH_P-1:0] dcache_rsp_tag,

    output wire lmem_req_valid,
    input  wire lmem_req_ready,
    output wire lmem_req_rw,
    output wire [LMEM_ADDR_WIDTH-1:0] lmem_req_addr,
    output wire [LMEM_DATA_SIZE*8-1:0] lmem_req_data,
    output wire [LMEM_DATA_SIZE-1:0] lmem_req_byteen,
    output wire [MEM_FLAGS_WIDTH-1:0] lmem_req_flags,
    output wire [LMEM_TAG_WIDTH_P-1:0] lmem_req_tag,
    input  wire lmem_rsp_valid,
    output wire lmem_rsp_ready,
    input  wire [LMEM_DATA_SIZE*8-1:0] lmem_rsp_data,
    input  wire [LMEM_TAG_WIDTH_P-1:0] lmem_rsp_tag
);

    VX_config_reg_if #(
        .NUM (CFG_REGS),
        .DW  (32)
    ) cfg_if ();

    VX_node_done_if done_if ();
    VX_dma_lookahead_if #(
        .BOUND_WIDTH (BOUND_WIDTH)
    ) lookahead_if ();

    assign lookahead_if.prepare_valid = 1'b0;
    assign lookahead_if.prepare_id = '0;
    assign lookahead_if.src_stride = '0;
    assign lookahead_if.dst_stride = '0;
    assign lookahead_if.bound = '0;
    assign lookahead_if.activate = 1'b0;
    assign lookahead_if.activate_id = '0;

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_DATA_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH_P)
    ) dcache_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (LMEM_DATA_SIZE),
        .TAG_WIDTH (LMEM_TAG_WIDTH_P)
    ) lmem_if ();

    assign cfg_if.regs = cfg_regs;
    assign cfg_if.entry_id = cfg_entry_id;
    assign cfg_if.valid = cfg_valid;
    assign cfg_ready = cfg_if.ready;

    assign done_valid = done_if.valid;
    assign done_entry_id = done_if.entry_id;
    assign done_if.ready = done_ready;

    assign dcache_req_valid = dcache_if.req_valid;
    assign dcache_if.req_ready = dcache_req_ready;
    assign dcache_req_rw = dcache_if.req_data.rw;
    assign dcache_req_addr = dcache_if.req_data.addr;
    assign dcache_req_data = dcache_if.req_data.data;
    assign dcache_req_byteen = dcache_if.req_data.byteen;
    assign dcache_req_flags = dcache_if.req_data.flags;
    assign dcache_req_tag = dcache_if.req_data.tag;
    assign dcache_if.rsp_valid = dcache_rsp_valid;
    assign dcache_rsp_ready = dcache_if.rsp_ready;
    assign dcache_if.rsp_data.data = dcache_rsp_data;
    assign dcache_if.rsp_data.tag = dcache_rsp_tag;

    assign lmem_req_valid = lmem_if.req_valid;
    assign lmem_if.req_ready = lmem_req_ready;
    assign lmem_req_rw = lmem_if.req_data.rw;
    assign lmem_req_addr = lmem_if.req_data.addr;
    assign lmem_req_data = lmem_if.req_data.data;
    assign lmem_req_byteen = lmem_if.req_data.byteen;
    assign lmem_req_flags = lmem_if.req_data.flags;
    assign lmem_req_tag = lmem_if.req_data.tag;
    assign lmem_if.rsp_valid = lmem_rsp_valid;
    assign lmem_rsp_ready = lmem_if.rsp_ready;
    assign lmem_if.rsp_data.data = lmem_rsp_data;
    assign lmem_if.rsp_data.tag = lmem_rsp_tag;

    VX_dma_unit #(
        .INSTANCE_ID         ("dma-node-ooc"),
        .ENABLE_MISALIGN     (1'b1),
        .BOUND_WIDTH         (BOUND_WIDTH),
        .MAX_DIMS            (MAX_DIMS),
        .DCACHE_ADDR_WIDTH   (DCACHE_ADDR_WIDTH),
        .LMEM_ADDR_WIDTH     (LMEM_ADDR_WIDTH),
        .DCACHE_TAG_WIDTH    (DCACHE_TAG_WIDTH_P),
        .LMEM_TAG_WIDTH      (LMEM_TAG_WIDTH_P),
        .MISALIGN_PACK_BYTES (MISALIGN_PACK_BYTES),
        .RD_OUTSTANDING      (RD_OUTSTANDING),
        .FIXED_DIR           (FIXED_DIR)
    ) u_dma_unit (
        .clk           (clk),
        .reset         (reset),
        .cfg_reg_if    (cfg_if),
        .lookahead_if  (lookahead_if),
        .dcache_bus_if (dcache_if),
        .lmem_bus_if   (lmem_if),
        .done_if       (done_if)
    );

endmodule

`include "VX_define.vh"

module VX_dma_engine_ooc import VX_gpu_pkg::*; #(
    parameter int NUM_CHANNELS   = `NUM_DMA_CHANNELS,
    parameter int DATA_SIZE      = `MEM_BLOCK_SIZE,
    parameter int AXI_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter int AXI_ID_WIDTH   = 8,
    parameter int TAG_WIDTH      = GEMM_BASE_TAG_WIDTH,
    parameter int MEM_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter int CFG_REGS       = `DMA_CFG_REG_NUM,
    parameter bit ENABLE_PADDING = 1'b1,
    parameter int BOUND_WIDTH = `DMA_BOUND_WIDTH,
    parameter int MAX_DIMS = 3,
    parameter int MISALIGN_PACK_BYTES = `MISALIGN_PACK_BYTES,
    parameter int AXI_DATA_WIDTH = DATA_SIZE * 8,
    parameter int MEM_ADDR_WORD_WIDTH = MEM_ADDR_WIDTH - `CLOG2(DATA_SIZE)
) (
    input wire clk,
    input wire reset,

    input  wire [NUM_CHANNELS-1:0][CFG_REGS-1:0][31:0] cfg_regs,
    input  wire [NUM_CHANNELS-1:0][31:0] cfg_entry_id,
    input  wire [NUM_CHANNELS-1:0] cfg_valid,
    output wire [NUM_CHANNELS-1:0] cfg_ready,

    output wire [NUM_CHANNELS-1:0] done_valid,
    output wire [NUM_CHANNELS-1:0][31:0] done_entry_id,
    input  wire [NUM_CHANNELS-1:0] done_ready,

    output wire [NUM_CHANNELS-1:0] axi_aw_valid,
    input  wire [NUM_CHANNELS-1:0] axi_aw_ready,
    output wire [NUM_CHANNELS-1:0][AXI_ADDR_WIDTH-1:0] axi_aw_addr,
    output wire [NUM_CHANNELS-1:0][AXI_ID_WIDTH-1:0] axi_aw_id,
    output wire [NUM_CHANNELS-1:0][7:0] axi_aw_len,
    output wire [NUM_CHANNELS-1:0][2:0] axi_aw_size,
    output wire [NUM_CHANNELS-1:0][1:0] axi_aw_burst,
    output wire [NUM_CHANNELS-1:0] axi_aw_lock,
    output wire [NUM_CHANNELS-1:0][3:0] axi_aw_cache,
    output wire [NUM_CHANNELS-1:0][2:0] axi_aw_prot,
    output wire [NUM_CHANNELS-1:0][3:0] axi_aw_qos,
    output wire [NUM_CHANNELS-1:0][3:0] axi_aw_region,
    output wire [NUM_CHANNELS-1:0][5:0] axi_aw_atop,

    output wire [NUM_CHANNELS-1:0] axi_w_valid,
    input  wire [NUM_CHANNELS-1:0] axi_w_ready,
    output wire [NUM_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] axi_w_data,
    output wire [NUM_CHANNELS-1:0][DATA_SIZE-1:0] axi_w_strb,
    output wire [NUM_CHANNELS-1:0] axi_w_last,

    input  wire [NUM_CHANNELS-1:0] axi_b_valid,
    output wire [NUM_CHANNELS-1:0] axi_b_ready,
    input  wire [NUM_CHANNELS-1:0][AXI_ID_WIDTH-1:0] axi_b_id,
    input  wire [NUM_CHANNELS-1:0][1:0] axi_b_resp,

    output wire [NUM_CHANNELS-1:0] axi_ar_valid,
    input  wire [NUM_CHANNELS-1:0] axi_ar_ready,
    output wire [NUM_CHANNELS-1:0][AXI_ADDR_WIDTH-1:0] axi_ar_addr,
    output wire [NUM_CHANNELS-1:0][AXI_ID_WIDTH-1:0] axi_ar_id,
    output wire [NUM_CHANNELS-1:0][7:0] axi_ar_len,
    output wire [NUM_CHANNELS-1:0][2:0] axi_ar_size,
    output wire [NUM_CHANNELS-1:0][1:0] axi_ar_burst,
    output wire [NUM_CHANNELS-1:0] axi_ar_lock,
    output wire [NUM_CHANNELS-1:0][3:0] axi_ar_cache,
    output wire [NUM_CHANNELS-1:0][2:0] axi_ar_prot,
    output wire [NUM_CHANNELS-1:0][3:0] axi_ar_qos,
    output wire [NUM_CHANNELS-1:0][3:0] axi_ar_region,

    input  wire [NUM_CHANNELS-1:0] axi_r_valid,
    output wire [NUM_CHANNELS-1:0] axi_r_ready,
    input  wire [NUM_CHANNELS-1:0][AXI_ID_WIDTH-1:0] axi_r_id,
    input  wire [NUM_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] axi_r_data,
    input  wire [NUM_CHANNELS-1:0][1:0] axi_r_resp,
    input  wire [NUM_CHANNELS-1:0] axi_r_last,

    output wire [NUM_CHANNELS-1:0] tmem_req_valid,
    input  wire [NUM_CHANNELS-1:0] tmem_req_ready,
    output wire [NUM_CHANNELS-1:0] tmem_req_rw,
    output wire [NUM_CHANNELS-1:0][MEM_ADDR_WORD_WIDTH-1:0] tmem_req_addr,
    output wire [NUM_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] tmem_req_data,
    output wire [NUM_CHANNELS-1:0][DATA_SIZE-1:0] tmem_req_byteen,
    output wire [NUM_CHANNELS-1:0][MEM_FLAGS_WIDTH-1:0] tmem_req_flags,
    output wire [NUM_CHANNELS-1:0][TAG_WIDTH-1:0] tmem_req_tag,
    input  wire [NUM_CHANNELS-1:0] tmem_rsp_valid,
    output wire [NUM_CHANNELS-1:0] tmem_rsp_ready,
    input  wire [NUM_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] tmem_rsp_data,
    input  wire [NUM_CHANNELS-1:0][TAG_WIDTH-1:0] tmem_rsp_tag
);

    VX_config_reg_if #(
        .NUM (CFG_REGS),
        .DW  (32)
    ) cfg_if [NUM_CHANNELS] ();

    VX_node_done_if done_if [NUM_CHANNELS] ();
    VX_dma_lookahead_if #(
        .BOUND_WIDTH (BOUND_WIDTH)
    ) lookahead_if [NUM_CHANNELS] ();

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_lookahead_tieoff
        assign lookahead_if[ch].prepare_valid = 1'b0;
        assign lookahead_if[ch].prepare_id = '0;
        assign lookahead_if[ch].src_stride = '0;
        assign lookahead_if[ch].dst_stride = '0;
        assign lookahead_if[ch].bound = '0;
        assign lookahead_if[ch].activate = 1'b0;
        assign lookahead_if[ch].activate_id = '0;
        assign lookahead_if[ch].data_release = 1'b1;
        assign lookahead_if[ch].data_max_beats = '0;
    end

    AXI_BUS #(
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .AXI_USER_WIDTH (1)
    ) axi_if [NUM_CHANNELS] ();

    VX_mem_bus_if #(
        .DATA_SIZE      (DATA_SIZE),
        .TAG_WIDTH      (TAG_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH)
    ) tmem_if [NUM_CHANNELS] ();

    for (genvar ch = 0; ch < NUM_CHANNELS; ++ch) begin : g_flatten
        assign cfg_if[ch].regs = cfg_regs[ch];
        assign cfg_if[ch].entry_id = cfg_entry_id[ch];
        assign cfg_if[ch].valid = cfg_valid[ch];
        assign cfg_ready[ch] = cfg_if[ch].ready;

        assign done_valid[ch] = done_if[ch].valid;
        assign done_entry_id[ch] = done_if[ch].entry_id;
        assign done_if[ch].ready = done_ready[ch];

        assign axi_aw_valid[ch] = axi_if[ch].aw_valid;
        assign axi_if[ch].aw_ready = axi_aw_ready[ch];
        assign axi_aw_addr[ch] = axi_if[ch].aw_addr;
        assign axi_aw_id[ch] = axi_if[ch].aw_id;
        assign axi_aw_len[ch] = axi_if[ch].aw_len;
        assign axi_aw_size[ch] = axi_if[ch].aw_size;
        assign axi_aw_burst[ch] = axi_if[ch].aw_burst;
        assign axi_aw_lock[ch] = axi_if[ch].aw_lock;
        assign axi_aw_cache[ch] = axi_if[ch].aw_cache;
        assign axi_aw_prot[ch] = axi_if[ch].aw_prot;
        assign axi_aw_qos[ch] = axi_if[ch].aw_qos;
        assign axi_aw_region[ch] = axi_if[ch].aw_region;
        assign axi_aw_atop[ch] = axi_if[ch].aw_atop;

        assign axi_w_valid[ch] = axi_if[ch].w_valid;
        assign axi_if[ch].w_ready = axi_w_ready[ch];
        assign axi_w_data[ch] = axi_if[ch].w_data;
        assign axi_w_strb[ch] = axi_if[ch].w_strb;
        assign axi_w_last[ch] = axi_if[ch].w_last;

        assign axi_if[ch].b_valid = axi_b_valid[ch];
        assign axi_b_ready[ch] = axi_if[ch].b_ready;
        assign axi_if[ch].b_id = axi_b_id[ch];
        assign axi_if[ch].b_resp = axi_b_resp[ch];
        assign axi_if[ch].b_user = '0;

        assign axi_ar_valid[ch] = axi_if[ch].ar_valid;
        assign axi_if[ch].ar_ready = axi_ar_ready[ch];
        assign axi_ar_addr[ch] = axi_if[ch].ar_addr;
        assign axi_ar_id[ch] = axi_if[ch].ar_id;
        assign axi_ar_len[ch] = axi_if[ch].ar_len;
        assign axi_ar_size[ch] = axi_if[ch].ar_size;
        assign axi_ar_burst[ch] = axi_if[ch].ar_burst;
        assign axi_ar_lock[ch] = axi_if[ch].ar_lock;
        assign axi_ar_cache[ch] = axi_if[ch].ar_cache;
        assign axi_ar_prot[ch] = axi_if[ch].ar_prot;
        assign axi_ar_qos[ch] = axi_if[ch].ar_qos;
        assign axi_ar_region[ch] = axi_if[ch].ar_region;

        assign axi_if[ch].r_valid = axi_r_valid[ch];
        assign axi_r_ready[ch] = axi_if[ch].r_ready;
        assign axi_if[ch].r_id = axi_r_id[ch];
        assign axi_if[ch].r_data = axi_r_data[ch];
        assign axi_if[ch].r_resp = axi_r_resp[ch];
        assign axi_if[ch].r_last = axi_r_last[ch];
        assign axi_if[ch].r_user = '0;

        assign tmem_req_valid[ch] = tmem_if[ch].req_valid;
        assign tmem_if[ch].req_ready = tmem_req_ready[ch];
        assign tmem_req_rw[ch] = tmem_if[ch].req_data.rw;
        assign tmem_req_addr[ch] = tmem_if[ch].req_data.addr;
        assign tmem_req_data[ch] = tmem_if[ch].req_data.data;
        assign tmem_req_byteen[ch] = tmem_if[ch].req_data.byteen;
        assign tmem_req_flags[ch] = tmem_if[ch].req_data.flags;
        assign tmem_req_tag[ch] = tmem_if[ch].req_data.tag;
        assign tmem_if[ch].rsp_valid = tmem_rsp_valid[ch];
        assign tmem_rsp_ready[ch] = tmem_if[ch].rsp_ready;
        assign tmem_if[ch].rsp_data.data = tmem_rsp_data[ch];
        assign tmem_if[ch].rsp_data.tag = tmem_rsp_tag[ch];
    end

`ifdef DMA_OOC_ENABLE_MISALIGN
    localparam bit ENABLE_MISALIGN = 1'b1;
`else
    localparam bit ENABLE_MISALIGN = 1'b0;
`endif

    VX_dma_engine #(
        .INSTANCE_ID    ("dma-ooc"),
        .NUM_CHANNELS   (NUM_CHANNELS),
        .DATA_WIDTH     (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .MEM_ADDR_WIDTH (MEM_ADDR_WIDTH),
        .TAG_WIDTH      (TAG_WIDTH),
        .MISALIGN_PACK_BYTES (MISALIGN_PACK_BYTES),
        .ENABLE_MISALIGN     (ENABLE_MISALIGN),
        .ENABLE_PADDING      (ENABLE_PADDING),
        .BOUND_WIDTH         (BOUND_WIDTH),
        .MAX_DIMS            (MAX_DIMS)
    ) u_dma_engine (
        .clk         (clk),
        .reset       (reset),
        .cfg_reg_if  (cfg_if),
        .lookahead_if(lookahead_if),
        .done_if     (done_if),
        .axi_m       (axi_if),
        .tmem_bus_if (tmem_if)
    );

endmodule

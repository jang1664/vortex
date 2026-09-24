// Copyright © 2019-2026
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

// Flatten the SystemVerilog interfaces at the OOC boundary.  Keeping every
// request, response, and handshake signal visible prevents synthesis from
// pruning inactive portions of VX_gemm_node because of constant tie-offs.
module VX_gemm_node_ooc import VX_gpu_pkg::*; #(
    parameter int N_MASTER = 1,
    parameter int NUM_DMA_CHANNELS = `NUM_DMA_CHANNELS,
    parameter int AXI_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH,
    parameter int AXI_DATA_WIDTH = `PLATFORM_MEMORY_DATA_SIZE * 8,
    parameter int AXI_ID_WIDTH = 8,
    parameter int AXI_USER_WIDTH = 1,
    parameter int MMIO_NUM_LANES = `NUM_LSU_LANES,
    parameter int MMIO_DATA_SIZE = LSU_WORD_SIZE,
    parameter int MMIO_TAG_WIDTH = LSU_TAG_WIDTH,
    parameter int MMIO_FLAGS_WIDTH = MEM_FLAGS_WIDTH,
    parameter int MMIO_ADDR_WIDTH =
        `MEM_ADDR_WIDTH - `CLOG2(MMIO_DATA_SIZE),
    parameter int MMIO_REQ_WIDTH =
        MMIO_NUM_LANES
        + 1
        + MMIO_NUM_LANES * MMIO_ADDR_WIDTH
        + MMIO_NUM_LANES * MMIO_DATA_SIZE * 8
        + MMIO_NUM_LANES * MMIO_DATA_SIZE
        + MMIO_NUM_LANES * MMIO_FLAGS_WIDTH
        + MMIO_TAG_WIDTH,
    parameter int MMIO_RSP_WIDTH =
        MMIO_NUM_LANES
        + MMIO_NUM_LANES * MMIO_DATA_SIZE * 8
        + MMIO_TAG_WIDTH
) (
    input  wire clk,
    input  wire reset,

    input  wire [N_MASTER-1:0] mmio_req_valid,
    input  wire [N_MASTER-1:0][MMIO_REQ_WIDTH-1:0] mmio_req_data,
    output wire [N_MASTER-1:0] mmio_req_ready,
    output wire [N_MASTER-1:0] mmio_rsp_valid,
    output wire [N_MASTER-1:0][MMIO_RSP_WIDTH-1:0] mmio_rsp_data,
    input  wire [N_MASTER-1:0] mmio_rsp_ready,

    output wire [NUM_DMA_CHANNELS-1:0][AXI_ID_WIDTH-1:0] dma_aw_id,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_ADDR_WIDTH-1:0] dma_aw_addr,
    output wire [NUM_DMA_CHANNELS-1:0][7:0] dma_aw_len,
    output wire [NUM_DMA_CHANNELS-1:0][2:0] dma_aw_size,
    output wire [NUM_DMA_CHANNELS-1:0][1:0] dma_aw_burst,
    output wire [NUM_DMA_CHANNELS-1:0] dma_aw_lock,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_aw_cache,
    output wire [NUM_DMA_CHANNELS-1:0][2:0] dma_aw_prot,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_aw_qos,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_aw_region,
    output wire [NUM_DMA_CHANNELS-1:0][5:0] dma_aw_atop,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_USER_WIDTH-1:0] dma_aw_user,
    output wire [NUM_DMA_CHANNELS-1:0] dma_aw_valid,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_aw_ready,

    output wire [NUM_DMA_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] dma_w_data,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_DATA_WIDTH/8-1:0] dma_w_strb,
    output wire [NUM_DMA_CHANNELS-1:0] dma_w_last,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_USER_WIDTH-1:0] dma_w_user,
    output wire [NUM_DMA_CHANNELS-1:0] dma_w_valid,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_w_ready,

    input  wire [NUM_DMA_CHANNELS-1:0][AXI_ID_WIDTH-1:0] dma_b_id,
    input  wire [NUM_DMA_CHANNELS-1:0][1:0] dma_b_resp,
    input  wire [NUM_DMA_CHANNELS-1:0][AXI_USER_WIDTH-1:0] dma_b_user,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_b_valid,
    output wire [NUM_DMA_CHANNELS-1:0] dma_b_ready,

    output wire [NUM_DMA_CHANNELS-1:0][AXI_ID_WIDTH-1:0] dma_ar_id,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_ADDR_WIDTH-1:0] dma_ar_addr,
    output wire [NUM_DMA_CHANNELS-1:0][7:0] dma_ar_len,
    output wire [NUM_DMA_CHANNELS-1:0][2:0] dma_ar_size,
    output wire [NUM_DMA_CHANNELS-1:0][1:0] dma_ar_burst,
    output wire [NUM_DMA_CHANNELS-1:0] dma_ar_lock,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_ar_cache,
    output wire [NUM_DMA_CHANNELS-1:0][2:0] dma_ar_prot,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_ar_qos,
    output wire [NUM_DMA_CHANNELS-1:0][3:0] dma_ar_region,
    output wire [NUM_DMA_CHANNELS-1:0][AXI_USER_WIDTH-1:0] dma_ar_user,
    output wire [NUM_DMA_CHANNELS-1:0] dma_ar_valid,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_ar_ready,

    input  wire [NUM_DMA_CHANNELS-1:0][AXI_ID_WIDTH-1:0] dma_r_id,
    input  wire [NUM_DMA_CHANNELS-1:0][AXI_DATA_WIDTH-1:0] dma_r_data,
    input  wire [NUM_DMA_CHANNELS-1:0][1:0] dma_r_resp,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_r_last,
    input  wire [NUM_DMA_CHANNELS-1:0][AXI_USER_WIDTH-1:0] dma_r_user,
    input  wire [NUM_DMA_CHANNELS-1:0] dma_r_valid,
    output wire [NUM_DMA_CHANNELS-1:0] dma_r_ready
);

    VX_lsu_mem_if #(
        .NUM_LANES (MMIO_NUM_LANES),
        .DATA_SIZE (MMIO_DATA_SIZE),
        .TAG_WIDTH (MMIO_TAG_WIDTH)
    ) mmio_if [N_MASTER] ();

    AXI_BUS #(
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .AXI_USER_WIDTH (AXI_USER_WIDTH)
    ) dma_axi [NUM_DMA_CHANNELS] ();

    for (genvar i = 0; i < N_MASTER; ++i) begin : g_mmio_flatten
        assign mmio_if[i].req_valid = mmio_req_valid[i];
        assign mmio_if[i].req_data  = mmio_req_data[i];
        assign mmio_req_ready[i]    = mmio_if[i].req_ready;
        assign mmio_rsp_valid[i]    = mmio_if[i].rsp_valid;
        assign mmio_rsp_data[i]     = mmio_if[i].rsp_data;
        assign mmio_if[i].rsp_ready = mmio_rsp_ready[i];
    end

    for (genvar i = 0; i < NUM_DMA_CHANNELS; ++i) begin : g_axi_flatten
        assign dma_aw_id[i]     = dma_axi[i].aw_id;
        assign dma_aw_addr[i]   = dma_axi[i].aw_addr;
        assign dma_aw_len[i]    = dma_axi[i].aw_len;
        assign dma_aw_size[i]   = dma_axi[i].aw_size;
        assign dma_aw_burst[i]  = dma_axi[i].aw_burst;
        assign dma_aw_lock[i]   = dma_axi[i].aw_lock;
        assign dma_aw_cache[i]  = dma_axi[i].aw_cache;
        assign dma_aw_prot[i]   = dma_axi[i].aw_prot;
        assign dma_aw_qos[i]    = dma_axi[i].aw_qos;
        assign dma_aw_region[i] = dma_axi[i].aw_region;
        assign dma_aw_atop[i]   = dma_axi[i].aw_atop;
        assign dma_aw_user[i]   = dma_axi[i].aw_user;
        assign dma_aw_valid[i]  = dma_axi[i].aw_valid;
        assign dma_axi[i].aw_ready = dma_aw_ready[i];

        assign dma_w_data[i]  = dma_axi[i].w_data;
        assign dma_w_strb[i]  = dma_axi[i].w_strb;
        assign dma_w_last[i]  = dma_axi[i].w_last;
        assign dma_w_user[i]  = dma_axi[i].w_user;
        assign dma_w_valid[i] = dma_axi[i].w_valid;
        assign dma_axi[i].w_ready = dma_w_ready[i];

        assign dma_axi[i].b_id    = dma_b_id[i];
        assign dma_axi[i].b_resp  = dma_b_resp[i];
        assign dma_axi[i].b_user  = dma_b_user[i];
        assign dma_axi[i].b_valid = dma_b_valid[i];
        assign dma_b_ready[i]     = dma_axi[i].b_ready;

        assign dma_ar_id[i]     = dma_axi[i].ar_id;
        assign dma_ar_addr[i]   = dma_axi[i].ar_addr;
        assign dma_ar_len[i]    = dma_axi[i].ar_len;
        assign dma_ar_size[i]   = dma_axi[i].ar_size;
        assign dma_ar_burst[i]  = dma_axi[i].ar_burst;
        assign dma_ar_lock[i]   = dma_axi[i].ar_lock;
        assign dma_ar_cache[i]  = dma_axi[i].ar_cache;
        assign dma_ar_prot[i]   = dma_axi[i].ar_prot;
        assign dma_ar_qos[i]    = dma_axi[i].ar_qos;
        assign dma_ar_region[i] = dma_axi[i].ar_region;
        assign dma_ar_user[i]   = dma_axi[i].ar_user;
        assign dma_ar_valid[i]  = dma_axi[i].ar_valid;
        assign dma_axi[i].ar_ready = dma_ar_ready[i];

        assign dma_axi[i].r_id    = dma_r_id[i];
        assign dma_axi[i].r_data  = dma_r_data[i];
        assign dma_axi[i].r_resp  = dma_r_resp[i];
        assign dma_axi[i].r_last  = dma_r_last[i];
        assign dma_axi[i].r_user  = dma_r_user[i];
        assign dma_axi[i].r_valid = dma_r_valid[i];
        assign dma_r_ready[i]     = dma_axi[i].r_ready;
    end

    VX_gemm_node #(
        .INSTANCE_ID      ("gemm_node_ooc"),
        .N_MASTER         (N_MASTER),
        .N_CHILDREN       (6),
        .NUM_TMEM_BANKS   (`NUM_TMEM_BANKS),
        .NUM_DMA_CHANNELS (NUM_DMA_CHANNELS)
    ) u_gemm_node (
        .clk       (clk),
        .reset     (reset),
        .mmio_if   (mmio_if),
        .dma_axi_m (dma_axi)
    );

endmodule

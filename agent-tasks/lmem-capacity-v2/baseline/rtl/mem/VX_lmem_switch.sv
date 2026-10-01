// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_lmem_switch import VX_gpu_pkg::*; #(
    parameter GLOBAL_OUT_BUF = 0,
    parameter LOCAL_OUT_BUF = 0,
    parameter GEMM_OUT_BUF = 0,
    parameter DMA_OUT_BUF = 0,
    parameter RSP_OUT_BUF = 0,
    parameter logic [63:0] GEMM_MMIO_BASE_ADDR = `GEMM_REG_BASE_ADDR,
    parameter logic [63:0] DMA_MMIO_BASE_ADDR  = `DMA_REG_BASE_ADDR,
    parameter logic [63:0] GEMM_MMIO_SIZE      = 64'd4096,
    parameter logic [63:0] DMA_MMIO_SIZE       = 64'd4096,
    parameter `STRING ARBITER = "R"
) (
    input wire              clk,
    input wire              reset,
    VX_lsu_mem_if.slave     lsu_in_if,
    VX_lsu_mem_if.master    global_out_if,
    VX_lsu_mem_if.master    local_out_if,
    VX_lsu_mem_if.master    gemm_ctrl_if,
    VX_lsu_mem_if.master    dma_ctrl_if
);
    localparam int NUM_LANES = `NUM_LSU_LANES;
    localparam int REQ_DATAW = `NUM_LSU_LANES
                             + 1
                             + `NUM_LSU_LANES * (LSU_WORD_SIZE
                                               + LSU_ADDR_WIDTH
                                               + MEM_FLAGS_WIDTH
                                               + LSU_WORD_SIZE * 8)
                             + LSU_TAG_WIDTH;
    localparam int RSP_DATAW = `NUM_LSU_LANES
                             + `NUM_LSU_LANES * (LSU_WORD_SIZE * 8)
                             + LSU_TAG_WIDTH;
    localparam int ADDR_SHIFT = `CLOG2(LSU_WORD_SIZE);

    function automatic logic [63:0] to_byte_addr(input logic [63:0] addr);
        return (addr << ADDR_SHIFT);
    endfunction

    initial begin
        if (DMA_MMIO_SIZE == 0 || GEMM_MMIO_SIZE == 0)
            $fatal(1, "VX_lmem_switch: MMIO size must be non-zero");
        if ((DMA_MMIO_BASE_ADDR < (GEMM_MMIO_BASE_ADDR + GEMM_MMIO_SIZE))
         && (GEMM_MMIO_BASE_ADDR < (DMA_MMIO_BASE_ADDR + DMA_MMIO_SIZE))) begin
            $fatal(1, "VX_lmem_switch: GEMM/DMA MMIO windows overlap");
        end
    end

    wire [NUM_LANES-1:0] is_addr_dma_mask;
    wire [NUM_LANES-1:0] is_addr_gemm_mask;
    wire [NUM_LANES-1:0] is_addr_local_mask;
    wire [NUM_LANES-1:0] is_addr_global_mask;

    wire req_global_ready;
    wire req_local_ready;
    wire req_gemm_ready;
    wire req_dma_ready;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_decode
        wire [63:0] lane_byte_addr = to_byte_addr(64'(lsu_in_if.req_data.addr[i]));
        wire lane_is_dma  = (lane_byte_addr >= DMA_MMIO_BASE_ADDR)
                         && (lane_byte_addr < (DMA_MMIO_BASE_ADDR + DMA_MMIO_SIZE));
        wire lane_is_gemm = (lane_byte_addr >= GEMM_MMIO_BASE_ADDR)
                         && (lane_byte_addr < (GEMM_MMIO_BASE_ADDR + GEMM_MMIO_SIZE));

        assign is_addr_dma_mask[i]   = lane_is_dma;
        assign is_addr_gemm_mask[i]  = lane_is_gemm && ~lane_is_dma;
        assign is_addr_local_mask[i] = lsu_in_if.req_data.flags[i][MEM_REQ_FLAG_LOCAL]
                                    && ~(is_addr_dma_mask[i] || is_addr_gemm_mask[i]);
        assign is_addr_global_mask[i] = ~(is_addr_dma_mask[i]
                                       || is_addr_gemm_mask[i]
                                       || is_addr_local_mask[i]);
    end

    wire is_addr_global = | (lsu_in_if.req_data.mask & is_addr_global_mask);
    wire is_addr_local  = | (lsu_in_if.req_data.mask & is_addr_local_mask);
    wire is_addr_gemm   = | (lsu_in_if.req_data.mask & is_addr_gemm_mask);
    wire is_addr_dma    = | (lsu_in_if.req_data.mask & is_addr_dma_mask);

    // Backpressure-safe split: all active destinations must be ready.
    assign lsu_in_if.req_ready = (~is_addr_global || req_global_ready)
                              && (~is_addr_local  || req_local_ready)
                              && (~is_addr_gemm   || req_gemm_ready)
                              && (~is_addr_dma    || req_dma_ready);

    VX_elastic_buffer #(
        .DATAW   (REQ_DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(GLOBAL_OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(GLOBAL_OUT_BUF))
    ) req_global_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (lsu_in_if.req_valid && is_addr_global),
        .data_in   ({
            lsu_in_if.req_data.mask & is_addr_global_mask,
            lsu_in_if.req_data.rw,
            lsu_in_if.req_data.addr,
            lsu_in_if.req_data.data,
            lsu_in_if.req_data.byteen,
            lsu_in_if.req_data.flags,
            lsu_in_if.req_data.tag
        }),
        .ready_in  (req_global_ready),
        .valid_out (global_out_if.req_valid),
        .data_out  (global_out_if.req_data),
        .ready_out (global_out_if.req_ready)
    );

    VX_elastic_buffer #(
        .DATAW   (REQ_DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(LOCAL_OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(LOCAL_OUT_BUF))
    ) req_local_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (lsu_in_if.req_valid && is_addr_local),
        .data_in   ({
            lsu_in_if.req_data.mask & is_addr_local_mask,
            lsu_in_if.req_data.rw,
            lsu_in_if.req_data.addr,
            lsu_in_if.req_data.data,
            lsu_in_if.req_data.byteen,
            lsu_in_if.req_data.flags,
            lsu_in_if.req_data.tag
        }),
        .ready_in  (req_local_ready),
        .valid_out (local_out_if.req_valid),
        .data_out  (local_out_if.req_data),
        .ready_out (local_out_if.req_ready)
    );

    VX_elastic_buffer #(
        .DATAW   (REQ_DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(GEMM_OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(GEMM_OUT_BUF))
    ) req_gemm_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (lsu_in_if.req_valid && is_addr_gemm),
        .data_in   ({
            lsu_in_if.req_data.mask & is_addr_gemm_mask,
            lsu_in_if.req_data.rw,
            lsu_in_if.req_data.addr,
            lsu_in_if.req_data.data,
            lsu_in_if.req_data.byteen,
            lsu_in_if.req_data.flags,
            lsu_in_if.req_data.tag
        }),
        .ready_in  (req_gemm_ready),
        .valid_out (gemm_ctrl_if.req_valid),
        .data_out  (gemm_ctrl_if.req_data),
        .ready_out (gemm_ctrl_if.req_ready)
    );

    VX_elastic_buffer #(
        .DATAW   (REQ_DATAW),
        .SIZE    (`TO_OUT_BUF_SIZE(DMA_OUT_BUF)),
        .OUT_REG (`TO_OUT_BUF_REG(DMA_OUT_BUF))
    ) req_dma_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (lsu_in_if.req_valid && is_addr_dma),
        .data_in   ({
            lsu_in_if.req_data.mask & is_addr_dma_mask,
            lsu_in_if.req_data.rw,
            lsu_in_if.req_data.addr,
            lsu_in_if.req_data.data,
            lsu_in_if.req_data.byteen,
            lsu_in_if.req_data.flags,
            lsu_in_if.req_data.tag
        }),
        .ready_in  (req_dma_ready),
        .valid_out (dma_ctrl_if.req_valid),
        .data_out  (dma_ctrl_if.req_data),
        .ready_out (dma_ctrl_if.req_ready)
    );

    VX_stream_arb #(
        .NUM_INPUTS (4),
        .DATAW      (RSP_DATAW),
        .ARBITER    (ARBITER),
        .OUT_BUF    (RSP_OUT_BUF)
    ) rsp_arb (
        .clk       (clk),
        .reset     (reset),
        .valid_in  ({
            dma_ctrl_if.rsp_valid,
            gemm_ctrl_if.rsp_valid,
            local_out_if.rsp_valid,
            global_out_if.rsp_valid
        }),
        .ready_in  ({
            dma_ctrl_if.rsp_ready,
            gemm_ctrl_if.rsp_ready,
            local_out_if.rsp_ready,
            global_out_if.rsp_ready
        }),
        .data_in   ({
            dma_ctrl_if.rsp_data,
            gemm_ctrl_if.rsp_data,
            local_out_if.rsp_data,
            global_out_if.rsp_data
        }),
        .data_out  (lsu_in_if.rsp_data),
        .valid_out (lsu_in_if.rsp_valid),
        .ready_out (lsu_in_if.rsp_ready),
        `UNUSED_PIN (sel_out)
    );

endmodule

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

module VX_lsu_mem_zero_rsp import VX_gpu_pkg::*; #(
    parameter NUM_LANES = `NUM_LSU_LANES,
    parameter DATA_SIZE = LSU_WORD_SIZE,
    parameter TAG_WIDTH = LSU_TAG_WIDTH
) (
    input wire          clk,
    input wire          reset,

    VX_lsu_mem_if.slave mem_if
);
    logic rsp_valid_r;
    logic [NUM_LANES-1:0] rsp_mask_r;
    logic [TAG_WIDTH-1:0] rsp_tag_r;

    wire rsp_fire    = rsp_valid_r && mem_if.rsp_ready;
    wire rsp_holding = rsp_valid_r && ~mem_if.rsp_ready;
    wire req_fire    = mem_if.req_valid && mem_if.req_ready;

    assign mem_if.req_ready     = ~rsp_holding;
    assign mem_if.rsp_valid     = rsp_valid_r;
    assign mem_if.rsp_data.mask = rsp_mask_r;
    assign mem_if.rsp_data.data = '0;
    assign mem_if.rsp_data.tag  = rsp_tag_r;

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid_r <= 1'b0;
            rsp_mask_r  <= '0;
            rsp_tag_r   <= '0;
        end else begin
            if (rsp_fire) begin
                rsp_valid_r <= 1'b0;
                rsp_mask_r  <= '0;
                rsp_tag_r   <= '0;
            end
            if (req_fire && ~mem_if.req_data.rw) begin
                rsp_valid_r <= 1'b1;
                rsp_mask_r  <= mem_if.req_data.mask;
                rsp_tag_r   <= mem_if.req_data.tag;
            end
        end
    end

    `UNUSED_VAR (mem_if.req_data.addr)
    `UNUSED_VAR (mem_if.req_data.data)
    `UNUSED_VAR (mem_if.req_data.byteen)
    `UNUSED_VAR (mem_if.req_data.flags)

endmodule

// Copyright (c) 2019-2026
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

module VX_hw_debug_vr_probe import VX_gpu_pkg::*; (
    input  wire              clk,
    input  wire              reset,

    input  wire              valid,
    input  wire              ready,
    input  wire [NW_WIDTH-1:0] wid,
    input  wire [15:0]       tag,
    input  wire [15:0]       payload_hash,

    output hw_debug_vr_t     debug
);

    reg        stalled_q;
    reg [15:0] payload_hash_q;

    wire stall = valid && !ready;
    wire payload_changed = stall && stalled_q && (payload_hash != payload_hash_q);

    always @(posedge clk) begin
        if (reset) begin
            stalled_q      <= 1'b0;
            payload_hash_q <= '0;
            debug          <= '0;
        end else begin
            stalled_q <= stall;
            if (!stall || !stalled_q) begin
                payload_hash_q <= payload_hash;
            end
            debug.valid           <= valid;
            debug.ready           <= ready;
            debug.fire            <= valid && ready;
            debug.stall           <= stall;
            debug.payload_changed <= payload_changed;
            debug.wid             <= wid;
            debug.tag             <= tag;
        end
    end

endmodule

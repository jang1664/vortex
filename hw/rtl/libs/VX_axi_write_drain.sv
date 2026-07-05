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

`include "VX_platform.vh"

`TRACING_OFF
module VX_axi_write_drain #(
    parameter COUNT_WIDTH   = 32,
    parameter PENDING_WIDTH = 12
) (
    input wire                      clk,
    input wire                      reset,

    input wire                      awvalid,
    input wire                      awready,
    input wire [7:0]                awlen,

    input wire                      wvalid,
    input wire                      wready,
    input wire                      wlast,

    input wire                      bvalid,
    input wire                      bready,

    output wire                     aw_fire,
    output wire                     w_fire,
    output wire                     wlast_fire,
    output wire                     b_fire,
    output wire                     pending_empty,

    output reg [COUNT_WIDTH-1:0]    aw_handshake_cnt,
    output reg [COUNT_WIDTH-1:0]    aw_burst_total_cnt,
    output reg [COUNT_WIDTH-1:0]    w_handshake_cnt,
    output reg [COUNT_WIDTH-1:0]    wlast_cnt,
    output reg [COUNT_WIDTH-1:0]    b_handshake_cnt,
    output wire [PENDING_WIDTH-1:0] pending_writes
);

    assign aw_fire    = awvalid && awready;
    assign w_fire     = wvalid && wready;
    assign wlast_fire = w_fire && wlast;
    assign b_fire     = bvalid && bready;

    wire [COUNT_WIDTH-1:0] aw_burst_beats = COUNT_WIDTH'(awlen) + COUNT_WIDTH'(1);

    always @(posedge clk) begin
        if (reset) begin
            aw_handshake_cnt   <= '0;
            aw_burst_total_cnt <= '0;
            w_handshake_cnt    <= '0;
            wlast_cnt          <= '0;
            b_handshake_cnt    <= '0;
        end else begin
            if (aw_fire) begin
                aw_handshake_cnt   <= aw_handshake_cnt + COUNT_WIDTH'(1);
                aw_burst_total_cnt <= aw_burst_total_cnt + aw_burst_beats;
            end
            if (w_fire) begin
                w_handshake_cnt <= w_handshake_cnt + COUNT_WIDTH'(1);
            end
            if (wlast_fire) begin
                wlast_cnt <= wlast_cnt + COUNT_WIDTH'(1);
            end
            if (b_fire) begin
                b_handshake_cnt <= b_handshake_cnt + COUNT_WIDTH'(1);
            end
        end
    end

    assign pending_empty = (aw_handshake_cnt == b_handshake_cnt)
                        && (aw_handshake_cnt == wlast_cnt)
                        && (aw_burst_total_cnt == w_handshake_cnt);

    assign pending_writes = PENDING_WIDTH'(aw_handshake_cnt - b_handshake_cnt);

endmodule
`TRACING_ON

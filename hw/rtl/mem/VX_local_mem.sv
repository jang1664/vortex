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

module VX_local_mem import VX_gpu_pkg::*; #(
    parameter `STRING  INSTANCE_ID = "",

    // Size of cache in bytes
    parameter SIZE              = (1024*16*8),

    // Number of Word requests per cycle
    parameter NUM_REQS          = 4,
    // Number of banks
    parameter NUM_BANKS         = 4,

    // Address width
    parameter ADDR_WIDTH        = `CLOG2(SIZE),
    // Size of a word in bytes
    parameter WORD_SIZE         = `XLEN/8,

    // Request tag size
    parameter TAG_WIDTH         = 16,

    // Response buffer
    parameter OUT_BUF           = 0
 ) (
    input wire clk,
    input wire reset,

    // PERF
`ifdef PERF_ENABLE
    output lmem_perf_t lmem_perf,
`endif

    VX_mem_bus_if.slave mem_bus_if [NUM_REQS]
);
    `UNUSED_SPARAM (INSTANCE_ID)

    localparam REQ_SEL_BITS    = `CLOG2(NUM_REQS);
    localparam REQ_SEL_WIDTH   = `UP(REQ_SEL_BITS);
    localparam WORD_WIDTH      = WORD_SIZE * 8;
    localparam NUM_WORDS       = SIZE / WORD_SIZE;
    localparam WORDS_PER_BANK  = NUM_WORDS / NUM_BANKS;
    localparam BANK_ADDR_WIDTH = `CLOG2(WORDS_PER_BANK);
    localparam BANK_SEL_BITS   = `CLOG2(NUM_BANKS);
    localparam BANK_SEL_WIDTH  = `UP(BANK_SEL_BITS);
    localparam REQ_DATAW       = 1 + BANK_ADDR_WIDTH + WORD_SIZE + WORD_WIDTH + TAG_WIDTH;
    localparam RSP_DATAW       = WORD_WIDTH + TAG_WIDTH;
    localparam LMEM_XBAR_FANOUT_VALID = (`LMEM_XBAR_MAX_FANOUT == 0)
                                     || ((`LMEM_XBAR_MAX_FANOUT >= 2)
                                      && `IS_POW2(`LMEM_XBAR_MAX_FANOUT));

`ifdef LMEM_REQ_OMEGA_ENABLE
`ifdef LMEM_RSP_OMEGA_ENABLE
    `UNUSED_PARAM (LMEM_XBAR_FANOUT_VALID)
`endif
`endif

    `VX_STATIC_ASSERT(ADDR_WIDTH == (BANK_ADDR_WIDTH + `CLOG2(NUM_BANKS)), ("invalid parameter"))

`ifndef LMEM_REQ_OMEGA_ENABLE
    `VX_STATIC_ASSERT(LMEM_XBAR_FANOUT_VALID, ("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", `LMEM_XBAR_MAX_FANOUT))
`endif
`ifndef LMEM_RSP_OMEGA_ENABLE
    `VX_STATIC_ASSERT(LMEM_XBAR_FANOUT_VALID, ("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", `LMEM_XBAR_MAX_FANOUT))
`endif

    // bank selection

    wire [NUM_REQS-1:0][BANK_SEL_WIDTH-1:0] req_bank_idx;
    if (NUM_BANKS > 1) begin : g_req_bank_idx
        for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_bank_idxs
            assign req_bank_idx[i] = mem_bus_if[i].req_data.addr[0 +: BANK_SEL_BITS];
        end
    end else begin : g_req_bank_idx_0
        assign req_bank_idx = 0;
    end

    // bank addressing

    wire [NUM_REQS-1:0][BANK_ADDR_WIDTH-1:0] req_bank_addr;
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_bank_addr
        assign req_bank_addr[i] = mem_bus_if[i].req_data.addr[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
        `UNUSED_VAR (mem_bus_if[i].req_data.flags)
    end

    // bank requests dispatch

    wire [NUM_BANKS-1:0]                    per_bank_req_valid;
    wire [NUM_BANKS-1:0]                    per_bank_req_rw;
    wire [NUM_BANKS-1:0][BANK_ADDR_WIDTH-1:0] per_bank_req_addr;
    wire [NUM_BANKS-1:0][WORD_SIZE-1:0]     per_bank_req_byteen;
    wire [NUM_BANKS-1:0][WORD_WIDTH-1:0]    per_bank_req_data;
    wire [NUM_BANKS-1:0][TAG_WIDTH-1:0]     per_bank_req_tag;
    wire [NUM_BANKS-1:0][REQ_SEL_WIDTH-1:0] per_bank_req_idx;
    wire [NUM_BANKS-1:0]                    per_bank_req_ready;

    wire [NUM_BANKS-1:0][REQ_DATAW-1:0]     per_bank_req_data_aos;

    wire [NUM_REQS-1:0]                 req_valid_in;
    wire [NUM_REQS-1:0][REQ_DATAW-1:0]  req_data_in;
    wire [NUM_REQS-1:0]                 req_ready_in;

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_data_in
        assign req_valid_in[i] = mem_bus_if[i].req_valid;
        assign req_data_in[i] = {
            mem_bus_if[i].req_data.rw,
            req_bank_addr[i],
            mem_bus_if[i].req_data.data,
            mem_bus_if[i].req_data.byteen,
            mem_bus_if[i].req_data.tag
        };
        assign mem_bus_if[i].req_ready = req_ready_in[i];
    end

`ifdef LMEM_REQ_OMEGA_ENABLE
    VX_stream_omega #(
        .NUM_INPUTS    (NUM_REQS),
        .NUM_OUTPUTS   (NUM_BANKS),
        .RADIX         (2),
        .DATAW         (REQ_DATAW),
        .PERF_CTR_BITS (PERF_CTR_BITS),
        .ARBITER       ("P"),
        .OUT_BUF       (3) // output should be registered for the data_store addressing
    ) req_xbar (
        .clk       (clk),
        .reset     (reset),
        `UNUSED_PIN (collisions),
        .valid_in  (req_valid_in),
        .data_in   (req_data_in),
        .sel_in    (req_bank_idx),
        .ready_in  (req_ready_in),
        .valid_out (per_bank_req_valid),
        .data_out  (per_bank_req_data_aos),
        .sel_out   (per_bank_req_idx),
        .ready_out (per_bank_req_ready)
    );
`else
    if (LMEM_XBAR_FANOUT_VALID) begin : g_req_hier_valid
        VX_stream_xbar #(
            .NUM_INPUTS    (NUM_REQS),
            .NUM_OUTPUTS   (NUM_BANKS),
            .DATAW         (REQ_DATAW),
            .PERF_CTR_BITS (PERF_CTR_BITS),
            .ARBITER       ("P"),
            .OUT_BUF       (3), // output should be registered for the data_store addressing
            .MAX_FANOUT    (`LMEM_XBAR_MAX_FANOUT)
        ) req_xbar (
            .clk       (clk),
            .reset     (reset),
            `UNUSED_PIN (collisions),
            .valid_in  (req_valid_in),
            .data_in   (req_data_in),
            .sel_in    (req_bank_idx),
            .ready_in  (req_ready_in),
            .valid_out (per_bank_req_valid),
            .data_out  (per_bank_req_data_aos),
            .sel_out   (per_bank_req_idx),
            .ready_out (per_bank_req_ready)
        );
    end else begin : g_req_hier_invalid
        assign per_bank_req_valid    = '0;
        assign per_bank_req_data_aos = '0;
        assign per_bank_req_idx      = '0;
        assign req_ready_in          = '0;
        `UNUSED_VAR (req_data_in)
        initial begin : invalid_LMEM_XBAR_MAX_FANOUT
            $error("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", `LMEM_XBAR_MAX_FANOUT);
        end
    end
`endif

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_per_bank_req_data_soa
        assign {
            per_bank_req_rw[i],
            per_bank_req_addr[i],
            per_bank_req_data[i],
            per_bank_req_byteen[i],
            per_bank_req_tag[i]
        } = per_bank_req_data_aos[i];
    end

    // banks access

    wire [NUM_BANKS-1:0]                per_bank_rsp_valid;
    wire [NUM_BANKS-1:0][WORD_WIDTH-1:0] per_bank_rsp_data;
    wire [NUM_BANKS-1:0][REQ_SEL_WIDTH-1:0] per_bank_rsp_idx;
    wire [NUM_BANKS-1:0][TAG_WIDTH-1:0] per_bank_rsp_tag;
    wire [NUM_BANKS-1:0]                per_bank_rsp_ready;

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_data_store
        wire bank_rsp_valid, bank_rsp_ready;

        VX_sp_ram #(
            .DATAW    (WORD_WIDTH),
            .SIZE     (WORDS_PER_BANK),
            .WRENW    (WORD_SIZE),
            .OUT_REG  (1),
            .USE_URAM (1),
            .RDW_MODE ("R")
        ) lmem_store (
            .clk   (clk),
            .reset (reset),
            .read  (per_bank_req_valid[i] && per_bank_req_ready[i] && ~per_bank_req_rw[i]),
            .write (per_bank_req_valid[i] && per_bank_req_ready[i] && per_bank_req_rw[i]),
            .wren  (per_bank_req_byteen[i]),
            .addr  (per_bank_req_addr[i]),
            .wdata (per_bank_req_data[i]),
            .rdata (per_bank_rsp_data[i])
        );

        // read-during-write hazard detection
        reg [BANK_ADDR_WIDTH-1:0] last_wr_addr;
        reg last_wr_valid;
        always @(posedge clk) begin
            if (reset) begin
                last_wr_valid <= 0;
            end else begin
                last_wr_valid <= per_bank_req_valid[i] && per_bank_req_ready[i] && per_bank_req_rw[i];
            end
            last_wr_addr <= per_bank_req_addr[i];
        end
        wire is_rdw_hazard = last_wr_valid && ~per_bank_req_rw[i] && (per_bank_req_addr[i] == last_wr_addr);

        // drop write response
        assign bank_rsp_valid = per_bank_req_valid[i] && ~per_bank_req_rw[i] && ~is_rdw_hazard;
        assign per_bank_req_ready[i] = (bank_rsp_ready || per_bank_req_rw[i]) && ~is_rdw_hazard;

        // register BRAM output
        VX_pipe_buffer #(
            .DATAW (REQ_SEL_WIDTH + TAG_WIDTH)
        ) bram_buf (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (bank_rsp_valid),
            .ready_in  (bank_rsp_ready),
            .data_in   ({per_bank_req_idx[i], per_bank_req_tag[i]}),
            .data_out  ({per_bank_rsp_idx[i], per_bank_rsp_tag[i]}),
            .valid_out (per_bank_rsp_valid[i]),
            .ready_out (per_bank_rsp_ready[i])
        );
    end

    // bank responses gather

    wire [NUM_BANKS-1:0][RSP_DATAW-1:0] per_bank_rsp_data_aos;

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_per_bank_rsp_data_aos
        assign per_bank_rsp_data_aos[i] = {per_bank_rsp_data[i], per_bank_rsp_tag[i]};
    end

    wire [NUM_REQS-1:0]                 rsp_valid_out;
    wire [NUM_REQS-1:0][RSP_DATAW-1:0]  rsp_data_out;
    wire [NUM_REQS-1:0]                 rsp_ready_out;

`ifdef LMEM_RSP_OMEGA_ENABLE
    VX_stream_omega #(
        .NUM_INPUTS    (NUM_BANKS),
        .NUM_OUTPUTS   (NUM_REQS),
        .RADIX         (2),
        .DATAW         (RSP_DATAW),
        .PERF_CTR_BITS (PERF_CTR_BITS),
        .ARBITER       ("P"), // this priority arbiter has negligeable impact om performance
        .OUT_BUF       (OUT_BUF)
    ) rsp_xbar (
        .clk       (clk),
        .reset     (reset),
        `UNUSED_PIN (collisions),
        .sel_in    (per_bank_rsp_idx),
        .valid_in  (per_bank_rsp_valid),
        .data_in   (per_bank_rsp_data_aos),
        .ready_in  (per_bank_rsp_ready),
        .valid_out (rsp_valid_out),
        .data_out  (rsp_data_out),
        .ready_out (rsp_ready_out),
        `UNUSED_PIN (sel_out)
    );
`else
    if (LMEM_XBAR_FANOUT_VALID) begin : g_rsp_hier_valid
        VX_stream_xbar #(
            .NUM_INPUTS    (NUM_BANKS),
            .NUM_OUTPUTS   (NUM_REQS),
            .DATAW         (RSP_DATAW),
            .PERF_CTR_BITS (PERF_CTR_BITS),
            .ARBITER       ("P"), // this priority arbiter has negligeable impact om performance
            .OUT_BUF       (OUT_BUF),
            .MAX_FANOUT    (`LMEM_XBAR_MAX_FANOUT)
        ) rsp_xbar (
            .clk       (clk),
            .reset     (reset),
            `UNUSED_PIN (collisions),
            .sel_in    (per_bank_rsp_idx),
            .valid_in  (per_bank_rsp_valid),
            .data_in   (per_bank_rsp_data_aos),
            .ready_in  (per_bank_rsp_ready),
            .valid_out (rsp_valid_out),
            .data_out  (rsp_data_out),
            .ready_out (rsp_ready_out),
            `UNUSED_PIN (sel_out)
        );
    end else begin : g_rsp_hier_invalid
        assign rsp_valid_out      = '0;
        assign rsp_data_out       = '0;
        assign per_bank_rsp_ready = '0;
        `UNUSED_VAR (per_bank_rsp_valid)
        `UNUSED_VAR (per_bank_rsp_idx)
        `UNUSED_VAR (per_bank_rsp_data_aos)
        initial begin : invalid_LMEM_XBAR_MAX_FANOUT
            $error("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", `LMEM_XBAR_MAX_FANOUT);
        end
    end
`endif

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_mem_bus_if
        assign mem_bus_if[i].rsp_valid = rsp_valid_out[i];
        assign mem_bus_if[i].rsp_data  = rsp_data_out[i];
        assign rsp_ready_out[i] = mem_bus_if[i].rsp_ready;
    end

`ifdef PERF_ENABLE
    // per cycle: reads, writes
    wire [`CLOG2(NUM_REQS+1)-1:0] perf_reads_per_cycle;
    wire [`CLOG2(NUM_REQS+1)-1:0] perf_writes_per_cycle;
    wire [`CLOG2(NUM_REQS+1)-1:0] perf_crsp_stall_per_cycle;

    // Preserve the legacy final-bank collision definition independently of
    // the selected request fabric. Count each duplicate requester once when
    // at least one request in the colliding pair can make forward progress.
    reg [NUM_REQS-1:0] perf_bank_collision_per_req;
    reg [NUM_REQS-1:0] perf_bank_collision_per_req_r;
    wire [`CLOG2(NUM_REQS+1)-1:0] perf_bank_collisions_per_cycle;
    reg [PERF_CTR_BITS-1:0] perf_bank_stalls;

    always @(*) begin
        perf_bank_collision_per_req = '0;
        for (integer i = 0; i < NUM_REQS; ++i) begin
            for (integer j = i + 1; j < NUM_REQS; ++j) begin
                perf_bank_collision_per_req[i] |= req_valid_in[i]
                                                && req_valid_in[j]
                                                && (req_bank_idx[i] == req_bank_idx[j])
                                                && (req_ready_in[i] | req_ready_in[j]);
            end
        end
    end

    `BUFFER(perf_bank_collision_per_req_r, perf_bank_collision_per_req);
    `POP_COUNT(perf_bank_collisions_per_cycle, perf_bank_collision_per_req_r);

    wire [NUM_REQS-1:0] req_rw;
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_rw
        assign req_rw[i] = mem_bus_if[i].req_data.rw;
    end

    wire [NUM_REQS-1:0] perf_reads_per_req, perf_writes_per_req;
    wire [NUM_REQS-1:0] perf_crsp_stall_per_req = rsp_valid_out & ~rsp_ready_out;

    `BUFFER(perf_reads_per_req, req_valid_in & req_ready_in & ~req_rw);
    `BUFFER(perf_writes_per_req, req_valid_in & req_ready_in & req_rw);

    `POP_COUNT(perf_reads_per_cycle, perf_reads_per_req);
    `POP_COUNT(perf_writes_per_cycle, perf_writes_per_req);
    `POP_COUNT(perf_crsp_stall_per_cycle, perf_crsp_stall_per_req);

    reg [PERF_CTR_BITS-1:0] perf_reads;
    reg [PERF_CTR_BITS-1:0] perf_writes;
    reg [PERF_CTR_BITS-1:0] perf_crsp_stalls;

    always @(posedge clk) begin
        if (reset) begin
            perf_reads       <= '0;
            perf_writes      <= '0;
            perf_crsp_stalls <= '0;
            perf_bank_stalls <= '0;
        end else begin
            perf_reads       <= perf_reads  + PERF_CTR_BITS'(perf_reads_per_cycle);
            perf_writes      <= perf_writes + PERF_CTR_BITS'(perf_writes_per_cycle);
            perf_crsp_stalls <= perf_crsp_stalls + PERF_CTR_BITS'(perf_crsp_stall_per_cycle);
            perf_bank_stalls <= perf_bank_stalls + PERF_CTR_BITS'(perf_bank_collisions_per_cycle);
        end
    end

    assign lmem_perf.reads       = perf_reads;
    assign lmem_perf.writes      = perf_writes;
    assign lmem_perf.bank_stalls = perf_bank_stalls;
    assign lmem_perf.crsp_stalls = perf_crsp_stalls;

`endif

`ifdef DBG_TRACE_MEM

    wire [NUM_BANKS-1:0][TAG_WIDTH-UUID_WIDTH-1:0] per_bank_req_tag_value;
    wire [NUM_BANKS-1:0][`UP(UUID_WIDTH)-1:0] per_bank_req_uuid;

    wire [NUM_BANKS-1:0][TAG_WIDTH-UUID_WIDTH-1:0] per_bank_rsp_tag_value;
    wire [NUM_BANKS-1:0][`UP(UUID_WIDTH)-1:0] per_bank_rsp_uuid;

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_per_bank_req_uuid
        assign per_bank_req_tag_value[i] = per_bank_req_tag[i][TAG_WIDTH-UUID_WIDTH-1:0];
        assign per_bank_rsp_tag_value[i] = per_bank_rsp_tag[i][TAG_WIDTH-UUID_WIDTH-1:0];
        if (UUID_WIDTH != 0) begin : g_uuid
            assign per_bank_req_uuid[i] = per_bank_req_tag[i][TAG_WIDTH-1 -: UUID_WIDTH];
            assign per_bank_rsp_uuid[i] = per_bank_rsp_tag[i][TAG_WIDTH-1 -: UUID_WIDTH];
        end else begin : g_no_uuid
            assign per_bank_req_uuid[i] = 0;
            assign per_bank_rsp_uuid[i] = 0;
        end
    end

    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_trace
        always @(posedge clk) begin
            if (mem_bus_if[i].req_valid && mem_bus_if[i].req_ready) begin
                if (mem_bus_if[i].req_data.rw) begin
                    `TRACE(2, ("%t: %s core-wr-req[%0d]: addr=0x%0h, byteen=0x%h, data=0x%h, tag=0x%0h (#%0d)\n",
                        $time, INSTANCE_ID, i, mem_bus_if[i].req_data.addr, mem_bus_if[i].req_data.byteen, mem_bus_if[i].req_data.data, mem_bus_if[i].req_data.tag.value, mem_bus_if[i].req_data.tag.uuid))
                end else begin
                    `TRACE(2, ("%t: %s core-rd-req[%0d]: addr=0x%0h, tag=0x%0h (#%0d)\n",
                        $time, INSTANCE_ID, i, mem_bus_if[i].req_data.addr, mem_bus_if[i].req_data.tag.value, mem_bus_if[i].req_data.tag.uuid))
                end
            end
            if (mem_bus_if[i].rsp_valid && mem_bus_if[i].rsp_ready) begin
                `TRACE(2, ("%t: %s core-rd-rsp[%0d]: data=0x%h, tag=0x%0h (#%0d)\n",
                    $time, INSTANCE_ID, i, mem_bus_if[i].rsp_data.data, mem_bus_if[i].rsp_data.tag.value, mem_bus_if[i].rsp_data.tag.uuid))
            end
        end
    end

    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_bank_trace
        always @(posedge clk) begin
            if (per_bank_req_valid[i] && per_bank_req_ready[i]) begin
                if (per_bank_req_rw[i]) begin
                    `TRACE(2, ("%t: %s bank-wr-req[%0d]: addr=0x%0h, byteen=0x%h, data=0x%h, tag=0x%0h (#%0d)\n",
                        $time, INSTANCE_ID, i, per_bank_req_addr[i], per_bank_req_byteen[i], per_bank_req_data[i], per_bank_req_tag_value[i], per_bank_req_uuid[i]))
                end else begin
                    `TRACE(2, ("%t: %s bank-rd-req[%0d]: addr=0x%0h, tag=0x%0h (#%0d)\n",
                        $time, INSTANCE_ID, i, per_bank_req_addr[i], per_bank_req_tag_value[i], per_bank_req_uuid[i]))
                end
            end
            if (per_bank_rsp_valid[i] && per_bank_rsp_ready[i]) begin
                `TRACE(2, ("%t: %s bank-rd-rsp[%0d]: data=0x%h, tag=0x%0h (#%0d)\n",
                    $time, INSTANCE_ID, i, per_bank_rsp_data[i], per_bank_rsp_tag_value[i], per_bank_rsp_uuid[i]))
            end
        end
    end

`endif

endmodule

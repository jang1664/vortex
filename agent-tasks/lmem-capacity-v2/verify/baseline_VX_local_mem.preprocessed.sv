module VX_local_mem import VX_gpu_pkg::*; #(
    parameter   INSTANCE_ID = "",
    parameter SIZE              = (1024*16*8),
    parameter NUM_REQS          = 4,
    parameter NUM_BANKS         = 4,
    parameter ADDR_WIDTH        = $clog2(SIZE),
    parameter WORD_SIZE         = 64/8,
    parameter TAG_WIDTH         = 16,
    parameter OMEGA_STORE_CAM_SIZE = 64,
    parameter OMEGA_RSP_QUEUE_SIZE = 16,
    parameter OUT_BUF           = 0
 ) (
    input wire clk,
    input wire reset,
    VX_mem_bus_if.slave mem_bus_if [NUM_REQS]
);
    localparam REQ_SEL_BITS    = $clog2(NUM_REQS);
    localparam REQ_SEL_WIDTH   = (((REQ_SEL_BITS) > 0) ? (REQ_SEL_BITS) : 1);
    localparam WORD_WIDTH      = WORD_SIZE * 8;
    localparam NUM_WORDS       = SIZE / WORD_SIZE;
    localparam WORDS_PER_BANK  = NUM_WORDS / NUM_BANKS;
    localparam BANK_ADDR_WIDTH = $clog2(WORDS_PER_BANK);
    localparam BANK_SEL_BITS   = $clog2(NUM_BANKS);
    localparam BANK_SEL_WIDTH  = (((BANK_SEL_BITS) > 0) ? (BANK_SEL_BITS) : 1);
    localparam REQ_DATAW       = 1 + BANK_ADDR_WIDTH + WORD_SIZE + WORD_WIDTH + TAG_WIDTH;
    localparam RSP_DATAW       = WORD_WIDTH + TAG_WIDTH;
    localparam LMEM_XBAR_FANOUT_VALID = (8 == 0)
                                     || ((8 >= 2)
                                      && (((8) != 0) && (0 == ((8) & ((8) - 1)))));
    wire [NUM_REQS-1:0][BANK_SEL_WIDTH-1:0] req_bank_idx;
    if (NUM_BANKS > 1) begin : g_req_bank_idx
        for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_bank_idxs
            assign req_bank_idx[i] = mem_bus_if[i].req_data.addr[0 +: BANK_SEL_BITS];
        end
    end else begin : g_req_bank_idx_0
        assign req_bank_idx = 0;
    end
    wire [NUM_REQS-1:0][BANK_ADDR_WIDTH-1:0] req_bank_addr;
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_req_bank_addr
        assign req_bank_addr[i] = mem_bus_if[i].req_data.addr[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
    end
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
    if (LMEM_XBAR_FANOUT_VALID) begin : g_req_hier_valid
        VX_stream_xbar #(
            .NUM_INPUTS    (NUM_REQS),
            .NUM_OUTPUTS   (NUM_BANKS),
            .DATAW         (REQ_DATAW),
            .PERF_CTR_BITS (PERF_CTR_BITS),
            .ARBITER       ("P"),
            .OUT_BUF       (3),  
            .MAX_FANOUT    (8)
        ) req_xbar (
            .clk       (clk),
            .reset     (reset),
            . collisions (),
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
        initial begin : invalid_LMEM_XBAR_MAX_FANOUT
            $error("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", 8);
        end
    end
    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_per_bank_req_data_soa
        assign {
            per_bank_req_rw[i],
            per_bank_req_addr[i],
            per_bank_req_data[i],
            per_bank_req_byteen[i],
            per_bank_req_tag[i]
        } = per_bank_req_data_aos[i];
    end
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
            .USE_URAM (0),
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
        assign bank_rsp_valid = per_bank_req_valid[i] && ~per_bank_req_rw[i] && ~is_rdw_hazard;
        assign per_bank_req_ready[i] = (bank_rsp_ready || per_bank_req_rw[i]) && ~is_rdw_hazard;
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
    wire [NUM_BANKS-1:0][RSP_DATAW-1:0] per_bank_rsp_data_aos;
    for (genvar i = 0; i < NUM_BANKS; ++i) begin : g_per_bank_rsp_data_aos
        assign per_bank_rsp_data_aos[i] = {per_bank_rsp_data[i], per_bank_rsp_tag[i]};
    end
    wire [NUM_REQS-1:0]                 rsp_valid_out;
    wire [NUM_REQS-1:0][RSP_DATAW-1:0]  rsp_data_out;
    wire [NUM_REQS-1:0]                 rsp_ready_out;
    if (LMEM_XBAR_FANOUT_VALID) begin : g_rsp_hier_valid
        VX_stream_xbar #(
            .NUM_INPUTS    (NUM_BANKS),
            .NUM_OUTPUTS   (NUM_REQS),
            .DATAW         (RSP_DATAW),
            .PERF_CTR_BITS (PERF_CTR_BITS),
            .ARBITER       ("P"),  
            .OUT_BUF       (OUT_BUF),
            .MAX_FANOUT    (8)
        ) rsp_xbar (
            .clk       (clk),
            .reset     (reset),
            . collisions (),
            .sel_in    (per_bank_rsp_idx),
            .valid_in  (per_bank_rsp_valid),
            .data_in   (per_bank_rsp_data_aos),
            .ready_in  (per_bank_rsp_ready),
            .valid_out (rsp_valid_out),
            .data_out  (rsp_data_out),
            .ready_out (rsp_ready_out),
            . sel_out ()
        );
    end else begin : g_rsp_hier_invalid
        assign rsp_valid_out      = '0;
        assign rsp_data_out       = '0;
        assign per_bank_rsp_ready = '0;
        initial begin : invalid_LMEM_XBAR_MAX_FANOUT
            $error("invalid LMEM_XBAR_MAX_FANOUT=%0d: expected 0 or a power of two >= 2", 8);
        end
    end
    for (genvar i = 0; i < NUM_REQS; ++i) begin : g_mem_bus_if
        assign mem_bus_if[i].rsp_valid = rsp_valid_out[i];
        assign mem_bus_if[i].rsp_data  = rsp_data_out[i];
        assign rsp_ready_out[i] = mem_bus_if[i].rsp_ready;
    end
endmodule

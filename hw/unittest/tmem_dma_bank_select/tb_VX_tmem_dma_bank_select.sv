`timescale 1ns/1ps
`include "VX_define.vh"

// The real subsystem, 64-KiB physical banks, and DMA response mux are used.
// Only the idle DMA engine output is replaced by transaction-level stimulus.
module tb_VX_tmem_dma_bank_select import VX_gpu_pkg::*; ();
    localparam int CHANNELS = 4;
    localparam int BANKS = 8;
    localparam int TAG_WIDTH = `UP(UUID_WIDTH) + 7;
    localparam int ADDR_WIDTH = `MEM_ADDR_WIDTH - 6;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    VX_config_reg_if #(.NUM(`DMA_CFG_REG_NUM), .DW(32)) cfg [CHANNELS] ();
    VX_dma_lookahead_if lookahead [CHANNELS] ();
    VX_node_done_if done_if [CHANNELS] ();
    VX_lmem_dma_ctrl_if local_ctrl [5] ();
    AXI_BUS #(.AXI_ADDR_WIDTH(`PLATFORM_MEMORY_ADDR_WIDTH),
              .AXI_DATA_WIDTH(512), .AXI_ID_WIDTH(8), .AXI_USER_WIDTH(1)) axi [CHANNELS] ();
    VX_mem_bus_if #(.DATA_SIZE(64), .TAG_WIDTH(TAG_WIDTH)) gemm [5] ();
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] priorities [4] = '{default:'0};
    VX_tmem_subsystem #(
        .INSTANCE_ID("bank_select_tb"), .NUM_BANKS(BANKS),
        .NUM_DMA_CHANNELS(CHANNELS), .BANK_SIZE(65536),
        .DATA_SIZE(64), .WEIGHT_DATA_SIZE(64), .TAG_WIDTH(TAG_WIDTH),
        .AXI_DATA_WIDTH(512)
    ) dut (
        .clk(clk), .reset(reset), .dma_cfg_if(cfg),
        .dma_lookahead_if(lookahead), .dma_done_if(done_if),
        .ldma_ctrl_if(local_ctrl), .weight_writer_wait_i('0),
        .weight_consume_value0_i('0), .weight_consume_value1_i('0),
        .scale_writer_wait_i('0), .scale_consume_value0_i('0),
        .scale_consume_value1_i('0), .zero_point_writer_wait_i('0),
        .zero_point_consume_value0_i('0), .zero_point_consume_value1_i('0),
        .sched_source_priority_i(priorities), .sched_input_source_enable_i(1'b1),
        .sched_source_valid_o(), .sched_source_work_seq_o(),
        .sched_source_total_beats_o(), .sched_source_request_beats_o(),
        .sched_source_response_beats_o(), .sched_source_writer_beats_o(),
        .sched_input_slot_occupancy_o(), .sched_fetch_complete_o(),
        .sched_fetch_complete_work_seq_o(), .axi_m(axi),
        .gemm_input_if(gemm[0]), .gemm_weight_if(gemm[1]),
        .gemm_scale_if(gemm[2]), .gemm_zp_if(gemm[3]), .gemm_output_if(gemm[4])
    );

    logic [CHANNELS-1:0] drive_valid = '0, drive_rw = '0, drive_rsp_ready = '1;
    logic [CHANNELS-1:0][ADDR_WIDTH-1:0] drive_addr = '0;
    logic [CHANNELS-1:0][511:0] drive_data = '0;
    logic [CHANNELS-1:0][TAG_WIDTH-1:0] drive_tag = '0;
    wire [CHANNELS-1:0] req_ready, rsp_valid;
    wire [CHANNELS-1:0][TAG_WIDTH-1:0] rsp_tag;
    logic [BANKS-1:0] hold_req = '0, hold_rsp = '0;
    logic pending [CHANNELS][256];
    logic [TAG_WIDTH-1:0] expected_tag [CHANNELS][256];
    logic [511:0] expected_data [CHANNELS][256];
    int received [CHANNELS][256];
    int bank_writes [BANKS], bank_reads [BANKS], bank_responses [BANKS];
    logic [CHANNELS-1:0] was_stalled = '0;
    logic [CHANNELS-1:0][511:0] stalled_data;
    logic [CHANNELS-1:0][TAG_WIDTH-1:0] stalled_tag;

    function automatic logic [511:0] payload(input int c, input int addr, input int epoch = 0);
        for (int i = 0; i < 64; ++i)
            payload[8*i +: 8] = 8'(c * 37 + addr * 3 + (addr >> 8) * 19 + epoch * 71 + i * 5);
    endfunction

    for (genvar c = 0; c < CHANNELS; ++c) begin : g_channel
        assign req_ready[c] = dut.dma_to_tmem[c].req_ready;
        assign rsp_valid[c] = dut.dma_to_tmem[c].rsp_valid;
        assign rsp_tag[c] = dut.dma_to_tmem[c].rsp_data.tag;
        initial begin
            cfg[c].valid = 0; cfg[c].regs = '0; cfg[c].entry_id = 0;
            lookahead[c].prepare_valid = 0; lookahead[c].prepare_id = 0;
            lookahead[c].src_stride = '0; lookahead[c].dst_stride = '0;
            lookahead[c].bound = '0; lookahead[c].activate = 0;
            lookahead[c].activate_id = 0; lookahead[c].data_release = 1;
            lookahead[c].data_max_beats = '1;
            axi[c].aw_ready = 0; axi[c].w_ready = 0; axi[c].ar_ready = 0;
            axi[c].b_valid = 0; axi[c].b_id = 0; axi[c].b_resp = 0; axi[c].b_user = 0;
            axi[c].r_valid = 0; axi[c].r_id = 0; axi[c].r_data = 0;
            axi[c].r_resp = 0; axi[c].r_last = 0; axi[c].r_user = 0;
            force dut.dma_to_tmem[c].req_valid = drive_valid[c];
            force dut.dma_to_tmem[c].req_data.rw = drive_rw[c];
            force dut.dma_to_tmem[c].req_data.addr = drive_addr[c];
            force dut.dma_to_tmem[c].req_data.data = drive_data[c];
            force dut.dma_to_tmem[c].req_data.byteen = '1;
            force dut.dma_to_tmem[c].req_data.flags = 0;
            force dut.dma_to_tmem[c].req_data.tag = drive_tag[c];
            force dut.dma_to_tmem[c].rsp_ready = drive_rsp_ready[c];
        end
        always @(posedge clk) begin : check_response
            int slot;
            if (!reset) begin
                if (was_stalled[c] && (!rsp_valid[c]
                    || dut.dma_to_tmem[c].rsp_data.tag !== stalled_tag[c]
                    || dut.dma_to_tmem[c].rsp_data.data !== stalled_data[c]))
                    $fatal(1, "channel%0d response changed while stalled", c);
                was_stalled[c] = rsp_valid[c] && !drive_rsp_ready[c];
                stalled_tag[c] = dut.dma_to_tmem[c].rsp_data.tag;
                stalled_data[c] = dut.dma_to_tmem[c].rsp_data.data;
                if (rsp_valid[c]) begin
                    slot = int'(dut.dma_to_tmem[c].rsp_data.tag[7:0]);
                    if (!pending[c][slot])
                        $fatal(1, "channel%0d unexpected response/write ACK tag=%h", c, rsp_tag[c]);
                    if (rsp_tag[c] !== expected_tag[c][slot]
                        || dut.dma_to_tmem[c].rsp_data.data !== expected_data[c][slot])
                        $fatal(1, "channel%0d read tag/data mismatch slot=%0d", c, slot);
                    if (drive_rsp_ready[c]) begin
                        pending[c][slot] = 0;
                        received[c][slot]++;
                    end
                end
            end
        end
    end
    for (genvar p = 0; p < 5; ++p) begin : g_local
        initial begin
            local_ctrl[p].start = 0; local_ctrl[p].prepare = 0;
            local_ctrl[p].prepare_max_beats = 0;
            local_ctrl[p].src_base_addr = 0; local_ctrl[p].dst_base_addr = 0;
            local_ctrl[p].src_strides = '{default:0}; local_ctrl[p].dst_strides = '{default:0};
            local_ctrl[p].bounds = '{default:0}; local_ctrl[p].seg_size = 0;
            local_ctrl[p].reg_idx = 0; local_ctrl[p].reg_value = 0;
            local_ctrl[p].scheduler_work_seq = 0;
            gemm[p].req_ready = 1; gemm[p].rsp_valid = 0; gemm[p].rsp_data = '0;
        end
    end
    for (genvar b = 0; b < BANKS; ++b) begin : g_bank
        localparam int C = b % CHANNELS;
        // Block both sides of each boundary: never fabricate an accepted
        // transaction on one side while the other side sees no handshake.
        always @(hold_req[b]) begin
            if (hold_req[b]) begin
                force dut.g_bank[b].bank_port_if[0].req_valid = 0;
                force dut.g_bank[b].bank_port_if[0].req_ready = 0;
            end else begin
                release dut.g_bank[b].bank_port_if[0].req_valid;
                release dut.g_bank[b].bank_port_if[0].req_ready;
            end
        end
        always @(hold_rsp[b]) begin
            if (hold_rsp[b]) begin
                force dut.g_bank[b].bank_port_if[0].rsp_valid = 0;
                force dut.g_bank[b].bank_port_if[0].rsp_ready = 0;
            end else begin
                release dut.g_bank[b].bank_port_if[0].rsp_valid;
                release dut.g_bank[b].bank_port_if[0].rsp_ready;
            end
        end
        always @(posedge clk) begin
            if (reset) begin
                bank_writes[b] = 0; bank_reads[b] = 0; bank_responses[b] = 0;
            end else begin
                if (dut.g_bank[b].bank_port_if[0].req_valid && dut.g_bank[b].bank_port_if[0].req_ready) begin
                    if (!drive_valid[C] || b != C + CHANNELS * int'(drive_addr[C][0])
                        || dut.g_bank[b].bank_port_if[0].req_data.addr !== (drive_addr[C] >> 1))
                        $fatal(1, "physical bank/row mapping mismatch bank=%0d channel_addr=%0h row=%0h",
                               b, drive_addr[C], dut.g_bank[b].bank_port_if[0].req_data.addr);
                    if (dut.g_bank[b].bank_port_if[0].req_data.rw) bank_writes[b]++;
                    else bank_reads[b]++;
                end
                if (dut.g_bank[b].bank_port_if[0].rsp_valid && dut.g_bank[b].bank_port_if[0].rsp_ready)
                    bank_responses[b]++;
            end
        end
    end

    task automatic request(input int c, input bit rw, input int addr,
                           input logic [TAG_WIDTH-1:0] tag, input int epoch = 0);
        int slot;
        @(negedge clk);
        slot = int'(tag[7:0]);
        if (!rw) begin
            if (pending[c][slot]) $fatal(1, "test reused pending tag");
            pending[c][slot] = 1;
            expected_tag[c][slot] = tag;
            expected_data[c][slot] = payload(c, addr, epoch);
        end
        drive_valid[c] = 1; drive_rw[c] = rw; drive_addr[c] = ADDR_WIDTH'(addr);
        drive_tag[c] = tag; drive_data[c] = payload(c, addr, epoch);
        do @(posedge clk); while (!req_ready[c]);
        @(negedge clk);
        drive_valid[c] = 0;
    endtask

    task automatic drain;
        bit outstanding;
        do begin
            @(negedge clk);
            outstanding = 0;
            for (int c = 0; c < CHANNELS; ++c)
                for (int s = 0; s < 256; ++s) outstanding |= pending[c][s];
            for (int b = 0; b < BANKS; ++b)
                outstanding |= (bank_responses[b] != bank_reads[b] + bank_writes[b]);
        end while (outstanding);
        repeat (4) @(negedge clk);
    endtask

    initial begin : stimulus
        int addresses [8] = '{0, 1, 2, 3, 1022, 1023, 2046, 2047};
        bit other_finished;
        $assertoff(0, dut.u_dma_engine);
        for (int c = 0; c < CHANNELS; ++c)
            for (int s = 0; s < 256; ++s) begin pending[c][s] = 0; received[c][s] = 0; end
        repeat (8) @(negedge clk);
        reset = 0;
        repeat (3) @(negedge clk);
        // Both owned banks on every channel, including the last physical row.
        for (int c = 0; c < CHANNELS; ++c)
            foreach (addresses[a]) request(c, 1, addresses[a], '0);
        drain();
        for (int c = 0; c < CHANNELS; ++c)
            foreach (addresses[a]) request(c, 0, addresses[a], TAG_WIDTH'(a));
        drain();
        $display("COVERAGE: all channels, both bank choices, rows 0/1/511/1023");

        // A blocked bank cannot block its paired bank or another DMA channel.
        hold_req[0] = 1;
        request(0, 0, 1, TAG_WIDTH'(8));
        other_finished = 0;
        fork
            request(0, 0, 0, TAG_WIDTH'(9));
            begin request(1, 0, 0, TAG_WIDTH'(9)); other_finished = 1; end
            begin
                repeat (12) @(negedge clk);
                if (!other_finished || received[0][8] != 1)
                    $fatal(1, "unrelated bank/channel blocked by bank0 request stall");
                hold_req[0] = 0;
            end
        join
        drain();

        // Bank4 returns before bank0; tags must retain association, no reorder.
        hold_rsp[0] = 1;
        request(0, 0, 0, TAG_WIDTH'(10));
        request(0, 0, 1, TAG_WIDTH'(11));
        wait (received[0][11] == 1);
        if (!pending[0][10]) $fatal(1, "delayed bank0 read unexpectedly completed");
        // A stalled bank4 response must remain stable when bank0 becomes valid.
        @(negedge clk); drive_rsp_ready[0] = 0;
        request(0, 0, 3, TAG_WIDTH'(12));
        wait (rsp_valid[0] && rsp_tag[0] == TAG_WIDTH'(12));
        repeat (2) @(negedge clk);
        hold_rsp[0] = 0;
        repeat (8) @(negedge clk);
        drive_rsp_ready[0] = 1;
        drain();
        $display("COVERAGE: independent stalls, out-of-order reads, stable stalled response on competing arrival");

        // Late write ACKs precede reads on all eight banks, while DMA refuses
        // read responses. ACKs must drain locally and never alias read tag zero.
        hold_rsp = '1;
        drive_rsp_ready = '0;
        for (int c = 0; c < CHANNELS; ++c) begin
            request(c, 1, 0, '0, 1);
            request(c, 1, 1, '0, 1);
        end
        fork
            begin
                for (int c = 0; c < CHANNELS; ++c) begin
                    request(c, 0, 0, '0, 1);
                    request(c, 0, 1, '1, 1);
                end
            end
            begin
                repeat (8) @(negedge clk);
                for (int b = BANKS-1; b >= 0; --b) begin
                    hold_rsp[b] = 0;
                    repeat (3) @(negedge clk);
                end
                repeat (20) @(negedge clk);
                for (int b = 0; b < BANKS; ++b)
                    if (bank_responses[b] < bank_writes[b]) $fatal(1, "write ACK did not drain bank%0d", b);
                drive_rsp_ready = '1;
            end
        join
        drain();
        for (int b = 0; b < BANKS; ++b) begin
            if (bank_writes[b] < 5 || bank_reads[b] < 5)
                $fatal(1, "missing bank coverage bank%0d", b);
            $display("BANK%0d writes=%0d reads=%0d responses=%0d", b, bank_writes[b], bank_reads[b], bank_responses[b]);
        end
        $display("TEST PASSED: DMA4/TMEM8 selected-bank transport, 512KiB, UUID=%0d", UUID_WIDTH);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "bank-select transport timeout");
    end
endmodule

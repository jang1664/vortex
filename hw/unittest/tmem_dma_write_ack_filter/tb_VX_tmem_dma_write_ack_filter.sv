`timescale 1ns/1ps
`include "VX_define.vh"

// Transport-focused integration test: real subsystem, pair adapter, switch,
// and physical banks. The unconfigured DMA engine's outgoing bus is replaced
// by a directed driver; full descriptor lifecycle is covered by blackbox tests.
module tb_VX_tmem_dma_write_ack_filter import VX_gpu_pkg::*; #(
    parameter int DATA_SIZE = 32,
    parameter int NUM_BANKS = 2,
    parameter int BANK_SIZE = 4096
) ();
    localparam int CHANNELS = NUM_BANKS / (64 / DATA_SIZE);
    localparam int RATIO = 64 / DATA_SIZE;
    localparam int TAG_WIDTH = `UP(UUID_WIDTH) + 7;
    localparam int ADDR_WIDTH = `MEM_ADDR_WIDTH - 6;
    logic clk = 0;
    logic reset = 1;
    always #5 clk = ~clk;
    VX_config_reg_if #(.NUM(`DMA_CFG_REG_NUM), .DW(32)) cfg [CHANNELS] ();
    VX_dma_lookahead_if lookahead [CHANNELS] ();
    VX_node_done_if done_if [CHANNELS] ();
    VX_lmem_dma_ctrl_if local_ctrl [5] ();
    AXI_BUS #(.AXI_ADDR_WIDTH(`PLATFORM_MEMORY_ADDR_WIDTH),
              .AXI_DATA_WIDTH(512), .AXI_ID_WIDTH(8), .AXI_USER_WIDTH(1)) axi [CHANNELS] ();
    VX_mem_bus_if #(.DATA_SIZE(DATA_SIZE), .TAG_WIDTH(TAG_WIDTH)) gemm [5] ();
    wire [GEMM_SCHED_PRIORITY_WIDTH-1:0] priorities [4] = '{default:'0};

    VX_tmem_subsystem #(
        .INSTANCE_ID("ack_filter_tb"), .NUM_BANKS(NUM_BANKS),
        .NUM_DMA_CHANNELS(CHANNELS), .BANK_SIZE(BANK_SIZE),
        .DATA_SIZE(DATA_SIZE), .WEIGHT_DATA_SIZE(DATA_SIZE),
        .TAG_WIDTH(TAG_WIDTH), .AXI_DATA_WIDTH(512)
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
        .sched_fetch_complete_work_seq_o(),
        .axi_m(axi), .gemm_input_if(gemm[0]), .gemm_weight_if(gemm[1]),
        .gemm_scale_if(gemm[2]), .gemm_zp_if(gemm[3]), .gemm_output_if(gemm[4])
    );

    for (genvar c = 0; c < CHANNELS; ++c) begin : g_idle_channel
        initial begin
            cfg[c].valid = 0;
            cfg[c].regs = '0;
            cfg[c].entry_id = 0;
            lookahead[c].prepare_valid = 0;
            lookahead[c].prepare_id = 0;
            lookahead[c].src_stride = '0;
            lookahead[c].dst_stride = '0;
            lookahead[c].bound = '0;
            lookahead[c].activate = 0;
            lookahead[c].activate_id = 0;
            lookahead[c].data_release = 1;
            lookahead[c].data_max_beats = '1;
            axi[c].aw_ready = 0;
            axi[c].w_ready = 0;
            axi[c].ar_ready = 0;
            axi[c].b_valid = 0;
            axi[c].b_id = 0;
            axi[c].b_resp = 0;
            axi[c].b_user = 0;
            axi[c].r_valid = 0;
            axi[c].r_id = 0;
            axi[c].r_data = 0;
            axi[c].r_resp = 0;
            axi[c].r_last = 0;
            axi[c].r_user = 0;
        end
    end
    for (genvar p = 0; p < 5; ++p) begin : g_idle_local
        initial begin
            local_ctrl[p].start = 0;
            local_ctrl[p].prepare = 0;
            local_ctrl[p].prepare_max_beats = 0;
            local_ctrl[p].src_base_addr = 0;
            local_ctrl[p].dst_base_addr = 0;
            local_ctrl[p].src_strides = '{default:0};
            local_ctrl[p].dst_strides = '{default:0};
            local_ctrl[p].bounds = '{default:0};
            local_ctrl[p].seg_size = 0;
            local_ctrl[p].reg_idx = 0;
            local_ctrl[p].reg_value = 0;
            local_ctrl[p].scheduler_work_seq = 0;
            gemm[p].req_ready = 1;
            gemm[p].rsp_valid = 0;
            gemm[p].rsp_data = '0;
        end
    end

    logic drive_valid = 0;
    logic drive_rw = 0;
    logic [ADDR_WIDTH-1:0] drive_addr = 0;
    logic [511:0] drive_data = 0;
    logic [TAG_WIDTH-1:0] drive_tag = 0;
    logic drive_rsp_ready = 0;
    logic [RATIO-1:0] hold_ack = 0;
    integer bank_writes [RATIO];
    integer bank_reads [RATIO];
    integer bank_acks [RATIO];
    integer read_count = 0;
    logic [TAG_WIDTH-1:0] expected_tag = 0;
    logic [511:0] expected_data;
    logic read_expected = 0;
    logic local_write_valid = 0;
    integer local_write_acks = 0;

    initial begin
        // Engine request bookkeeping is intentionally bypassed by this bus
        // driver. Keep all assertions in the actual transport/banks enabled.
        $assertoff(0, dut.u_dma_engine);
        force dut.dma_to_tmem[0].req_valid = drive_valid;
        force dut.dma_to_tmem[0].req_data.rw = drive_rw;
        force dut.dma_to_tmem[0].req_data.addr = drive_addr;
        force dut.dma_to_tmem[0].req_data.data = drive_data;
        force dut.dma_to_tmem[0].req_data.byteen = 64'hffff_ffff_ffff_ffff;
        force dut.dma_to_tmem[0].req_data.flags = 0;
        force dut.dma_to_tmem[0].req_data.tag = drive_tag;
        force dut.dma_to_tmem[0].rsp_ready = drive_rsp_ready;
        // Direct port-5 stimulus checks that write-ACK filtering is restricted
        // to HBM DMA port 0 and does not alter the local output writer path.
        force dut.g_bank[0].bank_port_if[5].req_valid = local_write_valid;
        force dut.g_bank[0].bank_port_if[5].req_data.rw = 1;
        force dut.g_bank[0].bank_port_if[5].req_data.addr = 20;
        force dut.g_bank[0].bank_port_if[5].req_data.data = '1;
        force dut.g_bank[0].bank_port_if[5].req_data.byteen = '1;
        force dut.g_bank[0].bank_port_if[5].req_data.flags = 0;
        force dut.g_bank[0].bank_port_if[5].req_data.tag = 8'h55;
        force dut.g_bank[0].bank_port_if[5].rsp_ready = 1;
    end

    for (genvar b = 0; b < RATIO; ++b) begin : g_bank_check
        // Hold BOTH sides of the bank response boundary. No fabricated
        // handshake: the real bank cannot dequeue, and its client sees no
        // response while the test inserts this controlled transport delay.
        always @(hold_ack[b]) begin
            if (hold_ack[b]) begin
                force dut.g_bank[b].bank_port_if[0].rsp_ready = 0;
                force dut.g_bank[b].bank_port_if[0].rsp_valid = 0;
            end else begin
                release dut.g_bank[b].bank_port_if[0].rsp_ready;
                release dut.g_bank[b].bank_port_if[0].rsp_valid;
            end
        end
        always @(posedge clk) begin
            if (reset) begin
                bank_writes[b] = 0;
                bank_reads[b] = 0;
                bank_acks[b] = 0;
            end else begin
                if (dut.g_bank[b].bank_port_if[0].req_valid
                    && dut.g_bank[b].bank_port_if[0].req_ready) begin
                    if (dut.g_bank[b].bank_port_if[0].req_data.rw)
                        bank_writes[b]++;
                    else
                        bank_reads[b]++;
                end
                if (dut.g_bank[b].bank_port_if[0].rsp_valid
                    && dut.g_bank[b].bank_port_if[0].rsp_ready)
                    bank_acks[b]++;
            end
        end
    end
    always @(posedge clk) begin
        if (!reset && dut.g_bank[0].bank_port_if[5].rsp_valid) begin
            if (!dut.out_switch_to_tmem[0].rsp_valid
                || dut.out_switch_to_tmem[0].rsp_data.tag !== 8'h55)
                $fatal(1, "local output write ACK was filtered or its tag changed");
            local_write_acks++;
        end
        if (!reset && dut.dma_to_tmem[0].rsp_valid) begin
            if (!read_expected)
                $fatal(1, "write acknowledgement leaked into DMA response channel");
            if (dut.dma_to_tmem[0].rsp_data.tag !== TAG_WIDTH'(expected_tag))
                $fatal(1, "read tag mismatch: got=%h expected=%h",
                       dut.dma_to_tmem[0].rsp_data.tag, expected_tag);
            if (dut.dma_to_tmem[0].rsp_data.data !== expected_data)
                $fatal(1, "read payload mismatch (late write ACK consumed as read)");
            if (drive_rsp_ready) begin
                read_count++;
                read_expected = 0;
            end
        end
    end

    task automatic request(input bit rw, input int addr, input logic [TAG_WIDTH-1:0] tag,
                           input logic [511:0] data);
        @(negedge clk);
        drive_valid = 1;
        drive_rw = rw;
        drive_addr = ADDR_WIDTH'(addr);
        drive_tag = TAG_WIDTH'(tag);
        drive_data = data;
        do @(posedge clk); while (!dut.dma_to_tmem[0].req_ready);
        @(negedge clk);
        drive_valid = 0;
    endtask

    task automatic reset_design;
        @(negedge clk);
        reset = 1;
        drive_valid = 0;
        read_expected = 0;
        repeat (5) @(negedge clk);
        hold_ack = 0;
        reset = 0;
        repeat (3) @(negedge clk);
    endtask

    task automatic transition_test(input logic [TAG_WIDTH-1:0] tag, input int seed,
                                   input int address = -1);
        logic [511:0] payload;
        int old_reads;
        int old_acks;
        for (int byte_idx = 0; byte_idx < 64; ++byte_idx)
            payload[byte_idx*8 +: 8] = 8'(seed + byte_idx * 3);
        old_reads = read_count;
        old_acks = bank_acks[0];
        @(negedge clk);
        drive_rsp_ready = 0;
        hold_ack = '1;
        request(1, address < 0 ? seed % 8 : address, 0, payload);
        // Physical write is complete; start the next read before releasing
        // the old write ACK. Tag zero deliberately aliases old store tags.
        expected_data = payload;
        expected_tag = tag;
        read_expected = 1;
        fork
            request(0, address < 0 ? seed % 8 : address, tag, '0);
            begin
                repeat (5) @(negedge clk);
                hold_ack[0] = 0;
                if (RATIO == 2) begin
                    repeat (9) @(negedge clk);
                    hold_ack = '0;
                end
                repeat (12) @(negedge clk);
                for (int b = 0; b < RATIO; ++b) begin
                    if (bank_acks[b] < old_acks + 1)
                        $fatal(1, "write ACK did not drain with DMA rsp_ready low");
                end
                drive_rsp_ready = 1;
            end
        join
        wait (read_count == old_reads + 1);
        repeat (12) @(negedge clk);
        if (read_count != old_reads + 1)
            $fatal(1, "read response duplicated");
    endtask

    task automatic depth_retention_test;
        logic [511:0] low_payload, high_payload;
        int previous_reads;
        for (int i = 0; i < 64; ++i) begin
            low_payload[i*8 +: 8] = 8'(i * 7 + 13);
            high_payload[i*8 +: 8] = 8'(i * 11 + 91);
        end
        // Both writes precede either read. Truncating row bit 10 would alias
        // rows 1023/2047 and corrupt the first read instead of passing a
        // write/read test that accidentally uses the same truncated address.
        drive_rsp_ready = 1;
        request(1, 1023, 0, low_payload);
        request(1, 2047, 0, high_payload);
        previous_reads = read_count;
        expected_data = low_payload;
        expected_tag = TAG_WIDTH'(2);
        read_expected = 1;
        request(0, 1023, expected_tag, '0);
        wait (read_count == previous_reads + 1);
        @(negedge clk);
        expected_data = high_payload;
        expected_tag = TAG_WIDTH'(3);
        read_expected = 1;
        request(0, 2047, expected_tag, '0);
        wait (read_count == previous_reads + 2);
        repeat (12) @(negedge clk);
        $display("COVERAGE: distinct row1023/row2047 payloads retained across both writes");
    endtask

    initial begin
        reset_design();
        transition_test(0, 17);
        transition_test(0, 41);
        transition_test('1, 83);
        for (int b = 0; b < RATIO; ++b) begin
            if (bank_writes[b] != 3 || bank_reads[b] != 3 || bank_acks[b] != 6)
                $fatal(1, "bank%0d count mismatch write=%0d read=%0d ack=%0d",
                       b, bank_writes[b], bank_reads[b], bank_acks[b]);
        end
        // No read is outstanding: write ACKs must be locally consumed even
        // when the DMA refuses responses indefinitely.
        @(negedge clk);
        drive_rsp_ready = 0;
        request(1, 6, 0, '1);
        repeat (20) @(negedge clk);
        for (int b = 0; b < RATIO; ++b) begin
            if (bank_writes[b] != 4 || bank_reads[b] != 3 || bank_acks[b] != 7)
                $fatal(1, "write-only ACK failed to drain on bank%0d", b);
        end
        // Reset with write acknowledgements still physically pending.
        @(negedge clk);
        hold_ack = '1;
        request(1, 7, 0, '1);
        reset_design();
        // Exercise the final physical row, including 2048-deep MXU16 banks.
        transition_test(0, 29, BANK_SIZE / DATA_SIZE - 1);
        for (int b = 0; b < RATIO; ++b) begin
            if (bank_writes[b] != 1 || bank_reads[b] != 1 || bank_acks[b] != 2)
                $fatal(1, "post-reset bank%0d count mismatch", b);
        end
        if (BANK_SIZE / DATA_SIZE == 2048)
            depth_retention_test();
        @(negedge clk);
        local_write_valid = 1;
        do @(posedge clk); while (!dut.g_bank[0].bank_port_if[5].req_ready);
        @(negedge clk);
        local_write_valid = 0;
        wait (local_write_acks == 1);
        repeat (12) @(negedge clk);
        if (local_write_acks != 1)
            $fatal(1, "local output write ACK duplicated");
        $display("TEST PASSED: actual TMEM subsystem write ACK filter bytes=%0d banks=%0d UUID=%0d", DATA_SIZE, NUM_BANKS, UUID_WIDTH);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "timeout waiting for filtered DMA read response");
    end
endmodule

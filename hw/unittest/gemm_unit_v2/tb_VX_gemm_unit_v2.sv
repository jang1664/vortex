`timescale 1ns / 1ps

`include "VX_define.vh"

module tb_VX_gemm_unit_v2 import VX_gpu_pkg::*;
    import fpint_emul::*;
    import cf_math_util_pkg::*;
();

    localparam int PERIOD = 10;
    localparam int FP32_WIDTH = 32;
    localparam int FP16_WIDTH = 16;
    localparam int NUM_TEST_PACKETS = 16;
    localparam int ACC_ROW_BYTES = `GEMM_PSUM_DATA_SIZE;
    localparam int RANDOM_PACKET_COUNT = 40;
    localparam int RANDOM_COMMAND_LENGTH = 10;
    localparam int RANDOM_COMMAND_COUNT
        = RANDOM_PACKET_COUNT / RANDOM_COMMAND_LENGTH;
    // Same-group: 2 groups * 2 bank offsets * 2 packets (admission handoff
    // and registered fence). Different-group: 2 groups * 3 phases.
    localparam int ARBITRATION_COMPUTE_PACKETS
        = (2 * 2 * 2) + (2 * 3);
    localparam int M3_D3_RAW_LAST_WRITES = 2;
    localparam int M5_READ_WRITE_ARB_LAST_WRITES = 2;
    localparam int EXPECTED_LAST_WRITES
        = 22 + RANDOM_COMMAND_COUNT + ARBITRATION_COMPUTE_PACKETS
        + M3_D3_RAW_LAST_WRITES + M5_READ_WRITE_ARB_LAST_WRITES;

    typedef logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] input_vector_t;
    typedef logic [`MXU_COL-1:0][FP32_WIDTH-1:0] psum_vector_t;

    typedef struct {
        logic acc_wr_en;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        logic [1:0] bank;
        logic notify_on_writeback;
        logic last;
    } write_expect_t;

    typedef struct {
        logic is_early;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        logic [1:0] bank;
    } read_expect_t;

    typedef struct {
        logic valid;
        logic acc_wr_en;
        logic [1:0] write_bank;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] write_address;
    } post_history_t;

    typedef struct {
        logic acc_rd_en;
        logic immediate_forward;
        logic history_forward;
        logic early_read;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_address;
    } forward_expect_t;

    typedef struct {
        logic acc_rd_en;
        logic acc_wr_en;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_address;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] write_address;
        logic [1:0] write_bank;
        logic notify_on_writeback;
        logic last;
    } transaction_expect_t;

    logic clk;
    logic reset;
    int cycle_count;
    int input_count;
    int write_count;
    int early_read_count;
    int nominal_read_count;
    int coincident_read_count;
    int forward_count;
    int history_forward_count;
    int d3_raw_stall_count;
    int acc_write_backpressure_count;
    int last_write_count;
    int weight_consume_count [2];
    int scale_consume_count [2];
    int zp_consume_count [2];
    bit test_failed;
    longint unsigned scoreboard_cycle;
    int scoreboard_admission_count;
    int scoreboard_retire_count;
    int scoreboard_write_count;
    int scoreboard_read_count;
    int scoreboard_coincident_read_count;
    int scoreboard_forward_count;
    int scoreboard_history_forward_count;
    int scoreboard_early_hold_count;
    int scoreboard_output_read_count;
    int scoreboard_output_response_count;
    int scoreboard_stalled_input_cycles;
    transaction_expect_t launch_expect_q[$];
    write_expect_t write_expect_q[$];
    read_expect_t read_expect_q[$];
    post_history_t post_history_q[$];
    forward_expect_t forward_expect_q[$];

    function automatic logic [1:0] scoreboard_acc_bank(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address
    );
        logic group;
        logic bank_offset;
        group = address[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        bank_offset = address[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
    endfunction

    function automatic logic [FP32_WIDTH-1:0] fp32_from_int(
        input int value
    );
        shortreal converted;
        converted = value;
        return $shortrealtobits(converted);
    endfunction

    function automatic logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]
        directed_acc_address(
            input logic group,
            input logic bank_offset,
            input int unsigned depth
        );
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        address = `GEMM_ACC_MEM_ADDR_WIDTH'(
            depth << `CLOG2(`GEMM_PSUM_DATA_SIZE));
        address[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1] = group;
        address[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)] = bank_offset;
        return address;
    endfunction

    function automatic int unsigned next_random(input int unsigned state);
        int unsigned value;
        value = state;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        return value;
    endfunction

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_INPUT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) i_lmem_bus_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_WEIGHT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) w_lmem_bus_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_SCALE_ZERO_DATA_SIZE),
        .TAG_WIDTH (1)
    ) sc_lmem_bus_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_SCALE_ZERO_DATA_SIZE),
        .TAG_WIDTH (1)
    ) zp_lmem_bus_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_OUTPUT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) o_lmem_bus_if ();

    VX_gemm_unit_v2_if gemm_unit_v2_if ();
    assign gemm_unit_v2_if.input_admission_ready = 1'b1;
    for (genvar bank = 0; bank < 2; ++bank) begin : g_ready_generations
        assign gemm_unit_v2_if.w_load_value[bank] = 32'd1;
        assign gemm_unit_v2_if.s_load_value[bank] = 32'd1;
        assign gemm_unit_v2_if.z_load_value[bank] = 32'd1;
    end

    logic input_stall_q;
    logic [$bits(i_lmem_bus_if.req_data)-1:0] stalled_input_data_q;
    gemm_input_ctrl_t stalled_input_ctrl_q;

    VX_gemm_unit_v2 #(
        .INSTANCE_ID ("gemm_unit_v2_ut")
    ) u_dut (
        .clk             (clk),
        .reset           (reset),
        .i_lmem_bus_if   (i_lmem_bus_if),
        .w_lmem_bus_if   (w_lmem_bus_if),
        .sc_lmem_bus_if  (sc_lmem_bus_if),
        .zp_lmem_bus_if  (zp_lmem_bus_if),
        .o_lmem_bus_if   (o_lmem_bus_if),
        .gemm_unit_v2_if (gemm_unit_v2_if)
    );

    initial clk = 1'b0;
    always #(PERIOD / 2) clk = ~clk;

    always @(posedge clk) begin
        if (reset) begin
            cycle_count <= 0;
            input_count <= 0;
            write_count <= 0;
            early_read_count <= 0;
            nominal_read_count <= 0;
            coincident_read_count <= 0;
            forward_count <= 0;
            history_forward_count <= 0;
            d3_raw_stall_count <= 0;
            acc_write_backpressure_count <= 0;
            weight_consume_count[0] <= 0;
            weight_consume_count[1] <= 0;
            scale_consume_count[0] <= 0;
            scale_consume_count[1] <= 0;
            zp_consume_count[0] <= 0;
            zp_consume_count[1] <= 0;
            input_stall_q <= 1'b0;
            stalled_input_data_q <= '0;
            stalled_input_ctrl_q <= '0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (i_lmem_bus_if.req_valid && i_lmem_bus_if.req_ready)
                input_count <= input_count + 1;

            if (gemm_unit_v2_if.packet_ctrl.valid
             !== i_lmem_bus_if.req_valid) begin
                $error("input packet/request valid mismatch at cycle %0d",
                       cycle_count);
                test_failed = 1'b1;
            end
            if (input_stall_q) begin
                if (!i_lmem_bus_if.req_valid
                 || !gemm_unit_v2_if.packet_ctrl.valid
                 || i_lmem_bus_if.req_data !== stalled_input_data_q
                 || gemm_unit_v2_if.packet_ctrl !== stalled_input_ctrl_q) begin
                    $error("input request/control changed before ready handshake at cycle %0d",
                           cycle_count);
                    test_failed = 1'b1;
                end
            end
            input_stall_q <= i_lmem_bus_if.req_valid
                          && !i_lmem_bus_if.req_ready;
            if (i_lmem_bus_if.req_valid && !i_lmem_bus_if.req_ready) begin
                stalled_input_data_q <= i_lmem_bus_if.req_data;
                stalled_input_ctrl_q <= gemm_unit_v2_if.packet_ctrl;
                if (u_dut.input_fire) begin
                    $error("stalled input advanced admission at cycle %0d",
                           cycle_count);
                    test_failed = 1'b1;
                end
            end
            if (u_dut.acc_write_fire)
                write_count <= write_count + 1;
            if (|u_dut.early_read_req)
                early_read_count <= early_read_count + 1;
            if (|u_dut.nominal_read_req)
                nominal_read_count <= nominal_read_count + 1;
            if ((|u_dut.early_read_req) && (|u_dut.nominal_read_req))
                coincident_read_count <= coincident_read_count + 1;
            if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].valid
             && u_dut.u_compute_core.forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX])
                forward_count <= forward_count + 1;
            if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].valid
             && u_dut.u_compute_core.history_forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX])
                history_forward_count <= history_forward_count + 1;
            if (u_dut.u_compute_core.post_head_d3_raw_stall)
                d3_raw_stall_count <= d3_raw_stall_count + 1;
            if (u_dut.acc_if.wr_req_valid && !u_dut.acc_if.wr_req_ready)
                acc_write_backpressure_count
                    <= acc_write_backpressure_count + 1;
            if (gemm_unit_v2_if.last_write)
                last_write_count <= last_write_count + 1;
            if (gemm_unit_v2_if.weight_consume_valid)
                weight_consume_count[gemm_unit_v2_if.weight_consume_idx]
                    <= weight_consume_count[
                        gemm_unit_v2_if.weight_consume_idx] + 1;
            if (gemm_unit_v2_if.scale_consume_valid)
                scale_consume_count[gemm_unit_v2_if.scale_consume_idx]
                    <= scale_consume_count[
                        gemm_unit_v2_if.scale_consume_idx] + 1;
            if (gemm_unit_v2_if.zp_consume_valid)
                zp_consume_count[gemm_unit_v2_if.zp_consume_idx]
                    <= zp_consume_count[
                        gemm_unit_v2_if.zp_consume_idx] + 1;
        end
    end

    // Independent transaction scoreboard.  Admission establishes in-order
    // ownership, while each expectation is consumed only at its architectural
    // post-launch, read, scaler, or write event.  Elastic waiting therefore
    // changes no expected cycle and cannot be mistaken for a missing event.
    always @(posedge clk) begin : admission_scoreboard
        transaction_expect_t transaction_expect;
        write_expect_t write_expect;
        read_expect_t read_expect;
        post_history_t history_entry;
        forward_expect_t forward_expect;
        logic [3:0] expected_write_en;
        logic [1:0] current_read_bank;
        logic schedule_early;
        logic schedule_forward;
        logic schedule_history_forward;
        logic schedule_d3_raw_stall;

        if (reset) begin
            scoreboard_cycle = 0;
            launch_expect_q.delete();
            write_expect_q.delete();
            read_expect_q.delete();
            post_history_q.delete();
            forward_expect_q.delete();
        end else begin
            expected_write_en = '0;
            history_entry.valid = 1'b0;
            history_entry.acc_wr_en = 1'b0;
            history_entry.write_bank = '0;
            history_entry.write_address = '0;
            schedule_d3_raw_stall = 1'b0;

            if ((!u_dut.u_compute_core.int2fp_result_empty
              || u_dut.u_compute_core.int2fp_result_push)
             && u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_en
             && (post_history_q.size()
                 > u_dut.u_compute_core.K_LOOKBACK)) begin
                current_read_bank = scoreboard_acc_bank(
                    u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr);
                schedule_d3_raw_stall
                    = !(post_history_q[0].valid
                      && post_history_q[0].acc_wr_en
                      && (post_history_q[0].write_address
                       == u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr))
                   && !(post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].valid
                      && post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].acc_wr_en
                      && (post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].write_address
                       == u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr))
                   && post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].valid
                   && post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].acc_wr_en
                   && (post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK-1].write_bank
                       == current_read_bank)
                   && post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK].valid
                   && post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK].acc_wr_en
                   && (post_history_q[
                        u_dut.u_compute_core.K_LOOKBACK].write_address
                       == u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr);
            end
            if (u_dut.u_compute_core.post_head_d3_raw_stall
                !== schedule_d3_raw_stall) begin
                $error("d=3 RAW stall classification mismatch cycle=%0d expected=%0b actual=%0b",
                       scoreboard_cycle, schedule_d3_raw_stall,
                       u_dut.u_compute_core.post_head_d3_raw_stall);
                test_failed = 1'b1;
            end

            if (u_dut.output_read_fire === 1'b1)
                scoreboard_output_read_count
                    = scoreboard_output_read_count + 1;
            if ((o_lmem_bus_if.rsp_valid === 1'b1)
             && (o_lmem_bus_if.rsp_ready === 1'b1))
                scoreboard_output_response_count
                    = scoreboard_output_response_count + 1;
            if ((i_lmem_bus_if.req_valid === 1'b1)
             && (i_lmem_bus_if.req_ready === 1'b0))
                scoreboard_stalled_input_cycles
                    = scoreboard_stalled_input_cycles + 1;

            // Every accepted transaction commits through the ordered result
            // queue, including packets with acc_wr_en deasserted.  Checking the
            // commit boundary permits the backend to backpressure a same-bank
            // physical write without changing transaction order.
            if (u_dut.u_compute_core.acc_result_commit) begin
                scoreboard_retire_count = scoreboard_retire_count + 1;
                if (write_expect_q.size() == 0) begin
                    $error("unexpected ACC write/control transaction cycle=%0d addr=%h",
                           scoreboard_cycle,
                           u_dut.u_compute_core.acc_result_data_out.ctrl.acc_wr_addr);
                    test_failed = 1'b1;
                end else begin
                    write_expect = write_expect_q.pop_front();
                    expected_write_en[write_expect.bank]
                        = write_expect.acc_wr_en;
                    if (u_dut.u_compute_core.acc_result_data_out.ctrl.acc_wr_en
                          !== write_expect.acc_wr_en
                     || u_dut.u_compute_core.acc_result_data_out.ctrl.acc_wr_addr
                          !== write_expect.address) begin
                        $error("write control order/address mismatch cycle=%0d exp_en=%0b exp_addr=%h actual_en=%0b actual_addr=%h",
                               scoreboard_cycle, write_expect.acc_wr_en,
                               write_expect.address,
                               u_dut.u_compute_core.acc_result_data_out.ctrl.acc_wr_en,
                               u_dut.u_compute_core.acc_result_data_out.ctrl.acc_wr_addr);
                        test_failed = 1'b1;
                    end
                    if (u_dut.acc_write_fire !== write_expect.acc_wr_en
                     || u_dut.acc_mem_wr_en !== expected_write_en) begin
                        $error("ACC write event mismatch cycle=%0d exp_fire=%0b exp_bank_en=%b actual_fire=%0b actual_bank_en=%b",
                               scoreboard_cycle, write_expect.acc_wr_en,
                               expected_write_en, u_dut.acc_write_fire,
                               u_dut.acc_mem_wr_en);
                        test_failed = 1'b1;
                    end
                    if (write_expect.acc_wr_en
                     && (u_dut.acc_mem_in_data[write_expect.bank]
                         !== u_dut.u_compute_core.writeback_result_data)) begin
                        $error("ACC write data routing mismatch cycle=%0d bank=%0d",
                               scoreboard_cycle, write_expect.bank);
                        test_failed = 1'b1;
                    end
                    if (gemm_unit_v2_if.last_write
                        !== (write_expect.acc_wr_en && write_expect.last)) begin
                        $error("last_write misaligned cycle=%0d expected=%0b actual=%0b",
                               scoreboard_cycle,
                               write_expect.acc_wr_en && write_expect.last,
                               gemm_unit_v2_if.last_write);
                        test_failed = 1'b1;
                    end
                    if (gemm_unit_v2_if.tagged_final_writeback
                        !== (write_expect.acc_wr_en
                          && write_expect.last
                          && write_expect.notify_on_writeback)) begin
                        $error("tagged writeback misaligned cycle=%0d expected=%0b actual=%0b",
                               scoreboard_cycle,
                               write_expect.acc_wr_en
                            && write_expect.last
                            && write_expect.notify_on_writeback,
                               gemm_unit_v2_if.tagged_final_writeback);
                        test_failed = 1'b1;
                    end
                    if (write_expect.acc_wr_en)
                        scoreboard_write_count
                            = scoreboard_write_count + 1;
                end
            end else begin
                if (u_dut.acc_write_fire !== 1'b0
                 || u_dut.acc_mem_wr_en !== '0
                 || gemm_unit_v2_if.last_write !== 1'b0
                 || gemm_unit_v2_if.tagged_final_writeback !== 1'b0) begin
                    $error("unexpected ACC write/control cycle=%0d commit=%0b fire=%0b banks=%b last=%0b",
                           scoreboard_cycle,
                           u_dut.u_compute_core.acc_result_commit,
                           u_dut.acc_write_fire, u_dut.acc_mem_wr_en,
                           gemm_unit_v2_if.last_write);
                    test_failed = 1'b1;
                end
            end

            // Each post launch contributes one scaler-boundary expectation.
            // Pop only when the corresponding control actually arrives.
            if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].valid) begin
                if (forward_expect_q.size() == 0) begin
                    $error("unexpected scaler/forward transaction cycle=%0d addr=%h",
                           scoreboard_cycle,
                           u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_addr);
                    test_failed = 1'b1;
                end else begin
                    forward_expect = forward_expect_q.pop_front();
                    if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_en
                          !== forward_expect.acc_rd_en
                     || u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_addr
                          !== forward_expect.read_address
                     || u_dut.u_compute_core.forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                          !== forward_expect.immediate_forward
                     || u_dut.u_compute_core.history_forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                          !== forward_expect.history_forward
                     || u_dut.u_compute_core.early_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                          !== forward_expect.early_read) begin
                        $error("forward sideband order mismatch cycle=%0d exp_rd=%0b exp_immediate=%0b exp_history=%0b exp_early=%0b exp_addr=%h actual_rd=%0b actual_immediate=%0b actual_history=%0b actual_early=%0b actual_addr=%h",
                               scoreboard_cycle,
                               forward_expect.acc_rd_en,
                               forward_expect.immediate_forward,
                               forward_expect.history_forward,
                               forward_expect.early_read,
                               forward_expect.read_address,
                               u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_en,
                               u_dut.u_compute_core.forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX],
                               u_dut.u_compute_core.history_forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX],
                               u_dut.u_compute_core.early_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX],
                               u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_addr);
                        test_failed = 1'b1;
                    end
                    current_read_bank = scoreboard_acc_bank(
                        forward_expect.read_address);
                    if (forward_expect.acc_rd_en) begin
                        if (forward_expect.immediate_forward
                         && (u_dut.u_compute_core.selected_psum_data
                             !== u_dut.u_compute_core.writeback_result_data)) begin
                            $error("immediate-forward data routing mismatch cycle=%0d",
                                   scoreboard_cycle);
                            test_failed = 1'b1;
                        end else if (forward_expect.history_forward
                                  && (u_dut.u_compute_core.selected_psum_data
                                      !== u_dut.u_compute_core.writeback_history_data)) begin
                            $error("history-forward data routing mismatch cycle=%0d",
                                   scoreboard_cycle);
                            test_failed = 1'b1;
                        end else if (forward_expect.early_read
                                  && (u_dut.u_compute_core.selected_psum_data
                                      !== u_dut.early_hold_data[
                                          current_read_bank])) begin
                            $error("early-read data routing mismatch cycle=%0d bank=%0d",
                                   scoreboard_cycle, current_read_bank);
                            test_failed = 1'b1;
                        end else if (!forward_expect.immediate_forward
                                  && !forward_expect.history_forward
                                  && !forward_expect.early_read
                                  && (u_dut.u_compute_core.selected_psum_data
                                      !== u_dut.acc_mem_out_data[
                                          current_read_bank])) begin
                            $error("nominal-read data routing mismatch cycle=%0d bank=%0d",
                                   scoreboard_cycle, current_read_bank);
                            test_failed = 1'b1;
                        end
                    end
                    if (forward_expect.immediate_forward)
                        scoreboard_forward_count
                            = scoreboard_forward_count + 1;
                    if (forward_expect.history_forward)
                        scoreboard_history_forward_count
                            = scoreboard_history_forward_count + 1;
                    if (forward_expect.early_read)
                        scoreboard_early_hold_count
                            = scoreboard_early_hold_count + 1;
                end
            end else if ((u_dut.u_compute_core.forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX] !== 1'b0)
                      || (u_dut.u_compute_core.history_forward_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                          !== 1'b0)
                      || (u_dut.u_compute_core.early_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                          !== 1'b0)) begin
                $error("forward/read sideband without scaler control cycle=%0d",
                       scoreboard_cycle);
                test_failed = 1'b1;
            end

            // Pop accepted transactions at the true post-converter launch.
            // The history is shifted every cycle so forwarding and early-read
            // classification is independent of elastic admission latency but
            // still checks the fixed post-process ownership distances.
            // This runs before request consumption because an early ACC read
            // may be issued in the same cycle as int2fp_result_pop.
            if (u_dut.u_compute_core.int2fp_result_pop) begin
                if (launch_expect_q.size() == 0) begin
                    $error("unexpected INT2FP-result launch cycle=%0d addr=%h",
                           scoreboard_cycle,
                           u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_addr);
                    test_failed = 1'b1;
                end else begin
                    transaction_expect = launch_expect_q.pop_front();
                    if (u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_en
                          !== transaction_expect.acc_rd_en
                     || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_en
                          !== transaction_expect.acc_wr_en
                     || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr
                          !== transaction_expect.read_address
                     || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_addr
                          !== transaction_expect.write_address) begin
                        $error("INT2FP-result launch order/address mismatch cycle=%0d exp_rd_en=%0b exp_wr_en=%0b exp_rd=%h exp_wr=%h actual_rd_en=%0b actual_wr_en=%0b actual_rd=%h actual_wr=%h",
                               scoreboard_cycle,
                               transaction_expect.acc_rd_en,
                               transaction_expect.acc_wr_en,
                               transaction_expect.read_address,
                               transaction_expect.write_address,
                               u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_en,
                               u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_en,
                               u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr,
                               u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_addr);
                        test_failed = 1'b1;
                    end

                    schedule_forward = 1'b0;
                    if (transaction_expect.acc_rd_en
                     && (post_history_q.size() > 0)) begin
                        schedule_forward = post_history_q[0].valid
                            && post_history_q[0].acc_wr_en
                            && (post_history_q[0].write_address
                                == transaction_expect.read_address);
                    end
                    schedule_history_forward = 1'b0;
                    if (transaction_expect.acc_rd_en
                     && !schedule_forward
                     && (post_history_q.size() > 1)) begin
                        schedule_history_forward = post_history_q[1].valid
                            && post_history_q[1].acc_wr_en
                            && (post_history_q[1].write_address
                                == transaction_expect.read_address);
                    end
                    current_read_bank = scoreboard_acc_bank(
                        transaction_expect.read_address);
                    schedule_early = 1'b0;
                    if (transaction_expect.acc_rd_en
                     && !schedule_forward
                     && !schedule_history_forward
                     && (post_history_q.size() >= u_dut.u_compute_core.K_LOOKBACK)) begin
                        schedule_early
                            = post_history_q[u_dut.u_compute_core.K_LOOKBACK-1].valid
                           && post_history_q[u_dut.u_compute_core.K_LOOKBACK-1].acc_wr_en
                           && (post_history_q[
                                   u_dut.u_compute_core.K_LOOKBACK-1].write_bank
                               == current_read_bank);
                    end
                    if (u_dut.u_compute_core.post_launch_forward !== schedule_forward
                     || u_dut.u_compute_core.post_launch_history_forward
                          !== schedule_history_forward
                     || u_dut.u_compute_core.post_launch_early !== schedule_early) begin
                        $error("post-launch dependency classification mismatch cycle=%0d exp_forward=%0b exp_history=%0b exp_early=%0b actual_forward=%0b actual_history=%0b actual_early=%0b",
                               scoreboard_cycle, schedule_forward,
                               schedule_history_forward, schedule_early,
                               u_dut.u_compute_core.post_launch_forward,
                               u_dut.u_compute_core.post_launch_history_forward,
                               u_dut.u_compute_core.post_launch_early);
                        test_failed = 1'b1;
                    end

                    forward_expect.acc_rd_en
                        = transaction_expect.acc_rd_en;
                    forward_expect.immediate_forward = schedule_forward;
                    forward_expect.history_forward
                        = schedule_history_forward;
                    forward_expect.early_read = schedule_early;
                    forward_expect.read_address
                        = transaction_expect.read_address;
                    forward_expect_q.push_back(forward_expect);

                    if (transaction_expect.acc_rd_en
                     && !schedule_forward
                     && !schedule_history_forward) begin
                        read_expect.is_early = schedule_early;
                        read_expect.address
                            = transaction_expect.read_address;
                        read_expect.bank = current_read_bank;
                        read_expect_q.push_back(read_expect);
                    end

                    history_entry.valid = 1'b1;
                    history_entry.acc_wr_en
                        = transaction_expect.acc_wr_en;
                    history_entry.write_bank
                        = transaction_expect.write_bank;
                    history_entry.write_address
                        = transaction_expect.write_address;
                end
            end

            // Nominal and early requests may coincide.  The nominal request
            // belongs to the older launch, so consume it first to retain the
            // architectural transaction order.  The launch block above has
            // already queued a same-cycle early-read expectation.
            if ((u_dut.nominal_read_req != '0)
             && !$onehot(u_dut.nominal_read_req)) begin
                $error("multiple nominal ACC reads in one cycle=%0d req=%b",
                       scoreboard_cycle, u_dut.nominal_read_req);
                test_failed = 1'b1;
            end
            for (int bank = 0; bank < 4; ++bank) begin
                if (u_dut.nominal_read_req[bank]) begin
                    if (read_expect_q.size() == 0) begin
                        $error("unexpected nominal ACC read cycle=%0d bank=%0d addr=%h",
                               scoreboard_cycle, bank,
                               u_dut.read_req_addr[bank]);
                        test_failed = 1'b1;
                    end else begin
                        read_expect = read_expect_q.pop_front();
                        if (read_expect.is_early
                         || read_expect.bank != bank
                         || read_expect.address
                              !== u_dut.read_req_addr[bank]) begin
                            $error("nominal ACC read order/address mismatch cycle=%0d exp_early=%0b exp_bank=%0d exp_addr=%h actual_bank=%0d actual_addr=%h",
                                   scoreboard_cycle, read_expect.is_early,
                                   read_expect.bank, read_expect.address,
                                   bank, u_dut.read_req_addr[bank]);
                            test_failed = 1'b1;
                        end
                        scoreboard_read_count
                            = scoreboard_read_count + 1;
                    end
                end
            end
            if ((u_dut.early_read_req != '0)
             && !$onehot(u_dut.early_read_req)) begin
                $error("multiple early ACC reads in one cycle=%0d req=%b",
                       scoreboard_cycle, u_dut.early_read_req);
                test_failed = 1'b1;
            end
            for (int bank = 0; bank < 4; ++bank) begin
                if (u_dut.early_read_req[bank]) begin
                    if (read_expect_q.size() == 0) begin
                        $error("unexpected early ACC read cycle=%0d bank=%0d addr=%h",
                               scoreboard_cycle, bank,
                               u_dut.read_req_addr[bank]);
                        test_failed = 1'b1;
                    end else begin
                        read_expect = read_expect_q.pop_front();
                        if (!read_expect.is_early
                         || read_expect.bank != bank
                         || read_expect.address
                              !== u_dut.read_req_addr[bank]) begin
                            $error("early ACC read order/address mismatch cycle=%0d exp_early=%0b exp_bank=%0d exp_addr=%h actual_bank=%0d actual_addr=%h",
                                   scoreboard_cycle, read_expect.is_early,
                                   read_expect.bank, read_expect.address,
                                   bank, u_dut.read_req_addr[bank]);
                            test_failed = 1'b1;
                        end
                        scoreboard_read_count
                            = scoreboard_read_count + 1;
                    end
                end
            end
            if ((|u_dut.early_read_req) && (|u_dut.nominal_read_req))
                scoreboard_coincident_read_count
                    = scoreboard_coincident_read_count + 1;

            if (i_lmem_bus_if.req_valid && i_lmem_bus_if.req_ready) begin
                if (gemm_unit_v2_if.packet_ctrl.valid !== 1'b1) begin
                    $error("scoreboard admission without packet control cycle=%0d",
                           scoreboard_cycle);
                    test_failed = 1'b1;
                end

                transaction_expect.acc_rd_en
                    = gemm_unit_v2_if.packet_ctrl.acc_rd_en;
                transaction_expect.acc_wr_en
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_en;
                transaction_expect.read_address
                    = gemm_unit_v2_if.packet_ctrl.acc_rd_addr;
                transaction_expect.write_address
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
                transaction_expect.write_bank = scoreboard_acc_bank(
                    gemm_unit_v2_if.packet_ctrl.acc_wr_addr);
                transaction_expect.last
                    = gemm_unit_v2_if.packet_ctrl.last;
                transaction_expect.notify_on_writeback
                    = gemm_unit_v2_if.packet_ctrl.notify_on_writeback;
                launch_expect_q.push_back(transaction_expect);

                write_expect.acc_wr_en
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_en;
                write_expect.address
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
                write_expect.bank = scoreboard_acc_bank(
                    gemm_unit_v2_if.packet_ctrl.acc_wr_addr);
                write_expect.last = gemm_unit_v2_if.packet_ctrl.last;
                write_expect.notify_on_writeback
                    = gemm_unit_v2_if.packet_ctrl.notify_on_writeback;
                write_expect_q.push_back(write_expect);
                scoreboard_admission_count
                    = scoreboard_admission_count + 1;
            end

            post_history_q.push_front(history_entry);
            while (post_history_q.size()
                   > u_dut.u_compute_core.K_LOOKBACK + 1)
                void'(post_history_q.pop_back());

            if (gemm_unit_v2_if.pipeline_empty
             && !i_lmem_bus_if.req_valid
             && ((launch_expect_q.size() != 0)
              || (write_expect_q.size() != 0)
              || (read_expect_q.size() != 0)
              || (forward_expect_q.size() != 0))) begin
                $error("pipeline_empty with pending scoreboard ownership cycle=%0d launch=%0d write=%0d read=%0d forward=%0d",
                       scoreboard_cycle, launch_expect_q.size(),
                       write_expect_q.size(), read_expect_q.size(),
                       forward_expect_q.size());
                test_failed = 1'b1;
            end
            scoreboard_cycle = scoreboard_cycle + 1;
        end
    end

    task automatic init_signals();
        i_lmem_bus_if.req_valid = 1'b0;
        i_lmem_bus_if.req_data = '0;
        i_lmem_bus_if.rsp_ready = 1'b1;
        w_lmem_bus_if.req_valid = 1'b0;
        w_lmem_bus_if.req_data = '0;
        w_lmem_bus_if.rsp_ready = 1'b1;
        sc_lmem_bus_if.req_valid = 1'b0;
        sc_lmem_bus_if.req_data = '0;
        sc_lmem_bus_if.rsp_ready = 1'b1;
        zp_lmem_bus_if.req_valid = 1'b0;
        zp_lmem_bus_if.req_data = '0;
        zp_lmem_bus_if.rsp_ready = 1'b1;
        o_lmem_bus_if.req_valid = 1'b0;
        o_lmem_bus_if.req_data = '0;
        o_lmem_bus_if.rsp_ready = 1'b1;
        gemm_unit_v2_if.packet_ctrl = '0;
    endtask

    task automatic apply_reset();
        reset = 1'b1;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (3) @(posedge clk);
        if (i_lmem_bus_if.req_ready !== 1'b1) begin
            $error("ready is not high after reset");
            test_failed = 1'b1;
        end
        if (gemm_unit_v2_if.pipeline_empty !== 1'b1) begin
            $error("pipeline is not empty after reset");
            test_failed = 1'b1;
        end
    endtask

    task automatic clear_weight_bank(input gemm_wreg_idx_t bank);
        for (int beat = 0; beat < (`MXU_ROW / `MXU_WLOAD_NUM); ++beat) begin
            @(negedge clk);
            w_lmem_bus_if.req_valid = 1'b1;
            w_lmem_bus_if.req_data.rw = 1'b1;
            w_lmem_bus_if.req_data.addr
                = $bits(w_lmem_bus_if.req_data.addr)'({1'b0, bank});
            w_lmem_bus_if.req_data.data = '0;
            w_lmem_bus_if.req_data.byteen = '1;
            do @(posedge clk); while (!w_lmem_bus_if.req_ready);
        end
        @(negedge clk);
        w_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic write_scale_reg(
        input logic bank,
        input logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] value
    );
        @(negedge clk);
        sc_lmem_bus_if.req_valid = 1'b1;
        sc_lmem_bus_if.req_data.rw = 1'b1;
        sc_lmem_bus_if.req_data.addr
            = bank * (`MXU_MAX_DIM * `SCALE_WIDTH / 8);
        sc_lmem_bus_if.req_data.data = value;
        sc_lmem_bus_if.req_data.byteen = '1;
        do @(posedge clk); while (!sc_lmem_bus_if.req_ready);
        @(negedge clk);
        sc_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic write_zero_reg(
        input logic bank,
        input logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] value
    );
        @(negedge clk);
        zp_lmem_bus_if.req_valid = 1'b1;
        zp_lmem_bus_if.req_data.rw = 1'b1;
        zp_lmem_bus_if.req_data.addr
            = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8)
            + bank * (`MXU_MAX_DIM * `ZP_WIDTH / 8);
        zp_lmem_bus_if.req_data.data = value;
        zp_lmem_bus_if.req_data.byteen = '1;
        do @(posedge clk); while (!zp_lmem_bus_if.req_ready);
        @(negedge clk);
        zp_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic test_parallel_qparam_ports();
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_reg0_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_reg1_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_reg0_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_reg1_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_reg0_expected;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_reg1_expected;
        int scale_consume_start;
        int zp_consume_start;
        int timeout;
        begin
            for (int i = 0; i < `MXU_MAX_DIM; ++i) begin
                scale_reg0_data[i] = `SCALE_WIDTH'(16'h3000 + i);
                scale_reg1_data[i] = `SCALE_WIDTH'(16'h3800 + i);
                zero_reg0_data[i] = `ZP_WIDTH'(i + 1);
                zero_reg1_data[i] = `ZP_WIDTH'(i + 33);
                zero_reg0_expected[i] = -$signed(zero_reg0_data[i]);
                zero_reg1_expected[i] = -$signed(zero_reg1_data[i]);
            end

            // Scale REG0 and ZP REG1 must accept and write in the same cycle.
            @(negedge clk);
            sc_lmem_bus_if.req_valid = 1'b1;
            sc_lmem_bus_if.req_data = '0;
            sc_lmem_bus_if.req_data.rw = 1'b1;
            sc_lmem_bus_if.req_data.addr = 0;
            sc_lmem_bus_if.req_data.data = scale_reg0_data;
            sc_lmem_bus_if.req_data.byteen = '1;
            zp_lmem_bus_if.req_valid = 1'b1;
            zp_lmem_bus_if.req_data = '0;
            zp_lmem_bus_if.req_data.rw = 1'b1;
            zp_lmem_bus_if.req_data.addr
                = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8)
                + (`MXU_MAX_DIM * `ZP_WIDTH / 8);
            zp_lmem_bus_if.req_data.data = zero_reg1_data;
            zp_lmem_bus_if.req_data.byteen = '1;
            #1;
            if (!sc_lmem_bus_if.req_ready || !zp_lmem_bus_if.req_ready)
                $fatal(1, "parallel qparam REG0/REG1 requests were not both ready");
            @(posedge clk);
            #1;
            if (!gemm_unit_v2_if.scale_register_write
             || !gemm_unit_v2_if.zero_point_register_write
             || !gemm_unit_v2_if.quant_register_write)
                $fatal(1, "parallel qparam REG0/REG1 write pulses were not simultaneous");
            if (u_dut.u_compute_core.scale_regs[0] !== scale_reg0_data
             || u_dut.u_compute_core.zero_regs[1] !== zero_reg1_expected)
                $fatal(1, "parallel qparam REG0/REG1 data mismatch");
            @(negedge clk);
            sc_lmem_bus_if.req_valid = 1'b0;
            zp_lmem_bus_if.req_valid = 1'b0;

            // Exercise the opposite register pair in another simultaneous beat.
            sc_lmem_bus_if.req_valid = 1'b1;
            sc_lmem_bus_if.req_data.addr
                = `MXU_MAX_DIM * `SCALE_WIDTH / 8;
            sc_lmem_bus_if.req_data.data = scale_reg1_data;
            zp_lmem_bus_if.req_valid = 1'b1;
            zp_lmem_bus_if.req_data.addr
                = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8);
            zp_lmem_bus_if.req_data.data = zero_reg0_data;
            @(posedge clk);
            #1;
            if (!gemm_unit_v2_if.scale_register_write
             || !gemm_unit_v2_if.zero_point_register_write
             || u_dut.u_compute_core.scale_regs[1] !== scale_reg1_data
             || u_dut.u_compute_core.zero_regs[0] !== zero_reg0_expected)
                $fatal(1, "parallel qparam REG1/REG0 write mismatch");
            @(negedge clk);
            sc_lmem_bus_if.req_valid = 1'b0;
            zp_lmem_bus_if.req_valid = 1'b0;

            // Admit a no-write QCOL packet with independent qparam indices.
            // The two registers become reusable only after their distinct
            // direct consumer stages have read the selected old generation.
            scale_consume_start = scale_consume_count[0];
            zp_consume_start = zp_consume_count[1];
            i_lmem_bus_if.req_valid = 1'b1;
            i_lmem_bus_if.req_data = '0;
            gemm_unit_v2_if.packet_ctrl = '0;
            gemm_unit_v2_if.packet_ctrl.valid = 1'b1;
            gemm_unit_v2_if.packet_ctrl.sreg_use_idx = 1'b0;
            gemm_unit_v2_if.packet_ctrl.zreg_use_idx = 1'b1;
            gemm_unit_v2_if.packet_ctrl.w_load_target = 32'd1;
            gemm_unit_v2_if.packet_ctrl.s_load_target = 32'd1;
            gemm_unit_v2_if.packet_ctrl.z_load_target = 32'd1;
            gemm_unit_v2_if.packet_ctrl.last = 1'b1;
            do @(posedge clk); while (!i_lmem_bus_if.req_ready);
            @(negedge clk);
            i_lmem_bus_if.req_valid = 1'b0;
            gemm_unit_v2_if.packet_ctrl = '0;
            timeout = 0;
            while (((scale_consume_count[0] == scale_consume_start)
                  || (zp_consume_count[1] == zp_consume_start))
                && (timeout < 200)) begin
                @(posedge clk);
                timeout++;
            end
            if (timeout == 200
             || scale_consume_count[0] != scale_consume_start + 1
             || zp_consume_count[1] != zp_consume_start + 1)
                $fatal(1, "independent consumer-stage qparam metadata mismatch");
            @(negedge clk);
            sc_lmem_bus_if.req_valid = 1'b1;
            sc_lmem_bus_if.req_data.addr = 0;
            sc_lmem_bus_if.req_data.data = scale_reg1_data;
            zp_lmem_bus_if.req_valid = 1'b1;
            zp_lmem_bus_if.req_data.addr
                = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8);
            zp_lmem_bus_if.req_data.data = zero_reg1_data;
            #1;
            if (!sc_lmem_bus_if.req_ready || !zp_lmem_bus_if.req_ready)
                $fatal(1, "qparam register did not release after final direct read");
            @(posedge clk);
            #1;
            if (!gemm_unit_v2_if.scale_register_write
             || !gemm_unit_v2_if.zero_point_register_write)
                $fatal(1, "post-consumer qparam writes were not simultaneous");
            @(negedge clk);
            sc_lmem_bus_if.req_valid = 1'b0;
            zp_lmem_bus_if.req_valid = 1'b0;
            $display("QPARAM_PARALLEL_PORTS_PASS simultaneous_64B=1 reg0_reg1=1 consumer_stage_release=1");
        end
    endtask

    task automatic test_nonlast_qcol_consumer_metadata_overlap();
        input_vector_t input_data;
        bit qcol_scale_seen;
        bit qcol_zp_seen;
        int timeout;
        begin
            input_data = '0;

            // Hold an unrelated QROW bank-1 transaction at the input Scale
            // consumer while an older non-final QCOL bank-0 transaction
            // reaches its later ZP and Scale direct reads.  The last-event
            // muxes deliberately point at QROW here and must not feed either
            // QCOL read/readiness/lifetime decision.
            drive_packet_ctrl(input_data, '0, 1'b0, 1'b0, 1'b0,
                              `QDIR_COL, gemm_wreg_idx_t'(0), 1'b0, 1'b0,
                              1'b0, 1'b0);
            force u_dut.u_compute_core.qrow_scaler_input_ready = 1'b0;
            drive_packet_ctrl(
                              input_data,
                              `GEMM_ACC_MEM_ADDR_WIDTH'(ACC_ROW_BYTES),
                              1'b0, 1'b0, 1'b0,
                              `QDIR_ROW, gemm_wreg_idx_t'(1), 1'b1, 1'b1,
                              1'b0, 1'b1);
            end_stream();

            timeout = 0;
            while (!(u_dut.u_compute_core.in_pipe_valid_out
                  && (u_dut.u_compute_core.qrow_scale_consumer_ctrl.quant_dir == `QDIR_ROW)
                  && (u_dut.u_compute_core.qrow_scale_consumer_ctrl.sreg_use_idx == 1'b1)
                  && (u_dut.u_compute_core.qrow_zp_consumer_ctrl.zreg_use_idx == 1'b1))
                && (timeout < 100)) begin
                @(negedge clk);
                ++timeout;
            end
            if (timeout == 100)
                $fatal(1, "failed to hold opposite-QDIR/bank consumer metadata");

            qcol_scale_seen = 1'b0;
            qcol_zp_seen = 1'b0;
            timeout = 0;
            while ((!qcol_scale_seen || !qcol_zp_seen) && (timeout < 200)) begin
                @(negedge clk);
                if (u_dut.u_compute_core.qcol_zp_consumer_fire) begin
                    if (u_dut.u_compute_core.qcol_zp_consumer_ctrl.quant_dir != `QDIR_COL
                     || u_dut.u_compute_core.qcol_zp_consumer_ctrl.zreg_use_idx != 1'b0
                     || u_dut.u_compute_core.qcol_zp_consumer_ctrl.last
                     || u_dut.u_compute_core.zp_last_consume_idx != 1'b1)
                        $fatal(1, "non-last QCOL ZP used last-event metadata");
                    qcol_zp_seen = 1'b1;
                end
                if (u_dut.u_compute_core.qcol_scale_consumer_fire) begin
                    if (u_dut.u_compute_core.qcol_scale_consumer_ctrl.quant_dir != `QDIR_COL
                     || u_dut.u_compute_core.qcol_scale_consumer_ctrl.sreg_use_idx != 1'b0
                     || u_dut.u_compute_core.qcol_scale_consumer_ctrl.last
                     || u_dut.u_compute_core.scale_last_consume_idx != 1'b1)
                        $fatal(1, "non-last QCOL Scale used last-event metadata");
                    qcol_scale_seen = 1'b1;
                end
                ++timeout;
            end
            if (timeout == 200)
                $fatal(1, "timeout waiting for non-last QCOL consumers");

            release u_dut.u_compute_core.qrow_scaler_input_ready;
            wait_for_empty();
            $display("NONLAST_QCOL_CONSUMER_METADATA_PASS qcol_bank=0 held_qrow_bank=1");
        end
    endtask

    task automatic write_weight_matrix(
        input gemm_wreg_idx_t bank,
        input logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            value
    );
        logic [`MXU_ROW*`MXU_COL*`W_BIT_WIDTH-1:0] flat_value;
        flat_value = value;
        for (int beat = 0; beat < (`MXU_ROW / `MXU_WLOAD_NUM); ++beat) begin
            @(negedge clk);
            w_lmem_bus_if.req_valid = 1'b1;
            w_lmem_bus_if.req_data.rw = 1'b1;
            w_lmem_bus_if.req_data.addr
                = $bits(w_lmem_bus_if.req_data.addr)'({1'b0, bank});
            w_lmem_bus_if.req_data.data
                = flat_value[
                    beat * (`MXU_COL * `MXU_WLOAD_NUM * `W_BIT_WIDTH)
                    +: (`MXU_COL * `MXU_WLOAD_NUM * `W_BIT_WIDTH)
                ];
            w_lmem_bus_if.req_data.byteen = '1;
            do @(posedge clk); while (!w_lmem_bus_if.req_ready);
        end
        @(negedge clk);
        w_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic read_output(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        output logic [`MXU_COL-1:0][FP16_WIDTH-1:0] data
    );
        @(negedge clk);
        o_lmem_bus_if.req_valid = 1'b1;
        o_lmem_bus_if.req_data.rw = 1'b0;
        o_lmem_bus_if.req_data.addr
            = address >> `CLOG2(`GEMM_PSUM_DATA_SIZE);
        do @(posedge clk); while (!o_lmem_bus_if.req_ready);
        @(negedge clk);
        o_lmem_bus_if.req_valid = 1'b0;
        while (!o_lmem_bus_if.rsp_valid)
            @(posedge clk);
        data = o_lmem_bus_if.rsp_data.data;
        @(posedge clk);
    endtask

    task automatic drive_compute_request(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address
    );
        i_lmem_bus_if.req_valid = 1'b1;
        i_lmem_bus_if.req_data.rw = 1'b0;
        i_lmem_bus_if.req_data.addr = '0;
        i_lmem_bus_if.req_data.data = '0;
        i_lmem_bus_if.req_data.byteen = '1;
        gemm_unit_v2_if.packet_ctrl = '0;
        gemm_unit_v2_if.packet_ctrl.valid = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_rd_en = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_wr_en = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_rd_addr = address;
        gemm_unit_v2_if.packet_ctrl.acc_wr_addr = address;
        gemm_unit_v2_if.packet_ctrl.quant_dir = `QDIR_COL;
        gemm_unit_v2_if.packet_ctrl.w_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.s_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.z_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.is_load = 1'b0;
        gemm_unit_v2_if.packet_ctrl.notify_on_writeback = 1'b1;
        gemm_unit_v2_if.packet_ctrl.last = 1'b1;
    endtask

    task automatic clear_compute_request();
        i_lmem_bus_if.req_valid = 1'b0;
        gemm_unit_v2_if.packet_ctrl = '0;
    endtask

    task automatic drive_output_request(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        input logic tag
    );
        o_lmem_bus_if.req_valid = 1'b1;
        o_lmem_bus_if.req_data = '0;
        o_lmem_bus_if.req_data.rw = 1'b0;
        o_lmem_bus_if.req_data.addr
            = address >> `CLOG2(`GEMM_PSUM_DATA_SIZE);
        o_lmem_bus_if.req_data.tag = tag;
    endtask

    task automatic clear_output_request();
        o_lmem_bus_if.req_valid = 1'b0;
        o_lmem_bus_if.req_data = '0;
    endtask

    task automatic check_output_response_tag(input logic expected_tag);
        int timeout;
        timeout = 0;
        while (!o_lmem_bus_if.rsp_valid && timeout < 100) begin
            @(negedge clk);
            timeout++;
        end
        if (timeout == 100) begin
            $error("timeout waiting for output response tag=%0b", expected_tag);
            test_failed = 1'b1;
        end else if (o_lmem_bus_if.rsp_data.tag !== expected_tag) begin
            $error("output response tag mismatch expected=%0b actual=%0b",
                   expected_tag, o_lmem_bus_if.rsp_data.tag);
            test_failed = 1'b1;
        end
        @(posedge clk);
        @(negedge clk);
        if (u_dut.output_read_valid !== 1'b0) begin
            $error("output response did not retire after ready handshake");
            test_failed = 1'b1;
        end
    endtask

    task automatic check_output_bank_exclusion(input string check_name);
        if ((u_dut.compute_bank_read_req & u_dut.output_bank_read_req) != 0
         || (u_dut.acc_mem_wr_en & u_dut.output_bank_read_req) != 0) begin
            $error("physical ACC bank conflict during %s compute_read=%b write=%b output=%b",
                   check_name, u_dut.compute_bank_read_req,
                   u_dut.acc_mem_wr_en, u_dut.output_bank_read_req);
            test_failed = 1'b1;
        end
    endtask

    task automatic drive_packet_ctrl(
        input input_vector_t data,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        input logic is_load,
        input logic acc_rd_en,
        input logic acc_wr_en,
        input logic quant_dir,
        input gemm_wreg_idx_t wreg_idx,
        input logic sreg_idx,
        input logic zreg_idx,
        input logic notify_on_writeback,
        input logic last
    );
        @(negedge clk);
        i_lmem_bus_if.req_valid = 1'b1;
        i_lmem_bus_if.req_data.rw = 1'b0;
        i_lmem_bus_if.req_data.addr = '0;
        i_lmem_bus_if.req_data.data = data;
        i_lmem_bus_if.req_data.byteen = '1;
        gemm_unit_v2_if.packet_ctrl.valid = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_rd_en = acc_rd_en;
        gemm_unit_v2_if.packet_ctrl.acc_wr_en = acc_wr_en;
        gemm_unit_v2_if.packet_ctrl.acc_rd_addr = address;
        gemm_unit_v2_if.packet_ctrl.acc_wr_addr = address;
        gemm_unit_v2_if.packet_ctrl.quant_dir = quant_dir;
        gemm_unit_v2_if.packet_ctrl.wreg_use_idx = wreg_idx;
        gemm_unit_v2_if.packet_ctrl.sreg_use_idx = sreg_idx;
        gemm_unit_v2_if.packet_ctrl.zreg_use_idx = zreg_idx;
        gemm_unit_v2_if.packet_ctrl.w_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.s_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.z_load_target = 32'd1;
        gemm_unit_v2_if.packet_ctrl.is_load = is_load;
        gemm_unit_v2_if.packet_ctrl.notify_on_writeback
            = notify_on_writeback;
        gemm_unit_v2_if.packet_ctrl.last = last;
        // Source valid and both request halves remain unchanged until fire.
        do @(posedge clk); while (!i_lmem_bus_if.req_ready);
    endtask

    task automatic drive_packet(
        input input_vector_t data,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        input logic is_load,
        input logic quant_dir,
        input gemm_wreg_idx_t wreg_idx,
        input logic sreg_idx,
        input logic zreg_idx,
        input logic last
    );
        drive_packet_ctrl(data, address, is_load, !is_load, 1'b1,
                          quant_dir, wreg_idx, sreg_idx, zreg_idx,
                          last, last);
    endtask

    task automatic drive_bubble(input int count);
        @(negedge clk);
        i_lmem_bus_if.req_valid = 1'b0;
        gemm_unit_v2_if.packet_ctrl = '0;
        repeat (count) @(posedge clk);
    endtask

    task automatic end_stream();
        @(negedge clk);
        i_lmem_bus_if.req_valid = 1'b0;
        gemm_unit_v2_if.packet_ctrl = '0;
    endtask

    task automatic test_resource_consumer_stages(
        input logic bank,
        input logic quant_dir,
        input int bubble_cycles
    );
        input_vector_t input_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] old_scale;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] new_scale;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] old_zero;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] new_zero;
        int weight_count_start;
        int scale_count_start;
        int zp_count_start;
        int timeout;
        bit weight_consume_seen;
        begin
            input_data = '0;
            for (int lane = 0; lane < `MXU_MAX_DIM; ++lane) begin
                old_scale[lane] = `SCALE_WIDTH'(16'h3400 + lane + bank * 16);
                new_scale[lane] = `SCALE_WIDTH'(16'h3c00 + lane + bank * 16);
                old_zero[lane] = `ZP_WIDTH'(lane + 3 + bank * 32);
                new_zero[lane] = `ZP_WIDTH'(lane + 67 + bank * 32);
            end

            write_scale_reg(bank, old_scale);
            write_zero_reg(bank, old_zero);
            weight_count_start = weight_consume_count[bank];
            scale_count_start = scale_consume_count[bank];
            zp_count_start = zp_consume_count[bank];

            // Two packets exercise continuous admission for QROW and an
            // explicit bubble for QCOL.  Phase 2 consumes qparams at their
            // actual QDIR-specific register-read boundaries, not admission.
            drive_packet_ctrl(input_data, '0, 1'b0, 1'b0, 1'b0,
                              quant_dir, bank, bank, bank,
                              1'b0, 1'b0);
            if (bubble_cycles != 0)
                drive_bubble(bubble_cycles);
            drive_packet_ctrl(
                              input_data,
                              `GEMM_ACC_MEM_ADDR_WIDTH'(ACC_ROW_BYTES),
                              1'b0, 1'b0, 1'b0,
                              quant_dir, bank, bank, bank,
                              1'b0, 1'b1);
            end_stream();

            timeout = 0;
            weight_consume_seen = 1'b0;
            while (((weight_consume_count[bank] - weight_count_start) != 1
                 || (scale_consume_count[bank] - scale_count_start) != 1
                 || (zp_consume_count[bank] - zp_count_start) != 1)
                && (timeout < 200)) begin
                if (gemm_unit_v2_if.weight_consume_valid) begin
                    if (gemm_unit_v2_if.weight_consume_idx != bank)
                        $fatal(1, "weight consume bank mismatch");
                    weight_consume_seen = 1'b1;
                end
                @(posedge clk);
                @(negedge clk);
                timeout++;
            end
            if (timeout == 200 || !weight_consume_seen)
                $fatal(1, "timeout waiting for consumer-stage resource events");

            // After the true consumers retire, the next values may be written;
            // no Scale/ZP value was carried in a transaction payload.
            write_scale_reg(bank, new_scale);
            write_zero_reg(bank, new_zero);
            wait_for_empty();
            @(negedge clk);
            if ((weight_consume_count[bank] - weight_count_start) != 1
             || (scale_consume_count[bank] - scale_count_start) != 1
             || (zp_consume_count[bank] - zp_count_start) != 1)
                $fatal(1, "resource consume pulse count mismatch bank=%0d W=%0d SC=%0d ZP=%0d",
                       bank,
                       weight_consume_count[bank] - weight_count_start,
                       scale_consume_count[bank] - scale_count_start,
                       zp_consume_count[bank] - zp_count_start);
            $display("RESOURCE_CONSUMER_STAGE_PASS bank=%0d qdir=%0d bubbles=%0d",
                     bank, quant_dir, bubble_cycles);
        end
    endtask

    task automatic test_independent_resource_indices();
        input_vector_t input_data;
        gemm_wreg_idx_t expected_wreg;
        logic expected_sreg;
        logic expected_zreg;
        int weight_count_start [2];
        int timeout;
        begin
            input_data = '0;
            weight_count_start[0] = weight_consume_count[0];
            weight_count_start[1] = weight_consume_count[1];

            for (int tuple = 0; tuple < 2; ++tuple) begin
                expected_wreg = gemm_wreg_idx_t'(tuple);
                expected_sreg = logic'(tuple);
                expected_zreg = ~expected_sreg;
                drive_packet_ctrl(input_data, '0, 1'b0, 1'b0, 1'b0,
                                  `QDIR_COL, expected_wreg,
                                  expected_sreg, expected_zreg,
                                  1'b0, 1'b1);
                end_stream();

                timeout = 0;
                while (!gemm_unit_v2_if.weight_consume_valid
                    && timeout < 100) begin
                    @(posedge clk);
                    ++timeout;
                end
                if (timeout == 100
                 || gemm_unit_v2_if.weight_consume_idx != expected_wreg)
                    $fatal(1,
                        "independent W/S/Z Weight consume mismatch W=%0d",
                        expected_wreg);
                wait_for_empty();
            end

            @(negedge clk);
            if ((weight_consume_count[0] - weight_count_start[0]) != 1
             || (weight_consume_count[1] - weight_count_start[1]) != 1)
                $fatal(1,
                    "two-bank Weight consume count mismatch W0=%0d W1=%0d",
                    weight_consume_count[0] - weight_count_start[0],
                    weight_consume_count[1] - weight_count_start[1]);
            $display("INDEPENDENT_RESOURCE_INDICES_PASS tuples=W0_S0_Z1,W1_S1_Z0");
        end
    endtask

    task automatic wait_for_last_write();
        int timeout;
        timeout = 0;
        while (!gemm_unit_v2_if.last_write && timeout < 1000) begin
            @(posedge clk);
            ++timeout;
        end
        if (timeout == 1000) begin
            $error("timeout waiting for last_write");
            test_failed = 1'b1;
        end
        @(posedge clk);
    endtask

    task automatic wait_for_empty();
        int timeout;
        timeout = 0;
        while (!gemm_unit_v2_if.pipeline_empty && timeout < 1000) begin
            @(posedge clk);
            ++timeout;
        end
        if (timeout == 1000) begin
            $error("timeout waiting for pipeline_empty");
            test_failed = 1'b1;
        end
    endtask

    task automatic check_scoreboard_empty(input string check_name);
        @(negedge clk);
        if ((launch_expect_q.size() != 0)
         || (write_expect_q.size() != 0)
         || (read_expect_q.size() != 0)
         || (forward_expect_q.size() != 0)) begin
            $error("scoreboard not empty after %s: launches=%0d writes=%0d reads=%0d forwards=%0d",
                   check_name, launch_expect_q.size(),
                   write_expect_q.size(), read_expect_q.size(),
                   forward_expect_q.size());
            test_failed = 1'b1;
        end
    endtask

    task automatic check_memory(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr,
        input int count,
        input logic [FP32_WIDTH-1:0] expected
    );
        psum_vector_t data;
        for (int i = 0; i < count; ++i) begin
            u_dut.read_acc_mem(
                `GEMM_ACC_MEM_ADDR_WIDTH'(base_addr + i * ACC_ROW_BYTES),
                data);
            for (int lane = 0; lane < `MXU_COL; ++lane) begin
                if (data[lane] !== expected) begin
                    $error("ACC mismatch row=%0d lane=%0d expected=%h actual=%h",
                           i, lane, expected, data[lane]);
                    test_failed = 1'b1;
                end
            end
        end
    endtask

    task automatic test_same_group_stage_block(
        input logic compute_group,
        input logic compute_bank_offset,
        input int unsigned depth
    );
        input_vector_t zero_input;
        psum_vector_t zero_psum;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] compute_address;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_address;
        bit stage_seen [0:63];
        bit stage_required [0:63];
        bit final_write_block_seen;

        zero_input = '0;
        zero_psum = '0;
        compute_address = directed_acc_address(
            compute_group, compute_bank_offset, depth);
        output_address = directed_acc_address(
            compute_group, ~compute_bank_offset, depth + 32);
        u_dut.initialize_acc_mem(compute_address, 1, zero_psum);
        u_dut.initialize_acc_mem(output_address, 1, zero_psum);
        for (int stage = 0; stage < 64; ++stage) begin
            stage_seen[stage] = 1'b0;
            stage_required[stage] = 1'b0;
        end
        // Elastic control has intentional holes between the branch output and
        // prealign completion.  Cover the architectural ownership boundaries
        // instead of requiring every legacy fixed-latency index to toggle.
        stage_required[u_dut.u_compute_core.INPUT_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.PREALIGN_INPUT_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.PREALIGN_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.PREALIGN_CTRL_IDX+1] = 1'b1;
        stage_required[u_dut.u_compute_core.QCOL_REDUCE_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.PREPROCESS_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.MXU_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.MERGER_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.INT2FP_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.SCALER_CTRL_IDX] = 1'b1;
        stage_required[u_dut.u_compute_core.WRITE_CTRL_IDX] = 1'b1;
        final_write_block_seen = 1'b0;

        // Admission-edge handoff is legal: the incoming packet does not
        // access ACC until after it has entered ctrl_pipe[0], so the old owner
        // may complete an output read on the same edge.  Accept this transfer
        // as a real handshake before testing the registered-pipeline fence
        // with a second packet below.
        @(negedge clk);
        drive_compute_request(compute_address);
        drive_output_request(output_address, compute_bank_offset);
        #1;
        if ((|u_dut.compute_group_busy)
         || !o_lmem_bus_if.req_ready
         || !u_dut.output_read_fire) begin
            $error("same-group admission-edge output handoff was not accepted group=%0d bank_offset=%0d",
                   compute_group, compute_bank_offset);
            test_failed = 1'b1;
        end
        check_output_bank_exclusion("same-group incoming admission");

        do @(posedge clk); while (!i_lmem_bus_if.req_ready);
        #1;
        if (!u_dut.u_compute_core.ctrl_pipe[0].valid
         || !u_dut.compute_group_busy[compute_group]
         || !u_dut.output_group_conflict) begin
            $error("same-group fence did not begin at ctrl_pipe[0] group=%0d",
                   compute_group);
            test_failed = 1'b1;
        end
        @(negedge clk);
        clear_compute_request();
        clear_output_request();
        check_output_response_tag(compute_bank_offset);
        wait_for_empty();
        check_scoreboard_empty("same-group admission-edge handoff");

        // A registered packet owns its ACC group from ctrl_pipe[0] through
        // final writeback.  Hold a second output request against every stage
        // and require release only after the complete pipeline drains.
        @(negedge clk);
        drive_compute_request(compute_address);
        do @(posedge clk); while (!i_lmem_bus_if.req_ready);
        #1;
        @(negedge clk);
        clear_compute_request();
        drive_output_request(output_address, compute_bank_offset);
        #1;
        if (!u_dut.u_compute_core.ctrl_pipe[0].valid
         || !u_dut.compute_group_busy[compute_group]
         || o_lmem_bus_if.req_ready
         || u_dut.output_read_fire) begin
            $error("same-group output was not blocked from ctrl_pipe[0] group=%0d bank_offset=%0d",
                   compute_group, compute_bank_offset);
            test_failed = 1'b1;
        end
        check_output_bank_exclusion("same-group ctrl_pipe[0]");

        while (u_dut.compute_group_pending_count[compute_group] != 0) begin
            if (!u_dut.compute_group_busy[compute_group]) begin
                $error("same-group busy dropped with accepted ownership group=%0d pending=%0d",
                       compute_group,
                       u_dut.compute_group_pending_count[compute_group]);
                test_failed = 1'b1;
            end
            for (int stage = 0; stage <= u_dut.u_compute_core.WRITE_CTRL_IDX; ++stage) begin
                if (u_dut.u_compute_core.ctrl_pipe[stage].valid) begin
                    stage_seen[stage] = 1'b1;
                    if (u_dut.u_compute_core.ctrl_pipe[stage].acc_rd_addr
                          [`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1]
                        != compute_group
                     || u_dut.u_compute_core.ctrl_pipe[stage].acc_wr_addr
                          [`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1]
                        != compute_group) begin
                        $error("compute group changed in ctrl_pipe stage=%0d", stage);
                        test_failed = 1'b1;
                    end
                end
            end
            if (o_lmem_bus_if.req_ready || u_dut.output_read_fire) begin
                $error("same-group output escaped block while pipeline busy group=%0d stages=%b",
                       compute_group, u_dut.compute_group_busy);
                test_failed = 1'b1;
            end
            if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].valid) begin
                if (!u_dut.acc_write_fire) begin
                    $error("directed final ACC writeback was not valid");
                    test_failed = 1'b1;
                end
                final_write_block_seen = !o_lmem_bus_if.req_ready
                                      && !u_dut.output_read_fire;
            end
            check_output_bank_exclusion("same-group pipeline stage");
            @(posedge clk);
            #1;
            if (u_dut.compute_group_pending_count[compute_group] != 0)
                @(negedge clk);
        end

        for (int stage = 0; stage <= u_dut.u_compute_core.WRITE_CTRL_IDX; ++stage) begin
            if (stage_required[stage] && !stage_seen[stage]) begin
                $error("same-group block did not cover architectural ctrl boundary stage=%0d", stage);
                test_failed = 1'b1;
            end
        end
        if (!final_write_block_seen) begin
            $error("same-group output was not proven blocked through final writeback");
            test_failed = 1'b1;
        end
        if (!o_lmem_bus_if.req_ready || !u_dut.output_read_fire) begin
            $error("same-group output did not release after final writeback");
            test_failed = 1'b1;
        end
        @(posedge clk);
        @(negedge clk);
        clear_output_request();
        check_output_response_tag(compute_bank_offset);
        wait_for_empty();
        check_scoreboard_empty("same-group stage block");
    endtask

    task automatic test_different_group_phase(
        input logic compute_group,
        input int unsigned phase,
        input logic compute_bank_offset,
        input logic output_bank_offset,
        input int unsigned depth
    );
        input_vector_t zero_input;
        psum_vector_t zero_psum;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] compute_address;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_address;
        logic response_tag;
        int timeout;

        zero_input = '0;
        zero_psum = '0;
        response_tag = phase[0];
        compute_address = directed_acc_address(
            compute_group, compute_bank_offset, depth);
        output_address = directed_acc_address(
            ~compute_group, output_bank_offset, depth + 32);
        u_dut.initialize_acc_mem(compute_address, 1, zero_psum);
        u_dut.initialize_acc_mem(output_address, 1, zero_psum);

        @(negedge clk);
        drive_compute_request(compute_address);
        if (phase == 0) begin
            drive_output_request(output_address, response_tag);
            #1;
            if ((|u_dut.compute_group_busy)
             || !o_lmem_bus_if.req_ready
             || !u_dut.output_read_fire) begin
                $error("different-group admission-edge output handoff did not fire group=%0d",
                       compute_group);
                test_failed = 1'b1;
            end
            check_output_bank_exclusion("different-group incoming admission");
            do @(posedge clk); while (!i_lmem_bus_if.req_ready);
            #1;
            if (!u_dut.u_compute_core.ctrl_pipe[0].valid
             || !u_dut.compute_group_busy[compute_group]
             || u_dut.compute_group_busy[~compute_group]) begin
                $error("different-group registered ownership was not visible at ctrl_pipe[0] group=%0d",
                       compute_group);
                test_failed = 1'b1;
            end
            @(negedge clk);
            clear_compute_request();
            clear_output_request();
        end else begin
            do @(posedge clk); while (!i_lmem_bus_if.req_ready);
            @(negedge clk);
            clear_compute_request();
            timeout = 0;
            while ((((phase == 1) && !(|u_dut.compute_bank_read_req))
                  || ((phase == 2)
                   && !(u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].valid
                     && u_dut.acc_write_fire)))
                && timeout < 100) begin
                @(posedge clk);
                @(negedge clk);
                timeout++;
            end
            if (timeout == 100) begin
                $error("timeout waiting for different-group phase=%0d", phase);
                test_failed = 1'b1;
            end
            drive_output_request(output_address, response_tag);
            #1;
            if (!u_dut.compute_group_busy[compute_group]
             || u_dut.compute_group_busy[~compute_group]
             || !o_lmem_bus_if.req_ready
             || !u_dut.output_read_fire) begin
                $error("different-group output did not fire phase=%0d group=%0d",
                       phase, compute_group);
                test_failed = 1'b1;
            end
            if ((phase == 1) && !(|u_dut.compute_bank_read_req)) begin
                $error("mid-pipeline overlap missed physical compute read");
                test_failed = 1'b1;
            end
            if ((phase == 2) && !(|u_dut.acc_mem_wr_en)) begin
                $error("final-writeback overlap missed physical ACC write");
                test_failed = 1'b1;
            end
            check_output_bank_exclusion(
                phase == 1 ? "different-group mid-pipeline"
                           : "different-group final writeback");
            @(posedge clk);
            @(negedge clk);
            clear_output_request();
        end

        check_output_response_tag(response_tag);
        wait_for_empty();
        check_scoreboard_empty("different-group overlap phase");
    endtask

    task automatic test_output_response_backpressure_order();
        psum_vector_t value_a;
        psum_vector_t value_b;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address_a;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address_b;
        logic [`MXU_COL-1:0][FP16_WIDTH-1:0] held_data;
        logic [`MXU_COL-1:0][FP16_WIDTH-1:0] second_data;
        logic held_tag;
        int timeout;

        value_a = '{default: 32'h3f80_0000};
        value_b = '{default: 32'h4000_0000};
        address_a = directed_acc_address(1'b0, 1'b0, 900);
        address_b = directed_acc_address(1'b1, 1'b1, 901);
        u_dut.initialize_acc_mem(address_a, 1, value_a);
        u_dut.initialize_acc_mem(address_b, 1, value_b);

        @(negedge clk);
        o_lmem_bus_if.rsp_ready = 1'b0;
        drive_output_request(address_a, 1'b0);
        #1;
        if (!o_lmem_bus_if.req_ready || !u_dut.output_read_fire) begin
            $error("first backpressure response request was not accepted");
            test_failed = 1'b1;
        end
        @(posedge clk);
        @(negedge clk);
        clear_output_request();
        timeout = 0;
        while (!o_lmem_bus_if.rsp_valid && timeout < 100) begin
            @(posedge clk);
            @(negedge clk);
            timeout++;
        end
        if (timeout == 100) begin
            $error("timeout waiting for first backpressured output response");
            test_failed = 1'b1;
        end
        held_data = o_lmem_bus_if.rsp_data.data;
        held_tag = o_lmem_bus_if.rsp_data.tag;
        for (int lane = 0; lane < `MXU_COL; ++lane) begin
            if (held_data[lane] !== 16'h3c00) begin
                $error("first output data mismatch lane=%0d expected=3c00 actual=%h",
                       lane, held_data[lane]);
                test_failed = 1'b1;
            end
        end
        if (held_tag !== 1'b0) begin
            $error("first output tag mismatch expected=0 actual=%0b", held_tag);
            test_failed = 1'b1;
        end

        drive_output_request(address_b, 1'b1);
        repeat (4) begin
            #1;
            if (o_lmem_bus_if.req_ready || u_dut.output_read_fire
             || !o_lmem_bus_if.rsp_valid
             || o_lmem_bus_if.rsp_data.data !== held_data
             || o_lmem_bus_if.rsp_data.tag !== held_tag) begin
                $error("outstanding response/order changed under backpressure");
                test_failed = 1'b1;
            end
            @(posedge clk);
            @(negedge clk);
        end

        o_lmem_bus_if.rsp_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!o_lmem_bus_if.req_ready || !u_dut.output_read_fire
         || u_dut.output_read_valid) begin
            $error("second request did not release after first response handshake");
            test_failed = 1'b1;
        end
        @(posedge clk);
        @(negedge clk);
        clear_output_request();
        timeout = 0;
        while (!o_lmem_bus_if.rsp_valid && timeout < 100) begin
            @(posedge clk);
            @(negedge clk);
            timeout++;
        end
        if (timeout == 100) begin
            $error("timeout waiting for second ordered output response");
            test_failed = 1'b1;
        end else begin
            second_data = o_lmem_bus_if.rsp_data.data;
            for (int lane = 0; lane < `MXU_COL; ++lane) begin
                if (second_data[lane] !== 16'h4000) begin
                    $error("second output data mismatch lane=%0d expected=4000 actual=%h",
                           lane, second_data[lane]);
                    test_failed = 1'b1;
                end
            end
            if (o_lmem_bus_if.rsp_data.tag !== 1'b1) begin
                $error("second output tag mismatch expected=1 actual=%0b",
                       o_lmem_bus_if.rsp_data.tag);
                test_failed = 1'b1;
            end
        end
        @(posedge clk);
        @(negedge clk);
        if (u_dut.output_read_valid) begin
            $error("second output response did not retire");
            test_failed = 1'b1;
        end
        $display("GEMM_UNIT_V2_GROUP_ARBITRATION_PASS same_group_stages=%0d different_group_phases=6 backpressure=1",
                 u_dut.u_compute_core.WRITE_CTRL_IDX + 1);
    endtask

    task automatic test_group_aware_output_arbitration();
        int unsigned depth;
        depth = 640;
        for (int group = 0; group < 2; ++group) begin
            for (int bank_offset = 0; bank_offset < 2; ++bank_offset) begin
                test_same_group_stage_block(group[0], bank_offset[0], depth);
                depth++;
            end
        end
        for (int group = 0; group < 2; ++group) begin
            test_different_group_phase(group[0], 0, 1'b0, 1'b1, depth);
            depth++;
            test_different_group_phase(group[0], 1, 1'b1, 1'b0, depth);
            depth++;
            test_different_group_phase(group[0], 2, 1'b0, 1'b0, depth);
            depth++;
        end
        test_output_response_backpressure_order();
    endtask

    task automatic test_nonzero_reference(
        input logic quant_dir,
        input logic reg_idx,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address
    );
        input_vector_t input_data;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`MXU_COL-1:0][FP16_WIDTH-1:0] dut_output;
        logic [fpint_emul::IN_WIDTH-1:0]
            ref_input[fpint_emul::MAX_M*fpint_emul::MAX_K];
        logic [fpint_emul::MAX_W_WIDTH-1:0]
            ref_weight[fpint_emul::MAX_K*fpint_emul::MAX_N];
        logic [fpint_emul::S_WIDTH-1:0]
            ref_scale[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::Z_WIDTH-1:0]
            ref_zero[fpint_emul::MAX_KG*fpint_emul::MAX_N];
        logic [fpint_emul::O_WIDTH-1:0]
            ref_output[fpint_emul::MAX_M*fpint_emul::MAX_N];
        logic [fpint_emul::P_WIDTH-1:0]
            ref_psum[fpint_emul::MAX_M*fpint_emul::MAX_N];

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        write_scale_reg(reg_idx, scale_data);
        write_zero_reg(reg_idx, zero_data);
        write_weight_matrix(reg_idx, weight_data);

        ref_input = '{default: '0};
        ref_weight = '{default: '0};
        ref_scale = '{default: '0};
        ref_zero = '{default: '0};
        ref_output = '{default: '0};
        ref_psum = '{default: '0};
        for (int k = 0; k < `MXU_ROW; ++k) begin
            ref_input[k] = input_data[k];
            for (int n = 0; n < `MXU_COL; ++n)
                ref_weight[k * `MXU_COL + n] = weight_data[k][n];
        end
        for (int i = 0; i < fpint_emul::MAX_KG * fpint_emul::MAX_N; ++i) begin
            ref_scale[i] = 16'h3c00;
            ref_zero[i] = '0;
        end

        drive_packet(input_data, address, 1'b1, quant_dir,
                     reg_idx, reg_idx, reg_idx, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        fpint_emul::fpint_gemm_ref(
            ref_input, ref_weight, ref_scale, ref_zero,
            1, `MXU_COL, `MXU_ROW, ref_output,
            quant_dir, fpint_emul::WNOTRANS, 1'b0, ref_psum
        );
        read_output(address, dut_output);
        for (int n = 0; n < `MXU_COL; ++n) begin
            if (dut_output[n] !== ref_output[n]) begin
                $error("nonzero load mismatch qdir=%0d reg=%0d lane=%0d expected=%h actual=%h",
                       quant_dir, reg_idx, n, ref_output[n], dut_output[n]);
                test_failed = 1'b1;
            end
            ref_psum[n] = fp32_from_int(`MXU_ROW);
        end

        ref_output = '{default: '0};
        drive_packet(input_data, address, 1'b0, quant_dir,
                     reg_idx, reg_idx, reg_idx, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        fpint_emul::fpint_gemm_ref(
            ref_input, ref_weight, ref_scale, ref_zero,
            1, `MXU_COL, `MXU_ROW, ref_output,
            quant_dir, fpint_emul::WNOTRANS, 1'b0, ref_psum
        );
        read_output(address, dut_output);
        for (int n = 0; n < `MXU_COL; ++n) begin
            if (dut_output[n] !== ref_output[n]) begin
                $error("nonzero accumulate mismatch qdir=%0d reg=%0d lane=%0d expected=%h actual=%h",
                       quant_dir, reg_idx, n, ref_output[n], dut_output[n]);
                test_failed = 1'b1;
            end
        end
    endtask

    task automatic test_same_address_distance(
        input int distance,
        input logic command_boundary,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address
    );
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        int early_before;
        int nominal_before;
        int forwards_before;
        int history_forwards_before;
        int writes_before;
        int expected_reads;
        int expected_immediate_forwards;
        int expected_history_forwards;
        string check_name;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '{default: 32'h3f80_0000};
        check_name = $sformatf("same-address d=%0d boundary=%0b",
                            distance, command_boundary);

        if ((distance < 1) || (distance > 3)) begin
            $error("invalid directed forwarding distance %0d", distance);
            test_failed = 1'b1;
            return;
        end
        if ((address % ACC_ROW_BYTES) != 0) begin
            $error("unaligned directed forwarding address %h", address);
            test_failed = 1'b1;
            return;
        end

        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(address, 1, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        writes_before = write_count;
        drive_packet(input_data, address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, command_boundary);
        if (distance > 1)
            drive_bubble(distance - 1);
        drive_packet(input_data, address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty(check_name);

        expected_reads = (distance == 3) ? 2 : 1;
        expected_immediate_forwards = (distance == 1) ? 1 : 0;
        expected_history_forwards = (distance == 2) ? 1 : 0;
        if ((early_read_count - early_before) != 0
         || (nominal_read_count - nominal_before) != expected_reads) begin
            $error("%s read count mismatch expected_early=0 expected_nominal=%0d actual_early=%0d actual_nominal=%0d",
                   check_name, expected_reads,
                   early_read_count - early_before,
                   nominal_read_count - nominal_before);
            test_failed = 1'b1;
        end
        if ((forward_count - forwards_before)
            != expected_immediate_forwards) begin
            $error("%s immediate forwarding count mismatch expected=%0d actual=%0d",
                   check_name, expected_immediate_forwards,
                   forward_count - forwards_before);
            test_failed = 1'b1;
        end
        if ((history_forward_count - history_forwards_before)
            != expected_history_forwards) begin
            $error("%s history forwarding count mismatch expected=%0d actual=%0d",
                   check_name, expected_history_forwards,
                   history_forward_count - history_forwards_before);
            test_failed = 1'b1;
        end
        if ((write_count - writes_before) != 2) begin
            $error("%s write count mismatch expected=2 actual=%0d",
                   check_name, write_count - writes_before);
            test_failed = 1'b1;
        end
        // Initial 1.0 plus two MXU_ROW-wide unit dot products.
        check_memory(address, 1, fp32_from_int(1 + 2 * `MXU_ROW));
    endtask

    task automatic test_same_address_d1_chain();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        int early_before;
        int nominal_before;
        int forwards_before;
        int history_forwards_before;
        int writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '{default: 32'h3f80_0000};
        address = `GEMM_ACC_MEM_ADDR_WIDTH'(160 * ACC_ROW_BYTES);

        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(address, 1, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        writes_before = write_count;
        for (int i = 0; i < 3; ++i) begin
            drive_packet(input_data, address, 1'b0, `QDIR_COL,
                         1'b0, 1'b0, 1'b0, i == 2);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("same-address d=1 chain");

        if ((early_read_count - early_before) != 0
         || (nominal_read_count - nominal_before) != 1
         || (forward_count - forwards_before) != 2
         || (history_forward_count - history_forwards_before) != 0
         || (write_count - writes_before) != 3) begin
            $error("same-address d=1 chain event mismatch early=%0d nominal=%0d immediate=%0d history=%0d writes=%0d",
                   early_read_count - early_before,
                   nominal_read_count - nominal_before,
                   forward_count - forwards_before,
                   history_forward_count - history_forwards_before,
                   write_count - writes_before);
            test_failed = 1'b1;
        end
        // Initial 1.0 plus three MXU_ROW-wide unit dot products.
        check_memory(address, 1, fp32_from_int(1 + 3 * `MXU_ROW));
    endtask

    task automatic test_same_bank_different_address_d2();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address_a;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address_b;
        int early_before;
        int nominal_before;
        int forwards_before;
        int history_forwards_before;
        int writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '{default: 32'h3f80_0000};
        address_a = `GEMM_ACC_MEM_ADDR_WIDTH'(168 * ACC_ROW_BYTES);
        address_b = `GEMM_ACC_MEM_ADDR_WIDTH'(170 * ACC_ROW_BYTES);

        if (scoreboard_acc_bank(address_a) != scoreboard_acc_bank(address_b)) begin
            $error("directed d=2 addresses do not share an ACC bank");
            test_failed = 1'b1;
            return;
        end
        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(address_a, 3, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        writes_before = write_count;
        drive_packet(input_data, address_a, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        drive_bubble(1);
        drive_packet(input_data, address_b, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("same-bank different-address d=2");

        if ((early_read_count - early_before) != 1
         || (nominal_read_count - nominal_before) != 1
         || (forward_count - forwards_before) != 0
         || (history_forward_count - history_forwards_before) != 0
         || (write_count - writes_before) != 2) begin
            $error("same-bank different-address d=2 event mismatch early=%0d nominal=%0d immediate=%0d history=%0d writes=%0d",
                   early_read_count - early_before,
                   nominal_read_count - nominal_before,
                   forward_count - forwards_before,
                   history_forward_count - history_forwards_before,
                   write_count - writes_before);
            test_failed = 1'b1;
        end
        // Each row starts at 1.0 and receives one MXU_ROW-wide dot product.
        check_memory(address_a, 1, fp32_from_int(1 + `MXU_ROW));
        check_memory(address_b, 1, fp32_from_int(1 + `MXU_ROW));
    endtask

    task automatic test_m2_seamless_micro_k_d2();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] row0_address;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] row1_address;
        int early_before;
        int nominal_before;
        int forwards_before;
        int history_forwards_before;
        int writes_before;
        int last_writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '{default: 32'h3f80_0000};
        row0_address = `GEMM_ACC_MEM_ADDR_WIDTH'(176 * ACC_ROW_BYTES);
        row1_address = `GEMM_ACC_MEM_ADDR_WIDTH'(177 * ACC_ROW_BYTES);

        if (scoreboard_acc_bank(row0_address)
            == scoreboard_acc_bank(row1_address)) begin
            $error("M=2 seamless micro-K rows must use different ACC banks");
            test_failed = 1'b1;
            return;
        end
        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(row0_address, 2, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        writes_before = write_count;
        last_writes_before = last_write_count;

        // Two seamless micro-K commands: row0/row1 repeat at d=2 while the
        // other row occupies the intervening admission and writeback cycle.
        drive_packet(input_data, row0_address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b0);
        drive_packet(input_data, row1_address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        drive_packet(input_data, row0_address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b0);
        drive_packet(input_data, row1_address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("M=2 seamless micro-K d=2");

        if ((early_read_count - early_before) != 0
         || (nominal_read_count - nominal_before) != 2
         || (forward_count - forwards_before) != 0
         || (history_forward_count - history_forwards_before) != 2
         || (write_count - writes_before) != 4
         || (last_write_count - last_writes_before) != 2) begin
            $error("M=2 seamless micro-K event mismatch early=%0d nominal=%0d immediate=%0d history=%0d writes=%0d last_writes=%0d",
                   early_read_count - early_before,
                   nominal_read_count - nominal_before,
                   forward_count - forwards_before,
                   history_forward_count - history_forwards_before,
                   write_count - writes_before,
                   last_write_count - last_writes_before);
            test_failed = 1'b1;
        end
        // Each row starts at 1.0 and accumulates two unit dot products.
        check_memory(row0_address, 1, fp32_from_int(1 + 2 * `MXU_ROW));
        check_memory(row1_address, 1, fp32_from_int(1 + 2 * `MXU_ROW));
    endtask

    task automatic test_m3_seamless_micro_k_d3_raw();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_address;
        logic [FP32_WIDTH-1:0] expected_value;
        int early_before;
        int nominal_before;
        int forwards_before;
        int history_forwards_before;
        int raw_stalls_before;
        int writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '0;
        base_address = `GEMM_ACC_MEM_ADDR_WIDTH'(184 * ACC_ROW_BYTES);
        expected_value = fp32_from_int(2 * `MXU_ROW);

        if (scoreboard_acc_bank(base_address)
            != scoreboard_acc_bank(`GEMM_ACC_MEM_ADDR_WIDTH'(
                 base_address + 2 * ACC_ROW_BYTES))) begin
            $error("M=3 seamless micro-K rows 0/2 must alias one ACC bank");
            test_failed = 1'b1;
            return;
        end

        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(base_address, 3, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        raw_stalls_before = d3_raw_stall_count;
        writes_before = write_count;

        // This is the MXU16 M=3, K-tail command shape: the first micro-K
        // loads rows 0/1/2 and the next accumulates the same rows without a
        // bubble.  For row2, the d=2 row0 aliases its bank while the exact
        // row2 producer is at d=3; the read must remain nominal.
        for (int row = 0; row < 3; ++row) begin
            drive_packet(input_data,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(
                           base_address + row * ACC_ROW_BYTES),
                         1'b1, `QDIR_ROW, 1'b0, 1'b0, 1'b0, row == 2);
        end
        for (int row = 0; row < 3; ++row) begin
            drive_packet(input_data,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(
                           base_address + row * ACC_ROW_BYTES),
                         1'b0, `QDIR_ROW, 1'b0, 1'b0, 1'b0, row == 2);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("M=3 seamless micro-K d=3 RAW");

        if ((early_read_count - early_before) != 0
         || (nominal_read_count - nominal_before) != 3
         || (forward_count - forwards_before) != 0
         || (history_forward_count - history_forwards_before) != 0
         || (d3_raw_stall_count - raw_stalls_before) != 1
         || (write_count - writes_before) != 6) begin
            $error("M=3 seamless micro-K event mismatch early=%0d nominal=%0d immediate=%0d history=%0d d3_stalls=%0d writes=%0d",
                   early_read_count - early_before,
                   nominal_read_count - nominal_before,
                   forward_count - forwards_before,
                   history_forward_count - history_forwards_before,
                   d3_raw_stall_count - raw_stalls_before,
                   write_count - writes_before);
            test_failed = 1'b1;
        end
        check_memory(base_address, 3, expected_value);
        $display("M3_D3_RAW_STALL_PASSED | rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6");
    endtask

    task automatic test_m5_seamless_read_write_arbitration();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_address;
        logic [FP32_WIDTH-1:0] expected_value;
        int early_before;
        int nominal_before;
        int backpressure_before;
        int writes_before;
        int last_writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        initial_value = '0;
        base_address = `GEMM_ACC_MEM_ADDR_WIDTH'(200 * ACC_ROW_BYTES);
        expected_value = fp32_from_int(2 * `MXU_ROW);

        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(base_address, 5, initial_value);

        early_before = early_read_count;
        nominal_before = nominal_read_count;
        backpressure_before = acc_write_backpressure_count;
        writes_before = write_count;
        last_writes_before = last_write_count;

        // The fifth load row and the early read of accumulate row 2 share a
        // physical ACC bank but have different addresses.  The scheduled read
        // must win while the ordered result queue retains the load write.
        for (int row = 0; row < 5; ++row) begin
            drive_packet(input_data,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(
                           base_address + row * ACC_ROW_BYTES),
                         1'b1, `QDIR_ROW, 1'b0, 1'b0, 1'b0, row == 4);
        end
        for (int row = 0; row < 5; ++row) begin
            drive_packet(input_data,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(
                           base_address + row * ACC_ROW_BYTES),
                         1'b0, `QDIR_ROW, 1'b0, 1'b0, 1'b0, row == 4);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("M=5 seamless ACC read/write arbitration");

        if ((early_read_count - early_before)
              + (nominal_read_count - nominal_before) != 5
         || (acc_write_backpressure_count - backpressure_before) == 0
         || (write_count - writes_before) != 10
         || (last_write_count - last_writes_before) != 2) begin
            $error("M=5 ACC arbitration event mismatch early=%0d nominal=%0d write_stalls=%0d writes=%0d last_writes=%0d",
                   early_read_count - early_before,
                   nominal_read_count - nominal_before,
                   acc_write_backpressure_count - backpressure_before,
                   write_count - writes_before,
                   last_write_count - last_writes_before);
            test_failed = 1'b1;
        end
        check_memory(base_address, 5, expected_value);
        $display("M5_ACC_READ_WRITE_ARBITRATION_PASSED | rows=5 qdir=row write_stalls=%0d writes=10",
                 acc_write_backpressure_count - backpressure_before);
    endtask

    task automatic test_full_rate_load(input logic quant_dir);
        input_vector_t zero_input;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr;
        int writes_before;
        zero_input = '0;
        base_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
            (quant_dir == `QDIR_COL) ? 0 : 32 * ACC_ROW_BYTES);
        writes_before = write_count;
        for (int i = 0; i < NUM_TEST_PACKETS; ++i) begin
            drive_packet(zero_input,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(base_addr + i * ACC_ROW_BYTES),
                         1'b1, quant_dir, i[0], i[0], i[0],
                         i == NUM_TEST_PACKETS - 1);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        if ((write_count - writes_before) != NUM_TEST_PACKETS) begin
            $error("load write count mismatch expected=%0d actual=%0d",
                   NUM_TEST_PACKETS, write_count - writes_before);
            test_failed = 1'b1;
        end
        check_memory(base_addr, NUM_TEST_PACKETS, 32'h0000_0000);
    endtask

    task automatic test_accumulate_scheduler();
        input_vector_t zero_input;
        psum_vector_t initial_value;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] writer_addr;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] nominal_addr;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] early_addr;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] expected_addr;
        logic [1:0] nominal_bank;
        logic [1:0] early_bank;
        int early_before;
        int nominal_before;
        int coincident_before;
        int forwards_before;
        int history_forwards_before;
        int early_holds_before;
        int writes_before;
        int last_writes_before;
        int launch_index;
        int directed_write_index;
        int last_launch_cycle;
        int observe_timeout;
        bit coincident_seen;
        bit early_hold_seen;
        zero_input = '0;
        initial_value = '{default: 32'h3f80_0000};
        base_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(64 * ACC_ROW_BYTES);
        writer_addr = base_addr;
        nominal_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
            base_addr
          + `GEMM_ACC_MEM_ADDR_WIDTH'(ACC_ROW_BYTES));
        early_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
            base_addr
          + `GEMM_ACC_MEM_ADDR_WIDTH'(
                u_dut.u_compute_core.K_LOOKBACK * ACC_ROW_BYTES));
        nominal_bank = scoreboard_acc_bank(nominal_addr);
        early_bank = scoreboard_acc_bank(early_addr);

        // The directed launch sequence relies on the current 1/1/0 ACC
        // read/add/post contract: W, N, E launch in consecutive cycles, N is
        // nominal on the opposite bank, and E sees W exactly K_LOOKBACK=2
        // launches earlier on its bank at a different address.
        if (u_dut.u_compute_core.K_LOOKBACK != 2
         || scoreboard_acc_bank(writer_addr) != early_bank
         || nominal_bank == early_bank
         || writer_addr == early_addr) begin
            $error("invalid directed scheduler address/latency setup K=%0d writer_bank=%0d nominal_bank=%0d early_bank=%0d writer=%h early=%h",
                   u_dut.u_compute_core.K_LOOKBACK, scoreboard_acc_bank(writer_addr),
                   nominal_bank, early_bank, writer_addr, early_addr);
            test_failed = 1'b1;
            return;
        end
        u_dut.initialize_acc_mem(base_addr, NUM_TEST_PACKETS, initial_value);
        early_before = early_read_count;
        nominal_before = nominal_read_count;
        coincident_before = coincident_read_count;
        forwards_before = forward_count;
        history_forwards_before = history_forward_count;
        early_holds_before = scoreboard_early_hold_count;
        writes_before = write_count;
        last_writes_before = last_write_count;
        launch_index = 0;
        directed_write_index = 0;
        last_launch_cycle = -1;
        observe_timeout = 0;
        coincident_seen = 1'b0;
        early_hold_seen = 1'b0;

        fork
            begin : drive_scheduler_stream
                // Keep one elastic pre-process branch selected so admission
                // order reaches int2fp_result_pop at one launch per cycle.
                for (int i = 0; i < NUM_TEST_PACKETS; ++i) begin
                    drive_packet(
                        zero_input,
                        `GEMM_ACC_MEM_ADDR_WIDTH'(
                            base_addr
                          + `GEMM_ACC_MEM_ADDR_WIDTH'(
                                i * ACC_ROW_BYTES)),
                        1'b0, `QDIR_COL, gemm_wreg_idx_t'(i[0]),
                        i[0], i[0],
                        i == NUM_TEST_PACKETS - 1);
                end
                end_stream();
            end
            begin : observe_scheduler_events
                while (((launch_index != NUM_TEST_PACKETS)
                      || (directed_write_index != NUM_TEST_PACKETS)
                      || !coincident_seen
                      || !early_hold_seen)
                    && (observe_timeout < 1000)) begin
                    @(posedge clk);
                    observe_timeout++;

                    if (u_dut.u_compute_core.int2fp_result_pop) begin
                        expected_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
                            base_addr
                          + `GEMM_ACC_MEM_ADDR_WIDTH'(
                                launch_index * ACC_ROW_BYTES));
                        if (launch_index >= NUM_TEST_PACKETS
                         || u_dut.u_compute_core.int2fp_result_data_out.ctrl.quant_dir
                              !== `QDIR_COL
                         || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_en
                              !== 1'b1
                         || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_en
                              !== 1'b1
                         || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr
                              !== expected_addr
                         || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_addr
                              !== expected_addr) begin
                            $error("directed scheduler INT2FP-result launch mismatch index=%0d expected_addr=%h actual_qdir=%0b actual_rd_en=%0b actual_wr_en=%0b actual_rd=%h actual_wr=%h",
                                   launch_index, expected_addr,
                                   u_dut.u_compute_core.int2fp_result_data_out.ctrl.quant_dir,
                                   u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_en,
                                   u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_en,
                                   u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr,
                                   u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_wr_addr);
                            test_failed = 1'b1;
                        end
                        if ((launch_index != 0)
                         && (cycle_count != last_launch_cycle + 1)) begin
                            $error("directed scheduler launch gap index=%0d previous_cycle=%0d current_cycle=%0d",
                                   launch_index, last_launch_cycle,
                                   cycle_count);
                            test_failed = 1'b1;
                        end

                        if (launch_index == 1) begin
                            if (u_dut.u_compute_core.post_launch_forward
                             || u_dut.u_compute_core.post_launch_history_forward
                             || u_dut.u_compute_core.post_launch_early) begin
                                $error("directed nominal launch was misclassified immediate=%0b history=%0b early=%0b",
                                       u_dut.u_compute_core.post_launch_forward,
                                       u_dut.u_compute_core.post_launch_history_forward,
                                       u_dut.u_compute_core.post_launch_early);
                                test_failed = 1'b1;
                            end
                        end
                        if (launch_index == u_dut.u_compute_core.K_LOOKBACK) begin
                            if (!u_dut.u_compute_core.ctrl_pipe[
                                    u_dut.u_compute_core.MERGER_CTRL_IDX
                                  + u_dut.u_compute_core.K_LOOKBACK - 1].valid
                             || !u_dut.u_compute_core.ctrl_pipe[
                                    u_dut.u_compute_core.MERGER_CTRL_IDX
                                  + u_dut.u_compute_core.K_LOOKBACK - 1].acc_wr_en
                             || u_dut.u_compute_core.ctrl_pipe[
                                    u_dut.u_compute_core.MERGER_CTRL_IDX
                                  + u_dut.u_compute_core.K_LOOKBACK - 1].acc_wr_addr
                                  !== writer_addr
                             || u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr
                                  !== early_addr
                             || u_dut.u_compute_core.post_launch_forward
                             || u_dut.u_compute_core.post_launch_history_forward
                             || !u_dut.u_compute_core.post_launch_early) begin
                                $error("directed early launch classification mismatch writer=%h expected_writer=%h read=%h expected_read=%h immediate=%0b history=%0b early=%0b",
                                       u_dut.u_compute_core.ctrl_pipe[
                                           u_dut.u_compute_core.MERGER_CTRL_IDX
                                         + u_dut.u_compute_core.K_LOOKBACK - 1].acc_wr_addr,
                                       writer_addr,
                                       u_dut.u_compute_core.int2fp_result_data_out.ctrl.acc_rd_addr,
                                       early_addr,
                                       u_dut.u_compute_core.post_launch_forward,
                                       u_dut.u_compute_core.post_launch_history_forward,
                                       u_dut.u_compute_core.post_launch_early);
                                test_failed = 1'b1;
                            end
                        end
                        last_launch_cycle = cycle_count;
                        launch_index++;
                    end

                    if (u_dut.nominal_read_req[nominal_bank]
                     && u_dut.early_read_req[early_bank]) begin
                        if (u_dut.nominal_read_req
                              !== (4'b0001 << nominal_bank)
                         || u_dut.early_read_req
                              !== (4'b0001 << early_bank)
                         || u_dut.read_req_addr[nominal_bank]
                              !== nominal_addr
                         || u_dut.read_req_addr[early_bank]
                              !== early_addr) begin
                            $error("directed coincident read mismatch nominal_req=%b early_req=%b nominal_addr=%h early_addr=%h",
                                   u_dut.nominal_read_req,
                                   u_dut.early_read_req,
                                   u_dut.read_req_addr[nominal_bank],
                                   u_dut.read_req_addr[early_bank]);
                            test_failed = 1'b1;
                        end
                        coincident_seen = 1'b1;
                    end

                    if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].valid
                     && u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX].acc_rd_addr
                          == early_addr) begin
                        if (!u_dut.u_compute_core.early_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX]
                         || !u_dut.early_hold_valid[early_bank]
                         || u_dut.u_compute_core.selected_psum_data
                              !== u_dut.early_hold_data[early_bank]) begin
                            $error("directed early-hold source mismatch bank=%0d early_sideband=%0b hold_valid=%0b",
                                   early_bank,
                                   u_dut.u_compute_core.early_pipe[u_dut.u_compute_core.SCALER_CTRL_IDX],
                                   u_dut.early_hold_valid[early_bank]);
                            test_failed = 1'b1;
                        end
                        early_hold_seen = 1'b1;
                    end

                    if (u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].valid) begin
                        expected_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
                            base_addr
                          + `GEMM_ACC_MEM_ADDR_WIDTH'(
                                directed_write_index * ACC_ROW_BYTES));
                        if (directed_write_index >= NUM_TEST_PACKETS
                         || !u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].acc_wr_en
                         || !u_dut.acc_write_fire
                         || u_dut.u_compute_core.ctrl_pipe[u_dut.u_compute_core.WRITE_CTRL_IDX].acc_wr_addr
                              !== expected_addr) begin
                            $error("directed scheduler write order mismatch index=%0d expected_addr=%h actual_en=%0b actual_fire=%0b actual_addr=%h",
                                   directed_write_index, expected_addr,
                                   u_dut.u_compute_core.ctrl_pipe[
                                       u_dut.u_compute_core.WRITE_CTRL_IDX].acc_wr_en,
                                   u_dut.acc_write_fire,
                                   u_dut.u_compute_core.ctrl_pipe[
                                       u_dut.u_compute_core.WRITE_CTRL_IDX].acc_wr_addr);
                            test_failed = 1'b1;
                        end
                        directed_write_index++;
                    end
                end
                if (observe_timeout == 1000) begin
                    $error("timeout observing directed scheduler events launches=%0d writes=%0d coincident=%0b early_hold=%0b",
                           launch_index, directed_write_index,
                           coincident_seen, early_hold_seen);
                    test_failed = 1'b1;
                end
            end
        join

        wait_for_empty();
        check_scoreboard_empty("same-QDIR full-rate ACC scheduler");

        if ((early_read_count - early_before)
            != NUM_TEST_PACKETS - u_dut.u_compute_core.K_LOOKBACK) begin
            $error("one-cycle-early read count mismatch expected=%0d actual=%0d",
                   NUM_TEST_PACKETS - u_dut.u_compute_core.K_LOOKBACK,
                   early_read_count - early_before);
            test_failed = 1'b1;
        end
        if ((nominal_read_count - nominal_before) != u_dut.u_compute_core.K_LOOKBACK) begin
            $error("nominal read count mismatch expected=%0d actual=%0d",
                   u_dut.u_compute_core.K_LOOKBACK,
                   nominal_read_count - nominal_before);
            test_failed = 1'b1;
        end
        if ((coincident_read_count - coincident_before) != 1
         || !coincident_seen) begin
            $error("cross-bank coincident nominal/early read count mismatch expected=1 actual=%0d seen=%0b",
                   coincident_read_count - coincident_before,
                   coincident_seen);
            test_failed = 1'b1;
        end
        if ((scoreboard_early_hold_count - early_holds_before)
               != NUM_TEST_PACKETS - u_dut.u_compute_core.K_LOOKBACK
         || !early_hold_seen) begin
            $error("early-hold source coverage mismatch expected=%0d actual=%0d seen=%0b",
                   NUM_TEST_PACKETS - u_dut.u_compute_core.K_LOOKBACK,
                   scoreboard_early_hold_count - early_holds_before,
                   early_hold_seen);
            test_failed = 1'b1;
        end
        if ((forward_count - forwards_before) != 0
         || (history_forward_count - history_forwards_before) != 0) begin
            $error("directed different-address stream unexpectedly forwarded immediate=%0d history=%0d",
                   forward_count - forwards_before,
                   history_forward_count - history_forwards_before);
            test_failed = 1'b1;
        end
        if ((write_count - writes_before) != NUM_TEST_PACKETS
         || (last_write_count - last_writes_before) != 1) begin
            $error("directed scheduler final write mismatch expected_writes=%0d actual_writes=%0d expected_last=1 actual_last=%0d",
                   NUM_TEST_PACKETS, write_count - writes_before,
                   last_write_count - last_writes_before);
            test_failed = 1'b1;
        end
        check_memory(base_addr, NUM_TEST_PACKETS, 32'h3f80_0000);
    endtask

    task automatic test_bubbles_and_group_boundary();
        input_vector_t zero_input;
        psum_vector_t initial_value;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr;
        int writes_before;
        zero_input = '0;
        initial_value = '{default: 32'h4000_0000};
        base_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
            (1 << (`GEMM_ACC_MEM_BANK_ADDR_WIDTH + 1))
            - ACC_ROW_BYTES);
        u_dut.initialize_acc_mem(base_addr, 8, initial_value);
        writes_before = write_count;

        for (int i = 0; i < 8; ++i) begin
            drive_packet(zero_input,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(base_addr + i * ACC_ROW_BYTES),
                         1'b0, i[0] ? `QDIR_ROW : `QDIR_COL,
                         i[0], ~i[0], i[0], i == 7);
            if ((i == 1) || (i == 4))
                drive_bubble(i == 1 ? u_dut.u_compute_core.K_LOOKBACK : 1);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        if ((write_count - writes_before) != 8) begin
            $error("bubble test dropped or duplicated writes");
            test_failed = 1'b1;
        end
        check_memory(base_addr, 8, 32'h4000_0000);
    endtask

    task automatic test_constrained_random();
        input_vector_t zero_input;
        psum_vector_t initial_value;
        psum_vector_t actual_value;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        logic [FP32_WIDTH-1:0]
            expected_value [0:RANDOM_PACKET_COUNT-1];
        int unsigned random_state;
        int unsigned random_word;
        int bubble_count;
        int load_count;
        int accum_count;
        int qcol_count;
        int qrow_count;
        int disabled_write_count;
        int bubble_cycle_count;
        int expected_write_count;
        int writes_before;
        logic is_load;
        logic quant_dir;
        logic acc_wr_en;
        logic is_last;
        logic [1:0] wreg_seen;
        logic [1:0] sreg_seen;
        logic [1:0] zreg_seen;
        logic [1:0] group_seen;
        logic [3:0] bank_seen;

        zero_input = '0;
        initial_value = '{default: 32'h4000_0000};
        base_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(
            (1 << (`GEMM_ACC_MEM_BANK_ADDR_WIDTH + 1))
            - 15 * ACC_ROW_BYTES);
        u_dut.initialize_acc_mem(
            base_addr, RANDOM_PACKET_COUNT, initial_value);

        random_state = 32'h6d2b_79f5;
        load_count = 0;
        accum_count = 0;
        qcol_count = 0;
        qrow_count = 0;
        disabled_write_count = 0;
        bubble_cycle_count = 0;
        expected_write_count = 0;
        writes_before = write_count;
        wreg_seen = '0;
        sreg_seen = '0;
        zreg_seen = '0;
        group_seen = '0;
        bank_seen = '0;

        for (int i = 0; i < RANDOM_PACKET_COUNT; ++i) begin
            random_state = next_random(random_state);
            random_word = random_state;
            address = `GEMM_ACC_MEM_ADDR_WIDTH'(
                base_addr + i * ACC_ROW_BYTES);
            is_last = ((i + 1) % RANDOM_COMMAND_LENGTH) == 0;
            is_load = random_word[0];
            quant_dir = random_word[1] ? `QDIR_ROW : `QDIR_COL;
            acc_wr_en = is_last || (random_word[6:4] != 3'b000);
            bubble_count = (random_word[9:8] % 3);

            load_count += is_load;
            accum_count += !is_load;
            qcol_count += quant_dir == `QDIR_COL;
            qrow_count += quant_dir == `QDIR_ROW;
            disabled_write_count += !acc_wr_en;
            bubble_cycle_count += bubble_count;
            expected_write_count += acc_wr_en;
            wreg_seen[random_word[2]] = 1'b1;
            sreg_seen[random_word[3]] = 1'b1;
            zreg_seen[random_word[7]] = 1'b1;
            group_seen[address[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1]] = 1'b1;
            bank_seen[scoreboard_acc_bank(address)] = 1'b1;
            expected_value[i]
                = (acc_wr_en && is_load) ? 32'h0000_0000
                                         : 32'h4000_0000;

            drive_packet_ctrl(
                zero_input, address, is_load, !is_load, acc_wr_en,
                quant_dir, random_word[2], random_word[10], random_word[7],
                is_last && ((i / RANDOM_COMMAND_LENGTH) & 1), is_last);
            if (bubble_count != 0)
                drive_bubble(bubble_count);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("fixed-seed constrained-random stream");

        if ((write_count - writes_before) != expected_write_count) begin
            $error("random write count mismatch expected=%0d actual=%0d",
                   expected_write_count, write_count - writes_before);
            test_failed = 1'b1;
        end
        if ((load_count == 0) || (accum_count == 0)
         || (qcol_count == 0) || (qrow_count == 0)
         || (disabled_write_count == 0) || (bubble_cycle_count == 0)
         || (wreg_seen != 2'b11) || (sreg_seen != 2'b11)
         || (zreg_seen != 2'b11) || (group_seen != 2'b11)
         || (bank_seen != 4'b1111)) begin
            $error("random coverage gap load=%0d accum=%0d qcol=%0d qrow=%0d wr_disabled=%0d bubbles=%0d wreg=%b sreg=%b zreg=%b groups=%b banks=%b",
                   load_count, accum_count, qcol_count, qrow_count,
                   disabled_write_count, bubble_cycle_count, wreg_seen,
                   sreg_seen, zreg_seen, group_seen, bank_seen);
            test_failed = 1'b1;
        end

        for (int i = 0; i < RANDOM_PACKET_COUNT; ++i) begin
            address = `GEMM_ACC_MEM_ADDR_WIDTH'(
                base_addr + i * ACC_ROW_BYTES);
            u_dut.read_acc_mem(address, actual_value);
            for (int lane = 0; lane < `MXU_COL; ++lane) begin
                if (actual_value[lane] !== expected_value[i]) begin
                    $error("random ACC mismatch packet=%0d lane=%0d addr=%h expected=%h actual=%h",
                           i, lane, address, expected_value[i],
                           actual_value[lane]);
                    test_failed = 1'b1;
                end
            end
        end
    endtask

    task automatic test_reset_flush();
        input_vector_t zero_input;
        zero_input = '0;
        drive_packet(zero_input,
                     `GEMM_ACC_MEM_ADDR_WIDTH'(128 * ACC_ROW_BYTES),
                     1'b1, `QDIR_COL, 1'b0, 1'b0, 1'b0, 1'b1);
        end_stream();
        reset = 1'b1;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (u_dut.u_compute_core.WRITE_DLY + 3) @(posedge clk);
        if (u_dut.acc_write_fire
         || gemm_unit_v2_if.last_write
         || gemm_unit_v2_if.tagged_final_writeback) begin
            $error("ghost write after reset");
            test_failed = 1'b1;
        end
    endtask

    initial begin
        test_failed = 1'b0;
        last_write_count = 0;
        scoreboard_cycle = 0;
        scoreboard_admission_count = 0;
        scoreboard_retire_count = 0;
        scoreboard_write_count = 0;
        scoreboard_read_count = 0;
        scoreboard_coincident_read_count = 0;
        scoreboard_forward_count = 0;
        scoreboard_history_forward_count = 0;
        scoreboard_early_hold_count = 0;
        scoreboard_output_read_count = 0;
        scoreboard_output_response_count = 0;
        scoreboard_stalled_input_cycles = 0;
        reset = 1'b0;
        init_signals();
        apply_reset();
        clear_weight_bank(2'd0);
        clear_weight_bank(2'd1);
        test_parallel_qparam_ports();
        test_nonlast_qcol_consumer_metadata_overlap();
        test_resource_consumer_stages(1'b0, `QDIR_ROW, 0);
        test_resource_consumer_stages(1'b1, `QDIR_COL, 1);
        test_independent_resource_indices();
        test_group_aware_output_arbitration();

        test_nonzero_reference(`QDIR_COL, 1'b0,
            `GEMM_ACC_MEM_ADDR_WIDTH'(8 * ACC_ROW_BYTES));
        test_nonzero_reference(`QDIR_ROW, 1'b1,
            `GEMM_ACC_MEM_ADDR_WIDTH'(16 * ACC_ROW_BYTES));
        test_same_address_distance(1, 1'b0,
            `GEMM_ACC_MEM_ADDR_WIDTH'(136 * ACC_ROW_BYTES));
        test_same_address_distance(2, 1'b0,
            `GEMM_ACC_MEM_ADDR_WIDTH'(140 * ACC_ROW_BYTES));
        test_same_address_distance(3, 1'b0,
            `GEMM_ACC_MEM_ADDR_WIDTH'(144 * ACC_ROW_BYTES));
        test_same_address_distance(1, 1'b1,
            `GEMM_ACC_MEM_ADDR_WIDTH'(148 * ACC_ROW_BYTES));
        test_same_address_distance(2, 1'b1,
            `GEMM_ACC_MEM_ADDR_WIDTH'(152 * ACC_ROW_BYTES));
        test_same_address_distance(3, 1'b1,
            `GEMM_ACC_MEM_ADDR_WIDTH'(156 * ACC_ROW_BYTES));
        test_same_address_d1_chain();
        test_same_bank_different_address_d2();
        test_m2_seamless_micro_k_d2();
        test_m3_seamless_micro_k_d3_raw();
        test_m5_seamless_read_write_arbitration();
        test_full_rate_load(`QDIR_COL);
        test_full_rate_load(`QDIR_ROW);
        test_accumulate_scheduler();
        test_constrained_random();
        test_bubbles_and_group_boundary();
        test_reset_flush();
        check_scoreboard_empty("reset flush");

        if ((scoreboard_admission_count == 0)
         || (scoreboard_write_count == 0)
         || (scoreboard_read_count == 0)
         || (scoreboard_coincident_read_count == 0)
         || (scoreboard_forward_count == 0)
         || (scoreboard_history_forward_count == 0)
         || (scoreboard_early_hold_count == 0)
         || (scoreboard_output_read_count == 0)
         || (scoreboard_output_response_count == 0)
         || (scoreboard_stalled_input_cycles == 0)) begin
            $error("scoreboard coverage gap admissions=%0d retires=%0d writes=%0d reads=%0d coincident_reads=%0d immediate_forwards=%0d history_forwards=%0d early_holds=%0d output_reads=%0d output_responses=%0d stalled_input_cycles=%0d",
                   scoreboard_admission_count, scoreboard_retire_count,
                   scoreboard_write_count,
                   scoreboard_read_count,
                   scoreboard_coincident_read_count,
                   scoreboard_forward_count,
                   scoreboard_history_forward_count,
                   scoreboard_early_hold_count,
                   scoreboard_output_read_count,
                   scoreboard_output_response_count,
                   scoreboard_stalled_input_cycles);
            test_failed = 1'b1;
        end

        $display("GEMM_UNIT_V2_PHASE1_COUNTS admissions=%0d retires=%0d writes=%0d reads=%0d coincident_reads=%0d immediate_forwards=%0d history_forwards=%0d early_holds=%0d output_reads=%0d output_responses=%0d stalled_input_cycles=%0d",
                 scoreboard_admission_count, scoreboard_retire_count,
                 scoreboard_write_count, scoreboard_read_count,
                 scoreboard_coincident_read_count,
                 scoreboard_forward_count,
                 scoreboard_history_forward_count,
                 scoreboard_early_hold_count,
                 scoreboard_output_read_count,
                 scoreboard_output_response_count,
                 scoreboard_stalled_input_cycles);

        if (last_write_count != EXPECTED_LAST_WRITES) begin
            $error("last_write pulse count mismatch expected=%0d actual=%0d",
                   EXPECTED_LAST_WRITES, last_write_count);
            test_failed = 1'b1;
        end

        if (test_failed) begin
            $fatal(1, "VX_gemm_unit_v2 unittest FAILED");
        end else begin
            $display("VX_gemm_unit_v2 unittest PASSED");
        end
        $finish;
    end

endmodule

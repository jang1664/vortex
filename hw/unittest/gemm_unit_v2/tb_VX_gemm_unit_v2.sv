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
    localparam int EXPECTED_LAST_WRITES = 9 + RANDOM_COMMAND_COUNT;

    typedef logic [`MXU_ROW-1:0][`IFP_WIDTH-1:0] input_vector_t;
    typedef logic [`MXU_COL-1:0][FP32_WIDTH-1:0] psum_vector_t;

    typedef struct {
        longint unsigned due_cycle;
        logic acc_wr_en;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        logic [1:0] bank;
        logic last;
    } write_expect_t;

    typedef struct {
        longint unsigned due_cycle;
        logic is_early;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        logic [1:0] bank;
    } read_expect_t;

    typedef struct {
        longint unsigned admission_cycle;
        logic acc_wr_en;
        logic [1:0] write_bank;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] write_address;
    } admission_history_t;

    typedef struct {
        longint unsigned due_cycle;
        logic forward;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_address;
    } forward_expect_t;

    logic clk;
    logic reset;
    int cycle_count;
    int input_count;
    int write_count;
    int early_read_count;
    int nominal_read_count;
    int coincident_read_count;
    int forward_count;
    int last_write_count;
    bit test_failed;
    longint unsigned scoreboard_cycle;
    int scoreboard_admission_count;
    int scoreboard_write_count;
    int scoreboard_read_count;
    int scoreboard_coincident_read_count;
    int scoreboard_forward_count;
    write_expect_t write_expect_q[$];
    read_expect_t read_expect_q[$];
    admission_history_t admission_history_q[$];
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
    ) sz_lmem_bus_if ();

    VX_mem_bus_if #(
        .DATA_SIZE (`GEMM_OUTPUT_DATA_SIZE),
        .TAG_WIDTH (1)
    ) o_lmem_bus_if ();

    VX_gemm_unit_v2_if gemm_unit_v2_if ();

    VX_gemm_unit_v2 #(
        .INSTANCE_ID ("gemm_unit_v2_ut")
    ) u_dut (
        .clk             (clk),
        .reset           (reset),
        .i_lmem_bus_if   (i_lmem_bus_if),
        .w_lmem_bus_if   (w_lmem_bus_if),
        .sz_lmem_bus_if  (sz_lmem_bus_if),
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
        end else begin
            cycle_count <= cycle_count + 1;
            if (i_lmem_bus_if.req_valid) begin
                input_count <= input_count + 1;
                if (i_lmem_bus_if.req_ready !== 1'b1) begin
                    $error("input backpressure at cycle %0d", cycle_count);
                    test_failed <= 1'b1;
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
            if (u_dut.ctrl_pipe[u_dut.SCALER_CTRL_IDX].valid
             && u_dut.forward_pipe[u_dut.SCALER_CTRL_IDX])
                forward_count <= forward_count + 1;
            if (gemm_unit_v2_if.last_write)
                last_write_count <= last_write_count + 1;
        end
    end

    // Independent admission-based scoreboard.  All due cycles are measured at
    // the accepting posedge, which is also the SRAM request/write edge.
    always @(posedge clk) begin : admission_scoreboard
        write_expect_t write_expect;
        read_expect_t read_expect;
        admission_history_t history_entry;
        forward_expect_t forward_expect;
        logic [3:0] expected_write_en;
        logic [3:0] expected_early_read;
        logic [3:0] expected_nominal_read;
        logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0]
            expected_read_addr;
        logic [1:0] current_read_bank;
        logic schedule_early;
        logic schedule_forward;

        if (reset) begin
            scoreboard_cycle = 0;
            write_expect_q.delete();
            read_expect_q.delete();
            admission_history_q.delete();
            forward_expect_q.delete();
        end else begin
            expected_write_en = '0;
            expected_early_read = '0;
            expected_nominal_read = '0;
            expected_read_addr = '0;

            // A queued control record must appear exactly WRITE_DLY cycles
            // after admission, including packets whose write enable is zero.
            while ((write_expect_q.size() != 0)
                && (write_expect_q[0].due_cycle < scoreboard_cycle)) begin
                $error("scoreboard missing ACC write/control due=%0d now=%0d",
                       write_expect_q[0].due_cycle, scoreboard_cycle);
                test_failed = 1'b1;
                void'(write_expect_q.pop_front());
            end
            if ((write_expect_q.size() != 0)
             && (write_expect_q[0].due_cycle == scoreboard_cycle)) begin
                write_expect = write_expect_q.pop_front();
                expected_write_en[write_expect.bank]
                    = write_expect.acc_wr_en;
                if (u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].valid !== 1'b1
                 || u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].acc_wr_en
                    !== write_expect.acc_wr_en
                 || u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].acc_wr_addr
                    !== write_expect.address) begin
                    $error("write control mismatch cycle=%0d exp_en=%0b exp_addr=%h actual_valid=%0b actual_en=%0b actual_addr=%h",
                           scoreboard_cycle, write_expect.acc_wr_en,
                           write_expect.address,
                           u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].valid,
                           u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].acc_wr_en,
                           u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].acc_wr_addr);
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
                if (gemm_unit_v2_if.last_write
                    !== (write_expect.acc_wr_en && write_expect.last)) begin
                    $error("last_write misaligned cycle=%0d expected=%0b actual=%0b",
                           scoreboard_cycle,
                           write_expect.acc_wr_en && write_expect.last,
                           gemm_unit_v2_if.last_write);
                    test_failed = 1'b1;
                end
                if (write_expect.acc_wr_en)
                    scoreboard_write_count = scoreboard_write_count + 1;
            end else begin
                if (u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].valid !== 1'b0
                 || u_dut.acc_write_fire !== 1'b0
                 || u_dut.acc_mem_wr_en !== '0
                 || gemm_unit_v2_if.last_write !== 1'b0) begin
                    $error("unexpected ACC write/control cycle=%0d valid=%0b fire=%0b banks=%b last=%0b",
                           scoreboard_cycle,
                           u_dut.ctrl_pipe[u_dut.WRITE_CTRL_IDX].valid,
                           u_dut.acc_write_fire, u_dut.acc_mem_wr_en,
                           gemm_unit_v2_if.last_write);
                    test_failed = 1'b1;
                end
            end

            // Forwarding is a fixed-latency sideband.  Every admitted packet
            // contributes one expectation, including non-forwarded packets.
            while ((forward_expect_q.size() != 0)
                && (forward_expect_q[0].due_cycle < scoreboard_cycle)) begin
                $error("scoreboard missing forwarding sideband due=%0d now=%0d",
                       forward_expect_q[0].due_cycle, scoreboard_cycle);
                test_failed = 1'b1;
                void'(forward_expect_q.pop_front());
            end
            if ((forward_expect_q.size() != 0)
             && (forward_expect_q[0].due_cycle == scoreboard_cycle)) begin
                forward_expect = forward_expect_q.pop_front();
                if (u_dut.ctrl_pipe[u_dut.SCALER_CTRL_IDX].valid !== 1'b1
                 || u_dut.ctrl_pipe[u_dut.SCALER_CTRL_IDX].acc_rd_addr
                    !== forward_expect.read_address
                 || u_dut.forward_pipe[u_dut.SCALER_CTRL_IDX]
                    !== forward_expect.forward) begin
                    $error("forward sideband mismatch cycle=%0d exp_forward=%0b exp_addr=%h actual_valid=%0b actual_forward=%0b actual_addr=%h",
                           scoreboard_cycle, forward_expect.forward,
                           forward_expect.read_address,
                           u_dut.ctrl_pipe[u_dut.SCALER_CTRL_IDX].valid,
                           u_dut.forward_pipe[u_dut.SCALER_CTRL_IDX],
                           u_dut.ctrl_pipe[u_dut.SCALER_CTRL_IDX].acc_rd_addr);
                    test_failed = 1'b1;
                end
                if (forward_expect.forward)
                    scoreboard_forward_count
                        = scoreboard_forward_count + 1;
            end else if (u_dut.forward_pipe[u_dut.SCALER_CTRL_IDX] !== 1'b0) begin
                $error("unexpected forwarding sideband cycle=%0d",
                       scoreboard_cycle);
                test_failed = 1'b1;
            end

            // Multiple expected reads may share a cycle, but never a bank.
            // The queue is cycle ordered because early scheduling advances a
            // request by only one cycle.
            while ((read_expect_q.size() != 0)
                && (read_expect_q[0].due_cycle < scoreboard_cycle)) begin
                $error("scoreboard missing ACC read due=%0d now=%0d bank=%0d",
                       read_expect_q[0].due_cycle, scoreboard_cycle,
                       read_expect_q[0].bank);
                test_failed = 1'b1;
                void'(read_expect_q.pop_front());
            end
            while ((read_expect_q.size() != 0)
                && (read_expect_q[0].due_cycle == scoreboard_cycle)) begin
                read_expect = read_expect_q.pop_front();
                if (expected_early_read[read_expect.bank]
                 || expected_nominal_read[read_expect.bank]) begin
                    $error("scoreboard derived same-bank read collision cycle=%0d bank=%0d",
                           scoreboard_cycle, read_expect.bank);
                    test_failed = 1'b1;
                end
                if (read_expect.is_early)
                    expected_early_read[read_expect.bank] = 1'b1;
                else
                    expected_nominal_read[read_expect.bank] = 1'b1;
                expected_read_addr[read_expect.bank] = read_expect.address;
                scoreboard_read_count = scoreboard_read_count + 1;
            end
            if ((|expected_early_read) && (|expected_nominal_read))
                scoreboard_coincident_read_count
                    = scoreboard_coincident_read_count + 1;
            if (u_dut.early_read_req !== expected_early_read
             || u_dut.nominal_read_req !== expected_nominal_read) begin
                $error("ACC read schedule mismatch cycle=%0d exp_early=%b exp_nominal=%b actual_early=%b actual_nominal=%b",
                       scoreboard_cycle, expected_early_read,
                       expected_nominal_read, u_dut.early_read_req,
                       u_dut.nominal_read_req);
                test_failed = 1'b1;
            end
            for (int bank = 0; bank < 4; ++bank) begin
                if ((expected_early_read[bank]
                  || expected_nominal_read[bank])
                 && (u_dut.read_req_addr[bank]
                    !== expected_read_addr[bank])) begin
                    $error("ACC read address mismatch cycle=%0d bank=%0d expected=%h actual=%h",
                           scoreboard_cycle, bank,
                           expected_read_addr[bank],
                           u_dut.read_req_addr[bank]);
                    test_failed = 1'b1;
                end
            end

            if (i_lmem_bus_if.req_ready !== 1'b1) begin
                $error("scoreboard observed ready stall cycle=%0d valid=%0b",
                       scoreboard_cycle, i_lmem_bus_if.req_valid);
                test_failed = 1'b1;
            end
            if (i_lmem_bus_if.req_valid) begin
                if (gemm_unit_v2_if.packet_ctrl.valid !== 1'b1) begin
                    $error("scoreboard admission without packet control cycle=%0d",
                           scoreboard_cycle);
                    test_failed = 1'b1;
                end

                write_expect.due_cycle
                    = scoreboard_cycle + u_dut.WRITE_DLY;
                write_expect.acc_wr_en
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_en;
                write_expect.address
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
                write_expect.bank = scoreboard_acc_bank(
                    gemm_unit_v2_if.packet_ctrl.acc_wr_addr);
                write_expect.last = gemm_unit_v2_if.packet_ctrl.last;
                write_expect_q.push_back(write_expect);

                schedule_forward = 1'b0;
                foreach (admission_history_q[index]) begin
                    if (admission_history_q[index].admission_cycle + 1
                          == scoreboard_cycle) begin
                        schedule_forward
                            = gemm_unit_v2_if.packet_ctrl.acc_rd_en
                           && admission_history_q[index].acc_wr_en
                           && (admission_history_q[index].write_address
                              == gemm_unit_v2_if.packet_ctrl.acc_rd_addr);
                    end
                end
                forward_expect.due_cycle
                    = scoreboard_cycle + u_dut.L_PRE;
                forward_expect.forward = schedule_forward;
                forward_expect.read_address
                    = gemm_unit_v2_if.packet_ctrl.acc_rd_addr;
                forward_expect_q.push_back(forward_expect);

                if (gemm_unit_v2_if.packet_ctrl.acc_rd_en
                 && !schedule_forward) begin
                    current_read_bank = scoreboard_acc_bank(
                        gemm_unit_v2_if.packet_ctrl.acc_rd_addr);
                    schedule_early = 1'b0;
                    foreach (admission_history_q[index]) begin
                        if (admission_history_q[index].admission_cycle
                              + u_dut.K_LOOKBACK == scoreboard_cycle) begin
                            schedule_early
                                = admission_history_q[index].acc_wr_en
                               && (admission_history_q[index].write_bank
                                  == current_read_bank);
                        end
                    end
                    read_expect.due_cycle = scoreboard_cycle
                        + (schedule_early ? u_dut.EARLY_READ_DLY
                                          : u_dut.NOMINAL_READ_DLY);
                    read_expect.is_early = schedule_early;
                    read_expect.address
                        = gemm_unit_v2_if.packet_ctrl.acc_rd_addr;
                    read_expect.bank = current_read_bank;
                    read_expect_q.push_back(read_expect);
                end

                history_entry.admission_cycle = scoreboard_cycle;
                history_entry.acc_wr_en
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_en;
                history_entry.write_bank = scoreboard_acc_bank(
                    gemm_unit_v2_if.packet_ctrl.acc_wr_addr);
                history_entry.write_address
                    = gemm_unit_v2_if.packet_ctrl.acc_wr_addr;
                admission_history_q.push_back(history_entry);
                scoreboard_admission_count
                    = scoreboard_admission_count + 1;
            end

            while ((admission_history_q.size() != 0)
                && (admission_history_q[0].admission_cycle
                      + u_dut.K_LOOKBACK <= scoreboard_cycle)) begin
                void'(admission_history_q.pop_front());
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
        sz_lmem_bus_if.req_valid = 1'b0;
        sz_lmem_bus_if.req_data = '0;
        sz_lmem_bus_if.rsp_ready = 1'b1;
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

    task automatic clear_weight_bank(input logic bank);
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
        sz_lmem_bus_if.req_valid = 1'b1;
        sz_lmem_bus_if.req_data.rw = 1'b1;
        sz_lmem_bus_if.req_data.addr
            = bank * (`MXU_MAX_DIM * `SCALE_WIDTH / 8);
        sz_lmem_bus_if.req_data.data = value;
        sz_lmem_bus_if.req_data.byteen = '1;
        do @(posedge clk); while (!sz_lmem_bus_if.req_ready);
        @(negedge clk);
        sz_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic write_zero_reg(
        input logic bank,
        input logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] value
    );
        @(negedge clk);
        sz_lmem_bus_if.req_valid = 1'b1;
        sz_lmem_bus_if.req_data.rw = 1'b1;
        sz_lmem_bus_if.req_data.addr
            = 2 * (`MXU_MAX_DIM * `SCALE_WIDTH / 8)
            + bank * (`MXU_MAX_DIM * `ZP_WIDTH / 8);
        sz_lmem_bus_if.req_data.data = value;
        sz_lmem_bus_if.req_data.byteen = '1;
        do @(posedge clk); while (!sz_lmem_bus_if.req_ready);
        @(negedge clk);
        sz_lmem_bus_if.req_valid = 1'b0;
    endtask

    task automatic write_weight_matrix(
        input logic bank,
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

    task automatic drive_packet_ctrl(
        input input_vector_t data,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        input logic is_load,
        input logic acc_rd_en,
        input logic acc_wr_en,
        input logic quant_dir,
        input logic wreg_idx,
        input logic sreg_idx,
        input logic zreg_idx,
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
        gemm_unit_v2_if.packet_ctrl.is_load = is_load;
        gemm_unit_v2_if.packet_ctrl.last = last;
        @(posedge clk);
        if (i_lmem_bus_if.req_ready !== 1'b1) begin
            $error("packet was not accepted");
            test_failed = 1'b1;
        end
    endtask

    task automatic drive_packet(
        input input_vector_t data,
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address,
        input logic is_load,
        input logic quant_dir,
        input logic wreg_idx,
        input logic sreg_idx,
        input logic zreg_idx,
        input logic last
    );
        drive_packet_ctrl(data, address, is_load, !is_load, 1'b1,
                          quant_dir, wreg_idx, sreg_idx, zreg_idx, last);
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

    task automatic check_scoreboard_empty(input string context);
        @(negedge clk);
        if ((write_expect_q.size() != 0)
         || (read_expect_q.size() != 0)
         || (forward_expect_q.size() != 0)) begin
            $error("scoreboard not empty after %s: writes=%0d reads=%0d forwards=%0d",
                   context, write_expect_q.size(), read_expect_q.size(),
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
            ref_psum[n] = 32'h4200_0000;
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

    task automatic test_same_address_forwarding();
        input_vector_t input_data;
        psum_vector_t initial_value;
        logic [`MXU_ROW-1:0][`MXU_COL-1:0][`W_BIT_WIDTH-1:0]
            weight_data;
        logic [`MXU_MAX_DIM-1:0][`SCALE_WIDTH-1:0] scale_data;
        logic [`MXU_MAX_DIM-1:0][`ZP_WIDTH-1:0] zero_data;
        logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] address;
        int reads_before;
        int forwards_before;
        int writes_before;

        input_data = '{default: 16'h3c00};
        weight_data = '{default: `W_BIT_WIDTH'(1)};
        scale_data = '{default: 16'h3c00};
        zero_data = '0;
        address = `GEMM_ACC_MEM_ADDR_WIDTH'(24 * ACC_ROW_BYTES);
        initial_value = '{default: 32'h3f80_0000};

        write_scale_reg(1'b0, scale_data);
        write_zero_reg(1'b0, zero_data);
        write_weight_matrix(1'b0, weight_data);
        u_dut.initialize_acc_mem(address, 1, initial_value);

        reads_before = early_read_count + nominal_read_count;
        forwards_before = forward_count;
        writes_before = write_count;
        drive_packet(input_data, address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b0);
        drive_packet(input_data, address, 1'b0, `QDIR_COL,
                     1'b0, 1'b0, 1'b0, 1'b1);
        end_stream();
        wait_for_last_write();
        wait_for_empty();
        check_scoreboard_empty("same-address forwarding stream");

        if ((early_read_count + nominal_read_count - reads_before) != 1) begin
            $error("same-address forwarding issued extra ACC read expected=1 actual=%0d",
                   early_read_count + nominal_read_count - reads_before);
            test_failed = 1'b1;
        end
        if ((forward_count - forwards_before) != 1) begin
            $error("same-address forwarding count mismatch expected=1 actual=%0d",
                   forward_count - forwards_before);
            test_failed = 1'b1;
        end
        if ((write_count - writes_before) != 2) begin
            $error("same-address forwarding write count mismatch expected=2 actual=%0d",
                   write_count - writes_before);
            test_failed = 1'b1;
        end
        // Initial 1.0 plus two consecutive dot products of 32.0 = 65.0.
        check_memory(address, 1, 32'h4282_0000);
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
        int early_before;
        int nominal_before;
        int coincident_before;
        zero_input = '0;
        initial_value = '{default: 32'h3f80_0000};
        base_addr = `GEMM_ACC_MEM_ADDR_WIDTH'(64 * ACC_ROW_BYTES);
        u_dut.initialize_acc_mem(base_addr, NUM_TEST_PACKETS, initial_value);
        early_before = early_read_count;
        nominal_before = nominal_read_count;
        coincident_before = coincident_read_count;

        for (int i = 0; i < NUM_TEST_PACKETS; ++i) begin
            drive_packet(zero_input,
                         `GEMM_ACC_MEM_ADDR_WIDTH'(base_addr + i * ACC_ROW_BYTES),
                         1'b0, i[0] ? `QDIR_ROW : `QDIR_COL,
                         i[0], i[0], i[0],
                         i == NUM_TEST_PACKETS - 1);
        end
        end_stream();
        wait_for_last_write();
        wait_for_empty();

        if ((early_read_count - early_before) == 0) begin
            $error("one-cycle-early path was not exercised");
            test_failed = 1'b1;
        end
        if ((nominal_read_count - nominal_before) == 0) begin
            $error("nominal read path was not exercised");
            test_failed = 1'b1;
        end
        if ((coincident_read_count - coincident_before) == 0) begin
            $error("cross-bank coincident nominal/early reads were not exercised");
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
                drive_bubble(i == 1 ? u_dut.K_LOOKBACK : 1);
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
                quant_dir, random_word[2], random_word[3], random_word[7],
                is_last);
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
        repeat (u_dut.WRITE_DLY + 3) @(posedge clk);
        if (u_dut.acc_write_fire || gemm_unit_v2_if.last_write) begin
            $error("ghost write after reset");
            test_failed = 1'b1;
        end
    endtask

    initial begin
        test_failed = 1'b0;
        last_write_count = 0;
        scoreboard_cycle = 0;
        scoreboard_admission_count = 0;
        scoreboard_write_count = 0;
        scoreboard_read_count = 0;
        scoreboard_coincident_read_count = 0;
        scoreboard_forward_count = 0;
        reset = 1'b0;
        init_signals();
        apply_reset();
        clear_weight_bank(1'b0);
        clear_weight_bank(1'b1);

        test_nonzero_reference(`QDIR_COL, 1'b0,
            `GEMM_ACC_MEM_ADDR_WIDTH'(8 * ACC_ROW_BYTES));
        test_nonzero_reference(`QDIR_ROW, 1'b1,
            `GEMM_ACC_MEM_ADDR_WIDTH'(16 * ACC_ROW_BYTES));
        test_same_address_forwarding();
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
         || (scoreboard_forward_count == 0)) begin
            $error("scoreboard coverage gap admissions=%0d writes=%0d reads=%0d coincident_reads=%0d forwards=%0d",
                   scoreboard_admission_count, scoreboard_write_count,
                   scoreboard_read_count,
                   scoreboard_coincident_read_count,
                   scoreboard_forward_count);
            test_failed = 1'b1;
        end

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

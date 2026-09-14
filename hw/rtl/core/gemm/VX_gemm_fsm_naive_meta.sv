`include "VX_define.vh"

`ifdef GEMM_NAIVE
// Metadata-only producer. Macro order K -> M -> N; micro order N -> K.
// No execution dependency is polled here: all fences travel on real commands.
module VX_gemm_fsm_naive_meta import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire clk,
    input wire reset,
    VX_config_reg_if.slave cfg_reg_if,
    output wire invocation_valid_o,
    input wire invocation_ready_i,
    output wire [`JOB_MMIO_ENTRYID_W-1:0] invocation_entry_id_o,
    output wire cmd_valid_o,
    input wire cmd_ready_i,
    output gemm_unified_cmd_t cmd_o,
    output wire producer_done_o,
    input wire controller_done_i,
    output wire idle_o,
    output wire [31:0] job_geometry_o [9],
    // Producer closure only: NOT source-read completion or SRC_FREE.
    output wire source_closed_valid_o,
    output wire source_closed_buffer_o,
    output wire [31:0] source_closed_generation_o,
    output wire [31:0] source_closed_count_o
);
    localparam int MT = `GEMM_FSM_MT;
    localparam int KT = `GEMM_FSM_KT;
    localparam int NT = `GEMM_FSM_NT;
    localparam int MK = `GEMM_FSM_MXU_KT;
    localparam int MN = `GEMM_FSM_MXU_NT;
    localparam int MAX_MICROS = (KT / MK) * (NT / MN);
    localparam int MICRO_BITS = $clog2(MAX_MICROS + 1);
    localparam int QREG_BYTES = `MAX(`MXU_ROW, `MXU_COL) * 2;
    localparam logic [3:0] OP_LOAD=4'd1, OP_STORE=4'd2, OP_WEIGHT=4'd5,
                         OP_SCALE=4'd6, OP_INPUT=4'd7, OP_ZERO=4'd10;
    typedef enum logic [2:0] {
        S_IDLE, S_LOAD, S_WEIGHT, S_SCALE, S_ZERO, S_INPUT, S_STORE, S_DRAIN
    } state_t;
    typedef struct packed {
        logic [4:0][63:0] dram; // I, W, O, S, Z
        logic [3:0][1:0][63:0] source; // I, W, S, Z; two physical buffers
        logic [63:0] obuf, pbuf;
        logic [31:0] orig_m, orig_n, orig_k, qlog;
        logic [31:0] m, n, k, m_start, n_start;
        logic wtrans, qrow;
    } job_t;
    job_t job_q;
    assign job_geometry_o[0] = job_q.orig_m;
    assign job_geometry_o[1] = job_q.orig_n;
    assign job_geometry_o[2] = job_q.orig_k;
    // The DMA descriptor adapter expects log2(QBLK), as stored in config.
    assign job_geometry_o[3] = job_q.qlog;
    assign job_geometry_o[4] = job_q.m;
    assign job_geometry_o[5] = job_q.n;
    assign job_geometry_o[6] = job_q.k;
    assign job_geometry_o[7] = {31'd0,job_q.wtrans};
    assign job_geometry_o[8] = {31'd0,job_q.qrow};
    state_t state_q;
    logic [1:0] load_member_q;
    logic [31:0] tile_q, load_tile_q, ordinal_q, owner_q;
    logic [31:0] mt_q, nt_q, kt_q;
    logic [31:0] load_mt_q, load_nt_q, load_kt_q;
    logic [MICRO_BITS-1:0] kb_q, nb_q;
    wire [31:0] mdim = (job_q.m + MT - 1) >> $clog2(MT);
    wire [31:0] ndim = (job_q.n + NT - 1) >> $clog2(NT);
    wire [31:0] kdim = (job_q.k + KT - 1) >> $clog2(KT);
    wire [31:0] total_tiles = mdim * ndim * kdim;
    function automatic logic [31:0] lesser(input logic [31:0] a, b);
        return a < b ? a : b;
    endfunction
    function automatic logic [31:0] ceil_quant(input logic [31:0] value);
        return (value + (32'd1 << job_q.qlog) - 1) >> job_q.qlog;
    endfunction
    function automatic logic [63:0] config64(input int index);
        return {cfg_reg_if.regs[index+1][31:0], cfg_reg_if.regs[index][31:0]};
    endfunction
    function automatic gemm_wait_meta_t wait_meta(input int rid, input logic [31:0] target);
        gemm_wait_meta_t result;
        result.valid = 1'b1;
        result.reg_id = GEMM_SYNC_REG_ID_WIDTH'(rid);
        result.target = target;
        return result;
    endfunction
    function automatic gemm_notify_meta_t notify_meta(input int rid, input logic [31:0] value, input logic set_mode);
        gemm_notify_meta_t result;
        result.valid = 1'b1;
        result.reg_id = GEMM_SYNC_REG_ID_WIDTH'(rid);
        result.value = value;
        result.set_mode = set_mode;
        return result;
    endfunction
    function automatic logic [31:0] instruction(input logic [3:0] op, input logic [31:0] amount);
        return {amount[27:0], op};
    endfunction
    wire [31:0] rows = lesser(MT, job_q.m - mt_q * MT);
    wire [31:0] cols = lesser(NT, job_q.n - nt_q * NT);
    wire [31:0] kval = lesser(KT, job_q.k - kt_q * KT);
    wire [31:0] knum = kval / MK;
    wire [31:0] nnum = (cols + MN - 1) / MN;
    wire [31:0] k0 = 32'(kb_q) * MK;
    wire [31:0] n0 = 32'(nb_q) * MN;
    wire [31:0] valid_cols = lesser(MN, cols - n0);
    wire [31:0] work_seq = tile_q * MAX_MICROS + 32'(kb_q) * nnum + 32'(nb_q) + 1;
    wire source_bank = tile_q[0];
    wire register_bank = ordinal_q[0];
    wire [31:0] source_generation = (tile_q >> 1) + 1;
    wire [31:0] previous_consumes = ordinal_q >> 1;
    wire last_micro = (32'(kb_q) + 1 == knum) && (32'(nb_q) + 1 == nnum);
    wire last_k = kt_q * KT + k0 + MK >= job_q.k;
    wire last_macro_k = kt_q + 1 == kdim;
    wire terminal = last_micro && last_macro_k;
    wire [31:0] load_rows = lesser(MT, job_q.m - load_mt_q * MT);
    wire [31:0] load_cols = lesser(NT, job_q.n - load_nt_q * NT);
    wire [31:0] load_k = lesser(KT, job_q.k - load_kt_q * KT);
    wire [31:0] load_generation = (load_tile_q >> 1) + 1;
    wire load_bank = load_tile_q[0];
    wire [31:0] quant_offset = job_q.qrow
        ? k0 * ceil_quant(NT) * 2 + (n0 >> job_q.qlog) * 2
        : (k0 >> job_q.qlog) * NT * 2 + n0 * 2;
    wire command_fire = cmd_valid_o && cmd_ready_i;
    wire start_fire = invocation_valid_o && invocation_ready_i;
    wire tile_finished = command_fire && ((state_q == S_INPUT && last_micro && !last_macro_k)
                                        || state_q == S_STORE);
    assign idle_o = state_q == S_IDLE;
    assign invocation_valid_o = !reset && idle_o && cfg_reg_if.valid && cfg_reg_if.regs[0][0];
    assign invocation_entry_id_o = `JOB_MMIO_ENTRYID_W'(cfg_reg_if.entry_id);
    assign cfg_reg_if.ready = !reset && idle_o && invocation_ready_i;
    assign cmd_valid_o = !reset && (state_q != S_IDLE) && (state_q != S_DRAIN);
    assign producer_done_o = state_q == S_DRAIN;
    assign source_closed_valid_o = command_fire && state_q == S_INPUT && last_micro;
    assign source_closed_buffer_o = source_bank;
    assign source_closed_generation_o = source_generation;
    assign source_closed_count_o = knum * nnum;

    always_comb begin : make_command
        logic [63:0] address;
        logic [31:0] amount, row0, col0, segment_bytes, segments;
        int install_rid, consume_rid;
        cmd_o = '0;
        address = '0;
        amount = '0;
        row0 = '0;
        col0 = '0;
        segment_bytes = '0;
        segments = '0;
        install_rid = 0;
        consume_rid = 0;
        cmd_o.work_seq = work_seq;
        cmd_o.naive_source_buffer = source_bank;
        cmd_o.naive_source_generation = source_generation;
        if (state_q == S_LOAD) begin
            cmd_o.naive_source_buffer = load_bank;
            cmd_o.naive_source_generation = load_generation;
            cmd_o.work_seq = load_tile_q * MAX_MICROS + 1;
            cmd_o.rd = NUM_REGS_BITS'(load_member_q);
            cmd_o.flags = {load_generation[6:0], load_bank};
            cmd_o.rs1_data = job_q.source[load_member_q][load_bank];
            if (load_tile_q >= 2)
                cmd_o.waits[0] = wait_meta(load_bank ? GEMM_RID_SRC_FREE1 : GEMM_RID_SRC_FREE0,
                                          load_generation - 1);
            unique case (load_member_q)
                0: begin
                    address = job_q.dram[0] + (64'(job_q.m_start + load_mt_q * MT) * job_q.orig_k
                                              + 64'(load_kt_q * KT)) * 2;
                    amount = load_rows * load_k * 2;
                    cmd_o.rs1 = NUM_REGS_BITS'(load_mt_q);
                    cmd_o.rs2 = NUM_REGS_BITS'(load_kt_q);
                end
                1: begin
                    if (job_q.wtrans)
                        address = job_q.dram[1] + 64'(job_q.n_start + load_nt_q * NT)
                                  * ((64'(job_q.orig_k) + 1) >> 1) + 64'(load_kt_q * (KT/2));
                    else
                        address = job_q.dram[1] + 64'(load_kt_q * KT)
                                  * ((64'(job_q.orig_n) + 1) >> 1) + 64'((job_q.n_start + load_nt_q * NT) >> 1);
                    amount = job_q.wtrans ? load_cols * ((load_k + 1) >> 1)
                                          : load_k * ((load_cols + 1) >> 1);
                    cmd_o.rs1 = NUM_REGS_BITS'(load_kt_q);
                    cmd_o.rs2 = NUM_REGS_BITS'(load_nt_q);
                end
                2, 3: begin
                    row0 = job_q.qrow ? load_kt_q * KT : (load_kt_q * KT) >> job_q.qlog;
                    col0 = job_q.qrow ? (job_q.n_start + load_nt_q * NT) >> job_q.qlog
                                     : job_q.n_start + load_nt_q * NT;
                    address = job_q.dram[load_member_q + 1] + (64'(row0)
                              * (job_q.qrow ? ceil_quant(job_q.orig_n) : job_q.orig_n) + 64'(col0)) * 2;
                    amount = job_q.qrow ? load_k * ceil_quant(load_cols) * 2
                                        : ceil_quant(load_k) * load_cols * 2;
                    cmd_o.groups_eff = job_q.qrow ? load_k : ceil_quant(load_k);
                    cmd_o.rs2 = NUM_REGS_BITS'(load_nt_q);
                end
                default:;
            endcase
            cmd_o.rs2_data = address;
            cmd_o.instr = instruction(OP_LOAD, amount);
        end else if (state_q == S_STORE) begin
            cmd_o.instr = instruction(OP_STORE, rows * cols * 2);
            cmd_o.rd = NUM_REGS_BITS'(4);
            cmd_o.rs1 = NUM_REGS_BITS'(mt_q);
            cmd_o.rs2 = NUM_REGS_BITS'(nt_q);
            cmd_o.rs1_data = job_q.dram[2] + (64'(job_q.m_start + mt_q * MT) * job_q.orig_n
                                            + 64'(job_q.n_start + nt_q * NT)) * 2;
            cmd_o.rs2_data = job_q.obuf;
            cmd_o.waits[0] = wait_meta(GEMM_RID_G1, owner_q);
            cmd_o.notify = notify_meta(GEMM_RID_O, 1, 1'b0);
        end else if ((state_q == S_WEIGHT) || (state_q == S_SCALE)
                  || (state_q == S_ZERO) || (state_q == S_INPUT)) begin
            cmd_o.waits[0] = wait_meta(source_bank ? GEMM_RID_T1 : GEMM_RID_T0, source_generation);
            cmd_o.prepare.valid = 1'b1;
            cmd_o.prepare.mode = GEMM_PREPARE_SOURCE_READ;
            cmd_o.prepare.max_beats = (state_q == S_INPUT || state_q == S_WEIGHT) ? 8'd16 : 8'd8;
            cmd_o.prepare.waits[0] = cmd_o.waits[0];
            unique case (state_q)
                S_WEIGHT: begin
                    install_rid = register_bank ? GEMM_RID_W1 : GEMM_RID_W0;
                    consume_rid = register_bank ? GEMM_RID_W_CONSUME1 : GEMM_RID_W_CONSUME0;
                    cmd_o.instr = instruction(OP_WEIGHT, job_q.wtrans ? valid_cols * (MK/2) : MK * ((valid_cols + 1) >> 1));
                    cmd_o.rs1_data = 64'(register_bank);
                    cmd_o.rs2_data = job_q.source[1][source_bank]
                        + (job_q.wtrans ? 64'(n0) * (KT/2) + 64'(k0/2)
                                         : 64'(k0) * (NT/2) + 64'(n0/2));
                    cmd_o.flags[1:0] = {job_q.wtrans, register_bank};
                    cmd_o.bound = job_q.wtrans ? 16'(valid_cols) : 16'(MK);
                    cmd_o.stride = job_q.wtrans ? KT/2 : NT/2;
                    cmd_o.groups_eff = valid_cols;
                end
                S_SCALE, S_ZERO: begin
                    install_rid = (state_q == S_SCALE)
                        ? (register_bank ? GEMM_RID_SC1 : GEMM_RID_SC0)
                        : (register_bank ? GEMM_RID_ZP1 : GEMM_RID_ZP0);
                    consume_rid = (state_q == S_SCALE)
                        ? (register_bank ? GEMM_RID_SC_CONSUME1 : GEMM_RID_SC_CONSUME0)
                        : (register_bank ? GEMM_RID_ZP_CONSUME1 : GEMM_RID_ZP_CONSUME0);
                    segments = job_q.qrow ? MK : ceil_quant(MK);
                    segment_bytes = job_q.qrow ? ceil_quant(valid_cols) * 2 : valid_cols * 2;
                    cmd_o.instr = instruction((state_q == S_SCALE) ? OP_SCALE : OP_ZERO,
                                              segments * segment_bytes);
                    cmd_o.rs1_data = 64'(((state_q == S_ZERO) ? 2 : 0) + 32'(register_bank)) * QREG_BYTES;
                    cmd_o.rs2_data = job_q.source[(state_q == S_SCALE) ? 2 : 3][source_bank] + 64'(quant_offset);
                    cmd_o.flags[2:1] = {job_q.qrow, register_bank};
                    cmd_o.bound = 16'(segments);
                    cmd_o.stride = job_q.qrow ? ceil_quant(NT) * 2 : NT * 2;
                    cmd_o.groups_eff = segment_bytes;
                end
                S_INPUT: begin
                    cmd_o.instr = instruction(OP_INPUT, rows);
`ifdef GEMM_NAIVE_USE_ACC_MEM
                    cmd_o.rs1_data = 64'(n0) * MT * 4;
`else
                    cmd_o.rs1_data = job_q.pbuf + 64'(n0) * MT * 4;
`endif
                    cmd_o.rs2_data = job_q.source[0][source_bank] + 64'(k0) * 2;
                    cmd_o.stride = MN * 4;
`ifdef GEMM_NAIVE_USE_ACC_MEM
                    cmd_o.naive_final_base = cmd_o.rs1_data;
                    cmd_o.naive_final_stride = cmd_o.stride;
`else
                    cmd_o.naive_final_base = job_q.obuf + 64'(n0) * 2;
                    cmd_o.naive_final_stride = NT * 2;
`endif
                    cmd_o.naive_terminal = terminal;
                    cmd_o.flags = {1'b0, job_q.qrow, terminal, (kt_q * KT + k0 != 0), last_k,
                                   register_bank, register_bank, register_bank};
                    cmd_o.bound = 16'(rows);
                    cmd_o.eff_mt = 21'(rows);
                    cmd_o.groups_eff = valid_cols;
                    cmd_o.input_admit_waits[0] = wait_meta(register_bank ? GEMM_RID_W1 : GEMM_RID_W0, work_seq);
                    cmd_o.input_admit_waits[1] = wait_meta(register_bank ? GEMM_RID_SC1 : GEMM_RID_SC0, work_seq);
                    cmd_o.input_admit_waits[2] = wait_meta(register_bank ? GEMM_RID_ZP1 : GEMM_RID_ZP0, work_seq);
                    cmd_o.input_admit_waits[3] = wait_meta(GEMM_RID_O, owner_q - 1);
                    cmd_o.notify = notify_meta(terminal ? GEMM_RID_G1 : GEMM_RID_G0, 1, 1'b0);
                end
                default:;
            endcase
            if (state_q != S_INPUT) begin
                cmd_o.notify = notify_meta(install_rid, work_seq, 1'b1);
                if (previous_consumes != 0)
                    cmd_o.writer_wait = wait_meta(consume_rid, previous_consumes);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state_q <= S_IDLE;
            job_q <= '0;
            tile_q <= 0; load_tile_q <= 0; ordinal_q <= 0; owner_q <= 1;
            mt_q <= 0; nt_q <= 0; kt_q <= 0;
            load_mt_q <= 0; load_nt_q <= 0; load_kt_q <= 0;
            load_member_q <= 0; kb_q <= 0; nb_q <= 0;
        end else if (start_fire) begin
            for (int resource = 0; resource < 5; ++resource)
                job_q.dram[resource] <= config64(1 + 2 * resource);
            for (int resource = 0; resource < 4; ++resource)
                for (int bank = 0; bank < 2; ++bank)
                    job_q.source[resource][bank] <= config64(11 + 4 * resource + 2 * bank);
            job_q.obuf <= config64(27); job_q.pbuf <= config64(40);
            job_q.orig_m <= cfg_reg_if.regs[29][31:0];
            job_q.orig_n <= cfg_reg_if.regs[30][31:0];
            job_q.orig_k <= cfg_reg_if.regs[31][31:0];
            job_q.qlog <= cfg_reg_if.regs[32][31:0];
            job_q.m <= cfg_reg_if.regs[33][31:0];
            job_q.n <= cfg_reg_if.regs[34][31:0];
            job_q.k <= cfg_reg_if.regs[35][31:0];
            job_q.m_start <= cfg_reg_if.regs[36][31:0];
            job_q.n_start <= cfg_reg_if.regs[37][31:0];
            job_q.wtrans <= cfg_reg_if.regs[38][0];
            job_q.qrow <= cfg_reg_if.regs[39][0];
            state_q <= S_LOAD;
            tile_q <= 0; load_tile_q <= 0; ordinal_q <= 0; owner_q <= 1;
            mt_q <= 0; nt_q <= 0; kt_q <= 0;
            load_mt_q <= 0; load_nt_q <= 0; load_kt_q <= 0;
            load_member_q <= 0; kb_q <= 0; nb_q <= 0;
        end else begin
            if (state_q == S_DRAIN && controller_done_i)
                state_q <= S_IDLE;
            if (command_fire) begin
                unique case (state_q)
                    S_LOAD: begin
                        load_member_q <= load_member_q + 1'b1;
                        if (load_member_q == 3) begin
                            load_tile_q <= load_tile_q + 1;
                            if (load_kt_q + 1 < kdim)
                                load_kt_q <= load_kt_q + 1;
                            else begin
                                load_kt_q <= 0;
                                if (load_mt_q + 1 < mdim)
                                    load_mt_q <= load_mt_q + 1;
                                else begin load_mt_q <= 0; load_nt_q <= load_nt_q + 1; end
                            end
                            state_q <= ((load_tile_q == 0) && (total_tiles > 1)) ? S_LOAD : S_WEIGHT;
                        end
                    end
                    S_WEIGHT: state_q <= S_SCALE;
                    S_SCALE: state_q <= S_ZERO;
                    S_ZERO: state_q <= S_INPUT;
                    S_INPUT: begin
                        ordinal_q <= ordinal_q + 1;
                        if (last_micro) begin
                            if (last_macro_k) state_q <= S_STORE;
                        end else begin
                            state_q <= S_WEIGHT;
                            if (32'(nb_q) + 1 < nnum) nb_q <= nb_q + 1'b1;
                            else begin nb_q <= 0; kb_q <= kb_q + 1'b1; end
                        end
                    end
                    default:;
                endcase
            end
            if (tile_finished) begin
                tile_q <= tile_q + 1;
                kb_q <= 0; nb_q <= 0;
                if (kt_q + 1 < kdim)
                    kt_q <= kt_q + 1;
                else begin
                    kt_q <= 0;
                    owner_q <= owner_q + 1;
                    if (mt_q + 1 < mdim) mt_q <= mt_q + 1;
                    else begin mt_q <= 0; nt_q <= nt_q + 1; end
                end
                if (tile_q + 1 == total_tiles) state_q <= S_DRAIN;
                else if (load_tile_q < total_tiles) state_q <= S_LOAD;
                else state_q <= S_WEIGHT;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        assert (MT == 128 && KT == 128 && NT == 128 && MK == MN && (MK == 16 || MK == 32))
            else $fatal(1, "%s: unsupported frozen tile geometry", INSTANCE_ID);
    end
    always_ff @(posedge clk) begin
        if (!reset && start_fire) begin
            assert (cfg_reg_if.regs[33][31:0] != 0 && cfg_reg_if.regs[34][31:0] != 0
                 && cfg_reg_if.regs[35][31:0] != 0 && cfg_reg_if.regs[35][31:0] % MK == 0
                 && cfg_reg_if.regs[32][31:0] == 5
                 && (cfg_reg_if.regs[37][31:0] & 31) == 0)
                else $fatal(1, "%s: unsupported dimensions/qblock/alignment", INSTANCE_ID);
        end
`ifdef DBG_TRACE_GEMM
        if (!reset && command_fire)
            $display("%s: META_FSM op=%0d work=%0d source=%0d/%0d", INSTANCE_ID,
                     cmd_o.instr[3:0], cmd_o.work_seq, cmd_o.naive_source_buffer, cmd_o.naive_source_generation);
`endif
    end
`endif
endmodule
`endif

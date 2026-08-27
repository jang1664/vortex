`include "VX_define.vh"

// Compatibility wrapper for the fixed-latency GEMM v2 implementation.  The
// backend-independent pipeline lives in VX_gemm_compute_core, while the
// physical four-bank accumulator and output-read endpoint remain owned here
// through VX_gemm_acc_internal.
module VX_gemm_unit_v2 import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input wire               clk,
    input wire               reset,

    VX_mem_bus_if.slave      i_lmem_bus_if,
    VX_mem_bus_if.slave      w_lmem_bus_if,
    VX_mem_bus_if.slave      sc_lmem_bus_if,
    VX_mem_bus_if.slave      zp_lmem_bus_if,
    VX_mem_bus_if.slave      o_lmem_bus_if,

    VX_gemm_unit_v2_if.slave gemm_unit_v2_if
`ifdef ENABLE_HW_DEBUG_GEMM
    ,output gemm_unit_debug_t debug
`endif
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t perf
`endif
);

    localparam FP32_WIDTH = 32;

    VX_gemm_acc_if #(
        .ADDRW (`GEMM_ACC_MEM_ADDR_WIDTH),
        .DATAW (`MXU_COL * FP32_WIDTH),
        .TAGW  (32)
    ) acc_if();

    logic [3:0] early_read_req;
    logic [3:0] nominal_read_req;
    logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_req_addr;
    logic [3:0] early_rsp_pending;
    logic [3:0] early_hold_valid;
    logic [3:0][`MXU_COL-1:0][31:0] early_hold_data;
    logic [3:0][`MXU_COL-1:0][31:0] acc_mem_out_data;
    logic [3:0][`MXU_COL-1:0][31:0] acc_mem_in_data;
    logic [3:0][`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] acc_mem_addr;
    logic [3:0] acc_mem_rd_en;
    logic [3:0] acc_mem_wr_en;
    logic [1:0] write_bank;
    logic [1:0] output_read_bank;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_read_addr;
    logic output_read_fire;
    logic output_read_valid;
    logic output_group_conflict;
    logic [3:0] compute_bank_read_req;
    logic [3:0] output_bank_read_req;
    logic [1:0] compute_group_busy;
    logic [7:0] compute_group_pending_count [0:1];
    logic [1:0] accum_bank;
    logic [1:0] output_read_bank_q;
    logic [$bits(o_lmem_bus_if.req_data.tag)-1:0] output_read_tag_q;

    // Compatibility probes retained at the wrapper boundary for existing
    // debug and verification users.
    wire input_fire = acc_if.txn_accept_valid;
    wire acc_write_fire = acc_if.wr_req_valid && acc_if.wr_req_ready;

`ifdef SIMULATION
    logic postprocess_ready_test;
    initial postprocess_ready_test = 1'b1;
    wire postprocess_ready = postprocess_ready_test;
`else
    wire postprocess_ready = 1'b1;
`endif

`ifdef ENABLE_HW_DEBUG_GEMM
    gemm_unit_debug_t core_debug;
`endif
`ifdef PERF_ENABLE
    gemm_unit_perf_t core_perf;
`endif

    VX_gemm_compute_core #(
        .INSTANCE_ID (INSTANCE_ID)
    ) u_compute_core (
        .clk               (clk),
        .reset             (reset),
        .input_bus_if      (i_lmem_bus_if),
        .weight_bus_if     (w_lmem_bus_if),
        .scale_bus_if      (sc_lmem_bus_if),
        .zero_bus_if       (zp_lmem_bus_if),
        .gemm_unit_if      (gemm_unit_v2_if),
        .acc_if            (acc_if),
        .postprocess_ready (postprocess_ready)
`ifdef ENABLE_HW_DEBUG_GEMM
        ,.debug            (core_debug)
`endif
`ifdef PERF_ENABLE
        ,.perf             (core_perf)
`endif
    );

    VX_gemm_acc_internal #(
        .INSTANCE_ID (INSTANCE_ID),
        .TAGW        (32)
    ) u_acc_internal (
        .clk                         (clk),
        .reset                       (reset),
        .acc_if                      (acc_if),
        .o_lmem_bus_if               (o_lmem_bus_if),
        .early_read_req              (early_read_req),
        .nominal_read_req            (nominal_read_req),
        .read_req_addr               (read_req_addr),
        .early_rsp_pending           (early_rsp_pending),
        .early_hold_valid            (early_hold_valid),
        .early_hold_data             (early_hold_data),
        .acc_mem_out_data            (acc_mem_out_data),
        .acc_mem_in_data             (acc_mem_in_data),
        .acc_mem_addr                (acc_mem_addr),
        .acc_mem_rd_en               (acc_mem_rd_en),
        .acc_mem_wr_en               (acc_mem_wr_en),
        .write_bank                  (write_bank),
        .output_read_bank            (output_read_bank),
        .output_read_addr            (output_read_addr),
        .output_read_fire            (output_read_fire),
        .output_read_valid           (output_read_valid),
        .output_group_conflict       (output_group_conflict),
        .compute_bank_read_req       (compute_bank_read_req),
        .output_bank_read_req        (output_bank_read_req),
        .compute_group_busy          (compute_group_busy),
        .compute_group_pending_count (compute_group_pending_count),
        .accum_bank                  (accum_bank),
        .output_read_bank_q          (output_read_bank_q),
        .output_read_tag_q           (output_read_tag_q)
    );

`ifdef ENABLE_HW_DEBUG_GEMM
    always_comb begin
        debug = core_debug;
        debug.rd_req = |(early_read_req | nominal_read_req);
        debug.rd_accept = debug.rd_req;
        debug.wr_req = |acc_mem_wr_en;
        debug.wr_fire = |acc_mem_wr_en;
        debug.rd_bank = accum_bank;
        debug.wr_bank = write_bank;
    end
`endif

`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] perf_accum_rd_accept_r;
    reg [PERF_CTR_BITS-1:0] perf_output_fire_r;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            perf_accum_rd_accept_r <= '0;
            perf_output_fire_r <= '0;
        end else begin
            if (|(early_read_req | nominal_read_req))
                perf_accum_rd_accept_r
                    <= perf_accum_rd_accept_r + PERF_CTR_BITS'(1);
            if (output_read_fire)
                perf_output_fire_r <= perf_output_fire_r + PERF_CTR_BITS'(1);
        end
    end

    always_comb begin
        perf = core_perf;
        perf.accum_rd_accept = perf_accum_rd_accept_r;
        perf.output_fire = perf_output_fire_r;
    end
`endif

    function automatic [1:0] get_acc_mem_idx(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        logic group;
        logic bank_offset;
        group = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0]
        get_acc_mem_bank_addr(
            input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
        );
        return {
            addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH:
                 `CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)+1],
            addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)-1:0]
        };
    endfunction

    function automatic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0]
        get_acc_mem_bank_depth_addr(
            input logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] addr
        );
        return addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:
                    `CLOG2(`GEMM_PSUM_DATA_SIZE)];
    endfunction

`ifdef SIMULATION
`ifndef SYNTHESIS
    task initialize_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] base_addr,
        input int size,
        input logic [`MXU_COL-1:0][FP32_WIDTH-1:0] init_value = '0
    );
        logic [`GEMM_ACC_MEM_BANK_ADDR_WIDTH-1:0] bank_addr;
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] depth_addr;
        logic [1:0] bank_idx;
        for (int i = 0; i < size; ++i) begin
            bank_idx = get_acc_mem_idx(
                base_addr + `GEMM_ACC_MEM_ADDR_WIDTH'(
                    i * `GEMM_PSUM_DATA_SIZE));
            bank_addr = get_acc_mem_bank_addr(
                base_addr + `GEMM_ACC_MEM_ADDR_WIDTH'(
                    i * `GEMM_PSUM_DATA_SIZE));
            depth_addr = get_acc_mem_bank_depth_addr(bank_addr);
            case (bank_idx)
                2'd0: u_acc_internal.gen_acc_mem[0].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd1: u_acc_internal.gen_acc_mem[1].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd2: u_acc_internal.gen_acc_mem[2].VX_sp_ram_instance.ram[depth_addr] = init_value;
                2'd3: u_acc_internal.gen_acc_mem[3].VX_sp_ram_instance.ram[depth_addr] = init_value;
                default: begin end
            endcase
        end
    endtask

    task read_acc_mem(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr,
        output logic [`MXU_COL-1:0][FP32_WIDTH-1:0] data
    );
        logic [`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] depth_addr;
        logic [1:0] bank_idx;
        bank_idx = get_acc_mem_idx(addr);
        depth_addr = get_acc_mem_bank_depth_addr(get_acc_mem_bank_addr(addr));
        case (bank_idx)
            2'd0: data = u_acc_internal.gen_acc_mem[0].VX_sp_ram_instance.ram[depth_addr];
            2'd1: data = u_acc_internal.gen_acc_mem[1].VX_sp_ram_instance.ram[depth_addr];
            2'd2: data = u_acc_internal.gen_acc_mem[2].VX_sp_ram_instance.ram[depth_addr];
            2'd3: data = u_acc_internal.gen_acc_mem[3].VX_sp_ram_instance.ram[depth_addr];
            default: data = '0;
        endcase
    endtask
`endif
`endif

`ifndef SYNTHESIS
    logic acc_txn_accept_valid_q;
    logic acc_txn_accept_rd_en_q;
    logic acc_txn_accept_wr_en_q;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_txn_accept_rd_addr_q;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] acc_txn_accept_wr_addr_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            acc_txn_accept_valid_q <= 1'b0;
            acc_txn_accept_rd_en_q <= 1'b0;
            acc_txn_accept_wr_en_q <= 1'b0;
            acc_txn_accept_rd_addr_q <= '0;
            acc_txn_accept_wr_addr_q <= '0;
        end else begin
            acc_txn_accept_valid_q <= acc_if.txn_accept_valid;
            acc_txn_accept_rd_en_q <= acc_if.txn_accept_rd_en;
            acc_txn_accept_wr_en_q <= acc_if.txn_accept_wr_en;
            acc_txn_accept_rd_addr_q <= acc_if.txn_accept_rd_addr;
            acc_txn_accept_wr_addr_q <= acc_if.txn_accept_wr_addr;
        end
    end

    always @(posedge clk) begin
        if (reset === 1'b0) begin
            if (acc_txn_accept_valid_q) begin
                if (acc_txn_accept_rd_en_q) begin
                    assert (compute_group_busy[
                        acc_txn_accept_rd_addr_q[
                            `GEMM_ACC_MEM_BANK_ADDR_WIDTH+1]])
                        else $fatal(1,
                            "GEMM v2 accepted ACC read group is not fenced");
                end
                if (acc_txn_accept_wr_en_q) begin
                    assert (compute_group_busy[
                        acc_txn_accept_wr_addr_q[
                            `GEMM_ACC_MEM_BANK_ADDR_WIDTH+1]])
                        else $fatal(1,
                            "GEMM v2 accepted ACC write group is not fenced");
                end
            end
            if (output_read_fire) begin
                assert (!compute_group_busy[output_read_bank[1]])
                    else $fatal(1,
                        "GEMM v2 output read escaped a busy ACC group");
            end
        end
    end
`endif

    `UNUSED_VAR (read_req_addr)
    `UNUSED_VAR (early_rsp_pending)
    `UNUSED_VAR (early_hold_valid)
    `UNUSED_VAR (early_hold_data)
    `UNUSED_VAR (acc_mem_out_data)
    `UNUSED_VAR (acc_mem_in_data)
    `UNUSED_VAR (acc_mem_addr)
    `UNUSED_VAR (acc_mem_rd_en)
    `UNUSED_VAR (acc_mem_wr_en)
    `UNUSED_VAR (output_read_addr)
    `UNUSED_VAR (output_read_valid)
    `UNUSED_VAR (output_group_conflict)
    `UNUSED_VAR (compute_bank_read_req)
    `UNUSED_VAR (output_bank_read_req)
    `UNUSED_VAR (output_read_bank_q)
    `UNUSED_VAR (output_read_tag_q)

endmodule

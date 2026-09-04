`include "VX_define.vh"

// Fixed-latency four-bank accumulator backend used by GEMM v2.  This module
// owns the physical bank/address decode, early-versus-nominal SRAM schedule,
// early response holding, and the external output-read path.
module VX_gemm_acc_internal import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter TAGW = 32
) (
    input wire               clk,
    input wire               reset,

    VX_gemm_acc_if.backend   acc_if,
    VX_mem_bus_if.slave      o_lmem_bus_if,

    output logic [3:0]       early_read_req,
    output logic [3:0]       nominal_read_req,
    output logic [3:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_req_addr,
    output logic [3:0]       early_rsp_pending,
    output logic [3:0]       early_hold_valid,
    output logic [3:0][`MXU_COL-1:0][31:0] early_hold_data,
    output logic [3:0][`MXU_COL-1:0][31:0] acc_mem_out_data,
    output logic [3:0][`MXU_COL-1:0][31:0] acc_mem_in_data,
    output logic [3:0][`GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH-1:0] acc_mem_addr,
    output logic [3:0]       acc_mem_rd_en,
    output logic [3:0]       acc_mem_wr_en,
    output logic [1:0]       write_bank,
    output logic [1:0]       output_read_bank,
    output logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] output_read_addr,
    output logic             output_read_fire,
    output logic             output_read_valid,
    output logic             output_group_conflict,
    output logic [3:0]       compute_bank_read_req,
    output logic [3:0]       output_bank_read_req,
    output logic [1:0]       compute_group_busy,
    output logic [7:0]       compute_group_pending_count [0:1],
    output logic [1:0]       accum_bank,
    output logic [1:0]       output_read_bank_q,
    output logic [$bits(o_lmem_bus_if.req_data.tag)-1:0] output_read_tag_q
);

    localparam FP32_WIDTH = 32;
    localparam FP16_WIDTH = 16;

    logic [1:0] nominal_valid_pipe;
    logic [1:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] nominal_addr_pipe;
    logic [2:0] read_rsp_valid_pipe;
    logic [2:0][TAGW-1:0] read_rsp_tag_pipe;
    logic [2:0][`GEMM_ACC_MEM_ADDR_WIDTH-1:0] read_rsp_addr_pipe;
    logic [2:0][1:0] read_rsp_bank_pipe;
    logic [2:0] read_rsp_early_pipe;
    logic [`MXU_COL-1:0][FP16_WIDTH-1:0] fp16_out_data;
    logic [`MXU_COL-1:0] fp16_out_valid;

    function automatic [1:0] get_acc_mem_idx(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        logic group;
        logic bank_offset;
        group = addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
        bank_offset = addr[`CLOG2(`GEMM_ACC_MEM_BANK_WIDTH)];
        return {group, bank_offset};
    endfunction

    function automatic logic get_acc_group(
        input logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] addr
    );
        return addr[`GEMM_ACC_MEM_BANK_ADDR_WIDTH+1];
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

    // The Phase-1 adapter is intentionally always-accept.  Later phases may
    // replace it with a variable-latency backend without changing the channel.
    assign acc_if.rd_req_ready = 1'b1;
    assign acc_if.wr_req_ready = 1'b1;
    assign acc_if.rd_req_early
        = acc_if.rd_req_valid
       && acc_if.rd_dependency_valid
       && (get_acc_mem_idx(acc_if.rd_dependency_addr)
        == get_acc_mem_idx(acc_if.rd_req_addr));

    always_comb begin
        early_read_req = '0;
        nominal_read_req = '0;
        read_req_addr = '0;

        if (read_rsp_valid_pipe[0] && read_rsp_early_pipe[0]) begin
            early_read_req[get_acc_mem_idx(read_rsp_addr_pipe[0])] = 1'b1;
            read_req_addr[get_acc_mem_idx(read_rsp_addr_pipe[0])]
                = read_rsp_addr_pipe[0];
        end

        if (nominal_valid_pipe[1]) begin
            nominal_read_req[get_acc_mem_idx(nominal_addr_pipe[1])] = 1'b1;
            read_req_addr[get_acc_mem_idx(nominal_addr_pipe[1])]
                = nominal_addr_pipe[1];
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            nominal_valid_pipe <= '0;
            nominal_addr_pipe <= '0;
            read_rsp_valid_pipe <= '0;
            read_rsp_tag_pipe <= '0;
            read_rsp_addr_pipe <= '0;
            read_rsp_bank_pipe <= '0;
            read_rsp_early_pipe <= '0;
            early_rsp_pending <= '0;
            early_hold_valid <= '0;
            early_hold_data <= '0;
        end else begin
            nominal_valid_pipe[0]
                <= acc_if.rd_req_valid && acc_if.rd_req_ready
                && !acc_if.rd_req_early;
            nominal_valid_pipe[1] <= nominal_valid_pipe[0];
            nominal_addr_pipe[0] <= acc_if.rd_req_addr;
            nominal_addr_pipe[1] <= nominal_addr_pipe[0];

            read_rsp_valid_pipe[0]
                <= acc_if.rd_req_valid && acc_if.rd_req_ready;
            read_rsp_valid_pipe[1] <= read_rsp_valid_pipe[0];
            read_rsp_valid_pipe[2] <= read_rsp_valid_pipe[1];
            read_rsp_tag_pipe[0] <= acc_if.rd_req_tag;
            read_rsp_tag_pipe[1] <= read_rsp_tag_pipe[0];
            read_rsp_tag_pipe[2] <= read_rsp_tag_pipe[1];
            read_rsp_addr_pipe[0] <= acc_if.rd_req_addr;
            read_rsp_addr_pipe[1] <= read_rsp_addr_pipe[0];
            read_rsp_addr_pipe[2] <= read_rsp_addr_pipe[1];
            read_rsp_bank_pipe[0] <= get_acc_mem_idx(acc_if.rd_req_addr);
            read_rsp_bank_pipe[1] <= read_rsp_bank_pipe[0];
            read_rsp_bank_pipe[2] <= read_rsp_bank_pipe[1];
            read_rsp_early_pipe[0] <= acc_if.rd_req_early;
            read_rsp_early_pipe[1] <= read_rsp_early_pipe[0];
            read_rsp_early_pipe[2] <= read_rsp_early_pipe[1];

            early_rsp_pending <= early_read_req;
            early_hold_valid <= early_rsp_pending;
            for (int i = 0; i < 4; ++i) begin
                if (early_rsp_pending[i])
                    early_hold_data[i] <= acc_mem_out_data[i];
            end
        end
    end

    assign acc_if.rd_rsp_valid = read_rsp_valid_pipe[2];
    assign acc_if.rd_rsp_tag = read_rsp_tag_pipe[2];
    assign acc_if.rd_rsp_data = read_rsp_early_pipe[2]
        ? early_hold_data[read_rsp_bank_pipe[2]]
        : acc_mem_out_data[read_rsp_bank_pipe[2]];
    assign accum_bank = read_rsp_bank_pipe[2];

    always_comb begin
        for (int i = 0; i < 2; ++i)
            compute_group_busy[i] = (compute_group_pending_count[i] != 0);
    end

    always_ff @(posedge clk or posedge reset) begin : pending_ownership
        if (reset) begin
            for (int i = 0; i < 2; ++i)
                compute_group_pending_count[i] <= '0;
        end else begin
            for (int i = 0; i < 2; ++i) begin
                case ({acc_if.txn_accept_valid
                       && ((acc_if.txn_accept_rd_en
                         && (get_acc_group(acc_if.txn_accept_rd_addr)
                             == logic'(i)))
                        || (acc_if.txn_accept_wr_en
                         && (get_acc_group(acc_if.txn_accept_wr_addr)
                             == logic'(i)))),
                       acc_if.txn_retire_valid
                       && ((acc_if.txn_retire_rd_en
                         && (get_acc_group(acc_if.txn_retire_rd_addr)
                             == logic'(i)))
                        || (acc_if.txn_retire_wr_en
                         && (get_acc_group(acc_if.txn_retire_wr_addr)
                             == logic'(i))))})
                    2'b10: compute_group_pending_count[i]
                        <= compute_group_pending_count[i] + 1'b1;
                    2'b01: compute_group_pending_count[i]
                        <= compute_group_pending_count[i] - 1'b1;
                    default: begin end
                endcase
            end
        end
    end

    assign write_bank = get_acc_mem_idx(acc_if.wr_req_addr);
    assign output_read_addr
        = `GEMM_ACC_MEM_ADDR_WIDTH'(
            o_lmem_bus_if.req_data.addr << `CLOG2(`GEMM_PSUM_DATA_SIZE));
    assign output_read_bank = get_acc_mem_idx(output_read_addr);
    assign output_group_conflict
        = o_lmem_bus_if.req_valid
       && compute_group_busy[output_read_bank[1]];
    assign o_lmem_bus_if.req_ready
        = !output_read_valid && !output_group_conflict;
    assign output_read_fire
        = o_lmem_bus_if.req_valid && o_lmem_bus_if.req_ready
       && !o_lmem_bus_if.req_data.rw;
    assign compute_bank_read_req = early_read_req | nominal_read_req;
    assign output_bank_read_req
        = output_read_fire ? (4'b0001 << output_read_bank) : '0;
    assign o_lmem_bus_if.rsp_valid = fp16_out_valid[0];
    assign o_lmem_bus_if.rsp_data.data = fp16_out_data;
    assign o_lmem_bus_if.rsp_data.tag = output_read_tag_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            output_read_valid <= 1'b0;
            output_read_bank_q <= '0;
            output_read_tag_q <= '0;
        end else begin
            if (output_read_fire) begin
                output_read_valid <= 1'b1;
                output_read_bank_q <= output_read_bank;
                output_read_tag_q <= o_lmem_bus_if.req_data.tag;
            end else if (fp16_out_valid[0] && o_lmem_bus_if.rsp_ready) begin
                output_read_valid <= 1'b0;
            end
        end
    end

    generate
        for (genvar i = 0; i < 4; ++i) begin : gen_acc_mem
            logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] selected_addr;

            assign acc_mem_wr_en[i]
                = acc_if.wr_req_valid && acc_if.wr_req_ready
               && (write_bank == i);
            assign acc_mem_rd_en[i] = early_read_req[i]
                                    || nominal_read_req[i]
                                    || (output_read_fire
                                     && (output_read_bank == i));
            assign selected_addr = acc_mem_wr_en[i]
                ? acc_if.wr_req_addr
                : (output_read_fire && (output_read_bank == i))
                ? output_read_addr : read_req_addr[i];
            assign acc_mem_addr[i] = get_acc_mem_bank_depth_addr(
                get_acc_mem_bank_addr(selected_addr));
            assign acc_mem_in_data[i] = acc_if.wr_req_data;

            VX_sp_ram #(
                .DATAW    (`MXU_COL * FP32_WIDTH),
                .SIZE     (`GEMM_ACC_MEM_DEPTH),
                .OUT_REG  (1),
                .USE_URAM (1),
                .RDW_MODE ("R")
            ) VX_sp_ram_instance (
                .clk   (clk),
                .reset (reset),
                .read  (acc_mem_rd_en[i]),
                .write (acc_mem_wr_en[i]),
                .wren  (1'b1),
                .addr  (acc_mem_addr[i]),
                .wdata (acc_mem_in_data[i]),
                .rdata (acc_mem_out_data[i])
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < `MXU_COL; ++i) begin : gen_fp32_to_fp16
            VX_f32_to_f16 u_f32_to_f16 (
                .clk_i    (clk),
                .resetn_i (~reset),
                .data_i   (acc_mem_out_data[output_read_bank_q][i]),
                .valid_i  (output_read_valid),
                .data_o   (fp16_out_data[i]),
                .valid_o  (fp16_out_valid[i])
            );
        end
    endgenerate

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (reset === 1'b0) begin
            assert (!(acc_if.rd_req_valid && !acc_if.rd_req_ready))
                else $fatal(1, "internal ACC unexpectedly stalled read request");
            assert (!(acc_if.wr_req_valid && !acc_if.wr_req_ready))
                else $fatal(1, "internal ACC unexpectedly stalled write request");
            if (acc_if.rd_rsp_valid && !acc_if.rd_rsp_ready) begin
                $fatal(1, "Phase-1 internal ACC response must be consumed immediately");
            end
            assert ((early_read_req & nominal_read_req) == '0)
                else $fatal(1, "internal ACC same-bank read/read collision");
            assert ((acc_mem_wr_en & acc_mem_rd_en) == '0)
                else $fatal(1, "internal ACC same-bank read/write collision");
            assert ((compute_bank_read_req & output_bank_read_req) == '0)
                else $fatal(1, "internal ACC compute/output same-bank collision");
            assert ((acc_mem_wr_en & output_bank_read_req) == '0)
                else $fatal(1, "internal ACC write/output same-bank collision");
            assert ((early_rsp_pending & early_hold_valid) == '0)
                else $fatal(1, "internal ACC early hold overwrite");
            for (int i = 0; i < 2; ++i) begin
                if (acc_if.txn_retire_valid
                 && ((acc_if.txn_retire_rd_en
                   && (get_acc_group(acc_if.txn_retire_rd_addr)
                       == logic'(i)))
                  || (acc_if.txn_retire_wr_en
                   && (get_acc_group(acc_if.txn_retire_wr_addr)
                       == logic'(i))))) begin
                    assert ((compute_group_pending_count[i] != 0)
                         || (acc_if.txn_accept_valid
                          && ((acc_if.txn_accept_rd_en
                            && (get_acc_group(acc_if.txn_accept_rd_addr)
                                == logic'(i)))
                           || (acc_if.txn_accept_wr_en
                            && (get_acc_group(acc_if.txn_accept_wr_addr)
                                == logic'(i))))))
                        else $fatal(1, "internal ACC group ownership underflow");
                end
            end
        end
    end
`endif

    `UNUSED_PARAM (INSTANCE_ID)
    `UNUSED_VAR (acc_if.wr_req_tag)
    `UNUSED_VAR (acc_if.wr_req_final_output)
    `UNUSED_VAR (acc_if.wr_req_last)

endmodule

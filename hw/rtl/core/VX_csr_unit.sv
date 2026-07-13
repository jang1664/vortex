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

module VX_csr_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter CORE_ID = 0,
    parameter NUM_LANES = 1
) (
    input wire                  clk,
    input wire                  reset,

    input base_dcrs_t           base_dcrs,

`ifdef PERF_ENABLE
    input sysmem_perf_t         sysmem_perf,
    input pipeline_perf_t       pipeline_perf,
    input accel_perf_t          accel_perf,
`endif

`ifdef EXT_F_ENABLE
    VX_fpu_csr_if.slave         fpu_csr_if [`NUM_FPU_BLOCKS],
`endif

    VX_commit_csr_if.slave      commit_csr_if,
    VX_sched_csr_if.slave       sched_csr_if,
    VX_execute_if.slave         execute_if,
    VX_result_if.master         result_if
);
    `UNUSED_SPARAM (INSTANCE_ID)
    localparam PID_BITS   = `CLOG2(`NUM_THREADS / NUM_LANES);
    localparam PID_WIDTH  = `UP(PID_BITS);
    localparam DATAW      = UUID_WIDTH + NW_WIDTH + NUM_LANES + PC_BITS + NUM_REGS_BITS + 1 + NUM_LANES * `XLEN + PID_WIDTH + 1 + 1;
`ifdef PERF_ENABLE
    localparam PERF_DATAW = DATAW + (8 * `XLEN) + 8 + 1;
`endif

    `UNUSED_VAR (execute_if.data.rs3_data)

    reg [NUM_LANES-1:0][`XLEN-1:0]  csr_read_data;
    reg  [`XLEN-1:0]                csr_write_data;
    wire [`XLEN-1:0]                csr_read_data_ro, csr_read_data_rw;
`ifdef PERF_ENABLE
    wire [8:1][`XLEN-1:0]           csr_read_data_mpm;
`endif
    wire [`XLEN-1:0]                csr_req_data;
    reg                             csr_rd_enable;
    wire                            csr_wr_enable;
    wire                            csr_req_ready;

    wire [`VX_CSR_ADDR_BITS-1:0] csr_addr = execute_if.data.op_args.csr.addr;
    wire [RV_REGS_BITS-1:0] csr_imm = execute_if.data.op_args.csr.imm;

    wire is_fpu_csr = (csr_addr <= `VX_CSR_FCSR);

    // wait for all pending instructions for current warp to complete
    assign sched_csr_if.alm_empty_wid = execute_if.data.wid;
    wire no_pending_instr = sched_csr_if.alm_empty || ~is_fpu_csr;

    wire csr_req_valid = execute_if.valid && no_pending_instr;
    wire csr_req_fire = csr_req_valid && csr_req_ready;
    assign execute_if.ready = csr_req_ready && no_pending_instr;

    wire [NUM_LANES-1:0][`XLEN-1:0] rs1_data;
    `UNUSED_VAR (rs1_data)
    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_rs1_data
        assign rs1_data[i] = execute_if.data.rs1_data[i];
    end

    wire csr_write_enable = (execute_if.data.op_type == INST_SFU_CSRRW);

    VX_csr_data #(
        .INSTANCE_ID (INSTANCE_ID),
        .CORE_ID     (CORE_ID)
    ) csr_data (
        .clk            (clk),
        .reset          (reset),

        .base_dcrs      (base_dcrs),

    `ifdef PERF_ENABLE
        .sysmem_perf    (sysmem_perf),
        .pipeline_perf  (pipeline_perf),
        .accel_perf     (accel_perf),
    `endif

        .commit_csr_if  (commit_csr_if),
        .cycles         (sched_csr_if.cycles),
        .active_warps   (sched_csr_if.active_warps),
        .thread_masks   (sched_csr_if.thread_masks),

    `ifdef EXT_F_ENABLE
        .fpu_csr_if     (fpu_csr_if),
    `endif

        .read_enable    (csr_req_fire && csr_rd_enable),
        .read_uuid      (execute_if.data.uuid),
        .read_wid       (execute_if.data.wid),
        .read_addr      (csr_addr),
        .read_data_ro   (csr_read_data_ro),
        .read_data_rw   (csr_read_data_rw),
    `ifdef PERF_ENABLE
        .read_data_mpm  (csr_read_data_mpm),
    `endif

        .write_enable   (csr_req_fire && csr_wr_enable),
        .write_uuid     (execute_if.data.uuid),
        .write_wid      (execute_if.data.wid),
        .write_addr     (csr_addr),
        .write_data     (csr_write_data)
    );

    // CSR read

    wire [NUM_LANES-1:0][`XLEN-1:0] wtid, gtid;

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_wtid
        if (PID_BITS != 0) begin : g_pid
            assign wtid[i] = `XLEN'(execute_if.data.pid * NUM_LANES + i);
        end else begin : g_no_pid
            assign wtid[i] = `XLEN'(i);
        end
    end

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_gtid
        assign gtid[i] = (`XLEN'(CORE_ID) << (NW_BITS + NT_BITS)) + (`XLEN'(execute_if.data.wid) << NT_BITS) + wtid[i];
    end

    always @(*) begin
        csr_rd_enable = 0;
        case (csr_addr)
        `VX_CSR_THREAD_ID : csr_read_data = wtid;
        `VX_CSR_MHARTID   : csr_read_data = gtid;
        default : begin
            csr_read_data = {NUM_LANES{csr_read_data_ro | csr_read_data_rw}};
            csr_rd_enable = 1;
        end
        endcase
    end

    // CSR write

    assign csr_req_data = execute_if.data.op_args.csr.use_imm ? `XLEN'(csr_imm) : rs1_data[0];
    assign csr_wr_enable = csr_write_enable || (| csr_req_data);

    always @(*) begin
        case (execute_if.data.op_type)
            INST_SFU_CSRRW: begin
                csr_write_data = csr_req_data;
            end
            INST_SFU_CSRRS: begin
                csr_write_data = csr_read_data_rw | csr_req_data;
            end
            //INST_SFU_CSRRC
            default: begin
                csr_write_data = csr_read_data_rw & ~csr_req_data;
            end
        endcase
    end

    // unlock the warp
    assign sched_csr_if.unlock_warp = csr_req_fire && execute_if.data.eop && is_fpu_csr;
    assign sched_csr_if.unlock_wid = execute_if.data.wid;

    wire rsp_valid_in;
    wire rsp_ready_in;
    wire [DATAW-1:0] rsp_data_in;

`ifdef PERF_ENABLE
    wire csr_is_mpm_addr = ((csr_addr >= `VX_CSR_MPM_USER)
                         && (csr_addr < (`VX_CSR_MPM_USER + 32)))
                        || ((csr_addr >= `VX_CSR_MPM_USER_H)
                         && (csr_addr < (`VX_CSR_MPM_USER_H + 32)));

    wire perf_stage_valid;
    wire [UUID_WIDTH-1:0] perf_uuid;
    wire [NW_WIDTH-1:0] perf_wid;
    wire [NUM_LANES-1:0] perf_tmask;
    wire [PC_BITS-1:0] perf_PC;
    wire [NUM_REGS_BITS-1:0] perf_rd;
    wire perf_wb;
    wire [NUM_LANES-1:0][`XLEN-1:0] perf_read_data;
    wire [8:1][`XLEN-1:0] perf_read_data_mpm;
    wire [7:0] perf_mpm_class;
    wire perf_is_mpm_addr;
    wire [PID_WIDTH-1:0] perf_pid;
    wire perf_sop;
    wire perf_eop;

    VX_elastic_buffer #(
        .DATAW (PERF_DATAW),
        .SIZE  (1)
    ) perf_decode_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (csr_req_valid),
        .ready_in  (csr_req_ready),
        .data_in   ({execute_if.data.uuid, execute_if.data.wid, execute_if.data.tmask,
                     execute_if.data.PC, execute_if.data.rd, execute_if.data.wb,
                     csr_read_data, csr_read_data_mpm, base_dcrs.mpm_class,
                     csr_is_mpm_addr, execute_if.data.pid, execute_if.data.sop,
                     execute_if.data.eop}),
        .data_out  ({perf_uuid, perf_wid, perf_tmask, perf_PC, perf_rd, perf_wb,
                     perf_read_data, perf_read_data_mpm, perf_mpm_class,
                     perf_is_mpm_addr, perf_pid, perf_sop, perf_eop}),
        .valid_out (perf_stage_valid),
        .ready_out (rsp_ready_in)
    );

    reg [`XLEN-1:0] perf_read_data_selected;
    always @(*) begin
        perf_read_data_selected = '0;
        case (perf_mpm_class)
            `VX_DCR_MPM_CLASS_CORE:           perf_read_data_selected = perf_read_data_mpm[1];
            `VX_DCR_MPM_CLASS_MEM:            perf_read_data_selected = perf_read_data_mpm[2];
            `VX_DCR_MPM_CLASS_ACCEL_MXU:      perf_read_data_selected = perf_read_data_mpm[3];
            `VX_DCR_MPM_CLASS_ACCEL_DMA:      perf_read_data_selected = perf_read_data_mpm[4];
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_IN:  perf_read_data_selected = perf_read_data_mpm[5];
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_WT:  perf_read_data_selected = perf_read_data_mpm[6];
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_SZ:  perf_read_data_selected = perf_read_data_mpm[7];
            `VX_DCR_MPM_CLASS_ACCEL_LDMA_OUT: perf_read_data_selected = perf_read_data_mpm[8];
            default:;
        endcase
    end

    wire [NUM_LANES-1:0][`XLEN-1:0] perf_rsp_read_data
        = perf_is_mpm_addr ? {NUM_LANES{perf_read_data_selected}} : perf_read_data;

    assign rsp_valid_in = perf_stage_valid;
    assign rsp_data_in = {perf_uuid, perf_wid, perf_tmask, perf_PC, perf_rd, perf_wb,
                          perf_rsp_read_data, perf_pid, perf_sop, perf_eop};
`else
    assign csr_req_ready = rsp_ready_in;
    assign rsp_valid_in = csr_req_valid;
    assign rsp_data_in = {execute_if.data.uuid, execute_if.data.wid, execute_if.data.tmask,
                          execute_if.data.PC, execute_if.data.rd, execute_if.data.wb,
                          csr_read_data, execute_if.data.pid, execute_if.data.sop,
                          execute_if.data.eop};
`endif

    VX_elastic_buffer #(
        .DATAW (DATAW),
        .SIZE  (2)
    ) rsp_buf (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (rsp_valid_in),
        .ready_in  (rsp_ready_in),
        .data_in   (rsp_data_in),
        .data_out  ({result_if.data.uuid,  result_if.data.wid,  result_if.data.tmask,  result_if.data.PC,  result_if.data.rd,  result_if.data.wb,  result_if.data.data, result_if.data.pid,  result_if.data.sop,  result_if.data.eop}),
        .valid_out (result_if.valid),
        .ready_out (result_if.ready)
    );

endmodule

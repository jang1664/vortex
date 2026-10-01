`include "VX_define.vh"
`ifdef GEMM_NAIVE
// Metadata controller child. The gather owns all operand payload and the four
// descriptors; this adapter retains only activation and completion ownership.
module VX_naive_weight_executor import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int TAG_WIDTH = GEMM_BASE_TAG_WIDTH,
    parameter int RESPONSE_SLOTS = `W_LMEM_DMA_CMD_BEATS
) (
    input wire clk,
    input wire reset,
    input gemm_unified_cmd_t cmd,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire prepare_valid,
    output wire prepare_ready,
    output wire done_valid,
    input wire done_ready,
    output wire [31:0] done_work_seq,
    input wire [31:0] sync_value [GEMM_NUM_SYNC_REGS],
    VX_mem_bus_if.master lane_bus_if [`GEMM_WEIGHT_DATA_SIZE/8],
    VX_mem_bus_if.master install_bus_if,
    output wire source_done_valid,
    output wire [31:0] source_done_work_seq,
    output wire quiescent
);
    VX_lmem_dma_ctrl_if transport();
    logic prepared_q, done_q;
    logic [31:0] prepared_id_q, done_id_q;
    logic [2:0] outstanding_q;
    wire head_valid, installed;
    wire [31:0] head_id, installed_id;
    gemm_wait_meta_t head_wait;
    logic writer_release;
    wire retire = done_q && done_ready;
    wire capacity = outstanding_q < 4 || retire;
    wire admit = transport.start && transport.idle;
    wire activate = cmd_valid && cmd_ready;
    assign prepare_ready = !prepared_q && capacity && transport.idle;
    assign cmd_ready = prepared_q ? cmd.work_seq == prepared_id_q
                                 : capacity && transport.idle;
    assign transport.start = !prepared_q && capacity && (prepare_valid || cmd_valid);
    assign done_valid = done_q;
    assign done_work_seq = done_id_q;
    assign quiescent = outstanding_q == 0 && !prepared_q && !done_q;

    always_comb begin
        writer_release = head_valid && !done_q
                      && !(prepared_q && head_id == prepared_id_q);
        if (head_wait.valid) begin
            if (head_wait.reg_id == GEMM_RID_W_CONSUME0
             || head_wait.reg_id == GEMM_RID_W_CONSUME1)
                writer_release &= sync_value[head_wait.reg_id] >= head_wait.target;
            else writer_release = 1'b0;
        end
    end
    // Full allocated microtiles are read even for an N tail. Padding stays in
    // the existing LMEM macro tile, and GEMM requires a complete W register.
    // Logical valid columns remain owned by the producer/Input/store metadata.
    assign transport.src_base_addr = cmd.rs2_data;
    assign transport.dst_base_addr = 64'(cmd.flags[1:0]) << $clog2(`GEMM_WEIGHT_DATA_SIZE);
    assign transport.src_strides[0] = cmd.stride;
    assign transport.src_strides[1] = 0;
    assign transport.src_strides[2] = 0;
    assign transport.dst_strides[0] = 0;
    assign transport.dst_strides[1] = 0;
    assign transport.dst_strides[2] = 0;
    assign transport.bounds[0] = `MXU_ROW;
    assign transport.bounds[1] = 1;
    assign transport.bounds[2] = 1;
    assign transport.seg_size = `MXU_COL/2;
    assign transport.reg_idx = cmd.work_seq;
    assign transport.reg_value = cmd.notify.value;
    assign transport.scheduler_work_seq = cmd.work_seq;
    assign transport.prepare = 0;
    assign transport.prepare_max_beats = 0;
    VX_lmem_weight_gather_dma #(.INSTANCE_ID(INSTANCE_ID),
        .NUM_LANES(`GEMM_WEIGHT_DATA_SIZE/8), .TAG_WIDTH(TAG_WIDTH),
        .RD_PREFETCH_DEPTH(RESPONSE_SLOTS), .CMD_FIFO_DEPTH(4),
        .NAIVE_METADATA(1)) gather (
        .clk(clk), .reset(reset), .ctrl_if(transport), .lmem_bus_if(lane_bus_if),
        .gemm_bus_if(install_bus_if), .writer_wait_i(cmd.writer_wait),
        .writer_release_i(writer_release), .writer_head_valid_o(head_valid),
        .writer_wait_o(head_wait), .writer_work_seq_o(head_id),
        .source_done_valid_o(source_done_valid), .source_done_work_seq_o(source_done_work_seq),
        .install_done_valid_o(installed), .install_done_work_seq_o(installed_id)
    );
    always_ff @(posedge clk) begin
        if (reset) begin
            prepared_q <= 0; prepared_id_q <= 0;
            done_q <= 0; done_id_q <= 0; outstanding_q <= 0;
        end else begin
            if (admit && !activate) begin
                prepared_q <= 1;
                prepared_id_q <= cmd.work_seq;
            end
            if (activate) prepared_q <= 0;
            if (retire) done_q <= 0;
            if (installed) begin
                done_q <= 1;
                done_id_q <= installed_id;
            end
            case ({admit,retire})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: outstanding_q <= outstanding_q - 1'b1;
                default: ;
            endcase
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (outstanding_q <= 4) else $fatal(1,"%s Weight ownership overflow",INSTANCE_ID);
            if (retire) assert (outstanding_q != 0)
                else $fatal(1,"%s Weight completion without owner",INSTANCE_ID);
            if (installed) assert (!done_q && !(prepared_q && head_id == prepared_id_q))
                else $fatal(1,"%s Weight completion overwrite/unactivated install",INSTANCE_ID);
            if (cmd_valid && prepared_q) assert (cmd.work_seq == prepared_id_q)
                else $fatal(1,"%s prepared Weight command changed",INSTANCE_ID);
            if (admit) begin
                assert (cmd.instr[3:0] == 4'd5 && cmd.work_seq != 0)
                    else $fatal(1,"%s invalid Weight command",INSTANCE_ID);
                assert (cmd.rs2_data[63:34] == 0)
                    else $fatal(1,"%s Weight source address overflow",INSTANCE_ID);
                assert (!cmd.writer_wait.valid || cmd.writer_wait.reg_id == GEMM_RID_W_CONSUME0
                    || cmd.writer_wait.reg_id == GEMM_RID_W_CONSUME1)
                    else $fatal(1,"%s invalid Weight writer RID",INSTANCE_ID);
            end
        end
    end
`endif
endmodule
`endif

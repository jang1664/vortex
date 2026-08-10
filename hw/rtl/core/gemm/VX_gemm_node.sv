/*
  VX_gemm_node

  Top-level GEMM node that integrates:
    - job frontend (MMIO register file + dispatch),
    - GEMM controller / GEMM unit,
    - VX_tmem_subsystem (tensor memory with DMA engine, banks, local DMAs).

  Dataflow summary
    - Load paths (i/w/scale/zero-point):
        HBM -> DMA engine -> TMEM banks -> local DMAs -> GEMM unit
    - Output path:
        GEMM unit -> local DMA -> TMEM banks -> DMA engine -> HBM
*/
`include "VX_define.vh"

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 6,
    parameter NUM_TMEM_BANKS = `NUM_DMA_CHANNELS,
    parameter int DMA_STORE_MAX_CHUNK_BEATS =
        `GEMM_DMA_STORE_MAX_CHUNK_BEATS
) (
    // Clock
    input wire              clk,
    input wire              reset,

    VX_lsu_mem_if.slave     mmio_if[N_MASTER],

    // DMA engine AXI ports (pass through to VX_tmem_subsystem -> HBM)
    AXI_BUS.Master          dma_axi_m [NUM_TMEM_BANKS]
`ifdef ENABLE_HW_DEBUG_GEMM
    ,output gemm_unit_debug_t gemm_unit_debug
`endif
`ifdef PERF_ENABLE
    ,output gemm_unit_perf_t  gemm_unit_perf
    ,output gemm_node_perf_t  gemm_node_perf
    ,output hbm_dma_perf_t    hbm_dma_perf
    ,output dma_perf_t        lmem_dma_input_perf
    ,output dma_perf_t        lmem_dma_weight_perf
    ,output dma_perf_t        lmem_dma_sz_perf
    ,output dma_perf_t        lmem_dma_output_perf
`endif
);

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------

    // Number of child nodes synchronized by gemm_ctrl.
    localparam N_NODE   = 6;

    // Use GEMM-specific base tag width so adapter split tags stay valid even
    // when LMEM_TAG_WIDTH is reduced in NDEBUG builds.
    localparam int I_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int W_GEMM_TAG_WIDTH  = GEMM_BASE_TAG_WIDTH;
    localparam int SZ_GEMM_TAG_WIDTH = GEMM_BASE_TAG_WIDTH;

    // DMA tile sizes
    // localparam int MT = `GEMM_FSM_MT;
    // localparam int NT = `GEMM_FSM_NT;
    // localparam int KT = `GEMM_FSM_KT;

    // MXU micro tile sizes
    localparam int MXU_KT = `MXU_ROW;
    localparam int MXU_NT = `MXU_COL;

    // localparam int ENTRYID_W  = `JOB_MMIO_ENTRYID_W;
    // localparam int OWNER_W    = `JOB_MMIO_OWNER_W;
    // localparam int GEN_W      = `JOB_MMIO_GEN_W;

    localparam int INPUT_NOTIFY_ON_WRITEBACK_FLAG = 4;
    localparam int OUTPUT_PROGRESS_REG_IDX = 43;

    // -------------------------------------------------------------------------
    // Data-path interfaces
    // -------------------------------------------------------------------------
    // GEMM-unit-facing buses (native GEMM widths)
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(I_GEMM_TAG_WIDTH)
    ) i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(W_GEMM_TAG_WIDTH)
    ) w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(SZ_GEMM_TAG_WIDTH)
    ) zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) o_gemm_bus_if ();

    // Intermediate buses from TMEM subsystem to address manipulation logic
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_INPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_i_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_w_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_sc_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_SCALE_ZERO_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_zp_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_o_gemm_bus_if ();

    // -------------------------------------------------------------------------
    // Control interfaces
    // -------------------------------------------------------------------------
    VX_gemm_unit_v2_if gemm_unit_v2_if ();

    typedef struct packed {
        logic                 active;
        logic                 ingress_complete;
        logic [`XLEN-1:0]     acc_base;
        logic [20:0]          packet_count;
        logic [20:0]          packet_index;
        logic                 is_accum;
        logic                 notify_on_writeback;
        logic                 quant_dir;
        logic                 wreg_use_idx;
        logic                 sreg_use_idx;
        logic                 zreg_use_idx;
    } input_cmd_context_t;

    input_cmd_context_t input_cmd_ctx_r;
    input_cmd_context_t input_cmd_ctx;
    VX_gemm_ctrl_if gemm_ctrl_if ();

    // LMEM DMA control interfaces (issued by gemm_ctrl)
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if scale_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if zero_point_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();
    VX_gemm_dma_ctrl_if gemm_dma_ctrl_if ();

    logic [7:0]  weight_cmd_flags_r;
    logic        weight_write_active_r;
    logic [63:0] weight_writes_remaining_r;
    logic        scale_write_active_r;
    logic [63:0] scale_writes_remaining_r;
    logic        zero_point_write_active_r;
    logic [63:0] zero_point_writes_remaining_r;
    logic        output_write_active_r;

    wire weight_dma_start = gemm_ctrl_if.weight_read_ctrl.start;
    wire scale_dma_start = gemm_ctrl_if.scale_read_ctrl.start;
    wire zero_point_dma_start = gemm_ctrl_if.zero_point_read_ctrl.start;
    wire [63:0] weight_command_bytes
        = 64'(gemm_ctrl_if.weight_read_ctrl.cmd.bound)
        * 64'(MXU_KT * (MXU_NT >> 1));
    wire [63:0] weight_command_writes
        = (weight_command_bytes + 64'(`GEMM_WEIGHT_DATA_SIZE) - 1)
        / 64'(`GEMM_WEIGHT_DATA_SIZE);
    wire [63:0] scale_command_bytes
        = 64'(gemm_ctrl_if.scale_read_ctrl.cmd.bound)
        * 64'(MXU_NT * 2);
    wire [63:0] scale_command_writes
        = (scale_command_bytes + 64'(`GEMM_SCALE_ZERO_DATA_SIZE) - 1)
        / 64'(`GEMM_SCALE_ZERO_DATA_SIZE);
    wire [63:0] zero_point_command_bytes
        = 64'(gemm_ctrl_if.zero_point_read_ctrl.cmd.bound)
        * 64'(MXU_NT * 2);
    wire [63:0] zero_point_command_writes
        = (zero_point_command_bytes + 64'(`GEMM_SCALE_ZERO_DATA_SIZE) - 1)
        / 64'(`GEMM_SCALE_ZERO_DATA_SIZE);
    wire weight_last_register_write
        = gemm_unit_v2_if.weight_register_write
       && ((weight_write_active_r
         && (weight_writes_remaining_r == 64'd1))
        || (weight_dma_start && (weight_command_writes == 64'd1)));
    wire scale_last_register_write
        = gemm_unit_v2_if.scale_register_write
       && ((scale_write_active_r
         && (scale_writes_remaining_r == 64'd1))
        || (scale_dma_start && (scale_command_writes == 64'd1)));
    wire zero_point_last_register_write
        = gemm_unit_v2_if.zero_point_register_write
       && ((zero_point_write_active_r
         && (zero_point_writes_remaining_r == 64'd1))
        || (zero_point_dma_start
         && (zero_point_command_writes == 64'd1)));
    // wire weight_wtrans      = weight_cmd_flags_r[1];

`ifndef SYNTHESIS
    logic [31:0] dbg_cyc_q;
    always_ff @(posedge clk) begin
        if (reset) dbg_cyc_q <= 32'd0;
        else       dbg_cyc_q <= dbg_cyc_q + 32'd1;
    end

    logic        dbg_weight_dma_start;
    logic [31:0] dbg_weight_dma_start_cyc_q;
    assign dbg_weight_dma_start = weight_dma_start;
    always_ff @(posedge clk) begin
        if (reset)                  dbg_weight_dma_start_cyc_q <= 32'd0;
        else if (weight_dma_start)  dbg_weight_dma_start_cyc_q <= dbg_cyc_q;
    end
`endif

    // Legacy sync wires are inert compatibility pins; executors publish only
    // architectural done events and the scheduler owns all sync updates.
    VX_gemm_sync_if gemm_sync_if[N_NODE] ();

    // Job frontend dispatch/done handshake.
    VX_config_reg_if #(
      .NUM(`GEMM_CFG_REG_NUM),
      .DW (32)
    ) issue_if();

    VX_node_done_if done_if();
    wire output_store_done;
    wire progress_update_valid;
    wire [`JOB_MMIO_ENTRYID_W-1:0] progress_update_entry_id;
    wire [31:0] progress_update_value;

    // -------------------------------------------------------------------------
    // Control-plane wiring
    // -------------------------------------------------------------------------

    // Packet-level control for the stateless fixed-latency GEMM unit.
    wire input_cmd_start = gemm_ctrl_if.input_read_ctrl.start;
    wire input_packet_fire = i_gemm_bus_if.req_valid
                           && i_gemm_bus_if.req_ready;
    wire input_last_admission = input_packet_fire
                              && gemm_unit_v2_if.packet_ctrl.last;
    wire qualified_input_dma_idle
        = input_cmd_ctx_r.active
       && !input_cmd_ctx_r.notify_on_writeback
       && input_cmd_ctx_r.ingress_complete
       && input_dma_ctrl_if.idle;
    wire tagged_final_writeback
        = input_cmd_ctx_r.active
       && input_cmd_ctx_r.notify_on_writeback
       && gemm_unit_v2_if.tagged_final_writeback;
    wire input_cmd_done = input_cmd_ctx_r.notify_on_writeback
                        ? tagged_final_writeback
                        : qualified_input_dma_idle;
    wire [`XLEN-1:0] input_packet_addr_full
        = input_cmd_ctx.acc_base
        + `XLEN'(input_cmd_ctx.packet_index * `GEMM_PSUM_DATA_SIZE);
    wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] input_packet_addr
        = input_packet_addr_full[`GEMM_ACC_MEM_ADDR_WIDTH-1:0];

    // Select the incoming command on its start cycle so a zero-latency first
    // LDMA packet cannot observe stale registered context.
    always_comb begin
        input_cmd_ctx = input_cmd_ctx_r;
        if (input_cmd_start) begin
            input_cmd_ctx.active = 1'b1;
            input_cmd_ctx.ingress_complete = 1'b0;
            input_cmd_ctx.acc_base
                = gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
            input_cmd_ctx.packet_count
                = gemm_ctrl_if.input_read_ctrl.cmd.eff_mt;
            input_cmd_ctx.packet_index = '0;
            input_cmd_ctx.is_accum
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[3];
            input_cmd_ctx.notify_on_writeback
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[
                    INPUT_NOTIFY_ON_WRITEBACK_FLAG];
            input_cmd_ctx.quant_dir
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[5];
            input_cmd_ctx.wreg_use_idx
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[2];
            input_cmd_ctx.sreg_use_idx
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
            input_cmd_ctx.zreg_use_idx
                = gemm_ctrl_if.input_read_ctrl.cmd.flags[0];
        end
    end

    always_comb begin
        gemm_unit_v2_if.packet_ctrl = '0;
        gemm_unit_v2_if.packet_ctrl.valid = input_packet_fire;
        gemm_unit_v2_if.packet_ctrl.acc_rd_en = input_cmd_ctx.is_accum;
        gemm_unit_v2_if.packet_ctrl.acc_wr_en = 1'b1;
        gemm_unit_v2_if.packet_ctrl.acc_rd_addr = input_packet_addr;
        gemm_unit_v2_if.packet_ctrl.acc_wr_addr = input_packet_addr;
        gemm_unit_v2_if.packet_ctrl.quant_dir = input_cmd_ctx.quant_dir;
        gemm_unit_v2_if.packet_ctrl.wreg_use_idx
            = input_cmd_ctx.wreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.sreg_use_idx
            = input_cmd_ctx.sreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.zreg_use_idx
            = input_cmd_ctx.zreg_use_idx;
        gemm_unit_v2_if.packet_ctrl.is_load = !input_cmd_ctx.is_accum;
        gemm_unit_v2_if.packet_ctrl.notify_on_writeback
            = input_cmd_ctx.notify_on_writeback;
        gemm_unit_v2_if.packet_ctrl.last
            = (input_cmd_ctx.packet_count != 0)
           && (input_cmd_ctx.packet_index
            == input_cmd_ctx.packet_count - 1'b1);
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            input_cmd_ctx_r <= '0;
        end else begin
            if (input_cmd_start) begin
                input_cmd_ctx_r <= input_cmd_ctx;
                if (input_packet_fire) begin
                    if (gemm_unit_v2_if.packet_ctrl.last)
                        input_cmd_ctx_r.ingress_complete <= 1'b1;
                    else
                        input_cmd_ctx_r.packet_index <= 21'd1;
                end
            end else if (input_packet_fire
                      && input_cmd_ctx_r.active
                      && !input_cmd_ctx_r.ingress_complete) begin
                if (gemm_unit_v2_if.packet_ctrl.last)
                    input_cmd_ctx_r.ingress_complete <= 1'b1;
                else
                    input_cmd_ctx_r.packet_index
                        <= input_cmd_ctx_r.packet_index + 1'b1;
            end else if (input_cmd_done) begin
                input_cmd_ctx_r <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    // Named integration probes used by node-level and XRT-VCS debug.
    logic        dbg_input_cmd_start;
    logic        dbg_input_admission;
    logic [20:0] dbg_input_packet_index;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] dbg_input_acc_addr;
    logic        dbg_input_acc_rd_en;
    logic        dbg_input_last_admission;
    logic        dbg_input_last_write;
    logic        dbg_input_cmd_done;

    assign dbg_input_cmd_start = input_cmd_start;
    assign dbg_input_admission = input_packet_fire;
    assign dbg_input_packet_index = input_cmd_ctx.packet_index;
    assign dbg_input_acc_addr = input_packet_addr;
    assign dbg_input_acc_rd_en = gemm_unit_v2_if.packet_ctrl.acc_rd_en;
    assign dbg_input_last_admission = input_last_admission;
    assign dbg_input_last_write = gemm_unit_v2_if.last_write;
    assign dbg_input_cmd_done = gemm_ctrl_if.input_read_flag.done;

    logic        input_ctx_sample_valid_r;
    logic [20:0] input_packet_index_sample_r;
    logic        input_packet_fire_sample_r;
    logic        input_cmd_start_sample_r;
    logic        input_last_write_sample_r;
    logic [31:0] input_cmd_count_r;
    logic [31:0] input_last_admission_count_r;
    logic [31:0] input_last_write_count_r;
    logic [31:0] input_done_count_r;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            input_ctx_sample_valid_r <= 1'b0;
            input_packet_index_sample_r <= '0;
            input_packet_fire_sample_r <= 1'b0;
            input_cmd_start_sample_r <= 1'b0;
            input_last_write_sample_r <= 1'b0;
            input_cmd_count_r <= '0;
            input_last_admission_count_r <= '0;
            input_last_write_count_r <= '0;
            input_done_count_r <= '0;
        end else begin
            input_ctx_sample_valid_r <= 1'b1;
            input_packet_index_sample_r <= input_cmd_ctx_r.packet_index;
            input_packet_fire_sample_r <= input_packet_fire;
            input_cmd_start_sample_r <= input_cmd_start;
            input_last_write_sample_r <= input_cmd_done;

            if (input_cmd_start)
                input_cmd_count_r <= input_cmd_count_r + 1'b1;
            if (input_last_admission)
                input_last_admission_count_r
                    <= input_last_admission_count_r + 1'b1;
            if (gemm_unit_v2_if.last_write)
                input_last_write_count_r <= input_last_write_count_r + 1'b1;
            if (gemm_ctrl_if.input_read_flag.done)
                input_done_count_r <= input_done_count_r + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset === 1'b0) begin
            assert (gemm_unit_v2_if.packet_ctrl.valid == input_packet_fire)
                else $fatal(1, "GEMM node V2 packet valid/admission mismatch");

            if (input_cmd_start) begin
                assert (!input_cmd_ctx_r.active)
                    else $fatal(1, "GEMM node V2 input command overwrote active context");
                assert (gemm_ctrl_if.input_read_ctrl.cmd.eff_mt != 0)
                    else $fatal(1, "GEMM node V2 input command has zero packet count");
                assert (gemm_ctrl_if.input_read_ctrl.cmd.eff_mt
                     == {5'd0, gemm_ctrl_if.input_read_ctrl.cmd.bound})
                    else $fatal(1, "GEMM node V2 eff_mt/input LDMA bound mismatch");
            end

            if (input_packet_fire) begin
                assert (input_cmd_start || input_cmd_ctx_r.active)
                    else $fatal(1, "GEMM node V2 admitted input without command context");
                assert (input_cmd_start || !input_cmd_ctx_r.ingress_complete)
                    else $fatal(1, "GEMM node V2 admitted input after last packet");
                assert (input_cmd_ctx.packet_count != 0)
                    else $fatal(1, "GEMM node V2 packet has zero command count");
                assert (input_cmd_ctx.packet_index < input_cmd_ctx.packet_count)
                    else $fatal(1, "GEMM node V2 packet index exceeds command count");
                assert (input_packet_addr_full[`CLOG2(`GEMM_PSUM_DATA_SIZE)-1:0]
                     == '0)
                    else $fatal(1, "GEMM node V2 accumulation address is not row aligned");
                assert ((input_packet_addr_full + `GEMM_PSUM_DATA_SIZE)
                     <= `GEMM_ACC_MEM_TOT_SIZE)
                    else $fatal(1, "GEMM node V2 accumulation address is out of range");
                assert (gemm_unit_v2_if.packet_ctrl.last
                     == (input_cmd_ctx.packet_index
                      == input_cmd_ctx.packet_count - 1'b1))
                    else $fatal(1, "GEMM node V2 last metadata mismatch");
            end

            if (input_last_admission) begin
                assert (!input_cmd_ctx_r.ingress_complete)
                    else $fatal(1, "GEMM node V2 emitted duplicate last packet");
                assert (input_last_admission_count_r < input_cmd_count_r
                     || input_cmd_start)
                    else $fatal(1, "GEMM node V2 has multiple last packets per command");
            end

            if (gemm_unit_v2_if.last_write) begin
                assert (input_last_write_count_r < input_last_admission_count_r)
                    else $fatal(1, "GEMM node V2 emitted duplicate last_write");
            end

            if (qualified_input_dma_idle) begin
                assert (input_cmd_ctx_r.active
                     && input_cmd_ctx_r.ingress_complete
                     && !input_cmd_ctx_r.notify_on_writeback)
                    else $fatal(1, "GEMM node V2 accepted an unqualified input DMA idle");
            end

            if (gemm_unit_v2_if.tagged_final_writeback) begin
                assert (gemm_unit_v2_if.last_write)
                    else $fatal(1, "GEMM node V2 tagged writeback lacks last_write");
            end

            if (gemm_ctrl_if.input_read_flag.done) begin
                assert (input_cmd_ctx_r.active
                     && input_cmd_ctx_r.ingress_complete)
                    else $fatal(1, "GEMM node V2 command done lacks completed ingress");
                assert (input_cmd_ctx_r.notify_on_writeback
                      ? tagged_final_writeback
                      : qualified_input_dma_idle)
                    else $fatal(1, "GEMM node V2 command done used the wrong completion source");
                assert (input_done_count_r < input_cmd_count_r)
                    else $fatal(1, "GEMM node V2 emitted duplicate command done");
            end

            if (input_ctx_sample_valid_r
             && !input_packet_fire_sample_r
             && !input_cmd_start_sample_r
             && !input_last_write_sample_r) begin
                assert (input_cmd_ctx_r.packet_index
                     == input_packet_index_sample_r)
                    else $fatal(1, "GEMM node V2 packet index changed without admission");
            end
        end
    end

    always @(posedge reset) begin
        if ($time > 0) begin
            assert (!input_cmd_ctx_r.active
                 && gemm_unit_v2_if.pipeline_empty)
                else $fatal(1, "Reset asserted with outstanding GEMM input/pipeline state");
        end
    end
`endif

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start           = input_cmd_start;
    assign input_dma_ctrl_if.prepare         = gemm_ctrl_if.input_read_ctrl.prepare;
    assign input_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.input_read_ctrl.cmd.prepare.max_beats;
    assign input_dma_ctrl_if.src_base_addr   = gemm_ctrl_if.input_read_ctrl.cmd.rs2_data;
    assign input_dma_ctrl_if.src_strides[0]  = gemm_ctrl_if.input_read_ctrl.cmd.stride;
    assign input_dma_ctrl_if.src_strides[1]  = 0;
    assign input_dma_ctrl_if.src_strides[2]  = 0;

    assign input_dma_ctrl_if.dst_base_addr   = '0;  //gemm_unit 으로 들어가는 input activation의 주소는 안 중요함
    assign input_dma_ctrl_if.dst_strides[0]  = 0;
    assign input_dma_ctrl_if.dst_strides[1]  = 0;
    assign input_dma_ctrl_if.dst_strides[2]  = 0;

    assign input_dma_ctrl_if.bounds[0]       = gemm_ctrl_if.input_read_ctrl.cmd.bound;
    assign input_dma_ctrl_if.bounds[1]       = 32'd1;
    assign input_dma_ctrl_if.bounds[2]       = 32'd1;

    assign input_dma_ctrl_if.seg_size        = MXU_KT*2;  // one MXU_ROW of FP16 per segment (64 bytes)
    assign gemm_ctrl_if.input_read_flag.idle
        = !input_cmd_ctx_r.active && input_dma_ctrl_if.idle;
    assign gemm_ctrl_if.input_read_flag.done = input_cmd_done;
    assign gemm_ctrl_if.input_read_flag.prepare_ready
        = input_dma_ctrl_if.prepare_ready;

    assign gemm_sync_if[0].valid   = 1'b0;
    assign gemm_sync_if[0].reg_idx = 32'd0;
    assign gemm_sync_if[0].value   = 32'd0;

    // Weight load DMA command mapping.
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start;
    assign weight_dma_ctrl_if.prepare        = gemm_ctrl_if.weight_read_ctrl.prepare;
    assign weight_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.weight_read_ctrl.cmd.prepare.max_beats;
    assign weight_dma_ctrl_if.src_base_addr  = gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data;
    assign weight_dma_ctrl_if.src_strides[0] = gemm_ctrl_if.weight_read_ctrl.cmd.stride;
    assign weight_dma_ctrl_if.src_strides[1] = 0;
    assign weight_dma_ctrl_if.src_strides[2] = 0;

    assign weight_dma_ctrl_if.dst_base_addr  = 0;  //gemm_unit 으로 들어가는 weight의 주소는 안 중요함
    assign weight_dma_ctrl_if.dst_strides[0] = 0;
    assign weight_dma_ctrl_if.dst_strides[1] = 0;
    assign weight_dma_ctrl_if.dst_strides[2] = 0;

    assign weight_dma_ctrl_if.bounds[0]      = gemm_ctrl_if.weight_read_ctrl.cmd.bound;
    assign weight_dma_ctrl_if.bounds[1]      = 32'd1;
    assign weight_dma_ctrl_if.bounds[2]      = 32'd1;

    assign weight_dma_ctrl_if.seg_size       = MXU_KT * (MXU_NT >> 1);  //int4, bytes
    assign gemm_ctrl_if.weight_read_flag.idle
        = weight_dma_ctrl_if.idle && !weight_write_active_r;
    assign gemm_ctrl_if.weight_read_flag.done = weight_last_register_write;
    assign gemm_ctrl_if.weight_read_flag.prepare_ready
        = weight_dma_ctrl_if.prepare_ready;

    assign gemm_sync_if[1].valid   = 1'b0;
    assign gemm_sync_if[1].reg_idx = 32'd0;
    assign gemm_sync_if[1].value   = 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        weight_cmd_flags_r <= '0;
        weight_write_active_r <= 1'b0;
        weight_writes_remaining_r <= '0;
      end else begin
        // Capture flags when weight DMA starts (FIFO pops same cycle, so cmd
        // changes next cycle), and count writes at the GEMM register endpoint.
        if (weight_dma_start) begin
          weight_cmd_flags_r <= gemm_ctrl_if.weight_read_ctrl.cmd.flags;
          weight_write_active_r
              <= !gemm_unit_v2_if.weight_register_write
              || (weight_command_writes != 64'd1);
          weight_writes_remaining_r
              <= weight_command_writes
               - 64'(gemm_unit_v2_if.weight_register_write);
        end else if (gemm_unit_v2_if.weight_register_write) begin
          weight_writes_remaining_r <= weight_writes_remaining_r - 1'b1;
          if (weight_writes_remaining_r == 64'd1)
            weight_write_active_r <= 1'b0;
        end
      end
    end

`ifdef DBG_TRACE_GEMM
    always @(posedge clk) begin
	      if (reset === 1'b0) begin
	        if (input_cmd_start) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_CMD_START | {inst=%s, base=0x%0h, packets=%0d, flags=0x%0h}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.input_read_ctrl.cmd.rs1_data,
	              gemm_ctrl_if.input_read_ctrl.cmd.eff_mt,
	              gemm_ctrl_if.input_read_ctrl.cmd.flags))
	        end
	        if (input_packet_fire) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_PACKET | {inst=%s, index=%0d, addr=0x%0h, rd=%0d, wr=%0d, last=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx.packet_index,
	              input_packet_addr,
	              gemm_unit_v2_if.packet_ctrl.acc_rd_en,
	              gemm_unit_v2_if.packet_ctrl.acc_wr_en,
	              gemm_unit_v2_if.packet_ctrl.last))
	        end
	        if (input_dma_ctrl_if.done) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_DMA_DONE | {inst=%s, index=%0d, active=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx_r.packet_index,
	              input_cmd_ctx_r.active))
	        end
	        if (gemm_unit_v2_if.last_write) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_LAST_WRITE | {inst=%s, index=%0d, ingress_complete=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx_r.packet_index,
	              input_cmd_ctx_r.ingress_complete))
	        end
	        if (gemm_ctrl_if.input_read_flag.done) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_INPUT_CMD_DONE | {inst=%s, index=%0d}\n",
	              $time, INSTANCE_ID,
	              input_cmd_ctx_r.packet_index))
	        end
	        if (weight_dma_start) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_WEIGHT_DMA_START | {inst=%s, src=0x%0h, stride=%0d, bound=%0d, flags=0x%0h, seg_size=%0d}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data,
	              gemm_ctrl_if.weight_read_ctrl.cmd.stride,
	              gemm_ctrl_if.weight_read_ctrl.cmd.bound,
	              gemm_ctrl_if.weight_read_ctrl.cmd.flags,
	              MXU_KT * (MXU_NT >> 1)))
	        end
	      end
	    end
`endif

    // Independent scale and zero-point local DMA command mappings.
    assign scale_dma_ctrl_if.start = gemm_ctrl_if.scale_read_ctrl.start;
    assign scale_dma_ctrl_if.prepare = gemm_ctrl_if.scale_read_ctrl.prepare;
    assign scale_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.scale_read_ctrl.cmd.prepare.max_beats;
    assign scale_dma_ctrl_if.src_base_addr
        = gemm_ctrl_if.scale_read_ctrl.cmd.rs2_data;
    assign scale_dma_ctrl_if.src_strides[0]
        = gemm_ctrl_if.scale_read_ctrl.cmd.stride[31:16];
    assign scale_dma_ctrl_if.src_strides[1] = 0;
    assign scale_dma_ctrl_if.src_strides[2] = 0;
    assign scale_dma_ctrl_if.dst_base_addr
        = gemm_ctrl_if.scale_read_ctrl.cmd.rs1_data;
    assign scale_dma_ctrl_if.dst_strides[0]
        = gemm_ctrl_if.scale_read_ctrl.cmd.stride[15:0];
    assign scale_dma_ctrl_if.dst_strides[1] = 0;
    assign scale_dma_ctrl_if.dst_strides[2] = 0;
    assign scale_dma_ctrl_if.bounds[0]
        = gemm_ctrl_if.scale_read_ctrl.cmd.bound;
    assign scale_dma_ctrl_if.bounds[1] = 32'd1;
    assign scale_dma_ctrl_if.bounds[2] = 32'd1;
    assign scale_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign gemm_ctrl_if.scale_read_flag.idle
        = scale_dma_ctrl_if.idle && !scale_write_active_r;
    assign gemm_ctrl_if.scale_read_flag.done = scale_last_register_write;
    assign gemm_ctrl_if.scale_read_flag.prepare_ready
        = scale_dma_ctrl_if.prepare_ready;

    assign zero_point_dma_ctrl_if.start
        = gemm_ctrl_if.zero_point_read_ctrl.start;
    assign zero_point_dma_ctrl_if.prepare
        = gemm_ctrl_if.zero_point_read_ctrl.prepare;
    assign zero_point_dma_ctrl_if.prepare_max_beats
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.prepare.max_beats;
    assign zero_point_dma_ctrl_if.src_base_addr
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.rs2_data;
    assign zero_point_dma_ctrl_if.src_strides[0]
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.stride[31:16];
    assign zero_point_dma_ctrl_if.src_strides[1] = 0;
    assign zero_point_dma_ctrl_if.src_strides[2] = 0;
    assign zero_point_dma_ctrl_if.dst_base_addr
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.rs1_data;
    assign zero_point_dma_ctrl_if.dst_strides[0]
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.stride[15:0];
    assign zero_point_dma_ctrl_if.dst_strides[1] = 0;
    assign zero_point_dma_ctrl_if.dst_strides[2] = 0;
    assign zero_point_dma_ctrl_if.bounds[0]
        = gemm_ctrl_if.zero_point_read_ctrl.cmd.bound;
    assign zero_point_dma_ctrl_if.bounds[1] = 32'd1;
    assign zero_point_dma_ctrl_if.bounds[2] = 32'd1;
    assign zero_point_dma_ctrl_if.seg_size = MXU_NT * 2;
    assign gemm_ctrl_if.zero_point_read_flag.idle
        = zero_point_dma_ctrl_if.idle && !zero_point_write_active_r;
    assign gemm_ctrl_if.zero_point_read_flag.done
        = zero_point_last_register_write;
    assign gemm_ctrl_if.zero_point_read_flag.prepare_ready
        = zero_point_dma_ctrl_if.prepare_ready;
    assign gemm_ctrl_if.quant_param_read_flag.idle = 1'b1;
    assign gemm_ctrl_if.quant_param_read_flag.done = 1'b0;
    assign gemm_ctrl_if.quant_param_read_flag.prepare_ready = 1'b0;

    always_ff @(posedge clk) begin
      if (reset) begin
        scale_write_active_r <= 1'b0;
        scale_writes_remaining_r <= '0;
        zero_point_write_active_r <= 1'b0;
        zero_point_writes_remaining_r <= '0;
      end else begin
        if (scale_dma_start) begin
          scale_write_active_r
              <= !gemm_unit_v2_if.scale_register_write
              || (scale_command_writes != 64'd1);
          scale_writes_remaining_r
              <= scale_command_writes
               - 64'(gemm_unit_v2_if.scale_register_write);
        end else if (gemm_unit_v2_if.scale_register_write) begin
          scale_writes_remaining_r <= scale_writes_remaining_r - 1'b1;
          if (scale_writes_remaining_r == 64'd1)
            scale_write_active_r <= 1'b0;
        end

        if (zero_point_dma_start) begin
          zero_point_write_active_r
              <= !gemm_unit_v2_if.zero_point_register_write
              || (zero_point_command_writes != 64'd1);
          zero_point_writes_remaining_r
              <= zero_point_command_writes
               - 64'(gemm_unit_v2_if.zero_point_register_write);
        end else if (gemm_unit_v2_if.zero_point_register_write) begin
          zero_point_writes_remaining_r
              <= zero_point_writes_remaining_r - 1'b1;
          if (zero_point_writes_remaining_r == 64'd1)
            zero_point_write_active_r <= 1'b0;
        end
      end
    end

    assign gemm_sync_if[2].valid   = 1'b0;
    assign gemm_sync_if[2].reg_idx = 32'd0;
    assign gemm_sync_if[2].value   = 32'd0;
    assign gemm_sync_if[3].valid   = 1'b0;
    assign gemm_sync_if[3].reg_idx = 32'd0;
    assign gemm_sync_if[3].value   = 32'd0;

    // Output store DMA command mapping.
    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start;
    assign output_dma_ctrl_if.prepare       = 1'b0;
    assign output_dma_ctrl_if.prepare_max_beats = '0;
    assign output_dma_ctrl_if.src_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs2_data;
    assign output_dma_ctrl_if.src_strides[0] = 0;
    assign output_dma_ctrl_if.src_strides[1] = 0;
    assign output_dma_ctrl_if.src_strides[2] = 0;

    assign output_dma_ctrl_if.dst_base_addr = gemm_ctrl_if.output_write_ctrl.cmd.rs1_data;
    assign output_dma_ctrl_if.dst_strides[0] = gemm_ctrl_if.output_write_ctrl.cmd.stride;
    assign output_dma_ctrl_if.dst_strides[1] = 0;
    assign output_dma_ctrl_if.dst_strides[2] = 0;

    assign output_dma_ctrl_if.bounds[0] = 32'd1;
    assign output_dma_ctrl_if.bounds[1] = 32'd1;
    assign output_dma_ctrl_if.bounds[2] = 32'd1;

    assign output_dma_ctrl_if.seg_size         = MXU_NT * 2 * gemm_ctrl_if.output_write_ctrl.cmd.bound;  // all rows in one segment
    assign gemm_ctrl_if.output_write_flag.idle
        = output_dma_ctrl_if.idle && !output_write_active_r;
    assign gemm_ctrl_if.output_write_flag.done = output_dma_ctrl_if.write_done;
    assign gemm_ctrl_if.output_write_flag.prepare_ready = 1'b0;

    always_ff @(posedge clk) begin
      if (reset) begin
        output_write_active_r <= 1'b0;
      end else if (gemm_ctrl_if.output_write_ctrl.start) begin
        output_write_active_r <= 1'b1;
      end else if (output_dma_ctrl_if.write_done) begin
        output_write_active_r <= 1'b0;
      end
    end

    assign gemm_sync_if[4].valid   = 1'b0;
    assign gemm_sync_if[4].reg_idx = 32'd0;
    assign gemm_sync_if[4].value   = 32'd0;

`ifndef SYNTHESIS
    // The scheduler completion pulses must coincide with the exact terminal
    // architectural writes and may occur only once for an active command.
    always_ff @(posedge clk) begin
      if (!reset) begin
        if (weight_dma_start) begin
          assert (!weight_write_active_r && (weight_command_writes != 0))
            else $fatal(1, "%s: overlapping/empty weight command", INSTANCE_ID);
        end
        if (gemm_unit_v2_if.weight_register_write) begin
          assert ((weight_write_active_r
                && (weight_writes_remaining_r != 0))
               || (weight_dma_start && (weight_command_writes != 0)))
            else $fatal(1, "%s: early or duplicate weight register write", INSTANCE_ID);
        end
        if (gemm_ctrl_if.weight_read_flag.done) begin
          assert (weight_last_register_write)
            else $fatal(1, "%s: weight done is not the final register write", INSTANCE_ID);
        end

        if (scale_dma_start) begin
          assert (!scale_write_active_r && (scale_command_writes != 0))
            else $fatal(1, "%s: overlapping/empty scale command", INSTANCE_ID);
        end
        if (gemm_unit_v2_if.scale_register_write) begin
          assert ((scale_write_active_r
                && (scale_writes_remaining_r != 0))
               || (scale_dma_start && (scale_command_writes != 0)))
            else $fatal(1, "%s: early or duplicate scale register write", INSTANCE_ID);
        end
        if (gemm_ctrl_if.scale_read_flag.done) begin
          assert (scale_last_register_write)
            else $fatal(1, "%s: scale done is not the final register write", INSTANCE_ID);
        end

        if (zero_point_dma_start) begin
          assert (!zero_point_write_active_r
               && (zero_point_command_writes != 0))
            else $fatal(1, "%s: overlapping/empty zero-point command", INSTANCE_ID);
        end
        if (gemm_unit_v2_if.zero_point_register_write) begin
          assert ((zero_point_write_active_r
                && (zero_point_writes_remaining_r != 0))
               || (zero_point_dma_start
                && (zero_point_command_writes != 0)))
            else $fatal(1, "%s: early or duplicate zero-point register write", INSTANCE_ID);
        end
        if (gemm_ctrl_if.zero_point_read_flag.done) begin
          assert (zero_point_last_register_write)
            else $fatal(1, "%s: zero-point done is not the final register write", INSTANCE_ID);
        end

        if (gemm_ctrl_if.output_write_ctrl.start) begin
          assert (!output_write_active_r)
            else $fatal(1, "%s: overlapping output command", INSTANCE_ID);
        end
        if (output_dma_ctrl_if.write_done) begin
          assert (output_write_active_r)
            else $fatal(1, "%s: early or duplicate output destination write done",
                        INSTANCE_ID);
        end
        assert (gemm_ctrl_if.output_write_flag.done
             == output_dma_ctrl_if.write_done)
          else $fatal(1, "%s: output done is not direct final destination write",
                      INSTANCE_ID);
      end
    end
`endif

    // External DMA control: VX_gemm_tmem_dma_ctrl translates GEMM DMA
    // commands into VX_config_reg_if writes for the DMA engine.
    assign gemm_dma_ctrl_if.start      = gemm_ctrl_if.dma_ctrl.start;
    assign gemm_dma_ctrl_if.cmd_valid  = gemm_ctrl_if.dma_ctrl.cmd_valid;
    assign gemm_dma_ctrl_if.cmd        = gemm_ctrl_if.dma_ctrl.cmd;
    assign gemm_dma_ctrl_if.cmd_tag    = gemm_ctrl_if.dma_ctrl.cmd_tag;
    assign gemm_dma_ctrl_if.prepare_valid
        = gemm_ctrl_if.dma_ctrl.prepare_valid;
    assign gemm_dma_ctrl_if.prepare_cmd = gemm_ctrl_if.dma_ctrl.prepare_cmd;

    assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;
    assign gemm_ctrl_if.dma_flag.cmd_ready = gemm_dma_ctrl_if.cmd_ready;
    assign gemm_ctrl_if.dma_flag.done_tag = gemm_dma_ctrl_if.done_tag;
    assign gemm_ctrl_if.dma_flag.prepare_ready
        = gemm_dma_ctrl_if.prepare_ready;

    // Internal DMA config/done interfaces (driven by tmem_dma_ctrl)
    VX_config_reg_if #(
        .NUM (`DMA_CFG_REG_NUM),
        .DW  (32)
    ) dma_cfg_if [NUM_TMEM_BANKS] ();

    VX_node_done_if dma_done_if [NUM_TMEM_BANKS] ();
    VX_dma_lookahead_if dma_lookahead_if [NUM_TMEM_BANKS] ();

    VX_gemm_tmem_dma_ctrl #(
        .INSTANCE_ID  ({INSTANCE_ID, "_tmem_dma_ctrl"}),
        .NUM_CHANNELS (NUM_TMEM_BANKS)
    ) u_tmem_dma_ctrl (
        .clk              (clk),
        .reset            (reset),
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM
        .compute_active_i (!gemm_unit_v2_if.pipeline_empty),
`endif
`endif
        .gemm_dma_ctrl_if (gemm_dma_ctrl_if),
        .store_done       (output_store_done),
        .gemm_sync_if     (gemm_sync_if[5]),
        .cfg_reg_if       (dma_cfg_if),
        .lookahead_if     (dma_lookahead_if),
        .done_if          (dma_done_if)
    );

    // -------------------------------------------------------------------------
    // Frontend
    // -------------------------------------------------------------------------

    // Job frontend: MMIO descriptor registers and issue/done interface.
    VX_job_frontend #(
      .INSTANCE_ID(INSTANCE_ID),
      .NUM_MASTERS(N_MASTER),
      .NUM_ENTRIES(`JOB_MMIO_NUM_ENTRIES),
      .NUM_REGS32(`GEMM_CFG_REG_NUM),
      .HW_WRITE_REG_IDX(OUTPUT_PROGRESS_REG_IDX),
      .CFG_BASE_ADDR(`GEMM_REG_BASE_ADDR),
      .ONE_LANE_MMIO(1'b1)
    ) u_job_frontend (
      .clk(clk),
      .reset(reset),
      .mmio_if(mmio_if),
      .issue_if(issue_if),
      .done_if(done_if),
      .hw_write_valid_i(progress_update_valid),
      .hw_write_entry_id_i(progress_update_entry_id),
      .hw_write_value_i(progress_update_value)
    );

    // -------------------------------------------------------------------------
    // TMEM Subsystem
    // -------------------------------------------------------------------------
    // Replaces: LMEM arbiter, width adapters, LMEM DMAs, VX_gemm_dma_ctrl.
    // Contains: DMA engine (8ch AXI<->TMEM), TMEM banks, switches, local DMAs.

    VX_lmem_dma_ctrl_if tmem_ldma_ctrl_if [5] ();

    // Wire local DMA ctrl interfaces to the array expected by VX_tmem_subsystem
    assign tmem_ldma_ctrl_if[0].start          = input_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[0].prepare        = input_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[0].prepare_max_beats
        = input_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[0].src_base_addr  = input_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[0].src_strides    = input_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[0].dst_base_addr  = input_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[0].dst_strides    = input_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[0].bounds         = input_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[0].seg_size       = input_dma_ctrl_if.seg_size;
    assign input_dma_ctrl_if.idle              = tmem_ldma_ctrl_if[0].idle;
    assign input_dma_ctrl_if.done              = tmem_ldma_ctrl_if[0].done;
    assign input_dma_ctrl_if.write_done        = tmem_ldma_ctrl_if[0].write_done;
    assign input_dma_ctrl_if.prepare_ready     = tmem_ldma_ctrl_if[0].prepare_ready;

    assign tmem_ldma_ctrl_if[1].start          = weight_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[1].prepare        = weight_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[1].prepare_max_beats
        = weight_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[1].src_base_addr  = weight_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[1].src_strides    = weight_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[1].dst_base_addr  = weight_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[1].dst_strides    = weight_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[1].bounds         = weight_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[1].seg_size       = weight_dma_ctrl_if.seg_size;
    assign weight_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[1].idle;
    assign weight_dma_ctrl_if.done             = tmem_ldma_ctrl_if[1].done;
    assign weight_dma_ctrl_if.write_done       = tmem_ldma_ctrl_if[1].write_done;
    assign weight_dma_ctrl_if.prepare_ready    = tmem_ldma_ctrl_if[1].prepare_ready;

    assign tmem_ldma_ctrl_if[2].start          = scale_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[2].prepare        = scale_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[2].prepare_max_beats
        = scale_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[2].src_base_addr  = scale_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[2].src_strides    = scale_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[2].dst_base_addr  = scale_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[2].dst_strides    = scale_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[2].bounds         = scale_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[2].seg_size       = scale_dma_ctrl_if.seg_size;
    assign scale_dma_ctrl_if.idle              = tmem_ldma_ctrl_if[2].idle;
    assign scale_dma_ctrl_if.done              = tmem_ldma_ctrl_if[2].done;
    assign scale_dma_ctrl_if.write_done        = tmem_ldma_ctrl_if[2].write_done;
    assign scale_dma_ctrl_if.prepare_ready     = tmem_ldma_ctrl_if[2].prepare_ready;

    assign tmem_ldma_ctrl_if[3].start          = zero_point_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[3].prepare        = zero_point_dma_ctrl_if.prepare;
    assign tmem_ldma_ctrl_if[3].prepare_max_beats
        = zero_point_dma_ctrl_if.prepare_max_beats;
    assign tmem_ldma_ctrl_if[3].src_base_addr  = zero_point_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[3].src_strides    = zero_point_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[3].dst_base_addr  = zero_point_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[3].dst_strides    = zero_point_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[3].bounds         = zero_point_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[3].seg_size       = zero_point_dma_ctrl_if.seg_size;
    assign zero_point_dma_ctrl_if.idle         = tmem_ldma_ctrl_if[3].idle;
    assign zero_point_dma_ctrl_if.done         = tmem_ldma_ctrl_if[3].done;
    assign zero_point_dma_ctrl_if.write_done   = tmem_ldma_ctrl_if[3].write_done;
    assign zero_point_dma_ctrl_if.prepare_ready = tmem_ldma_ctrl_if[3].prepare_ready;

    assign tmem_ldma_ctrl_if[4].start          = output_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[4].prepare        = 1'b0;
    assign tmem_ldma_ctrl_if[4].prepare_max_beats = '0;
    assign tmem_ldma_ctrl_if[4].src_base_addr  = output_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[4].src_strides    = output_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[4].dst_base_addr  = output_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[4].dst_strides    = output_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[4].bounds         = output_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[4].seg_size       = output_dma_ctrl_if.seg_size;
    assign output_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[4].idle;
    assign output_dma_ctrl_if.done             = tmem_ldma_ctrl_if[4].done;
    assign output_dma_ctrl_if.write_done       = tmem_ldma_ctrl_if[4].write_done;
    assign output_dma_ctrl_if.prepare_ready    = tmem_ldma_ctrl_if[4].prepare_ready;

    VX_tmem_subsystem #(
      .INSTANCE_ID    ({INSTANCE_ID, ":tmem"}),
      .NUM_BANKS      (NUM_TMEM_BANKS),
      .BANK_SIZE      (`TMEM_BANK_SIZE),
      .DATA_SIZE      (`MEM_BLOCK_SIZE),
      .GEMM_DATA_SIZE (`MEM_BLOCK_SIZE),
      .GEMM_WEIGHT_DATA_SIZE (`GEMM_WEIGHT_DATA_SIZE),
      .TAG_WIDTH      (GEMM_BASE_TAG_WIDTH)
    ) u_tmem_subsystem (
      .clk            (clk),
      .reset          (reset),
      .dma_cfg_if     (dma_cfg_if),
      .dma_lookahead_if (dma_lookahead_if),
      .dma_done_if    (dma_done_if),
      .ldma_ctrl_if   (tmem_ldma_ctrl_if),
      .axi_m          (dma_axi_m),
      .gemm_input_if  (tmem_i_gemm_bus_if),
      .gemm_weight_if (tmem_w_gemm_bus_if),
      .gemm_scale_if  (tmem_sc_gemm_bus_if),
      .gemm_zp_if     (tmem_zp_gemm_bus_if),
      .gemm_output_if (tmem_o_gemm_bus_if)
`ifdef PERF_ENABLE
      ,.hbm_dma_perf         (hbm_dma_perf)
      ,.lmem_dma_input_perf  (lmem_dma_input_perf)
      ,.lmem_dma_weight_perf (lmem_dma_weight_perf)
      ,.lmem_dma_sz_perf     (lmem_dma_sz_perf)
      ,.lmem_dma_output_perf (lmem_dma_output_perf)
`endif
    );

    // -------------------------------------------------------------------------
    // GEMM compute/control instances
    // -------------------------------------------------------------------------

    // GEMM compute unit
    VX_gemm_unit_v2 #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_unit_v2 (
      .clk(clk),
      .reset(reset),
      .i_lmem_bus_if(i_gemm_bus_if),
      .w_lmem_bus_if(w_gemm_bus_if),
      .sc_lmem_bus_if(sc_gemm_bus_if),
      .zp_lmem_bus_if(zp_gemm_bus_if),
      .o_lmem_bus_if(o_gemm_bus_if),
      .gemm_unit_v2_if(gemm_unit_v2_if)
`ifdef ENABLE_HW_DEBUG_GEMM
      ,.debug(gemm_unit_debug)
`endif
`ifdef PERF_ENABLE
      ,.perf(gemm_unit_perf)
`endif
    );

    // -------------------------------------------------------------------------
    // Address manipulation: TMEM subsystem outputs -> GEMM unit inputs
    // -------------------------------------------------------------------------

    // Input: direct connection (no addr manipulation)
    `ASSIGN_VX_MEM_BUS_IF(i_gemm_bus_if, tmem_i_gemm_bus_if);

    // Weight: addr replaced with captured flags for double-buffering control
    assign w_gemm_bus_if.req_valid  = tmem_w_gemm_bus_if.req_valid;

    assign tmem_w_gemm_bus_if.req_ready  = w_gemm_bus_if.req_ready;
    assign tmem_w_gemm_bus_if.rsp_valid  = w_gemm_bus_if.rsp_valid;
    assign tmem_w_gemm_bus_if.rsp_data   = w_gemm_bus_if.rsp_data;
    assign w_gemm_bus_if.rsp_ready       = tmem_w_gemm_bus_if.rsp_ready;

    assign w_gemm_bus_if.req_data.rw     = tmem_w_gemm_bus_if.req_data.rw;
    assign w_gemm_bus_if.req_data.addr   = {weight_cmd_flags_r[1], weight_cmd_flags_r[0]};  // captured at DMA start
    assign w_gemm_bus_if.req_data.data   = tmem_w_gemm_bus_if.req_data.data;
    assign w_gemm_bus_if.req_data.byteen = tmem_w_gemm_bus_if.req_data.byteen;
    assign w_gemm_bus_if.req_data.flags  = tmem_w_gemm_bus_if.req_data.flags;
    assign w_gemm_bus_if.req_data.tag    = tmem_w_gemm_bus_if.req_data.tag;

    // Scale and zero-point use independent ingress paths.  Both convert the
    // local DMA beat address back to the GEMM register byte address.
    assign sc_gemm_bus_if.req_valid = tmem_sc_gemm_bus_if.req_valid;
    assign tmem_sc_gemm_bus_if.req_ready = sc_gemm_bus_if.req_ready;
    assign tmem_sc_gemm_bus_if.rsp_valid = sc_gemm_bus_if.rsp_valid;
    assign tmem_sc_gemm_bus_if.rsp_data = sc_gemm_bus_if.rsp_data;
    assign sc_gemm_bus_if.rsp_ready = tmem_sc_gemm_bus_if.rsp_ready;
    assign sc_gemm_bus_if.req_data.rw = tmem_sc_gemm_bus_if.req_data.rw;
    assign sc_gemm_bus_if.req_data.addr
        = tmem_sc_gemm_bus_if.req_data.addr
       << `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
    assign sc_gemm_bus_if.req_data.data = tmem_sc_gemm_bus_if.req_data.data;
    assign sc_gemm_bus_if.req_data.byteen = tmem_sc_gemm_bus_if.req_data.byteen;
    assign sc_gemm_bus_if.req_data.flags = tmem_sc_gemm_bus_if.req_data.flags;
    assign sc_gemm_bus_if.req_data.tag = tmem_sc_gemm_bus_if.req_data.tag;

    assign zp_gemm_bus_if.req_valid = tmem_zp_gemm_bus_if.req_valid;
    assign tmem_zp_gemm_bus_if.req_ready = zp_gemm_bus_if.req_ready;
    assign tmem_zp_gemm_bus_if.rsp_valid = zp_gemm_bus_if.rsp_valid;
    assign tmem_zp_gemm_bus_if.rsp_data = zp_gemm_bus_if.rsp_data;
    assign zp_gemm_bus_if.rsp_ready = tmem_zp_gemm_bus_if.rsp_ready;
    assign zp_gemm_bus_if.req_data.rw = tmem_zp_gemm_bus_if.req_data.rw;
    assign zp_gemm_bus_if.req_data.addr
        = tmem_zp_gemm_bus_if.req_data.addr
       << `CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE);
    assign zp_gemm_bus_if.req_data.data = tmem_zp_gemm_bus_if.req_data.data;
    assign zp_gemm_bus_if.req_data.byteen = tmem_zp_gemm_bus_if.req_data.byteen;
    assign zp_gemm_bus_if.req_data.flags = tmem_zp_gemm_bus_if.req_data.flags;
    assign zp_gemm_bus_if.req_data.tag = tmem_zp_gemm_bus_if.req_data.tag;

    // Output: direct connection
    `ASSIGN_VX_MEM_BUS_IF(o_gemm_bus_if, tmem_o_gemm_bus_if);

`ifdef PERF_ENABLE
    gemm_node_perf_t gemm_ctrl_perf;
`endif

    // GEMM top controller
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE),
      .DMA_STORE_MAX_CHUNK_BEATS(DMA_STORE_MAX_CHUNK_BEATS)
    ) u_VX_gemm_ctrl (
      .clk(clk),
      .reset(reset),
      .cfg_reg_if(issue_if),
      .gemm_ctrl_if(gemm_ctrl_if),
      .done_if(done_if),
      .gemm_sync_slv_if(gemm_sync_if),
      .output_store_done_i(output_store_done),
      .progress_update_valid_o(progress_update_valid),
      .progress_update_entry_id_o(progress_update_entry_id),
      .progress_update_value_o(progress_update_value)
`ifndef SYNTHESIS
`ifdef DBG_TRACE_GEMM_CMD_PERF
      ,.dbg_compute_active_i(!gemm_unit_v2_if.pipeline_empty)
`endif
`endif
`ifdef PERF_ENABLE
      ,.gemm_unit_computing(gemm_unit_perf.computing)
      ,.perf(gemm_ctrl_perf)
`endif
    );

`ifdef PERF_ENABLE
    // Assemble gemm_node_perf:
    //   total_cycles  : forwarded from gemm_ctrl
    //   lmem_rd_bytes : deferred (tied to '0). The original 78ca77 design tapped
    //                   a single shared lmem_bus_if at the gemm_node boundary.
    //                   On fpint_improve that bus has been split into five
    //                   separate GEMM-unit-facing buses (i/w/sc/zp/o).
    //                   that flow through the TMEM subsystem's local DMAs. The
    //                   per-LDMA byte counts are already aggregated in
    //                   lmem_dma_agg_perf (rd_bytes/wr_bytes), and the per-port
    //                   fire counters in gemm_unit_perf cover the same traffic
    //                   from the MXU side. Adding a separate counter here would
    //                   double-count the same bytes. Defer to a follow-up patch
    //                   if a gemm_node-local LMEM byte counter is needed.
    assign gemm_node_perf.total_cycles  = gemm_ctrl_perf.total_cycles;
    assign gemm_node_perf.lmem_rd_bytes = '0;
    assign gemm_node_perf.lmem_wr_bytes = '0;
`endif

    // `UNUSED_VAR (weight_wtrans)
    // `UNUSED_PARAM (MT)
    // `UNUSED_PARAM (NT)
    // `UNUSED_PARAM (KT)
    // `UNUSED_PARAM (ENTRYID_W)
    // `UNUSED_PARAM (OWNER_W)
    // `UNUSED_PARAM (GEN_W)

endmodule

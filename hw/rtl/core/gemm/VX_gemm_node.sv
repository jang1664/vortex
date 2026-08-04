/*
  VX_gemm_node

  Top-level GEMM node that integrates:
    - job frontend (MMIO register file + dispatch),
    - GEMM controller / GEMM unit,
    - VX_tmem_subsystem (tensor memory with DMA engine, banks, local DMAs).

  Dataflow summary
    - Load paths (i/w/sz):
        HBM -> DMA engine -> TMEM banks -> local DMAs -> GEMM unit
    - Output path:
        GEMM unit -> local DMA -> TMEM banks -> DMA engine -> HBM
*/
`include "VX_define.vh"

module VX_gemm_node import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter N_MASTER    = 1,
    parameter N_CHILDREN  = 5,
    parameter NUM_TMEM_BANKS = `NUM_DMA_CHANNELS
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
    localparam N_NODE   = 5;

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

    localparam logic [3:0] OP_NOTIFY = 4'd3;
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
    ) sz_gemm_bus_if ();
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
    ) tmem_sz_gemm_bus_if ();
    VX_mem_bus_if # (
      .DATA_SIZE(`GEMM_OUTPUT_DATA_SIZE),
      .TAG_WIDTH(GEMM_BASE_TAG_WIDTH)
    ) tmem_o_gemm_bus_if ();

    // -------------------------------------------------------------------------
    // Control interfaces
    // -------------------------------------------------------------------------
    VX_gemm_unit_v2_if gemm_unit_v2_if ();
    gemm_unit_ctrl_t input_cmd_ctrl_r;
    logic [`GEMM_ACC_MAX_CNT-1:0] input_packet_idx_r;
    logic input_cmd_active_r;
    VX_gemm_ctrl_if gemm_ctrl_if ();

    // LMEM DMA control interfaces (issued by gemm_ctrl)
    VX_lmem_dma_ctrl_if input_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if weight_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if quant_param_dma_ctrl_if ();
    VX_lmem_dma_ctrl_if output_dma_ctrl_if ();
    VX_gemm_dma_ctrl_if gemm_dma_ctrl_if ();

    logic        input_notify_pending_r;
    logic [31:0] input_notify_reg_idx_r;
    logic [31:0] input_notify_value_r;

    wire input_is_notify   = (gemm_ctrl_if.input_read_ctrl.start && gemm_ctrl_if.input_read_ctrl.cmd.instr[3:0] == OP_NOTIFY);
    wire input_notify_req  = gemm_ctrl_if.input_read_ctrl.start && input_dma_ctrl_if.idle && input_is_notify;
    wire input_notify_fire = input_notify_pending_r && gemm_sync_if[0].ready;

    logic        weight_notify_pending_r;
    logic [31:0] weight_notify_reg_idx_r;
    logic [31:0] weight_notify_value_r;
    logic [7:0]  weight_cmd_flags_r;

    wire weight_is_notify   = (gemm_ctrl_if.weight_read_ctrl.start && gemm_ctrl_if.weight_read_ctrl.cmd.instr[3:0] == OP_NOTIFY);
    wire weight_dma_start   = gemm_ctrl_if.weight_read_ctrl.start && !weight_is_notify;
    wire weight_notify_req  = gemm_ctrl_if.weight_read_ctrl.start && weight_dma_ctrl_if.idle && weight_is_notify;
    wire weight_notify_fire = weight_notify_pending_r && gemm_sync_if[1].ready;
    // wire weight_wtrans      = weight_cmd_flags_r[1];

    logic        sz_notify_pending_r;
    logic [31:0] sz_notify_reg_idx_r;
    logic [31:0] sz_notify_value_r;

    wire sz_is_notify   = (gemm_ctrl_if.quant_param_read_ctrl.start && gemm_ctrl_if.quant_param_read_ctrl.cmd.instr[3:0] == OP_NOTIFY);
    wire sz_notify_req  = gemm_ctrl_if.quant_param_read_ctrl.start && quant_param_dma_ctrl_if.idle && sz_is_notify;
    wire sz_notify_fire = sz_notify_pending_r && gemm_sync_if[2].ready;

    logic        output_notify_pending_r;
    logic [31:0] output_notify_reg_idx_r;
    logic [31:0] output_notify_value_r;

    wire output_is_notify   = (gemm_ctrl_if.output_write_ctrl.start && gemm_ctrl_if.output_write_ctrl.cmd.instr[3:0] == OP_NOTIFY);
    wire output_notify_req  = gemm_ctrl_if.output_write_ctrl.start && output_dma_ctrl_if.idle && output_is_notify;
    wire output_notify_fire = output_notify_pending_r && gemm_sync_if[3].ready;

`ifndef SYNTHESIS
    logic [31:0] dbg_cyc_q;
    always_ff @(posedge clk) begin
        if (reset) dbg_cyc_q <= 32'd0;
        else       dbg_cyc_q <= dbg_cyc_q + 32'd1;
    end

    logic        dbg_input_notify_fire;
    logic        dbg_weight_notify_fire;
    logic        dbg_sz_notify_fire;
    logic        dbg_output_notify_fire;
    logic [31:0] dbg_input_notify_cyc_q;
    logic [31:0] dbg_weight_notify_cyc_q;
    logic [31:0] dbg_sz_notify_cyc_q;
    logic [31:0] dbg_output_notify_cyc_q;

    assign dbg_input_notify_fire  = input_notify_fire;
    assign dbg_weight_notify_fire = weight_notify_fire;
    assign dbg_sz_notify_fire     = sz_notify_fire;
    assign dbg_output_notify_fire = output_notify_fire;

    always_ff @(posedge clk) begin
        if (reset) begin
            dbg_input_notify_cyc_q  <= 32'd0;
            dbg_weight_notify_cyc_q <= 32'd0;
            dbg_sz_notify_cyc_q     <= 32'd0;
            dbg_output_notify_cyc_q <= 32'd0;
        end else begin
            if (input_notify_fire)  dbg_input_notify_cyc_q  <= dbg_cyc_q;
            if (weight_notify_fire) dbg_weight_notify_cyc_q <= dbg_cyc_q;
            if (sz_notify_fire)     dbg_sz_notify_cyc_q     <= dbg_cyc_q;
            if (output_notify_fire) dbg_output_notify_cyc_q <= dbg_cyc_q;
        end
    end

    logic        dbg_weight_dma_start;
    logic [31:0] dbg_weight_dma_start_cyc_q;
    assign dbg_weight_dma_start = weight_dma_start;
    always_ff @(posedge clk) begin
        if (reset)                  dbg_weight_dma_start_cyc_q <= 32'd0;
        else if (weight_dma_start)  dbg_weight_dma_start_cyc_q <= dbg_cyc_q;
    end
`endif

    // Completion/synchronization path from child nodes to gemm_ctrl.
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
    wire input_cmd_start = gemm_ctrl_if.input_read_ctrl.start
                         && !input_is_notify;
    wire input_packet_fire = i_gemm_bus_if.req_valid;
    wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] input_ctrl_base_addr
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.rs1_data
                          : input_cmd_ctrl_r.acc_mem_base_addr;
    wire [`GEMM_ACC_MAX_CNT-1:0] input_ctrl_acc_cnt
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.instr[31:4]
                          : input_cmd_ctrl_r.acc_cnt;
    wire input_ctrl_is_load
        = input_cmd_start ? ~gemm_ctrl_if.input_read_ctrl.cmd.flags[3]
                          : input_cmd_ctrl_r.is_load;
    wire [`GEMM_ACC_MAX_CNT-1:0] input_packet_idx
        = input_cmd_start ? '0 : input_packet_idx_r;
    wire [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] input_packet_addr
        = input_ctrl_base_addr
        + `GEMM_ACC_MEM_ADDR_WIDTH'(
            input_packet_idx << `CLOG2(`GEMM_PSUM_DATA_SIZE));

    assign gemm_unit_v2_if.packet_ctrl.valid = i_gemm_bus_if.req_valid;
    assign gemm_unit_v2_if.packet_ctrl.acc_rd_en
        = !input_ctrl_is_load;
    assign gemm_unit_v2_if.packet_ctrl.acc_wr_en = 1'b1;
    assign gemm_unit_v2_if.packet_ctrl.acc_rd_addr = input_packet_addr;
    assign gemm_unit_v2_if.packet_ctrl.acc_wr_addr = input_packet_addr;
    assign gemm_unit_v2_if.packet_ctrl.quant_dir
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.flags[5]
                          : input_cmd_ctrl_r.quant_dir;
    assign gemm_unit_v2_if.packet_ctrl.wreg_use_idx
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.flags[2]
                          : input_cmd_ctrl_r.wreg_use_idx;
    assign gemm_unit_v2_if.packet_ctrl.sreg_use_idx
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.flags[1]
                          : input_cmd_ctrl_r.sreg_use_idx;
    assign gemm_unit_v2_if.packet_ctrl.zreg_use_idx
        = input_cmd_start ? gemm_ctrl_if.input_read_ctrl.cmd.flags[0]
                          : input_cmd_ctrl_r.zreg_use_idx;
    assign gemm_unit_v2_if.packet_ctrl.is_load
        = input_ctrl_is_load;
    assign gemm_unit_v2_if.packet_ctrl.last
        = (input_packet_idx == input_ctrl_acc_cnt - 1'b1);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            input_cmd_ctrl_r <= '0;
            input_packet_idx_r <= '0;
            input_cmd_active_r <= 1'b0;
        end else begin
            if (input_cmd_start) begin
                input_cmd_ctrl_r.quant_dir
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[5];
                input_cmd_ctrl_r.acc_mem_base_addr
                    <= gemm_ctrl_if.input_read_ctrl.cmd.rs1_data;
                input_cmd_ctrl_r.output_mem_base_addr <= '0;
                input_cmd_ctrl_r.output_mem_stride <= '0;
                input_cmd_ctrl_r.acc_cnt
                    <= gemm_ctrl_if.input_read_ctrl.cmd.instr[31:4];
                input_cmd_ctrl_r.wreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[2];
                input_cmd_ctrl_r.sreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[1];
                input_cmd_ctrl_r.zreg_use_idx
                    <= gemm_ctrl_if.input_read_ctrl.cmd.flags[0];
                input_cmd_ctrl_r.is_load
                    <= ~gemm_ctrl_if.input_read_ctrl.cmd.flags[3];
                input_cmd_ctrl_r.is_last <= 1'b0;
                input_packet_idx_r
                    <= input_packet_fire ? `GEMM_ACC_MAX_CNT'(1) : '0;
                input_cmd_active_r <= 1'b1;
            end else if (input_packet_fire) begin
                input_packet_idx_r <= input_packet_idx_r + 1'b1;
            end else if (gemm_unit_v2_if.last_write) begin
                input_cmd_active_r <= 1'b0;
            end
        end
    end

    // Connect gemm_ctrl_if to DMA ctrl interfaces
    assign input_dma_ctrl_if.start           = gemm_ctrl_if.input_read_ctrl.start && !input_is_notify;
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
        = input_notify_pending_r ? 1'b0 : !input_cmd_active_r;
    assign gemm_ctrl_if.input_read_flag.done
        = input_notify_pending_r ? input_notify_fire
                                 : gemm_unit_v2_if.last_write;

    assign gemm_sync_if[0].valid   = input_notify_pending_r;
    assign gemm_sync_if[0].reg_idx = input_notify_pending_r ? input_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[0].value   = input_notify_pending_r ? input_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        input_notify_pending_r <= 1'b0;
        input_notify_reg_idx_r <= '0;
        input_notify_value_r   <= '0;
      end else begin
        if (input_notify_req) begin
          input_notify_pending_r <= 1'b1;
          input_notify_reg_idx_r <= gemm_ctrl_if.input_read_ctrl.cmd.rs1_data[31:0];
          input_notify_value_r   <= gemm_ctrl_if.input_read_ctrl.cmd.rs2_data[31:0];
        end else if (input_notify_fire) begin
          input_notify_pending_r <= 1'b0;
        end
      end
    end

    // Weight load DMA command mapping.
    assign weight_dma_ctrl_if.start          = gemm_ctrl_if.weight_read_ctrl.start && !weight_is_notify;
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
    assign gemm_ctrl_if.weight_read_flag.idle = weight_notify_pending_r ? 1'b0 : weight_dma_ctrl_if.idle;
    assign gemm_ctrl_if.weight_read_flag.done = weight_notify_pending_r ? weight_notify_fire : weight_dma_ctrl_if.done;

    assign gemm_sync_if[1].valid   = weight_notify_pending_r;
    assign gemm_sync_if[1].reg_idx = weight_notify_pending_r ? weight_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[1].value   = weight_notify_pending_r ? weight_notify_value_r : 32'd0;

	    always_ff @(posedge clk) begin
	      if (reset) begin
	        weight_notify_pending_r <= 1'b0;
	        weight_notify_reg_idx_r <= '0;
        weight_notify_value_r   <= '0;
        weight_cmd_flags_r      <= '0;
      end else begin
        if (weight_notify_req) begin
          weight_notify_pending_r <= 1'b1;
          weight_notify_reg_idx_r <= gemm_ctrl_if.weight_read_ctrl.cmd.rs1_data[31:0];
          weight_notify_value_r   <= gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data[31:0];
        end else if (weight_notify_fire) begin
          weight_notify_pending_r <= 1'b0;
        end
	        // Capture flags when weight DMA starts (FIFO pops same cycle, so cmd changes next cycle)
	        if (weight_dma_start) begin
	          weight_cmd_flags_r <= gemm_ctrl_if.weight_read_ctrl.cmd.flags;
	        end
	      end
	    end

`ifdef DBG_TRACE_GEMM
	    always @(posedge clk) begin
	      if (~reset) begin
	        if (weight_dma_start) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_WEIGHT_DMA_START | {inst=%s, src=0x%0h, stride=%0d, bound=%0d, flags=0x%0h, seg_size=%0d}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data,
	              gemm_ctrl_if.weight_read_ctrl.cmd.stride,
	              gemm_ctrl_if.weight_read_ctrl.cmd.bound,
	              gemm_ctrl_if.weight_read_ctrl.cmd.flags,
	              MXU_KT * (MXU_NT >> 1)))
	        end
	        if (weight_notify_req) begin
	          `TRACE(1, ("%m : [%0t] | GEMM_WEIGHT_NOTIFY_REQ | {inst=%s, reg=%0d, value=0x%0h}\n",
	              $time, INSTANCE_ID,
	              gemm_ctrl_if.weight_read_ctrl.cmd.rs1_data[31:0],
	              gemm_ctrl_if.weight_read_ctrl.cmd.rs2_data[31:0]))
	        end
	      end
	    end
`endif

	    // Quant parameter load DMA command mapping.
    assign quant_param_dma_ctrl_if.start         = gemm_ctrl_if.quant_param_read_ctrl.start && !sz_is_notify;
    assign quant_param_dma_ctrl_if.src_base_addr = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data;

    assign quant_param_dma_ctrl_if.src_strides[0] = gemm_ctrl_if.quant_param_read_ctrl.cmd.stride[31:16];
    assign quant_param_dma_ctrl_if.src_strides[1] = 0;
    assign quant_param_dma_ctrl_if.src_strides[2] = 0;

    assign quant_param_dma_ctrl_if.dst_base_addr  = gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data;

    assign quant_param_dma_ctrl_if.dst_strides[0] = gemm_ctrl_if.quant_param_read_ctrl.cmd.stride[15:0];
    assign quant_param_dma_ctrl_if.dst_strides[1] = 0;
    assign quant_param_dma_ctrl_if.dst_strides[2] = 0;

    assign quant_param_dma_ctrl_if.bounds[0]       = gemm_ctrl_if.quant_param_read_ctrl.cmd.bound;
    assign quant_param_dma_ctrl_if.bounds[1]       = 32'd1;
    assign quant_param_dma_ctrl_if.bounds[2]       = 32'd1;

    assign quant_param_dma_ctrl_if.seg_size        = MXU_NT * 2; // MXU_NT == MXU_KT 의 가정 하에
    assign gemm_ctrl_if.quant_param_read_flag.idle = sz_notify_pending_r ? 1'b0 : quant_param_dma_ctrl_if.idle;
    assign gemm_ctrl_if.quant_param_read_flag.done = sz_notify_pending_r ? sz_notify_fire : quant_param_dma_ctrl_if.done;

    assign gemm_sync_if[2].valid   = sz_notify_pending_r;
    assign gemm_sync_if[2].reg_idx = sz_notify_pending_r ? sz_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[2].value   = sz_notify_pending_r ? sz_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        sz_notify_pending_r <= 1'b0;
        sz_notify_reg_idx_r <= '0;
        sz_notify_value_r   <= '0;
      end else begin
        if (sz_notify_req) begin
          sz_notify_pending_r <= 1'b1;
          sz_notify_reg_idx_r <= gemm_ctrl_if.quant_param_read_ctrl.cmd.rs1_data[31:0];
          sz_notify_value_r   <= gemm_ctrl_if.quant_param_read_ctrl.cmd.rs2_data[31:0];
        end else if (sz_notify_fire) begin
          sz_notify_pending_r <= 1'b0;
        end
      end
    end

    // Output store DMA command mapping.
    assign output_dma_ctrl_if.start         = gemm_ctrl_if.output_write_ctrl.start && !output_is_notify;
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
    assign gemm_ctrl_if.output_write_flag.idle = output_notify_pending_r ? 1'b0 : output_dma_ctrl_if.idle;
    assign gemm_ctrl_if.output_write_flag.done = output_notify_pending_r ? output_notify_fire : output_dma_ctrl_if.done;

    assign gemm_sync_if[3].valid   = output_notify_pending_r;
    assign gemm_sync_if[3].reg_idx = output_notify_pending_r ? output_notify_reg_idx_r : 32'd0;
    assign gemm_sync_if[3].value   = output_notify_pending_r ? output_notify_value_r : 32'd0;

    always_ff @(posedge clk) begin
      if (reset) begin
        output_notify_pending_r <= 1'b0;
        output_notify_reg_idx_r <= '0;
        output_notify_value_r   <= '0;
      end else begin
        if (output_notify_req) begin
          output_notify_pending_r <= 1'b1;
          output_notify_reg_idx_r <= gemm_ctrl_if.output_write_ctrl.cmd.rs1_data[31:0];
          output_notify_value_r   <= gemm_ctrl_if.output_write_ctrl.cmd.rs2_data[31:0];
        end else if (output_notify_fire) begin
          output_notify_pending_r <= 1'b0;
        end
      end
    end

    // External DMA control: VX_gemm_tmem_dma_ctrl translates GEMM DMA
    // commands into VX_config_reg_if writes for the DMA engine.
    assign gemm_dma_ctrl_if.start      = gemm_ctrl_if.dma_ctrl.start;
    assign gemm_dma_ctrl_if.cmd        = gemm_ctrl_if.dma_ctrl.cmd;

    assign gemm_ctrl_if.dma_flag.idle = gemm_dma_ctrl_if.idle;
    assign gemm_ctrl_if.dma_flag.done = gemm_dma_ctrl_if.done;

    // Internal DMA config/done interfaces (driven by tmem_dma_ctrl)
    VX_config_reg_if #(
        .NUM (`DMA_CFG_REG_NUM),
        .DW  (32)
    ) dma_cfg_if [NUM_TMEM_BANKS] ();

    VX_node_done_if dma_done_if [NUM_TMEM_BANKS] ();

    VX_gemm_tmem_dma_ctrl #(
        .INSTANCE_ID  ({INSTANCE_ID, "_tmem_dma_ctrl"}),
        .NUM_CHANNELS (NUM_TMEM_BANKS)
    ) u_tmem_dma_ctrl (
        .clk              (clk),
        .reset            (reset),
        .gemm_dma_ctrl_if (gemm_dma_ctrl_if),
        .store_done       (output_store_done),
        .gemm_sync_if     (gemm_sync_if[4]),
        .cfg_reg_if       (dma_cfg_if),
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

    VX_lmem_dma_ctrl_if tmem_ldma_ctrl_if [4] ();

    // Wire local DMA ctrl interfaces to the array expected by VX_tmem_subsystem
    assign tmem_ldma_ctrl_if[0].start          = input_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[0].src_base_addr  = input_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[0].src_strides    = input_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[0].dst_base_addr  = input_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[0].dst_strides    = input_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[0].bounds         = input_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[0].seg_size       = input_dma_ctrl_if.seg_size;
    assign input_dma_ctrl_if.idle              = tmem_ldma_ctrl_if[0].idle;
    assign input_dma_ctrl_if.done              = tmem_ldma_ctrl_if[0].done;

    assign tmem_ldma_ctrl_if[1].start          = weight_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[1].src_base_addr  = weight_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[1].src_strides    = weight_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[1].dst_base_addr  = weight_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[1].dst_strides    = weight_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[1].bounds         = weight_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[1].seg_size       = weight_dma_ctrl_if.seg_size;
    assign weight_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[1].idle;
    assign weight_dma_ctrl_if.done             = tmem_ldma_ctrl_if[1].done;

    assign tmem_ldma_ctrl_if[2].start          = quant_param_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[2].src_base_addr  = quant_param_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[2].src_strides    = quant_param_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[2].dst_base_addr  = quant_param_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[2].dst_strides    = quant_param_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[2].bounds         = quant_param_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[2].seg_size       = quant_param_dma_ctrl_if.seg_size;
    assign quant_param_dma_ctrl_if.idle        = tmem_ldma_ctrl_if[2].idle;
    assign quant_param_dma_ctrl_if.done        = tmem_ldma_ctrl_if[2].done;

    assign tmem_ldma_ctrl_if[3].start          = output_dma_ctrl_if.start;
    assign tmem_ldma_ctrl_if[3].src_base_addr  = output_dma_ctrl_if.src_base_addr;
    assign tmem_ldma_ctrl_if[3].src_strides    = output_dma_ctrl_if.src_strides;
    assign tmem_ldma_ctrl_if[3].dst_base_addr  = output_dma_ctrl_if.dst_base_addr;
    assign tmem_ldma_ctrl_if[3].dst_strides    = output_dma_ctrl_if.dst_strides;
    assign tmem_ldma_ctrl_if[3].bounds         = output_dma_ctrl_if.bounds;
    assign tmem_ldma_ctrl_if[3].seg_size       = output_dma_ctrl_if.seg_size;
    assign output_dma_ctrl_if.idle             = tmem_ldma_ctrl_if[3].idle;
    assign output_dma_ctrl_if.done             = tmem_ldma_ctrl_if[3].done;

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
      .dma_done_if    (dma_done_if),
      .ldma_ctrl_if   (tmem_ldma_ctrl_if),
      .axi_m          (dma_axi_m),
      .gemm_input_if  (tmem_i_gemm_bus_if),
      .gemm_weight_if (tmem_w_gemm_bus_if),
      .gemm_sz_if     (tmem_sz_gemm_bus_if),
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
      .sz_lmem_bus_if(sz_gemm_bus_if),
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

    // Scale/zero: addr shifted left to convert beat address to byte address
    assign sz_gemm_bus_if.req_valid  = tmem_sz_gemm_bus_if.req_valid;
    assign tmem_sz_gemm_bus_if.req_ready  = sz_gemm_bus_if.req_ready;
    assign tmem_sz_gemm_bus_if.rsp_valid  = sz_gemm_bus_if.rsp_valid;
    assign tmem_sz_gemm_bus_if.rsp_data   = sz_gemm_bus_if.rsp_data;
    assign sz_gemm_bus_if.rsp_ready  = tmem_sz_gemm_bus_if.rsp_ready;

    assign sz_gemm_bus_if.req_data.rw     = tmem_sz_gemm_bus_if.req_data.rw;
    assign sz_gemm_bus_if.req_data.addr   = (tmem_sz_gemm_bus_if.req_data.addr) << (`CLOG2(`GEMM_SCALE_ZERO_DATA_SIZE)); // beat 단위 주소 -> byte 단위 주소
    assign sz_gemm_bus_if.req_data.data   = tmem_sz_gemm_bus_if.req_data.data;
    assign sz_gemm_bus_if.req_data.byteen = tmem_sz_gemm_bus_if.req_data.byteen;
    assign sz_gemm_bus_if.req_data.flags  = tmem_sz_gemm_bus_if.req_data.flags;
    assign sz_gemm_bus_if.req_data.tag    = tmem_sz_gemm_bus_if.req_data.tag;

    // Output: direct connection
    `ASSIGN_VX_MEM_BUS_IF(o_gemm_bus_if, tmem_o_gemm_bus_if);

`ifdef PERF_ENABLE
    gemm_node_perf_t gemm_ctrl_perf;
`endif

    // GEMM top controller
    VX_gemm_ctrl #(
      .INSTANCE_ID(INSTANCE_ID),
      .N_CHILDREN(N_CHILDREN),
      .N_NODE(N_NODE)
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
    //                   On fpint_improve that bus has been split into four
    //                   separate GEMM-unit-facing buses (i/w/sz/o_gemm_bus_if)
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

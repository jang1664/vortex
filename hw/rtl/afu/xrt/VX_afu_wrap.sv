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
//
// Reference: https://www.xilinx.com/developer/articles/porting-rtl-designs-to-vitis-rtl-kernels.html

`include "vortex_afu.vh"

module VX_afu_wrap import VX_gpu_pkg::*; #(
	parameter C_S_AXI_CTRL_ADDR_WIDTH = 8,
	parameter C_S_AXI_CTRL_DATA_WIDTH = 32,
	parameter C_M_AXI_MEM_ID_WIDTH    = `PLATFORM_MEMORY_ID_WIDTH,
	parameter C_M_AXI_MEM_DATA_WIDTH  = `PLATFORM_MEMORY_DATA_SIZE * 8,
	parameter C_M_AXI_MEM_ADDR_WIDTH  = 64,
	parameter C_M_AXI_MEM_NUM_PORTS   = `NUM_DMA_CHANNELS
) (
    // System signals
    input wire clk,
    input wire reset,

    // AXI4 master interface
	`REPEAT (`NUM_DMA_CHANNELS, GEN_AXI_MEM, REPEAT_COMMA),
    // AXI4-Lite slave interface
    input  wire                                 s_axi_ctrl_awvalid,
    output wire                                 s_axi_ctrl_awready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]   s_axi_ctrl_awaddr,

    input  wire                                 s_axi_ctrl_wvalid,
    output wire                                 s_axi_ctrl_wready,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]   s_axi_ctrl_wdata,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH/8-1:0] s_axi_ctrl_wstrb,

    input  wire                                 s_axi_ctrl_arvalid,
    output wire                                 s_axi_ctrl_arready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]   s_axi_ctrl_araddr,

    output wire                                 s_axi_ctrl_rvalid,
    input  wire                                 s_axi_ctrl_rready,
    output wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]   s_axi_ctrl_rdata,
    output wire [1:0]                           s_axi_ctrl_rresp,

    output wire                                 s_axi_ctrl_bvalid,
    input  wire                                 s_axi_ctrl_bready,
    output wire [1:0]                           s_axi_ctrl_bresp,

    output wire                                 interrupt
);
	localparam M_AXI_MEM_ADDR_WIDTH = `PLATFORM_MEMORY_ADDR_WIDTH;

	typedef enum logic [1:0] {
		STATE_IDLE = 0,
		STATE_INIT = 1,
    	STATE_RUN  = 2,
		STATE_DONE = 3
	} state_e;

	localparam PENDING_WR_SIZEW    = 12; // max outstanding requests size
	localparam WR_TRACK_SIZEW      = 32;
	localparam DBG_AFU_MEM_PORT    = (C_M_AXI_MEM_NUM_PORTS > 4) ? 4 : 0;

	wire                                 m_axi_mem_awvalid_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_awready_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]    m_axi_mem_awaddr_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ID_WIDTH-1:0]      m_axi_mem_awid_a [C_M_AXI_MEM_NUM_PORTS];
    wire [7:0]                           m_axi_mem_awlen_a [C_M_AXI_MEM_NUM_PORTS];
    wire [2:0]                           m_axi_mem_awsize_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_awburst_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_awlock_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_awcache_a [C_M_AXI_MEM_NUM_PORTS];
    wire [2:0]                           m_axi_mem_awprot_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_awqos_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_awregion_a [C_M_AXI_MEM_NUM_PORTS];

    wire                                 m_axi_mem_wvalid_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_wready_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_DATA_WIDTH-1:0]    m_axi_mem_wdata_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_DATA_WIDTH/8-1:0]  m_axi_mem_wstrb_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_wlast_a [C_M_AXI_MEM_NUM_PORTS];

    wire                                 m_axi_mem_bvalid_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_bready_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ID_WIDTH-1:0]      m_axi_mem_bid_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_bresp_a [C_M_AXI_MEM_NUM_PORTS];

    wire                                 m_axi_mem_arvalid_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_arready_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]    m_axi_mem_araddr_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ID_WIDTH-1:0]      m_axi_mem_arid_a [C_M_AXI_MEM_NUM_PORTS];
    wire [7:0]                           m_axi_mem_arlen_a [C_M_AXI_MEM_NUM_PORTS];
    wire [2:0]                           m_axi_mem_arsize_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_arburst_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_arlock_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_arcache_a [C_M_AXI_MEM_NUM_PORTS];
    wire [2:0]                           m_axi_mem_arprot_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_arqos_a [C_M_AXI_MEM_NUM_PORTS];
    wire [3:0]                           m_axi_mem_arregion_a [C_M_AXI_MEM_NUM_PORTS];

    wire                                 m_axi_mem_rvalid_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_rready_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_DATA_WIDTH-1:0]    m_axi_mem_rdata_a [C_M_AXI_MEM_NUM_PORTS];
    wire                                 m_axi_mem_rlast_a [C_M_AXI_MEM_NUM_PORTS];
    wire [C_M_AXI_MEM_ID_WIDTH-1:0]      m_axi_mem_rid_a [C_M_AXI_MEM_NUM_PORTS];
    wire [1:0]                           m_axi_mem_rresp_a [C_M_AXI_MEM_NUM_PORTS];

	// convert memory interface to array
	`REPEAT (`NUM_DMA_CHANNELS, AXI_MEM_TO_ARRAY, REPEAT_SEMICOLON);

	reg [`CLOG2(`RESET_DELAY+1)-1:0] vx_reset_ctr;
	wire [PENDING_WR_SIZEW-1:0] vx_pending_writes;
	reg vx_reset; 
	wire vx_busy;
	wire vx_cache_drain;

		wire                         dcr_wr_valid;
		wire [VX_DCR_ADDR_WIDTH-1:0] dcr_wr_addr;
		wire [VX_DCR_DATA_WIDTH-1:0] dcr_wr_data;

	`ifdef ENABLE_HW_DEBUG_MODULE
		wire [31:0] hw_debug_select;
		wire        hw_debug_clear;
		wire        hw_debug_freeze;
		wire [63:0] hw_debug_rdata;
		wire [31:0] hw_debug_status;

		wire                         hw_debug_pc_valid [HW_DEBUG_NUM_PC_SOURCES];
		wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id [HW_DEBUG_NUM_PC_SOURCES];
		wire [NW_WIDTH-1:0]          hw_debug_pc_wid [HW_DEBUG_NUM_PC_SOURCES];
		wire [`XLEN-1:0]             hw_debug_pc [HW_DEBUG_NUM_PC_SOURCES];
		core_pipeline_debug_t        core_pipeline_debug [HW_DEBUG_NUM_PC_SOURCES];
        gemm_unit_debug_t           gemm_unit_debug [HW_DEBUG_NUM_PC_SOURCES];
		cache_debug_t                cache_debug [HW_DEBUG_CACHE_NUM_SOURCES];
	`endif

		state_e state;

	wire ap_reset;
	wire ap_start;
	wire ap_ctrl_read;
	wire ap_idle  = (state == STATE_IDLE);
	wire vx_pending_writes_empty;
`ifdef AFU_DONE_WAIT_CACHE_DRAIN
    localparam USE_APDONE_CACHE_DRAIN =
        (`DCACHE_WRITEBACK == 0) &&
        (`L2_WRITEBACK == 0) &&
        (`L3_WRITEBACK == 0);
`else
    localparam USE_APDONE_CACHE_DRAIN = 0;
`endif

	wire ap_done_base = (state == STATE_DONE) && vx_pending_writes_empty;
	wire ap_done_wait_cache = ap_done_base && USE_APDONE_CACHE_DRAIN && !vx_cache_drain;
	wire ap_done_raw = ap_done_base && (!USE_APDONE_CACHE_DRAIN || vx_cache_drain);

	// Sticky pending bit with Clear-On-Read semantics (HLS AP_CTRL convention).
	// rdata is registered (sampled in RSTATE_DATA) but ap_ctrl_read pulses live
	// in RSTATE_RESP — without a sticky bit, the two can disagree across the
	// RUN→DONE edge: rdata captures ap_done=0 while ap_ctrl_read fires with live
	// ap_done=1, silently consuming DONE and leaving the host polling forever.
	reg ap_done_pending;
	wire ap_done_consumed = ap_ctrl_read && s_axi_ctrl_rdata[1];
	always @(posedge clk) begin
		if (reset || ap_reset) begin
			ap_done_pending <= 1'b0;
		end else if (ap_done_consumed) begin
			ap_done_pending <= 1'b0;
		`ifdef DBG_TRACE_AFU
			`TRACE(2, ("%t: AFU: ap_done consumed by host\n", $time))
		`endif
		end else if (ap_done_raw && !ap_done_pending) begin
			ap_done_pending <= 1'b1;
		`ifdef DBG_TRACE_AFU
			`TRACE(2, ("%t: AFU: ap_done pending latched\n", $time))
		`endif
		end
	end
	wire ap_done = ap_done_pending;
	wire ap_ready = ap_done;

	wire ap_done_ack = ap_done_consumed;

`ifdef SCOPE
	wire scope_bus_in;
	wire scope_bus_out;
  	wire scope_reset = reset;
`endif

	always @(posedge clk) begin
		if (reset || ap_reset) begin
			state    <= STATE_IDLE;
			vx_reset <= 1;
			vx_reset_ctr <= (`RESET_DELAY-1);
		end else begin
			case (state)
			STATE_IDLE: begin
				if (ap_start) begin
				`ifdef DBG_TRACE_AFU
					`TRACE(2, ("%t: AFU: Begin initialization\n", $time))
				`endif
					state <= STATE_INIT;
					vx_reset_ctr <= (`RESET_DELAY-1);
					vx_reset <= 1;
				end
			end
			STATE_INIT: begin
				if (vx_reset) begin
					// wait for reset to complete
					if (vx_reset_ctr == 0) begin
					`ifdef DBG_TRACE_AFU
						`TRACE(2, ("%t: AFU: Initialization completed\n", $time))
					`endif
						vx_reset <= 0;
					end
				end else begin
					// wait until processor goes busy
					if (vx_busy) begin
					`ifdef DBG_TRACE_AFU
						`TRACE(2, ("%t: AFU: Begin execution\n", $time))
					`endif
						state <= STATE_RUN;
					end
				end
			end
			STATE_RUN: begin
				// wait until the processor is not busy
				if (~vx_busy) begin
				`ifdef DBG_TRACE_AFU
					`TRACE(2, ("%t: AFU: Execution completed\n", $time))
				`endif
					state <= STATE_DONE;
				end
			end
			STATE_DONE: begin
				// wait for host's done acknowledgement
				if (ap_done_ack) begin
				`ifdef DBG_TRACE_AFU
					`TRACE(2, ("%t: AFU: Processor idle\n", $time))
				`endif
					state <= STATE_IDLE;
				end
			end
			endcase

			// ensure reset network initialization
			if (vx_reset_ctr != '0) begin
				vx_reset_ctr <= vx_reset_ctr - 1;
			end
		end
	end

	wire [C_M_AXI_MEM_NUM_PORTS-1:0] m_axi_wr_req_fire, m_axi_wr_rsp_fire;
	wire [C_M_AXI_MEM_NUM_PORTS-1:0] m_axi_wr_pending_empty;
	wire [PENDING_WR_SIZEW-1:0] m_axi_wr_pending [C_M_AXI_MEM_NUM_PORTS];
	wire [WR_TRACK_SIZEW-1:0] m_axi_wr_aw_handshake_cnt [C_M_AXI_MEM_NUM_PORTS];
	wire [WR_TRACK_SIZEW-1:0] m_axi_wr_aw_burst_total_cnt [C_M_AXI_MEM_NUM_PORTS];
	wire [WR_TRACK_SIZEW-1:0] m_axi_wr_w_handshake_cnt [C_M_AXI_MEM_NUM_PORTS];
	wire [WR_TRACK_SIZEW-1:0] m_axi_wr_wlast_cnt [C_M_AXI_MEM_NUM_PORTS];
	wire [WR_TRACK_SIZEW-1:0] m_axi_wr_b_handshake_cnt [C_M_AXI_MEM_NUM_PORTS];
	wire m_axi_wr_track_reset = reset || ap_reset || (state == STATE_IDLE && ap_start);

	for (genvar i = 0; i < C_M_AXI_MEM_NUM_PORTS; ++i) begin : g_m_axi_wr_req_fire
		VX_axi_write_drain #(
			.COUNT_WIDTH   (WR_TRACK_SIZEW),
			.PENDING_WIDTH (PENDING_WR_SIZEW)
		) axi_write_drain (
			.clk                (clk),
			.reset              (m_axi_wr_track_reset),
			.awvalid            (m_axi_mem_awvalid_a[i]),
			.awready            (m_axi_mem_awready_a[i]),
			.awlen              (m_axi_mem_awlen_a[i]),
			.wvalid             (m_axi_mem_wvalid_a[i]),
			.wready             (m_axi_mem_wready_a[i]),
			.wlast              (m_axi_mem_wlast_a[i]),
			.bvalid             (m_axi_mem_bvalid_a[i]),
			.bready             (m_axi_mem_bready_a[i]),
			.aw_fire            (m_axi_wr_req_fire[i]),
			`UNUSED_PIN (w_fire),
			`UNUSED_PIN (wlast_fire),
			.b_fire             (m_axi_wr_rsp_fire[i]),
			.pending_empty      (m_axi_wr_pending_empty[i]),
			.aw_handshake_cnt   (m_axi_wr_aw_handshake_cnt[i]),
			.aw_burst_total_cnt (m_axi_wr_aw_burst_total_cnt[i]),
			.w_handshake_cnt    (m_axi_wr_w_handshake_cnt[i]),
			.wlast_cnt          (m_axi_wr_wlast_cnt[i]),
			.b_handshake_cnt    (m_axi_wr_b_handshake_cnt[i]),
			.pending_writes     (m_axi_wr_pending[i])
        );
	end

	assign vx_pending_writes_empty = &m_axi_wr_pending_empty;

	reg [PENDING_WR_SIZEW-1:0] vx_pending_writes_r;
	integer pending_i;
	always @(*) begin
		vx_pending_writes_r = '0;
		for (pending_i = 0; pending_i < C_M_AXI_MEM_NUM_PORTS; pending_i = pending_i + 1) begin
			vx_pending_writes_r = vx_pending_writes_r + m_axi_wr_pending[pending_i];
		end
	end
	assign vx_pending_writes = vx_pending_writes_r;

	VX_afu_ctrl #(
		.S_AXI_ADDR_WIDTH (C_S_AXI_CTRL_ADDR_WIDTH),
		.S_AXI_DATA_WIDTH (C_S_AXI_CTRL_DATA_WIDTH)
	) afu_ctrl (
		.clk       		(clk),
		.reset     		(reset),

		.s_axi_awvalid  (s_axi_ctrl_awvalid),
		.s_axi_awready  (s_axi_ctrl_awready),
		.s_axi_awaddr   (s_axi_ctrl_awaddr),

		.s_axi_wvalid   (s_axi_ctrl_wvalid),
		.s_axi_wready   (s_axi_ctrl_wready),
		.s_axi_wdata    (s_axi_ctrl_wdata),
		.s_axi_wstrb    (s_axi_ctrl_wstrb),

		.s_axi_arvalid  (s_axi_ctrl_arvalid),
		.s_axi_arready  (s_axi_ctrl_arready),
		.s_axi_araddr   (s_axi_ctrl_araddr),

		.s_axi_rvalid   (s_axi_ctrl_rvalid),
		.s_axi_rready   (s_axi_ctrl_rready),
		.s_axi_rdata    (s_axi_ctrl_rdata),
		.s_axi_rresp    (s_axi_ctrl_rresp),

		.s_axi_bvalid   (s_axi_ctrl_bvalid),
		.s_axi_bready   (s_axi_ctrl_bready),
		.s_axi_bresp    (s_axi_ctrl_bresp),

		.ap_reset  		(ap_reset),
		.ap_start  		(ap_start),
		.ap_done     	(ap_done),
		.ap_ready       (ap_ready),
		.ap_idle     	(ap_idle),
		.interrupt 		(interrupt),

		.ap_ctrl_read   (ap_ctrl_read),

		`ifdef SCOPE
			.scope_bus_in   (scope_bus_out),
			.scope_bus_out  (scope_bus_in),
		`endif

		`ifdef ENABLE_HW_DEBUG_MODULE
			.hw_debug_select (hw_debug_select),
			.hw_debug_clear  (hw_debug_clear),
			.hw_debug_freeze (hw_debug_freeze),
			.hw_debug_rdata  (hw_debug_rdata),
			.hw_debug_status (hw_debug_status),
		`endif

			.dcr_wr_valid	(dcr_wr_valid),
			.dcr_wr_addr	(dcr_wr_addr),
			.dcr_wr_data	(dcr_wr_data)
	);

	wire [M_AXI_MEM_ADDR_WIDTH-1:0] m_axi_mem_awaddr_u [C_M_AXI_MEM_NUM_PORTS];
	wire [M_AXI_MEM_ADDR_WIDTH-1:0] m_axi_mem_araddr_u [C_M_AXI_MEM_NUM_PORTS];

	for (genvar i = 0; i < C_M_AXI_MEM_NUM_PORTS; ++i) begin : g_addressing
		assign m_axi_mem_awaddr_a[i] = C_M_AXI_MEM_ADDR_WIDTH'(m_axi_mem_awaddr_u[i]) + C_M_AXI_MEM_ADDR_WIDTH'(`PLATFORM_MEMORY_OFFSET);
		assign m_axi_mem_araddr_a[i] = C_M_AXI_MEM_ADDR_WIDTH'(m_axi_mem_araddr_u[i]) + C_M_AXI_MEM_ADDR_WIDTH'(`PLATFORM_MEMORY_OFFSET);
	end

	`SCOPE_IO_SWITCH (2);

	Vortex_axi #(
		.AXI_DATA_WIDTH (C_M_AXI_MEM_DATA_WIDTH),
		.AXI_ADDR_WIDTH (M_AXI_MEM_ADDR_WIDTH),
		.AXI_TID_WIDTH  (C_M_AXI_MEM_ID_WIDTH),
		.NUM_HBM_PORTS  (C_M_AXI_MEM_NUM_PORTS)
	) vortex_axi (
		`SCOPE_IO_BIND  (1)

		.clk			(clk),
		.reset			(vx_reset),

		.m_axi_awvalid	(m_axi_mem_awvalid_a),
		.m_axi_awready	(m_axi_mem_awready_a),
		.m_axi_awaddr	(m_axi_mem_awaddr_u),
		.m_axi_awid		(m_axi_mem_awid_a),
		.m_axi_awlen    (m_axi_mem_awlen_a),
		.m_axi_awsize   (m_axi_mem_awsize_a),
		.m_axi_awburst  (m_axi_mem_awburst_a),
		.m_axi_awlock   (m_axi_mem_awlock_a),
		.m_axi_awcache  (m_axi_mem_awcache_a),
		.m_axi_awprot   (m_axi_mem_awprot_a),
		.m_axi_awqos    (m_axi_mem_awqos_a),
		.m_axi_awregion (m_axi_mem_awregion_a),

		.m_axi_wvalid	(m_axi_mem_wvalid_a),
		.m_axi_wready	(m_axi_mem_wready_a),
		.m_axi_wdata	(m_axi_mem_wdata_a),
		.m_axi_wstrb	(m_axi_mem_wstrb_a),
		.m_axi_wlast	(m_axi_mem_wlast_a),

		.m_axi_bvalid	(m_axi_mem_bvalid_a),
		.m_axi_bready	(m_axi_mem_bready_a),
		.m_axi_bid		(m_axi_mem_bid_a),
		.m_axi_bresp	(m_axi_mem_bresp_a),

		.m_axi_arvalid	(m_axi_mem_arvalid_a),
		.m_axi_arready	(m_axi_mem_arready_a),
		.m_axi_araddr	(m_axi_mem_araddr_u),
		.m_axi_arid		(m_axi_mem_arid_a),
		.m_axi_arlen	(m_axi_mem_arlen_a),
		.m_axi_arsize   (m_axi_mem_arsize_a),
		.m_axi_arburst  (m_axi_mem_arburst_a),
		.m_axi_arlock   (m_axi_mem_arlock_a),
		.m_axi_arcache  (m_axi_mem_arcache_a),
		.m_axi_arprot   (m_axi_mem_arprot_a),
		.m_axi_arqos    (m_axi_mem_arqos_a),
		.m_axi_arregion (m_axi_mem_arregion_a),

		.m_axi_rvalid	(m_axi_mem_rvalid_a),
		.m_axi_rready	(m_axi_mem_rready_a),
		.m_axi_rdata	(m_axi_mem_rdata_a),
		.m_axi_rlast	(m_axi_mem_rlast_a),
		.m_axi_rid    	(m_axi_mem_rid_a),
		.m_axi_rresp	(m_axi_mem_rresp_a),

			.dcr_wr_valid	(dcr_wr_valid),
			.dcr_wr_addr	(dcr_wr_addr),
			.dcr_wr_data	(dcr_wr_data),

		`ifdef ENABLE_HW_DEBUG_MODULE
			.hw_debug_pc_valid   (hw_debug_pc_valid),
			.hw_debug_pc_core_id (hw_debug_pc_core_id),
			.hw_debug_pc_wid     (hw_debug_pc_wid),
			.hw_debug_pc         (hw_debug_pc),
			.core_pipeline_debug (core_pipeline_debug),
            .gemm_unit_debug     (gemm_unit_debug),
			.cache_debug         (cache_debug),
		`endif

			.busy			(vx_busy),
			.cache_drain	(vx_cache_drain)
		);

	`ifdef ENABLE_HW_DEBUG_MODULE
		VX_hw_debug #(
			.NUM_AXI_PORTS     (C_M_AXI_MEM_NUM_PORTS),
			.AXI_ADDR_WIDTH    (C_M_AXI_MEM_ADDR_WIDTH),
			.AXI_ID_WIDTH      (C_M_AXI_MEM_ID_WIDTH),
			.PENDING_WR_SIZEW  (PENDING_WR_SIZEW),
			.WR_TRACK_SIZEW    (WR_TRACK_SIZEW)
		) hw_debug (
			.clk                (clk),
			.reset              (reset || ap_reset),
			.debug_select       (hw_debug_select),
			.debug_clear        (hw_debug_clear),
			.debug_freeze       (hw_debug_freeze),
			.debug_rdata        (hw_debug_rdata),
			.debug_status       (hw_debug_status),

			.ap_reset           (ap_reset),
			.ap_start           (ap_start),
			.ap_done            (ap_done),
			.ap_idle            (ap_idle),
			.ap_ready           (ap_ready),
			.ap_state           (state),
			.ap_done_base       (ap_done_base),
			.ap_done_wait_cache (ap_done_wait_cache),
			.vx_busy            (vx_busy),
			.vx_cache_drain     (vx_cache_drain),
			.vx_pending_writes  (vx_pending_writes),
			.vx_pending_writes_empty (vx_pending_writes_empty),

			.hw_debug_pc_valid   (hw_debug_pc_valid),
			.hw_debug_pc_core_id (hw_debug_pc_core_id),
			.hw_debug_pc_wid     (hw_debug_pc_wid),
			.hw_debug_pc         (hw_debug_pc),
			.core_pipeline_debug (core_pipeline_debug),
            .gemm_unit_debug     (gemm_unit_debug),
			.cache_debug         (cache_debug),

			.s_axi_ctrl_awvalid (s_axi_ctrl_awvalid),
			.s_axi_ctrl_awready (s_axi_ctrl_awready),
			.s_axi_ctrl_awaddr  (s_axi_ctrl_awaddr[7:0]),
			.s_axi_ctrl_wvalid  (s_axi_ctrl_wvalid),
			.s_axi_ctrl_wready  (s_axi_ctrl_wready),
			.s_axi_ctrl_wdata   (s_axi_ctrl_wdata),
			.s_axi_ctrl_wstrb   (s_axi_ctrl_wstrb),
			.s_axi_ctrl_bvalid  (s_axi_ctrl_bvalid),
			.s_axi_ctrl_bready  (s_axi_ctrl_bready),
			.s_axi_ctrl_bresp   (s_axi_ctrl_bresp),
			.s_axi_ctrl_arvalid (s_axi_ctrl_arvalid),
			.s_axi_ctrl_arready (s_axi_ctrl_arready),
			.s_axi_ctrl_araddr  (s_axi_ctrl_araddr[7:0]),
			.s_axi_ctrl_rvalid  (s_axi_ctrl_rvalid),
			.s_axi_ctrl_rready  (s_axi_ctrl_rready),
			.s_axi_ctrl_rdata   (s_axi_ctrl_rdata),
			.s_axi_ctrl_rresp   (s_axi_ctrl_rresp),

			.m_axi_awvalid      (m_axi_mem_awvalid_a),
			.m_axi_awready      (m_axi_mem_awready_a),
			.m_axi_awaddr       (m_axi_mem_awaddr_a),
			.m_axi_awid         (m_axi_mem_awid_a),
			.m_axi_awlen        (m_axi_mem_awlen_a),
			.m_axi_wvalid       (m_axi_mem_wvalid_a),
			.m_axi_wready       (m_axi_mem_wready_a),
			.m_axi_wlast        (m_axi_mem_wlast_a),
			.m_axi_bvalid       (m_axi_mem_bvalid_a),
			.m_axi_bready       (m_axi_mem_bready_a),
			.m_axi_bid          (m_axi_mem_bid_a),
			.m_axi_bresp        (m_axi_mem_bresp_a),
			.m_axi_arvalid      (m_axi_mem_arvalid_a),
			.m_axi_arready      (m_axi_mem_arready_a),
			.m_axi_araddr       (m_axi_mem_araddr_a),
			.m_axi_arid         (m_axi_mem_arid_a),
			.m_axi_arlen        (m_axi_mem_arlen_a),
			.m_axi_rvalid       (m_axi_mem_rvalid_a),
			.m_axi_rready       (m_axi_mem_rready_a),
			.m_axi_rlast        (m_axi_mem_rlast_a),
			.m_axi_rid          (m_axi_mem_rid_a),
			.m_axi_rresp        (m_axi_mem_rresp_a),
			.m_axi_wr_req_fire  (m_axi_wr_req_fire),
			.m_axi_wr_pending_empty (m_axi_wr_pending_empty),
			.m_axi_wr_aw_handshake_cnt (m_axi_wr_aw_handshake_cnt),
			.m_axi_wr_aw_burst_total_cnt (m_axi_wr_aw_burst_total_cnt),
			.m_axi_wr_w_handshake_cnt (m_axi_wr_w_handshake_cnt),
			.m_axi_wr_wlast_cnt (m_axi_wr_wlast_cnt),
			.m_axi_wr_b_handshake_cnt (m_axi_wr_b_handshake_cnt)
		);
	`endif

	    // SCOPE //////////////////////////////////////////////////////////////////////

`ifdef SCOPE
`ifdef DBG_SCOPE_AFU
	wire m_axi_mem_awfire_dbg = m_axi_mem_awvalid_a[DBG_AFU_MEM_PORT] & m_axi_mem_awready_a[DBG_AFU_MEM_PORT];
	wire m_axi_mem_arfire_dbg = m_axi_mem_arvalid_a[DBG_AFU_MEM_PORT] & m_axi_mem_arready_a[DBG_AFU_MEM_PORT];
	wire m_axi_mem_wfire_dbg  = m_axi_mem_wvalid_a[DBG_AFU_MEM_PORT]  & m_axi_mem_wready_a[DBG_AFU_MEM_PORT];
	wire m_axi_mem_bfire_dbg  = m_axi_mem_bvalid_a[DBG_AFU_MEM_PORT]  & m_axi_mem_bready_a[DBG_AFU_MEM_PORT];
	wire reset_negedge;
	`NEG_EDGE (reset_negedge, reset);
	`SCOPE_TAP (0, 0, {
			ap_reset,
			ap_start,
			ap_done,
			ap_done_base,
			ap_done_wait_cache,
			ap_idle,
			interrupt,
			vx_reset,
			vx_busy,
			vx_cache_drain,
			state,
			m_axi_mem_awvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_awready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_wvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_wready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rready_a[DBG_AFU_MEM_PORT]
		}, {
			dcr_wr_valid,
			m_axi_mem_awfire_dbg,
			m_axi_mem_arfire_dbg,
			m_axi_mem_wfire_dbg,
			m_axi_mem_bfire_dbg
		}, {
			dcr_wr_addr,
			dcr_wr_data,
			vx_pending_writes,
			m_axi_mem_awaddr_u[DBG_AFU_MEM_PORT],
			m_axi_mem_awid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_araddr_u[DBG_AFU_MEM_PORT],
			m_axi_mem_arid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rid_a[DBG_AFU_MEM_PORT]
		},
		reset_negedge, 1'b0, 4096
	);
`else
    `SCOPE_IO_UNUSED(0)
`endif
`endif

`ifdef CHIPSCOPE
`ifdef DBG_SCOPE_AFU
	    ila_afu ila_afu_inst (
      	.clk (clk),
		.probe0 ({
			ap_reset,
        	ap_start,
        	ap_done,
			ap_done_base,
			ap_done_wait_cache,
			ap_idle,
			interrupt,
			vx_reset,
			vx_busy,
			vx_cache_drain,
			state,
			s_axi_ctrl_awvalid,
			s_axi_ctrl_awready,
			s_axi_ctrl_wvalid,
			s_axi_ctrl_wready,
			s_axi_ctrl_arvalid,
			s_axi_ctrl_arready,
			s_axi_ctrl_rvalid,
			s_axi_ctrl_rready,
			m_axi_wr_req_fire[DBG_AFU_MEM_PORT],
			m_axi_wr_rsp_fire[DBG_AFU_MEM_PORT],
			m_axi_mem_awvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_awready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_wvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_wready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_wlast_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rvalid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rready_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rlast_a[DBG_AFU_MEM_PORT]
		}),
		.probe1 ({
			m_axi_mem_awaddr_u[DBG_AFU_MEM_PORT][31:0],
			m_axi_mem_araddr_u[DBG_AFU_MEM_PORT][31:0],
			m_axi_mem_awlen_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arlen_a[DBG_AFU_MEM_PORT],
			m_axi_mem_awid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_arid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rid_a[DBG_AFU_MEM_PORT],
			m_axi_mem_bresp_a[DBG_AFU_MEM_PORT],
			m_axi_mem_rresp_a[DBG_AFU_MEM_PORT]
		}),
		.probe2 ({
			vx_pending_writes,
			dcr_wr_valid,
			dcr_wr_addr,
			dcr_wr_data,
			s_axi_ctrl_awaddr,
			s_axi_ctrl_wdata,
			s_axi_ctrl_wstrb,
			s_axi_ctrl_araddr,
			s_axi_ctrl_rdata,
			s_axi_ctrl_rresp,
			s_axi_ctrl_bresp
		})
    );
`endif
`endif

`ifdef SIMULATION
`ifndef VERILATOR
	// disable assertions until full reset
	reg [`CLOG2(`RESET_DELAY+1)-1:0] assert_delay_ctr;
	reg assert_enabled;
	initial begin
		$assertoff(0, vortex_axi);
	end
	always @(posedge clk) begin
		if (reset) begin
			assert_delay_ctr <= '0;
			assert_enabled   <= 0;
		end else begin
			if (~assert_enabled) begin
				if (assert_delay_ctr == (`RESET_DELAY-1)) begin
					assert_enabled <= 1;
					$asserton(0, vortex_axi); // enable assertions
				end else begin
					assert_delay_ctr <= assert_delay_ctr + 1;
				end
			end
		end
	end
`endif
`endif

`ifdef DBG_TRACE_AFU
    always @(posedge clk) begin
		for (integer i = 0; i < C_M_AXI_MEM_NUM_PORTS; ++i) begin
			if (m_axi_mem_awvalid_a[i] && m_axi_mem_awready_a[i]) begin
				`TRACE(2, ("%t: AXI Wr Req [%0d]: addr=0x%0h, id=0x%0h\n", $time, i, m_axi_mem_awaddr_a[i], m_axi_mem_awid_a[i]))
			end
			if (m_axi_mem_wvalid_a[i] && m_axi_mem_wready_a[i]) begin
				`TRACE(2, ("%t: AXI Wr Req [%0d]: strb=0x%h, data=0x%h\n", $time, i, m_axi_mem_wstrb_a[i], m_axi_mem_wdata_a[i]))
			end
			if (m_axi_mem_bvalid_a[i] && m_axi_mem_bready_a[i]) begin
				`TRACE(2, ("%t: AXI Wr Rsp [%0d]: id=0x%0h\n", $time, i, m_axi_mem_bid_a[i]))
			end
			if (m_axi_mem_arvalid_a[i] && m_axi_mem_arready_a[i]) begin
				`TRACE(2, ("%t: AXI Rd Req [%0d]: addr=0x%0h, id=0x%0h\n", $time, i, m_axi_mem_araddr_a[i], m_axi_mem_arid_a[i]))
			end
			if (m_axi_mem_rvalid_a[i] && m_axi_mem_rready_a[i]) begin
				`TRACE(2, ("%t: AXI Rd Rsp [%0d]: data=0x%h, id=0x%0h\n", $time, i, m_axi_mem_rdata_a[i], m_axi_mem_rid_a[i]))
			end
		end
  	end
`endif

endmodule

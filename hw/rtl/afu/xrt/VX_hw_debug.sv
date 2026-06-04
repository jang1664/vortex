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

`ifndef HW_DEBUG_PC_RING_DEPTH
`define HW_DEBUG_PC_RING_DEPTH 16
`endif

`ifndef HW_DEBUG_PC_SAMPLE_LOG2
`define HW_DEBUG_PC_SAMPLE_LOG2 10
`endif

module VX_hw_debug import VX_gpu_pkg::*; #(
    parameter NUM_AXI_PORTS    = `NUM_DMA_CHANNELS,
    parameter AXI_ADDR_WIDTH   = 64,
    parameter AXI_ID_WIDTH     = `PLATFORM_MEMORY_ID_WIDTH,
    parameter PENDING_WR_SIZEW = 12,
    parameter PC_RING_DEPTH    = `HW_DEBUG_PC_RING_DEPTH,
    parameter PC_SAMPLE_LOG2   = `HW_DEBUG_PC_SAMPLE_LOG2
) (
    input  wire                             clk,
    input  wire                             reset,

    input  wire [31:0]                      debug_select,
    input  wire                             debug_clear,
    input  wire                             debug_freeze,
    output reg  [63:0]                      debug_rdata,
    output wire [31:0]                      debug_status,

    input  wire                             ap_reset,
    input  wire                             ap_start,
    input  wire                             ap_done,
    input  wire                             ap_idle,
    input  wire                             ap_ready,
    input  wire [1:0]                       ap_state,
    input  wire                             ap_done_base,
    input  wire                             ap_done_wait_cache,
    input  wire                             vx_busy,
    input  wire                             vx_cache_drain,
    input  wire [PENDING_WR_SIZEW-1:0]      vx_pending_writes,

    input  wire                             hw_debug_pc_valid [HW_DEBUG_NUM_PC_SOURCES],
    input  wire [HW_DEBUG_CORE_ID_WIDTH-1:0] hw_debug_pc_core_id [HW_DEBUG_NUM_PC_SOURCES],
    input  wire [NW_WIDTH-1:0]              hw_debug_pc_wid [HW_DEBUG_NUM_PC_SOURCES],
    input  wire [`XLEN-1:0]                 hw_debug_pc [HW_DEBUG_NUM_PC_SOURCES],

    input  wire                             s_axi_ctrl_awvalid,
    input  wire                             s_axi_ctrl_awready,
    input  wire [7:0]                       s_axi_ctrl_awaddr,
    input  wire                             s_axi_ctrl_wvalid,
    input  wire                             s_axi_ctrl_wready,
    input  wire [31:0]                      s_axi_ctrl_wdata,
    input  wire [3:0]                       s_axi_ctrl_wstrb,
    input  wire                             s_axi_ctrl_bvalid,
    input  wire                             s_axi_ctrl_bready,
    input  wire [1:0]                       s_axi_ctrl_bresp,
    input  wire                             s_axi_ctrl_arvalid,
    input  wire                             s_axi_ctrl_arready,
    input  wire [7:0]                       s_axi_ctrl_araddr,
    input  wire                             s_axi_ctrl_rvalid,
    input  wire                             s_axi_ctrl_rready,
    input  wire [31:0]                      s_axi_ctrl_rdata,
    input  wire [1:0]                       s_axi_ctrl_rresp,

    input  wire                             m_axi_awvalid [NUM_AXI_PORTS],
    input  wire                             m_axi_awready [NUM_AXI_PORTS],
    input  wire [AXI_ADDR_WIDTH-1:0]        m_axi_awaddr [NUM_AXI_PORTS],
    input  wire [AXI_ID_WIDTH-1:0]          m_axi_awid [NUM_AXI_PORTS],
    input  wire [7:0]                       m_axi_awlen [NUM_AXI_PORTS],
    input  wire                             m_axi_wvalid [NUM_AXI_PORTS],
    input  wire                             m_axi_wready [NUM_AXI_PORTS],
    input  wire                             m_axi_wlast [NUM_AXI_PORTS],
    input  wire                             m_axi_bvalid [NUM_AXI_PORTS],
    input  wire                             m_axi_bready [NUM_AXI_PORTS],
    input  wire [AXI_ID_WIDTH-1:0]          m_axi_bid [NUM_AXI_PORTS],
    input  wire [1:0]                       m_axi_bresp [NUM_AXI_PORTS],
    input  wire                             m_axi_arvalid [NUM_AXI_PORTS],
    input  wire                             m_axi_arready [NUM_AXI_PORTS],
    input  wire [AXI_ADDR_WIDTH-1:0]        m_axi_araddr [NUM_AXI_PORTS],
    input  wire [AXI_ID_WIDTH-1:0]          m_axi_arid [NUM_AXI_PORTS],
    input  wire [7:0]                       m_axi_arlen [NUM_AXI_PORTS],
    input  wire                             m_axi_rvalid [NUM_AXI_PORTS],
    input  wire                             m_axi_rready [NUM_AXI_PORTS],
    input  wire                             m_axi_rlast [NUM_AXI_PORTS],
    input  wire [AXI_ID_WIDTH-1:0]          m_axi_rid [NUM_AXI_PORTS],
    input  wire [1:0]                       m_axi_rresp [NUM_AXI_PORTS],
    input  wire [NUM_AXI_PORTS-1:0]         m_axi_wr_req_fire
);

    localparam PC_RING_ADDRW = `UP(`CLOG2(PC_RING_DEPTH));
    localparam AXI_PORTW = `UP(`CLOG2(NUM_AXI_PORTS));
    localparam PC_SOURCEW = `UP(`CLOG2(HW_DEBUG_NUM_PC_SOURCES));
    localparam AXI_ADDR_LOG_BITS = `MIN(AXI_ADDR_WIDTH, 48);
    localparam AXI_PORT_COUNTW = `UP(`CLOG2(NUM_AXI_PORTS + 1));

    `VX_STATIC_ASSERT(`IS_POW2(PC_RING_DEPTH), ("PC_RING_DEPTH must be a power of 2"))
    `VX_STATIC_ASSERT(PC_SAMPLE_LOG2 > 0, ("PC_SAMPLE_LOG2 must be greater than zero"))

    localparam DBG_ID              = 8'h00;
    localparam DBG_AFU_STATUS      = 8'h01;
    localparam DBG_CYCLE_COUNT     = 8'h02;
    localparam DBG_PC_EVENT_COUNT  = 8'h03;
    localparam DBG_PC_LAST_META    = 8'h04;
    localparam DBG_PC_LAST_VALUE   = 8'h05;
    localparam DBG_PC_SAME_COUNT   = 8'h06;
    localparam DBG_PC_HASH         = 8'h07;
    localparam DBG_PC_RING_META    = 8'h08;
    localparam DBG_PC_RING_VALUE   = 8'h09;
    localparam DBG_ANOMALY_FLAGS   = 8'h0a;
    localparam DBG_ANOMALY_CYCLES  = 8'h0b;

    localparam DBG_AXI_AW_FIRE     = 8'h10;
    localparam DBG_AXI_W_FIRE      = 8'h11;
    localparam DBG_AXI_B_FIRE      = 8'h12;
    localparam DBG_AXI_AR_FIRE     = 8'h13;
    localparam DBG_AXI_R_FIRE      = 8'h14;
    localparam DBG_AXI_AW_STALL    = 8'h15;
    localparam DBG_AXI_W_STALL     = 8'h16;
    localparam DBG_AXI_B_STALL     = 8'h17;
    localparam DBG_AXI_AR_STALL    = 8'h18;
    localparam DBG_AXI_R_STALL     = 8'h19;
    localparam DBG_AXI_RD_OUTSTAND = 8'h1a;
    localparam DBG_AXI_WR_OUTSTAND = 8'h1b;
    localparam DBG_AXI_LAST_AW     = 8'h1c;
    localparam DBG_AXI_LAST_AR     = 8'h1d;
    localparam DBG_AXI_LAST_B      = 8'h1e;
    localparam DBG_AXI_LAST_R      = 8'h1f;
    localparam DBG_AXI_ERRORS      = 8'h20;
    localparam DBG_AXI_FLAGS       = 8'h21;

    localparam DBG_CTRL_STATUS     = 8'h30;
    localparam DBG_CTRL_COUNTS     = 8'h31;
    localparam DBG_CTRL_LAST_WRITE = 8'h32;
    localparam DBG_CTRL_LAST_READ  = 8'h33;
    localparam DBG_CTRL_FLAGS      = 8'h34;

    localparam GLB_FLAG_PENDING_SIGN      = 1;
    localparam GLB_FLAG_PENDING_UNDERFLOW = 2;
    localparam GLB_FLAG_PENDING_OVERFLOW  = 3;
    localparam GLB_FLAG_CTRL_PROTOCOL     = 4;
    localparam GLB_FLAG_AXI_PROTOCOL      = 5;
    localparam GLB_FLAG_CTRL_RESP_ERROR   = 6;
    localparam GLB_FLAG_AXI_RESP_ERROR    = 7;

    localparam CTRL_FLAG_AW_STABLE    = 0;
    localparam CTRL_FLAG_W_STABLE     = 1;
    localparam CTRL_FLAG_B_STABLE     = 2;
    localparam CTRL_FLAG_AR_STABLE    = 3;
    localparam CTRL_FLAG_R_STABLE     = 4;
    localparam CTRL_FLAG_B_UNDERFLOW  = 5;
    localparam CTRL_FLAG_R_UNDERFLOW  = 6;
    localparam CTRL_FLAG_BRESP_ERROR  = 7;
    localparam CTRL_FLAG_RRESP_ERROR  = 8;

    localparam AXI_FLAG_AW_STABLE    = 0;
    localparam AXI_FLAG_W_STABLE     = 1;
    localparam AXI_FLAG_B_STABLE     = 2;
    localparam AXI_FLAG_AR_STABLE    = 3;
    localparam AXI_FLAG_R_STABLE     = 4;
    localparam AXI_FLAG_B_UNDERFLOW  = 5;
    localparam AXI_FLAG_R_UNDERFLOW  = 6;
    localparam AXI_FLAG_BRESP_ERROR  = 7;
    localparam AXI_FLAG_RRESP_ERROR  = 8;

    wire [7:0] metric_id = debug_select[7:0];
    wire [7:0] port_id = debug_select[15:8];
    wire [7:0] ring_id = debug_select[23:16];
    wire [AXI_PORTW-1:0] port_idx = AXI_PORTW'(port_id);
    wire [PC_RING_ADDRW-1:0] ring_idx = PC_RING_ADDRW'(ring_id);
    wire port_valid = (port_id < NUM_AXI_PORTS);
    wire ring_valid = (ring_id < PC_RING_DEPTH);

    reg [63:0] cycle_count;

    reg [PC_SOURCEW-1:0] pc_source_rr;
    reg [63:0] pc_event_count;
    reg [63:0] pc_sample_count;
    reg [63:0] pc_same_count;
    reg [63:0] pc_hash;
    reg [PC_SAMPLE_LOG2-1:0] pc_sample_ctr;
    reg [PC_RING_ADDRW-1:0] pc_ring_wptr;

    reg                         pc_last_valid;
    reg [HW_DEBUG_CORE_ID_WIDTH-1:0] pc_last_core_id;
    reg [NW_WIDTH-1:0]          pc_last_wid;
    reg [`XLEN-1:0]             pc_last_pc;
    reg [63:0]                  pc_last_cycle;

    reg                         pc_ring_valid [PC_RING_DEPTH];
    reg [HW_DEBUG_CORE_ID_WIDTH-1:0] pc_ring_core_id [PC_RING_DEPTH];
    reg [NW_WIDTH-1:0]          pc_ring_wid [PC_RING_DEPTH];
    reg [`XLEN-1:0]             pc_ring_pc [PC_RING_DEPTH];
    reg [63:0]                  pc_ring_cycle [PC_RING_DEPTH];

    reg                         pc_event_valid;
    reg [PC_SOURCEW-1:0]        pc_event_src;
    reg [HW_DEBUG_CORE_ID_WIDTH-1:0] pc_event_core_id;
    reg [NW_WIDTH-1:0]          pc_event_wid;
    reg [`XLEN-1:0]             pc_event_pc;

    integer pc_sel_offset;
    integer pc_sel_candidate;
    always @(*) begin
        pc_event_valid   = 1'b0;
        pc_event_src     = '0;
        pc_event_core_id = '0;
        pc_event_wid     = '0;
        pc_event_pc      = '0;
        for (pc_sel_offset = 0; pc_sel_offset < HW_DEBUG_NUM_PC_SOURCES; pc_sel_offset = pc_sel_offset + 1) begin
            pc_sel_candidate = pc_source_rr + pc_sel_offset;
            if (pc_sel_candidate >= HW_DEBUG_NUM_PC_SOURCES) begin
                pc_sel_candidate = pc_sel_candidate - HW_DEBUG_NUM_PC_SOURCES;
            end
            if (!pc_event_valid && hw_debug_pc_valid[pc_sel_candidate]) begin
                pc_event_valid   = 1'b1;
                pc_event_src     = PC_SOURCEW'(pc_sel_candidate);
                pc_event_core_id = hw_debug_pc_core_id[pc_sel_candidate];
                pc_event_wid     = hw_debug_pc_wid[pc_sel_candidate];
                pc_event_pc      = hw_debug_pc[pc_sel_candidate];
            end
        end
    end

    wire s_axi_ctrl_aw_fire = s_axi_ctrl_awvalid && s_axi_ctrl_awready;
    wire s_axi_ctrl_w_fire  = s_axi_ctrl_wvalid && s_axi_ctrl_wready;
    wire s_axi_ctrl_b_fire  = s_axi_ctrl_bvalid && s_axi_ctrl_bready;
    wire s_axi_ctrl_ar_fire = s_axi_ctrl_arvalid && s_axi_ctrl_arready;
    wire s_axi_ctrl_r_fire  = s_axi_ctrl_rvalid && s_axi_ctrl_rready;

    reg [63:0] ctrl_aw_fire_count;
    reg [63:0] ctrl_w_fire_count;
    reg [63:0] ctrl_b_fire_count;
    reg [63:0] ctrl_ar_fire_count;
    reg [63:0] ctrl_r_fire_count;
    reg [63:0] ctrl_stall_count;
    reg [63:0] ctrl_error_count;
    reg [63:0] ctrl_last_write;
    reg [63:0] ctrl_last_read;
    reg [63:0] ctrl_flags;
    reg [63:0] global_anomaly_flags;
    reg [63:0] anomaly_first_cycle;
    reg [63:0] anomaly_last_cycle;
    reg [7:0]  ctrl_aw_pending;
    reg [7:0]  ctrl_w_pending;
    reg [7:0]  ctrl_b_pending;
    reg [7:0]  ctrl_r_pending;
    reg        ctrl_aw_stalled;
    reg        ctrl_w_stalled;
    reg        ctrl_b_stalled;
    reg        ctrl_ar_stalled;
    reg        ctrl_r_stalled;
    reg [7:0]  ctrl_awaddr_hold;
    reg [31:0] ctrl_wdata_hold;
    reg [3:0]  ctrl_wstrb_hold;
    reg [1:0]  ctrl_bresp_hold;
    reg [7:0]  ctrl_araddr_hold;
    reg [31:0] ctrl_rdata_hold;
    reg [1:0]  ctrl_rresp_hold;

    reg [63:0] axi_aw_fire_count [NUM_AXI_PORTS];
    reg [63:0] axi_w_fire_count [NUM_AXI_PORTS];
    reg [63:0] axi_b_fire_count [NUM_AXI_PORTS];
    reg [63:0] axi_ar_fire_count [NUM_AXI_PORTS];
    reg [63:0] axi_r_fire_count [NUM_AXI_PORTS];
    reg [63:0] axi_aw_stall_count [NUM_AXI_PORTS];
    reg [63:0] axi_w_stall_count [NUM_AXI_PORTS];
    reg [63:0] axi_b_stall_count [NUM_AXI_PORTS];
    reg [63:0] axi_ar_stall_count [NUM_AXI_PORTS];
    reg [63:0] axi_r_stall_count [NUM_AXI_PORTS];
    reg [63:0] axi_rd_outstanding [NUM_AXI_PORTS];
    reg [63:0] axi_wr_outstanding [NUM_AXI_PORTS];
    reg [63:0] axi_last_aw [NUM_AXI_PORTS];
    reg [63:0] axi_last_ar [NUM_AXI_PORTS];
    reg [63:0] axi_last_b [NUM_AXI_PORTS];
    reg [63:0] axi_last_r [NUM_AXI_PORTS];
    reg [63:0] axi_error_count [NUM_AXI_PORTS];
    reg [63:0] axi_flags [NUM_AXI_PORTS];
    reg        axi_aw_stalled [NUM_AXI_PORTS];
    reg        axi_w_stalled [NUM_AXI_PORTS];
    reg        axi_b_stalled [NUM_AXI_PORTS];
    reg        axi_ar_stalled [NUM_AXI_PORTS];
    reg        axi_r_stalled [NUM_AXI_PORTS];
    reg [AXI_ADDR_WIDTH-1:0] axi_awaddr_hold [NUM_AXI_PORTS];
    reg [AXI_ID_WIDTH-1:0]   axi_awid_hold [NUM_AXI_PORTS];
    reg [7:0]                axi_awlen_hold [NUM_AXI_PORTS];
    reg                      axi_wlast_hold [NUM_AXI_PORTS];
    reg [AXI_ID_WIDTH-1:0]   axi_bid_hold [NUM_AXI_PORTS];
    reg [1:0]                axi_bresp_hold [NUM_AXI_PORTS];
    reg [AXI_ADDR_WIDTH-1:0] axi_araddr_hold [NUM_AXI_PORTS];
    reg [AXI_ID_WIDTH-1:0]   axi_arid_hold [NUM_AXI_PORTS];
    reg [7:0]                axi_arlen_hold [NUM_AXI_PORTS];
    reg [AXI_ID_WIDTH-1:0]   axi_rid_hold [NUM_AXI_PORTS];
    reg [1:0]                axi_rresp_hold [NUM_AXI_PORTS];
    reg                      axi_rlast_hold [NUM_AXI_PORTS];

    reg [AXI_PORT_COUNTW-1:0] wr_req_count;
    reg [AXI_PORT_COUNTW-1:0] wr_rsp_count;
    reg [AXI_PORT_COUNTW-1:0] wr_req_delta;
    reg [AXI_PORT_COUNTW-1:0] wr_rsp_delta;
    reg                       axi_flags_any;
    reg [63:0]                global_flags_set;
    reg [63:0]                ctrl_flags_set;
    reg [63:0]                axi_flags_set [NUM_AXI_PORTS];

    function automatic [63:0] pack_pc_meta(
        input logic valid,
        input logic [HW_DEBUG_CORE_ID_WIDTH-1:0] core_id,
        input logic [NW_WIDTH-1:0] wid,
        input logic [63:0] cycle
    );
    begin
        pack_pc_meta = '0;
        pack_pc_meta[0] = valid;
        pack_pc_meta[15:8] = 8'(core_id);
        pack_pc_meta[23:16] = 8'(wid);
        pack_pc_meta[63:32] = cycle[31:0];
    end
    endfunction

    function automatic [63:0] pack_axi_addr(
        input logic [AXI_ADDR_WIDTH-1:0] addr,
        input logic [AXI_ID_WIDTH-1:0] id,
        input logic [7:0] len
    );
    begin
        pack_axi_addr = '0;
        pack_axi_addr[AXI_ADDR_LOG_BITS-1:0] = addr[AXI_ADDR_LOG_BITS-1:0];
        pack_axi_addr[55:48] = 8'(id);
        pack_axi_addr[63:56] = len;
    end
    endfunction

    function automatic [63:0] pack_axi_resp(
        input logic [AXI_ID_WIDTH-1:0] id,
        input logic [1:0] resp,
        input logic last
    );
    begin
        pack_axi_resp = '0;
        pack_axi_resp[7:0] = 8'(id);
        pack_axi_resp[8] = last;
        pack_axi_resp[10:9] = resp;
    end
    endfunction

    reg [63:0] afu_status_data;
    always @(*) begin
        afu_status_data = '0;
        afu_status_data[0] = ap_reset;
        afu_status_data[1] = ap_start;
        afu_status_data[2] = ap_done;
        afu_status_data[3] = ap_idle;
        afu_status_data[4] = ap_ready;
        afu_status_data[5] = vx_busy;
        afu_status_data[6] = vx_cache_drain;
        afu_status_data[7] = ap_done_base;
        afu_status_data[8] = ap_done_wait_cache;
        afu_status_data[11:10] = ap_state;
        afu_status_data[16 +: PENDING_WR_SIZEW] = vx_pending_writes;
    end

    reg [63:0] ctrl_status_data;
    always @(*) begin
        ctrl_status_data = '0;
        ctrl_status_data[0] = s_axi_ctrl_awvalid;
        ctrl_status_data[1] = s_axi_ctrl_awready;
        ctrl_status_data[2] = s_axi_ctrl_wvalid;
        ctrl_status_data[3] = s_axi_ctrl_wready;
        ctrl_status_data[4] = s_axi_ctrl_bvalid;
        ctrl_status_data[5] = s_axi_ctrl_bready;
        ctrl_status_data[6] = s_axi_ctrl_arvalid;
        ctrl_status_data[7] = s_axi_ctrl_arready;
        ctrl_status_data[8] = s_axi_ctrl_rvalid;
        ctrl_status_data[9] = s_axi_ctrl_rready;
        ctrl_status_data[17:10] = s_axi_ctrl_awaddr;
        ctrl_status_data[25:18] = s_axi_ctrl_araddr;
        ctrl_status_data[27:26] = s_axi_ctrl_bresp;
        ctrl_status_data[29:28] = s_axi_ctrl_rresp;
    end

    integer count_i;
    always @(*) begin
        wr_req_count = '0;
        wr_rsp_count = '0;
        for (count_i = 0; count_i < NUM_AXI_PORTS; count_i = count_i + 1) begin
            if (m_axi_wr_req_fire[count_i]) begin
                wr_req_count = wr_req_count + AXI_PORT_COUNTW'(1);
            end
            if (m_axi_bvalid[count_i] && m_axi_bready[count_i]) begin
                wr_rsp_count = wr_rsp_count + AXI_PORT_COUNTW'(1);
            end
        end
        wr_req_delta = wr_req_count - wr_rsp_count;
        wr_rsp_delta = wr_rsp_count - wr_req_count;
    end

    integer any_i;
    always @(*) begin
        axi_flags_any = 1'b0;
        for (any_i = 0; any_i < NUM_AXI_PORTS; any_i = any_i + 1) begin
            axi_flags_any = axi_flags_any || (|axi_flags[any_i]);
        end
    end

    wire anomaly_seen = (|global_anomaly_flags[63:1]) || (|ctrl_flags) || axi_flags_any;
    wire pending_sign_now = vx_pending_writes[PENDING_WR_SIZEW-1];
    wire pending_underflow_now = (wr_rsp_count > wr_req_count)
                              && (vx_pending_writes < PENDING_WR_SIZEW'(wr_rsp_delta));
    wire pending_overflow_now = (wr_req_count > wr_rsp_count)
                             && (({PENDING_WR_SIZEW{1'b1}} - vx_pending_writes)
                                  < PENDING_WR_SIZEW'(wr_req_delta));
    wire ctrl_write_pair_fire = (s_axi_ctrl_aw_fire && s_axi_ctrl_w_fire)
                             || (s_axi_ctrl_aw_fire && (ctrl_w_pending != 0))
                             || (s_axi_ctrl_w_fire && (ctrl_aw_pending != 0));
    wire ctrl_b_underflow_now = s_axi_ctrl_b_fire && !((ctrl_b_pending != 0) || ctrl_write_pair_fire);
    wire ctrl_r_underflow_now = s_axi_ctrl_r_fire && !((ctrl_r_pending != 0) || s_axi_ctrl_ar_fire);

    integer flag_i;
    always @(*) begin
        global_flags_set = '0;
        ctrl_flags_set = '0;
        for (flag_i = 0; flag_i < NUM_AXI_PORTS; flag_i = flag_i + 1) begin
            axi_flags_set[flag_i] = '0;
        end

        if (pending_sign_now) begin
            global_flags_set[GLB_FLAG_PENDING_SIGN] = 1'b1;
        end
        if (pending_underflow_now) begin
            global_flags_set[GLB_FLAG_PENDING_UNDERFLOW] = 1'b1;
        end
        if (pending_overflow_now) begin
            global_flags_set[GLB_FLAG_PENDING_OVERFLOW] = 1'b1;
        end

        if (s_axi_ctrl_awvalid && !s_axi_ctrl_awready
         && ctrl_aw_stalled && s_axi_ctrl_awaddr != ctrl_awaddr_hold) begin
            ctrl_flags_set[CTRL_FLAG_AW_STABLE] = 1'b1;
        end
        if (s_axi_ctrl_wvalid && !s_axi_ctrl_wready
         && ctrl_w_stalled
         && (s_axi_ctrl_wdata != ctrl_wdata_hold || s_axi_ctrl_wstrb != ctrl_wstrb_hold)) begin
            ctrl_flags_set[CTRL_FLAG_W_STABLE] = 1'b1;
        end
        if (s_axi_ctrl_bvalid && !s_axi_ctrl_bready
         && ctrl_b_stalled && s_axi_ctrl_bresp != ctrl_bresp_hold) begin
            ctrl_flags_set[CTRL_FLAG_B_STABLE] = 1'b1;
        end
        if (s_axi_ctrl_arvalid && !s_axi_ctrl_arready
         && ctrl_ar_stalled && s_axi_ctrl_araddr != ctrl_araddr_hold) begin
            ctrl_flags_set[CTRL_FLAG_AR_STABLE] = 1'b1;
        end
        if (s_axi_ctrl_rvalid && !s_axi_ctrl_rready
         && ctrl_r_stalled
         && (s_axi_ctrl_rdata != ctrl_rdata_hold || s_axi_ctrl_rresp != ctrl_rresp_hold)) begin
            ctrl_flags_set[CTRL_FLAG_R_STABLE] = 1'b1;
        end
        if (ctrl_b_underflow_now) begin
            ctrl_flags_set[CTRL_FLAG_B_UNDERFLOW] = 1'b1;
        end
        if (ctrl_r_underflow_now) begin
            ctrl_flags_set[CTRL_FLAG_R_UNDERFLOW] = 1'b1;
        end
        if (s_axi_ctrl_b_fire && s_axi_ctrl_bresp != 2'b00) begin
            ctrl_flags_set[CTRL_FLAG_BRESP_ERROR] = 1'b1;
            global_flags_set[GLB_FLAG_CTRL_RESP_ERROR] = 1'b1;
        end
        if (s_axi_ctrl_r_fire && s_axi_ctrl_rresp != 2'b00) begin
            ctrl_flags_set[CTRL_FLAG_RRESP_ERROR] = 1'b1;
            global_flags_set[GLB_FLAG_CTRL_RESP_ERROR] = 1'b1;
        end
        if (|ctrl_flags_set[CTRL_FLAG_R_UNDERFLOW:CTRL_FLAG_AW_STABLE]) begin
            global_flags_set[GLB_FLAG_CTRL_PROTOCOL] = 1'b1;
        end

        for (flag_i = 0; flag_i < NUM_AXI_PORTS; flag_i = flag_i + 1) begin
            if (m_axi_awvalid[flag_i] && !m_axi_awready[flag_i]
             && axi_aw_stalled[flag_i]
             && (m_axi_awaddr[flag_i] != axi_awaddr_hold[flag_i]
              || m_axi_awid[flag_i] != axi_awid_hold[flag_i]
              || m_axi_awlen[flag_i] != axi_awlen_hold[flag_i])) begin
                axi_flags_set[flag_i][AXI_FLAG_AW_STABLE] = 1'b1;
            end
            if (m_axi_wvalid[flag_i] && !m_axi_wready[flag_i]
             && axi_w_stalled[flag_i] && m_axi_wlast[flag_i] != axi_wlast_hold[flag_i]) begin
                axi_flags_set[flag_i][AXI_FLAG_W_STABLE] = 1'b1;
            end
            if (m_axi_bvalid[flag_i] && !m_axi_bready[flag_i]
             && axi_b_stalled[flag_i]
             && (m_axi_bid[flag_i] != axi_bid_hold[flag_i]
              || m_axi_bresp[flag_i] != axi_bresp_hold[flag_i])) begin
                axi_flags_set[flag_i][AXI_FLAG_B_STABLE] = 1'b1;
            end
            if (m_axi_arvalid[flag_i] && !m_axi_arready[flag_i]
             && axi_ar_stalled[flag_i]
             && (m_axi_araddr[flag_i] != axi_araddr_hold[flag_i]
              || m_axi_arid[flag_i] != axi_arid_hold[flag_i]
              || m_axi_arlen[flag_i] != axi_arlen_hold[flag_i])) begin
                axi_flags_set[flag_i][AXI_FLAG_AR_STABLE] = 1'b1;
            end
            if (m_axi_rvalid[flag_i] && !m_axi_rready[flag_i]
             && axi_r_stalled[flag_i]
             && (m_axi_rid[flag_i] != axi_rid_hold[flag_i]
              || m_axi_rresp[flag_i] != axi_rresp_hold[flag_i]
              || m_axi_rlast[flag_i] != axi_rlast_hold[flag_i])) begin
                axi_flags_set[flag_i][AXI_FLAG_R_STABLE] = 1'b1;
            end
            if (m_axi_bvalid[flag_i] && m_axi_bready[flag_i]
             && !((axi_wr_outstanding[flag_i] != 0) || m_axi_wr_req_fire[flag_i])) begin
                axi_flags_set[flag_i][AXI_FLAG_B_UNDERFLOW] = 1'b1;
            end
            if (m_axi_rvalid[flag_i] && m_axi_rready[flag_i]
             && !((axi_rd_outstanding[flag_i] != 0)
               || (m_axi_arvalid[flag_i] && m_axi_arready[flag_i]))) begin
                axi_flags_set[flag_i][AXI_FLAG_R_UNDERFLOW] = 1'b1;
            end
            if (m_axi_bvalid[flag_i] && m_axi_bready[flag_i] && m_axi_bresp[flag_i] != 2'b00) begin
                axi_flags_set[flag_i][AXI_FLAG_BRESP_ERROR] = 1'b1;
                global_flags_set[GLB_FLAG_AXI_RESP_ERROR] = 1'b1;
            end
            if (m_axi_rvalid[flag_i] && m_axi_rready[flag_i] && m_axi_rresp[flag_i] != 2'b00) begin
                axi_flags_set[flag_i][AXI_FLAG_RRESP_ERROR] = 1'b1;
                global_flags_set[GLB_FLAG_AXI_RESP_ERROR] = 1'b1;
            end
            if (|axi_flags_set[flag_i][AXI_FLAG_R_UNDERFLOW:AXI_FLAG_AW_STABLE]) begin
                global_flags_set[GLB_FLAG_AXI_PROTOCOL] = 1'b1;
            end
        end
    end

    integer i;
    always @(posedge clk) begin
        if (reset || debug_clear) begin
            cycle_count        <= '0;
            pc_source_rr       <= '0;
            pc_event_count     <= '0;
            pc_sample_count    <= '0;
            pc_same_count      <= '0;
            pc_hash            <= '0;
            pc_sample_ctr      <= '0;
            pc_ring_wptr       <= '0;
            pc_last_valid      <= 1'b0;
            pc_last_core_id    <= '0;
            pc_last_wid        <= '0;
            pc_last_pc         <= '0;
            pc_last_cycle      <= '0;
            ctrl_aw_fire_count <= '0;
            ctrl_w_fire_count  <= '0;
            ctrl_b_fire_count  <= '0;
            ctrl_ar_fire_count <= '0;
            ctrl_r_fire_count  <= '0;
            ctrl_stall_count   <= '0;
            ctrl_error_count   <= '0;
            ctrl_last_write    <= '0;
            ctrl_last_read     <= '0;
            ctrl_flags         <= '0;
            global_anomaly_flags <= '0;
            anomaly_first_cycle <= '0;
            anomaly_last_cycle <= '0;
            ctrl_aw_pending    <= '0;
            ctrl_w_pending     <= '0;
            ctrl_b_pending     <= '0;
            ctrl_r_pending     <= '0;
            ctrl_aw_stalled    <= 1'b0;
            ctrl_w_stalled     <= 1'b0;
            ctrl_b_stalled     <= 1'b0;
            ctrl_ar_stalled    <= 1'b0;
            ctrl_r_stalled     <= 1'b0;
            ctrl_awaddr_hold   <= '0;
            ctrl_wdata_hold    <= '0;
            ctrl_wstrb_hold    <= '0;
            ctrl_bresp_hold    <= '0;
            ctrl_araddr_hold   <= '0;
            ctrl_rdata_hold    <= '0;
            ctrl_rresp_hold    <= '0;
            for (i = 0; i < PC_RING_DEPTH; i = i + 1) begin
                pc_ring_valid[i]   <= 1'b0;
                pc_ring_core_id[i] <= '0;
                pc_ring_wid[i]     <= '0;
                pc_ring_pc[i]      <= '0;
                pc_ring_cycle[i]   <= '0;
            end
            for (i = 0; i < NUM_AXI_PORTS; i = i + 1) begin
                axi_aw_fire_count[i]  <= '0;
                axi_w_fire_count[i]   <= '0;
                axi_b_fire_count[i]   <= '0;
                axi_ar_fire_count[i]  <= '0;
                axi_r_fire_count[i]   <= '0;
                axi_aw_stall_count[i] <= '0;
                axi_w_stall_count[i]  <= '0;
                axi_b_stall_count[i]  <= '0;
                axi_ar_stall_count[i] <= '0;
                axi_r_stall_count[i]  <= '0;
                axi_rd_outstanding[i] <= '0;
                axi_wr_outstanding[i] <= '0;
                axi_last_aw[i]        <= '0;
                axi_last_ar[i]        <= '0;
                axi_last_b[i]         <= '0;
                axi_last_r[i]         <= '0;
                axi_error_count[i]    <= '0;
                axi_flags[i]          <= '0;
                axi_aw_stalled[i]     <= 1'b0;
                axi_w_stalled[i]      <= 1'b0;
                axi_b_stalled[i]      <= 1'b0;
                axi_ar_stalled[i]     <= 1'b0;
                axi_r_stalled[i]      <= 1'b0;
                axi_awaddr_hold[i]    <= '0;
                axi_awid_hold[i]      <= '0;
                axi_awlen_hold[i]     <= '0;
                axi_wlast_hold[i]     <= 1'b0;
                axi_bid_hold[i]       <= '0;
                axi_bresp_hold[i]     <= '0;
                axi_araddr_hold[i]    <= '0;
                axi_arid_hold[i]      <= '0;
                axi_arlen_hold[i]     <= '0;
                axi_rid_hold[i]       <= '0;
                axi_rresp_hold[i]     <= '0;
                axi_rlast_hold[i]     <= 1'b0;
            end
        end else if (!debug_freeze) begin
            cycle_count <= cycle_count + 1;

            if (|global_flags_set) begin
                global_anomaly_flags <= global_anomaly_flags | global_flags_set;
                if (!anomaly_seen) begin
                    anomaly_first_cycle <= cycle_count;
                end
                anomaly_last_cycle <= cycle_count;
            end
            ctrl_flags <= ctrl_flags | ctrl_flags_set;

            if (s_axi_ctrl_awvalid && !s_axi_ctrl_awready) begin
                if (!ctrl_aw_stalled) begin
                    ctrl_awaddr_hold <= s_axi_ctrl_awaddr;
                end
                ctrl_aw_stalled <= 1'b1;
            end else begin
                ctrl_aw_stalled <= 1'b0;
            end
            if (s_axi_ctrl_wvalid && !s_axi_ctrl_wready) begin
                if (!ctrl_w_stalled) begin
                    ctrl_wdata_hold <= s_axi_ctrl_wdata;
                    ctrl_wstrb_hold <= s_axi_ctrl_wstrb;
                end
                ctrl_w_stalled <= 1'b1;
            end else begin
                ctrl_w_stalled <= 1'b0;
            end
            if (s_axi_ctrl_bvalid && !s_axi_ctrl_bready) begin
                if (!ctrl_b_stalled) begin
                    ctrl_bresp_hold <= s_axi_ctrl_bresp;
                end
                ctrl_b_stalled <= 1'b1;
            end else begin
                ctrl_b_stalled <= 1'b0;
            end
            if (s_axi_ctrl_arvalid && !s_axi_ctrl_arready) begin
                if (!ctrl_ar_stalled) begin
                    ctrl_araddr_hold <= s_axi_ctrl_araddr;
                end
                ctrl_ar_stalled <= 1'b1;
            end else begin
                ctrl_ar_stalled <= 1'b0;
            end
            if (s_axi_ctrl_rvalid && !s_axi_ctrl_rready) begin
                if (!ctrl_r_stalled) begin
                    ctrl_rdata_hold <= s_axi_ctrl_rdata;
                    ctrl_rresp_hold <= s_axi_ctrl_rresp;
                end
                ctrl_r_stalled <= 1'b1;
            end else begin
                ctrl_r_stalled <= 1'b0;
            end

            if (s_axi_ctrl_aw_fire && !(s_axi_ctrl_w_fire || ctrl_w_pending != 0)) begin
                ctrl_aw_pending <= ctrl_aw_pending + 8'd1;
            end else if (s_axi_ctrl_w_fire && ctrl_aw_pending != 0) begin
                ctrl_aw_pending <= ctrl_aw_pending - 8'd1;
            end
            if (s_axi_ctrl_w_fire && !(s_axi_ctrl_aw_fire || ctrl_aw_pending != 0)) begin
                ctrl_w_pending <= ctrl_w_pending + 8'd1;
            end else if (s_axi_ctrl_aw_fire && ctrl_w_pending != 0) begin
                ctrl_w_pending <= ctrl_w_pending - 8'd1;
            end
            if (ctrl_write_pair_fire && !s_axi_ctrl_b_fire) begin
                ctrl_b_pending <= ctrl_b_pending + 8'd1;
            end else if (!ctrl_write_pair_fire && s_axi_ctrl_b_fire && ctrl_b_pending != 0) begin
                ctrl_b_pending <= ctrl_b_pending - 8'd1;
            end
            if (s_axi_ctrl_ar_fire && !s_axi_ctrl_r_fire) begin
                ctrl_r_pending <= ctrl_r_pending + 8'd1;
            end else if (!s_axi_ctrl_ar_fire && s_axi_ctrl_r_fire && ctrl_r_pending != 0) begin
                ctrl_r_pending <= ctrl_r_pending - 8'd1;
            end

            if (pc_event_valid) begin
                pc_event_count <= pc_event_count + 1;
                pc_hash <= {pc_hash[62:0], pc_hash[63]} ^ 64'(pc_event_pc);
                if (pc_last_valid && pc_event_pc == pc_last_pc) begin
                    pc_same_count <= pc_same_count + 1;
                end else begin
                    pc_same_count <= '0;
                end
                pc_last_valid   <= 1'b1;
                pc_last_core_id <= pc_event_core_id;
                pc_last_wid     <= pc_event_wid;
                pc_last_pc      <= pc_event_pc;
                pc_last_cycle   <= cycle_count;

                if (pc_event_src == PC_SOURCEW'(HW_DEBUG_NUM_PC_SOURCES - 1)) begin
                    pc_source_rr <= '0;
                end else begin
                    pc_source_rr <= pc_event_src + PC_SOURCEW'(1);
                end

                if (pc_sample_ctr == '0) begin
                    pc_ring_valid[pc_ring_wptr]   <= 1'b1;
                    pc_ring_core_id[pc_ring_wptr] <= pc_event_core_id;
                    pc_ring_wid[pc_ring_wptr]     <= pc_event_wid;
                    pc_ring_pc[pc_ring_wptr]      <= pc_event_pc;
                    pc_ring_cycle[pc_ring_wptr]   <= cycle_count;
                    pc_sample_count <= pc_sample_count + 1;
                    if (pc_ring_wptr == PC_RING_ADDRW'(PC_RING_DEPTH - 1)) begin
                        pc_ring_wptr <= '0;
                    end else begin
                        pc_ring_wptr <= pc_ring_wptr + PC_RING_ADDRW'(1);
                    end
                end
                pc_sample_ctr <= pc_sample_ctr + PC_SAMPLE_LOG2'(1);
            end

            if (s_axi_ctrl_aw_fire) begin
                ctrl_aw_fire_count <= ctrl_aw_fire_count + 1;
            end
            if (s_axi_ctrl_w_fire) begin
                ctrl_w_fire_count <= ctrl_w_fire_count + 1;
                ctrl_last_write <= {s_axi_ctrl_wdata, 8'b0, s_axi_ctrl_awaddr, 4'b0, s_axi_ctrl_wstrb, 4'b0, s_axi_ctrl_bresp};
            end
            if (s_axi_ctrl_b_fire) begin
                ctrl_b_fire_count <= ctrl_b_fire_count + 1;
                if (s_axi_ctrl_bresp != 2'b00) begin
                    ctrl_error_count <= ctrl_error_count + 1;
                end
            end
            if (s_axi_ctrl_ar_fire) begin
                ctrl_ar_fire_count <= ctrl_ar_fire_count + 1;
            end
            if (s_axi_ctrl_r_fire) begin
                ctrl_r_fire_count <= ctrl_r_fire_count + 1;
                ctrl_last_read <= {s_axi_ctrl_rdata, 8'b0, s_axi_ctrl_araddr, 14'b0, s_axi_ctrl_rresp};
                if (s_axi_ctrl_rresp != 2'b00) begin
                    ctrl_error_count <= ctrl_error_count + 1;
                end
            end
            if ((s_axi_ctrl_awvalid && !s_axi_ctrl_awready)
             || (s_axi_ctrl_wvalid && !s_axi_ctrl_wready)
             || (s_axi_ctrl_bvalid && !s_axi_ctrl_bready)
             || (s_axi_ctrl_arvalid && !s_axi_ctrl_arready)
             || (s_axi_ctrl_rvalid && !s_axi_ctrl_rready)) begin
                ctrl_stall_count <= ctrl_stall_count + 1;
            end

            for (i = 0; i < NUM_AXI_PORTS; i = i + 1) begin
                axi_flags[i] <= axi_flags[i] | axi_flags_set[i];

                if (m_axi_awvalid[i] && !m_axi_awready[i]) begin
                    if (!axi_aw_stalled[i]) begin
                        axi_awaddr_hold[i] <= m_axi_awaddr[i];
                        axi_awid_hold[i]   <= m_axi_awid[i];
                        axi_awlen_hold[i]  <= m_axi_awlen[i];
                    end
                    axi_aw_stalled[i] <= 1'b1;
                end else begin
                    axi_aw_stalled[i] <= 1'b0;
                end
                if (m_axi_wvalid[i] && !m_axi_wready[i]) begin
                    if (!axi_w_stalled[i]) begin
                        axi_wlast_hold[i] <= m_axi_wlast[i];
                    end
                    axi_w_stalled[i] <= 1'b1;
                end else begin
                    axi_w_stalled[i] <= 1'b0;
                end
                if (m_axi_bvalid[i] && !m_axi_bready[i]) begin
                    if (!axi_b_stalled[i]) begin
                        axi_bid_hold[i]   <= m_axi_bid[i];
                        axi_bresp_hold[i] <= m_axi_bresp[i];
                    end
                    axi_b_stalled[i] <= 1'b1;
                end else begin
                    axi_b_stalled[i] <= 1'b0;
                end
                if (m_axi_arvalid[i] && !m_axi_arready[i]) begin
                    if (!axi_ar_stalled[i]) begin
                        axi_araddr_hold[i] <= m_axi_araddr[i];
                        axi_arid_hold[i]   <= m_axi_arid[i];
                        axi_arlen_hold[i]  <= m_axi_arlen[i];
                    end
                    axi_ar_stalled[i] <= 1'b1;
                end else begin
                    axi_ar_stalled[i] <= 1'b0;
                end
                if (m_axi_rvalid[i] && !m_axi_rready[i]) begin
                    if (!axi_r_stalled[i]) begin
                        axi_rid_hold[i]   <= m_axi_rid[i];
                        axi_rresp_hold[i] <= m_axi_rresp[i];
                        axi_rlast_hold[i] <= m_axi_rlast[i];
                    end
                    axi_r_stalled[i] <= 1'b1;
                end else begin
                    axi_r_stalled[i] <= 1'b0;
                end

                if (m_axi_awvalid[i] && m_axi_awready[i]) begin
                    axi_aw_fire_count[i] <= axi_aw_fire_count[i] + 1;
                    axi_last_aw[i] <= pack_axi_addr(m_axi_awaddr[i], m_axi_awid[i], m_axi_awlen[i]);
                end
                if (m_axi_wvalid[i] && m_axi_wready[i]) begin
                    axi_w_fire_count[i] <= axi_w_fire_count[i] + 1;
                end
                if (m_axi_bvalid[i] && m_axi_bready[i]) begin
                    axi_b_fire_count[i] <= axi_b_fire_count[i] + 1;
                    axi_last_b[i] <= pack_axi_resp(m_axi_bid[i], m_axi_bresp[i], 1'b1);
                end
                if (m_axi_arvalid[i] && m_axi_arready[i]) begin
                    axi_ar_fire_count[i] <= axi_ar_fire_count[i] + 1;
                    axi_last_ar[i] <= pack_axi_addr(m_axi_araddr[i], m_axi_arid[i], m_axi_arlen[i]);
                end
                if (m_axi_rvalid[i] && m_axi_rready[i]) begin
                    axi_r_fire_count[i] <= axi_r_fire_count[i] + 1;
                    axi_last_r[i] <= pack_axi_resp(m_axi_rid[i], m_axi_rresp[i], m_axi_rlast[i]);
                end
                if ((m_axi_arvalid[i] && m_axi_arready[i]) && !(m_axi_rvalid[i] && m_axi_rready[i] && m_axi_rlast[i])) begin
                    axi_rd_outstanding[i] <= axi_rd_outstanding[i] + 1;
                end else if (!(m_axi_arvalid[i] && m_axi_arready[i]) && (m_axi_rvalid[i] && m_axi_rready[i] && m_axi_rlast[i]) && axi_rd_outstanding[i] != 0) begin
                    axi_rd_outstanding[i] <= axi_rd_outstanding[i] - 1;
                end
                if (m_axi_wr_req_fire[i] && !(m_axi_bvalid[i] && m_axi_bready[i])) begin
                    axi_wr_outstanding[i] <= axi_wr_outstanding[i] + 1;
                end else if (!m_axi_wr_req_fire[i] && (m_axi_bvalid[i] && m_axi_bready[i]) && axi_wr_outstanding[i] != 0) begin
                    axi_wr_outstanding[i] <= axi_wr_outstanding[i] - 1;
                end
                if ((m_axi_bvalid[i] && m_axi_bready[i] && m_axi_bresp[i] != 2'b00)
                 && (m_axi_rvalid[i] && m_axi_rready[i] && m_axi_rresp[i] != 2'b00)) begin
                    axi_error_count[i] <= axi_error_count[i] + 2;
                end else if ((m_axi_bvalid[i] && m_axi_bready[i] && m_axi_bresp[i] != 2'b00)
                          || (m_axi_rvalid[i] && m_axi_rready[i] && m_axi_rresp[i] != 2'b00)) begin
                    axi_error_count[i] <= axi_error_count[i] + 1;
                end
                if (m_axi_awvalid[i] && !m_axi_awready[i]) begin
                    axi_aw_stall_count[i] <= axi_aw_stall_count[i] + 1;
                end
                if (m_axi_wvalid[i] && !m_axi_wready[i]) begin
                    axi_w_stall_count[i] <= axi_w_stall_count[i] + 1;
                end
                if (m_axi_bvalid[i] && !m_axi_bready[i]) begin
                    axi_b_stall_count[i] <= axi_b_stall_count[i] + 1;
                end
                if (m_axi_arvalid[i] && !m_axi_arready[i]) begin
                    axi_ar_stall_count[i] <= axi_ar_stall_count[i] + 1;
                end
                if (m_axi_rvalid[i] && !m_axi_rready[i]) begin
                    axi_r_stall_count[i] <= axi_r_stall_count[i] + 1;
                end
            end
        end
    end

    always @(*) begin
        debug_rdata = 64'h0;
        case (metric_id)
            DBG_ID: begin
                debug_rdata = 64'h4857_4442_4700_0001;
            end
            DBG_AFU_STATUS: begin
                debug_rdata = afu_status_data;
            end
            DBG_CYCLE_COUNT: begin
                debug_rdata = cycle_count;
            end
            DBG_PC_EVENT_COUNT: begin
                debug_rdata = pc_event_count;
            end
            DBG_PC_LAST_META: begin
                debug_rdata = pack_pc_meta(pc_last_valid, pc_last_core_id, pc_last_wid, pc_last_cycle);
            end
            DBG_PC_LAST_VALUE: begin
                debug_rdata = pc_last_pc;
            end
            DBG_PC_SAME_COUNT: begin
                debug_rdata = pc_same_count;
            end
            DBG_PC_HASH: begin
                debug_rdata = pc_hash;
            end
            DBG_PC_RING_META: begin
                debug_rdata = ring_valid ? pack_pc_meta(
                    pc_ring_valid[ring_idx],
                    pc_ring_core_id[ring_idx],
                    pc_ring_wid[ring_idx],
                    pc_ring_cycle[ring_idx]
                ) : 64'hBAD0_DB60_0000_0000;
            end
            DBG_PC_RING_VALUE: begin
                debug_rdata = ring_valid ? pc_ring_pc[ring_idx] : 64'hBAD0_DB60_0000_0001;
            end
            DBG_ANOMALY_FLAGS: begin
                debug_rdata = {global_anomaly_flags[63:1], anomaly_seen};
            end
            DBG_ANOMALY_CYCLES: begin
                debug_rdata = {anomaly_last_cycle[31:0], anomaly_first_cycle[31:0]};
            end
            DBG_AXI_AW_FIRE: begin
                debug_rdata = port_valid ? axi_aw_fire_count[port_idx] : 64'hBAD0_DB60_0000_0010;
            end
            DBG_AXI_W_FIRE: begin
                debug_rdata = port_valid ? axi_w_fire_count[port_idx] : 64'hBAD0_DB60_0000_0011;
            end
            DBG_AXI_B_FIRE: begin
                debug_rdata = port_valid ? axi_b_fire_count[port_idx] : 64'hBAD0_DB60_0000_0012;
            end
            DBG_AXI_AR_FIRE: begin
                debug_rdata = port_valid ? axi_ar_fire_count[port_idx] : 64'hBAD0_DB60_0000_0013;
            end
            DBG_AXI_R_FIRE: begin
                debug_rdata = port_valid ? axi_r_fire_count[port_idx] : 64'hBAD0_DB60_0000_0014;
            end
            DBG_AXI_AW_STALL: begin
                debug_rdata = port_valid ? axi_aw_stall_count[port_idx] : 64'hBAD0_DB60_0000_0015;
            end
            DBG_AXI_W_STALL: begin
                debug_rdata = port_valid ? axi_w_stall_count[port_idx] : 64'hBAD0_DB60_0000_0016;
            end
            DBG_AXI_B_STALL: begin
                debug_rdata = port_valid ? axi_b_stall_count[port_idx] : 64'hBAD0_DB60_0000_0017;
            end
            DBG_AXI_AR_STALL: begin
                debug_rdata = port_valid ? axi_ar_stall_count[port_idx] : 64'hBAD0_DB60_0000_0018;
            end
            DBG_AXI_R_STALL: begin
                debug_rdata = port_valid ? axi_r_stall_count[port_idx] : 64'hBAD0_DB60_0000_0019;
            end
            DBG_AXI_RD_OUTSTAND: begin
                debug_rdata = port_valid ? axi_rd_outstanding[port_idx] : 64'hBAD0_DB60_0000_001a;
            end
            DBG_AXI_WR_OUTSTAND: begin
                debug_rdata = port_valid ? axi_wr_outstanding[port_idx] : 64'hBAD0_DB60_0000_001b;
            end
            DBG_AXI_LAST_AW: begin
                debug_rdata = port_valid ? axi_last_aw[port_idx] : 64'hBAD0_DB60_0000_001c;
            end
            DBG_AXI_LAST_AR: begin
                debug_rdata = port_valid ? axi_last_ar[port_idx] : 64'hBAD0_DB60_0000_001d;
            end
            DBG_AXI_LAST_B: begin
                debug_rdata = port_valid ? axi_last_b[port_idx] : 64'hBAD0_DB60_0000_001e;
            end
            DBG_AXI_LAST_R: begin
                debug_rdata = port_valid ? axi_last_r[port_idx] : 64'hBAD0_DB60_0000_001f;
            end
            DBG_AXI_ERRORS: begin
                debug_rdata = port_valid ? axi_error_count[port_idx] : 64'hBAD0_DB60_0000_0020;
            end
            DBG_AXI_FLAGS: begin
                debug_rdata = port_valid ? axi_flags[port_idx] : 64'hBAD0_DB60_0000_0021;
            end
            DBG_CTRL_STATUS: begin
                debug_rdata = ctrl_status_data;
            end
            DBG_CTRL_COUNTS: begin
                debug_rdata = {ctrl_r_fire_count[15:0], ctrl_ar_fire_count[15:0], ctrl_w_fire_count[15:0], ctrl_aw_fire_count[15:0]};
            end
            DBG_CTRL_LAST_WRITE: begin
                debug_rdata = ctrl_last_write;
            end
            DBG_CTRL_LAST_READ: begin
                debug_rdata = ctrl_last_read;
            end
            DBG_CTRL_FLAGS: begin
                debug_rdata = ctrl_flags;
            end
            default: begin
                debug_rdata = 64'hDEAD_DB60_BAD0_0000;
            end
        endcase
    end

    assign debug_status = {
        8'(NUM_AXI_PORTS),
        8'(HW_DEBUG_NUM_PC_SOURCES),
        13'b0,
        anomaly_seen,
        debug_freeze,
        1'b1
    };

endmodule

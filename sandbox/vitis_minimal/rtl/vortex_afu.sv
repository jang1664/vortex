// Minimal vortex_afu stub for the FSDB-plumbing experiment.
//
// Preserves the Vitis-facing interface (AXI4-Lite control slave + one AXI4
// master) so v++ --link + package_xo + platform integration all succeed
// unchanged, but strips the internals to a one-state FSM that asserts
// ap_done on ap_start and holds outputs at zero. All AXI master signals are
// tied off — the kernel performs no memory transactions.
//
// Only vortex_afu itself is needed; no VX_afu_wrap, no pipeline. The bind in
// runtime/xrt/vcs_fsdb_init.sv targets `vortex_afu` by module name, so the
// FSDB initializer fires inside every instance elaborated by the hw_emu TB.

module vortex_afu #(
    parameter C_S_AXI_CTRL_ADDR_WIDTH = 8,
    parameter C_S_AXI_CTRL_DATA_WIDTH = 32,
    parameter C_M_AXI_MEM_ID_WIDTH    = 32,
    parameter C_M_AXI_MEM_DATA_WIDTH  = 512,
    parameter C_M_AXI_MEM_ADDR_WIDTH  = 64
) (
    input  wire                                    ap_clk,
    input  wire                                    ap_rst_n,

    // -------- AXI4 master (one bank only; not exercised) --------------------
    output wire                                    m_axi_mem_0_awvalid,
    input  wire                                    m_axi_mem_0_awready,
    output wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]       m_axi_mem_0_awaddr,
    output wire [C_M_AXI_MEM_ID_WIDTH-1:0]         m_axi_mem_0_awid,
    output wire [7:0]                              m_axi_mem_0_awlen,
    output wire [2:0]                              m_axi_mem_0_awsize,
    output wire [1:0]                              m_axi_mem_0_awburst,
    output wire [1:0]                              m_axi_mem_0_awlock,
    output wire [3:0]                              m_axi_mem_0_awcache,
    output wire [2:0]                              m_axi_mem_0_awprot,
    output wire [3:0]                              m_axi_mem_0_awqos,
    output wire [3:0]                              m_axi_mem_0_awregion,
    output wire                                    m_axi_mem_0_wvalid,
    input  wire                                    m_axi_mem_0_wready,
    output wire [C_M_AXI_MEM_DATA_WIDTH-1:0]       m_axi_mem_0_wdata,
    output wire [C_M_AXI_MEM_DATA_WIDTH/8-1:0]     m_axi_mem_0_wstrb,
    output wire                                    m_axi_mem_0_wlast,
    output wire                                    m_axi_mem_0_arvalid,
    input  wire                                    m_axi_mem_0_arready,
    output wire [C_M_AXI_MEM_ADDR_WIDTH-1:0]       m_axi_mem_0_araddr,
    output wire [C_M_AXI_MEM_ID_WIDTH-1:0]         m_axi_mem_0_arid,
    output wire [7:0]                              m_axi_mem_0_arlen,
    output wire [2:0]                              m_axi_mem_0_arsize,
    output wire [1:0]                              m_axi_mem_0_arburst,
    output wire [1:0]                              m_axi_mem_0_arlock,
    output wire [3:0]                              m_axi_mem_0_arcache,
    output wire [2:0]                              m_axi_mem_0_arprot,
    output wire [3:0]                              m_axi_mem_0_arqos,
    output wire [3:0]                              m_axi_mem_0_arregion,
    input  wire                                    m_axi_mem_0_rvalid,
    output wire                                    m_axi_mem_0_rready,
    input  wire [C_M_AXI_MEM_DATA_WIDTH-1:0]       m_axi_mem_0_rdata,
    input  wire                                    m_axi_mem_0_rlast,
    input  wire [C_M_AXI_MEM_ID_WIDTH-1:0]         m_axi_mem_0_rid,
    input  wire [1:0]                              m_axi_mem_0_rresp,
    input  wire                                    m_axi_mem_0_bvalid,
    output wire                                    m_axi_mem_0_bready,
    input  wire [1:0]                              m_axi_mem_0_bresp,
    input  wire [C_M_AXI_MEM_ID_WIDTH-1:0]         m_axi_mem_0_bid,

    // -------- AXI4-Lite slave (control) -------------------------------------
    input  wire                                    s_axi_ctrl_awvalid,
    output wire                                    s_axi_ctrl_awready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]      s_axi_ctrl_awaddr,
    input  wire                                    s_axi_ctrl_wvalid,
    output wire                                    s_axi_ctrl_wready,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]      s_axi_ctrl_wdata,
    input  wire [C_S_AXI_CTRL_DATA_WIDTH/8-1:0]    s_axi_ctrl_wstrb,
    input  wire                                    s_axi_ctrl_arvalid,
    output wire                                    s_axi_ctrl_arready,
    input  wire [C_S_AXI_CTRL_ADDR_WIDTH-1:0]      s_axi_ctrl_araddr,
    output wire                                    s_axi_ctrl_rvalid,
    input  wire                                    s_axi_ctrl_rready,
    output wire [C_S_AXI_CTRL_DATA_WIDTH-1:0]      s_axi_ctrl_rdata,
    output wire [1:0]                              s_axi_ctrl_rresp,
    output wire                                    s_axi_ctrl_bvalid,
    input  wire                                    s_axi_ctrl_bready,
    output wire [1:0]                              s_axi_ctrl_bresp,

    output wire                                    interrupt
);
    // ------------------------------------------------------------------------
    // AXI master tie-off — no memory requests issued.
    // ------------------------------------------------------------------------
    assign m_axi_mem_0_awvalid  = 1'b0;
    assign m_axi_mem_0_awaddr   = '0;
    assign m_axi_mem_0_awid     = '0;
    assign m_axi_mem_0_awlen    = '0;
    assign m_axi_mem_0_awsize   = '0;
    assign m_axi_mem_0_awburst  = 2'b01;
    assign m_axi_mem_0_awlock   = '0;
    assign m_axi_mem_0_awcache  = '0;
    assign m_axi_mem_0_awprot   = '0;
    assign m_axi_mem_0_awqos    = '0;
    assign m_axi_mem_0_awregion = '0;
    assign m_axi_mem_0_wvalid   = 1'b0;
    assign m_axi_mem_0_wdata    = '0;
    assign m_axi_mem_0_wstrb    = '0;
    assign m_axi_mem_0_wlast    = 1'b0;
    assign m_axi_mem_0_arvalid  = 1'b0;
    assign m_axi_mem_0_araddr   = '0;
    assign m_axi_mem_0_arid     = '0;
    assign m_axi_mem_0_arlen    = '0;
    assign m_axi_mem_0_arsize   = '0;
    assign m_axi_mem_0_arburst  = 2'b01;
    assign m_axi_mem_0_arlock   = '0;
    assign m_axi_mem_0_arcache  = '0;
    assign m_axi_mem_0_arprot   = '0;
    assign m_axi_mem_0_arqos    = '0;
    assign m_axi_mem_0_arregion = '0;
    assign m_axi_mem_0_rready   = 1'b1;
    assign m_axi_mem_0_bready   = 1'b1;

    assign interrupt = 1'b0;

    // ------------------------------------------------------------------------
    // AXI4-Lite control slave — ap_ctrl_hs at offset 0x00.
    //   bit 0 = ap_start  (W1S, self-clears on transition to RUN)
    //   bit 1 = ap_done   (R, clear-on-read)
    //   bit 2 = ap_idle   (R)
    //   bit 3 = ap_ready  (R)
    // ------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_DONE = 2'd2;

    reg [1:0] state;
    reg [7:0] run_cnt;

    wire ap_start_write = s_axi_ctrl_awvalid && s_axi_ctrl_awready &&
                          s_axi_ctrl_wvalid  && s_axi_ctrl_wready  &&
                          (s_axi_ctrl_awaddr == 'h00) &&
                          s_axi_ctrl_wstrb[0] && s_axi_ctrl_wdata[0];

    always @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            state   <= S_IDLE;
            run_cnt <= 8'd0;
        end else begin
            case (state)
                S_IDLE: if (ap_start_write) begin
                    state   <= S_RUN;
                    run_cnt <= 8'd16;
                end
                S_RUN: if (run_cnt == 8'd0) state <= S_DONE;
                       else                 run_cnt <= run_cnt - 8'd1;
                S_DONE: ; // stay until ap_done is read-cleared
                default: state <= S_IDLE;
            endcase
        end
    end

    // AXI-Lite: accept every write and read in one cycle, ap_ctrl_hs status at 0x00.
    reg        awready_r, wready_r, bvalid_r;
    reg        arready_r, rvalid_r;
    reg [C_S_AXI_CTRL_DATA_WIDTH-1:0] rdata_r;
    reg        ap_done_sticky;

    always @(posedge ap_clk or negedge ap_rst_n) begin
        if (!ap_rst_n) begin
            awready_r      <= 1'b0;
            wready_r       <= 1'b0;
            bvalid_r       <= 1'b0;
            arready_r      <= 1'b0;
            rvalid_r       <= 1'b0;
            rdata_r        <= '0;
            ap_done_sticky <= 1'b0;
        end else begin
            // Write handshake (single beat)
            awready_r <= s_axi_ctrl_awvalid && !awready_r;
            wready_r  <= s_axi_ctrl_wvalid  && !wready_r;
            if (awready_r && wready_r)          bvalid_r <= 1'b1;
            else if (bvalid_r && s_axi_ctrl_bready) bvalid_r <= 1'b0;

            // Read handshake (single beat)
            arready_r <= s_axi_ctrl_arvalid && !arready_r && !rvalid_r;
            if (arready_r) begin
                rvalid_r <= 1'b1;
                if (s_axi_ctrl_araddr == 'h00) begin
                    rdata_r <= {28'd0,
                                (state==S_IDLE || state==S_DONE), // ap_ready (bit 3) proxy
                                (state==S_IDLE || state==S_DONE), // ap_idle (bit 2)
                                ap_done_sticky,                   // ap_done (bit 1)
                                1'b0};                            // ap_start RO=0
                end else begin
                    rdata_r <= '0;
                end
            end else if (rvalid_r && s_axi_ctrl_rready) begin
                rvalid_r <= 1'b0;
                // clear-on-read: if the address we just served was 0x00, clear ap_done
                if (rdata_r[1]) ap_done_sticky <= 1'b0;
            end

            // Latch ap_done when FSM enters DONE
            if (state == S_DONE) ap_done_sticky <= 1'b1;
        end
    end

    assign s_axi_ctrl_awready = awready_r;
    assign s_axi_ctrl_wready  = wready_r;
    assign s_axi_ctrl_bvalid  = bvalid_r;
    assign s_axi_ctrl_bresp   = 2'b00;
    assign s_axi_ctrl_arready = arready_r;
    assign s_axi_ctrl_rvalid  = rvalid_r;
    assign s_axi_ctrl_rdata   = rdata_r;
    assign s_axi_ctrl_rresp   = 2'b00;

endmodule

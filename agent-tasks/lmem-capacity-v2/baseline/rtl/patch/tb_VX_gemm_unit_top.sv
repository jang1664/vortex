// Steady-input testbench for VX_gemm_unit_top.
// Drives every input with a per-cycle pseudo-random pattern (toggling so
// PrimePower sees realistic switching activity), holds all valid/handshake
// signals high after reset, and dumps an FSDB for power annotation.
//
// The DUT instance name `u_VX_gemm_unit_top` and tb name `tb_VX_gemm_unit_top`
// match hwexplorer's PwrConfig defaults so STRIP_PATH lines up automatically.

`timescale 1ns / 1ps
`include "VX_define.vh"

module tb_VX_gemm_unit_top;

    // ----------------------------------------------------------------------
    // Clock & reset
    // ----------------------------------------------------------------------
    localparam real CLK_PERIOD_NS = 10.0;
    localparam int  WARMUP_CYC    = 8;
    localparam int  ACTIVE_CYC    = 256;

    logic clk = 0;
    logic reset = 1;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    // ----------------------------------------------------------------------
    // DUT parameters (use module defaults from VX_config.vh)
    // ----------------------------------------------------------------------
    localparam int I_DATA_SIZE  = `GEMM_INPUT_DATA_SIZE;
    localparam int W_DATA_SIZE  = `GEMM_WEIGHT_DATA_SIZE;
    localparam int SZ_DATA_SIZE = `GEMM_SCALE_ZERO_DATA_SIZE;
    localparam int O_DATA_SIZE  = `GEMM_OUTPUT_DATA_SIZE;
    localparam int TAG_WIDTH    = 1;
    localparam int ADDR_WIDTH   = `MEM_ADDR_WIDTH;
    localparam int ACC_ADDR_W   = `GEMM_ACC_MEM_BANK_DEPTH_ADDR_WIDTH;
    localparam int ACC_DATA_W   = `MXU_COL * 32;

    // ----------------------------------------------------------------------
    // DUT port wires
    // ----------------------------------------------------------------------
    // Input bus
    logic                          i_req_valid;
    logic                          i_req_rw;
    logic [ADDR_WIDTH-1:0]         i_req_addr;
    logic [I_DATA_SIZE*8-1:0]      i_req_data;
    logic [I_DATA_SIZE-1:0]        i_req_byteen;
    logic [TAG_WIDTH-1:0]          i_req_tag;
    wire                           i_req_ready;
    wire                           i_rsp_valid;
    wire  [I_DATA_SIZE*8-1:0]      i_rsp_data;
    wire  [TAG_WIDTH-1:0]          i_rsp_tag;
    logic                          i_rsp_ready;

    // Weight bus
    logic                          w_req_valid;
    logic                          w_req_rw;
    logic [ADDR_WIDTH-1:0]         w_req_addr;
    logic [W_DATA_SIZE*8-1:0]      w_req_data;
    logic [W_DATA_SIZE-1:0]        w_req_byteen;
    logic [TAG_WIDTH-1:0]          w_req_tag;
    wire                           w_req_ready;
    wire                           w_rsp_valid;
    wire  [W_DATA_SIZE*8-1:0]      w_rsp_data;
    wire  [TAG_WIDTH-1:0]          w_rsp_tag;
    logic                          w_rsp_ready;

    // Scale/Zero bus
    logic                          sz_req_valid;
    logic                          sz_req_rw;
    logic [ADDR_WIDTH-1:0]         sz_req_addr;
    logic [SZ_DATA_SIZE*8-1:0]     sz_req_data;
    logic [SZ_DATA_SIZE-1:0]       sz_req_byteen;
    logic [TAG_WIDTH-1:0]          sz_req_tag;
    wire                           sz_req_ready;
    wire                           sz_rsp_valid;
    wire  [SZ_DATA_SIZE*8-1:0]     sz_rsp_data;
    wire  [TAG_WIDTH-1:0]          sz_rsp_tag;
    logic                          sz_rsp_ready;

    // Output bus
    logic                          o_req_valid;
    logic                          o_req_rw;
    logic [ADDR_WIDTH-1:0]         o_req_addr;
    logic [O_DATA_SIZE*8-1:0]      o_req_data;
    logic [O_DATA_SIZE-1:0]        o_req_byteen;
    logic [TAG_WIDTH-1:0]          o_req_tag;
    wire                           o_req_ready;
    wire                           o_rsp_valid;
    wire  [O_DATA_SIZE*8-1:0]      o_rsp_data;
    wire  [TAG_WIDTH-1:0]          o_rsp_tag;
    logic                          o_rsp_ready;

    // Control IF
    logic                                   ctrl_start;
    logic                                   ctrl_quant_dir;
    logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0]    ctrl_acc_mem_base_addr;
    logic [`GEMM_ACC_MAX_CNT-1:0]           ctrl_acc_cnt;
    logic                                   ctrl_wreg_use_idx;
    logic                                   ctrl_sreg_use_idx;
    logic                                   ctrl_zreg_use_idx;
    logic                                   ctrl_is_load;
    wire                                    ctrl_idle;
    wire                                    ctrl_done;

    // Externalized acc memory ports — close the loop with a behavioral
    // memory-like model (just a register-array latch) so writes are visible
    // on reads. This is sim-only; the synthesis target excludes this model.
    wire [3:0]                     acc_mem_wr_en_o;
    wire [3:0]                     acc_mem_rd_en_o;
    wire [3:0][ACC_ADDR_W-1:0]     acc_mem_wr_addr_o;
    wire [3:0][ACC_ADDR_W-1:0]     acc_mem_rd_addr_o;
    wire [3:0][ACC_DATA_W-1:0]     acc_mem_wdata_o;
    logic [3:0][ACC_DATA_W-1:0]    acc_mem_rdata_i;

    logic [ACC_DATA_W-1:0] acc_mem_storage [3:0][(1 << ACC_ADDR_W)];
    always_ff @(posedge clk) begin
        for (int b = 0; b < 4; b++) begin
            if (acc_mem_wr_en_o[b])
                acc_mem_storage[b][acc_mem_wr_addr_o[b]] <= acc_mem_wdata_o[b];
            // OUT_REG=1 semantics: registered read (1-cycle latency).
            if (acc_mem_rd_en_o[b])
                acc_mem_rdata_i[b] <= acc_mem_storage[b][acc_mem_rd_addr_o[b]];
        end
    end

    // ----------------------------------------------------------------------
    // DUT
    // ----------------------------------------------------------------------
    VX_gemm_unit_top u_VX_gemm_unit_top (
        .clk            (clk),
        .reset          (reset),

        .i_req_valid    (i_req_valid),
        .i_req_rw       (i_req_rw),
        .i_req_addr     (i_req_addr),
        .i_req_data     (i_req_data),
        .i_req_byteen   (i_req_byteen),
        .i_req_tag      (i_req_tag),
        .i_req_ready    (i_req_ready),
        .i_rsp_valid    (i_rsp_valid),
        .i_rsp_data     (i_rsp_data),
        .i_rsp_tag      (i_rsp_tag),
        .i_rsp_ready    (i_rsp_ready),

        .w_req_valid    (w_req_valid),
        .w_req_rw       (w_req_rw),
        .w_req_addr     (w_req_addr),
        .w_req_data     (w_req_data),
        .w_req_byteen   (w_req_byteen),
        .w_req_tag      (w_req_tag),
        .w_req_ready    (w_req_ready),
        .w_rsp_valid    (w_rsp_valid),
        .w_rsp_data     (w_rsp_data),
        .w_rsp_tag      (w_rsp_tag),
        .w_rsp_ready    (w_rsp_ready),

        .sz_req_valid   (sz_req_valid),
        .sz_req_rw      (sz_req_rw),
        .sz_req_addr    (sz_req_addr),
        .sz_req_data    (sz_req_data),
        .sz_req_byteen  (sz_req_byteen),
        .sz_req_tag     (sz_req_tag),
        .sz_req_ready   (sz_req_ready),
        .sz_rsp_valid   (sz_rsp_valid),
        .sz_rsp_data    (sz_rsp_data),
        .sz_rsp_tag     (sz_rsp_tag),
        .sz_rsp_ready   (sz_rsp_ready),

        .o_req_valid    (o_req_valid),
        .o_req_rw       (o_req_rw),
        .o_req_addr     (o_req_addr),
        .o_req_data     (o_req_data),
        .o_req_byteen   (o_req_byteen),
        .o_req_tag      (o_req_tag),
        .o_req_ready    (o_req_ready),
        .o_rsp_valid    (o_rsp_valid),
        .o_rsp_data     (o_rsp_data),
        .o_rsp_tag      (o_rsp_tag),
        .o_rsp_ready    (o_rsp_ready),

        .ctrl_start             (ctrl_start),
        .ctrl_quant_dir         (ctrl_quant_dir),
        .ctrl_acc_mem_base_addr (ctrl_acc_mem_base_addr),
        .ctrl_acc_cnt           (ctrl_acc_cnt),
        .ctrl_wreg_use_idx      (ctrl_wreg_use_idx),
        .ctrl_sreg_use_idx      (ctrl_sreg_use_idx),
        .ctrl_zreg_use_idx      (ctrl_zreg_use_idx),
        .ctrl_is_load           (ctrl_is_load),
        .ctrl_idle              (ctrl_idle),
        .ctrl_done              (ctrl_done),

        .acc_mem_wr_en_o   (acc_mem_wr_en_o),
        .acc_mem_rd_en_o   (acc_mem_rd_en_o),
        .acc_mem_wr_addr_o (acc_mem_wr_addr_o),
        .acc_mem_rd_addr_o (acc_mem_rd_addr_o),
        .acc_mem_wdata_o   (acc_mem_wdata_o),
        .acc_mem_rdata_i   (acc_mem_rdata_i)
    );

    // ----------------------------------------------------------------------
    // Stimulus: random vectors on every cycle, all handshake highs asserted.
    // PrimePower's zero-delay activity propagation only needs realistic
    // toggle rates on inputs/regs, not protocol-correct traffic.
    // ----------------------------------------------------------------------
    int cycle;

    // Reset / start sequencing: drive only `reset` and `ctrl_start` from
    // an initial block — every other input is driven from a single
    // always_ff to avoid multiple-driver errors.
    initial begin
        reset = 1;
        repeat (WARMUP_CYC) @(posedge clk);
        reset = 0;
    end

    // One always_ff drives every input port. Random data each cycle gives
    // PrimePower non-trivial toggle activity. While reset is asserted, hold
    // valids low and data at zero (deterministic).
    always_ff @(posedge clk) begin
        if (reset) begin
            cycle <= 0;
            i_req_valid    <= 0;
            i_req_rw       <= 0;
            i_req_addr     <= '0;
            i_req_data     <= '0;
            i_req_byteen   <= '0;
            i_req_tag      <= '0;
            i_rsp_ready    <= 1;
            w_req_valid    <= 0;
            w_req_rw       <= 0;
            w_req_addr     <= '0;
            w_req_data     <= '0;
            w_req_byteen   <= '0;
            w_req_tag      <= '0;
            w_rsp_ready    <= 1;
            sz_req_valid   <= 0;
            sz_req_rw      <= 0;
            sz_req_addr    <= '0;
            sz_req_data    <= '0;
            sz_req_byteen  <= '0;
            sz_req_tag     <= '0;
            sz_rsp_ready   <= 1;
            o_req_valid    <= 0;
            o_req_rw       <= 0;
            o_req_addr     <= '0;
            o_req_data     <= '0;
            o_req_byteen   <= '0;
            o_req_tag      <= '0;
            o_rsp_ready    <= 1;
            ctrl_start             <= 0;
            ctrl_quant_dir         <= 0;
            ctrl_acc_mem_base_addr <= '0;
            ctrl_acc_cnt           <= '0;
            ctrl_wreg_use_idx      <= 0;
            ctrl_sreg_use_idx      <= 0;
            ctrl_zreg_use_idx      <= 0;
            ctrl_is_load           <= 0;
        end else begin
            cycle <= cycle + 1;
            // First cycle after reset: assert ctrl_start once to kick the FSM.
            ctrl_start <= (cycle == 0);
            // Steady-state random per-cycle activity.
            i_req_valid  <= 1;
            i_req_rw     <= $urandom & 1;
            i_req_addr   <= $urandom;
            for (int j = 0; j < (I_DATA_SIZE * 8) / 32; j++)
                i_req_data[j*32 +: 32] <= $urandom;
            i_req_byteen <= {(I_DATA_SIZE){1'b1}};
            i_req_tag    <= $urandom;

            w_req_valid  <= 1;
            w_req_rw     <= 0;
            w_req_addr   <= $urandom;
            for (int j = 0; j < (W_DATA_SIZE * 8) / 32; j++)
                w_req_data[j*32 +: 32] <= $urandom;
            w_req_byteen <= {(W_DATA_SIZE){1'b1}};
            w_req_tag    <= $urandom;

            sz_req_valid <= 1;
            sz_req_rw    <= 0;
            sz_req_addr  <= $urandom;
            for (int j = 0; j < (SZ_DATA_SIZE * 8) / 32; j++)
                sz_req_data[j*32 +: 32] <= $urandom;
            sz_req_byteen <= {(SZ_DATA_SIZE){1'b1}};
            sz_req_tag    <= $urandom;

            o_req_valid  <= 1;
            o_req_rw     <= $urandom & 1;
            o_req_addr   <= $urandom;
            for (int j = 0; j < (O_DATA_SIZE * 8) / 32; j++)
                o_req_data[j*32 +: 32] <= $urandom;
            o_req_byteen <= {(O_DATA_SIZE){1'b1}};
            o_req_tag    <= $urandom;
        end
    end

    // ----------------------------------------------------------------------
    // FSDB dump for PrimePower annotation.
    // ----------------------------------------------------------------------
    initial begin
        // PrimePower's pwr_setup.tcl looks for the FSDB under
        // <sim_root>/reports/<fsdb_fname>; match that convention.
        $fsdbDumpfile("./reports/tb_VX_gemm_unit_top.power.fsdb");
        $fsdbDumpvars(0, tb_VX_gemm_unit_top, "+all");
        $fsdbDumpMDA();
    end

    // ----------------------------------------------------------------------
    // Termination
    // ----------------------------------------------------------------------
    initial begin
        // Run reset+warmup+steady-state activity
        #((WARMUP_CYC + ACTIVE_CYC) * CLK_PERIOD_NS);
        $display("[tb] simulation finished at %0t (cycle %0d)", $time, cycle);
        $finish;
    end

endmodule

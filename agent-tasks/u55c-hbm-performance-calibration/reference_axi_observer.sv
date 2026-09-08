// Read-only request-boundary diagnostics; no force or DUT writes.
module reference_axi_observer;
    integer count=0;
    always @(posedge tb_vcs_xrtsim.ap_clk) begin
        if (tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arvalid === 1'b1 && count<16) begin
            $display("REFERENCE_LSU_AR t=%0t ready=%b addr=%h len=%h size=%h burst=%h",
                $time, tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arready,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_araddr,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arlen,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arsize,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arburst);
            count=count+1;
        end
    end
endmodule
bind tb_vcs_xrtsim reference_axi_observer reference_axi_observer_i();

module reference_guard_observer # (parameter AW=64)(
    input wire clk, reset_n, valid, ready,
    input wire [AW-1:0] addr,
    input wire [7:0] len
);
    integer count=0;
    always @(posedge clk)
        if (reset_n === 1'b1 && valid === 1'b1 && count<16) begin
            $display("REFERENCE_HBM_AR %m t=%0t ready=%b addr=%h len=%h", $time, ready, addr, len);
            count=count+1;
        end
endmodule
bind VX_hbm_axi_guard reference_guard_observer #(.AW(ADDR_WIDTH)) reference_guard_observer_i(
    .clk(clk), .reset_n(reset_n), .valid(arvalid), .ready(arready), .addr(araddr), .len(arlen)
);

module reference_mux_observer #(
    parameter integer N=1,
    parameter type REQ=logic,
    parameter type MREQ=logic
)(input wire clk, reset_n, input REQ [N-1:0] requests, input MREQ output_req);
    integer count=0;
    // Sample before the next accepting edge so a fatal cannot hide the input.
    always @(negedge clk)
        if (reset_n === 1'b1 && output_req.ar_valid !== 1'b0 && count<32) begin
            $display("REFERENCE_MUX_OUT %m t=%0t valid=%b addr=%h len=%h",
                $time, output_req.ar_valid, output_req.ar.addr, output_req.ar.len);
            for (integer p=0; p<N; p=p+1)
                $display("REFERENCE_MUX_IN %m t=%0t port=%0d valid=%b addr=%h len=%h",
                    $time, p, requests[p].ar_valid, requests[p].ar.addr, requests[p].ar.len);
            count=count+1;
        end
endmodule
bind axi_mux reference_mux_observer #(.N(NoSlvPorts), .REQ(slv_req_t), .MREQ(mst_req_t))
    reference_mux_observer_i(.clk(clk_i), .reset_n(rst_ni), .requests(slv_reqs_i), .output_req(mst_req_o));

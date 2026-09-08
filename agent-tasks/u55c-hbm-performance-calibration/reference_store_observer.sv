// Non-driving write/completion diagnostics for archived reference runs.
module reference_store_observer #(parameter NP=1);
    for (genvar p=0; p<NP; p=p+1) begin : ports
        integer aw_count=0, w_count=0;
        always @(posedge tb_vcs_xrtsim.ap_clk) begin
            if (tb_vcs_xrtsim.m_axi_mem_awvalid[p] === 1'b1 && tb_vcs_xrtsim.m_axi_mem_awready[p] === 1'b1) begin
                if (aw_count<4096)
                    $display("REFERENCE_STORE_AW t=%0t port=%0d addr=%h len=%h", $time, p,
                        tb_vcs_xrtsim.m_axi_mem_awaddr[p], tb_vcs_xrtsim.m_axi_mem_awlen[p]);
                aw_count=aw_count+1;
            end
            if (tb_vcs_xrtsim.m_axi_mem_wvalid[p] === 1'b1 && tb_vcs_xrtsim.m_axi_mem_wready[p] === 1'b1) begin
                if (w_count<4096)
                    $display("REFERENCE_STORE_W t=%0t port=%0d strb=%h data=%h", $time, p,
                        tb_vcs_xrtsim.m_axi_mem_wstrb[p], tb_vcs_xrtsim.m_axi_mem_wdata[p]);
                w_count=w_count+1;
            end
        end
        final $display("REFERENCE_STORE_TOTAL port=%0d aw=%0d w=%0d", p, aw_count, w_count);
    end
endmodule
bind tb_vcs_xrtsim reference_store_observer #(.NP(NUM_PORTS)) reference_store_observer_i();

module reference_done_observer(input wire clk, done_base, done_raw, drain, writes_empty);
    reg printed=0;
    always @(posedge clk)
        if (!printed && done_base === 1'b1) begin
            $display("REFERENCE_DONE %m t=%0t raw=%b drain=%b writes_empty=%b", $time, done_raw, drain, writes_empty);
            printed=1;
        end
endmodule
bind VX_afu_wrap reference_done_observer reference_done_observer_i(
    .clk(clk), .done_base(ap_done_base), .done_raw(ap_done_raw),
    .drain(vx_cache_drain), .writes_empty(vx_pending_writes_empty)
);

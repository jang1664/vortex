`timescale 1ns/1ps
// Bounded, non-driving bus timing observations plus device CSR phase markers.
module reference_startup_axi_observer #(parameter NP=1);
    for (genvar p=0; p<NP; p=p+1) begin : ports
        integer count=0;
        always @(posedge tb_vcs_xrtsim.ap_clk) begin
            if (tb_vcs_xrtsim.m_axi_mem_arvalid[p] === 1'b1 && tb_vcs_xrtsim.m_axi_mem_arready[p] === 1'b1) begin
                if (count >= 4096) $fatal(1,"STARTUP_TRACE_LIMIT");
                $display("STARTUP_AR t=%0t port=%0d id=%h addr=%h len=%h", $time, p,
                    tb_vcs_xrtsim.m_axi_mem_arid[p], tb_vcs_xrtsim.m_axi_mem_araddr[p], tb_vcs_xrtsim.m_axi_mem_arlen[p]);
                count=count+1;
            end
            if (tb_vcs_xrtsim.m_axi_mem_rvalid[p] === 1'b1 && tb_vcs_xrtsim.m_axi_mem_rready[p] === 1'b1)
                $display("STARTUP_R t=%0t port=%0d id=%h last=%b", $time, p,
                    tb_vcs_xrtsim.m_axi_mem_rid[p], tb_vcs_xrtsim.m_axi_mem_rlast[p]);
        end
    end
endmodule
bind tb_vcs_xrtsim reference_startup_axi_observer #(.NP(NUM_PORTS)) reference_startup_axi_observer_i();

module reference_startup_csr_observer #(parameter CW=64)(
    input wire clk, reset, read_enable,
    input wire [11:0] read_addr,
    input wire [CW-1:0] cycles
);
    reg was_reset=1;
    always @(posedge clk) begin
        if (reset) was_reset=1;
        else begin
            if (was_reset) begin
                $display("STARTUP_CORE_RELEASE t=%0t cycles=%0d", $time, cycles);
                was_reset=0;
            end
            if (read_enable && read_addr == 12'hb00)
                $display("STARTUP_CYCLE_SNAPSHOT t=%0t cycles=%0d", $time, cycles);
        end
    end
endmodule
bind VX_csr_data reference_startup_csr_observer #(.CW(PERF_CTR_BITS)) reference_startup_csr_observer_i(
    .clk(clk), .reset(reset), .read_enable(read_enable), .read_addr(read_addr), .cycles(cycles));

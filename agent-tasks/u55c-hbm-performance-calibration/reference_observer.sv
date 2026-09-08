// Read-only diagnostic bind. Never drives or forces archived DUT signals.
module reference_observer;
    integer records = 0;
    initial begin
        $dumpfile("reference_lsu.vcd");
        $dumpvars(1, tb_vcs_xrtsim.dut.vortex_axi);
    end
    always @(posedge tb_vcs_xrtsim.ap_clk) begin
        if (records < 100 && tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arvalid) begin
            $display("REFERENCE_AR time=%0t ready=%b addr=%h remapped=%h select=%h",
                $time, tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_arready,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_araddr,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_araddr_remapped,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_ar_select);
            records = records + 1;
        end
        if (records < 100 && tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_rvalid) begin
            $display("REFERENCE_R time=%0t ready=%b id=%h data=%h", $time,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_rready,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_rid,
                tb_vcs_xrtsim.dut.vortex_axi.lsu_axi_rdata);
            records = records + 1;
        end
    end
endmodule
bind tb_vcs_xrtsim reference_observer reference_observer_i();

module reference_core_observer(
    input wire clk, reset, dcr_valid,
    input wire [11:0] dcr_addr,
    input wire [31:0] dcr_data,
    input wire [63:0] startup_addr, warp_pc, scheduled_pc, fetch_addr,
    input wire schedule_valid, schedule_ready
);
    integer fetch_records = 0;
    always @(posedge clk)
        if (!reset && schedule_valid && fetch_records < 16) begin
            $display("REFERENCE_FETCH %m time=%0t ready=%b warp_pc=%h scheduled_pc=%h fetch_addr=%h",
                $time, schedule_ready, warp_pc, scheduled_pc, fetch_addr);
            fetch_records = fetch_records + 1;
        end
    always @(posedge clk)
        if (dcr_valid)
            $display("REFERENCE_CORE_DCR %m time=%0t reset=%b addr=%h data=%h startup=%h",
                $time, reset, dcr_addr, dcr_data, startup_addr);
    always @(negedge reset)
        $display("REFERENCE_CORE_START %m time=%0t startup=%h", $time, startup_addr);
endmodule
bind VX_core reference_core_observer reference_core_observer_i(
    .clk(clk), .reset(reset), .dcr_valid(dcr_bus_if.write_valid),
    .dcr_addr(dcr_bus_if.write_addr), .dcr_data(dcr_bus_if.write_data),
    .startup_addr(base_dcrs.startup_addr), .warp_pc(schedule.warp_pcs[0]),
    .scheduled_pc(schedule_if.data.PC), .fetch_addr(fetch.icache_req_addr),
    .schedule_valid(schedule_if.valid), .schedule_ready(schedule_if.ready)
);

module reference_cache_observer #(parameter NR=1, NP=1)(
    input wire clk, reset,
    VX_mem_bus_if core [NR],
    VX_mem_bus_if mem [NP]
);
    for (genvar p=0; p<NR; ++p) begin : core_ports
        integer count=0;
        always @(posedge clk)
            if (reset === 1'b0 && core[p].req_valid === 1'b1 && core[p].req_ready === 1'b1 && count<8) begin
                $display("REFERENCE_CACHE_IN %m time=%0t ready=%b addr=%h",
                    $time, core[p].req_ready, core[p].req_data.addr);
                count=count+1;
            end
    end
    for (genvar p=0; p<NP; ++p) begin : mem_ports
        integer count=0;
        always @(posedge clk)
            if (reset === 1'b0 && mem[p].req_valid === 1'b1 && count<8) begin
                $display("REFERENCE_CACHE_OUT %m time=%0t ready=%b addr=%h",
                    $time, mem[p].req_ready, mem[p].req_data.addr);
                count=count+1;
            end
    end
endmodule
bind VX_cache_wrap reference_cache_observer #(.NR(NUM_REQS), .NP(MEM_PORTS))
    reference_cache_observer_i(.clk(clk), .reset(reset), .core(core_bus_if), .mem(mem_bus_if));

module reference_bank_observer(
    input wire clk, reset, core_fire, selected_valid, st0_valid, st1_valid,
    input wire push, mem_valid, stall,
    input wire [63:0] core_addr, selected_addr, st0_addr, st1_addr, queue_addr, mem_addr
);
    integer count=0;
    always @(posedge clk)
        if (reset === 1'b0 && count<32 &&
            (core_fire === 1'b1 || push === 1'b1 || mem_valid === 1'b1)) begin
            $display("REFERENCE_BANK %m time=%0t fire=%b core=%h sel_v=%b sel=%h st0_v=%b st0=%h st1_v=%b st1=%h push=%b queue=%h mem_v=%b mem=%h stall=%b",
                $time, core_fire, core_addr, selected_valid, selected_addr,
                st0_valid, st0_addr, st1_valid, st1_addr, push, queue_addr,
                mem_valid, mem_addr, stall);
            count=count+1;
        end
endmodule
bind VX_cache_bank reference_bank_observer reference_bank_observer_i(
    .clk(clk), .reset(reset), .core_fire(core_req_fire),
    .selected_valid(valid_sel), .st0_valid(valid_st0), .st1_valid(valid_st1),
    .push(mreq_queue_push), .mem_valid(mem_req_valid), .stall(pipe_stall),
    .core_addr(core_req_addr), .selected_addr(addr_sel),
    .st0_addr(addr_st0), .st1_addr(addr_st1), .queue_addr(mreq_queue_addr),
    .mem_addr(mem_req_addr)
);

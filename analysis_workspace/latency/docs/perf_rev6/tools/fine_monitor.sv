`include "VX_define.vh"
// Passive simulation-only observation. No DUT signals are driven.
package fine_scope;
  bit active = 0;
  bit gemm_active = 0;
endpackage
module fine_core import VX_gpu_pkg::*; (
 input wire clk, reset, busy,
 input accel_perf_t p,
 input sysmem_perf_t m
);
 longint unsigned pipeline_cycles = 0, previous_total = 0;
 always @(negedge clk) begin
   fine_scope::active = busy && !reset;
   fine_scope::gemm_active = !reset && (p.gemm_node.total_cycles > previous_total);
   previous_total = p.gemm_node.total_cycles;
   if (reset) pipeline_cycles = 0;
   else if (p.gemm_unit.computing) pipeline_cycles++;
 end
 final begin
   $display("FINE CORE pipeline_cycles=%0d", pipeline_cycles);
   $display("FINE core busy_cycles=%0d overlap_dma_mxu=%0d dma_union_active_cycles=%0d", p.busy_cycles, p.overlap_dma_mxu, p.dma_union_active_cycles);
   $display("FINE gemm_node total_cycles=%0d lmem_rd_bytes=%0d lmem_wr_bytes=%0d", p.gemm_node.total_cycles, p.gemm_node.lmem_rd_bytes, p.gemm_node.lmem_wr_bytes);
   $display("FINE gemm_unit compute_cycles=%0d stall_cycles=%0d job_count=%0d input_fire=%0d weight_fire=%0d output_fire=%0d mac_count=%0d accum_rd_accept=%0d accum_wr_fire=%0d", p.gemm_unit.compute_cycles, p.gemm_unit.stall_cycles, p.gemm_unit.job_count, p.gemm_unit.input_fire, p.gemm_unit.weight_fire, p.gemm_unit.output_fire, p.gemm_unit.mac_count, p.gemm_unit.accum_rd_accept, p.gemm_unit.accum_wr_fire);
   $display("FINE cpu_dma rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.cpu_dma.rd_bytes, p.cpu_dma.wr_bytes, p.cpu_dma.xfer_count, p.cpu_dma.active_cycles, p.cpu_dma.src_rd_req_fire, p.cpu_dma.src_rd_req_stall, p.cpu_dma.src_rd_data_fire, p.cpu_dma.src_rd_data_stall, p.cpu_dma.dst_wr_fire, p.cpu_dma.dst_wr_stall, p.cpu_dma.wait_dcache, p.cpu_dma.wait_lmem);
   $display("FINE hbm_dma.aggregate rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.hbm_dma.aggregate.rd_bytes, p.hbm_dma.aggregate.wr_bytes, p.hbm_dma.aggregate.xfer_count, p.hbm_dma.aggregate.active_cycles, p.hbm_dma.aggregate.src_rd_req_fire, p.hbm_dma.aggregate.src_rd_req_stall, p.hbm_dma.aggregate.src_rd_data_fire, p.hbm_dma.aggregate.src_rd_data_stall, p.hbm_dma.aggregate.dst_wr_fire, p.hbm_dma.aggregate.dst_wr_stall, p.hbm_dma.aggregate.wait_dcache, p.hbm_dma.aggregate.wait_lmem);
   $display("FINE lmem_dma_input rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.lmem_dma_input.rd_bytes, p.lmem_dma_input.wr_bytes, p.lmem_dma_input.xfer_count, p.lmem_dma_input.active_cycles, p.lmem_dma_input.src_rd_req_fire, p.lmem_dma_input.src_rd_req_stall, p.lmem_dma_input.src_rd_data_fire, p.lmem_dma_input.src_rd_data_stall, p.lmem_dma_input.dst_wr_fire, p.lmem_dma_input.dst_wr_stall, p.lmem_dma_input.wait_dcache, p.lmem_dma_input.wait_lmem);
   $display("FINE lmem_dma_weight rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.lmem_dma_weight.rd_bytes, p.lmem_dma_weight.wr_bytes, p.lmem_dma_weight.xfer_count, p.lmem_dma_weight.active_cycles, p.lmem_dma_weight.src_rd_req_fire, p.lmem_dma_weight.src_rd_req_stall, p.lmem_dma_weight.src_rd_data_fire, p.lmem_dma_weight.src_rd_data_stall, p.lmem_dma_weight.dst_wr_fire, p.lmem_dma_weight.dst_wr_stall, p.lmem_dma_weight.wait_dcache, p.lmem_dma_weight.wait_lmem);
   $display("FINE lmem_dma_sz rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.lmem_dma_sz.rd_bytes, p.lmem_dma_sz.wr_bytes, p.lmem_dma_sz.xfer_count, p.lmem_dma_sz.active_cycles, p.lmem_dma_sz.src_rd_req_fire, p.lmem_dma_sz.src_rd_req_stall, p.lmem_dma_sz.src_rd_data_fire, p.lmem_dma_sz.src_rd_data_stall, p.lmem_dma_sz.dst_wr_fire, p.lmem_dma_sz.dst_wr_stall, p.lmem_dma_sz.wait_dcache, p.lmem_dma_sz.wait_lmem);
   $display("FINE lmem_dma_output rd_bytes=%0d wr_bytes=%0d xfer_count=%0d active_cycles=%0d src_rd_req_fire=%0d src_rd_req_stall=%0d src_rd_data_fire=%0d src_rd_data_stall=%0d dst_wr_fire=%0d dst_wr_stall=%0d wait_dcache=%0d wait_lmem=%0d", p.lmem_dma_output.rd_bytes, p.lmem_dma_output.wr_bytes, p.lmem_dma_output.xfer_count, p.lmem_dma_output.active_cycles, p.lmem_dma_output.src_rd_req_fire, p.lmem_dma_output.src_rd_req_stall, p.lmem_dma_output.src_rd_data_fire, p.lmem_dma_output.src_rd_data_stall, p.lmem_dma_output.dst_wr_fire, p.lmem_dma_output.dst_wr_stall, p.lmem_dma_output.wait_dcache, p.lmem_dma_output.wait_lmem);
   $display("FINE hbm_channels active_max=%0d active_min=%0d", p.hbm_dma.active_cycles_max, p.hbm_dma.active_cycles_min);
   $display("FINE lmem reads=%0d writes=%0d bank_stalls=%0d crsp_stalls=%0d",m.lmem.reads,m.lmem.writes,m.lmem.bank_stalls,m.lmem.crsp_stalls);
 end
endmodule
bind VX_core fine_core u_fine_core (.clk(clk),.reset(reset),.busy(busy),.p(accel_perf),.m(sysmem_perf_tmp));

module fine_axi # (parameter N=4, parameter D=512) (
 input wire clk, rst_n,
 input wire rv[N], rr[N], wv[N], wr[N], av[N], ar[N], awv[N], awr[N],
 input wire [D/8-1:0] ws[N]
);
 longint unsigned cycles=0, wc=0, windows=0;
 longint unsigned gc=0, gwc=0, gwin=0, grd=0, gwr=0, gwr_sum=0, grd_sum=0;
 longint unsigned rd[N], wb[N], rstall[N], wstall[N], arstall[N], awstall[N];
 longint unsigned win_rd=0, win_wr=0;
 longint unsigned sum_rd=0, sum_wr=0;
 initial begin
   for(int i=0;i<N;i++) begin rd[i]=0;wb[i]=0;rstall[i]=0;wstall[i]=0;arstall[i]=0;awstall[i]=0;end
 end
 always @(posedge clk) begin
   if(rst_n && fine_scope::gemm_active) begin
     gc++;gwc++;
     for(int i=0;i<N;i++) begin
       if(rv[i] && rr[i]) begin grd+=D/8;grd_sum+=D/8;end
       if(wv[i] && wr[i]) begin gwr+=$countones(ws[i]);gwr_sum+=$countones(ws[i]);end
     end
     if(gwc==1024) begin
       $display("FINE GEMM_WINDOW index=%0d cycles=%0d rd_bytes=%0d wr_bytes=%0d",gwin,gwc,grd,gwr);
       gwin++;gwc=0;grd=0;gwr=0;
     end
   end
   if(rst_n && fine_scope::active) begin
     cycles++;wc++;
     for(int i=0;i<N;i++) begin
       if(rv[i] && rr[i]) begin rd[i]+=D/8;win_rd+=D/8;sum_rd+=D/8;end
       if(wv[i] && wr[i]) begin wb[i]+=$countones(ws[i]);win_wr+=$countones(ws[i]);sum_wr+=$countones(ws[i]);end
       if(rv[i] && !rr[i]) rstall[i]++;
       if(wv[i] && !wr[i]) wstall[i]++;
       if(av[i] && !ar[i]) arstall[i]++;
       if(awv[i] && !awr[i]) awstall[i]++;
     end
     if(wc==1024) begin
       $display("FINE WINDOW index=%0d cycles=%0d rd_bytes=%0d wr_bytes=%0d",windows,wc,win_rd,win_wr);
       windows++;wc=0;win_rd=0;win_wr=0;
     end
   end
 end
 final begin
   if(gwc!=0) $display("FINE GEMM_WINDOW_TAIL cycles=%0d rd_bytes=%0d wr_bytes=%0d",gwc,grd,gwr);
   $display("FINE GEMM_AXI cycles=%0d rd_bytes=%0d wr_bytes=%0d",gc,grd_sum,gwr_sum);
   if(wc!=0) $display("FINE WINDOW_TAIL cycles=%0d rd_bytes=%0d wr_bytes=%0d",wc,win_rd,win_wr);
   $display("FINE AXI cycles=%0d rd_bytes=%0d wr_bytes=%0d ports=%0d bytes_per_beat=%0d",cycles,sum_rd,sum_wr,N,D/8);
   for(int i=0;i<N;i++)
     $display("FINE AXI_PORT index=%0d rd_bytes=%0d wr_bytes=%0d r_stall=%0d w_stall=%0d ar_stall=%0d aw_stall=%0d",i,rd[i],wb[i],rstall[i],wstall[i],arstall[i],awstall[i]);
 end
endmodule
bind tb_vcs_xrtsim fine_axi #(.N(NUM_PORTS),.D(C_M_AXI_MEM_DATA_WIDTH)) u_fine_axi(
 .clk(ap_clk),.rst_n(ap_rst_n),.rv(m_axi_mem_rvalid),.rr(m_axi_mem_rready),
 .wv(m_axi_mem_wvalid),.wr(m_axi_mem_wready),.ws(m_axi_mem_wstrb),
 .av(m_axi_mem_arvalid),.ar(m_axi_mem_arready),.awv(m_axi_mem_awvalid),.awr(m_axi_mem_awready));

module fine_tmem #(parameter P=6, parameter D=32) (
 input wire clk,reset,
 VX_mem_bus_if mem_bus_if[P]
);
 wire [P-1:0] v,r,w;
 wire [D-1:0] be[P];
 for(genvar g=0;g<P;g++) begin
   assign v[g]=mem_bus_if[g].req_valid;
   assign r[g]=mem_bus_if[g].req_ready;
   assign w[g]=mem_bus_if[g].req_data.rw;
   assign be[g]=mem_bus_if[g].req_data.byteen;
 end
 longint unsigned rd=0,wr=0,collision_cycles=0,collision_denied=0,blocked=0;
 always @(posedge clk) begin
   if(reset) begin rd=0;wr=0;collision_cycles=0;collision_denied=0;blocked=0;end
   else begin
     if($countones(v)>1 && |(v&r)) begin collision_cycles++;collision_denied+=$countones(v&~r);end
     blocked+=$countones(v&~r);
     for(int i=0;i<P;i++) if(v[i]&&r[i]) begin
       if(w[i]) wr+=$countones(be[i]); else rd+=D;
     end
   end
 end
 final $display("FINE TMEM path=%m rd_bytes=%0d wr_bytes=%0d collision_cycles=%0d collision_denied=%0d blocked=%0d",rd,wr,collision_cycles,collision_denied,blocked);
endmodule
`ifdef GEMM_IMPROVE
bind VX_tensor_mem_bank fine_tmem #(.P(NUM_PORTS),.D(DATA_SIZE)) u_fine_tmem(.clk(clk),.reset(reset),.mem_bus_if(mem_bus_if));
`endif

// LMEM physical SRAM transactions: reads are full bank words; writes use byte enables.
module fine_lmem #(parameter N=16, parameter D=8) (
 input wire clk,reset,
 input wire [N-1:0] v,r,w,
 input wire [N-1:0][D-1:0] be
);
 longint unsigned rd=0,wr=0;
 always @(posedge clk) begin
   if(reset) begin rd=0;wr=0;end
   else for(int i=0;i<N;i++) if(v[i] && r[i]) begin
     if(w[i]) wr+=$countones(be[i]);else rd+=D;
   end
 end
 final $display("FINE LMEM_PHYSICAL rd_bytes=%0d wr_bytes=%0d banks=%0d bytes_per_word=%0d",rd,wr,N,D);
endmodule
bind VX_local_mem fine_lmem #(.N(NUM_BANKS),.D(WORD_SIZE)) u_fine_lmem(.clk(clk),.reset(reset),.v(per_bank_req_valid),.r(per_bank_req_ready),.w(per_bank_req_rw),.be(per_bank_req_byteen));

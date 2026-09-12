`timescale 1ns/1ps
// End-to-end identity and bandwidth checks at the cache/AXI adapter boundary.
// The reference mapping below is arithmetic, independent of VX_mem_remap.
module axi_adapter_case #(parameter P=2, K=2, H=8, TAGO=5, TAG_SLOTS=16, REQBUF=2, RSPBUF=2, FULL_SUITE=1)(output logic done=0);
    localparam NMAX=512;
    logic clk=0;
    always #5 clk=~clk;
    logic reset=1;
    wire busy;
    logic mem_req_valid [P];
    logic mem_req_rw [P];
    logic [63:0] mem_req_byteen [P];
    logic [27:0] mem_req_addr [P];
    logic [511:0] mem_req_data [P];
    logic [11:0] mem_req_tag [P];
    wire mem_req_ready [P];
    wire mem_rsp_valid [P];
    wire [511:0] mem_rsp_data [P];
    wire [11:0] mem_rsp_tag [P];
    logic mem_rsp_ready [P];
    wire  m_axi_awvalid [H];
    logic  m_axi_awready [H];
    wire [33:0] m_axi_awaddr [H];
    wire [TAGO-1:0] m_axi_awid [H];
    wire [7:0] m_axi_awlen [H];
    wire [2:0] m_axi_awsize [H];
    wire [1:0] m_axi_awburst [H];
    wire [1:0] m_axi_awlock [H];
    wire [3:0] m_axi_awcache [H];
    wire [2:0] m_axi_awprot [H];
    wire [3:0] m_axi_awqos [H];
    wire [3:0] m_axi_awregion [H];
    wire  m_axi_arvalid [H];
    logic  m_axi_arready [H];
    wire [33:0] m_axi_araddr [H];
    wire [TAGO-1:0] m_axi_arid [H];
    wire [7:0] m_axi_arlen [H];
    wire [2:0] m_axi_arsize [H];
    wire [1:0] m_axi_arburst [H];
    wire [1:0] m_axi_arlock [H];
    wire [3:0] m_axi_arcache [H];
    wire [2:0] m_axi_arprot [H];
    wire [3:0] m_axi_arqos [H];
    wire [3:0] m_axi_arregion [H];
    wire  m_axi_wvalid [H];
    logic  m_axi_wready [H];
    wire [511:0] m_axi_wdata [H];
    wire [63:0] m_axi_wstrb [H];
    wire  m_axi_wlast [H];
    logic  m_axi_bvalid [H];
    wire  m_axi_bready [H];
    logic [TAGO-1:0] m_axi_bid [H];
    logic [1:0] m_axi_bresp [H];
    logic  m_axi_rvalid [H];
    wire  m_axi_rready [H];
    logic [511:0] m_axi_rdata [H];
    logic  m_axi_rlast [H];
    logic [TAGO-1:0] m_axi_rid [H];
    logic [1:0] m_axi_rresp [H];

    VX_axi_adapter #(
        .DATA_WIDTH(512), .ADDR_WIDTH_IN(28), .ADDR_WIDTH_OUT(34),
        .TAG_WIDTH_IN(12), .TAG_WIDTH_OUT(TAGO), .TAG_BUFFER_SIZE(TAG_SLOTS),
        .NUM_PORTS_IN(P), .NUM_BANKS_OUT(K), .NUM_HBM_PORTS(H),
        .INTERLEAVE(1), .REQ_OUT_BUF(REQBUF), .RSP_OUT_BUF(RSPBUF)
    ) dut (
        .clk(clk), .reset(reset), .busy(busy),
        .mem_req_valid(mem_req_valid),
        .mem_req_rw(mem_req_rw),
        .mem_req_byteen(mem_req_byteen),
        .mem_req_addr(mem_req_addr),
        .mem_req_data(mem_req_data),
        .mem_req_tag(mem_req_tag),
        .mem_req_ready(mem_req_ready),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_data(mem_rsp_data),
        .mem_rsp_tag(mem_rsp_tag),
        .mem_rsp_ready(mem_rsp_ready),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awid(m_axi_awid),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awregion(m_axi_awregion),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arid(m_axi_arid),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arregion(m_axi_arregion),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rid(m_axi_rid),
        .m_axi_rresp(m_axi_rresp)
    );

    int phase=0, cycle=0, count=0;
    int accepted[P], retired[P], active[P], peak_active[P];
    bit seen[P][NMAX], ar_seen[P][NMAX], aw_seen[P][NMAX];
    bit w_seen[P][NMAX], rsp_seen[P][NMAX], pending[P][NMAX];
    int read_id[P][NMAX], read_order[P][NMAX];
    int r_owner[H], r_tag[H];
    int b_count[H], b_rd[H], b_wr[H], b_ids[H][NMAX*P];
    int aw_rd[H], aw_wr[H], w_rd[H], w_wr[H];
    int aw_items[H][NMAX*P], w_items[H][NMAX*P];
    int req_total, ar_total, aw_total, w_total, r_total, rsp_total, b_total;
    int exhausted_cycles, reorder_count, last_return_order;
    int aw_first_count, w_first_count;
    int id_reuses, same_input_contenders, within_group_reorders;
    bit id_used[P][1<<TAGO];
    int last_group_order[K];
    int measure_req, measure_ar, measure_aw, measure_w, measure_rsp;
    bit hold_aw[H], hold_w[H], hold_ar[H], hold_rsp[P];
    logic [TAGO+33:0] held_aw[H], held_ar[H];
    logic [576:0] held_w[H];
    logic [523:0] held_rsp[P];

    function automatic bit is_write(input int t);
        return phase==3 || (phase==1 && t%4==3);
    endfunction
    function automatic longint unsigned block_addr(input int owner, t);
        longint unsigned result;
        if (phase==1) begin
            // At least two complete 32-bank rotations, followed by high rows.
            result=t+owner*129;
            if (t>=64) result=result+(64'h1<<24);
        end else if (phase==4) begin
            result=t*32+owner*2; // {0,2}: conflict at K=2, independent at K>=4.
        end else if (phase==5) begin
            result=t*32+owner*8192; // {0,0}: distinct addresses, same destination.
        end else begin
            result=t*32+owner; // {0,1}: independent groups for K>=2.
        end
        return result;
    endfunction
    function automatic int destination(input int owner, t);
        return block_addr(owner,t)%H;
    endfunction
    function automatic logic [33:0] physical_addr(input int owner, t);
        longint unsigned block, bank, row;
        block=block_addr(owner,t);
        bank=(block%H)*(32/H)+(block/H)%(32/H);
        row=block/32;
        return 34'((bank<<29)|(row<<6));
    endfunction
    function automatic logic [511:0] pattern(input int owner,t);
        logic [511:0] result;
        for (int lane=0;lane<16;lane++)
            result[lane*32+:32]=32'h96300000 ^ (owner<<20) ^ (t<<4) ^ lane;
        return result;
    endfunction
    function automatic int expected_rate();
        if (phase==5 || (phase==4 && K<=2)) return 1;
        return (P<K)?P:K;
    endfunction

    // Deterministic, independently stalled channels. R responses are held until
    // tags exhaust and are then selected newest-first in the mixed phase.
    always @(negedge clk) begin
        for (int p=0;p<P;p++) begin
            mem_req_valid[p]=!reset && accepted[p]<count;
            mem_req_rw[p]=is_write(accepted[p]);
            mem_req_byteen[p]=64'hfedcba9876543210;
            mem_req_addr[p]=28'(block_addr(p,accepted[p]));
            mem_req_data[p]=pattern(p,accepted[p]);
            mem_req_tag[p]=12'(accepted[p]);
            mem_rsp_ready[p]=!reset && (phase!=1 || cycle%11>2);
        end
        for (int h=0;h<H;h++) begin
            m_axi_arready[h]=!reset && (phase!=1 || (cycle+h)%7!=0);
            m_axi_awready[h]=!reset && (phase!=1 || (cycle+h)%12<6);
            m_axi_wready[h]=!reset && (phase!=1 || (cycle+h)%12>=6);
            m_axi_bresp[h]=0;
            m_axi_rresp[h]=0;
            m_axi_rlast[h]=1;
            if (reset) begin
                m_axi_rvalid[h]=0;
                m_axi_bvalid[h]=0;
                m_axi_rid[h]=0;
                m_axi_rdata[h]=0;
                m_axi_bid[h]=0;
                r_owner[h]=-1;
                r_tag[h]=-1;
            end else begin
                // posedge removes a delivered response from the pending pool.
                if (r_owner[h]>=0 && !pending[r_owner[h]][r_tag[h]])
                    m_axi_rvalid[h]=0;
                if (!m_axi_rvalid[h] && (phase!=1 || cycle>=256)) begin
                    automatic int best=-1;
                    automatic int best_p=-1;
                    automatic int best_t=-1;
                    for (int p=0;p<P;p++) begin
                        for (int t=0;t<count;t++) begin
                            if (pending[p][t] && destination(p,t)==h
                                && (best<0 || (phase==1 ? read_order[p][t]>best : read_order[p][t]<best))) begin
                                best=read_order[p][t]; best_p=p; best_t=t;
                            end
                        end
                    end
                    if (best_p>=0) begin
                        m_axi_rvalid[h]=1;
                        m_axi_rid[h]=TAGO'(read_id[best_p][best_t]);
                        m_axi_rdata[h]=pattern(best_p,best_t);
                        r_owner[h]=best_p; r_tag[h]=best_t;
                    end
                end
                m_axi_bvalid[h]=(b_count[h]>0) && (phase!=1 || cycle%9==0);
                m_axi_bid[h]=TAGO'(b_ids[h][b_rd[h]]);
            end
        end
    end

    // Request identity is recorded at cache acceptance. AXI requests must match
    // a recorded request's independently calculated destination and address.
    // No assumption about response order is used to check the returned tag/data.
    always @(posedge clk) begin : monitor
        int nr, na, nw, nd, ns;
        int owner, tag, found, item;
        nr=0; na=0; nw=0; nd=0; ns=0;
        if (!reset) begin
            cycle++;
            for (int p=0;p<P;p++) begin
                if (mem_req_valid[p] && mem_req_ready[p]) begin
                    tag=int'(mem_req_tag[p]);
                    if (tag!=accepted[p] || seen[p][tag]) $fatal(1,"request identity duplication P%0d K%0d H%0d",P,K,H);
                    seen[p][tag]=1;
                    if (!mem_req_rw[p]) begin
                        active[p]++;
                        if (active[p]>peak_active[p]) peak_active[p]=active[p];
                    end
                    accepted[p]++; req_total++; nr++;
                end
                if (phase==1 && cycle<256 && mem_req_valid[p] && !mem_req_rw[p]
                    && !mem_req_ready[p] && active[p]==TAG_SLOTS) exhausted_cycles++;
                if (hold_rsp[p] && (!mem_rsp_valid[p] || {mem_rsp_tag[p],mem_rsp_data[p]}!==held_rsp[p]))
                    $fatal(1,"cache response changed under backpressure P%0d K%0d port%0d",P,K,p);
                hold_rsp[p]=mem_rsp_valid[p]&&!mem_rsp_ready[p];
                held_rsp[p]={mem_rsp_tag[p],mem_rsp_data[p]};
                if (mem_rsp_valid[p] && mem_rsp_ready[p]) begin
                    tag=int'(mem_rsp_tag[p]);
                    if (tag>=count || !seen[p][tag] || !ar_seen[p][tag] || rsp_seen[p][tag]
                        || is_write(tag) || mem_rsp_data[p]!==pattern(p,tag))
                        $fatal(1,"response identity/data mismatch P%0d K%0d H%0d input%0d tag%0d",P,K,H,p,tag);
                    rsp_seen[p][tag]=1; active[p]--; retired[p]++; rsp_total++; ns++;
                end
            end
            for (int p=0;p<P;p++) begin
                int contenders;
                contenders=0;
                for (int h=0;h<H;h++)
                    if (m_axi_rvalid[h] && r_owner[h]==p) contenders++;
                if (contenders>1) same_input_contenders++;
            end
            for (int h=0;h<H;h++) begin
                if (hold_aw[h] && (!m_axi_awvalid[h] || {m_axi_awid[h],m_axi_awaddr[h]}!==held_aw[h]))
                    $fatal(1,"AW changed under backpressure K%0d H%0d port%0d",K,H,h);
                if (hold_ar[h] && (!m_axi_arvalid[h] || {m_axi_arid[h],m_axi_araddr[h]}!==held_ar[h]))
                    $fatal(1,"AR changed under backpressure K%0d H%0d port%0d",K,H,h);
                if (hold_w[h] && (!m_axi_wvalid[h] || {m_axi_wlast[h],m_axi_wstrb[h],m_axi_wdata[h]}!==held_w[h]))
                    $fatal(1,"W changed under backpressure K%0d H%0d port%0d",K,H,h);
                hold_aw[h]=m_axi_awvalid[h]&&!m_axi_awready[h]; held_aw[h]={m_axi_awid[h],m_axi_awaddr[h]};
                hold_ar[h]=m_axi_arvalid[h]&&!m_axi_arready[h]; held_ar[h]={m_axi_arid[h],m_axi_araddr[h]};
                hold_w[h]=m_axi_wvalid[h]&&!m_axi_wready[h]; held_w[h]={m_axi_wlast[h],m_axi_wstrb[h],m_axi_wdata[h]};
                if (m_axi_arvalid[h] && m_axi_arready[h]) begin
                    owner=P==1?0:int'(m_axi_arid[h]&1);
                    found=-1;
                    for (int t=0;t<count;t++)
                        if (seen[owner][t] && !is_write(t) && !ar_seen[owner][t]
                            && destination(owner,t)==h && physical_addr(owner,t)==m_axi_araddr[h] && found<0) found=t;
                    if (found<0) $fatal(1,"unexpected/misrouted AR K%0d H%0d port%0d addr%h id%h",K,H,h,m_axi_araddr[h],m_axi_arid[h]);
                    if (m_axi_arlen[h]!=0 || m_axi_arsize[h]!=6) $fatal(1,"invalid read geometry");
                    for (int t=0;t<count;t++)
                        if (ar_seen[owner][t] && !rsp_seen[owner][t] && read_id[owner][t]==int'(m_axi_arid[h]))
                            $fatal(1,"read ID reused before cache retirement P%0d K%0d H%0d input%0d",P,K,H,owner);
                    if (id_used[owner][int'(m_axi_arid[h])]) id_reuses++;
                    id_used[owner][int'(m_axi_arid[h])]=1;
                    ar_seen[owner][found]=1; pending[owner][found]=1;
                    read_id[owner][found]=int'(m_axi_arid[h]); read_order[owner][found]=ar_total;
                    ar_total++; na++;
                end
                if (m_axi_awvalid[h] && m_axi_awready[h]) begin
                    found=-1;
                    for (int p=0;p<P;p++)
                        for (int t=0;t<count;t++)
                            if (seen[p][t] && is_write(t) && !aw_seen[p][t]
                                && destination(p,t)==h && physical_addr(p,t)==m_axi_awaddr[h] && found<0) begin
                                found=t; owner=p;
                            end
                    if (found<0) $fatal(1,"unexpected/misrouted AW K%0d H%0d port%0d addr%h",K,H,h,m_axi_awaddr[h]);
                    if (m_axi_awlen[h]!=0 || m_axi_awsize[h]!=6) $fatal(1,"invalid write geometry");
                    aw_seen[owner][found]=1;
                    aw_items[h][aw_wr[h]++]=owner*NMAX+found;
                    b_ids[h][b_wr[h]++]=int'(m_axi_awid[h]);
                    aw_total++; nw++;
                end
                if (m_axi_wvalid[h] && m_axi_wready[h]) begin
                    found=-1;
                    for (int p=0;p<P;p++)
                        for (int t=0;t<count;t++)
                            if (seen[p][t] && is_write(t) && !w_seen[p][t] && m_axi_wdata[h]===pattern(p,t) && found<0) begin
                                found=t; owner=p;
                            end
                    if (found<0 || destination(owner,found)!=h || m_axi_wstrb[h]!==64'hfedcba9876543210 || !m_axi_wlast[h])
                        $fatal(1,"unexpected/misrouted W K%0d H%0d port%0d",K,H,h);
                    w_seen[owner][found]=1; w_items[h][w_wr[h]++]=owner*NMAX+found;
                    w_total++; nd++;
                end
                if (aw_wr[h]>aw_rd[h] && w_wr[h]==w_rd[h]) aw_first_count++;
                if (w_wr[h]>w_rd[h] && aw_wr[h]==aw_rd[h]) w_first_count++;
                if (aw_rd[h]<aw_wr[h] && w_rd[h]<w_wr[h]) begin
                    if (aw_items[h][aw_rd[h]]!=w_items[h][w_rd[h]]) $fatal(1,"AW/W pair identity mismatch K%0d H%0d port%0d",K,H,h);
                    aw_rd[h]++; w_rd[h]++; b_count[h]++;
                end
                if (m_axi_bvalid[h] && m_axi_bready[h]) begin
                    if (b_count[h]<=0) $fatal(1,"duplicate B");
                    b_count[h]--; b_rd[h]++; b_total++;
                end
                if (m_axi_rvalid[h] && m_axi_rready[h]) begin
                    owner=r_owner[h]; tag=r_tag[h];
                    if (!pending[owner][tag]) $fatal(1,"duplicate AXI R");
                    pending[owner][tag]=0; r_total++;
                    if (read_order[owner][tag]<last_return_order) reorder_count++;
                    last_return_order=read_order[owner][tag];
                    if (read_order[owner][tag]<last_group_order[h%K]) within_group_reorders++;
                    last_group_order[h%K]=read_order[owner][tag];
                end
            end
            // Measure a contiguous 64-cycle interval, beyond all queue depths.
            if (phase!=1 && cycle>=65 && cycle<=128) begin
                measure_req+=nr; measure_ar+=na; measure_aw+=nw; measure_w+=nd; measure_rsp+=ns;
                if (nr!=expected_rate() || (phase==3 ? (nw!=expected_rate() || nd!=expected_rate()) : (na!=expected_rate() || ns!=expected_rate())))
                    $fatal(1,"sustained throughput mismatch P%0d K%0d H%0d phase%0d cycle%0d rate%0d req%0d ar%0d aw%0d w%0d rsp%0d",P,K,H,phase,cycle,expected_rate(),nr,na,nw,nd,ns);
            end
            if ((ar_total>rsp_total || aw_total>b_total || w_total>b_total) && !busy)
                $fatal(1,"busy deasserted with unfinished transport P%0d K%0d H%0d",P,K,H);
            if (cycle>12000) $fatal(1,"timeout P%0d K%0d H%0d phase%0d req%0d ar%0d aw%0d w%0d rsp%0d",P,K,H,phase,req_total,ar_total,aw_total,w_total,rsp_total);
        end
    end

    task automatic run_phase(input int next_phase);
        int reads, writes;
        @(negedge clk); #1; reset=1;
        repeat (4) @(posedge clk);
        @(negedge clk); #1;
        phase=next_phase; cycle=0; count=phase==1?96:256;
        req_total=0; ar_total=0; aw_total=0; w_total=0; r_total=0; rsp_total=0; b_total=0;
        exhausted_cycles=0; reorder_count=0; last_return_order=-1;
        aw_first_count=0; w_first_count=0;
        id_reuses=0; same_input_contenders=0; within_group_reorders=0;
        for (int g=0;g<K;g++) last_group_order[g]=-1;
        measure_req=0; measure_ar=0; measure_aw=0; measure_w=0; measure_rsp=0;
        reads=0; writes=0;
        for (int p=0;p<P;p++) begin
            accepted[p]=0; retired[p]=0; active[p]=0; peak_active[p]=0; hold_rsp[p]=0;
            for (int id=0;id<(1<<TAGO);id++) id_used[p][id]=0;
            for (int t=0;t<NMAX;t++) begin
                seen[p][t]=0; ar_seen[p][t]=0; aw_seen[p][t]=0;
                w_seen[p][t]=0; rsp_seen[p][t]=0; pending[p][t]=0;
                if (t<count) begin
                    if (is_write(t)) writes++; else reads++;
                end
            end
        end
        for (int h=0;h<H;h++) begin
            b_count[h]=0; b_rd[h]=0; b_wr[h]=0;
            aw_rd[h]=0; aw_wr[h]=0; w_rd[h]=0; w_wr[h]=0;
            hold_aw[h]=0; hold_w[h]=0; hold_ar[h]=0;
        end
        reset=0;
        do begin
            @(negedge clk); #1;
        end while (req_total!=count*P || rsp_total!=reads || b_total!=writes);
        repeat (8) @(negedge clk);
        #1;
        if (busy || ar_total!=reads || r_total!=reads || aw_total!=writes || w_total!=writes)
            $fatal(1,"incomplete drain P%0d K%0d H%0d phase%0d",P,K,H,phase);
        for (int p=0;p<P;p++) begin
            if (active[p]!=0) $fatal(1,"leaked read identity");
            for (int t=0;t<count;t++)
                if (!seen[p][t] || (is_write(t)?(!aw_seen[p][t]||!w_seen[p][t]):!rsp_seen[p][t]))
                    $fatal(1,"missing transaction P%0d K%0d H%0d input%0d tag%0d",P,K,H,p,t);
        end
        if (phase==1) begin
            if (((TAGO<12+$clog2(P)) && (exhausted_cycles==0 || id_reuses==0))
                || (TAG_SLOTS>1 && (reorder_count==0 || within_group_reorders==0))
                || (TAG_SLOTS>1 && H>1 && same_input_contenders==0)
                || aw_first_count==0 || w_first_count==0)
                $fatal(1,"missing stress coverage P%0d K%0d H%0d exhaustion%0d reorder%0d AWfirst%0d Wfirst%0d",P,K,H,exhausted_cycles,reorder_count,aw_first_count,w_first_count);
            $display("IDENTITY P=%0d K=%0d H=%0d tag_out=%0d slots=%0d reused=%0d same_input_contenders=%0d within_group_reorders=%0d",P,K,H,TAGO,TAG_SLOTS,id_reuses,same_input_contenders,within_group_reorders);
            $display("STRESS P=%0d K=%0d H=%0d exhaustion=%0d reordered=%0d AW_before_W=%0d W_before_AW=%0d",P,K,H,exhausted_cycles,reorder_count,aw_first_count,w_first_count);
        end else begin
            $display("BANDWIDTH P=%0d K=%0d H=%0d phase=%0d window_cycles=64 req=%0d ar=%0d aw=%0d w=%0d rsp=%0d expected_bytes_per_cycle=%0d",P,K,H,phase,measure_req,measure_ar,measure_aw,measure_w,measure_rsp,expected_rate()*64);
        end
        $display("CASE PASS P=%0d K=%0d H=%0d phase=%0d requests=%0d reads=%0d writes=%0d cycles=%0d",P,K,H,phase,req_total,reads,writes,cycle);
        reset=1;
    endtask
    initial begin
        run_phase(1);
        if (FULL_SUITE) begin
            run_phase(2);
            run_phase(3);
            run_phase(4);
            run_phase(5);
        end
        done=1;
    end
endmodule

module tb_VX_axi_adapter;
    wire [8:0] done;
    axi_adapter_case #(.P(2),.K(1),.H(8)) k1(done[0]);
    axi_adapter_case #(.P(2),.K(2),.H(8)) k2(done[1]);
    axi_adapter_case #(.P(2),.K(4),.H(8)) k4(done[2]);
    axi_adapter_case #(.P(2),.K(8),.H(8)) k8(done[3]);
    axi_adapter_case #(.P(1),.K(1),.H(8)) p1(done[4]);
    axi_adapter_case #(.P(1),.K(1),.H(1)) bypass(done[5]);
    axi_adapter_case #(.P(2),.K(2),.H(8),.TAGO(13)) direct_tags(done[6]);
    axi_adapter_case #(.P(2),.K(2),.H(8),.REQBUF(0),.RSPBUF(0)) zero_buffer_request(done[7]);
    axi_adapter_case #(.P(2),.K(2),.H(8),.TAG_SLOTS(1),.FULL_SUITE(0)) one_tag_slot(done[8]);
    initial begin
        wait (&done);
        $display("TEST PASSED: grouped AXI adapter identity, mapping, stalls, drain and sustained bandwidth");
        $finish;
    end
endmodule

// Separate elaboration/static-assertion probe used by check_invalid.py.
`ifndef PROBE_K
`define PROBE_K 2
`endif
`ifndef PROBE_H
`define PROBE_H 8
`endif
`ifndef PROBE_ADDR_IN
`define PROBE_ADDR_IN 28
`endif
`ifndef PROBE_ADDR_OUT
`define PROBE_ADDR_OUT 34
`endif
`ifndef PROBE_DATA_WIDTH
`define PROBE_DATA_WIDTH 512
`endif
`ifndef PROBE_DATA_SIZE
`define PROBE_DATA_SIZE 64
`endif
module tb_VX_axi_adapter_geometry;
    // No traffic is needed: these are parameter/static-assertion checks.
    // Keep the functional cases above fixed at their supported geometry.
    VX_axi_adapter #(
        .NUM_PORTS_IN(2), .NUM_BANKS_OUT(`PROBE_K), .NUM_HBM_PORTS(`PROBE_H),
        .ADDR_WIDTH_IN(`PROBE_ADDR_IN), .ADDR_WIDTH_OUT(`PROBE_ADDR_OUT),
        .DATA_WIDTH(`PROBE_DATA_WIDTH), .DATA_SIZE(`PROBE_DATA_SIZE),
        .TAG_WIDTH_IN(12), .TAG_WIDTH_OUT(5), .TAG_BUFFER_SIZE(16),
        .INTERLEAVE(1)
    ) probe (.clk(1'b0), .reset(1'b1));
    initial begin
        #20;
        $display("GEOMETRY_PROBE_REACHED_END");
        $finish;
    end
endmodule

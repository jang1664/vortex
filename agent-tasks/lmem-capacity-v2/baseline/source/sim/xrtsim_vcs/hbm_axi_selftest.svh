// Included inside the production TB in place of the accelerator only.
// The AXI adapter, capture/response logic, clocks and DPI remain unchanged.
function automatic logic [DATA_SIZE*8-1:0] test_data(input int p, input int beat);
    for (int byte_idx = 0; byte_idx < DATA_SIZE; byte_idx++)
        test_data[byte_idx*8 +: 8] = 8'(p*32 + beat*7 + byte_idx);
endfunction

task automatic test_negedge;
    @(negedge ap_clk);
    #1ps; // Avoid a driver race with the production negedge service loop.
endtask

task automatic test_send_w(input int p, input int beat, input bit last);
    test_negedge();
    m_axi_mem_wvalid[p] = 1;
    m_axi_mem_wdata[p] = test_data(p, beat);
    m_axi_mem_wstrb[p] = '1;
    m_axi_mem_wlast[p] = last;
    do @(posedge ap_clk); while (!m_axi_mem_wready[p]);
    $display("HBM_REPLAY W %0d %0d %0d", p, beat, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_wvalid[p] = 0;
endtask

task automatic test_send_aw_single(input int id, input int slot);
    test_negedge();
    m_axi_mem_awaddr[0] = 64'(slot) * DATA_SIZE;
    m_axi_mem_awid[0] = id;
    m_axi_mem_awlen[0] = 0;
    m_axi_mem_awvalid[0] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_awready[0]);
    $display("HBM_REPLAY AW_QUEUE %0d %0d", id, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_awvalid[0] = 0;
endtask

// Exercise real WSTRB packing through SV open arrays and the production DPI.
task automatic test_masked_roundtrip(input int p, input int sequence_id,
                                     input logic [63:0] strobes,
                                     inout logic [DATA_SIZE*8-1:0] expected);
    logic [DATA_SIZE*8-1:0] payload;
    payload = test_data(p, sequence_id);
    test_negedge();
    m_axi_mem_awaddr[p] = ((64'(p) * (32 / NUM_PORTS)) << 29) + 8192;
    m_axi_mem_awid[p] = 700 + sequence_id;
    m_axi_mem_awlen[p] = 0;
    m_axi_mem_awvalid[p] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_awready[p]);
    $display("HBM_REPLAY AW_MASK %0d %0d %0d", p, sequence_id, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_awvalid[p] = 0;
    m_axi_mem_wdata[p] = payload;
    m_axi_mem_wstrb[p] = strobes;
    m_axi_mem_wlast[p] = 1;
    m_axi_mem_wvalid[p] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_wready[p]);
    $display("HBM_REPLAY W_MASK %0d %0d %0d", p, sequence_id, longint'($realtime/1ps));
    for (int b = 0; b < DATA_SIZE; b++)
        if (strobes[b]) expected[b*8 +: 8] = payload[b*8 +: 8];
    test_negedge();
    m_axi_mem_wvalid[p] = 0;
    m_axi_mem_bready[p] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_bvalid[p]);
    if (m_axi_mem_bid[p] !== 700+sequence_id || m_axi_mem_bresp[p] !== 0)
        $fatal(1, "HBM_SELFTEST_MASK: B mismatch port %0d", p);
    $display("HBM_REPLAY B_MASK %0d %0d %0d", p, sequence_id, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_bready[p] = 0;
    m_axi_mem_araddr[p] = m_axi_mem_awaddr[p];
    m_axi_mem_arid[p] = 800 + sequence_id;
    m_axi_mem_arlen[p] = 0;
    m_axi_mem_arvalid[p] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_arready[p]);
    $display("HBM_REPLAY AR_MASK %0d %0d %0d", p, sequence_id, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_arvalid[p] = 0;
    m_axi_mem_rready[p] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_rvalid[p]);
    if (m_axi_mem_rid[p] !== 800+sequence_id || m_axi_mem_rresp[p] !== 0
        || m_axi_mem_rlast[p] !== 1 || m_axi_mem_rdata[p] !== expected)
        $fatal(1, "HBM_SELFTEST_MASK: data/ID/LAST mismatch port %0d sequence %0d", p, sequence_id);
    $display("HBM_REPLAY R_MASK %0d %0d %0d", p, sequence_id, longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_rready[p] = 0;
endtask

initial begin : directed_axi_driver
    logic [DATA_SIZE*8-1:0] expected;
    for (int p = 0; p < NUM_PORTS; p++) begin
        m_axi_mem_arvalid[p] = 0;
        m_axi_mem_awvalid[p] = 0;
        m_axi_mem_wvalid[p] = 0;
        m_axi_mem_rready[p] = 0;
        m_axi_mem_bready[p] = 0;
        m_axi_mem_arsize[p] = $clog2(DATA_SIZE);
        m_axi_mem_awsize[p] = $clog2(DATA_SIZE);
        m_axi_mem_arburst[p] = 1;
        m_axi_mem_awburst[p] = 1;
    end
    wait (selftest_ready);
    for (int p = 0; p < NUM_PORTS; p++) begin
        // W arrives before AW and must remain bounded and associated in order.
        test_send_w(p, 0, 0);
        test_send_w(p, 1, 1);
        test_negedge();
        m_axi_mem_awaddr[p] = (64'(p) * (32 / NUM_PORTS)) << 29;
        m_axi_mem_awid[p] = 100 + p;
        m_axi_mem_awlen[p] = 1;
        m_axi_mem_awvalid[p] = 1;
        do @(posedge ap_clk); while (!m_axi_mem_awready[p]);
        $display("HBM_REPLAY AW %0d %0d", p, longint'($realtime/1ps));
        test_negedge();
        m_axi_mem_awvalid[p] = 0;
        wait (m_axi_mem_bvalid[p]);
        repeat (4) test_negedge();
        m_axi_mem_bready[p] = 1;
        do @(posedge ap_clk); while (!m_axi_mem_bvalid[p]);
        if (m_axi_mem_bid[p] !== 100+p || m_axi_mem_bresp[p] !== 0)
            $fatal(1, "HBM_SELFTEST_B mismatch");
        $display("HBM_REPLAY B %0d %0d", p, longint'($realtime/1ps));
        test_negedge();
        m_axi_mem_bready[p] = 0;
        m_axi_mem_araddr[p] = m_axi_mem_awaddr[p];
        m_axi_mem_arid[p] = 200 + p;
        m_axi_mem_arlen[p] = 1;
        m_axi_mem_arvalid[p] = 1;
        do @(posedge ap_clk); while (!m_axi_mem_arready[p]);
        $display("HBM_REPLAY AR %0d %0d", p, longint'($realtime/1ps));
        test_negedge();
        m_axi_mem_arvalid[p] = 0;
        wait (m_axi_mem_rvalid[p]);
        repeat (4) test_negedge();
        m_axi_mem_rready[p] = 1;
        for (int beat = 0; beat < 2; beat++) begin
            do @(posedge ap_clk); while (!m_axi_mem_rvalid[p]);
            if (m_axi_mem_rid[p] !== 200+p || m_axi_mem_rresp[p] !== 0
                || m_axi_mem_rdata[p] !== test_data(p, beat)
                || m_axi_mem_rlast[p] !== (beat == 1))
                $fatal(1, "HBM_SELFTEST_R mismatch port=%0d beat=%0d", p, beat);
            $display("HBM_REPLAY R %0d %0d %0d", p, beat, longint'($realtime/1ps));
        end
        test_negedge();
        m_axi_mem_rready[p] = 0;
    end
    // Reserve all 256 read beats while the DUT holds RREADY low. Admission
    // must stop even though the request socket no longer exists in this path.
    for (int burst = 0; burst < 4; burst++) begin
        test_negedge();
        m_axi_mem_araddr[0] = 0;
        m_axi_mem_arid[0] = 300;
        m_axi_mem_arlen[0] = 63;
        m_axi_mem_arvalid[0] = 1;
        do @(posedge ap_clk); while (!m_axi_mem_arready[0]);
        $display("HBM_REPLAY AR_FULL %0d %0d", burst, longint'($realtime/1ps));
        test_negedge();
        m_axi_mem_arvalid[0] = 0;
    end
    repeat (100) test_negedge();
    if (m_axi_mem_arready[0] !== 0 || r_queue[0].size() > RSP_QUEUE_LIMIT)
        $fatal(1, "HBM_SELFTEST_CREDIT: unbounded read admission or response queue");
    m_axi_mem_rready[0] = 1;
    for (int beat = 0; beat < 256; beat++) begin
        do @(posedge ap_clk); while (!m_axi_mem_rvalid[0]);
        if (m_axi_mem_rid[0] !== 300 || m_axi_mem_rresp[0] !== 0
            || m_axi_mem_rlast[0] !== ((beat % 64) == 63))
            $fatal(1, "HBM_SELFTEST_CREDIT: lost/reordered beat %0d", beat);
        $display("HBM_REPLAY R_FULL %0d %0d", beat, longint'($realtime/1ps));
    end
    test_negedge();
    m_axi_mem_rready[0] = 0;
    repeat (4) test_negedge();
    if (!m_axi_mem_arready[0] || m_axi_mem_rvalid[0])
        $fatal(1, "HBM_SELFTEST_CREDIT: arready=%b credit=%b stall=%b rvalid=%b rqueue=%0d",
               m_axi_mem_arready[0], ar_credit[0], req_stalling[0], m_axi_mem_rvalid[0], r_queue[0].size());
    $display("HBM_CREDIT_PASS");
    // AW can precede W, but only sixteen bursts can reserve write resources.
    for (int burst = 0; burst < 16; burst++)
        test_send_aw_single(400+burst, burst);
    repeat (4) test_negedge();
    if (m_axi_mem_awready[0] !== 0)
        $fatal(1, "HBM_SELFTEST_AW_CREDIT: unbounded address admission");
    // Sixteen W beats satisfy those AWs; another 64 must fill the independent
    // W-before-AW FIFO, without spilling into an unbounded software queue.
    for (int beat = 0; beat < 80; beat++)
        test_send_w(0, beat, 1);
    repeat (4) test_negedge();
    if (m_axi_mem_wready[0] !== 0 || b_queue[0].size() > RSP_QUEUE_LIMIT)
        $fatal(1, "HBM_SELFTEST_W_CREDIT: unbounded W or B queue");
    fork
        begin : remaining_addresses
            for (int burst = 0; burst < 64; burst++)
                test_send_aw_single(500+burst, burst);
        end
        begin : drain_write_responses
            test_negedge();
            m_axi_mem_bready[0] = 1;
            for (int burst = 0; burst < 80; burst++) begin
                do @(posedge ap_clk); while (!m_axi_mem_bvalid[0]);
                if (m_axi_mem_bid[0] !== ((burst < 16) ? 400+burst : 500+burst-16)
                    || m_axi_mem_bresp[0] !== 0)
                    $fatal(1, "HBM_SELFTEST_B_ORDER: response %0d", burst);
                $display("HBM_REPLAY B_QUEUE %0d %0d", burst, longint'($realtime/1ps));
            end
            test_negedge();
            m_axi_mem_bready[0] = 0;
        end
    join
    repeat (4) test_negedge();
    if (!m_axi_mem_awready[0] || !m_axi_mem_wready[0] || m_axi_mem_bvalid[0])
        $fatal(1, "HBM_SELFTEST_WRITE_CREDIT: no recovery or duplicate B");
    $display("HBM_WRITE_CREDIT_PASS");
    // Leave both response channels blocked and a long read outstanding across
    // reset. The write has become functionally visible before its B is taken.
    test_send_aw_single(600, 100);
    test_send_w(0, 9, 1);
    test_negedge();
    m_axi_mem_araddr[0] = 0;
    m_axi_mem_arid[0] = 601;
    m_axi_mem_arlen[0] = 63;
    m_axi_mem_arvalid[0] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_arready[0]);
    $display("HBM_REPLAY AR_RESET_OLD %0d", longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_arvalid[0] = 0;
    wait (m_axi_mem_rvalid[0] && m_axi_mem_bvalid[0]);
    repeat (100) test_negedge();
    if (r_queue[0].size() == 0)
        $fatal(1, "HBM_SELFTEST_RESET: response queue was not exercised");
    ap_rst_n = 0;
    repeat (4) test_negedge();
    for (int p = 0; p < NUM_PORTS; p++) begin
        if (m_axi_mem_rvalid[p] || m_axi_mem_bvalid[p]
            || r_queue[p].size() || b_queue[p].size())
            $fatal(1, "HBM_SELFTEST_RESET: stale response during reset");
    end
    ap_rst_n = 1;
    repeat (100) test_negedge();
    if (m_axi_mem_rvalid[0] || m_axi_mem_bvalid[0]
        || !m_axi_mem_arready[0] || !m_axi_mem_awready[0] || !m_axi_mem_wready[0])
        $fatal(1, "HBM_SELFTEST_RESET: stale completion or lost credit");
    m_axi_mem_araddr[0] = 100 * DATA_SIZE;
    m_axi_mem_arid[0] = 602;
    m_axi_mem_arlen[0] = 0;
    m_axi_mem_arvalid[0] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_arready[0]);
    $display("HBM_REPLAY AR_RESET_NEW %0d", longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_arvalid[0] = 0;
    m_axi_mem_rready[0] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_rvalid[0]);
    if (m_axi_mem_rid[0] !== 602 || m_axi_mem_rdata[0] !== test_data(0, 9)
        || m_axi_mem_rlast[0] !== 1 || m_axi_mem_rresp[0] !== 0)
        $fatal(1, "HBM_SELFTEST_RESET: RAM not preserved or stale response");
    $display("HBM_REPLAY R_RESET_NEW %0d", longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_rready[0] = 0;
    repeat (100) test_negedge();
    if (m_axi_mem_rvalid[0] || m_axi_mem_bvalid[0])
        $fatal(1, "HBM_SELFTEST_RESET: delayed stale completion");
    $display("HBM_RESET_PASS");
    for (int p = 0; p < NUM_PORTS; p++) begin
        expected = '0;
        test_masked_roundtrip(p, 0, '1, expected);
        test_masked_roundtrip(p, 1, '0, expected);
        test_masked_roundtrip(p, 2, 64'h5555555555555555, expected);
        test_masked_roundtrip(p, 3, 64'h8000000180000001, expected);
        test_masked_roundtrip(p, 4, 64'haaaaaaaaaaaaaaaa, expected);
    end
    $display("HBM_STROBE_PASS");
    // Three independently incomplete states: AW without W, W without AW,
    // and the first W of a two-beat burst. None may survive reset association.
    test_send_aw_single(900, 150);
    test_send_w(1, 31, 1);
    test_negedge();
    m_axi_mem_awaddr[2] = ((64'(2) * (32 / NUM_PORTS)) << 29) + 12288;
    m_axi_mem_awid[2] = 901;
    m_axi_mem_awlen[2] = 1;
    m_axi_mem_awvalid[2] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_awready[2]);
    $display("HBM_REPLAY AW_PARTIAL %0d", longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_awvalid[2] = 0;
    test_send_w(2, 32, 0);
    test_negedge();
    ap_rst_n = 0;
    repeat (4) test_negedge();
    ap_rst_n = 1;
    repeat (100) test_negedge();
    for (int p = 0; p < NUM_PORTS; p++) begin
        if (m_axi_mem_bvalid[p] || m_axi_mem_rvalid[p])
            $fatal(1, "HBM_SELFTEST_PARTIAL_RESET: stale response port %0d", p);
        expected = '0;
        test_masked_roundtrip(p, 5, '1, expected);
    end
    repeat (100) test_negedge();
    for (int p = 0; p < NUM_PORTS; p++)
        if (m_axi_mem_bvalid[p] || m_axi_mem_rvalid[p])
            $fatal(1, "HBM_SELFTEST_PARTIAL_RESET: duplicate response port %0d", p);
    $display("HBM_PARTIAL_RESET_PASS");
    // Exercise the same cleanup called by CMD_SHUTDOWN while request storage,
    // callbacks and unconsumed responses still exist. Shutdown cancels work;
    // it does not wait for an accelerator that has deasserted RREADY/BREADY.
    test_send_aw_single(950, 160);
    test_send_w(1, 42, 1);
    test_negedge();
    m_axi_mem_araddr[2] = (64'(2) * (32 / NUM_PORTS)) << 29;
    m_axi_mem_arid[2] = 951;
    m_axi_mem_arlen[2] = 63;
    m_axi_mem_arvalid[2] = 1;
    do @(posedge ap_clk); while (!m_axi_mem_arready[2]);
    $display("HBM_REPLAY AR_SHUTDOWN %0d", longint'($realtime/1ps));
    test_negedge();
    m_axi_mem_arvalid[2] = 0;
    wait (m_axi_mem_rvalid[2]);
    test_negedge();
    if (m_axi_mem_rready[2] || m_axi_mem_bvalid[0] || m_axi_mem_bvalid[1])
        $fatal(1, "HBM_SELFTEST_SHUTDOWN: outstanding setup invalid");
    socket_server_close();
    $display("HBM_OUTSTANDING_SHUTDOWN_PASS");
    $display("HBM_SELFTEST_PASS");
    $finish;
end

initial begin : selftest_watchdog
    #1ms;
    $fatal(1, "HBM_SELFTEST_TIMEOUT");
end

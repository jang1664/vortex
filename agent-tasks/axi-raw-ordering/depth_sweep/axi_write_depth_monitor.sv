`timescale 1ns/1ps
// Experiment-only bind instrumentation. Not part of production RTL.
module axi_write_depth_monitor #(parameter SIZE=16, ADDRW=28, IDW=8) (
    input wire clk,
    input wire reset,
    input wire [SIZE-1:0] valid,
    input wire write_fire,
    input wire b_fire,
    input wire write_ready,
    input wire read_valid,
    input wire read_fire,
    input wire read_allowed,
    input wire scan_read,
    input wire compare_valid
);
    longint unsigned cycles=0, aw=0, b=0, max_occupancy=0, occupancy_sum=0;
    longint unsigned full_cycles=0, slot_unavailable_cycles=0;
    longint unsigned reads=0, empty_bypass_reads=0, scan_requests=0;
    longint unsigned read_blocked_cycles=0, lookup_cycles=0, match_wait_cycles=0;
    always @(posedge clk) begin
        if (!reset) begin
            cycles++;
            aw+=write_fire;
            b+=b_fire;
            occupancy_sum+=$countones(valid);
            if ($countones(valid)>max_occupancy) max_occupancy=$countones(valid);
            full_cycles+=(&valid);
            // No upstream write-demand signal exists on the helper boundary.
            // This counts unavailable time, NOT demanded-write stall cycles.
            slot_unavailable_cycles+=!write_ready;
            reads+=read_fire;
            empty_bypass_reads+=(read_fire && !(|valid));
            scan_requests+=scan_read;
            if (read_valid && !read_allowed) begin
                read_blocked_cycles++;
                if (scan_read || compare_valid) lookup_cycles++;
                else match_wait_cycles++;
            end
        end
    end
    final begin
        $display("RAW_DEPTH_STATS depth=%0d addrw=%0d idw=%0d cycles=%0d aw=%0d b=%0d max_occupancy=%0d occupancy_sum=%0d full_cycles=%0d slot_unavailable_cycles=%0d reads=%0d empty_bypass_reads=%0d scan_requests=%0d read_blocked_cycles=%0d lookup_cycles=%0d match_wait_cycles=%0d path=%m", SIZE,ADDRW,IDW,cycles,aw,b,max_occupancy,occupancy_sum,full_cycles,slot_unavailable_cycles,reads,empty_bypass_reads,scan_requests,read_blocked_cycles,lookup_cycles,match_wait_cycles);
    end
endmodule

bind VX_axi_write_hazards axi_write_depth_monitor #(.SIZE(SIZE),.ADDRW(ADDRW),.IDW(IDW)) depth_monitor (
    .clk(clk),.reset(reset),.valid(valid),.write_fire(write_fire),.b_fire(b_fire),
    .write_ready(write_ready),.read_valid(read_valid),.read_fire(read_fire),
    .read_allowed(read_allowed),.scan_read(scan_read),.compare_valid(compare_valid)
);

`timescale 1ns/1ps
`include "VX_define.vh"
module tb_mem_bus_split_depth import VX_gpu_pkg::*; #(
    parameter LANES=4, BYTES=64, DEPTH=8, MASKED=1, SEED=1
) ();
    localparam TAGW=`UP(UUID_WIDTH)+12;
    localparam WIDE=LANES*BYTES;
    localparam COUNT=1024;
    logic clk=0, reset=1;
    always #5 clk=~clk;
    int cycle=0, sent=0, received=0, expected_reads=0;
    int expected[$];
    int last_cycle=-1, consecutive=0, max_consecutive=0;
    bit saw_full=0;
    int lane_accepted[LANES];
    VX_mem_bus_if #(.DATA_SIZE(WIDE),.TAG_WIDTH(TAGW)) wide();
    VX_mem_bus_if #(.DATA_SIZE(BYTES),.TAG_WIDTH(TAGW)) lane[LANES]();
    VX_mem_bus_split #(.NUM_LANES(LANES),.LANE_DATA_SIZE(BYTES),
        .TAG_WIDTH(TAGW),.ENABLE_LANE_MASK(MASKED),.RSP_DEPTH(DEPTH),.RSP_REORDER(1)) dut(
        .clk(clk),.reset(reset),.wide_bus_if(wide),.lane_bus_if(lane));

    function automatic bit is_write(int id);
        return id>=4*DEPTH && id<COUNT-128 && id%7==0;
    endfunction
    function automatic bit active(int id,int l);
        if (!MASKED || id<4*DEPTH || id>=COUNT-128) return 1;
        if (id%31==0) return 0;
        return ((id+l+SEED)%3)!=0;
    endfunction
    function automatic logic [BYTES*8-1:0] payload(int id,int l);
        logic [BYTES*8-1:0] v;
        for(int b=0;b<BYTES;b++) v[b*8+:8]=8'(id*17+l*13+b);
        return v;
    endfunction
    initial begin
        repeat(6) @(negedge clk);
        reset=0;
    end
    always @(negedge clk) begin
        wide.req_valid=!reset && sent<COUNT;
        wide.req_data='0;
        wide.req_data.rw=is_write(sent);
        wide.req_data.addr=sent;
        wide.req_data.tag.value=sent;
        for(int l=0;l<LANES;l++) begin
            wide.req_data.data[l*BYTES*8+:BYTES*8]=payload(sent,l);
            wide.req_data.byteen[l*BYTES+:BYTES]={BYTES{active(sent,l)}};
        end
        // Force full queues, then exercise intermittent and continuous drain.
        wide.rsp_ready=!reset && cycle>4*DEPTH+40
            && (sent>=COUNT-128 || (cycle+SEED)%11!=0);
    end
    for(genvar l=0;l<LANES;l++) begin:g_model
        typedef struct packed {int id; logic [TAGW-1:0] tag;} item_t;
        item_t pending[$];
        int last_id=-1;
        item_t head;
        int selection;
        bit holding=0;
        initial begin
            lane[l].req_ready=0;lane[l].rsp_valid=0;lane[l].rsp_data='0;
            lane_accepted[l]=0;
        end
        always @(negedge clk) begin
            lane[l].req_ready=!reset && (sent>=COUNT-128 || (cycle+l+SEED)%9!=0);
            if(!holding) begin
                lane[l].rsp_valid=0;
                if(!reset && pending.size()>0
                    && (sent>=COUNT-128 || (cycle+3*l+SEED)%7!=0)) begin
                    selection=(pending.size()>1 && (cycle+l+SEED)%3!=0)?1:0;
                    head=pending[selection];
                    lane[l].rsp_valid=1;
                    lane[l].rsp_data.tag=head.tag;
                    lane[l].rsp_data.data=payload(head.id,l);
                    holding=1;
                end
            end
        end
        always @(posedge clk) if(!reset) begin
            if(lane[l].req_valid && lane[l].req_ready) begin
                int id;
                id=int'(lane[l].req_data.addr)/LANES;
                assert(id>last_id && active(id,l)) else $fatal(1,"duplicate/inactive lane request");
                assert(lane[l].req_data.addr==id*LANES+l) else $fatal(1,"address mismatch");
                assert(lane[l].req_data.rw==is_write(id)) else $fatal(1,"direction mismatch");
                assert(lane[l].req_data.data===payload(id,l)) else $fatal(1,"request data mismatch");
                last_id=id;lane_accepted[l]++;
                if(!is_write(id)) pending.push_back({32'(id),lane[l].req_data.tag});
            end
            if(lane[l].rsp_valid && lane[l].rsp_ready) begin
                pending.delete(selection);holding=0;
            end
        end
    end
    always @(posedge clk) if(!reset) begin
        cycle++;
        if(dut.rsp_ctx_full) saw_full=1;
        if(wide.req_valid && wide.req_ready) begin
            if(!is_write(sent)) begin expected.push_back(sent);expected_reads++;end
            sent++;
        end
        if(wide.rsp_valid && wide.rsp_ready) begin
            int id;
            assert(expected.size()>0) else $fatal(1,"unexpected response");
            id=expected.pop_front();
            assert(wide.rsp_data.tag.value==id) else $fatal(1,"response tag mismatch");
            for(int l=0;l<LANES;l++) begin
                assert(wide.rsp_data.data[l*BYTES*8+:BYTES*8]===
                    (active(id,l)?payload(id,l):{BYTES*8{1'b0}}))
                    else $fatal(1,"response data mismatch id=%0d lane=%0d",id,l);
            end
            received++;
            consecutive=(last_cycle==cycle-1)?consecutive+1:1;
            if(consecutive>max_consecutive)max_consecutive=consecutive;
            last_cycle=cycle;
        end
        if(sent==COUNT && received==expected_reads) begin
            for(int l=0;l<LANES;l++) begin
                int n;
                n=0;
                for(int id=0;id<COUNT;id++) if(active(id,l))n++;
                assert(lane_accepted[l]==n) else $fatal(1,"lane request count mismatch");
            end
            assert(!MASKED || saw_full) else $fatal(1,"context full not covered");
            assert(max_consecutive>=16) else $fatal(1,"continuous response throughput not covered");
            $display("TEST PASSED: lanes=%0d bytes=%0d depth=%0d masked=%0d seed=%0d reads=%0d cycles=%0d continuous=%0d",LANES,BYTES,DEPTH,MASKED,SEED,received,cycle,max_consecutive);
            $finish;
        end
        if(cycle>200000)$fatal(1,"test timeout");
    end
endmodule

`include "VX_define.vh"
module tb_VX_naive_qparam_pair import VX_gpu_pkg::*; ();
    localparam int B=`GEMM_SCALE_ZERO_DATA_SIZE,L=B/8,TW=GEMM_BASE_TAG_WIDTH;
    localparam int TAGS=1<<(TW-UUID_WIDTH);
    logic clk=0;always #5 clk=~clk;
    logic reset=1;
    gemm_unified_cmd_t cmd[2];
    logic [1:0] cmd_valid=0,prepare_valid=0,done_ready=0;
    wire [1:0] cmd_ready,prepare_ready,done_valid,source_done_valid;
    wire [31:0] done_work_seq[2],source_done_work_seq[2];
    logic [31:0] sync_value[GEMM_NUM_SYNC_REGS]='{default:0};
    wire quiescent;
    VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(TW)) memory[L]();
    VX_mem_bus_if #(.DATA_SIZE(B),.TAG_WIDTH(TW)) install[2]();
    VX_naive_qparam_pair dut(.*,.lane_bus_if(memory),.install_bus_if(install));
    int cycle=0,qrow=0,blocked=0;
    int installed[2]='{default:0},completed[2]='{default:0},captured[2]='{default:0};
    int requests[2]='{default:0};
    wire [L-1:0] req_valid,req_ready,rsp_valid,rsp_ready;
    wire [L-1:0][TW-1:0] req_tag,rsp_tag;
    wire [L-1:0][`MEM_ADDR_WIDTH-4:0] req_addr;
    logic [L-1:0][TAGS-1:0] pending='0;
    logic [63:0] address[L][TAGS];
    int due[L][TAGS];
    logic [L-1:0][TW-1:0] selected_tag;
    logic [L-1:0] selected_valid;
    logic [L-1:0][63:0] response_data;
    function automatic byte image_byte(input logic[63:0] a);
        return 8'((a*17)^(a>>7)^(a>>15)^(a>>32));
    endfunction
    for(genvar lane=0;lane<L;++lane)begin:g_memory
        assign req_valid[lane]=memory[lane].req_valid;
        assign req_tag[lane]=memory[lane].req_data.tag;
        assign req_addr[lane]=memory[lane].req_data.addr;
        assign req_ready[lane]=(cycle+lane)%5!=0;
        assign memory[lane].req_ready=req_ready[lane];
        assign memory[lane].rsp_valid=selected_valid[lane];
        assign memory[lane].rsp_data.tag=selected_tag[lane];
        assign memory[lane].rsp_data.data=response_data[lane];
        assign rsp_valid[lane]=memory[lane].rsp_valid;
        assign rsp_ready[lane]=memory[lane].rsp_ready;
        assign rsp_tag[lane]=memory[lane].rsp_data.tag;
        always_comb begin
            selected_valid[lane]=0;selected_tag[lane]='0;response_data[lane]='0;
            for(int tag=TAGS-1;tag>=0;--tag)
                if(!selected_valid[lane] && pending[lane][tag] && due[lane][tag]<=cycle)begin
                    selected_valid[lane]=1;selected_tag[lane]=TW'(tag);
                    for(int byte_id=0;byte_id<8;++byte_id)
                        response_data[lane][byte_id*8+:8]=image_byte(address[lane][tag]+64'(byte_id));
                end
        end
    end
    wire [1:0] install_valid,install_ready;
    wire [1:0][B*8-1:0] install_data;
    wire [1:0][B-1:0] install_mask;
    wire [1:0][`MEM_ADDR_WIDTH-$clog2(B)-1:0] install_addr;
    for(genvar e=0;e<2;++e)begin:g_install
        assign install[e].req_ready=(cycle+e)%7<4;
        assign install[e].rsp_valid=0;
        assign install[e].rsp_data='0;
        assign install_valid[e]=install[e].req_valid;
        assign install_ready[e]=install[e].req_ready;
        assign install_data[e]=install[e].req_data.data;
        assign install_mask[e]=install[e].req_data.byteen;
        assign install_addr[e]=install[e].req_data.addr;
    end
    always @(posedge clk)begin
        cycle<=cycle+1;
        if(!reset)begin
            for(int lane=0;lane<L;++lane)begin
                if(req_valid[lane] && req_ready[lane])begin
                    assert(!pending[lane][req_tag[lane]])else $fatal(1,"Physical tag reused before response");
                    pending[lane][req_tag[lane]]<=1;
                    address[lane][req_tag[lane]]<=64'(req_addr[lane])*8;
                    due[lane][req_tag[lane]]<=cycle+((int'(req_tag[lane])%2)==0?19:2)+lane;
                    requests[(int'(req_addr[lane])>>13)&1]++;
                end
                if(rsp_valid[lane] && rsp_ready[lane])pending[lane][rsp_tag[lane]]<=0;
            end
            for(int e=0;e<2;++e)begin
                if(source_done_valid[e])begin
                    assert(source_done_work_seq[e]==1 && captured[e]==0)else $fatal(1,"Duplicate/wrong source owner");
                    captured[e]++;
                end
                if(install_valid[e] && install_ready[e])begin
                    logic[63:0] destination,source;
                    logic[B-1:0] mask;
                    int useful,offset;
                    useful=qrow?2:B-2;
                    destination=64'(e*2*B)+64'(qrow?installed[e]*2:0);
                    source=64'h1_0000_0000+64'(e*65536)+64'(qrow?2+installed[e]*8:0);
                    offset=int'(destination%B);
                    mask=({B{1'b1}}>>(B-useful))<<offset;
                    assert(install_addr[e]==((destination/B)*B) && install_mask[e]==mask)
                        else $fatal(1,"Register byte address/mask mapping mismatch");
                    assert(e!=blocked || sync_value[blocked?GEMM_RID_ZP_CONSUME0:GEMM_RID_SC_CONSUME0]>=1)
                        else $fatal(1,"Writer fence bypass");
                    for(int byte_id=0;byte_id<useful;++byte_id)
                        assert(install_data[e][(offset+byte_id)*8+:8]===image_byte(source+64'(byte_id)))
                            else $fatal(1,"Routed physical payload mismatch");
                    installed[e]++;
                end
                if(done_valid[e] && done_ready[e])begin
                    assert(done_work_seq[e]==1 && completed[e]==0 && installed[e]==(qrow?B/2:1))
                        else $fatal(1,"Install completion owner/count mismatch");
                    completed[e]++;
                end
            end
        end
    end
    initial begin
        void'($value$plusargs("QROW=%d",qrow));void'($value$plusargs("BLOCKED=%d",blocked));
        repeat(3)@(negedge clk);reset=0;
        for(int e=0;e<2;++e)begin
            cmd[e]='0;cmd[e].instr=e?10:6;cmd[e].work_seq=1;
            cmd[e].rs1_data=64'(e*2*B);
            cmd[e].rs2_data=64'h1_0000_0000+64'(e*65536)+64'(qrow?2:0);
            cmd[e].stride=qrow?8:B;cmd[e].bound=16'(qrow?B/2:1);
            cmd[e].groups_eff=32'(qrow?2:B-2);cmd[e].flags[2]=1'(qrow);
            cmd[e].naive_source_generation=1;
            cmd[e].notify.valid=1;cmd[e].notify.set_mode=1;cmd[e].notify.value=1;
            cmd[e].notify.reg_id=GEMM_SYNC_REG_ID_WIDTH'(e?GEMM_RID_ZP0:GEMM_RID_SC0);
            if(e==blocked)begin
                cmd[e].writer_wait.valid=1;cmd[e].writer_wait.target=1;
                cmd[e].writer_wait.reg_id=GEMM_SYNC_REG_ID_WIDTH'(e?GEMM_RID_ZP_CONSUME0:GEMM_RID_SC_CONSUME0);
            end
        end
        prepare_valid[blocked]=1;cmd_valid[1-blocked]=1;
        fork
            begin do @(posedge clk);while(!prepare_ready[blocked]);#1;prepare_valid[blocked]=0;end
            begin do @(posedge clk);while(!cmd_ready[1-blocked]);#1;cmd_valid[1-blocked]=0;end
        join
        repeat(30)@(negedge clk);
        assert(installed[blocked]==0 && requests[blocked]>0)else $fatal(1,"Prepare did not fetch without install");
        cmd_valid[blocked]=1;do @(posedge clk);while(!cmd_ready[blocked]);#1;cmd_valid[blocked]=0;
        wait(done_valid[1-blocked]);
        assert(installed[blocked]==0)else $fatal(1,"Blocked writer installed while peer progressed");
        repeat(9)@(negedge clk);
        done_ready='1;
        sync_value[blocked?GEMM_RID_ZP_CONSUME0:GEMM_RID_SC_CONSUME0]=1;
        wait(quiescent);@(negedge clk);
        assert(completed[0]==1 && completed[1]==1 && captured[0]==1 && captured[1]==1)
            else $fatal(1,"Pair did not drain owned commands");
        $display("TEST PASSED quant pair qrow%0d blocked%0d",qrow,blocked);$finish;
    end
    initial begin #200000;$fatal(1,"Quant pair timeout");end
endmodule

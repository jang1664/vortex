`include "VX_define.vh"
module tb_VX_naive_input_executor import VX_gpu_pkg::*; ();
    localparam int B=`GEMM_INPUT_DATA_SIZE,L=B/8,TW=GEMM_BASE_TAG_WIDTH,TAGS=1<<(TW-UUID_WIDTH);
    logic clk=0;always #5 clk=~clk;
    logic reset=1,cmd_valid=0,prepare_valid=0,done_ready=0;
    gemm_unified_cmd_t cmd;
    wire cmd_ready,prepare_ready,done_valid,source_done_valid,quiescent;
    wire [31:0] done_work_seq,source_done_work_seq,ingress_work_seq,terminal_wait_work_seq;
    logic [31:0] output_release_value=0,terminal_fence_work_seq=0;
    logic terminal_fence_valid=0;
    wire terminal_wait_valid,ingress_complete;
    gemm_input_ctrl_t packet_ctrl;
    VX_mem_bus_if #(.DATA_SIZE(8),.TAG_WIDTH(TW)) memory[L]();
    VX_mem_bus_if #(.DATA_SIZE(B),.TAG_WIDTH(TW)) input_bus();
    VX_naive_input_executor dut(.*,.lane_bus_if(memory),.input_bus_if(input_bus));
    int cycle=0,total_rows=0,completed=0,captures=0;
    int rows[6]='{default:0};
    bit captured[6]='{default:0};
    logic sink_enable=0;
    assign input_bus.req_ready=sink_enable && cycle%7<5;
    assign input_bus.rsp_valid=0;
    assign input_bus.rsp_data='0;
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
        return 8'((a*19)^(a>>7)^(a>>13)^(a>>32));
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
                    for(int b=0;b<8;++b)response_data[lane][b*8+:8]=image_byte(address[lane][tag]+64'(b));
                end
        end
    end
    always @(posedge clk)begin
        cycle<=cycle+1;
        if(!reset)begin
            for(int lane=0;lane<L;++lane)begin
                if(req_valid[lane] && req_ready[lane])begin
                    assert(!pending[lane][req_tag[lane]])else $fatal(1,"Input source tag reuse");
                    pending[lane][req_tag[lane]]<=1;
                    address[lane][req_tag[lane]]<=64'(req_addr[lane])*8;
                    due[lane][req_tag[lane]]<=cycle+((int'(req_tag[lane])%2)==0?25:2)+lane;
                end
                if(rsp_valid[lane] && rsp_ready[lane])pending[lane][rsp_tag[lane]]<=0;
            end
            if(source_done_valid)begin
                assert(source_done_work_seq inside {[1:5]} && !captured[source_done_work_seq])
                    else $fatal(1,"Input source completion identity mismatch");
                captured[source_done_work_seq]=1;captures++;
            end
            if(input_bus.req_valid && input_bus.req_ready)begin
                int id,row;
                logic[63:0] source,psum,final_address;
                id=int'(packet_ctrl.work_seq);row=rows[id];
                assert(id inside {[1:5]} && row<(id==5?32:4))else $fatal(1,"Input row owner/count mismatch");
                source=64'h1_0000_0000+64'(id*4096+row*256);
                psum=64'h1_0800_0000+64'(id*4096+row*B*2);
                final_address=64'h1_0900_0000+64'(id*4096+row*256);
                assert(packet_ctrl.acc_rd_addr==`MEM_ADDR_WIDTH'(psum)
                    && packet_ctrl.acc_wr_addr==`MEM_ADDR_WIDTH'(id==2?final_address:psum)
                    && packet_ctrl.notify_on_writeback==(row+1==(id==5?32:4))
                    && packet_ctrl.last==(id==2) && packet_ctrl.w_load_target==32'(id+10)
                    && packet_ctrl.s_load_target==32'(id+20) && packet_ctrl.z_load_target==32'(id+30)
                    && input_bus.req_data.byteen=={B{1'b1}})
                    else $fatal(1,"Input packet address/metadata mismatch");
                for(int b=0;b<B;++b)
                    assert(input_bus.req_data.data[b*8+:8]===image_byte(source+64'(b)))
                        else $fatal(1,"Input immutable source payload mismatch");
                if(id>=3)assert(output_release_value>=1)else $fatal(1,"Input O fence bypassed");
                rows[id]++;total_rows++;
            end
            if(done_valid && done_ready)begin
                completed++;
                assert(done_work_seq==32'(completed))else $fatal(1,"Input completion reordered");
            end
        end
    end
    task automatic setup(input int id);
        cmd='0;cmd.instr=7;cmd.work_seq=32'(id);cmd.eff_mt=21'(id==5?32:4);
        cmd.rs2_data=64'h1_0000_0000+64'(id*4096);
        cmd.rs1_data=64'h1_0800_0000+64'(id*4096);cmd.stride=B*2;
        cmd.naive_final_base=64'h1_0900_0000+64'(id*4096);cmd.naive_final_stride=256;
        cmd.flags[4]=1;cmd.flags[3]=(id==2);cmd.naive_terminal=(id==2);
        cmd.naive_source_generation=1;
        cmd.input_admit_waits[0].target=32'(id+10);cmd.input_admit_waits[1].target=32'(id+20);
        cmd.input_admit_waits[2].target=32'(id+30);cmd.input_admit_waits[3].target=32'(id>=3);
    endtask
    task automatic issue;
        cmd_valid=1;do @(posedge clk);while(!cmd_ready);#1;cmd_valid=0;
    endtask
    initial begin
        repeat(3)@(negedge clk);reset=0;
        setup(1);prepare_valid=1;do @(posedge clk);while(!prepare_ready);#1;prepare_valid=0;
        wait(source_done_valid);repeat(4)@(negedge clk);
        assert(total_rows==0 && !done_valid)else $fatal(1,"Prepared Input admitted before issue");
        issue();for(int id=2;id<=4;++id)begin setup(id);issue();end
        repeat(100)@(negedge clk);
        assert(dut.dma_commands==4 && dut.dma_slots==16 && captures==4 && total_rows==0)
            else $fatal(1,"Input read-ahead did not fill existing bounded capacity");
        sink_enable=1;
        wait(total_rows==8);@(negedge clk);
        assert(completed==0 && done_valid && done_work_seq==1)else $fatal(1,"Prior completion blocked next Input");
        done_ready=1;@(negedge clk);done_ready=0;
        repeat(6)@(negedge clk);
        assert(terminal_wait_valid && terminal_wait_work_seq==2 && !done_valid && total_rows==8)
            else $fatal(1,"Terminal/O fence ownership mismatch");
        terminal_fence_valid=1;terminal_fence_work_seq=99;
        repeat(3)@(negedge clk);assert(!done_valid)else $fatal(1,"Foreign terminal fence accepted");
        terminal_fence_work_seq=2;
        repeat(4)@(negedge clk);assert(done_valid && total_rows==8)else $fatal(1,"Terminal completion lost");
        done_ready=1;@(negedge clk);terminal_fence_valid=0;output_release_value=1;
        wait(quiescent);@(negedge clk);assert(completed==4 && captures==4)else $fatal(1,"Four Input owners not drained");
        setup(5);issue();wait(quiescent);@(negedge clk);
        assert(completed==5 && captures==5 && total_rows==48)else $fatal(1,"Input rolling slot reuse failed");
        $display("TEST PASSED physical Input executor overlap and source ownership");$finish;
    end
    initial begin #300000;$fatal(1,"Input executor timeout");end
endmodule

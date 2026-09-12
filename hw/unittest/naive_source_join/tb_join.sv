`include "VX_define.vh"
module tb_join import VX_gpu_pkg::*; ();
    localparam int MICROS = (`GEMM_FSM_KT/`GEMM_FSM_MXU_KT)*(`GEMM_FSM_NT/`GEMM_FSM_MXU_NT);
    logic clk=0;
    always #5 clk=~clk;
    logic reset=1, invocation_start=0, closed_valid=0, closed_buffer=0;
    logic [31:0] closed_generation=0, closed_count=0;
    logic [3:0] read_done_valid=0;
    logic [31:0] read_done_work_seq [4]='{default:'0};
    wire [1:0] source_free_valid;
    wire [31:0] source_free_generation [2];
    wire quiescent;
    int releases[2]='{default:0};
    string fault_case;
    VX_naive_source_join dut (.*);
    always @(posedge clk) begin
        if (!reset)
            for (int b=0;b<2;++b)
                if (source_free_valid[b]) begin
                    releases[b]++;
                    assert (source_free_generation[b]==32'(releases[b]))
                        else $fatal(1,"Wrong source release generation or duplicate");
                end
    end
    task automatic tick;
        @(posedge clk);#1;
    endtask
    task automatic close_tile(input int tile,input int count);
        closed_valid=1;closed_buffer=1'(tile%2);
        closed_generation=32'(tile/2+1);closed_count=32'(count);
        tick();closed_valid=0;
    endtask
    task automatic capture(input int tile,input int ordinal,input logic [3:0] mask);
        read_done_valid=mask;
        for(int e=0;e<4;++e)read_done_work_seq[e]=32'(tile*MICROS+ordinal);
        tick();read_done_valid=0;
    endtask
    initial begin
        void'($value$plusargs("CASE=%s",fault_case));
        assert ($bits(dut.owner_q)+$bits(dut.source_free_valid)
            == 2*(35+$clog2(MICROS+1)+4*MICROS)+2)
            else $fatal(1,"Source join allocation mismatch");
        repeat(3)tick();reset=0;
        close_tile(0,2);capture(0,1,4'hf);
        if(fault_case=="duplicate")begin capture(0,1,4'h1);$fatal(1,"Missing duplicate assertion");end
        if(fault_case=="foreign_generation")begin capture(2,1,4'h1);$fatal(1,"Missing generation assertion");end
        if(fault_case=="duplicate_closure")begin close_tile(0,2);$fatal(1,"Missing closure assertion");end
        if(fault_case=="early_restart")begin invocation_start=1;tick();$fatal(1,"Missing restart assertion");end
        capture(0,2,4'h7);
        repeat(5)begin tick();assert(!(|source_free_valid))else $fatal(1,"Released before Z capture");end
        // The other three engines make source progress on the second buffer.
        close_tile(1,2);capture(1,1,4'h7);capture(1,2,4'h7);
        assert(!quiescent && releases[0]==0 && releases[1]==0)
            else $fatal(1,"Outstanding source ownership lost");
        capture(0,2,4'h8);
        assert(source_free_valid==2'b01)else $fatal(1,"Missing first source release");
        capture(1,1,4'h8);capture(1,2,4'h8);
        assert(source_free_valid==2'b10)else $fatal(1,"Missing second source release");
        tick();tick();
        assert(quiescent && releases[0]==1 && releases[1]==1)else $fatal(1,"First generation did not drain");
        // Three physical uses of both regions; sometimes all reads precede closure.
        for(int tile=2;tile<6;++tile)begin
            capture(tile,2,4'hf);capture(tile,1,4'hf);
            assert(!(|source_free_valid))else $fatal(1,"Reads fabricated producer closure");
            close_tile(tile,2);
            assert(source_free_valid==(2'b01<<tile%2))else $fatal(1,"Closure did not release owned reads");
            tick();tick();
        end
        // Exact maximum descriptors per source generation, no counter overflow.
        for(int tile=6;tile<8;++tile)begin
            close_tile(tile,MICROS);
            for(int micro=1;micro<=MICROS;++micro)begin
                capture(tile,micro,4'hf);
                assert(source_free_valid==((micro==MICROS)?(2'b01<<tile%2):2'b00))
                    else $fatal(1,"Maximum source count released early/late");
            end
            tick();tick();
        end
        assert(quiescent && releases[0]==4 && releases[1]==4)else $fatal(1,"Source generations did not drain");
        invocation_start=1;tick();invocation_start=0;releases='{default:0};
        close_tile(0,1);capture(0,1,4'hf);tick();tick();
        assert(quiescent && releases[0]==1)else $fatal(1,"No-reset invocation reuse failed");
        $display("TEST PASSED naive source generation join");$finish;
    end
    initial begin #100000;$fatal(1,"Source join timeout");end
endmodule

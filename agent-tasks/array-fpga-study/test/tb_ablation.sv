`timescale 1ns/1ps
`include "VX_define.vh"
// Cycle/data equivalence on the legal WoQ subset plus independent integer oracle.
module tb_ablation;
 localparam I_DATA_SIZE=`GEMM_INPUT_DATA_SIZE, W_DATA_SIZE=`GEMM_WEIGHT_DATA_SIZE;
 localparam SZ_DATA_SIZE=`GEMM_SCALE_ZERO_DATA_SIZE, O_DATA_SIZE=`GEMM_OUTPUT_DATA_SIZE;
 localparam TAG_WIDTH=1, ADDR_WIDTH=`MEM_ADDR_WIDTH;
 logic  clk;
 logic  reset;
 logic  i_req_valid;
 logic  i_req_rw;
 logic [ADDR_WIDTH-1:0] i_req_addr;
 logic [I_DATA_SIZE*8-1:0] i_req_data;
 logic [I_DATA_SIZE-1:0] i_req_byteen;
 logic [TAG_WIDTH-1:0] i_req_tag;
 wire  i_req_ready [2];
 wire  i_rsp_valid [2];
 wire [I_DATA_SIZE*8-1:0] i_rsp_data [2];
 wire [TAG_WIDTH-1:0] i_rsp_tag [2];
 logic  i_rsp_ready;
 logic  w_req_valid;
 logic  w_req_rw;
 logic [ADDR_WIDTH-1:0] w_req_addr;
 logic [W_DATA_SIZE*8-1:0] w_req_data;
 logic [W_DATA_SIZE-1:0] w_req_byteen;
 logic [TAG_WIDTH-1:0] w_req_tag;
 wire  w_req_ready [2];
 wire  w_rsp_valid [2];
 wire [W_DATA_SIZE*8-1:0] w_rsp_data [2];
 wire [TAG_WIDTH-1:0] w_rsp_tag [2];
 logic  w_rsp_ready;
 logic  sz_req_valid;
 logic  sz_req_rw;
 logic [ADDR_WIDTH-1:0] sz_req_addr;
 logic [SZ_DATA_SIZE*8-1:0] sz_req_data;
 logic [SZ_DATA_SIZE-1:0] sz_req_byteen;
 logic [TAG_WIDTH-1:0] sz_req_tag;
 wire  sz_req_ready [2];
 wire  sz_rsp_valid [2];
 wire [SZ_DATA_SIZE*8-1:0] sz_rsp_data [2];
 wire [TAG_WIDTH-1:0] sz_rsp_tag [2];
 logic  sz_rsp_ready;
 logic  o_req_valid;
 logic  o_req_rw;
 logic [ADDR_WIDTH-1:0] o_req_addr;
 logic [O_DATA_SIZE*8-1:0] o_req_data;
 logic [O_DATA_SIZE-1:0] o_req_byteen;
 logic [TAG_WIDTH-1:0] o_req_tag;
 wire  o_req_ready [2];
 wire  o_rsp_valid [2];
 wire [O_DATA_SIZE*8-1:0] o_rsp_data [2];
 wire [TAG_WIDTH-1:0] o_rsp_tag [2];
 logic  o_rsp_ready;
 logic  ctrl_start;
 logic  ctrl_quant_dir;
 logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ctrl_acc_mem_base_addr;
 logic [`GEMM_ACC_MEM_ADDR_WIDTH-1:0] ctrl_output_mem_base_addr;
 logic [`GEMM_ACC_MAX_CNT-1:0] ctrl_acc_cnt;
 logic  ctrl_wreg_use_idx;
 logic  ctrl_sreg_use_idx;
 logic  ctrl_zreg_use_idx;
 logic  ctrl_is_load;
 logic  ctrl_is_last;
 wire  ctrl_idle [2];
 wire  ctrl_done [2];
 VX_gemm_unit_top dut0(
 .clk(clk),
 .reset(reset),
 .i_req_valid(i_req_valid),
 .i_req_rw(i_req_rw),
 .i_req_addr(i_req_addr),
 .i_req_data(i_req_data),
 .i_req_byteen(i_req_byteen),
 .i_req_tag(i_req_tag),
 .i_req_ready(i_req_ready[0]),
 .i_rsp_valid(i_rsp_valid[0]),
 .i_rsp_data(i_rsp_data[0]),
 .i_rsp_tag(i_rsp_tag[0]),
 .i_rsp_ready(i_rsp_ready),
 .w_req_valid(w_req_valid),
 .w_req_rw(w_req_rw),
 .w_req_addr(w_req_addr),
 .w_req_data(w_req_data),
 .w_req_byteen(w_req_byteen),
 .w_req_tag(w_req_tag),
 .w_req_ready(w_req_ready[0]),
 .w_rsp_valid(w_rsp_valid[0]),
 .w_rsp_data(w_rsp_data[0]),
 .w_rsp_tag(w_rsp_tag[0]),
 .w_rsp_ready(w_rsp_ready),
 .sz_req_valid(sz_req_valid),
 .sz_req_rw(sz_req_rw),
 .sz_req_addr(sz_req_addr),
 .sz_req_data(sz_req_data),
 .sz_req_byteen(sz_req_byteen),
 .sz_req_tag(sz_req_tag),
 .sz_req_ready(sz_req_ready[0]),
 .sz_rsp_valid(sz_rsp_valid[0]),
 .sz_rsp_data(sz_rsp_data[0]),
 .sz_rsp_tag(sz_rsp_tag[0]),
 .sz_rsp_ready(sz_rsp_ready),
 .o_req_valid(o_req_valid),
 .o_req_rw(o_req_rw),
 .o_req_addr(o_req_addr),
 .o_req_data(o_req_data),
 .o_req_byteen(o_req_byteen),
 .o_req_tag(o_req_tag),
 .o_req_ready(o_req_ready[0]),
 .o_rsp_valid(o_rsp_valid[0]),
 .o_rsp_data(o_rsp_data[0]),
 .o_rsp_tag(o_rsp_tag[0]),
 .o_rsp_ready(o_rsp_ready),
 .ctrl_start(ctrl_start),
 .ctrl_quant_dir(ctrl_quant_dir),
 .ctrl_acc_mem_base_addr(ctrl_acc_mem_base_addr),
 .ctrl_output_mem_base_addr(ctrl_output_mem_base_addr),
 .ctrl_acc_cnt(ctrl_acc_cnt),
 .ctrl_wreg_use_idx(ctrl_wreg_use_idx),
 .ctrl_sreg_use_idx(ctrl_sreg_use_idx),
 .ctrl_zreg_use_idx(ctrl_zreg_use_idx),
 .ctrl_is_load(ctrl_is_load),
 .ctrl_is_last(ctrl_is_last),
 .ctrl_idle(ctrl_idle[0]),
 .ctrl_done(ctrl_done[0])
 );
 VX_gemm_unit_woq_top dut1(
 .clk(clk),
 .reset(reset),
 .i_req_valid(i_req_valid),
 .i_req_rw(i_req_rw),
 .i_req_addr(i_req_addr),
 .i_req_data(i_req_data),
 .i_req_byteen(i_req_byteen),
 .i_req_tag(i_req_tag),
 .i_req_ready(i_req_ready[1]),
 .i_rsp_valid(i_rsp_valid[1]),
 .i_rsp_data(i_rsp_data[1]),
 .i_rsp_tag(i_rsp_tag[1]),
 .i_rsp_ready(i_rsp_ready),
 .w_req_valid(w_req_valid),
 .w_req_rw(w_req_rw),
 .w_req_addr(w_req_addr),
 .w_req_data(w_req_data),
 .w_req_byteen(w_req_byteen),
 .w_req_tag(w_req_tag),
 .w_req_ready(w_req_ready[1]),
 .w_rsp_valid(w_rsp_valid[1]),
 .w_rsp_data(w_rsp_data[1]),
 .w_rsp_tag(w_rsp_tag[1]),
 .w_rsp_ready(w_rsp_ready),
 .sz_req_valid(sz_req_valid),
 .sz_req_rw(sz_req_rw),
 .sz_req_addr(sz_req_addr),
 .sz_req_data(sz_req_data),
 .sz_req_byteen(sz_req_byteen),
 .sz_req_tag(sz_req_tag),
 .sz_req_ready(sz_req_ready[1]),
 .sz_rsp_valid(sz_rsp_valid[1]),
 .sz_rsp_data(sz_rsp_data[1]),
 .sz_rsp_tag(sz_rsp_tag[1]),
 .sz_rsp_ready(sz_rsp_ready),
 .o_req_valid(o_req_valid),
 .o_req_rw(o_req_rw),
 .o_req_addr(o_req_addr),
 .o_req_data(o_req_data),
 .o_req_byteen(o_req_byteen),
 .o_req_tag(o_req_tag),
 .o_req_ready(o_req_ready[1]),
 .o_rsp_valid(o_rsp_valid[1]),
 .o_rsp_data(o_rsp_data[1]),
 .o_rsp_tag(o_rsp_tag[1]),
 .o_rsp_ready(o_rsp_ready),
 .ctrl_start(ctrl_start),
 .ctrl_quant_dir(ctrl_quant_dir),
 .ctrl_acc_mem_base_addr(ctrl_acc_mem_base_addr),
 .ctrl_output_mem_base_addr(ctrl_output_mem_base_addr),
 .ctrl_acc_cnt(ctrl_acc_cnt),
 .ctrl_wreg_use_idx(ctrl_wreg_use_idx),
 .ctrl_sreg_use_idx(ctrl_sreg_use_idx),
 .ctrl_zreg_use_idx(ctrl_zreg_use_idx),
 .ctrl_is_load(ctrl_is_load),
 .ctrl_is_last(ctrl_is_last),
 .ctrl_idle(ctrl_idle[1]),
 .ctrl_done(ctrl_done[1])
 );
 always #5 clk=~clk;
 task automatic init_signals();
 i_req_valid=0;
 i_req_rw=0;
 i_req_addr=0;
 i_req_data=0;
 i_req_byteen=0;
 i_req_tag=0;
 i_rsp_ready=0;
 w_req_valid=0;
 w_req_rw=0;
 w_req_addr=0;
 w_req_data=0;
 w_req_byteen=0;
 w_req_tag=0;
 w_rsp_ready=0;
 sz_req_valid=0;
 sz_req_rw=0;
 sz_req_addr=0;
 sz_req_data=0;
 sz_req_byteen=0;
 sz_req_tag=0;
 sz_rsp_ready=0;
 o_req_valid=0;
 o_req_rw=0;
 o_req_addr=0;
 o_req_data=0;
 o_req_byteen=0;
 o_req_tag=0;
 o_rsp_ready=0;
 ctrl_start=0;
 ctrl_quant_dir=0;
 ctrl_acc_mem_base_addr=0;
 ctrl_output_mem_base_addr=0;
 ctrl_acc_cnt=0;
 ctrl_wreg_use_idx=0;
 ctrl_sreg_use_idx=0;
 ctrl_zreg_use_idx=0;
 ctrl_is_load=0;
 ctrl_is_last=0;
 i_rsp_ready=1; w_rsp_ready=1; sz_rsp_ready=1; o_rsp_ready=1;
 i_req_byteen='1; w_req_byteen='1; sz_req_byteen='1; o_req_byteen='1;
 endtask
 bit compare_enabled=0;
 int comparisons=0, checked_lanes=0, done_count=0, low_ready_observations=0;
 int expected [8][`MXU_COL];
 int seed=1234;
 always @(posedge clk) begin
   if (!reset) begin
     if (ctrl_done[0]) done_count++;
     if (compare_enabled) begin
       comparisons++;
       if ({i_req_ready[0],w_req_ready[0],sz_req_ready[0],o_req_ready[0],o_rsp_valid[0],ctrl_done[0],ctrl_idle[0]}
           !== {i_req_ready[1],w_req_ready[1],sz_req_ready[1],o_req_ready[1],o_rsp_valid[1],ctrl_done[1],ctrl_idle[1]})
         $fatal(1,"WoQ/WKV handshake/control mismatch at cycle %0t",$time);
       if (o_rsp_valid[0] && {o_rsp_data[0],o_rsp_tag[0]} !== {o_rsp_data[1],o_rsp_tag[1]})
         $fatal(1,"WoQ/WKV output mismatch at cycle %0t",$time);
       if (w_req_valid && w_req_addr[1]) $fatal(1,"column load is outside WoQ domain");
       if (ctrl_start && ctrl_quant_dir) $fatal(1,"QROW is outside WoQ domain");
     end
   end
 end
 initial begin
   #5000000;
   $fatal(1,"test watchdog expired");
 end
 task automatic reset_duts();
   @(negedge clk); reset=1;
   repeat(8) @(negedge clk);
   reset=0;
   repeat(5) @(negedge clk);
   if (!ctrl_idle[0] || !ctrl_idle[1]) $fatal(1,"reset did not return engines idle");
 endtask
 function automatic int weight_value(input int r,c,bank);
   return ((r+2*c+bank+seed)%7)+1;
 endfunction
 function automatic int input_value(input int row,lane,iteration);
   return 1+((row+lane+iteration+seed)%2);
 endfunction
 task automatic write_params(input int bank);
   @(negedge clk);
   sz_req_valid=1; sz_req_rw=1;
   sz_req_addr=bank*(`MXU_MAX_DIM*16/8);
   for(int i=0;i<`MXU_MAX_DIM;i++) sz_req_data[16*i+:16]=16'(directed_fp::encode(real'(bank+1),16));
   do @(posedge clk); while(!sz_req_ready[0]);
   @(negedge clk); sz_req_valid=0;
   @(negedge clk); sz_req_valid=1;
   sz_req_addr=(2+bank)*(`MXU_MAX_DIM*16/8);
   for(int i=0;i<`MXU_MAX_DIM;i++) sz_req_data[16*i+:16]=16'(bank+1);
   do @(posedge clk); while(!sz_req_ready[0]);
   @(negedge clk); sz_req_valid=0;
 endtask
 task automatic write_weights(input int bank, input bit column_load);
   for(int b=0;b<`MXU_ROW/`MXU_WLOAD_NUM;b++) begin
     @(negedge clk); w_req_valid=1; w_req_rw=1;
     w_req_addr=ADDR_WIDTH'((column_load<<1)|bank);
     for(int l=0;l<`MXU_WLOAD_NUM;l++)
       for(int c=0;c<`MXU_COL;c++)
         w_req_data[(`MXU_COL*l+c)*4+:4]=4'(column_load ? weight_value(c,b*`MXU_WLOAD_NUM+l,bank) : weight_value(b*`MXU_WLOAD_NUM+l,c,bank));
     do @(posedge clk); while(!w_req_ready[0]);
   end
   @(negedge clk); w_req_valid=0;
   repeat(5) @(negedge clk);
 endtask
 task automatic execute_tile(input int bank,nrows,iteration,base_row,input bit accumulate,qrow);
   int previous_done;
   previous_done=done_count;
   @(negedge clk);
   ctrl_quant_dir=qrow; ctrl_is_load=!accumulate;
   ctrl_acc_mem_base_addr=base_row*`GEMM_PSUM_DATA_SIZE;
   ctrl_acc_cnt=nrows; ctrl_wreg_use_idx=bank;
   ctrl_sreg_use_idx=bank; ctrl_zreg_use_idx=bank;
   ctrl_start=1;
   @(negedge clk); ctrl_start=0;
   for(int m=0;m<nrows;m++) begin
     repeat((m+iteration)%3) @(negedge clk);
     @(negedge clk); i_req_valid=1;
     for(int r=0;r<`MXU_ROW;r++) i_req_data[r*16+:16]=16'(directed_fp::encode(real'(input_value(m,r,iteration)),16));
     do @(posedge clk); while(!i_req_ready[0]);
     @(negedge clk); i_req_valid=0;
     for(int c=0;c<`MXU_COL;c++) begin
       if(!accumulate) expected[m][c]=0;
       for(int r=0;r<`MXU_ROW;r++) expected[m][c]+=input_value(m,r,iteration)*(weight_value(r,c,bank)-(bank+1))*(bank+1);
     end
   end
   while(done_count==previous_done) @(negedge clk);
   while(!ctrl_idle[0]) @(negedge clk);
   repeat(4) @(negedge clk);
 endtask
 task automatic read_and_check(input int nrows,base_row,input bit ready_low);
   logic [15:0] want;
   for(int m=0;m<nrows;m++) begin
     @(negedge clk); o_rsp_ready=!ready_low;
     o_req_valid=1; o_req_rw=0; o_req_addr=base_row+m; o_req_tag=m%2;
     do @(posedge clk); while(!o_req_ready[0]);
     @(negedge clk); o_req_valid=0;
     while(!o_rsp_valid[0]) @(negedge clk);
     // Production readout pulses valid irrespective of rsp_ready. Compare the
     // presented response here; do not claim a lossless ready/valid interface.
     if (ready_low) low_ready_observations++;
     for(int c=0;c<`MXU_COL;c++) begin
       want=16'(directed_fp::encode(real'(expected[m][c]),16));
       if(o_rsp_data[0][c*16+:16] !== want)
         $fatal(1,"numerical mismatch row=%0d col=%0d got=%h want=%h integer=%0d",m,c,o_rsp_data[0][c*16+:16],want,expected[m][c]);
       checked_lanes++;
     end
     @(negedge clk); o_rsp_ready=1;
     repeat(3) @(negedge clk);
   end
 endtask
 initial begin
   clk=0; reset=1;
   void'($value$plusargs("SEED=%d",seed));
   init_signals(); reset_duts(); compare_enabled=1;
   write_params(0); write_params(1);
   write_weights(0,0); write_weights(1,0);
   execute_tile(0,4,0,4,0,0); read_and_check(4,4,0);
   execute_tile(1,4,1,4,1,0); read_and_check(4,4,0);
   execute_tile(0,4,2,4,1,0); read_and_check(4,4,1);
   $display("QCOL equivalence and oracle: three K tiles, both weight/scale/zero banks, input gaps");
   init_signals(); reset_duts();
   write_params(1); write_weights(1,0);
   execute_tile(1,3,3,12,0,0); read_and_check(3,12,0);
   $display("Post-reset QCOL operation checked");
   compare_enabled=0; init_signals(); reset_duts();
   write_params(1); write_weights(1,1);
   execute_tile(1,3,4,20,0,1); read_and_check(3,20,0);
   $display("WKV QROW plus column-load numerical sanity checked");
   if(comparisons<100 || checked_lanes!=576 || low_ready_observations!=4) $fatal(1,"coverage counters incomplete");
   $display("TEST PASSED seed=%0d compared_cycles=%0d checked_lanes=%0d low_ready_responses=%0d",seed,comparisons,checked_lanes,low_ready_observations);
   $finish;
 end
endmodule

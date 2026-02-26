/*
  - Gemm 연산할 때 필요한 제어 신호들을 생성하는 모듈. 주로 DMA와 관련된 제어 신호를 생성한다.
  - cfg_reg를 받아서 동작함. cfg_reg에는 matrix 크기, stride, padding 등 정보가 들어있음.
    - start, idle, done signal을 이용해서 시작 시점을 제어함.
    - 내부에 wid, tid등 정보도 필요하면 추가해서 현재 요청이 어떤 워크 아이템, 스레드인지 추적할 수 있도록 함.
  - gemm 연산을 위한 input, weight, output 데이터의 LMEM 접근 제어 신호를 생성함.
    - 각 데이터 타입별로 별도의 read/write 제어 신호를 생성함.
    - gemm_node안에있는 local DMA 엔진과 연동됨.
    - LMEM <-> GEMM 유닛 간 데이터 전송을 control 하는 것이 목적.
  - tiling을 위해서 global memory (dcache) <-> LMEM 사이의 DMA를 제어함.
    - dma cmd controller에게 제어 신호를 보냄.
  
*/

/*
  - parent queue랑 child queue는 VX_fifo_queue를 사용
  - child queue는 5개 (input micro-tile read, weight micro-tile read, sz micro-tile read, output micro-tile write, global dma)
  - child queue는 node가 busy하면 대기 (idle 신호를 ready로 사용)
  - 각 node가 notify를 만났을 때 gemm_sync_slv_if로 직접 올린다는 가정
  - done은 현재 구조에서 사용하지 않으므로 0으로 둠. 
*/

`include "VX_define.vh"

module VX_gemm_ctrl import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter int N_CHILDREN = 5,
    parameter int N_NODE     = 5
) (
    input  wire              clk,
    input  wire              reset,

    VX_config_reg_if.slave    cfg_reg_if,         // from gemm node
    VX_gemm_ctrl_if.master    gemm_ctrl_if,       // to gemm unit + cmd ctrls
    VX_node_done_if.master    done_if,            // to job frontend (notify done)
    VX_gemm_sync_if.slave     gemm_sync_slv_if[N_NODE] // from cmd ctrls (notify events)
);

    // -------------------------------------------------------------------------
    // Job completion tracking for job_frontend done_if
    // -------------------------------------------------------------------------
    localparam int CFG_R_CONTROL = 0;

    logic                        job_active_q;
    logic [31:0]                 active_entry_id_q;
    logic [N_CHILDREN-1:0]       child_q_empty_v;
    logic                        parent_q_empty;
    logic                        gemm_start;

    wire cfg_start_fire = cfg_reg_if.valid && cfg_reg_if.ready && cfg_reg_if.regs[CFG_R_CONTROL][0];
    wire workers_idle   = gemm_ctrl_if.input_read_flag.idle
                        && gemm_ctrl_if.weight_read_flag.idle
                        && gemm_ctrl_if.quant_param_read_flag.idle
                        && gemm_ctrl_if.output_write_flag.idle
                        && gemm_ctrl_if.dma_flag.idle;
    wire queues_idle    = parent_q_empty && (&child_q_empty_v);
    wire all_idle_now   = cfg_reg_if.ready && queues_idle && workers_idle;
    wire done_fire      = done_if.valid && done_if.ready;

    // done_if is held until handshake so dispatcher never misses completion.
    assign done_if.valid    = job_active_q && all_idle_now;
    assign done_if.entry_id = active_entry_id_q;

    always_ff @(posedge clk) begin
      if (reset) begin
        job_active_q     <= 1'b0;
        active_entry_id_q <= '0;
      end else begin
        if (cfg_start_fire) begin
          job_active_q      <= 1'b1;
          active_entry_id_q <= cfg_reg_if.entry_id;
        end else if (done_fire) begin
          job_active_q      <= 1'b0;
        end
      end
    end

    // -------------------------------------------------------------------------
    // Local interfaces
    // -------------------------------------------------------------------------
    VX_gemm_fsm_if gemm_fsm_if        ();
    VX_gemm_fsm_if gemm_pqueue_out    ();
    VX_gemm_fsm_if gemm_sync_out[N_CHILDREN] ();
    VX_gemm_fsm_if gemm_cqueue_out[N_CHILDREN] ();

    // -------------------------------------------------------------------------
    // GEMM FSM: produces parent cmd stream (cmd + start pulse)
    // -------------------------------------------------------------------------
    VX_gemm_fsm #(
      .INSTANCE_ID(INSTANCE_ID)
    ) u_VX_gemm_fsm (
      .clk        (clk),
      .reset      (reset),
      .cfg_reg_if (cfg_reg_if),
      .gemm_fsm_if(gemm_fsm_if),
      .gemm_start_o(gemm_start)
    );

    // -------------------------------------------------------------------------
    // Parent cmd queue: store ONLY cmd payload (NOT start)
    //   - start is regenerated as (valid && sync_ready) pulse.
    //   - FSM sees idle=~full (buffer-only).
    // -------------------------------------------------------------------------
    localparam int PARENT_QUEUE_DATAW = $bits(gemm_unified_cmd_t);

    wire                        parent_q_full;
    wire [PARENT_QUEUE_DATAW-1:0] parent_q_dout;

    wire parent_q_push  = gemm_fsm_if.ctrl.start && gemm_fsm_if.flag.idle;
    wire parent_out_fire  = !parent_q_empty && gemm_pqueue_out.flag.idle;

    // Backpressure to FSM: do not emit start if queue full
    assign gemm_fsm_if.flag.idle = ~parent_q_full;  //sync에서 stall 되어도 parent queue에 버퍼링 가능
    assign gemm_fsm_if.flag.done = '0; // unused

    // Drive payload to sync; generate start pulse from fire
    assign gemm_pqueue_out.ctrl.cmd   = parent_q_dout;
    assign gemm_pqueue_out.ctrl.start = ~parent_q_empty;

    VX_fifo_queue #(
      .DATAW (PARENT_QUEUE_DATAW),
      .DEPTH (4)
    ) u_parent_cmd_queue (
      .clk      (clk),
      .reset    (reset),
      .push     (parent_q_push),
      .pop      (parent_out_fire),
      .data_in  (gemm_fsm_if.ctrl.cmd),
      .data_out (parent_q_dout),
      .empty    (parent_q_empty),
      .full     (parent_q_full),
      .alm_empty(),
      .alm_full (),
      .size     ()
    );

    // -------------------------------------------------------------------------
    // Sync: wait/notify 처리 + child demux
    //   - gemm_pqueue_out is "slave" into sync: sync drives gemm_pqueue_out.flag.idle
    // -------------------------------------------------------------------------
    VX_gemm_sync #(
      .INSTANCE_ID (INSTANCE_ID),
      .N_CHILDREN  (N_CHILDREN),
      .N_NODE      (N_NODE)
    ) u_VX_gemm_sync (
      .clk             (clk),
      .reset           (reset),
      .gemm_fsm_slv_if  (gemm_pqueue_out),
      .gemm_fsm_mas_if  (gemm_sync_out),
      .gemm_sync_slv_if (gemm_sync_slv_if),
      .gemm_start_i     (gemm_start)
    );

    // -------------------------------------------------------------------------
    // Child cmd queues: store ONLY cmd payload (NOT start)
    //   - sync_out[i].flag.idle provides backpressure to sync:
    //       here: buffer-only => idle = ~child_full
    //   - unit stall is handled at queue output: fire = valid && unit_idle
    // -------------------------------------------------------------------------
    localparam int CHILD_QUEUE_DATAW = $bits(gemm_unified_cmd_t);

    genvar i;
    generate
      for (i = 0; i < N_CHILDREN; i = i + 1) begin : gen_child_cmd_queues
        wire                        child_q_full, child_q_empty;
        wire [CHILD_QUEUE_DATAW-1:0] child_q_dout;

        // push when sync issues and we report ready (buffer-only)
        wire child_q_push = gemm_sync_out[i].ctrl.start && gemm_sync_out[i].flag.idle;

        // output to unit: valid if not empty, ready is unit idle
        wire child_out_fire  = !child_q_empty && gemm_cqueue_out[i].flag.idle;

        // backpressure to sync: only depends on queue capacity
        assign gemm_sync_out[i].flag.idle = ~child_q_full;
        assign gemm_sync_out[i].flag.done = '0; // unused

        // drive payload to unit-side interface; generate start from fire
        assign gemm_cqueue_out[i].ctrl.cmd   = child_q_dout;
        assign gemm_cqueue_out[i].ctrl.start = child_out_fire;

        VX_fifo_queue #(
          .DATAW (CHILD_QUEUE_DATAW),
          .DEPTH (4)
        ) u_child_cmd_queue (
          .clk      (clk),
          .reset    (reset),
          .push     (child_q_push),
          .pop      (child_out_fire),
          .data_in  (gemm_sync_out[i].ctrl.cmd),
          .data_out (child_q_dout),
          .empty    (child_q_empty),
          .full     (child_q_full),
          .alm_empty(),
          .alm_full (),
          .size     ()
        );

        assign child_q_empty_v[i] = child_q_empty;
      end
    endgenerate

    // -------------------------------------------------------------------------
    // Connect child cmd queues to gemm_ctrl_if outputs
    // Mapping (as you wrote):
    //   0=input_read, 1=weight_read, 2=quant_param_read, 3=output_write, 4=dma
    // -------------------------------------------------------------------------
    // child 0: input read
    assign gemm_ctrl_if.input_read_ctrl.cmd   = gemm_cqueue_out[0].ctrl.cmd;
    assign gemm_ctrl_if.input_read_ctrl.start = gemm_cqueue_out[0].ctrl.start;
    assign gemm_cqueue_out[0].flag.idle       = gemm_ctrl_if.input_read_flag.idle;
    assign gemm_cqueue_out[0].flag.done       = '0;

    // child 1: weight read
    assign gemm_ctrl_if.weight_read_ctrl.cmd   = gemm_cqueue_out[1].ctrl.cmd;
    assign gemm_ctrl_if.weight_read_ctrl.start = gemm_cqueue_out[1].ctrl.start;
    assign gemm_cqueue_out[1].flag.idle        = gemm_ctrl_if.weight_read_flag.idle;
    assign gemm_cqueue_out[1].flag.done        = '0;

    // child 2: quant param read (scale/zp)
    assign gemm_ctrl_if.quant_param_read_ctrl.cmd   = gemm_cqueue_out[2].ctrl.cmd;
    assign gemm_ctrl_if.quant_param_read_ctrl.start = gemm_cqueue_out[2].ctrl.start;
    assign gemm_cqueue_out[2].flag.idle             = gemm_ctrl_if.quant_param_read_flag.idle;
    assign gemm_cqueue_out[2].flag.done             = '0;

    // child 3: output write
    assign gemm_ctrl_if.output_write_ctrl.cmd   = gemm_cqueue_out[3].ctrl.cmd;
    assign gemm_ctrl_if.output_write_ctrl.start = gemm_cqueue_out[3].ctrl.start;
    assign gemm_cqueue_out[3].flag.idle         = gemm_ctrl_if.output_write_flag.idle;
    assign gemm_cqueue_out[3].flag.done         = '0;

    // child 4: global DMA (dcache <-> lmem)
    assign gemm_ctrl_if.dma_ctrl.cmd   = gemm_cqueue_out[4].ctrl.cmd;
    assign gemm_ctrl_if.dma_ctrl.start = gemm_cqueue_out[4].ctrl.start;
    assign gemm_cqueue_out[4].flag.idle = gemm_ctrl_if.dma_flag.idle;
    assign gemm_cqueue_out[4].flag.done = '0;

    assign gemm_ctrl_if.M_orig = gemm_fsm_if.M_orig;
    assign gemm_ctrl_if.N_orig = gemm_fsm_if.N_orig;
    assign gemm_ctrl_if.K_orig = gemm_fsm_if.K_orig;
    assign gemm_ctrl_if.qblk_orig = gemm_fsm_if.qblk_orig;
    assign gemm_ctrl_if.M_target = gemm_fsm_if.M_target;
    assign gemm_ctrl_if.N_target = gemm_fsm_if.N_target;
    assign gemm_ctrl_if.K_target = gemm_fsm_if.K_target;
    assign gemm_ctrl_if.wtrans_tot = gemm_fsm_if.wtrans_tot;
    assign gemm_ctrl_if.qdir_tot = gemm_fsm_if.qdir_tot;
    assign gemm_ctrl_if.entry_id = gemm_fsm_if.entry_id;
endmodule

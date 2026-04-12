`include "VX_define.vh"

module VX_cmd_constructor import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = ""
) (
    input  wire                 clk,
    input  wire                 reset,

    VX_instruction_if.slave     instruction_if,
    VX_gemm_fsm_if.master       gemm_fsm_if
);

  // ----------------------------
  // raw 4-bit opcodes from SW
  // ----------------------------
  localparam logic [3:0] RAW_OP_DMA_LOAD         = 4'd1;
  localparam logic [3:0] RAW_OP_DMA_STORE        = 4'd2;
  localparam logic [3:0] RAW_OP_NOTIFY           = 4'd3;
  localparam logic [3:0] RAW_OP_WAIT             = 4'd4;
  localparam logic [3:0] RAW_OP_MXU_LOAD_WEIGHT  = 4'd5;
  localparam logic [3:0] RAW_OP_MXU_LOAD_QPARAM  = 4'd6;
  localparam logic [3:0] RAW_OP_MXU_LOAD_INPUT   = 4'd7;
  localparam logic [3:0] RAW_OP_MXU_STORE_OUTPUT = 4'd8;
  localparam logic [3:0] RAW_OP_CLEAR            = 4'd9;
  // Raw opcodes are forwarded downstream in cmd.instr[3:0].

  typedef enum logic [1:0] {
    S_IDLE,
    S_COLLECT,
    S_WAIT_ISSUE
  } state_t;

  state_t            state_q, state_d;
  logic [63:0]       inst0_q, inst1_q, inst2_q;
  logic [31:0]       entry_id_q;
  logic [1:0]        words_expected_q, words_expected_d;
  logic [1:0]        words_captured_q, words_captured_d;

  logic              capture_first_fire;
  logic              capture_next_fire;
  logic              cmd_supported;
  logic              cmd_is_clear;
  logic [1:0]        first_word_count;

  gemm_unified_cmd_t decoded_cmd;
  gemm_unified_cmd_t out_cmd_d;
  logic              out_start_d;

  function automatic logic [1:0] cmd_word_count(input logic [3:0] raw_op);
    begin
      unique case (raw_op)
        RAW_OP_DMA_LOAD,
        RAW_OP_DMA_STORE:        cmd_word_count = 2'd3;
        RAW_OP_NOTIFY,
        RAW_OP_WAIT,
        RAW_OP_MXU_LOAD_WEIGHT,
        RAW_OP_CLEAR:            cmd_word_count = 2'd1;
        RAW_OP_MXU_LOAD_QPARAM,
        RAW_OP_MXU_LOAD_INPUT,
        RAW_OP_MXU_STORE_OUTPUT: cmd_word_count = 2'd2;
        default:                 cmd_word_count = 2'd0;
      endcase
    end
  endfunction

  function automatic gemm_unified_cmd_t build_cmd(
    input logic [63:0] w0,
    input logic [63:0] w1,
    input logic [63:0] w2
  );
    gemm_unified_cmd_t c;

    logic [3:0]  raw_op;
    logic [31:0] seg_size;
    logic [31:0] raw_value;

    logic [23:0] tmem_base24;
    logic [23:0] mxu_base24;
    logic [23:0] acc_mem_base24;
    logic [35:0] dram_base36;

    logic [15:0] tmem_stride16;
    logic [15:0] dram_stride16;
    logic [15:0] mxu_stride16;
    logic [15:0] stride16;
    logic [15:0] bound16;
    logic [31:0] acc_cnt;

    logic        set_mode;
    logic [4:0]  reg_id5;

    logic        wtrans;
    logic        reg_idx;

    logic        is_accum;
    logic        is_last;
    logic        wreg_idx;
    logic        sreg_idx;
    logic        zreg_idx;
    logic        qdir;

    begin
      c      = '0;
      raw_op = w0[3:0];

      unique case (raw_op)
        RAW_OP_DMA_LOAD: begin
          // <tmem_base_addr[24], dram_base_addr[36], opcode[4]>
          // <tmem_stride0[16], dram_stride0[16], bound0[16]>
          // <seg_size[32]>
          tmem_base24   = w0[63:40];
          dram_base36   = w0[39:4];
          tmem_stride16 = w1[47:32];
          dram_stride16 = w1[31:16];
          bound16       = w1[15:0];
          seg_size      = w2[31:0];

          // Keep raw opcode in instr[3:0]; carry seg_size in instr[31:4].
          c.instr      = {seg_size[27:0], RAW_OP_DMA_LOAD};
          c.rs1_data   = `XLEN'(tmem_base24);  //dst
          c.rs2_data   = `XLEN'(dram_base36);  //src
          c.stride     = {dram_stride16, tmem_stride16};
          c.bound      = bound16;
        end

        RAW_OP_DMA_STORE: begin
          tmem_base24   = w0[63:40];
          dram_base36   = w0[39:4];
          tmem_stride16 = w1[47:32];
          dram_stride16 = w1[31:16];
          bound16       = w1[15:0];
          seg_size      = w2[31:0];

          // Keep raw opcode in instr[3:0]; carry seg_size in instr[31:4].
          c.instr      = {seg_size[27:0], RAW_OP_DMA_STORE};
          c.rs1_data   = `XLEN'(dram_base36);  //dst
          c.rs2_data   = `XLEN'(tmem_base24);  //src
          c.stride     = {dram_stride16, tmem_stride16};
          c.bound      = bound16;
        end

        RAW_OP_NOTIFY: begin
          // <set_mode[1], value[32], reg_id[5], opcode[4]>
          set_mode  = w0[41];
          raw_value = w0[40:9];
          reg_id5   = w0[8:4];

          // rs2_data remains legacy-friendly: {set_mode, value[30:0]}.
          c.instr      = {28'd0, RAW_OP_NOTIFY};
          c.rs1_data   = `XLEN'(reg_id5);
          c.rs2_data   = `XLEN'({set_mode, raw_value[30:0]});
        end

        RAW_OP_WAIT: begin
          // <value[32], reg_id[5], opcode[4]>
          raw_value = w0[40:9];
          reg_id5   = w0[8:4];

          c.instr      = {28'd0, RAW_OP_WAIT};
          c.rs1_data   = `XLEN'(reg_id5);
          c.rs2_data   = `XLEN'(raw_value);
        end

        RAW_OP_MXU_LOAD_WEIGHT: begin
          // <wtrans[1], reg_idx[1], bound[16], stride[16],
          //  tmem_base_addr[24], opcode[4]>
          // raw[63:62] are currently reserved.
          wtrans      = w0[61];
          reg_idx     = w0[60];
          bound16     = w0[59:44];
          stride16    = w0[43:28];
          tmem_base24 = w0[27:4];

          c.instr     = {28'd0, RAW_OP_MXU_LOAD_WEIGHT};
          c.flags[1]  = wtrans;
          c.flags[0]  = reg_idx;
          c.rs2_data  = `XLEN'(tmem_base24);
          c.stride    = {16'd0, stride16};
          c.bound     = bound16;
        end

        RAW_OP_MXU_LOAD_QPARAM: begin
          // <mxu_sz_base_addr[24], tmem_base_addr[24], opcode[4]>
          // <tmem_stride0[16], mxu_stride0[16], bound0[16]>
          mxu_base24    = w0[51:28];
          tmem_base24   = w0[27:4];
          tmem_stride16 = w1[47:32];
          mxu_stride16  = w1[31:16];
          bound16       = w1[15:0];

          c.instr       = {28'd0, RAW_OP_MXU_LOAD_QPARAM};
          c.flags[0]    = reg_idx;
          c.rs1_data    = `XLEN'(mxu_base24);
          c.rs2_data    = `XLEN'(tmem_base24);
          c.stride      = {tmem_stride16, mxu_stride16};
          c.bound       = bound16;
        end

        RAW_OP_MXU_LOAD_INPUT: begin
          // <is_accum[1], is_last[1], wreg_idx[1], sreg_idx[1], zreg_idx[1],
          //  qdir[1], tmem_base_addr[24], acc_mem_base_addr[24], opcode[4]>
          // <stride[16], bound[16]>
          is_accum       = w0[57];
          is_last        = w0[56];
          wreg_idx       = w0[55];
          sreg_idx       = w0[54];
          zreg_idx       = w0[53];
          qdir           = w0[52];
          tmem_base24    = w0[51:28];
          acc_mem_base24 = w0[27:4];
          acc_cnt        = w1[63:32];
          stride16       = w1[31:16];
          bound16        = w1[15:0];

          c.instr        = {acc_cnt[27:0], RAW_OP_MXU_LOAD_INPUT};
          c.flags        = {2'b00, qdir, is_last, is_accum, wreg_idx, sreg_idx, zreg_idx};
          c.rs1_data     = `XLEN'(acc_mem_base24);
          c.rs2_data     = `XLEN'(tmem_base24);
          c.stride       = {16'd0, stride16};
          c.bound        = bound16;
        end

        RAW_OP_MXU_STORE_OUTPUT: begin
          // <tmem_base_addr[24], acc_mem_base_addr[24], opcode[4]>
          // <stride[16], bound[16]>
          tmem_base24    = w0[51:28];
          acc_mem_base24 = w0[27:4];
          stride16       = w1[31:16];
          bound16        = w1[15:0];

          c.instr      = {28'd0, RAW_OP_MXU_STORE_OUTPUT};
          c.rs1_data   = `XLEN'(tmem_base24);
          c.rs2_data   = `XLEN'(acc_mem_base24);
          c.stride     = {16'd0, stride16};
          c.bound      = bound16;
        end

        RAW_OP_CLEAR: begin
          c.instr = {28'd0, RAW_OP_CLEAR};
        end

        default: begin
          c = '0;
        end
      endcase

      build_cmd = c;
    end
  endfunction

  assign decoded_cmd      = build_cmd(inst0_q, inst1_q, inst2_q);
  assign cmd_supported    = (cmd_word_count(inst0_q[3:0]) != 2'd0);
  assign cmd_is_clear     = (inst0_q[3:0] == RAW_OP_CLEAR);
  assign first_word_count = cmd_word_count(instruction_if.inst[3:0]);

  assign gemm_fsm_if.ctrl.cmd   = out_cmd_d;
  assign gemm_fsm_if.ctrl.start = out_start_d;

  always_comb begin
    state_d              = state_q;
    words_expected_d     = words_expected_q;
    words_captured_d     = words_captured_q;
    capture_first_fire   = 1'b0;
    capture_next_fire    = 1'b0;
    out_cmd_d            = '0;
    out_start_d          = 1'b0;
    instruction_if.ready = (state_q != S_WAIT_ISSUE);

    unique case (state_q)
      S_IDLE: begin
        if (instruction_if.valid && instruction_if.ready) begin
          if (first_word_count != 2'd0) begin
            capture_first_fire = 1'b1;
            words_expected_d   = first_word_count;
            words_captured_d   = 2'd1;
            state_d            = (first_word_count == 2'd1) ? S_WAIT_ISSUE : S_COLLECT;
          end
        end
      end

      S_COLLECT: begin
        if (instruction_if.valid && instruction_if.ready) begin
          capture_next_fire = 1'b1;

          if ((words_captured_q + 2'd1) >= words_expected_q) begin
            words_captured_d = words_expected_q;
            state_d          = S_WAIT_ISSUE;
          end else begin
            words_captured_d = words_captured_q + 2'd1;
          end
        end
      end

      S_WAIT_ISSUE: begin
        if (!cmd_supported) begin
          state_d          = S_IDLE;
          words_expected_d = '0;
          words_captured_d = '0;
        end else if (gemm_fsm_if.flag.idle) begin
          out_cmd_d   = decoded_cmd;
          out_start_d = 1'b1;
          state_d     = S_IDLE;
          words_expected_d = '0;
          words_captured_d = '0;
        end else begin
          out_cmd_d = decoded_cmd;
        end
      end

      default: begin
        state_d = S_IDLE;
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      state_q    <= S_IDLE;
      inst0_q    <= '0;
      inst1_q    <= '0;
      inst2_q    <= '0;
      entry_id_q <= '0;
      words_expected_q <= '0;
      words_captured_q <= '0;
    end else begin
      state_q          <= state_d;
      words_expected_q <= words_expected_d;
      words_captured_q <= words_captured_d;

      if (capture_first_fire) begin
        inst0_q    <= instruction_if.inst;
        inst1_q    <= '0;
        inst2_q    <= '0;
        entry_id_q <= '0;
      end else if (capture_next_fire) begin
        unique case (words_captured_q)
          2'd1: inst1_q <= instruction_if.inst;
          2'd2: inst2_q <= instruction_if.inst;
          default: ;
        endcase
      end
    end
  end

`ifdef DBG_TRACE_CMD_CONSTRUCTOR
  function automatic string raw_op_to_str(input logic [3:0] op);
    begin
      unique case (op)
        RAW_OP_DMA_LOAD:         raw_op_to_str = "DMA_LOAD";
        RAW_OP_DMA_STORE:        raw_op_to_str = "DMA_STORE";
        RAW_OP_NOTIFY:           raw_op_to_str = "NOTIFY";
        RAW_OP_WAIT:             raw_op_to_str = "WAIT";
        RAW_OP_MXU_LOAD_WEIGHT:  raw_op_to_str = "MXU_LOAD_WEIGHT";
        RAW_OP_MXU_LOAD_QPARAM:  raw_op_to_str = "MXU_LOAD_QPARAM";
        RAW_OP_MXU_LOAD_INPUT:   raw_op_to_str = "MXU_LOAD_INPUT";
        RAW_OP_MXU_STORE_OUTPUT: raw_op_to_str = "MXU_STORE_OUTPUT";
        RAW_OP_CLEAR:            raw_op_to_str = "CLEAR";
        default:                 raw_op_to_str = "UNKNOWN";
      endcase
    end
  endfunction

  function automatic string state_to_str(input state_t s);
    begin
      unique case (s)
        S_IDLE:       state_to_str = "IDLE";
        S_COLLECT:    state_to_str = "COLLECT";
        S_WAIT_ISSUE: state_to_str = "WAIT_ISSUE";
        default:      state_to_str = "UNKNOWN";
      endcase
    end
  endfunction

  always_ff @(posedge clk) begin
    if (!reset) begin
      // Log instruction capture (first word)
      if (capture_first_fire) begin
        `TRACE(2, ("%m : [%0t] | CMD_CTOR_CAPTURE_FIRST | {inst=%s, op=%s, words_expected=%0d, inst0=0x%0h}\n",
                   $time, INSTANCE_ID, raw_op_to_str(instruction_if.inst[3:0]),
                   first_word_count, instruction_if.inst))
      end

      // Log subsequent word captures
      if (capture_next_fire) begin
        `TRACE(3, ("%m : [%0t] | CMD_CTOR_CAPTURE_NEXT | {inst=%s, word_idx=%0d, data=0x%0h}\n",
                   $time, INSTANCE_ID, words_captured_q, instruction_if.inst))
      end

      // Log state transitions
      if (state_q != state_d) begin
        `TRACE(3, ("%m : [%0t] | CMD_CTOR_STATE | {inst=%s, from=%s, to=%s}\n",
                   $time, INSTANCE_ID, state_to_str(state_q), state_to_str(state_d)))
      end

      // Log command issued to FSM
      if (out_start_d) begin
        `TRACE(2, ("%m : [%0t] | CMD_CTOR_ISSUE | {inst=%s, op=%s, instr=0x%0h, rs1=0x%0h, rs2=0x%0h, stride=0x%0h, bound=%0d, flags=0x%0h}\n",
                   $time, INSTANCE_ID, raw_op_to_str(out_cmd_d.instr[3:0]),
                   out_cmd_d.instr, out_cmd_d.rs1_data, out_cmd_d.rs2_data,
                   out_cmd_d.stride, out_cmd_d.bound, out_cmd_d.flags))
      end

      // Log unsupported command skip
      if ((state_q == S_WAIT_ISSUE) && !cmd_supported && !cmd_is_clear) begin
        `TRACE(2, ("%m : [%0t] | CMD_CTOR_SKIP_UNSUPPORTED | {inst=%s, raw_op=0x%0h}\n",
                   $time, INSTANCE_ID, inst0_q[3:0]))
      end

    end
  end
`endif

endmodule

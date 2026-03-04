module VX_stream_slave import VX_mem_pkg::*; #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned FIFO_DEPTH = 8,
    parameter int unsigned ALWAYS_READY = 0,
    parameter int unsigned WORD_SIZE = DATA_WIDTH
) (
    input logic clk_i,
    input logic rst_ni,
    input logic clear_i,

    output flags_fifo_t flags_o,

    VX_stream_intf.sink   push_i,
    VX_stream_intf.source pop_o
);

  // Local Parameter
  localparam FIFO_DEPTH_ = (ALWAYS_READY) ? 2**15 : FIFO_DEPTH;
  localparam ADDR_DEPTH = (FIFO_DEPTH_ == 1) ? 1 : $clog2(FIFO_DEPTH_);

  enum logic [1:0] {
    EMPTY,
    FULL,
    MIDDLE
  } cs, ns;
  // Internal Signals

  logic [ADDR_DEPTH-1:0] pop_pointer_q, pop_pointer_d;
  logic [ADDR_DEPTH-1:0] push_pointer_q, push_pointer_d;
  logic [DATA_WIDTH+(DATA_WIDTH+7)/8-1:0] fifo_registers[FIFO_DEPTH_-1:0];
  logic [DATA_WIDTH+(DATA_WIDTH+7)/8-1:0] stack[$];
  integer i;

  logic random_mask;

  assign flags_o.empty = (cs == EMPTY) ? 1'b1 : 1'b0;

  // state update
  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) begin
      cs             <= EMPTY;
      pop_pointer_q  <= {ADDR_DEPTH{1'b0}};
      push_pointer_q <= {ADDR_DEPTH{1'b0}};
    end else if (clear_i == 1'b1) begin
      cs             <= EMPTY;
      pop_pointer_q  <= {ADDR_DEPTH{1'b0}};
      push_pointer_q <= {ADDR_DEPTH{1'b0}};
    end else begin
      cs             <= ns;
      pop_pointer_q  <= pop_pointer_d;
      push_pointer_q <= push_pointer_d;
    end
  end

  always_ff@(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) begin
      random_mask <= 1'b0;
    end else begin
      if(ALWAYS_READY == 0) begin
        random_mask <= ($urandom_range(0, 10) < 8) ? 0 : 1;
      end else begin
        random_mask <= 1;
      end
    end
  end

  // drive ready/valid (a separte always_comb is necessary for Verilator)
  always_comb begin
    push_i.ready = 1'b0;
    pop_o.valid  = 1'b0;
    case (cs)
      EMPTY: begin
        push_i.ready = 1'b1 & random_mask;
        pop_o.valid  = 1'b0;
      end
      MIDDLE: begin
        push_i.ready = 1'b1 & random_mask;
        pop_o.valid  = 1'b1;
      end
      FULL: begin
        push_i.ready = 1'b0;
        pop_o.valid  = 1'b1;
      end
      default: begin
        push_i.ready = 1'b0;
        pop_o.valid  = 1'b0;
      end
    endcase
  end

  // Compute Next State
  always_comb begin
    if(random_mask) begin
      case (cs)
        EMPTY: begin
          case (push_i.valid)
            1'b0: begin
              ns = EMPTY;
              push_pointer_d = push_pointer_q;
              pop_pointer_d = pop_pointer_q;
            end
            1'b1: begin
              ns = MIDDLE;
              push_pointer_d = push_pointer_q + 1'b1;
              pop_pointer_d = pop_pointer_q;
            end
          endcase
        end
        MIDDLE: begin
          case ({
            push_i.valid, pop_o.ready
          })
            2'b01: begin
              if((pop_pointer_q == push_pointer_q -1 ) || ((pop_pointer_q == FIFO_DEPTH_-1) && (push_pointer_q == 0) ))
                ns = EMPTY;
              else ns = MIDDLE;
              push_pointer_d = push_pointer_q;
              if (pop_pointer_q == FIFO_DEPTH_ - 1) pop_pointer_d = 0;
              else pop_pointer_d = pop_pointer_q + 1'b1;
            end
            2'b00: begin
              ns = MIDDLE;
              push_pointer_d = push_pointer_q;
              pop_pointer_d = pop_pointer_q;
            end
            2'b11: begin
              ns = MIDDLE;
              if (push_pointer_q == FIFO_DEPTH_ - 1) push_pointer_d = 0;
              else push_pointer_d = push_pointer_q + 1'b1;

              if (pop_pointer_q == FIFO_DEPTH_ - 1) pop_pointer_d = 0;
              else pop_pointer_d = pop_pointer_q + 1'b1;
            end
            2'b10: begin
              if(( push_pointer_q == pop_pointer_q - 1) || ( (push_pointer_q == FIFO_DEPTH_-1) && (pop_pointer_q == 0) ))
                ns = FULL;
              else ns = MIDDLE;
              if (push_pointer_q == FIFO_DEPTH_ - 1) push_pointer_d = 0;
              else push_pointer_d = push_pointer_q + 1'b1;
              pop_pointer_d = pop_pointer_q;
            end
          endcase
        end
        FULL: begin
          case (pop_o.ready)
            1'b1: begin
              ns = MIDDLE;
              push_pointer_d = push_pointer_q;
              if (pop_pointer_q == FIFO_DEPTH_ - 1) pop_pointer_d = 0;
              else pop_pointer_d = pop_pointer_q + 1'b1;
            end
            1'b0: begin
              ns = FULL;
              push_pointer_d = push_pointer_q;
              pop_pointer_d = pop_pointer_q;
            end
          endcase
        end
        default: begin
          ns = EMPTY;
          pop_pointer_d = 0;
          push_pointer_d = 0;
        end
      endcase
    end else begin
      case (cs)
        EMPTY: begin
          pop_pointer_d = pop_pointer_q;
          push_pointer_d = push_pointer_q;
          ns=EMPTY;
        end
        MIDDLE: begin
          if(pop_o.ready) begin
            if((pop_pointer_q == push_pointer_q -1 ) || ((pop_pointer_q == FIFO_DEPTH_-1) && (push_pointer_q == 0) ))
              ns = EMPTY;
            else ns = MIDDLE;
            push_pointer_d = push_pointer_q;
            if (pop_pointer_q == FIFO_DEPTH_ - 1) pop_pointer_d = 0;
            else pop_pointer_d = pop_pointer_q + 1'b1;
          end else begin
            ns = MIDDLE;
            push_pointer_d = push_pointer_q;
            pop_pointer_d = pop_pointer_q;
          end
        end
        FULL: begin
          case (pop_o.ready)
            1'b1: begin
              ns = MIDDLE;
              push_pointer_d = push_pointer_q;
              if (pop_pointer_q == FIFO_DEPTH_ - 1) pop_pointer_d = 0;
              else pop_pointer_d = pop_pointer_q + 1'b1;
            end
            1'b0: begin
              ns = FULL;
              push_pointer_d = push_pointer_q;
              pop_pointer_d = pop_pointer_q;
            end
          endcase
        end
        default: begin
          ns = EMPTY;
          pop_pointer_d = 0;
          push_pointer_d = 0;
        end
      endcase
    end
  end

  logic [DATA_WIDTH+(DATA_WIDTH+7)/8-1:0] data_out_int;
  // logic [DATA_WIDTH+DATA_WIDTH/8-1:0] data_in_int;

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) begin
      for (i = 0; i < FIFO_DEPTH_; i++) fifo_registers[i] <= '0;
    end else if (clear_i == 1'b1) begin
      for (i = 0; i < FIFO_DEPTH_; i++) fifo_registers[i] <= '0;
    end else begin
      if ((push_i.ready == 1'b1) && (push_i.valid == 1'b1)) begin
        fifo_registers[push_pointer_q] <= {push_i.data, push_i.strb};
        stack.push_back({push_i.data, push_i.strb});
        if(stack.size()>9999) begin
          $display("Warning: stack size exceeds 9999, data may be lost");
          stack.pop_front();
        end
      end
    end
  end

  assign data_out_int = fifo_registers[pop_pointer_q];
  assign pop_o.data = (pop_o.valid == 1'b1) ? data_out_int[DATA_WIDTH+(DATA_WIDTH+7)/8-1:(DATA_WIDTH+7)/8] : '0;
  assign pop_o.strb = (pop_o.valid == 1'b1) ? data_out_int[(DATA_WIDTH+7)/8-1:0] : '0;

`ifdef FUNCTIONAL
  int fd;

  initial begin
    fd = $fopen($sformatf("./logs/%m.log"), "w");
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) begin
    end else if (clear_i == 1'b1) begin
    end else begin
      if ((push_i.ready == 1'b1) && (push_i.valid == 1'b1))
        $fdisplay(fd, "[%0t] push_pointer_q:%d | data : %s", $time, push_pointer_q, VX_utils_pkg::parseWordNoNormal(push_i.data, DATA_WIDTH, WORD_SIZE, "int"));
    end
  end

  always_ff @(posedge clk_i, negedge rst_ni) begin
    if (rst_ni == 1'b0) begin
    end else if (clear_i == 1'b1) begin
    end else begin
      if ((pop_o.ready == 1'b1) && (pop_o.valid == 1'b1))
        $fdisplay(fd, "[%0t] pop_pointer_q:%d | data : %s", $time, pop_pointer_q, VX_utils_pkg::parseWordNoNormal(pop_o.data, DATA_WIDTH, WORD_SIZE, "int"));
    end
  end

  function automatic int size();
    int ret;
    // ret = (cs == FULL) ? FIFO_DEPTH_ : push_pointer_q;
    ret = push_pointer_q-pop_pointer_q;
    if(ret<0) ret = ret + FIFO_DEPTH_;
    return ret;
  endfunction

  function automatic int size_of_stack();
    int ret;
    ret = stack.size();
    return ret;
  endfunction

  function automatic logic[DATA_WIDTH-1:0] get_data(int index);
    logic[DATA_WIDTH-1:0] ret;
    ret = fifo_registers[index][(DATA_WIDTH+7)/8 +: DATA_WIDTH];
    // logic [DATA_WIDTH+(DATA_WIDTH+7)/8-1:0] fifo_registers[FIFO_DEPTH_-1:0];
    return ret;
  endfunction

  function automatic logic[(DATA_WIDTH+7)/8-1:0] get_strb(int index);
    logic[(DATA_WIDTH+7)/8-1:0] ret;
    ret = fifo_registers[index][0 +: (DATA_WIDTH+7)/8];
    return ret;
  endfunction

  function automatic logic[DATA_WIDTH-1:0] get_data_from_stack(int index);
    logic[DATA_WIDTH-1:0] ret;
    if(index < stack.size()) begin
      ret = stack[index][(DATA_WIDTH+7)/8 +: DATA_WIDTH];
    end else begin
      $fdisplay(fd, "[%0t] Error: index %d is out of range for stack size %d", $time, index, stack.size());
      ret = '0;
    end
    return ret;
  endfunction

  function automatic logic[(DATA_WIDTH+7)/8-1:0] get_strb_from_stack(int index);
    logic[(DATA_WIDTH+7)/8-1:0] ret;
    if(index < stack.size()) begin
      ret = stack[index][0 +: (DATA_WIDTH+7)/8];
    end else begin
      $fdisplay(fd, "[%0t] Error: index %d is out of range for stack size %d", $time, index, stack.size());
      ret = '0;
    end
    return ret;
  endfunction

`endif

endmodule

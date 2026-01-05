/*
  VX_lmem_dma.sv

  DMA Engine for LMEM <-> GEMM Unit data transfer
  Parameterized by direction (read/write), LMEM data width, GEMM data width

  Usage:
    - DIR = 0: LMEM -> GEMM (read from LMEM)
    - DIR = 1: GEMM -> LMEM (write to LMEM)
*/

`include "VX_define.vh"

module VX_lmem_dma import VX_gpu_pkg::*; #(
  parameter `STRING INSTANCE_ID = "",
  parameter DIR      = 0,        // 0: LMEM->GEMM (read), 1: GEMM->LMEM (write)
  parameter LMEM_DW  = 32,       // LMEM data width in bits
  parameter GEMM_DW  = 32,       // GEMM data width in bits
  parameter NDIM     = 3         // Number of dimensions for nested loop
) (
  input wire clk,
  input wire reset,

  // Control interface
  VX_lmem_dma_ctrl_if.slave ctrl_if,

  // LMEM memory bus interface
  VX_mem_bus_if.master lmem_bus_if,

  // GEMM data interface
  output wire                    gemm_data_valid,
  output wire [GEMM_DW-1:0]      gemm_data_out,
  input  wire                    gemm_data_ready,
  input  wire                    gemm_data_valid_in,
  input  wire [GEMM_DW-1:0]      gemm_data_in,
  output wire                    gemm_data_ready_out
);

  // FSM states
  typedef enum logic [2:0] {
    STATE_IDLE,
    STATE_CALC_ADDR,
    STATE_REQ,
    STATE_WAIT_RSP,
    STATE_NEXT_SEG,
    STATE_NEXT_DIM,
    STATE_DONE
  } state_t;

  state_t state, state_next;

  // Loop counters
  logic [31:0] dim_counters [NDIM];
  logic [31:0] seg_counter;

  // Address registers
  logic [31:0] src_addr;
  logic [31:0] dst_addr;

  // Done pulse register
  logic done_r;

  // State machine
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      state <= STATE_IDLE;
    end else begin
      state <= state_next;
    end
  end

  // Next state logic
  always_comb begin
    state_next = state;
    case (state)
      STATE_IDLE: begin
        if (ctrl_if.start) begin
          state_next = STATE_CALC_ADDR;
        end
      end
      STATE_CALC_ADDR: begin
        state_next = STATE_REQ;
      end
      STATE_REQ: begin
        if (lmem_bus_if.req_valid && lmem_bus_if.req_ready) begin
          if (DIR == 0) begin
            // Read: wait for response
            state_next = STATE_WAIT_RSP;
          end else begin
            // Write: move to next segment
            state_next = STATE_NEXT_SEG;
          end
        end
      end
      STATE_WAIT_RSP: begin
        if (lmem_bus_if.rsp_valid && lmem_bus_if.rsp_ready) begin
          state_next = STATE_NEXT_SEG;
        end
      end
      STATE_NEXT_SEG: begin
        if (seg_counter >= ctrl_if.seg_size - 1) begin
          state_next = STATE_NEXT_DIM;
        end else begin
          state_next = STATE_REQ;
        end
      end
      STATE_NEXT_DIM: begin
        if (dim_counters[NDIM-1] >= ctrl_if.bounds[NDIM-1] - 1) begin
          state_next = STATE_DONE;
        end else begin
          state_next = STATE_CALC_ADDR;
        end
      end
      STATE_DONE: begin
        state_next = STATE_IDLE;
      end
      default: state_next = STATE_IDLE;
    endcase
  end

  // Loop counter management
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      for (int i = 0; i < NDIM; i++) begin
        dim_counters[i] <= '0;
      end
      seg_counter <= '0;
    end else begin
      case (state)
        STATE_IDLE: begin
          if (ctrl_if.start) begin
            for (int i = 0; i < NDIM; i++) begin
              dim_counters[i] <= '0;
            end
            seg_counter <= '0;
          end
        end
        STATE_NEXT_SEG: begin
          if (seg_counter >= ctrl_if.seg_size - 1) begin
            seg_counter <= '0;
          end else begin
            seg_counter <= seg_counter + 1;
          end
        end
        STATE_NEXT_DIM: begin
          // Increment dimension counters (nested loop style)
          for (int i = 0; i < NDIM; i++) begin
            if (i == 0) begin
              if (dim_counters[0] >= ctrl_if.bounds[0] - 1) begin
                dim_counters[0] <= '0;
              end else begin
                dim_counters[0] <= dim_counters[0] + 1;
              end
            end else begin
              // Only increment if all lower dimensions wrapped
              if (dim_counters[i-1] >= ctrl_if.bounds[i-1] - 1) begin
                if (dim_counters[i] >= ctrl_if.bounds[i] - 1) begin
                  dim_counters[i] <= '0;
                end else begin
                  dim_counters[i] <= dim_counters[i] + 1;
                end
              end
            end
          end
        end
        default: ;
      endcase
    end
  end

  // Address calculation
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      src_addr <= '0;
      dst_addr <= '0;
    end else if (state == STATE_IDLE && ctrl_if.start) begin
      src_addr <= ctrl_if.src_base_addr;
      dst_addr <= ctrl_if.dst_base_addr;
    end else if (state == STATE_CALC_ADDR) begin
      // Calculate addresses based on dimension counters
      src_addr <= ctrl_if.src_base_addr;
      dst_addr <= ctrl_if.dst_base_addr;
      for (int i = 0; i < NDIM; i++) begin
        src_addr <= src_addr + dim_counters[i] * ctrl_if.src_strides[i];
        dst_addr <= dst_addr + dim_counters[i] * ctrl_if.dst_strides[i];
      end
    end else if (state == STATE_NEXT_SEG && seg_counter < ctrl_if.seg_size - 1) begin
      // Advance by element size for next segment element
      if (DIR == 0) begin
        src_addr <= src_addr + (LMEM_DW / 8);
      end else begin
        dst_addr <= dst_addr + (LMEM_DW / 8);
      end
    end
  end

  // Done pulse generation
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      done_r <= 1'b0;
    end else begin
      done_r <= (state == STATE_DONE);
    end
  end

  // Output assignments
  assign ctrl_if.idle = (state == STATE_IDLE);
  assign ctrl_if.done = done_r;

  // LMEM bus interface
  generate
    if (DIR == 0) begin : gen_read
      // Read from LMEM -> GEMM
      assign lmem_bus_if.req_valid = (state == STATE_REQ);
      assign lmem_bus_if.req_data.rw = 1'b0;  // Read
      assign lmem_bus_if.req_data.addr = src_addr[`MEM_ADDR_WIDTH-1:0];
      assign lmem_bus_if.req_data.data = '0;
      assign lmem_bus_if.req_data.byteen = '1;
      assign lmem_bus_if.req_data.tag = '0;
      assign lmem_bus_if.req_data.flags = '0;
      assign lmem_bus_if.rsp_ready = gemm_data_ready;

      // GEMM data output
      assign gemm_data_valid = lmem_bus_if.rsp_valid;
      assign gemm_data_out = lmem_bus_if.rsp_data.data[GEMM_DW-1:0];
      assign gemm_data_ready_out = 1'b1;  // Always ready to accept (not used in read mode)
    end else begin : gen_write
      // Write from GEMM -> LMEM
      assign lmem_bus_if.req_valid = (state == STATE_REQ) && gemm_data_valid_in;
      assign lmem_bus_if.req_data.rw = 1'b1;  // Write
      assign lmem_bus_if.req_data.addr = dst_addr[`MEM_ADDR_WIDTH-1:0];
      assign lmem_bus_if.req_data.data = {{(LMEM_DW-GEMM_DW){1'b0}}, gemm_data_in};
      assign lmem_bus_if.req_data.byteen = '1;
      assign lmem_bus_if.req_data.tag = '0;
      assign lmem_bus_if.req_data.flags = '0;
      assign lmem_bus_if.rsp_ready = 1'b1;  // Always accept write responses

      // GEMM data interface (write mode)
      assign gemm_data_valid = 1'b0;  // Not used in write mode
      assign gemm_data_out = '0;
      assign gemm_data_ready_out = (state == STATE_REQ) && lmem_bus_if.req_ready;
    end
  endgenerate

endmodule

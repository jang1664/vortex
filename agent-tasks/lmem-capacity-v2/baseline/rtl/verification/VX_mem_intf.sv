/*
 * hwpe_stream_interfaces.sv
 * Francesco Conti <f.conti@unibo.it>
 *
 * Copyright (C) 2014-2018 ETH Zurich, University of Bologna
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

`ifndef HWPE_ASSERT_SEVERITY
`define HWPE_ASSERT_SEVERITY $warning
`endif

interface VX_mem_intf #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter TAG_WIDTH  = 8,
    parameter bit RVALID_ASSERT = 1'b1,
    parameter bit REQ_HOLD_ASSERT = 1'b1,
    parameter bit RDATA_HOLD_ASSERT = 1'b1
) (
    input logic clk
);
`ifndef SYNTHESIS
  // the TRVR assert is disabled by default, as it is only valid for zero-latency
  // accesses (e.g. using FIFO queues breaks this assumption)
  parameter bit BYPASS_TRVR_ASSERT = 1'b0;
`endif

  logic                      req;
  logic                      gnt;
  logic [    ADDR_WIDTH-1:0] addr;
  logic                      wen;
  logic [(DATA_WIDTH/8)-1:0] be;
  logic [    DATA_WIDTH-1:0] data;
  logic [    TAG_WIDTH-1:0]  wtag;

  logic [    DATA_WIDTH-1:0] r_data;
  logic [    TAG_WIDTH-1:0]  rtag;
  logic                      r_valid;
  logic                      r_ready;

  modport master(output req, addr, wen, be, data, r_ready, wtag, input gnt, r_data, r_valid, rtag);
  modport slave(input req, addr, wen, be, data, r_ready, output gnt, r_data, r_valid, rtag);
  modport monitor(input req, addr, wen, be, data, gnt, r_data, r_valid, r_ready, rtag, wtag);

`ifndef SYNTHESIS
`ifndef VERILATOR

  generate 
    if(RVALID_ASSERT) begin : gen_rvalid_assert
    // The r_valid signal must be asserted the cycle after a valid read handshake;
    // r_data must be valid on this cycle. This is due to the tightly-coupled
    // memories; if the memory cannot respond in one cycle, it must delay
    // granting the transaction.
      property hwpe_r_valid_rule;
        @(posedge clk) ($past(
            req
        ) & $past(
            gnt
        ) & $past(
            ~wen
        )) |-> (r_valid) | BYPASS_TRVR_ASSERT;
      endproperty

      HWPE_R_VALID :
      assert property (hwpe_r_valid_rule)
      else
        `HWPE_ASSERT_SEVERITY("ASSERTION FAILURE HWPE_R_VALID", 1);
    end

    if(REQ_HOLD_ASSERT) begin
      property MEM_INTF_REQ_HOLD;
        @(posedge clk)
          // on any cycle where we still haven’t seen the req&gnt handshake…
          (req && ~gnt) |=> 
            // …the three signals must equal their last‐cycle values
            (data == $past(data) && be == $past(be) && wen == $past(wen));
      endproperty
      assert property (MEM_INTF_REQ_HOLD)
        else `HWPE_ASSERT_SEVERITY("ASSERTION FAILURE: MEM_INTF_REQ_HOLD", 1);
    end

    if(RDATA_HOLD_ASSERT) begin
      property MEM_INTF_RDATA_HOLD;
        @(posedge clk)
          (r_valid && ~r_ready) |=> 
            // r_data must equal its last‐cycle value
            (r_data == $past(r_data));
      endproperty
      assert property (MEM_INTF_RDATA_HOLD)
        else `HWPE_ASSERT_SEVERITY("ASSERTION FAILURE: MEM_INTF_RDATA_HOLD", 1);
    end
  endgenerate

`endif
`endif

endinterface  // hwpe_stream_intf_tcdm
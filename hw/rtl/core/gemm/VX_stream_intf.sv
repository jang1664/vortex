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

interface VX_stream_intf (
    input logic clk
);
  parameter int unsigned DATA_WIDTH = 32;  // used to default to -1 and always overridden --> not well supported by some tools
  parameter int unsigned STRB_WIDTH = (DATA_WIDTH+7) / 8;
`ifndef SYNTHESIS
  parameter bit BYPASS_VCR_ASSERT = 1'b0;
  parameter bit BYPASS_VDR_ASSERT = 1'b0;
`endif

  logic                  valid;
  logic                  ready;
  logic [DATA_WIDTH-1:0] data;
  logic [STRB_WIDTH-1:0] strb;

  modport source(output valid, data, strb, input ready);
  modport sink(input valid, data, strb, output ready);
  modport monitor(input valid, data, strb, ready);

`ifndef SYNTHESIS
`ifndef VERILATOR
  // The data and strb can change their value 1) when valid is deasserted,
  // 2) in the cycle after a valid handshake, even if valid remains asserted.
  // In other words, valid data must remain on the interface until
  // a valid handshake has occurred.
  property hwpe_stream_value_change_rule;
    @(posedge clk) ($past(
        valid
    ) & ~($past(
        valid
    ) & $past(
        ready
    ))) |-> ((data == $past(
        data
    )) && (strb == $past(
        strb
    ))) | BYPASS_VCR_ASSERT;
  endproperty
  ;

  // The deassertion of valid (transition 1->0) can happen only in the cycle
  // after a valid handshake. In other words, valid data produced by a source
  // must be consumed on the sink side before valid is deasserted.
  property hwpe_stream_valid_deassert_rule;
    @(posedge clk) ($past(
        valid
    ) & ~valid) |-> ($past(
        valid
    ) & $past(
        ready
    )) | BYPASS_VDR_ASSERT;
  endproperty
  ;

  HWPE_STREAM_VALUE_CHANGE :
  assert property (hwpe_stream_value_change_rule)
  else
    `HWPE_ASSERT_SEVERITY("ASSERTION FAILURE: HWPE_STREAM_VALUE_CHANGE", 1);

  HWPE_STREAM_VALID_DEASSERT :
  assert property (hwpe_stream_valid_deassert_rule)
  else
    `HWPE_ASSERT_SEVERITY("ASSERTION FAILURE HWPE_STREAM_VALID_DEASSERT", 1);
`endif
`endif

endinterface  // hwpe_stream_intf_stream
# VX_gemm_unit_v2

`VX_gemm_unit_v2` is the fixed-latency GEMM datapath used by the
`GEMM_IMPROVE` node. It is a separate implementation from
`VX_gemm_unit.sv`; the legacy unit and interface remain available for the
naive node and its unit tests.

## Packet interface

Every accepted input beat carries a `gemm_input_ctrl_t` sideband through
`VX_gemm_unit_v2_if`. The sideband contains the accumulator read/write
enables and byte addresses, quantization direction, weight/scale/zero
register selectors, load/accumulate mode, and final-packet marker.

The input request channel is non-blocking: `i_lmem_bus_if.req_ready` is tied
high. A valid request is therefore committed to the fixed pipeline and must
produce its enabled accumulator write after the configured latency. The unit
does not contain a command FSM, input FIFO, credit counter, or round-robin
scheduler. Command lifetime and address generation belong to
`VX_gemm_node`.

`last_write` pulses on the actual accumulator write of a packet marked
`last`. `pipeline_empty` is asserted only after all packet sidebands and any
early-read response held inside the unit have drained. Output-memory reads
are accepted only while the compute pipeline is empty.

## Fixed-latency alignment

For the supported `MXU_COL_TILE=32` configuration, the control convention
and derived latency values are:

| Item | Cycles |
| --- | ---: |
| Pre-accumulator datapath (`L_PRE`) | 15 |
| ACC SRAM read (`L_R`) | 1 |
| Accumulator add (`L_A`) | 1 |
| Post-accumulator path (`L_P`) | 0 |
| Write latency (`WRITE_DLY`) | 16 |
| Conflict lookback (`K`) | 2 |
| Nominal read-request delay | 14 |
| Early read-request delay | 13 |

`ctrl_pipe[0]` is aligned with the output of the one-cycle input register.
QCOL and QROW preprocessing use parallel paths so adjacent packets may
change quantization direction and register selectors without sharing
crossed mode-dependent state.

The FPU wrapper parameter is selected per backend to preserve this same
one-cycle contract. FPnew uses `LATENCY=0` because its mandatory input buffer
already supplies the cycle. DPI and the latency-1 Xilinx IP path use
`LATENCY=1`. This rule is applied consistently to the FP16 input/output
multipliers, FP32 output multiplier, and FP32 accumulator adder. A DPI
`LATENCY=0` setting would be combinational and would make data valid arrive
one cycle before `ctrl_pipe`, dropping the final ACC write.

## Accumulator scheduling

The accumulator consists of four physical single-port SRAM banks. The
external byte address selects the physical bank and the per-bank depth.
For an accumulating packet, the unit compares its target bank with the
write-side packet admitted exactly

```text
K = L_A + L_P + L_R
```

cycles earlier. A matching valid write makes the packet issue its read one
cycle before the nominal request cycle. Otherwise it issues at the nominal
cycle. The early response is stored in a one-entry hold register for that
bank and consumed at the accumulator input. Strict sequential ping-pong
addresses guarantee that moving the request by one cycle cannot create a
second same-bank conflict.

Two adjacent accumulation packets may target the same PSUM address. In this
case, the second packet suppresses its SRAM read and forwards the first
packet's aligned writeback result directly into the accumulator input. The
forward-dependency bit travels with the packet sideband, so the input remains
always-ready and the write latency stays fixed. Elaboration asserts that the
previous packet's writeback stage is exactly one cycle ahead of the dependent
packet's accumulator-input stage.

Simulation assertions check always-ready behavior, control/data alignment,
single-port read/write exclusion, early-response availability, forwarding
source validity/address equality, and legal sequential or immediate
same-address dependencies within a command stream. Load packets are checked
at the scaler stage as well as accumulation packets, so a backend latency
mismatch fails at its first packet instead of appearing as a later command
completion hang.

## Verification scope

The dedicated unittest is `hw/unittest/gemm_unit_v2`. It covers continuous
input traffic, load and accumulate paths, nominal and one-cycle-early reads,
bubbles, physical bank-group boundaries, immediate same-address forwarding,
alternating QCOL/QROW modes and register selectors, reset draining, and
non-zero arithmetic reference cases. The forwarding test sends two adjacent
accumulation packets to one PSUM initialized to 1.0, checks the final FP32
value 65.0, and requires one SRAM read, one forwarded consume, and two writes.
An admission-based scoreboard independently checks the exact write/read cycle,
bank, address, enable, completion marker, and ordering of every packet. A
fixed-seed constrained-random stream also covers bubbles, disabled writes,
mode/register changes, and physical bank-group crossings. Top-level simulation
was additionally verified with `fpint_gemm_ffn_hw` in `xrt-vcs-sim` for M1
K32/K64/K128, M32 K64/K128, WTRANS, and QROW cases. Synthesis remains outside
this change.

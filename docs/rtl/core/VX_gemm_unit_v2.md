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

Same-address accumulation dependencies use two fixed forwarding paths. At
admission distance `d=1`, the consumer suppresses its SRAM read and uses the
producer's concurrent writeback result. At `d=2`, the consumer suppresses both
the otherwise-conflicting early read and its nominal read, then uses the
producer result retained in a one-cycle writeback-history register. Immediate
forwarding has priority when both admission-history comparisons match, which
preserves a full-rate chain of three or more same-address packets. At `d=3`
or greater, the producer has already updated ACC SRAM before the consumer's
nominal read.

This contract is intentionally limited to `L_R=1`, `L_A=1`, and `L_P=0`.
Elaboration rejects a different accumulator timing instead of silently
generalizing the history window. Both forwarding dependency bits travel with
the packet sideband, so the input remains always-ready and every enabled write
keeps its fixed latency.

Simulation assertions check always-ready behavior, control/data alignment,
single-port read/write exclusion, early-response availability, both forwarding
sources' validity/address equality, and legal sequential or same-address
dependencies within a command stream. Load packets are checked at the scaler
stage as well as accumulation packets, so a backend latency mismatch fails at
its first packet instead of appearing as a later command completion hang.

## Verification scope

The dedicated unittest is `hw/unittest/gemm_unit_v2`. It covers continuous
input traffic, load and accumulate paths, nominal and one-cycle-early reads,
bubbles, physical bank-group boundaries, and non-zero arithmetic reference
cases. Directed same-address tests cover `d=1`, `d=2`, and `d=3` both within a
command and across a `last` boundary, plus a three-packet `d=1` chain. A
same-bank/different-address `d=2` case ensures exact-address history forwarding
does not replace the existing early-read scheduler. An M=2 seamless micro-K
case drives `row0(k0), row1(k0), row0(k1), row1(k1)` without bubbles, proving
that both rows use exact-address history forwarding at `d=2` even though the
other row writes in the intervening cycle. Each case checks the final FP32
value, read/forward/write counts, fixed write timing, address alignment, and
pipeline drain. An admission-based scoreboard independently checks the exact
write/read cycle, bank, address, enable, completion marker, forwarding source,
and ordering of every packet. A fixed-seed constrained-random stream also
covers bubbles, disabled writes, mode/register changes, and physical bank-group
crossings. Node, blackbox, and synthesis verification are outside this
forwarding-window change.

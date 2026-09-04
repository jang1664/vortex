# VX_gemm_unit_v2

`VX_gemm_unit_v2` is the fixed-latency compatibility wrapper used by the
`GEMM_IMPROVE` node. It is a separate implementation from
`VX_gemm_unit.sv`; the legacy unit and interface remain available only as
migration references and for their focused unit tests. The default NAIVE node
also instantiates the common core directly.

The production module is now a compatibility wrapper around two explicit
blocks. `VX_gemm_compute_core` owns the arithmetic pipeline, elastic
data/control movement, W/S/Z consumer gates, result FIFOs and credits,
forwarding history, and transaction retirement. It communicates accumulator
reads and writes only through `VX_gemm_acc_if` and has no local-memory,
tensor-memory, DMA, accumulator-bank-layout, or physical-SRAM ownership.
`VX_gemm_acc_internal` owns the fixed four-bank accumulator, early/nominal
physical read schedule, output-read endpoint, and bank-group fence. The wrapper
preserves the existing `VX_gemm_unit_v2` ports and fixed-cycle behavior. The
common core itself accepts variable ACC request, response, and write latency;
the internal adapter's ready/latency contract selects the original fast path.

## Packet interface

Every accepted input beat carries a `gemm_input_ctrl_t` sideband through
`VX_gemm_unit_v2_if`. The sideband contains the accumulator read/write
enables and byte addresses, quantization direction, weight/scale/zero
register selectors, load/accumulate mode, and final-packet marker.

The input request channel is admitted by `input_admission_ready`, which the
node derives from the writer-head command's exact W/S/Z load-completion and
ACC-free fences. A request enters the fixed pipeline only on
`req_valid && req_ready`; a stalled request must keep its data and writer-head
context stable. The unit does not contain a command FSM, input FIFO, credit
counter, or round-robin scheduler. Command lifetime, address generation, and
the ordered admission fence belong to `VX_gemm_node`.

Scale and zero-point register writes use independent 64-byte ingress ports.
Each port applies backpressure only when its selected register is live in the
input-admission snapshot cycle, so both writes may be accepted in the same
cycle after the old values have been captured. QROW scale, QROW zero point,
QCOL zero point, and QCOL scale use immutable snapshot paths ending at their
respective consumer stages; later register overwrites cannot affect admitted
packets. Separate
`scale_register_write` and `zero_point_register_write` pulses identify the
architectural write endpoints; `quant_register_write` remains their OR for
legacy observability.

The unit also reports per-command resource lifetime endpoints. Scale and
zero-point consume pulses occur when the final input packet captures its
qparams. Weight consume occurs when that packet reaches
`PREALIGN_CTRL_IDX`, where the GEMM tree performs its final weight read. The
weight write-ready mask scans only the current admission and control stages
through `PREALIGN_CTRL_IDX`, inclusive; stages after the GEMM-tree read no
longer keep the weight register busy.

Weight storage has four physical banks selected by a two-bit index. The FSM
allocates these banks circularly, while scale and zero-point storage remain
independent two-bank resources selected by their own one-bit indices. There is
no requirement that the W/S/Z indices in an input packet be equal.

When the only remaining user of a Weight bank is the final consumer at
`PREALIGN_CTRL_IDX`, the unit may capture the old Weight value and accept the
matching new-bank write on the same edge. This exception is rejected if an
incoming packet or any earlier pipeline stage still names that bank. The
upstream Weight executor independently enforces the command's exact consume
RID and target, covering the interval before an accepted packet becomes
visible in the unit's local busy scan.

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

The internal accumulator adapter consists of four physical single-port SRAM
banks. The
external byte address selects the physical bank and the per-bank depth.
For an accumulating packet, the common core reports the older dependent
address through `VX_gemm_acc_if`; the adapter compares its target bank with the
write-side packet admitted exactly

```text
K = L_A + L_P + L_R
```

cycles earlier. A matching valid write makes the adapter issue its read one
cycle before the nominal request cycle. Otherwise it issues at the nominal
cycle. The early response is stored in a one-entry hold register for that
bank and consumed at the accumulator input. Strict sequential ping-pong
addresses guarantee that moving the request by one cycle cannot create a
second same-bank conflict.

Accepted and retired transaction events, including a backend-independent
core-local packet tag, cross the same interface with opaque ACC addresses. The
packet tag increments on each input handshake and is distinct from `work_seq`,
which identifies a logical microtile and may repeat across in-flight packets.
These events let
the adapter retain physical bank-group ownership for
output-read exclusion without exposing the group bit or bank mapping to the
common core. The fixed adapter remains always-ready. The common core holds a
read request until acceptance, joins responses by tag in a four-entry ordered
post queue, and reserves a two-entry result queue before launching the no-ready
ACC add. Responses may arrive with variable latency or out of request order.
A write request keeps valid, tag, address, and data stable until its actual
handshake; only that handshake retires a writing transaction. Filling either
bounded queue stops converter-result pops and propagates through the existing
converter, merged-result, and tree credits.

Same-address accumulation dependencies use two common forwarding paths. At
admission distance `d=1`, the consumer suppresses its SRAM read and uses the
producer's concurrent writeback result. At `d=2`, the consumer suppresses both
the otherwise-conflicting early read and its nominal read, then uses the
producer result retained in a two-entry tagged writeback history. Pending
results are also searched before physical write acceptance, so backend write
backpressure cannot expose stale SRAM data. Immediate
forwarding has priority when both admission-history comparisons match, which
preserves a full-rate chain of three or more same-address packets. At `d=3`
or greater, the producer has already updated ACC SRAM before the consumer's
nominal read.

The arithmetic island remains intentionally limited to `L_A=1` and `L_P=0`;
its no-ready output is protected by explicit result credit. Physical read
latency is no longer part of that safety proof. `VX_gemm_acc_programmable`
provides a validation backend with non-uniform, reorderable responses and
request/write backpressure. It fences reads behind older accepted same-address
writers by transaction order, without treating the transaction's own
destination or a younger writer as a dependency.

## NAIVE backend integration

`VX_gemm_node_naive` uses the same compute core through
`VX_gemm_acc_lmem`. `VX_gemm_input_packetizer` converts each already-decoded
NAIVE compute command into one control record per actual Input handshake. The
packetizer treats the FSM's PSUM and final-output bases and strides as opaque
byte addresses, advances the row index only when the core accepts Input, and
holds the complete control record stable while Input is stalled.

The NAIVE node exposes exact W/S/Z load generations to the common consumer
gates. A generation becomes visible only after the final corresponding common
core register write, rather than when the source DMA finishes. Compute-command
completion is similarly based on the tagged last-result write followed by the
drain of every physical LMEM lane request. Thus the existing row-major address
equations, LMEM lane split/arbitration, pending-write ordering, and external
output DMA topology remain unchanged, while the former fixed PSUM response
startup delay is no longer a correctness condition.

Simulation assertions check valid-ready stability, tagged response matching,
bounded join/result credits, fire-only input state updates, control/data alignment,
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

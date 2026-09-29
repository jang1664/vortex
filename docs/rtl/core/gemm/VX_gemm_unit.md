# VX_gemm_unit: optional MXU SLR transport

`GEMM_SLR_PIPELINE` enables fixed-latency transport around the shared
`VX_gemm_tree_v1 u_mxu` instance. With the macro undefined, the original
connections and latency are retained. The supported geometry is
`MXU_ROW=MXU_COL=MXU_COL_TILE=32`; other SLR geometries fail a static assertion.
No external port, command format, DMA behavior, or accumulator backend changes.

## Datapath and timing

Activation data, block indices, valid, and weight bank selection travel through
an unconditional TX/RX register pair. Weight data, valid, write-bank selection,
and load direction travel through a separate pair with the same two-cycle
delay. A third pair returns MXU result data and valid. Payloads advance every
cycle; reset flushes valid bits. There is no handshake or combinational logic
between each TX Q and RX D; RX valid reset is mapped to a register reset pin.

`MXU_OUT_DLY` is the base tree delay plus the two input and two output cycles.
The zero-point correction and maximum-exponent delay use that total. The local
QROW block-index path remains one cycle and is preserved separately from the
input TX, because merging those equal registers would break the crossing.

The existing `WLOAD_AT_ONCE` buffer remains ahead of the weight transport, and
the existing `in_flight` bank interlock remains responsible for write exclusion.
Both weight writes and activation consumption move by the same two cycles.
Completion still follows actual accumulator writes, so bank ownership spans
the added flight time. No remote ownership feedback or metadata FIFO is added.

For the naive external-LMEM PSUM backend, SLR mode additionally reserves one
returned PSUM per accepted accumulate input. Two local counters track FIFO
pushes minus input reservations, with reservation parity initialized from the
command base address. Admission waits for the corresponding parity credit;
this guarantees that an input already in the unstalled datapath cannot outrun
its PSUM when memory responses stall. No FIFO enlargement or arbitration
change is needed. Inputs are admitted only on a load-command start or during
an active command, so a future accumulate row cannot bypass initialization.
With SLR disabled, the original occupancy-threshold admission is retained.

## Placement contract

The optional MXU floorplan uses these stable instance/register names:

| Location | Register group or hierarchy |
| --- | --- |
| SLR1 | `g_slr_mxu_input_tx.control_q`, `.data_q` |
| SLR2 | `g_slr_mxu_input_rx.control_q`, `.data_q` |
| SLR1 | `g_slr_mxu_weight_tx.payload_q` |
| SLR2 | `g_slr_mxu_weight_rx.payload_q` |
| SLR2 | `u_mxu`, `g_slr_mxu_output_tx.payload_q` |
| SLR1 | `g_slr_mxu_output_rx.payload_q` |
| SLR1 | `g_local_prealign_blk_idx.data_q` |

Input `payload_q` is a combinational alias of `control_q` and `data_q`, not an
additional register. Boundary FFs have `USER_SLL_REG` and `SHREG_EXTRACT=NO`;
selective `DONT_TOUCH` prevents local block-index merging, DSP absorption of
activation stages, and naive BRAM absorption of the weight TX. `u_mxu` retains
its hierarchy only in SLR mode. These attributes alone do not place the MXU;
physical constraints and post-place checks are required. DMA and other GEMM
logic are outside this placement contract, and SLR2 is not exclusively reserved.

For a hardware build, source the desired base configuration and append:

```bash
export CONFIGS="$CONFIGS -DGEMM_SLR_PIPELINE"
export GEMM_MXU_SLR_FLOORPLAN=1
```

`GEMM_MXU_SLR_FLOORPLAN` defaults to zero and requires the pipeline macro and
`TARGET=hw`. XRT records it in the link configuration fingerprint. Post-init
creates `pblock_mxu_slr1` and `pblock_mxu_slr2`; post-opt refreshes ownership.
Post-place checks actual SLRs and direct FF links even when
`CONGESTION_FAIL_FAST=0`. Link reports record fabric/Laguna mapping; Laguna
mapping is not mandatory. These hooks support XCU55C and fail on missing
groups or bypass connections instead of silently applying an empty pblock.

For RTL simulation, only append `-DGEMM_SLR_PIPELINE`; no floorplan option is
needed. To disable the RTL transport, leave the macro undefined (do not pass
`-DGEMM_SLR_PIPELINE=0`, because the RTL tests macro presence).

## Simulation observability

Existing `mxu_output` and `mxu_output_valid` signals remain the local returned
result. The added `mxu_output_raw` and `mxu_output_valid_raw` are the tree output
before return transport. `mxu_*_capture` signals are the transported tree inputs.
Simulation-only assertions check input/weight capture delay, selected bank and
weight version, full result latency, correction alignment, and exponent
alignment. Weight versions count accepted writes at launch and installation;
the version seen by each activation must be unchanged across transport.

Verify both macro states, both `WLOAD_AT_ONCE` states, both weight-load
directions, both quantization directions, bank alternation, bubbles,
consecutive inputs, and reset flushing. Kernel validation must cover naive
ACC ON/OFF and improve. Functional simulation does not establish actual SLR
placement, FF preservation after synthesis, or timing closure.

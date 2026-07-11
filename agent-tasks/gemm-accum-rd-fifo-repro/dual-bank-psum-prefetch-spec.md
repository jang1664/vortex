# Dual-Bank Accumulator Psum Prefetch

Status: confirmed for implementation

## Problem

The current accumulator read path uses one sequential address stream and one
FIFO. When the head read targets the same physical accumulator bank as a write,
the read is rejected even though the other bank in the active pair is idle.
Repeated write-valid bubbles can restore the conflicting parity and drain the
FIFO by one entry per occurrence.

## RTL Design

- Use two depth-4, non-fall-through FIFOs, indexed by bank offset within the
  active accumulator bank group.
- Split the command's sequential read stream into two bank-local streams. The
  stream containing the base address starts at the base; the other starts one
  psum entry later. Each accepted read advances its bank-local address by two
  psum entries.
- Track remaining reads and reserved FIFO capacity independently for each bank.
  A credit is consumed when a read is accepted and returned when that bank's
  FIFO entry is consumed.
- Permit one accumulator-memory read per cycle. During a write, only the
  opposite bank is eligible. Without a write, prefer the eligible bank with
  more free credit and use round-robin arbitration for ties.
- Tag each accepted read with its bank offset and route the synchronous RAM
  response directly to the corresponding FIFO. Remove the global response
  skid because accepted reads already reserve destination capacity.
- Consume FIFO banks in original address order, starting with the base bank and
  toggling for every psum consume attempt. Preserve the existing behavior that
  does not stall `acc_psum_data_valid` on FIFO empty.
- Keep the active physical bank group fixed for a command and assert that no
  accepted read conflicts with a simultaneous write.

## Verification

- Preserve the default FPNEW unittest path.
- Add an optional VCS Xilinx floating-point IP path selected by `FPU_XILINX_EN=1`.
  Share IP generation, compiled-library setup, and VHDL wrapper compilation
  with `sim/xrtsim_vcs` through a common make fragment.
- Run the hardware shape `M=256 N=256 K=1024 QBLK=32` and representative shape,
  quantization-direction, and deterministic input-stall sweeps.
- In strict dual-bank mode, require zero read/write conflicts, zero psum
  underflows, balanced accepted-response-push-pop counts per bank, and empty
  FIFOs at command completion, in addition to numerical output comparison.

## Non-Goals

- Do not add a final-output skid buffer.
- Do not change the deadlock-avoidance `acc_psum_data_valid` behavior.
- Do not rely on increased FIFO depth to compensate for lost read bandwidth.

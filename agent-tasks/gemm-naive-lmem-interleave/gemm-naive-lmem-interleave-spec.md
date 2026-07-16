# GEMM Naive LMEM Interleaving

Status: confirmed

## Goal

Remove artificial GEMM_NAIVE weight-path serialization while retaining the
shared Vortex local-memory architecture. Use four-row weight loads, distribute
each 64-byte tensor transfer over eight 64-bit LSU lanes, and wrap the tensor
lane ranges over the configured physical LSU lane count.

## Confirmed Configuration

Primary build and comparison configuration:
`configs/naive_gemm_simd_th16_tcol32_hwexp_dcache.sh`.

This configuration elaborates 16 LSU lanes and 16 LMEM banks. The tensor
mapping is:

```text
physical_lane = (tensor_offset + logical_lane) % NUM_LSU_LANES

I offset  = 0
W offset  = 8
SZ offset = 16
O offset  = 24
logical_lane = 0..7
```

For 16 lanes this maps I/SZ to lanes 0..7 and W/O to lanes 8..15.

## Design Decisions

- GEMM_NAIVE defaults to `MXU_WLOAD_NUM=4`, producing a 64-byte weight bus.
- Weight data remains in the existing row-major LMEM layout. A dedicated
  gather DMA reads four strided 16-byte rows through eight 64-bit lane ports
  and emits one ordered 64-byte GEMM request.
- The weight gather keeps up to `LMEM_DMA_RD_PREFETCH_DEPTH` groups in flight
  and retires them to the GEMM unit in issue order.
- Input, scale/zero, and output retain the existing 64-byte local DMA and
  `VX_mem_bus_split` paths.
- Tensor clients that wrap onto the same physical lane use round-robin
  arbitration. The shared LSU/CPU-DMA/GEMM LMEM arbiter is round-robin only in
  GEMM_NAIVE builds.
- The LMEM bank crossbar, memory layout, software ABI, and GEMM FSM command
  interface are unchanged.
- Naive configurations require at least eight LSU lanes.

## Verification

- Capture an unmodified 16-thread xrt-vcs-sim baseline for generation
  `M=1,K=256,N=256` and prefill `M=1024,K=256,N=256`.
- Add a focused gather-DMA unittest covering strided rows, out-of-order lane
  responses, output backpressure, and four outstanding groups.
- Run GEMM unit/node tests for WTRANS 0/1, K accumulation, and QDIR.
- Elaborate representative 8-, 16-, and 32-lane naive configurations.
- Repeat the baseline workloads with FSDB and compare correctness, cycles,
  lane use, bank collisions, DMA occupancy, FSM residency, and GEMM busy time.

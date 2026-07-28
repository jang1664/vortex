# LMEM Omega Ordering Hardware Specification

## Status

Confirmed by the user on 2026-07-28.

## Goal

Preserve the performance-oriented Omega request and response fabrics while
making local-memory write-to-read visibility and read-response association
architecturally correct.

## Scope

- `hw/rtl/mem/VX_local_mem.sv`
- `hw/rtl/mem/VX_local_mem_top.sv` when parameter plumbing is required
- `hw/rtl/VX_config.vh` for configurable default depths
- `hw/unittest/local_mem_top/` for targeted regressions
- Omega-enabled configurations only

The incumbent stream-crossbar request and response paths must retain their
current low-latency structure and behavior.

## Confirmed Design

### Omega request path

Add a parameterized outstanding-store CAM.

- Allocate one entry when an Omega request input accepts a write.
- Each entry records enough identity to retire the exact write when it commits
  at an LMEM bank, including requester, bank/address, and a slot or equivalent
  completion token.
- A younger read must not be accepted while an older outstanding write in its
  ordering domain matches the same LMEM word address.
- Release the entry only on the actual bank write handshake, not when the
  Omega fabric accepts the request.
- Apply backpressure when no CAM entry is available.
- Parameterize the CAM capacity.
- Instantiate or activate this hardware only when
  `LMEM_REQ_OMEGA_ENABLE` is defined.

### Omega response path

Add a parameterized requester-local read-order queue.

- Record every accepted Omega read request in requester order.
- Preserve sufficient bank/transaction identity to admit only the response
  corresponding to the head request.
- Pop the order entry only on the external response handshake.
- Backpressure new reads when the requester order queue is full.
- Parameterize the queue capacity.
- Instantiate or activate this hardware only when
  `LMEM_RSP_OMEGA_ENABLE` is defined.

### Parameter defaults

Expose named defaults in `VX_config.vh` and module parameters so unit tests can
override small depths without source edits. Defaults must cover the maximum
outstanding traffic of current Omega-enabled production configurations.

## Correctness Requirements

1. An accepted write followed by a read of the same word in the same ordering
   domain cannot return pre-write data.
2. Read responses observed at each requester are in that requester's accepted
   read order even when banks complete out of order.
3. CAM/queue full conditions use ready/valid backpressure without dropping or
   duplicating transactions.
4. Partial writes preserve byte-enable semantics.
5. Stream request and response configurations do not instantiate the new
   ordering state on their respective disabled side.
6. Existing performance-counter semantics remain unchanged.

## Verification

### Level 1: local_mem unittest

Extend `hw/unittest/local_mem_top` with focused cases covering:

- same-requester immediate write/read to one address;
- cross-requester older write and younger read to one address;
- multiple outstanding reads spanning banks with intentionally asymmetric
  response backpressure;
- CAM full and order-queue full backpressure;
- wraparound and simultaneous push/pop;
- partial-write RAW behavior;
- request Omega only, response Omega only, both Omega, and stream baseline as
  applicable.

Run through `python tools/verify_rtl.py`.

### Level 2: xrt-vcs

After Level 1 passes, use the configured build and repository wrapper:

```text
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw_naive --args "..."
```

Use `configs/naive_gemm_th32_tcol32_hwexp_dcache_oxbar_f16.sh` and include the
known stale-data diagnostic plus the final M=1 and M=32, K=256 cases.


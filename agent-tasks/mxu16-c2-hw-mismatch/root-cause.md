# Late TMEM write acknowledgments crossing DMA direction changes

## Reproduction

The original C2 RTL fails `fpint_gemm_ffn_hw -m 8 -k 256 -n 256 -q 32 -d 0
-t 0 -r 1` through `ci/run_black.sh xrt-vcs-sim`. Two launches reach the same
DMA channel-4 assertion: `response wrote slot 0 in state 0` in
`VX_dma_unit_align.sv`. The clean confirmation stops at 67,355,000 ps.

Reducing M to 4, K to 128, or N to 128 passes with the same simulator. This
explains why the prior C2 M4-only ablations did not exercise this failure.
The original hardware mismatch count has not been independently reproduced;
the assertion stops simulation before numeric output comparison.

## Ownership error

`VX_tensor_mem_bank` replies to every accepted request, including writes.
Write acknowledgments carry the request tag and zero data. The old subsystem
forwarded these acknowledgments through the same direct/fixed-pair return path
as read data.

HBM DMA G2L completion correctly waits for physical writes, including both
halves of each paired write. It does not wait for optional TMEM write replies.
After completion, the next descriptor can select L2G. In the old design,
`VX_dma_unit_align` interprets incoming local-memory responses according to
the current descriptor direction, not the direction of their original request.

The first preserved failing waveform/log has this boundary:

| Time (ps) | Channel 4 event |
|---|---|
| 66,995,000 | Final buffered G2L write physically dequeues; done asserted |
| 67,005,000 | Done handshake and next L2G configuration acceptance |
| 67,015,000 | Late G2L write reply is treated as an L2G read for free slot 0 |

A delayed write reply can therefore overwrite a read-response slot with zero
data or violate its ownership state. Slot/tag reuse is legal; confusing write
acknowledgments with read responses is not.

## Repair

At the actual TMEM bank's HBM-DMA port (port 0), carry request `rw` in the
highest unused routing-tag padding bit. The bank already registers and echoes
that tag. Consume replies with the write marker locally, before they reach
the fixed-pair response FIFOs or the direct DMA return path. Forward read
payloads and tags unchanged.

- No new response reorder, queue, or outstanding-ack counter.
- No new descriptor wait and no change to physical-write completion.
- No change to local-DMA ports 1 through 5, which retain their reply contract.
- Production 8/16-bank tag widths do not increase; single-bank configurations
  reserve one padding bit to keep the original payload tag intact.
- Generic tensor-memory bank and fixed-pair adapter semantics remain unchanged.

Validation must cover actual subsystem wiring, not just a generic pair model
that supplies only read replies. The before-fix source is preserved byte-for-byte
in `execution/before/VX_tmem_subsystem.sv` (c4acea43).

## Verification results

Fresh fixed-RTL blackbox regression: **11/11 PASS**, including the original
M8 K256 N256 failure three times, all four qdir/transposed combinations,
M4 K256 N256, M8 K4096 N16, M256 K128 N16, M16 K512 N256, and
M256 K256 N256. The kernel binary is identical before and after the RTL fix.
All runs have explicit PASSED, exit zero, and no strict simulator-log errors.
See [blackbox report](execution/repro/fixed-verification.md).

Independent actual-subsystem verification: **5 profiles PASS** across paired
32B/direct 64B banks, production 16/8-bank topology, and UUID1/UUID44 tag
geometry. The same final testbench fails the original paired source at275ns
and direct source at175ns because a late write acknowledgment is returned as
read payload. It also checks tag reuse, asymmetric response delay,
backpressure, write-only acknowledgment retirement, reset, and preservation
of local output-port acknowledgments. See
[directed report](execution/ack_filter-verification.md).

The optional single-bank probe encounters the same pre-existing switch
zero-width compile errors with original and fixed RTL; it is not a functional
PASS claim. No unrelated single-bank switch repair was made.

No replacement FPGA image has been synthesized or tested. The existing C2
xclbin is unchanged. These results establish the reduced protocol bug and its
repair, but do not independently reproduce the exact2048 hardware mismatches
or validate a corrected hardware image.

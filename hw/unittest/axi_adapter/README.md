# Grouped AXI adapter verification

Source the intended `configs/` profile and configure a build directory before
using this test. Run `tools/verify_rtl.py unittest --path <configured-build>/hw/unittest/axi_adapter --sim vcs`
from the repository root. Alternatively, run `make run SIM_EXEC=vcs` inside the
configured unittest directory. Run `make check-invalid SIM_EXEC=vcs` there for
the separate geometry rejection tests. This test uses VCS only and runs no
synthesis or hardware resource estimation.

The test fixes the data beat to 64 bytes, physical bank count to 32, and address
width to 34 bits, independently of the sourced kernel profile. It tests:

- P=2, H=8, K=1/2/4/8; P=1, H=8, K=1; and P=1, H=1, K=1.
- Compressed tags with 16 slots, uncompressed tags, a single tag slot, and
  requested zero input/output buffering.
- At least two full bank-map rotations and representative high rows using an
  independent arithmetic address oracle, checked at both AR and AW.
- Distinct request identities and full-width data, independently stalled AW/W,
  AW/W pairing, stable stalled channel payloads, delayed B and read responses,
  reordered reads, same-input return contention, tag exhaustion and ID reuse
  only after cache-side retirement, and complete drain.
- Opposite-group {0,1}, same-group {0,2}, and same-destination {0,0} traffic.
  A contiguous 64-cycle interval after 64 warm-up cycles requires the expected
  number of cache and AXI handshakes on **every cycle**. Writes count both AW
  and W; reads count both requests and returned cache responses. The single
  tag-slot case checks correctness without a throughput requirement.
- Separate negative elaboration/static-assertion probes for K=3/H=8,
  K=16/H=8, and K=1/H=3, preceded by a valid control probe.
- Targeted static-assertion probes for a 32-bit output address that cannot
  represent the 34-bit physical bank map (with a valid 26-bit input address),
  and for `DATA_WIDTH=1024` with an inconsistent `DATA_SIZE=64` override.
  These two checks require their specific assertion diagnostics after successful
  compilation; unrelated compile failures do not count as a pass.
- Every AR handshake requires no outstanding same-address AW-to-B write on its
  physical HBM port. Unrelated lines on the same port may continue before B.
  Additional 1-, 2-, and 3-credit cases hold B for 128 cycles, fill the write
  capacity, split AW/W handshakes, and read previously written addresses after
  the write burst. These cases require credit saturation and both AW-first and
  W-first coverage. Existing sustained-bandwidth checks remain unchanged.
- A same-port unrelated-read case requires all reads to pass before delayed B.
  A direct helper case checks B reordering across IDs, repeated IDs, repeated
  addresses, simultaneous allocate/retire with the same ID, circular capacity
  backpressure, and read admission held through downstream backpressure.

The adapter's `WRITE_PENDING_SIZE` (default 16) bounds outstanding writes per
physical port. `VX_axi_write_hazards` stores their cache-line addresses in a
synchronous `VX_dp_ram`; ID metadata, valid bits and scan masks remain registers.
Reads bypass the table when empty, otherwise scan live entries at one per cycle
and wait only for matching writes' B completions. Circular allocation stalls at
an occupied next slot, even if other slots are free. This keeps live slots in
age order and lets a B retire the oldest matching ID without assuming globally
ordered responses. Writes retain independent AW/W handshakes, and a partially
accepted write can complete its other channel even after using the final slot.
An admitted AR stays stable through backpressure. The request head remains
shared by all ports in a transport group, so a checking/waiting read can delay
later requests within that group.

`BANDWIDTH` lines contain measured counts and expected bytes/cycle. These
adapter-boundary measurements exclude the output cuts, DMA arbitration and
physical memory latency. The required unified and naive FPINT blackbox runs
provide the cache/DMA integration coverage specified in the implementation plan.

`ADAPTER_RTL` may point to a reviewed draft for early verification; it defaults
to the production adapter. For example, export
`MAKEFLAGS="ADAPTER_RTL=/absolute/path/to/VX_axi_adapter.sv"` before invoking
`verify_rtl.py`. Keep the resulting draft-verification logs distinct from the
final production-RTL verification logs.

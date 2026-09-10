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

`BANDWIDTH` lines contain measured counts and expected bytes/cycle. These
adapter-boundary measurements exclude the output cuts, DMA arbitration and
physical memory latency. The required unified and naive FPINT blackbox runs
provide the cache/DMA integration coverage specified in the implementation plan.

`ADAPTER_RTL` may point to a reviewed draft for early verification; it defaults
to the production adapter. For example, export
`MAKEFLAGS="ADAPTER_RTL=/absolute/path/to/VX_axi_adapter.sv"` before invoking
`verify_rtl.py`. Keep the resulting draft-verification logs distinct from the
final production-RTL verification logs.

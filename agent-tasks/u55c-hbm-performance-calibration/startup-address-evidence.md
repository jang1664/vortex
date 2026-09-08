# Startup address attribution (2026-09-08 23:04 KST)

The archived `VX_mem_remap` transforms LSU logical addresses using64-byte
blocks,32 banks,8 ports and bank-field shift29. `Vortex_axi.sv:498` and506
instantiate this mapping. `decode_startup_addresses.py` inverts that exact
mapping and checks forward/inverse round trips for every trace address plus
bit-position/boundary cases. This is functional-address remap, distinct from
the model's RBC/BG timing-address permutation.

Of182 read transactions before the phase diagnostic's first main snapshot:

- 165 target64 unique thread-stack cache lines; every hardware thread0..63
  is represented, with2–4 read transactions per thread's line.
- All165 stack reads map to physical HBM bank31, hence AXI port7.
- 17 target the linked program-image range0x80000000..0x80002080.
- No address is unclassified for this diagnostic.

The stack classification uses configured STACK_BASE_ADDR0x1ffc00000,
STACK_LOG2_SIZE13 (8KiB/thread) and64 hardware threads (four warps x16 lanes).
`vx_start.S` initializes sp as base minus hart-ID times the stack stride.
It initializes registers/TLS for all hardware threads even though the eventual
poll/GEMM main uses one reporting thread. Example logical lines:
thread0=0x1ffbfffc0, thread8=0x1ffbeffc0; both map to bank31/port7.

Actual diagnostic ELF symbols show `_edata == _end == 0x80002080`,
`__tdata_size == 0` and `__tbss_size == 0`. Therefore this specific diagnostic
does not have a large BSS/TLS payload to clear/copy. The initialization functions
and their stack traffic still execute; zero payload does not mean zero cost.

Archived socket configuration selects32KiB/4-way data cache. The8KiB stack
stride equals one cache-way capacity; the observed64 lines all have the same
offset modulo8KiB. This is consistent with heavy same-set pressure, not proof
of the miss/replacement history: AR addresses alone do not identify every
cache event or prove a cache bug. The same archived RTL applies to both sides,
so the address pattern itself is not a simulator/hardware mismatch.

`startup-address-results.json` preserves logical/physical addresses, bank,
thread classification and counts. This rules out prioritizing a large TLS/BSS
payload explanation for this case, but does not establish the precise cause
of the hardware's extra startup cycles. Further latency diagnostics should
include this single-bank strided pattern; do not introduce proprietary switch
contention or alter stack layout merely to force agreement.

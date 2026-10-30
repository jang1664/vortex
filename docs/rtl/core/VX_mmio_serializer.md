# VX_mmio_serializer

With `GEMM_SRAM_FUSION`, the GEMM MMIO source uses a scalar bus. The serializer
accepts one LSU vector request, saves its payload and active mask, and services
each active lane in ascending index order. It reuses `VX_priority_encoder` for
selection. An accepted vector remains owned until every active lane is served.

Writes advance when the scalar request is accepted. Reads allow one outstanding
scalar transaction and advance only when the LSU accepts its response. Each
response preserves the request tag and carries a one-hot mask for the selected
lane; the scalar data is broadcast into inactive lanes, whose contents are
ignored. Byte enables, address, flags, and write data are preserved per lane.
Backpressure cannot change the selected lane or payload.

The serializer sits before `VX_sram_lsu_transport`, so only the single-lane
request and response cross the SLR boundary. `VX_job_frontend` uses
`MMIO_NUM_LANES=1` and its register bank uses `NUM_LANES=1`; no vector decoder is
left behind the serial bus. A source-local vector payload register replaces
vector-width request queues across the boundary. Existing core reset clears
ownership; no reset relay is added.

The frontend's unified ABI adds two descriptor words: word 44 selects the GEMM
input/output memories and copy opcode, and word 45 records hardware completion
errors. Word 45 is software-read-only and survives completion. Both words clear
on slot allocation, so reused jobs default to HBM GEMM. A simultaneous software
beat write cannot suppress an error update.
The fixed `BASE+0x3f0` read holds until `publish_ready_i` acknowledges the
publication query; it then returns one. `BASE+0x3f8` returns capability
`0x53465203`. These globals share the ordinary GEMM window. The node owns the
publication query transport and memory completion ordering.

`hw/unittest/mmio_serializer` checks multi-lane allocation, sparse masks,
different and identical register addresses, byte enables, response stalls,
publication, error lifetime, and reset. `tests/regression/mmio_serialization`
issues concurrent MMIO operations from a real 16-lane LSU warp and checks every
lane's results without launching GEMM.

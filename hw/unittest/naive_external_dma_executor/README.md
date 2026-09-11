# Naive external DMA executor

The real metadata executor accepts only LOAD (low nibble 1) and STORE (low nibble 2). Controller dependency/notification metadata stays with the controller; this executor allocates a physical DMA entry, programs a coherent descriptor, starts it, polls the entry, and holds the original work ID until completion is accepted. It has no NOTIFY state or sync-write interface.

The directed VCS fixture retains the legacy descriptor-snapshot oracle and adds metadata opcodes with nonzero amount bits, addresses above 4GiB, exact work IDs, and 19-cycle completion backpressure. It covers a contiguous input LOAD (128 rows coalesced to a 32768-byte segment) and an edge output STORE (two short rows kept separate). Live command and geometry inputs change while descriptor programming is stalled. All descriptor base halves, strides, bounds, segment size, padding and direction are checked. The allocator response is delayed; bus requests must remain stable under write backpressure. No new command is accepted while completion is held, and the bus stays idle during that hold.

The DMA allocator/poll responder is modeled. It does not perform real LMEM writes or prove bank-commit visibility. In production, the existing naive DMA worker fence must delay the polled entry release until actual LMEM bank commits drain. Full-node tests must validate that connection. Geometry inputs must come from the FSM's accepted job snapshot, not mutable MMIO configuration.

Run from a configured XLEN64 build after sourcing a naive config, using `tools/verify_rtl.py unittest --path BUILD/hw/unittest/naive_external_dma_executor --sim vcs`.

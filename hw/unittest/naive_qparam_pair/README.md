# Quant metadata executor and physical lane arbitration

Use a configured XLEN64 build, source the matching naive TH16 configuration,
and run `tools/verify_rtl.py unittest --path ABSOLUTE_BUILD_PATH --sim vcs`.
`+QROW=0/1` selects quant layout and `+BLOCKED=0/1` selects the blocked S/Z
writer. The MXU16/MXU32 × layout × blocked-resource matrix has eight cases.

The fixture instantiates the actual `VX_naive_qparam_pair`, both metadata
executors, both independent DMA engines and per-lane unbuffered round-robin
arbiters. Immutable source bytes are generated from full physical addresses
above 4 GiB. Real returned tags select the engine and its response slot.
The fixture checks byte-enabled GEMM register requests, shifted byte addresses,
source/install work IDs, preparation before activation without duplicate
fetch, retained done backpressure, and peer installation while one writer is
blocked. Both quant layouts and reciprocal writer blocking are required.

The pair reuses the existing quant lane positions. Activating another input of
the existing five-input node arbiter would add previously inactive response
buffer payload (16 bytes per lane); those inactive bits are not budget credit.
Instead, this pair adds an unbuffered 2:1 arbiter before the existing quant lane
input. Each engine tag is one bit narrower; the arbiter inserts engine identity
within the unchanged GEMM base tag width and removes it on return. The new
arbiters have REQ_OUT_BUF=RSP_OUT_BUF=0 and no operand payload register. Actual
node integration must retain the existing outer lane buffers once, not create
a second response path for Zero.

Each metadata executor adds only one functional prepared-owner bit. Compact
descriptor and register bus mapping are combinational; payload remains solely
in the independently audited DMA engine storage. Arbiter control and the final
node-wide declaration ledger still require elaboration accounting; no mapped
cost claim is made here.

Iteration 1 failed fixture elaboration because it sized a pending-tag table
using the full tag width including debug UUID bits. Iteration 2 indexes the
table by the finite route/slot value width (UUIDs are zero in this fixture).
The actual buses retain their complete configured tag width. Eight cases pass
VCS in `p3-verification/quant-pair-iteration2`. This is a physical-interface
adapter test, not a complete GEMM register-array or numerical blackbox test.
The pair is ready for node replacement; the legacy node is not yet switched.

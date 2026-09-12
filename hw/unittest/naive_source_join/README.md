# Source generation join verification

Use the configured XLEN64 build and sourced naive TH16/MXU16 or MXU32 config.
Run `tools/verify_rtl.py unittest --path ABSOLUTE_BUILD_PATH --sim vcs`.
Default/`+CASE=positive` must PASS. Negative cases `duplicate`,
`foreign_generation`, and `duplicate_closure` must fail with the DUT diagnostic
`Naive source join ownership/count violation`. `early_restart` must fail with
`Naive source join invocation started before drain`. A generic failure is not
an expected-negative pass.

The actual helper joins producer closure with descriptor-qualified completion
of Input/W/S/Z source responses. The fixture supplies explicit completion
identities; it does not model physical operand memory. It covers one delayed
engine while the others advance in the second buffer, reads preceding closure,
closure preceding reads, reverse descriptor completion, four generations of
both buffers, exact maximum descriptors, one release per generation, and
completed invocation reuse without resetting the whole design.

Per-engine completion order is not assumed: the existing stream DMA queue
reports the owner of the response completing a descriptor (`response_slot`),
which can differ from issue order. A first draft with monotonic work IDs was
replaced before integration. Bitmaps accept unordered completion and reject
duplicates, holes, wrong generations and indices outside the closed range.
The new FSM reserves a fixed work-ID range per macro tile and uses a contiguous
prefix within it, including tails; that convention is independently checked
in the command-stream fixture.

The finite control allocation is two records of valid/closed/published (3),
generation (32), expected descriptor count (7/5), and four completion bitmaps
(4×64/4×16), plus two registered release-valid bits: **598 bits at MXU16 and
210 bits at MXU32**. Generation outputs reuse the records. There is no operand
payload, extra descriptor queue, per-response identity table or improve logic.
This is a new global source-join allocation, separately counted from controller
T-ready joins, context metadata and S/Z payload/control budgets. It is not a
synthesis cell count.

# Source generation join verification

Use the configured XLEN64 build and sourced naive TH16/MXU16 or MXU32 config.
Run `tools/verify_rtl.py unittest --path ABSOLUTE_BUILD_PATH --sim vcs`.
Default/`+CASE=positive` must PASS. Negative cases `duplicate`,
`foreign_generation`, `duplicate_closure`, `zero_work`, `zero_count`,
`large_count`, `high_count`, `zero_generation`, `simultaneous_generation`,
and `outside_count` must fail with the DUT diagnostic
`Naive source join ownership/count violation`. `early_restart` and `early_restart_pending` must fail with
`Naive source join invocation started before drain`. A generic failure is not
an expected-negative pass.

The actual helper joins producer closure with descriptor-qualified completion
of Input/W/S/Z source responses. The fixture supplies explicit completion
identities; it does not model physical operand memory. It covers one delayed
engine while the others advance in the second buffer, reads preceding closure,
closure preceding reads, reverse descriptor completion, four generations of
both buffers, exact maximum descriptors, one release per generation, and
completed invocation reuse without resetting the whole design. It also checks
exactly one input-register cycle before ownership changes, pending-event
quiescence, reset discarding pending closure/read events, and simultaneous
closure plus all four read completions. Consecutive completions cover the
owner feedback path. Expected-negative cases wait through the event register;
the DUT diagnostic is required. `high_count` uses 0x80000001 to detect accidental
truncation of the input count before validation.

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
210 bits at MXU32**. The input event register adds 198 bits (closure valid,
buffer, 32-bit generation, full 32-bit count, four read valids and four 32-bit
work IDs), giving 796/408 bits in total. Generation outputs reuse the records. There is no operand
payload, extra descriptor queue, per-response identity table or improve logic.
This is a new global source-join allocation, separately counted from controller
T-ready joins, context metadata and S/Z payload/control budgets. It is not a
synthesis cell count.

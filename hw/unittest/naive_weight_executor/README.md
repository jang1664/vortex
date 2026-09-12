# Naive Weight executor

This test instantiates the actual metadata executor and gather against per-lane memory responders and a backpressured GEMM register port. Use a configured XLEN64 build, source the MXU16 or MXU32 naive config, then run `tools/verify_rtl.py unittest --path BUILD/hw/unittest/naive_weight_executor --sim vcs`.

Eight full microtiles execute in two waves without reset. Every command has a different stride and source address above 4GiB. The first command of each wave is prepared, fully source-captured, and held without issue even though its writer dependency is satisfied. No installation is allowed until activation. Four executor owners coexist after activation. Every physical request and installed data word is checked against immutable address-derived payloads, with reordered lane replies and destination stalls.

All four destination selections are exercised. Commands alternate full and partial logical bounds; the executor still fills the complete W register from the allocated LMEM microtile. Each completion is held for 19 cycles, checking a stable exact work ID and no following-command installation. The final state requires eight distinct source captures, eight issues, eight completions, the exact full-microtile beat count, and quiescence. This establishes transport behavior, not the numerical correctness of padded tails in the actual GEMM node.

The adapter adds 69 functional ownership bits: prepared flag/ID (33), held completion flag/ID (33), and outstanding count (3). It introduces no operand payload. Four gathered descriptors and response slots remain owned by `VX_lmem_weight_gather_dma`; a final elaborated boundary ledger is still required.

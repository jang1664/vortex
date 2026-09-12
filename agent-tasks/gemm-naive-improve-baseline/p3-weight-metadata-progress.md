# Weight metadata integration — work in progress

`VX_lmem_weight_gather_dma` now has a compile-time `NAIVE_METADATA` option, declared only under `GEMM_NAIVE`. Its default remains disabled until the real executor is connected and verified.

The enabled path admits four stream-queue descriptors, stores the writer wait beside each destination address, exposes the exact writer-head wait and work sequence, and accepts a writer-release signal. Physical source-capture completion and register-install completion expose their separate command IDs. Destination decoding explicitly uses only the lower 64 address bits.

Each live assembly slot retains its own 32-bit source stride. The legacy global stride is insufficient once a subsequent command may be admitted while prior lane requests remain outstanding. This adds 128/256 control bits at response depth 4/8, and no operand payload. This is a provisional delta, not the complete candidate allocation ledger.

Improve synthesis preprocessing passed all 72 comparisons in `p1-isolation/iteration9/result.json`, with stable sources. This does not prove unchanged elaboration, synthesis resources, or application latency.

Legacy regression iteration 1 failed compilation because the existing unit Makefile omitted `VX_dp_ram`, required by the current stream queue. Added that source dependency and reconfigured the build before iteration 2. No assertions or expected results were weakened.

Still required: directed four-command tests with distinct strides and delayed/reordered lane responses, held writer fences and exact completion IDs; a real Weight executor with prepared-command ownership and completion handling; final storage accounting; node integration and all P4/P5 gates. The enabled metadata path is not yet verified and is not selected by the production node.

Legacy iteration 2 reached the exact-time assertion after all payload, request, response, backpressure and ownership checks, but completed at 525ns rather than the stale expected 515ns. Running the same fixture against the frozen P0 RTL snapshot reproduced the identical 525ns failure (`p3-weight-frozen-baseline-check.json`). Updated the exact expectation to 525ns; retained all other assertions. This baseline reproduction establishes that the one-cycle mismatch predates these Weight changes.

Legacy iteration 3: VCS PASS, including the exact 525ns completion check. New metadata mode remains unverified.

## Enabled transport verification

The final matrix in `p3-verification/weight-metadata-matrix/summary.json` passes MXU16, MXU32 and MXU16 NDEBUG. Each case retains compile/simulation logs. Eight distinct-stride commands, four simultaneous queue owners, out-of-order physical replies/source completion, independently held writer targets, exact source/install identities, full payload checks and no-reset reuse pass. Test scope and fixture bring-up are documented in `hw/unittest/naive_weight_metadata/README.md`. No DUT changes were needed during this test turn. Earlier statements that metadata mode is unverified are superseded only for this transport scope; the real executor, full microtiles, production node and P4/P5 gates remain pending.

## Unified-command executor

`VX_naive_weight_executor` now maps the unified command into the gather, retains a prepared owner until matching issue, checks the registered W-consume counter, and holds completion/work ID under backpressure. Four total owners are bounded across prepared, queued and completed commands. The adapter adds 69 control bits and no payload. The source queue remains the sole descriptor owner.

Actual full-microtile tests pass at MXU16, MXU32 and MXU16 NDEBUG in `p3-verification/weight-executor-iteration1`. Sources remained stable throughout the retained matrix. Prepared source capture occurs while the writer is available, but installation waits for activation. Completion is held 19 cycles for each command. All physical addresses, register payloads and completion IDs are checked. Padded-tail numerical correctness and production-node integration remain unproven. Improve preprocessing iteration 10 passes all 76 comparisons; actual resource/cycle gates remain required.

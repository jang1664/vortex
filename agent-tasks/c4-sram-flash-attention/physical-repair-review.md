# Physical repair review, 2026-10-24

This review authorizes only the scopes stated below in the isolated physical
repair worktree. Original production sources remain frozen for the ongoing
R5 implementation and full decoder/prefill runs.

## Applied LMEM partial repair

The feature-only LMEM `VX_slr_mem_bus` uses its existing LOCAL branch and
retains one request launch entry. TMEM keeps the registered credit link.
Root matched all three author-file hashes and verified that the original
three source files and three topology tests remain unchanged. The three
updated pure Tcl fixtures pass; this is not RTL or physical acceptance.

Assigning `u_fusion_lmem_cut` to SLR1 alone does not constrain its existing
consumer. The final repair must establish a bounded complete consumer
interface and inspect every incident edge after placement. Current frontier
evidence is insufficient for broad parent anchoring: the existing port-0
arbiter and LSU switch each include a cell observed in SLR0. Do not move an
individual failing LUT or reclassify all existing LMEM logic as feature logic.

## Approved independent MMIO transport component

Implement a feature-only `VX_sram_lsu_transport` with its new directed
testbench. Reuse the existing same-clock `VX_slr_stream_tx` and
`VX_slr_stream_rx` primitives without editing them. Preserve the complete
packed LSU request and response, including mask, tag, flags and byte enables.
Use one request launch entry, four request credits, four response credits
and no response launch entry. Source and destination resets are separate
inputs for integration with the proposed endpoint-local reset relays.

For each master, an upper bound on accepted reads awaiting source response
consumption is:

| Storage or ownership | Packet bound |
|---|---:|
| Request launch | 1 |
| Request credit transport, including flight | 4 |
| Controller response slot | 1 |
| Existing controller `u_mmio_arb` response buffer, `RSP_OUT_BUF(2)` | 2 |
| Response credit transport, including flight | 4 |
| Total | 12 |

The shared three controller-side slots may conservatively be charged in full
to each master. Four counter bits represent 0 through 12. Count every
accepted read packet, including a zero-mask read, because the existing
controller returns one packet for every accepted read. Simultaneous read
acceptance and response consumption leave the count unchanged. Credits
already include payload flight stages; do not count those stages again.

Source ownership must cover the request launch, unreturned request credits,
accepted reads awaiting response consumption and a real pending request
offer. It must not manufacture busy from reset release alone. Explicitly
deassert source request ready during source reset; resetting an elastic
buffer does not by itself guarantee this. Coordinated reset discards both
directions and their ownership together.

The new testbench must exercise full payload preservation, zero-mask reads,
request and response stalls, posted writes, delayed responses, the storage
bound, simultaneous acceptance/consumption and reset with work pending.
Independent verification uses the configured isolated build and
`tools/verify_rtl.py`. Controller/core integration awaits the final design.

Both component iterations now pass independent VCS verification. Iteration 1
reached the 12-packet bound. Iteration 2 adds an explicit destination-storage
parameter, retaining default 3 slots and allowing 4 for the GEMM frontend's
additional captured-request stage. Separate tests reach 12 and 13 packets,
with simultaneous acceptance/consumption, zero masks, backpressure and reset
witnesses. Root verified archived sources, binaries and logs for both cases.

## Approved integration scope

The full LSU admission ready cone also contains the existing GEMM MMIO
downstream ready through `VX_lmem_switch`. A second feature-only complete
LSU link on `gemm_ctrl_if` therefore uses the 4-slot destination setting;
removing ready from the admission predicate would change mixed-packet
acceptance semantics. Both interfaces preserve the existing register ABI.

At remote GEMM request acceptance E3, include actual `req_capture` in the
busy transmitter immediately. `req_valid_q` covers processing at E4, and
`occupy & (valid | working)` covers queued/active descriptors until retirement.
The busy receiver observes ownership before the final request credit can
remove source ownership at E5. Allocated but inactive descriptors alone must
not hold the AFU busy. Preserve actual GEMM work/drain ownership as well;
controller quiescence alone does not prove that the frontend is empty.

Root has authorized the coherent integration in the isolated tree: both
MMIO links, request-scoped publication, lossless original-epoch commit-count
return, complete bounded LMEM support scopes, endpoint-local reset relays,
and source/remote busy handoff. Existing test infrastructure remains under
independent review. New modules require directed testbenches. The exact
consumer scopes are the adapter, lane-0 CPU/DMA arbiter, port-0 response
arbiter and all 16 complete final bank request-output elastic buffers. Do
not expand these to the whole CPU, crossbar or bank arrays. Their complete
incident edges remain subject to the new physical audit.

## Publication proof required before integration

Keep the existing all-pending-zero condition. A single cumulative committed
watermark cannot prove completion of a requested admission prefix when newer
stores can overtake an older store in another lane or bank.

If commit producers are local to SLR1, return each cycle's commit count
losslessly through a source register and destination register to the existing
SLR0 accounting. With no loss or duplication, let A be admitted stores, C be
actual commits, and R be returned commit observations. Then R <= C <= A and
the observed pending value A - R is at least the true pending value A - C.
Observed pending zero, combined with no current-cycle admission, therefore
proves physical publication. Delayed observations can only delay completion.
The count width must represent 0 through all 16 bank commits in one cycle.

This proof requires producer locality, no transport backpressure/loss, and a
shared reset epoch. Admission accounting and every commit-return stage must
use the original global reset epoch; delaying only accounting reset would
lose stores admitted during reset release. Per-bank producer identification
and a complete new physical input/output audit remain mandatory.

Probe 14758 now resolves all 48 bank valid/rw/source-tag FF Q pins. Banks
0, 10 and 11 have these fields split between SLR0 and SLR1, even though every
`last_wr_valid` FF is in SLR1. Therefore that last-write FF's placement alone
does not prove a local CPU/DMA decode. Twelve explicit CPU LUT3 INIT=8'h08
truth tables match `valid && rw && !source_tag`; four terms are folded into
larger logic. The next design review must address complete request-output
buffers or another correctly aligned registered event interface, rather than
placing just the new popcount beside a subset of its inputs. The complete DMA
reduction cone and consumer inventory remain in progress as probe 65605.

Publication query/reply tokens must be request-scoped. Mixed vector reads
retain the existing controller-acceptance snapshot and delay only response
visibility. A valid START reserves internal busy before querying publication;
the direct same-edge GEMM exclusion guard remains local. Exported busy may
be delayed only with overlapping source-side MMIO ownership, and must reset
to zero to preserve AFU startup behavior.

## Integrated source review before RTL execution (10:24 KST)

The isolated implementation now separates the operational bridge guard from
its SLR0 busy export. The source combiner includes actual MMIO offers and
accepted transaction ownership; the remote input includes the frontend's
capture/processing stages and occupied valid/working entries. Inactive
allocated entries alone do not hold busy. Both fusion and GEMM MMIO links
are present, with independently verified read capacities of 12 and 13.

The commit helper derives CPU/DMA events from aligned valid/write/source-tag
fields at each complete final bank request buffer. Its five-bit count carries
all 16 CPU commits, including consecutive nonzero cycles, through two common
clock registers without backpressure. The observer and both count registers
use the original global reset; endpoint reset relays do not alter that epoch.
The assertion that every offered physical write is accepted protects the
existing `rw => ready` simplification.

The publication helper transports query wait-mode/token and reply result/token.
The controller reserves a valid START while its fresh observation is pending;
PUBLISH retains the acceptance-time response snapshot. The new directed
controller test explicitly enables `PUBLICATION_LINK=1`, unlike the legacy
standalone controller fixtures. A separate actual-frontend test covers the
posted-write handoff after CPU retirement. These source reviews do not yet
establish simulation results.

Root's five pure Tcl suites pass with stable source hashes. The new support
fixture covers 25 exact roots in slash/dot spellings, all 16 final bank buffers,
both source-buffer kinds on two example masters, observer and mixed-owner
commit-return hierarchy. It excludes unrelated roots and all support takeover
when the feature is absent, and rejects escaped publication arithmetic.
Evidence: isolated `logs/physical_metadata_root/iteration2/receipt.json`.
No original production input or checker was changed by these repairs.

## Queued descriptor arbitration correction (10:52 KST)

Node integration exposed two distinct issues in the simultaneous START/cfg
case. The old test launched its source doorbell only after remote cfg valid;
with the new MMIO transport, that request had not reached the controller when
GEMM accepted cfg. Diagnostic reproduction records source valid=1, remote
valid/fire/start=0 and zero bridge commands/responses at the failure.

The initial repair also included `!fusion_frontend_pending` in START
quiescence. That wrongly rejects a queued but unaccepted GEMM descriptor even
when actual work and memory have drained. Only this conjunct is removed.
On the START acceptance edge the immediate bridge guard blocks cfg; pending
publication then holds ownership until launch or rejection. Actual invocation,
TMEM pending work and request-drain checks remain unchanged. Frontend pending
still protects the exported AFU busy signal and its no-gap assertion.

The fixture now detects the actual public GEMM CONTROL handshake E0 and
accepts source START at E2, aligning the controller request with cfg at E5.
The actual same-edge collision, exactly-once command, physical drain and
numerical checks are unchanged. No private state or ready signal is forced
for this alignment. Node iteration3 subsequently passed all three route and
four local-owner cases; its combined run failed at the boundary fixture as
described below. The two earlier failures remain recorded separately.
New node SHA: `100d538d36fd0c207272ba7235f04e646cd555700e93fae63ed9a2a86769853e`.

## Node acceptance and full-core release (11:10 KST)

Iteration3's boundary fixture issued source STATUS only after DMA completion,
so the new MMIO latency prevented the intended controller-edge collision.
The corrected fixture releases a real pending TMEM response at E0 and accepts
source STATUS at E1. Both completion and the transported read reach the
controller at E4, including the DMA advance state. The original actual
same-edge assertion remains mandatory; no completion/state force was added.

Iteration4 session80422 exited0 with boundary and all six resident FP16/FP32
cases passing. Coverage includes reset with pending responses, sequence wrap,
BUSY rejection, eighteen invalid shapes with zero HBM requests, FP32 values
above65504, accumulator backpressure and FP32/FP16/legacy reuse without reset.
Together with iteration3's route/local-owner pass, all eight node scopes are
accepted. Root rehashed793 current sources and per-case evidence. The sole
between-pass change is the boundary-only fixture, inactive in route tests;
production RTL and route predicates are identical. The failed combined
iteration3 remains failed. Evidence is isolated
`logs/physical_bundle_root/node_acceptance/receipt.json`.

Full-core publication stress session12658 terminated before DUT/host launch:
the private tree lacked Ramulator's library. Vendor prerequisite compilation
also logged unsupported SystemC compiler errors. Wrapper2/collector-15 and
the missing EOF are preserved as an infrastructure failure, with927 sources
unchanged. Root rehashed the previously used vendor cache's712files and the
complete806-file Ramulator dependency. Ramulator is now copied privately;
new session49073 uses the immutable vendor cache and private work/IP outputs.
Its fresh build freezes1733 inputs and retains the same workload,1800s
allowance and120s collector drain. Session49073 subsequently exited0 with
actual wrapper/host/simulator/collector exits all0. Root independently checked
the complete66,206,369-byte trace's hash/CRC/EOF, the256-cycle store hold and
empty-accounting witness, absence of fatals,1733 sources, six launch/terminal
binaries/configs and712 vendor files. Tiled/dense maximum errors are
2.86102e-6/2.38034e-6, with relative L2 .00129931/.00106072. Queued PUBLISH
was not observed and is not claimed. This accepts the full-core publication
stress only; production traffic and physical-bank stalls have separate gates.
Evidence: isolated `logs/physical_fullcore_root/publication_acceptance.json`.

Feature-off preprocessing session62603 exited0: all26 source comparisons
(thirteen modules/testbench files in two profiles) and18helper-selection
checks pass. Root verified412 current source hashes,400 existing snapshot
entries, exact normalized text and historical inputs. This proves selected
source identity only. Root verified the separate VPI/cycle preparation's522
source inputs, ten build outputs and three observer artifacts, then released
that actual run. Early-return and production attention workloads are also
released after publication acceptance, each in its own configured build with
the frozen bounds and checks. Their results remain pending.

## Remaining acceptance

At11:36 KST, repaired full-core publication, natural early-return and production
FP32 M4/KV256 have passed independent root review. The latter includes complete
trace EOF/CRC, exact four-job completion, zero intermediate GEMM HBM writes and
all-AFU address classification. Early-return includes both65,536-byte copies,
all physical commits and exact readback. Feature-off iteration3 also passes
full VPI identity, the frozen kernel, exact6334/8406 instruction/cycle counts
and complete17-file actual simulator/host launch-to-terminal provenance. The
two earlier capture failures remain separately recorded, with no RTL change.

The R6 package freezes933 production inputs and retains the corrected physical
classifier. Its acceptance reader checks23 support scopes plus10 node scopes;
eleven pure cases cover complete slash/dot inventories and nine missing or
invalid inventories. The same checkpoint also receives the strict no-waivers
LUTLP-1 check. Independent final package review passed all39 package and933
production hashes plus the11 pure reader cases. Whole-platform R6 build16386
launched and was observed live at11:47 KST. Root accepted generated input
identity at11:43:313 generated files match the actual build, launch archive
and exact preprocessing reproduction;32 copied helpers,17 raw third-party
entries and933 sources match. Full effective defines and the derived INI also
match. See isolated `logs/r6_launch_verification/root_generated_acceptance.json`.
All placed/routed checks remain pending; input identity does not imply a
physical result.

The original R5 routed timing stage now meets setup/hold/pulse-width checks,
but its physical-frontier failures remain. Neither that report nor the pure
topology tests certify the repaired implementation. The complete repair needs
new placed/routed physical, image identity and hardware matrix evidence.
Full decoder and complete prefill traffic evidence also remain separate gates.

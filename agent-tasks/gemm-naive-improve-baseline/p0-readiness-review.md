# Independent P0 readiness review

Reviewed 2026-09-11 03:27 KST against plan.rev3, the exit checklist, proposed
allocation bounds, interface map and retained evidence. No production changes,
new functional simulations, STATUS updates or goal-completion claims were made.

## Verdict

The four corrected numerical baselines and numeric thresholds now have their
required completed captures and exact endpoint matching. P0 can be frozen
**after adopting the external LOAD bank-commit contract and its finite control
allocation** from `p0-load-visibility.md` into the interface/allocation/checklist
artifacts. That is the concrete missing prerequisite found in this audit.
It is a contract/budget closure, not permission to claim the new fence works
before implementation and directed verification.

No further baseline simulation is requested. No P1–P5 overlap, independent
engine, candidate resource or arbitrary-stall result is credited here.

## Finding: T-ready lacked a physical LOAD completion contract

The earlier visibility audit correctly rejected node request drain as a G1
fence and correctly identified STORE source-read retirement as O release.
However, its bank-commit return proposal classified only GEMM-priority PSUM and
final writes. External I/W/S/Z LOAD writes arrive through the normal-DMA input.
`p0-contract.md` still listed actual LOAD visibility as an unproven T-ready
producer, while the interface map described T-ready without a corresponding
physical completion fence.

The additional retained-wave check makes the distinction concrete:

- All 64 external LOAD worker-done events precede completion of their bank
  writes. They have 3–48 uncommitted 8-byte writes, draining 4–15 cycles later.
- All 22,528 enabled reserved words match committed words. Route-tag decoding
  agrees independently with source-region address classification.
- The baseline still passes numerically. Worker done is not the later GEMM T
  notification; this audit does not label all T notifications premature without
  comparing their polling latency. No new corruption trace is claimed.

The resolution in `p0-load-visibility.md` preserves the existing single-worker
DMA descriptor owner and holds frontend completion until its bank commits.
It uses a 12-bit pending count plus 1 reservation bit, a 4,095-credit ceiling with
pre-scatter reservation/backpressure, exact simultaneous reserve/commit math,
and the existing 3-bit-per-bank event allocation recoded to distinguish DMA
from PSUM/final. It adds no payload and no per-write owner tags. An optional
registered return is still 48/96 bits total, shared with the G1 fence.

Source generation mapping joins four distinct fenced member completions for
one buffer/generation. The review additionally gives a conservative 74-bit
ceiling for the two T-ready generation/member/published records and up to 36
bits for an active LOAD receipt only when not already present in an existing
counted command. Including the 13-bit fence gives a 123-bit global control cap;
receipt fields cannot be charged twice. Actual worker entry/owner/generation
storage is reused. The root should reconcile these named categories with the
existing global-source bookkeeping before freezing the allocation manifest.

Required integration tests are explicit: delayed cross-port writes/read
attempts, partial and zero byte masks, simultaneous reserve/commit, credit
saturation, mixed CPU/GEMM descriptors and origin tags, generation duplicates
and stale receipts, both source buffers and three no-reset generations. These
remain implementation tests; the present baseline is not an arbitrary-stall
proof. The previous combined quant engine remains the measured starting point.

## Numerical gate and provenance checks

I inspected all four final capture manifests/endpoints and verified their
manifest/endpoint hashes against `p0-numeric-gates.json`. Each capture has
returncode 0, numerical PASS, no source changes during its execution, one
invocation, exact log matching and no endpoint differences.

| Capture | Normalized GEMM cycles | Core cycles | Candidate requirement |
|---|---:|---:|---|
| naive M4 | 61,552 | 68,154 | GEMM<=46,164; core<=68,835 |
| naive M256 | 1,372,729 | 1,379,304 | GEMM<=1,386,456; core<=1,393,097 |
| improve M4 | 6,449 | 12,206 | Exact equality for both |
| improve M256 | 272,870 | 278,684 | Exact equality for both |

The integer arithmetic matches floor(0.75*naive_M4), floor(1.01*naive_M256)
and floor(1.01*naive_core). Service uses exactly ordinals 256..767, excludes
pair 511/512, and retains 510 eligible pairs/2,048 rows. At least 255 pairs must
overlap. Increasing density by 25% with equal accepted rows yields interval
<=floor(30,233*4/5)=24,186 cycles; the gate is not incorrectly reduced by 25%.

The gate script deliberately leaves `baseline_frozen=false` and states that
numeric derivation cannot close the other P0 exits. That is appropriate. The
old timeout124 M256 run is not used. Historical legacy counter values are not
substituted for normalized endpoints.

## Allocation arithmetic and scope checks

At review time every evidence SHA in `p0-allocation-bounds.json` matched its
referenced plan/map/report. Named arithmetic checks passed:

- Naive-only command extension 130 bits; at most 30 copies -> 3,900 added bits.
- Input contexts: 4*549+9=2,205 bits, without a duplicate old context array.
- Notification/controller bound: 1,207+288+28+16=1,539 bits.
- Per S/Z engine queue: 1,716 descriptor bits  + 544 slot bits  + 155 other bits
  =2,415 bits.
- Adapter: 1,297+B+813L -> 4,581/7,865 bits. Functional totals 6,996/10,280 bits;
  adding 448 PERF bits gives7,444/10,728 bits per engine.
- Independent S/Z payload: 2*(256+32+128+32)=896 bytes at MXU16;
  MXU32 total 1,792 bytes, both below the existing 928/1,856 combined transport.

The boundary storage scopes reconcile to 2,976/6,464 bytes of active-capable
payload plus separate inactive/control declarations. With dedicated Input/SZ,
totals are 4,832/10,176 bytes, including RAM-output copies and shared arbitration
once. Weight resolves 4/8 slots and 288/1,088 bytes; no constant-depth extrapolation
is used. Final converter OUT_REG=0 is combinational. Opaque fixed vendor IP and
external memory staging are expressly excluded, not usable credits.

These are declaration/allocation bounds, not synthesized naive-cost equality
or demonstrated replacement engine capacity. The planned four-descriptor,
eight-slot configuration still needs actual implementation elaboration and
its fixed finite fairness/retirement tests. That future work is correctly
outside the baseline freeze, while the newly found LOAD global-control fields
must now be included in the frozen allocation/hash chain.

## Improve preservation evidence

The retained 72 MiB post-synthesis checkpoint exists and its SHA256 matches the
cost summary. All referenced source/include/input hash manifests exist; all
include/input hashes match current files. One full source hash differs:
VX_gemm_ctrl.sv, whose observation include/instance changed after the synthesis
source snapshot. I independently removed its current synthesis-excluded
observer block and compared whitespace-normalized text with HEAD; it matches
exactly, as does the naive controller. This supports the documented observer
isolation explanation rather than hiding the full-file hash difference.

The frozen resource report is OOC VX_gemm_node_ooc with part, tool 2025.1,
7 ns clock, source list and synthesis options retained. WNS=-0.690ns is reported
as a failed timing-closure result, not a passing one. P0 freezes that existing
configuration; it does not authorize changes to improve or offset one resource
increase against another. Future guards in VX_local_mem/VX_mem_unit/VX_core
must also demonstrate unchanged improve elaboration because the OOC node alone
does not instantiate those external wrappers. This is a required candidate
scope check, not a missing baseline resource report for unchanged wrappers.

## Other exit evidence and final bookkeeping

Shared-vector parity, packed-weight references, 0.001 relative/zero-reference
absolute comparisons, copied-payload fault controls, actual S/Z install checks,
real-controller completion tests and same-epoch lifecycle results are clearly
separated in the reports. The lifecycle device timestamps prove verification
before next submission; substantial software-check time is not called GEMM
latency. Reset-separated -r runs are not mislabeled as no-reset evidence.
The resource DAG is labeled a software partial-order model, not bounded RTL
liveness. These scope qualifications should remain in the P0 freeze record.

Before marking P0 frozen, root should:

1. Add the binding LOAD fence/event encoding and global-control allowance to
   p1-interface-map/p0-allocation-bounds, retaining the improve isolation rule.
2. Refresh affected evidence hashes and point the exit checklist to the new
   LOAD visibility evidence and completed M256/numeric gate artifacts.
3. Record candidate fence/credit/origin/generation tests as outstanding P1/P2
   work, preserving all P1–P5 final gates.

No additional P0 simulation is requested by this review. The complete naive
redesign remains unimplemented and its acceptance criteria remain unchanged.

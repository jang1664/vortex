# P1/P2 interface and implementation map

Status: source-derived preparation, 2026-09-11. No production RTL changes or new simulation results are represented here. This implements the architecture prescribed by [plan.rev3.md](plan.rev3.md); P0 freeze remains a prerequisite. The physical completion endpoint is the bank-commit contract in [p0-visibility.md](p0-visibility.md), which supersedes treating node write-request drain as visibility.

## Preserve the improve branch

Keep improve's existing elaborated command width, 21 synchronization counters, five-bit RID encoding, interfaces, timing options, TMEM readiness scheduler, queues, and optimized completion reducer unchanged. A declaration needed only by naive belongs inside `ifdef GEMM_NAIVE`; a replacement algorithm selects a naive helper inside that guard. Do not introduce a runtime backend selector or refactor improve pipelines to accommodate naive.

The practical reuse boundary is existing command metadata, FIFO/stream-queue primitives and architectural control algorithms. Reusing an algorithm does not require moving improve's implementation into a newly parameterized module. Preserve improve source branches and adapt its algorithm in the already separate naive controller/node when commonization cannot prove identical elaboration. Remove the legacy naive parent synchronization architecture instead of retaining it behind a new metadata facade.

## Concrete file map

| File | Implementation boundary |
|---|---|
| `hw/rtl/VX_gpu_pkg.sv` | Retain existing waits, prepare, writer-wait and notify types. Guard appended naive command fields below. Define SRC_FREE0/1 as 21/22 and counter count 23 only for naive; keep improve 21. No global ID renumbering or ID-width increase. |
| `hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv` | Replace parent WAIT/NOTIFY issue with improve-style command stage, independent child queues, dependency checks and ordered owned inflight completion. Reuse FIFO primitives directly. Adapt the improve controller algorithm with naive routing and completion semantics; retain real queue/inflight quiescence and pending notification ownership. |
| `hw/rtl/core/gemm/VX_gemm_ctrl.sv` | Preserve the improve implementation. Its source is the baseline for the naive rewrite, not a requirement to instantiate its TMEM ports and tie them off. Existing optional synthesis-excluded observer remains observational. |
| `hw/rtl/core/gemm/VX_gemm_ctrl_naive_if.sv` | Replace combined quant control/flag with separate Scale and Zero control/flag. Add exact resource readiness and consume targets, source-completion identity, and O admission readiness. Retain the actual external DMA single-command ready/done adapter unless its executor is explicitly redesigned; do not fabricate improve DMA tags. Remove unused output-copy control from naive. |
| `hw/rtl/core/gemm/VX_gemm_fsm_naive.sv` and its FSM interface | Generate only real Input, Weight, Scale, Zero, external LOAD and STORE commands using improve's metadata-builder conventions. Retain common index/address arithmetic when identical; select naive LMEM addresses and fixed N-fast traversal. Delete WAIT/NOTIFY and dummy ACC2LMEM emission. Capacity may stall emission, dependencies live on commands. |
| `hw/rtl/core/gemm/VX_gemm_input_packetizer.sv` | Preserve existing users through a naive-only implementation branch/helper. Replace the single head's coupled admission/retirement ownership with separate admission and completion pointers, following improve node context logic. Keep full physical addresses and independent packet-end, final-output mode and terminal-fence semantics. |
| `hw/rtl/core/gemm/VX_gemm_node_naive.sv` | Integrate the four contexts, independent S/Z engines, precise source-generation joins, O-owner admission and bank-commit retirement. Ordinary Input completion uses registered last ingress; terminal Input completion waits for the tile fence. Keep existing LMEM result storage and PSUM mechanisms; no forwarding store or new result hierarchy. |
| `hw/rtl/core/gemm/VX_lmem_dma_misal.sv` / new naive helper selected under `GEMM_NAIVE` | Replace the combined quant executor with two independent queue/adapters. Reuse `VX_gemm_stream_dma_queue` unchanged with four descriptors and eight response slots per engine; replace generalized quant aligner buffering with the bounded byte-select/install adapter. Preserve improve instances/parameters. |
| `hw/rtl/core/gemm/VX_gemm_stream_dma_queue.sv` | Reuse owned request/response/installation sequencing and `fetch_complete` semantics. No common functional changes needed for the proposed compact descriptor payloads. Keep optional sink elastic/bypass payload disabled in naive unless the frozen ledger is explicitly rebudgeted. |
| `hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv` | Consume real LOAD/STORE metadata; STORE's actual descriptor completion publishes O. LOAD readiness must represent installed LMEM operands, not merely requests issued. Preserve the distinction between source retirement and HBM visibility. |
| `hw/rtl/core/VX_core.sv`, `hw/rtl/core/VX_mem_unit.sv`, `hw/rtl/mem/VX_local_mem.sv` | Add only guarded naive control sideband for actual LMEM bank write acceptance, following `p0-visibility.md`; route it back to the naive node. Preserve all improve ports, request tags, payload buffers and arbitration stages. |

## Child routing and dependency/completion ownership

Use five active naive children: Input=0, Weight=1, Scale=2, Zero=3, external DMA=4. Improve keeps its existing six-child routing (Output=4, DMA=5). This keeps the four operand children aligned without allocating an unused naive Output queue. The branch is explicit at opcode routing, child count, DMA index and producer assertions; do not reuse numerical child-4 ownership assumptions from improve.

The improve controller's ordered child FIFOs/inflight records (`VX_gemm_ctrl.sv`, around lines 850–935) are reusable mechanisms. Its DMA tag scoreboard and specialized DMA wait switch are not directly compatible with the current naive single-active external executor. Use a bounded one-active owned DMA notification record, retiring only on actual executor completion; retain queued external commands and independent local child progress. No fake `done_tag` or synthetic completion is allowed.

Evaluate every valid naive `waits[0..4]`, including SRC_FREE. The improve DMA path's G0/G1/ACC_FREE-only decoder cannot simply be retained. Likewise, the optimized fixed-producer reducer around line 417 has six-child ownership assumptions: implement the five-child naive reducer and generation-qualified source-release updates separately. Keep simultaneous independent RID updates, legal increment/set assertions, registered W/S/Z installation readiness and registered cuts preventing completion-to-admission combinational loops. RID_SZ remains a derived minimum, not an independently guessed install event.

Naive Input admission slot 3 checks O against the carried owner target; it does not read ACC_FREE. W/S/Z slots retain exact bank/generation checks at their true consumers. G0 increments on ordinary registered ingress completion; G1 increments only on the terminal real Input's closed-producer plus bank-commit fence. STORE waits for G1 and increments O on actual source-read retirement. Every Input carries its O owner target, including commands after the first blocked command. SRC_FREE requires all expected Input/W/S/Z source reads issued and all matching responses captured into owned transport storage, with no future source reads for that generation.

Delete TMEM scheduler instance, probe admission, scheduler credits/priorities, event bookkeeping and associated scheduler assertions from naive elaboration. Retain actual child queue capacity, dependency checks, inflight ownership and invocation quiescence. Already queued eligible work must run while another child waits; the ordered producer can still backpressure on a full target queue.

## Exact proposed metadata bounds

These are pre-integration declaration ceilings for the specified replacement records, not synthesized flop counts or permission to add unspecified storage. Counts below are packed bits; byte equivalents may be fractional because these are control flops. Parameterized address width is `MEM_ADDR_WIDTH` (34 for this XLEN64 baseline). Prove narrowing from host address to physical address rather than truncating a final address through the old 32-bit `stride` field.

### Unified command

Existing types have wait=38 bits, prepare=48 bits, notify=39 bits. The existing unified command is `UUID_WIDTH + NW_WIDTH + PC_BITS + 3*NUM_REGS_BITS + 773` bits at XLEN64; all of it remains unchanged for improve. Append exactly 130 bits only for naive:

| Field | Bits | Meaning |
|---|---:|---|
| `naive_final_base` | 64 | Full final-output byte address; never overload 32-bit stride |
| `naive_final_stride` | 32 | Final-output row byte stride |
| `naive_terminal` | 1 | Real terminal Input closes this output tile's producer |
| `naive_source_buffer` | 1 | Operand tile-buffer owner |
| `naive_source_generation` | 32 | Exact source-buffer generation |

PSUM base remains existing 64-bit `rs1_data`, PSUM row stride remains existing 32-bit `stride`; no duplicate PSUM address field is required. Output owner derives from the existing O admission target, packet count from `eff_mt`, W/S/Z versions from existing admission waits and final-output mode from the existing naive flag interpretation. Normalize these once at the naive adapter. The controller command stage plus four-deep queues for four operand children and eight-deep external queue stores 25 command records: at most 25×130=3,250 added field bits over those same records without the appended fields. Allow at most one additional registered command output copy for each of the five child queues: five command words and five valid bits. Thus the complete command storage ceiling is `30*CMD_BITS + 5` bits, where `CMD_BITS = UUID_WIDTH + NW_WIDTH + PC_BITS + 3*NUM_REGS_BITS + 903` for naive. This permits 3,900 added field bits across records and output copies. Queue read/write pointers and occupancy add at most 38 bits (four depth4 queues: 4*(2+2+3); one depth8 queue: 3+3+4). No further command-payload register copy is funded.

### Four Input contexts

Use one four-entry context array, not the old packetizer context array plus a second improve-style array. Exact proposed per-entry ceiling:

| Contents | Bits |
|---|---:|
| Six physical address/stride fields: PSUM read base/stride, PSUM write base/stride, final base/stride | 6×34 = 204 |
| Packet count and packet index | 2×21 = 42 |
| Valid, ingress complete, read enable, write enable, final-output mode, quant direction, W/S/Z bank selects, terminal | 10 |
| Exact W/S/Z load targets | 3×32 = 96 |
| Work sequence | 32 |
| O admission target | 32 |
| Source-buffer ID and generation | 33 |
| **Per entry** | **549** |

Four entries allocate 2,196 bits (274.5 B); admission/completion/tail pointers (2 bits each) and count (3 bits) add 9 bits, for **2,205 bits (275.625 B)**. Existing packetizer metadata is `2*GEMM_ACC_MAX_CNT + 6*MEM_ADDR_WIDTH + 136` bits per entry: 362 bits at the default count width 11 and address width34, or 1,448 bits for four entries, plus existing two pointers/count 7 bits. The replacement increases this bounded context allocation by 750 bits including pointers; it adds no operand/result data. The 21-bit count mirrors improve `eff_mt`; validate legal packet-count limits at command construction.

Keep controller notification records separate: 39-bit notify plus 32-bit work identity is 71 bits each. Four entries for each of the four local children plus one active external record is 1,207 bits, before output copies and FIFO occupancy bookkeeping. Bound these too: one 71-bit registered output copy and one valid bit for each of four local inflight queues adds 288 bits; their depth4 pointers/counts add 28 bits. Allow 16 further scalar handshake/active/reservation state bits at this controller boundary. The complete notification-record/control ceiling is therefore 1,539 bits. The external single-active record is already included; there is no external inflight FIFO. The Input context does not duplicate the notify struct. Last-row admission advances the admission pointer; ordered completion advances the retirement pointer. Enqueue wins over retirement when recycling the same entry, following `VX_gemm_node.sv` lines 430–510. Preserve the registered ingress-completion cut around lines 335–346. Terminal completion cannot use a transient unrelated tagged writeback pulse.

### Four descriptors per independent Scale/Zero engine

Use a compact naive two-dimensional mapping descriptor instead of carrying the entire unified command into every stream-queue record. It covers contiguous QCOL installs and segmented QROW gathers for the fixed macro geometry; tail values are explicit. Reject unsupported bounds rather than silently wrapping.

| Source payload | Bits |
|---|---:|
| Physical source base | 34 |
| Source segment stride | 32 |
| Segment count, useful bytes per segment | 16 + 16 |
| Source-buffer ID and generation | 1 + 32 |
| **Source payload total** | **131** |

| Destination payload | Bits |
|---|---:|
| Register bank, quant direction | 1 + 1 |
| Destination byte offset and segment stride | 16 + 16 |
| Writer wait | 38 |
| Exact install generation target | 32 |
| **Destination payload total** | **104** |

S/Z identity is the engine instance, not a new field. Work identity is the queue's existing 32-bit `cmd_id`; its 32-bit internal sequence remains a distinct slot-reuse identity. For existing stream-queue declarations at lines 100–108, each descriptor is 235 payload + 32 ID + 4×32 progress counters + 32 sequence + 2 valid/fetch-done = **429 bits**. Four descriptors are **1,716 bits (214.5 B) per engine**, or **3,432 bits (429 B) for both**. This is a replacement allowance, not a claim that the old combined naive quant executor already had these exact records.

Count other queue metadata too: eight slots × (state2 + owner-command2 + owner-sequence32 + beat32) = 544 bits per engine. The declared pointer/count/sequence/handoff and registered drain metadata in the existing queue add 155 bits per engine (three command pointers6, command count3, next sequence32, handoff count32, slot count4, two slot pointers6, drain valid1/slot3/beat32/sequence32, held request-slot valid1/index3). Thus queue descriptors plus these explicit ownership/control records total **2,415 bits per engine, 4,830 bits (603.75 B) for both**. The additional finite adapter allowance below includes lane tags, request-pipeline records, byte enables and registered metadata copies. This corrects the initial queue subtotal by including the four held-request-slot bits declared around line 307. This remains a source declaration/allocation ceiling, not a mapped flop count.

Payload storage is geometry-specific: the two-engine proposal is **896 B at MXU16** versus old combined quant 928 B, and **1,792 B at MXU32** versus old 1,856 B. Each engine has eight response slots of one native beat (32/64 B), one registered RAM output beat, and four-deep 8-byte lane FIFOs with one head copy per lane (four/eight lanes). Thus per engine: MXU16 256+32+128+32=448 B; MXU32 512+64+256+64=896 B. These include every response FIFO/RAM output payload copy; control allowances cannot finance an additional data register. Metadata cannot be used to hide operand bits. No new sink elastic payload or generalized alignment holding registers may be added outside that ledger. The 235-bit compact descriptor needs source/address/byte-enable tests in both layouts before adoption; it is a concrete design ceiling, not a proven existing adapter.

### Frozen adapter, lane-control, output-copy and PERF allowance

This is an explicit conservative allocation for the proposed compact adapter, not a claim that these records all exist or must be implemented. The RTL can omit unused copies; it must not exceed either the per-category count/width or total without revising the allocation before integration. There is no unbounded pending table. Let `L` be the number of physical 8-byte lanes (4 for MXU16, 8 for MXU32), `B=8L` the native beat bytes, with eight source slots and four descriptors per engine in both configurations.

| Adapter control allocation per engine | Exact allowed records | Bits |
|---|---|---:|
| Registered descriptor/output metadata copies | Two copies of source131 + destination104 + work ID32 + internal sequence32 + beat index32 + valid1; these cover fetch and install/FIFO-output copies | 664 |
| Segment/address progression | Two physical addresses34 each, segment index16, source and destination byte offsets16 each, remaining segment count16, source and destination remaining-byte counts32 each | 196 |
| Registered source/install completion identities | Two records of valid1 + work ID32 + sequence32 + buffer1 + generation32 | 196 |
| Writer-release state | Wait38 + released1 + install generation32 | 71 |
| Registered install-stage metadata | Destination104 + beat index32 + sequence32 + valid1 + last1 + byte mask B; operand bits are already in RAM output payload allowance | 170+B |
| Per-lane request stage/control copy | Address34 + byte mask8 + slot3 + locally retained sequence32 + valid1; no read-request data register | 78L |
| Per-lane response FIFO control and output copy | Four entries plus one registered head, each slot3 + sequence32 + beat32 + byte mask8 =75; read/write pointers2 each, count3, output valid1 | 383L |
| Eight-slot lane-join control | For each slot and lane: arrived1 + byte mask8 + slot3 + locally retained sequence32; response data resides exclusively in allocated response/FIFO payload | 352L |
| **Adapter subtotal** | **1,297+B+813L** | **4,581 / 7,865** |

The slot-plus-sequence allowance describes local ownership/control; it does not require adding a 35-bit tag to the shared LMEM bus. A three-bit physical source-slot tag can select an owned sequence from the table, provided the request/response contract forbids reuse until that response is captured. The explicit generation and sequence records preserve the independent stale-owner checks. A different tag mapping must fit the same bound and prove the same ownership; do not change improve tags.

FIFO head/output copies are charged separately from entry storage: five 75-bit lane-control records include four live FIFO entries plus the registered head; the two 332-bit compact descriptor copies cover possible registered fetch/install metadata outputs in addition to the four stream-queue descriptors. There is no additional descriptor FIFO hidden in the adapter allowance. Controller child-queue and inflight FIFO output copies are separately bounded above (five complete command words plus four 71-bit notify records and their valid bits); they must not be duplicated into another uncounted executor queue.

| Per-engine control ceiling | MXU16 | MXU32 |
|---|---:|---:|
| Stream queue, including slot and held-request metadata | 2,415 bits | 2,415 bits |
| All compact adapter/lane control above | 4,581 bits | 7,865 bits |
| **Functional engine control total** | **6,996 bits (874.5 B)** | **10,280 bits (1,285 B)** |
| PERF enabled: ten 44-bit counters plus eight registered event/active flags | 448 bits | 448 bits |
| **Total with PERF, per engine** | **7,444 bits (930.5 B)** | **10,728 bits (1,341 B)** |
| **Both engines, functional / with PERF** | **13,992 / 14,888 bits** | **20,560 / 21,456 bits** |

The PERF allowance follows the ten existing transfer/byte/active/source/destination counters in `VX_lmem_dma_misal.sv` (for example lines 1110–1120), `PERF_CTR_BITS=44` in `VX_gpu_pkg.sv:56`, and conservatively allows the eight event/active flags used by its existing non-overlap wrapper around lines 443–446. PERF is zero when disabled. These are per-engine counters only; existing node/controller aggregate PERF remains in its separately preserved scope. Simulation-only waveform assertions and payload scoreboards are excluded from synthesis, not disguised as functional control.

These ceilings are deliberately conservative, including local ownership duplication that may optimize away. They are **not** a latency/cost prediction or an assertion of equal naive metadata cost: replacement independent engines can increase control while staying within the frozen explicit bound. Actual P1/P2 elaboration must publish a declaration ledger separating engine records, controller queues/output copies, global source-generation joins and bank-commit accounting; all operand-bearing fields count toward the separate 896/1,792 B payload ceiling regardless of their signal name. No capacity may be traded between payload and control. No improve allocation changes are permitted.

## Physical completion control path

Implement the exact guarded bank-commit return from `p0-visibility.md` and the external LOAD contract in `p0-load-visibility.md`: classify actual LMEM bank writes using the existing original port and arbitration route tags. Encode each return as `{kind[1:0], psum_set}` with kind none/PSUM/final/DMA. This retains three bits per bank, with either direct wires or one counted register stage (48 bits at 16 banks, 96 at 32). Normal-origin DMA writes are distinct from CPU writes and GEMM-priority writes. No result payload returns to a producer; do not widen improve tags or use discarded request flags.

Reserve writes once on first presentation and retire reservations only on matching bank commit, including simultaneous reserve/commit next-count arithmetic. Retarget PSUM set-pending checks to this endpoint. A terminal producer-close record must also prove conversion holders cannot create a future unreserved write. Single PBUF/OBUF owner plus carried generation makes bounded aggregate outstanding accounting valid; assert that invariant. If implementation introduces multiple owners it must supply exact identity rather than pretending the aggregate remains sufficient. Retain G1 notification until its owned completion is consumed. O remains the source-read retirement endpoint, not HBM visibility.

For external LOAD, add only a 12-bit pending-LMEM-word counter and one wide-request reservation bit to `VX_dma_node` under `GEMM_NAIVE`. Cap credits at 4,095 words; reserve all active physical lanes before partial scatter begins, backpressure first presentation if credits are insufficient, and retire only classified DMA bank commits. Hold the existing worker-done/frontend handshake until this owned count drains; the single worker remains in its existing S_DONE state, retaining the existing descriptor owner. Its next descriptor cannot start before this fence. T0/T1's four-load join therefore observes fenced real completions. The 13-bit control allowance adds no payload, owner tags or queue entries. Credit arithmetic, partial scatter, reset/quiescence and CPU/GEMM-write exclusion require directed implementation tests. The baseline worker-done gap does not by itself prove its later polled T notification was premature.

Bound the associated T-ready join bookkeeping to 74 bits: two records of generation32, completed-member mask4 and published1. An active LOAD receipt may use at most 36 additional bits (generation32, buffer1, member2, valid1) only where this identity is not already retained in a counted command record. Thus the conservative external LOAD fence plus T-ready bookkeeping ceiling is 123 bits, including the 13-bit fence above. Do not duplicate an already retained receipt or count that fence twice. The bank-return register allocation is shared and separate. See `p0-load-visibility.md` for exact source-generation ownership and directed tests.

## Ordered integration and verification boundaries

1. Freeze P0 artifacts and compare improve preprocessing/elaboration before and after each shared-file edit. Assert `$bits` for common improve types, 21 counters and absence of every naive field/port. Run the fixed improve normalized-cycle and synthesis-cost checks; any delta requires isolation, not compensation.
2. Add guarded schema/interface declarations and naive metadata controller shell. Compile both backends at TH16/MXU16 and MXU32. Directed child tests cover all valid wait slots, SRC_FREE decoding, independent progress, simultaneous updates, bounded queues and no TMEM scheduler instance. Do not enable the new FSM until actual executors match the interface.
3. Implement the four-context adapter with full-width addresses and owned completion. Test simultaneous enqueue/admit/retire, full queue recycling, output backpressure, ordinary ingress retirement, terminal hold and work identity. Include an address above 4 GiB so the historical final-address truncation cannot pass through LMEM aliasing.
4. Integrate independent S/Z adapters and compact descriptors within the payload/metadata ledgers. Test S-blocked/Z-progress and reverse, QCOL/QROW, both weight layouts, partial masks, source-slot reuse and writer fences. Re-run immutable expected-payload checks on actual accepted installs; static metadata inspection is insufficient.
5. Integrate bank commit and source-generation joins before enabling G1/SRC_FREE consumers. Test delayed cross-port bank writes, simultaneous reserve/commit, PSUM hazards, producer-close/conversion races, final STORE reads and at least three region reuses. Demonstrate no fence waits on its own future consumer.
6. Connect the metadata-only N-fast FSM and remove legacy synchronization routes. Validate actual emitted commands against `p0-contract.py`, then numerical and no-reset lifecycle tests, fixed-window service/overlap gates and improve preservation. Existing service-baseline legacy metadata rejection is expected only for the old baseline; the candidate must pass the real contract.

Every test above is a required implementation boundary, not a claim of a completed test. No baseline threshold, fixed command order, independent S/Z requirement, single physical output region or improve-preservation requirement is relaxed by this map.

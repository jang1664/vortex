# P0 region, N-fast stream, and resource dependency model

Run `python3 agent-tasks/gemm-naive-improve-baseline/p0-contract.py` from the repository root. The script writes `p0-contract-results.json` and `p0-contract-inputs.json`. It checks exact source anchors and records source SHA-256 values and anchor line numbers. This is an executable translation of the inspected formulas plus the planned metadata contract; it does not run an RTL FSM.

## Verified model results

- All 24 combinations pass: M4/K512/N512, M256/K512/N512, and M129/K160/N145; MXU16/MXU32; QCOL/QROW; both W layouts. The latter shape exercises M/N edge tiles and a shorter, MXU-aligned final K tile.
- Every allocation is disjoint and every modeled Input/W/S/Z/PSUM/final-output access envelope stays inside its physical region. Regions end at offset `0x2d000`; QCOL and QROW both allocate 184,320 bytes at MT=KT=NT=128, QBLK=32.
- Within each output-owner/N-slice pair, global K indices are exactly `0, MXU_KT, ..., K-MXU_KT`, in order. There is one terminal real Input per output tile.
- M4/K512/N512, MXU16 emits 1,024 modeled real Input commands. DMA scan is `kt -> mt -> nt` (fastest to slowest); inside a DMA tile, `nb` advances before `kb`. The requested N-fast rule concerns this microtile scan, not changing the outer DMA scan.
- Ordinals 256 through 767 contain 512 Input commands and 2,048 accepted rows of useful work. Of 511 adjacent pairs, only `(511,512)` crosses an output owner; the remaining 510 are adjacent independent N slices. A 50% overlap gate therefore requires 255 successes. This validates the plan's arithmetic without selecting pairs from timing results.
- Four output owners and 16 DMA source generations produce an acyclic planned graph of 15,465 nodes and 29,785 edges. Sixteen event schedules, with final-write and store delays up to 1,000,000 model time units, preserve every checked lifetime/ownership dependency. An injected terminal-fence wait on its own store is detected as cyclic.

`p0-contract-inputs.json` contains canonical descriptors, ordinal, current FSM work_seq, owner, buffer/generation identity, effective rows/columns, actual LMEM base formulas, and proposed admission/completion metadata. On tails, current work_seq may have gaps because it reserves the full DMA tile's maximum microtile count. Window selection uses contiguous real-command ordinals, not work_seq arithmetic.

The optional `--input-trace PATH` accepts an independently extracted JSON descriptor list in this exact canonical schema and requires exact equality. No RTL trace has yet been supplied; `rtl_trace_compared` is false. Passing the generated model file back to this option would not constitute independent RTL evidence.

## Source grounding

| Contract item | Actual source and interpretation |
|---|---|
| Allocation order and sizes | `tests/regression/fpint_gemm_ffn_hw_naive/main.cpp`, `compute_lmem_layout`: I0/I1, W0/W1, SC0/SC1, ZP0/ZP1, OBUF, PBUF, each aligned to 64 bytes |
| Outer DMA traversal | `hw/rtl/core/gemm/VX_gemm_fsm_naive.sv`, `tile_next_coords`: K DMA tile first, then M, then N |
| N-fast microtile traversal | Same FSM, `n_nt_mxu`, `n_kt_mxu`, and `mxu_linear` assignments; one real `OP_I_LDMA_ARM` in `S_MXU_ARM_GEMM` |
| Source buffer/generation | Same FSM: `buf_cur = tile_cur_q[0]`, `buf_gen(t) = (t >> 1) + 1` |
| Input address | Same FSM: IBUF + `kb*MXU_KT*2`; node sets the row stride to `KT*2` |
| PSUM address | Same FSM: PBUF + `nb*MXU_NT*MT*4`; `VX_gemm_node_naive.sv` supplies `GEMM_PSUM_DATA_SIZE` per row. Thus MXU16 row r is `PBUF + nb*16*128*4 + r*16*4` |
| Final-output address | Same FSM: OBUF + `nb*MXU_NT*2`; node supplies row stride `NT*2` |
| W address | Same FSM: non-transposed `kb*MXU_KT*(NT/2) + nb*MXU_NT/2`; transposed `nb*MXU_NT*(KT/2) + kb*MXU_KT/2` |
| S/Z addresses | Same FSM QCOL group/column offset or QROW K-row/N-group offset in `lmem_sc_mxu` and `lmem_zp_mxu` |
| Current RID values | `hw/rtl/VX_gpu_pkg.sv`, `GEMM_RID_*`: retained IDs 0 through 20. Proposed naive-only SRC_FREE IDs 21/22 are not implemented by this model |

The JSON provenance identifies exact current anchor lines and hashes. The model checks address envelopes for complete MXU-width accesses even when effective N has a tail; it does not prove byte-enable masks, register install packing, or downstream bank behavior.

## Planned resource graph and actual producer candidates

| Resource | Planned producer and consumers | Current source mapping / missing implementation |
|---|---|---|
| T0/T1, IDs 0/5 | Join four visible I/W/S/Z external loads of one buffer generation; all local source reads wait for this generation | Existing FSM external load sequence followed by `S_PRE*_LD_DONE_NTF`; `VX_gemm_dma_ctrl_naive` completion. A real-command metadata join with proven physical visibility is still required |
| W0/W1, IDs 1/6 | Actual register install, then matching Input consumer; later install waits for previous consumer of that bank | Node `u_weight_gather_dma`, `weight_dma_ctrl_if.done`, and the existing operand scheduler bank-generation machinery. Legacy node notification is a separate queued command |
| SC0/SC1, IDs 11/13; ZP0/ZP1, IDs 12/14 | Independent scale/zero installs and matching consumers, with distinct writer fences | Current node has one `u_quant_param_lmem_dma` / `quant_param_dma_ctrl_if`; independent engines and metadata producers remain to be implemented |
| Consume W/SC/ZP, IDs 15–20 | Last actual consumer of the exact register bank/generation releases that bank to its next writer | Must use existing scheduler consumption events with exact bank identity. This DAG models consumption after ingress; it does not establish the RTL event boundary |
| G0, ID 3 | Nonterminal real Input registered-ingress completion; ordered progress only | Current node `input_read_flag.done` and `input_notify_pending_r` include legacy serialization. The new producer must be separated from compute retirement |
| G1/OUTPUT_READY, ID 8 | Terminal real Input's closed-producer marker plus every matching output-owner write completion; STORE waits for this | Node `psum_wr_lmem_bus_if[p]` lane handshakes and reserve/pending machinery are candidates, but downstream visibility and tile tagging are not proved here |
| O/STORE_DONE, ID 4 | Actual completed external STORE; every Input for next owner waits for previous owner O, so PBUF/OBUF cannot be reused early | `VX_gemm_dma_ctrl_naive.store_done` currently identifies cache-path descriptor retirement. Its source comment explicitly denies that this guarantees arrival at HBM. The required visibility/ordered-read endpoint still needs the dedicated hardware proof |
| SRC_FREE0/1, proposed IDs 21/22 | Join all four resources' actual captured source responses, qualified by buffer and generation, with the expected read set closed | Node local Input/W/quant DMA response capture paths. Existing work_seq or install completion alone is not this event. Proposed generation joins remain unimplemented |
| ACC_FREE, IDs 9/10 | No naive producer or consumer | Remains improve-specific; no synthetic copy/notify command is modeled |

The event graph attaches source-generation release to the closed set of real reads and keeps it distinct from register-bank consumption. A refill of DMA tile d waits for source release of d-2, i.e. the previous generation of the same physical buffer. Each Input waits for its own source generation, exact installed operands, and STORE_DONE of owner t-1. Consecutive Inputs retain ingress order but do not wait for previous compute completion. Same-owner/same-N-slice compute also waits for its previous K contribution's modeled visible PSUM write.

A tile's G1 node joins *every* modeled write for that owner, plus a closed-producer marker carried by its terminal real Input. It never waits for its own store. OBUF store follows G1, and reuse follows store. Source-only reads cannot extend the final-write join because they do not create PSUM/final writes.

## Scope, unresolved proof, and plan consistency

No numerical inconsistency was found in the specified regions, command count, or 510-pair gate. Several intentional redesign differences must not be mistaken for current RTL behavior:

1. Current naive T-ready target is `4*buf_gen+4`, and current private RID width is four bits. The planned generation-qualified T/SRC_FREE model and five-bit metadata require explicit migration; old targets must not be copied blindly.
2. Current G0/G1 alternate by compute bank with explicit NOTIFY/WAIT. The planned ordinary-ingress versus tile-final semantics are different producers and require new routing.
3. Current store_done is not independently proven HBM visibility. The graph assumes the final chosen store-completion contract; it cannot prove that contract by naming a node STORE_DONE.
4. Early source reads in this DAG have no transport-capacity model. The acyclic partial order holds for any finite nonnegative event delays because dependencies cannot reverse; the 16 schedules are executable checks, not exhaustive timing/state-space verification. Required bounded queue/context ownership, fair shared-port arbitration, counter wrap/reset behavior, and exact physical visibility remain RTL verification work.
5. No RTL descriptor trace has been compared. Planned metadata fields in the canonical descriptors are specification, not evidence that today's FSM emits them.

These artifacts complete the software region/enumeration/DAG portion of P0. They do not close the plan's physical visibility proof, independent-DMA progress proof, source-generation hardware joins, emitted-descriptor comparison, or performance gates. No production source or RTL was modified by this subtask.

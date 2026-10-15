# FP16 x FP16 GEMM in the naive GEMM node

Status: FPFP implementation and scoped VCS WLOAD=1/4 comparison complete (2026-10-14). Results: `agent-tasks/naive-fpfp/RESULTS.md`; execution log: `agent-tasks/naive-fpfp/STATUS.yaml`. FPGA feasibility/PnR remains a separate future step.

Execution coverage: M4/K256/N256 covers multiple K/N macrotiles, M129/K32/N32 replaces the expensive full M256/K256/N256 test for multi-M coverage, and M1/K384/N160 covers three K tiles. All ran successfully. Nonzero job-level partition offsets and Inf/NaN semantics were not validated; see the result report for exact coverage and limits.
Date: 2026-10-14.

## 1. Scope and recommended design

Add a **naive-only FP16 x FP16 compute path** behind the existing GEMM job interface. Keep the FSM-generated LOAD / WEIGHT / INPUT / STORE micro-operations, dependency tracking, and accumulator backends. Replace the quantized arithmetic path for FP16 jobs, and omit all scale/zero-point work.

The proposed mathematical contract is `C[M,N] = A[M,K] * B[K,N]`:

- Both operands are FP16; products, reduction, and partial sums are FP32; final output is FP16 with round-to-nearest-even. The user confirmed FP32 accumulation with FP16 conversion only at final output; do not convert intermediate K-tile partial sums to FP16.
- No quantization block, scale, or zero-point is consumed in FP16 mode.
- FPFP has no transpose mode. B uses fixed row-major `[K,N]` storage.
- Preserve the existing naive row-major A/C storage contract, origin/target dimensions, partition offsets, and DMA tile ordering. Do not import improve-specific packed layouts or introduce LLM-specific fields.
- Existing FP16 x INT4 jobs remain supported when `GEMM_NAIVE_ENABLE` is enabled. TCU remains independently available; moving all FP GEMMs to the new path is a separate software policy decision.
- FP16 mode is unsupported on improve. Its RTL, interfaces, storage widths, latency, and hardware cost must remain unchanged.

**Confirmed configuration contract:** `GEMM_NAIVE_ENABLE` enables naive FPINT and `GEMM_NAIVE_FP16_ENABLE` enables naive FPFP. They are independent compile-time capabilities. Neither implies the other; all four combinations are supported from the first implementation.

| `GEMM_NAIVE_ENABLE` | `GEMM_NAIVE_FP16_ENABLE` | Hardware configuration |
|---|---|---|
| Off | Off | No naive GEMM datapath or naive-only shared infrastructure; other independently configured compute engines remain available |
| On | Off | Existing naive FPINT path only |
| Off | On | Naive FPFP path only; no INT4 arithmetic, weight bank, or quantization-specific resources |
| On | On | Both arithmetic paths, sharing naive control/DMA/ACC infrastructure; select the format per job |

Shared naive infrastructure is present when either capability is enabled. Runtime format selection is needed only in a dual-format build; single-format builds specialize to their enabled path. An FPFP-only image is a first-class configuration, not a later pruning optimization.

All names introduced in this document are proposals, not existing APIs.

## 2. What the current RTL actually does

| Area | Current implementation | Consequence |
|---|---|---|
| Naive control | `VX_naive_gemm_control` instantiates `VX_gemm_fsm_naive_meta`, metadata controller, and source join | Extend this active producer, not just the older/general `VX_gemm_fsm` |
| Arithmetic | `VX_gemm_node_naive` instantiates `VX_gemm_compute_core`; that core instantiates **`VX_gemm_tree_v1`**, with `VX_gemm_weight_regs_v1` and `VX_pe_tree_new` | `VX_gemm_tree_v2` and the old synthesis unit wrapper are not the active naive arithmetic boundary |
| Quantized calculation | Input scaling for QROW, prealignment/block selection, integer-weight tree, zero-point correction, integer-to-FP conversion, QCOL output scaling | Neither changing `W_BIT_WIDTH` to 16 nor supplying scale=1/zero=0 implements FP16 multiplication |
| Weight addressing | Metadata FSM, external DMA executor, and weight gather use INT4 byte calculations | All three levels need datatype-aware geometry |
| Dependencies | WEIGHT → SCALE → ZERO → INPUT; source join tracks four source readers | Simply removing scale/zero commands would leave completion/dependency waits unresolved |
| Accumulator | `VX_gemm_acc_if` separates tagged reads/writes and transaction ownership from the physical backend | Reuse FP32 accumulation ownership and internal-ACC/LMEM adapters |
| Numerical helpers | `VX_fp16_mul` returns **16 bits**; `VX_fp16_arith.vh` provides corrected conversion helpers; `VX_tcu_fedp_dsp` widens half operands before FP32 multiplication/reduction | Reuse numerical primitives, not the FP16-result multiplier as a widened-product primitive |

Important source anchors, relative to the repository root:

- `hw/rtl/core/gemm/VX_gemm_node_naive.sv`: weight-lane geometry, executor wiring, compute core, ACC adapters.
- `hw/rtl/core/gemm/VX_gemm_fsm_naive_meta.sv`: `make_command`, `job_q`, LOAD member sequencing, SCALE/ZERO transitions and geometry assertions.
- `hw/rtl/core/gemm/VX_naive_external_dma_executor.sv`: `T_WEIGHT` segment size, padding, DRAM and LMEM strides.
- `hw/rtl/core/gemm/VX_naive_weight_executor.sv`: `seg_size = MXU_COL/2` and gather setup.
- `hw/rtl/core/gemm/VX_lmem_weight_gather_dma.sv`: fixed `WEIGHT_ROW_BYTES`, `ROWS_PER_GROUP`, response assembly and beat-count assertions.
- `hw/rtl/core/gemm/VX_naive_source_join.sv`: completion requires captured masks for all four engines.
- `hw/rtl/core/gemm/VX_gemm_compute_core.sv`: prealignment/tree/scaling path; tagged post-transaction join; FP32 accumulator; pipeline-empty accounting.
- `tests/regression/fpint_gemm_ffn_hw_naive/{common.h,kernel.cpp,main.cpp}`: job ABI, submission, scratch layout and reference generation.

## 3. Reuse and new implementation boundaries

| Component | Decision | Required work |
|---|---|---|
| Job allocation, entry ownership and completion | Reuse | Capture datatype at job acceptance; prevent changes until full drain |
| Naive metadata FSM and macro/micro tile loops | Extend locally | Datatype-dependent weight bytes; skip scale/zero LOADs and register commands |
| Naive command scheduler and source lifetime accounting | Reuse with explicit active-source metadata | FPFP requires Input+Weight only; disabled sources must not delay buffer release |
| External DMA and AXI/LMEM ordering protection | Reuse | Change descriptor geometry, not the ordering protocol |
| Weight gather transport | Extend existing gather/assembler | Separate source element width, physical beat width, and rows installed per beat |
| Weight register structure | Reuse parameterized `VX_gemm_weight_regs_v1` | Instantiate a 16-bit bank for FPFP; preserve INT4 bank and its load behavior |
| Input transport | Reuse FP16 payload capture | Route raw FP16 to FPFP instead of prealignment or QROW scaling |
| FPINT prealign / INT tree / zero correction / scaling | Preserve under `GEMM_NAIVE_ENABLE` | Absent from FPFP-only builds; idle for FPFP jobs in dual-format builds |
| FPFP multiplier/reduction tree | New naive-only module | FP16-to-FP32 conversion, FP32 products, FP32 reduction, valid/tag pipeline and output credits |
| FP32 post-processing and ACC transactions | Reuse through a guarded result insertion point | Associate FPFP results with the existing transaction tags and accumulator ownership |
| Output conversion, writeback, progress and final store | Reuse | Retain existing corrected conversion and tail-store rules |
| Host/device test support | Extend existing naive app | FP16 B generation, datatype selection, scratch allocation, numerical reference |

Do not duplicate the whole GEMM node, DMA engine, or accumulator. Do not instantiate an entire SIMT TCU under the GEMM node. Its instruction/fragments interface and issue mechanism are not the FSM interface we need.

## 4. Job mode and compatibility

1. Define an explicit operand format, initially FP16_INT4 and FP16_FP16. Do not overload existing quantization or layout fields to mean datatype. The FPFP interface exposes no transpose option; keep any legacy transpose handling confined to INT4 compatibility.
2. Keep current job register numbering. Prefer a reviewed unused CONTROL bit so existing `CONTROL=1` submissions still select INT4, and no shared register-array resize is needed. Audit the allocator's owner/generation masks before assigning its exact bit. **Register 42 is not globally free:** the improve FSM uses it as `CFG_R_LOG2_DMA_NT`; register 43 is output progress. Do not repurpose either casually.
3. In dual-format builds, latch the mode in the naive invocation state and propagate it to descriptor creation and compute admission. Because jobs are serialized through drain, a latched mode can serve the job; do not widen every shared control struct automatically. Single-format builds specialize this selection at compile time while validating that requests use the supported format.
4. If a per-command mode field is necessary for queued commands, keep it inside the naive feature guards. Initialize it explicitly for every producer.
5. FPINT-only builds retain the old arithmetic implementation and bus widths. FPFP-only builds omit INT4 arithmetic, quantization executors, qparam buffers and their dependency bookkeeping. With both capabilities off, omit the naive node and its dedicated resources. Reject unsupported format requests in software and RTL validation where the node exists; software must reject dispatch to an absent node. Do not silently execute another format or wait forever.
6. FPFP ignores QDIR, qparam addresses and qblock fields, and bypasses quantization-specific admission assertions. Null qparam pointers must be legal and must never produce a memory access. QCOL/QROW have no meaning for FPFP; see section 4.1.
7. Reset and job acceptance initialize the relevant ownership state. INT4 → FP16 → INT4 must work without resetting the node or flushing unrelated caches.

The first implementation instantiates separate INT4 and FPFP arithmetic/weight banks only when both capabilities are enabled, with one selected per job and shared DMA/ACC infrastructure. Single-format builds instantiate only the requested bank and arithmetic. Sharing multipliers between fundamentally different arithmetic schemes is a separate area optimization. Quantization support still occupies resources in a dual-format image even when its job is idle.

The current source uses `GEMM_NAIVE` guards in many places. Audit those guards during implementation: shared node/control/DMA/ACC code must depend on the OR of the two capabilities, INT4-specific code on `GEMM_NAIVE_ENABLE`, and FPFP-specific code on `GEMM_NAIVE_FP16_ENABLE`. Do not make FPFP depend on enabling FPINT just to reach the shared code. Define any internal shared-presence guard separately from arithmetic capability, and migrate existing config/source-list selection consistently. Apply this split only to naive-specific paths; preserve the separately selected improve implementation.

### 4.1. QCOL/QROW apply only to FPINT

FPFP is a separate arithmetic format, not a QCOL or QROW variant. Do not select QCOL as a default FPFP execution path, and do not encode FPFP as an extra QDIR value. Operand format selects the arithmetic path first; QDIR is interpreted only inside the enabled FPINT path.

| Layer | FPFP handling |
|---|---|
| Software API | Expose no QDIR/QCOL/QROW or QBLK option for FPFP. If a shared legacy job register layout retains these fields, initialize them deterministically; their values have no effect on FPFP execution |
| Job decode and FSM | Ignore QDIR for FPFP. No QROW/QCOL-dependent loop bounds, qparam geometry, addresses, or validation; generate A/B loads and compute/store operations only |
| Weight transport | Fixed row-major `[K,N]` addressing and fixed row-loading direction, independent of QDIR and quantization-related compile-time switches |
| Arithmetic | Raw FP16 A and B → widened products → FP32 reduction → FP32 accumulation. Neither QROW input scaling nor QCOL output scaling/zero-point correction is part of this path |
| Dependencies | No SC/ZP ready checks, generation waits, consume events, or QROW/QCOL arbitration for an FPFP job |
| Build guards | FPFP-only builds contain no QDIR-dependent arithmetic/control resources. In dual-format builds, QDIR-dependent logic belongs exclusively to FPINT jobs |

Shared control structs may retain legacy QDIR bits to preserve the FPINT ABI, but FPFP consumers must not branch on them. Audit existing couplings such as `GEMM_UNIT_FORCE_QDIR_COL` when reusing modules; use an explicit fixed row-load setting for FPFP rather than making its behavior depend on a quantization switch.

Verification must show that changing retained legacy QDIR/QBLK fields for an otherwise identical FPFP job does not change its command stream, addresses, result, or deterministic simulation cycle count. Also verify that no scale/zero transaction or wait is generated. This is a compatibility test of ignored fields, not support for FPFP quantization modes.

## 5. FSM and dependency changes

For FPFP, macro LOAD emits Input and Weight only; after weight installation the micro sequence is `WEIGHT → INPUT`. Macro K/M/N scheduling, accumulation first/last semantics, source double buffering, and STORE remain unchanged.

Update the following together:

- LOAD member count and expected DMA completions.
- Input admission and true-consumer dependencies: require the correct W generation and ACC ownership, but no SC/ZP generation.
- Source join: snapshot an active-reader mask per invocation (or per source owner if needed). Compare completion masks only for active readers; still wait for producer closure and all actual A/B reads. Preserve all four readers for INT4.
- Readiness scheduler, register-busy masks, consume notifications, and executor quiescence must agree about inactive qparam children. In dual-format builds, keep qparam children idle during FPFP jobs; in FPFP-only builds, omit their resources. Do not manufacture completion events to imitate nonexistent reads.
- Weight source-read completion still means all bytes are captured in owned transport storage; weight-installed completion means the complete microtile is in the destination bank. These events remain distinct.
- Completion waits for result pipelines, ACC writes, final output DMA, and outstanding transport responses, not merely FSM command exhaustion.

These changes address a likely first failure mode: arithmetic succeeds for a tile, but the next tile or final job hangs waiting for scale/zero work that was never issued.

## 6. Weight layout, transport and memory capacity

For FPFP, B is ordinary FP16 row-major storage:

| Storage | DRAM element address | LMEM macro-tile row stride | Microtile row bytes |
|---|---|---|---|
| Fixed row-major `[K,N]` | `Bbase + 2*(k*origin_n+n)` | `2*NT` | `2*MXU_COL` |

Here k/n include the existing tile/partition offsets. DRAM stride uses origin dimensions; loop bounds use target dimensions. Keep all address calculations wide enough for current DRAM addresses.

Do not globally redefine `W_BIT_WIDTH` or `GEMM_WEIGHT_DATA_SIZE`. **Confirmed requirement: retain the existing physical memory ports and control weight-loading parallelism with `MXU_WLOAD_NUM`; test FPFP with values 1 and 4.** For a 16x16 array, one FP16 weight row is 32 B. FPFP WLOAD=1 requests 32 B through four 8-byte lanes; WLOAD=4 requests 128 B through sixteen lanes, within the existing sixteen-port LMEM infrastructure. The grouped operand payload is configurable; the physical per-port width and port count are unchanged. Existing INT4 payloads remain independently sized at 8 B/32 B for WLOAD=1/4.

Separate logical rows per install from physical transfer lanes. Adapt the existing gather response assembly and command beat accounting; reuse its tags and descriptor ownership. The FP16 weight-register instance uses a fixed row-loading direction and `MXU_WLOAD_NUM` rows per install; no runtime transpose selection is needed. If the requested grouped payload exceeds the available physical lanes, explicitly serialize it or reject that geometry; never truncate it. Keep the old gather behavior for INT4. Do not increase the physical memory port count automatically.

Requested width is not guaranteed sustained bandwidth. With the current NT=128 FP16 LMEM row stride of 256 B and sixteen 8-byte-interleaved banks, the four rows of a WLOAD=4 group request the same four banks. The capacity preflight finds four requests per bank, versus one for WLOAD=1. Measure bank contention and actual cycles; do not assume a 4x speedup or silently add a new swizzled layout.

With a 128x128 L1 DMA weight tile:

| Storage item | INT4 | FP16 |
|---|---:|---:|
| One B tile | 8 KiB | 32 KiB |
| Double-buffered B tiles | 16 KiB | 64 KiB |
| Double-buffered S and Z, QBLK=32 | 4 KiB total | 0 |
| B+S+Z scratch total | 20 KiB | 64 KiB |

Thus removing qparams does **not** compensate for weight growth: this example requires 44 KiB more operand scratch, before allocation alignment. Input, output, partial-sum storage and stack reservations must be added separately. The current host allocator reserves 64 KiB for two A tiles, 32 KiB for C, and 64 KiB for partial sums at these tile sizes. Whether a backend can avoid a reservation is a separate, explicit change.

Recompute scratch bases with the current checked allocator and check bank/port mappings; never retain INT4 offsets for larger FP16 buffers. Host and RTL must agree on padded LMEM macro-tile strides and valid DRAM extents. Preserve existing tails and store masks, and ensure padded lanes cannot inject garbage or NaNs.

### 6.1. Mandatory capacity check before implementation

Before implementing the FPFP datapath, validate the scratch layout for the intended configurations. If capacity is insufficient, reduce the DMA macro-tile dimensions; do not increase transfer width or assume extra LMEM. This preflight is a required gate, not an optional later optimization.

With double-buffered FP16 A/B, one FP16 C tile, and the current host's FP32 partial-sum reservation, the unaligned scratch requirement is:

`scratch_bytes = 4*MT*KT + 4*KT*NT + 6*MT*NT`.

| DMA tile `(MT,KT,NT)` | A buffers | B buffers | C buffer | PSUM reservation | Total before other reservations |
|---|---:|---:|---:|---:|---:|
| `(128,128,128)` | 64 KiB | 64 KiB | 32 KiB | 64 KiB | 224 KiB |
| `(128,64,128)` | 32 KiB | 32 KiB | 32 KiB | 64 KiB | 160 KiB |
| `(64,128,128)` | 32 KiB | 64 KiB | 16 KiB | 32 KiB | 144 KiB |
| `(128,128,64)` | 64 KiB | 32 KiB | 16 KiB | 32 KiB | 144 KiB |

Initial static check: both `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr_v3.sh` and `configs/naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_tcu_base_pnr_v3.sh` specify `LMEM_SIZE=1310720` (1280 KiB). The 224 KiB allocation is below that physical capacity, leaving 1056 KiB **before** other reservations. This checks the byte budget for those configurations, not complete address safety or final configuration selection. Use `LMEM_SIZE`, not the larger `1 << LMEM_LOG_SIZE` address envelope.

The preflight report must also check actual buffer intervals, alignment, LMEM offsets, live kernel stack/other allocations, physical bank mapping, and ACC capacity/addressing. Keep the current PSUM reservation in the budget unless its removal is separately proven safe for the selected ACC backend. For dual-format jobs, reuse scratch across drained jobs when legal; do not sum mutually exclusive job allocations unnecessarily.

Preflight completed for the two configurations above: `agent-tasks/naive-fpfp/capacity_preflight.py` and `.json` record nonoverlapping, aligned scratch intervals at offset zero, bank depths within physical capacity, and unique ACC locations with maximum depth index 511 < 1024. Stack initialization places stacks below `STACK_BASE_ADDR`; the LSU routes only `[LMEM_BASE_ADDR, LMEM_BASE_ADDR+LMEM_SIZE)` to LMEM, so the default stack and upward scratch allocation do not overlap. This standalone-app check assumes no concurrent scratch allocator. Keep 128x128x128 tiles for implementation.

The smaller tiles above are budgeting candidates, **not currently validated settings**. `VX_gemm_fsm_naive_meta` currently asserts MT=KT=NT=128, and the host header also fixes those dimensions. If a smaller tile is necessary, update the naive host/FSM/DMA geometry consistently, audit loop counters, dependency identities, ACC strides and tail handling, and validate divisibility by the microtile dimensions. Keep the current FPINT baseline and improve geometry unchanged; any FPFP-specific tile selection belongs to the naive extension. Record the chosen tile and capacity evidence before proceeding to arithmetic implementation.

## 7. FPFP arithmetic and accumulator integration

Implement a weight-stationary vector-dot datapath matching the existing array geometry: for each admitted A row slice, produce `MXU_COL` results, each reduced over `MXU_ROW` K elements. Reuse weight-bank selection and the existing column transport organization where applicable, but derive latency from the new arithmetic pipeline.

Recommended initial numerical implementation:

1. Widen both FP16 operands exactly using the corrected conversion semantics in `VX_fp16_arith.vh` / the TCU implementation. Preserve zeros, subnormals, Inf and NaN classification.
2. Use existing FP32 multiplier primitives, then a pipelined FP32 adder tree. Finite FP16 products fit exactly in FP32; **do not round each product to FP16** using `VX_fp16_mul` and then widen it.
3. Feed each tagged FP32 dot result into the existing post-transaction/ACC join and accumulator, then use the current final-output conversion.
4. Keep reduction order specified in the reference. A tree, a serial CPU loop, and TCU reduction need not be bit-identical. Define the treatment of exceptional values and report NaN/Inf explicitly rather than letting tolerance checks accept them.

The integration point is the FP32 dot-result side of the current post-transaction join, after quantized scaling would normally finish. It is **not** safe to mux only the data signal there: current allocation, metadata timing, credit reservation, bypass/forwarding, and accepted-versus-retired accounting depend on the existing pipeline. Add a naive-only FPFP admission/result adapter carrying the existing ACC transaction tag and control; allocate the transaction exactly once and retire it exactly once. Preserve current INT4 schedules outside that guarded branch.

Reuse ACC backends without assuming a one-cycle read or in-order memory response. Exercise same-address RAW, bank conflicts, delayed reads, output backpressure, and repeated K-tile accumulation. Recalculate result credits from multiplier/tree latency and initiation interval; do not reuse INT-tree delay constants unchanged.

This adds substantial arithmetic: a fully spatial AxA dot array has A² multipliers and A*(A-1) reduction adders, plus cross-slice accumulation. At A=16 that is 256 multipliers and 240 tree adders; these are logical operator counts, **not DSP/LUT estimates**. Removing scale/zero work does not make this automatically smaller or faster than FPINT or TCU. First validate the widened-product implementation; a compact FP16-input/FP32-output multiplier can be considered later if FPGA area requires it.

The existing naive metadata FSM currently asserts 128x128x128 macro tiles and a 16/32 square microtile. Do not claim arbitrary power-of-two A support from this change alone. Keep the datapath parameterized, validate existing supported geometries, and treat relaxing the frozen FSM/gather/port constraints as a separate task. Preserve the existing equality constraints rather than adding more unrelated hardcoding.

## 8. Implementation sequence and verification gates

| Step | Changes | Completion evidence |
|---|---|---|
| 0. Baseline | Record source/config revisions, selected RTL and naive INT4 cycles | Repeatable baseline before RTL changes |
| 0a. Capacity preflight | Check configured LMEM/ACC and all live allocation intervals; select smaller FPFP DMA tiles only if necessary | Documented capacity/address-safety PASS and agreed tile geometry before FPFP implementation |
| 1. Contract and software | Implement independent capability guards and mode encoding; add FP16 mode to existing naive regression app, FP16 B and reference, scratch sizing | All four configurations elaborate; host checks layouts, bounds and unsupported modes; old FPINT app invocation unchanged |
| 2. Control and DMA | Update naive FSM, external weight DMA, gather, active-source masks and qparam bypass | VCS command/transport tests show only A/B reads and correct fixed row-major weight addressing |
| 3. Arithmetic unit | Add FPFP bank/tree with conversion and valid/tag control | Directed and seeded-random dot-product tests, including subnormals and stalls |
| 4. Integration | Connect FP32 results to shared ACC ownership/join/output path | End-to-end VCS PASS, no lost/duplicate writes, clean full drain |
| 5. Compatibility and performance | Alternate formats, run old naive tests and improve identity checks | Numerical PASS; measured cycles and no unintended improve changes |
| 6. FPGA feasibility | Only after simulation, assess enabled naive resource/timing results | Area/timing measured before promising a replacement for TCU |

Use configured, isolated build directories for each configuration. Source the matching config before tests. Use `ci/run_black.sh xrt-vcs-sim` for blackbox verification, with `--perf 3`; do not use simx or Verilator as a substitute. Follow the repository blackbox and RTL verification skills when executing this plan.

Extend `fpint_gemm_ffn_hw_naive` with an explicit FP16 weight option instead of copying its whole host/device implementation into another app. Reuse existing unittest fixtures under `hw/unittest/gemm_naive_meta*`, `gemm_unit_v2_backpressure`, `gemm_psum_read_ooo_join`, and `gemm_fp16_arith` as appropriate; add focused FPFP unit fixtures where the current tests only understand quantized arithmetic. A final CLI name is part of step 1, not an already supported command.

Minimum test matrix, ordered to keep debug iterations short:

| Test | Purpose |
|---|---|
| Single-dot unit tests: zeros, signed values, identity patterns, cancellation, min/max normal and subnormal, Inf/NaN | Establish arithmetic behavior independently of DMA |
| Tiny GEMM, e.g. M=1/4, K=N=32 at A=16, row-major B | Addressing, FP16 bank installation, first/last accumulation |
| M=1/4/256, K=256, N=256 | Baseline comparison, two K macrotiles, multiple M/N tiles |
| M=3, K=384, N=160; partition offsets within supported alignment | Three K macrotiles, M/N tails, origin stride distinct from target extent |
| Consecutive INT4 → FP16 → INT4 jobs with different B contents | Mode capture, bank generations, stale state and complete drain |
| Randomized DMA/ACC backpressure and response order, repeated ACC addresses | Ownership, RAW forwarding, no deadlock or silent response misassociation |
| FPFP qparam pointers zero or outside allocated operand buffers | Prove no qparam memory transaction is issued |
| Identical FPFP jobs with different retained legacy QDIR/QBLK fields | Identical commands, addresses, outputs and deterministic cycles; no quantization-dependent waits |
| All four capability combinations and unsupported format requests | Correct resource presence/absence, FPINT-only compatibility, FPFP-only functionality, dual-format switching, and rejection when unavailable |

Use an arithmetic-order-aware reference for bit checks and a high-precision mathematical reference for error reports. Record mismatch count, max absolute/relative error, and NaN/Inf counts. Do not exclude subnormal inputs: their earlier failures are a reason to test them explicitly. Validate both internal-ACC and LMEM-ACC paths if both are advertised as supported.

Compatibility gates:

- Existing naive INT4 functionality must pass when enabled; FPINT-only selected RTL should remain unchanged. Report any INT4 cycle change in dual-format builds rather than hiding it behind an FPFP result.
- Check elaborated resource presence for every capability combination: no INT4/qparam resources in FPFP-only builds, no FPFP resources in FPINT-only builds, and no naive-only resources with both disabled. Test FPFP independently of FPINT from the first implementation.
- All naive additions to shared files must be compile-time guarded and absent from improve elaboration. Compare selected/preprocessed RTL, interfaces/widths, queues, pipelines and handshakes, and require zero improve GEMM/core-cycle delta under identical conditions.
- **Do not run improve GEMM-node synthesis** to establish this identity. Preserve it structurally; new-feature FPGA feasibility work concerns the enabled naive implementation.

## 9. Decisions and easily missed requirements

| Item | Proposed answer / remaining decision |
|---|---|
| FPINT/FPFP hardware selection? | Confirmed independent `GEMM_NAIVE_ENABLE` and `GEMM_NAIVE_FP16_ENABLE`; support neither, either one, or both. Only dual-format builds need runtime path selection |
| Output/accumulation precision? | Confirmed FP32 accumulation; convert to FP16 only for final output. Keep products/reduction/partial sums in FP32 |
| Matrix transpose? | No FPFP transpose mode; B is fixed row-major `[K,N]` |
| Alpha/beta, bias, activation? | Not added. Preserve current full-job output semantics and internal K-slice accumulation |
| Missing scale/zero operations? | Remove their traffic **and** their dependency obligations, not only arithmetic |
| Weight bandwidth and capacity? | Confirmed unchanged transfer width. Validate LMEM allocation before implementation; reduce DMA tile size if capacity is insufficient |
| FP16 tiny values? | Exact widening and widened products; no implicit native-half FTZ or half-product rounding |
| Dynamic K/N and multicore partitions? | Preserve origin/target semantics; do not conflate physical strides with valid loop bounds |
| Geometry portability? | Parameterize new logic, but do not promise support beyond the current FSM/transport constraints without separate validation |
| TCU replacement benefit? | Measure cycles, memory stalls, area and timing; the shared FSM does not imply equal arithmetic cost or throughput |

The largest changes are the FPFP arithmetic tree, datatype-aware weight transport, and correct removal of qparam dependencies. Job dispatch, tiling, DMA protocol, accumulation storage, and output handling should retain their existing architecture.

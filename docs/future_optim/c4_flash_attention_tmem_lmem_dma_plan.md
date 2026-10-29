# C4 FlashAttention with a simple TMEM–LMEM DMA

Status: implementation remains incomplete. The user narrowed PnR validation on 2026-10-27: use the already successful RTL simulation results, make minimal floorplan pattern corrections, and use the existing placement/crossing checks plus Vivado timing/QoR. The earlier custom reset-source equivalence, payload/valid proof and full-cone audit gates are superseded for this PnR work; their reports remain historical evidence, not prerequisites for another attempt. Do not repeat broad native metadata collection.

The expanded r3 build was deliberately cancelled. A simpler attempt was launched through canonical `build/hw/syn/xilinx/xrt/run_hw.sh` at 100 MHz with postfix `20261027_minimal_slr_r4`. It adds bank/MMIO lifted-LUT patterns; ambiguous bank suffixes are resolved only from immediate destinations using existing hierarchy-owner patterns. No RTL change or extra reset relay. Detailed reset proof code is archived outside the synthesis helper directory. This attempt completed synthesis but failed during floorplan application because the lifted-LUT destination classifier omitted bank slice0. On 2026-10-28, the user requested validating the corrected floorplan on the existing synthesized checkpoint before a fresh canonical run_hw.sh build. The slice0 arbiter now shares SLR1 with the local bank join. Native checkpoint validation also exposed Vivado resetting IS_SOFT while setting routing/exclusion properties; IS_SOFT is now set last, as confirmed by a focused property probe. Complete current floorplan application on that AFU synthesis checkpoint passed with Vivado exit 0 on 2026-10-28 at 15:06 KST, including pblocks, 28,570 marked FFs/direct pairs, and boundary nets. Repeated pure name translations are cached, and two ownership lookups use the existing array style to avoid measured Vivado dictionary overhead; no checks were removed or added. A fresh canonical run_hw.sh build then started at 100 MHz with postfix `20261028_minimal_slr_r5` (session 54094). That build finished at 2026-10-29 00:27 KST with exit 0 and an xclbin, but did not close timing at the requested clocks. Final postroute-physopt WNS is -1.659 ns and TNS -2621.004 ns; hold passes (WHS +0.004 ns, THS 0) and routing errors are zero. Vitis automatically reduced the kernel from 100 to 85.7 MHz and HBM from 450 to 357.7 MHz (xclbin.info integer entries: DATA_CLK 85 MHz, hbm_aclk 357 MHz). No build remains running. Evidence: `agent-tasks/c4-sram-flash-attention/pnr_minimal_revision2/checkpoint_fast/run.log` and `pnr_minimal_revision2/run.log`. No RTL change.

Hardware update (2026-10-29): the r5 image passed 14 actual FPGA cases, three independent full-decoder CPU comparisons, and two legacy/resident backend comparisons. This covers the standalone SRAM/attention cases and one full Llama3 decode fixture across three backends; it is not the complete nine-fixture matrix. See [functionality results and frequency recovery plan](c4_sram_fusion_r5_functionality_and_frequency_plan.md). Frequency recovery is planned; no further PnR has been launched.

Target: the C4 entry in `analysis_workspace/latency_on_hw/candidate_fpga_bins.rev8.yaml`, resolved through `ci/fpga_bin_alias_map.yaml` to `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh`. This is the TH16/MXU16 improve configuration, not the older generic `--fpga-bin C4` alias.

## Configuration name and PnR invocation

Use `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh`, which extends the existing C4 `improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp.sh` with `GEMM_SRAM_FUSION`. The rename does not change effective configuration values.

The user requires PnR to run from `/home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt` using its `run_hw.sh`:

```bash
cd /home/jaeyongjang/project.local/vortex_fpint-feat-gemv/build/hw/syn/xilinx/xrt
./run_hw.sh --config improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion --clock-freq 100 --postfix direct_reset_r1
```

Check that the postfix is unused before launch. Historical frozen evidence retains its original config paths. Producer preparation revision2 now binds the renamed config and canonical build; the earlier paused draft remains superseded history. The canonical build's XLEN64 configuration, wrapper and Makefile match current templates exactly, so they are adopted without rewriting generated files. Independent process controls and root execution bindings must pass before launching the fresh dated output.

## Reset policy update (2026-10-26)

The user permits reset distribution across SLRs without additional boundary FFs and prefers removing the added local reset relays. Use the existing core reset directly for the same-clock fusion logic. The relay removal is implemented in the current RTL. Ten positive unit cases, an expected stale-token rejection and 33 feature-off preprocessing comparisons pass. Current-source fullcore publication stress, 64 KiB early-return/readback, and normal FP32 M4/KV256 attention pass. Native physical verification remains outstanding; the frozen R11 evidence remains unchanged.

The removed `VX_sram_reset_relay` asynchronously asserted reset and delayed release by two clock edges. It was introduced for endpoint-local reset distribution, not by the attention algorithm or a separate clock-domain requirement. The existing core-reset generation and its `VX_reset_relay` instances remain the reset source.

The implementation change should:

- Remove the added `VX_sram_reset_relay` instances and their two-stage state from fusion control/DMA, MMIO buffers and links, LMEM vector transport, lane request links and bank slice transport. Connect their reset inputs to the existing core reset. Remove obsolete aliases, preservation attributes and source-list references where no longer needed.
- Reset both endpoints of each same-clock link from that common reset. Retain reset of valid bits, FIFO pointers/counts, outstanding credits and ownership/publication state, and retain handshake gating during reset. Remove only the additional reset-distribution stages, not state reset itself.
- Keep registered payload, valid, credit, response and commit crossings. The reset exception does not authorize new combinational transaction paths across SLRs.
- Remove physical requirements for separate local reset islands and their exact FDPE counts. Recompute support-root expectations from the surviving hardware while retaining non-reset metadata, RAM, ownership and transaction-crossing checks. Do not retain empty reset wrappers solely to satisfy old hierarchy counts.
- Replace the custom local-relay structural gate with checks for connection to the real core-reset source and correct state reset. Classify reset-only fanout separately from transaction data: establish its actual source and sink semantics, including any LUT implementing reset gating, instead of trusting a net name or allowing arbitrary unregistered crossings.
- Continue to check applicable timing for reset consumers. Permission to omit extra relay FFs is not a request for blanket false-path or timing waivers.

Focused verification must cover reset with requests, responses and credits pending; clearing stale transactions and ownership; no accepted/emitted transaction while reset is asserted; and correct first requests after core-reset release, without an artificial two-cycle holdoff. Reuse the existing transport/controller/publication tests and the existing core-reset pulse/clock contract. Feature-off RTL must remain unchanged.

The frozen R11 checkpoints and their failed audit results describe the old local-relay design. Preserve them as historical evidence. A successor design needs its own functional and physical results; changing this policy does not retroactively make the old audits pass.

## 1. Objective and architectural decisions

Implement tiled W4A16/KV4 attention using the existing C4 GEMM datapath and SIMD softmax. Keep scores, probabilities, PV partials, and online state on chip. Q/K/V reads and final output writes may use HBM.

The requested data path is:

```text
HBM --existing DMA--> TMEM --existing local DMA--> GEMM / ACC
                       ^                            |
                       +------ ACC output copy -----+
                       |
                  simple bidirectional DMA
                       |
                    LMEM <---- existing LMEM crossbar ----> SIMD lanes
```

Decisions for the first implementation:

1. Add no TMEM crossbar and no SIMD lane ports to TMEM. Reuse an existing single-requester TMEM bank-routing path through an exclusive-owner mux.
2. Reuse the existing, currently inactive C4 `dma_local_data_if` attachment to the LMEM crossbar. Do not widen the LMEM crossbar or increase its requester count.
3. Use one bidirectional, contiguous-copy DMA with one command and one memory transaction in flight. No scatter/gather, transpose, misalignment engine, or descriptor queue.
4. Execute GEMM, SRAM copy, and SIMD work sequentially initially. Software controls the attention loop. Do not add an attention-specific hardware scheduler.
5. Add resident GEMM input/output modes. A resident output descriptor completes after ACC-to-TMEM writes are committed, without an HBM store.
6. Keep online maximum, denominator, and output accumulation in FP32 in SIMD LMEM. SIMD performs rescaling; the first implementation needs no new arithmetic or persistent cross-job state inside GEMM ACC.
7. Put the feature behind a proposed compile-time `GEMM_SRAM_FUSION` guard, supported only with `GEMM_IMPROVE`. With the guard absent, preserve the existing RTL paths and software ABI.

This plan implements quantized C4 attention. It does not change the accelerator into an FP16-by-FP16 GEMM engine. Numerical comparison must account for quantized K/V and the existing GEMM rounding behavior.

## 2. Existing components and integration points

| Component | Current behavior | Planned use |
|---|---|---|
| `hw/rtl/core/gemm/VX_gemm_fsm.sv` | Loads inputs from HBM; copies ACC to TMEM; stores completed output tiles to HBM | Add explicit resident A and resident output modes for a single DMA tile |
| `hw/rtl/core/gemm/VX_gemm_ctrl.sv` | Controls dependency counters, descriptor retirement, and HBM output progress | Keep legacy counters; add resident completion conditions and bridge exclusion |
| `hw/rtl/mem/VX_tmem_subsystem.sv` | Existing `u_switch_input` routes one requester across TMEM banks | Share this existing route after draining the GEMM input path |
| `hw/rtl/mem/VX_tmem_switch.sv` | Routes read/write memory-bus requests using interleaved address bits | Reuse the existing instance unchanged; do not instantiate another switch |
| `hw/rtl/core/VX_core.sv` | C4 ties off `dma_local_data_if` and responds with zero on the unused DMA MMIO window | Attach the bridge and its small control block under the feature guard |
| `hw/rtl/core/VX_mem_unit.sv` | Already arbitrates SIMD and DMA per LMEM requester | Reuse `dma_local_data_if[0]`; leave the other DMA requesters inactive |
| `hw/rtl/mem/VX_local_mem.sv` | LMEM writes are posted; write responses are dropped | Expose narrowly scoped physical write-commit information for correct bridge completion and SIMD publication |
| `tests/regression/flash_attn` | Single-KV-tile experiment using global-memory buffers and output-progress polling | Reuse its reference and worker structure; add a separate resident execution mode |
| `tests/regression/layout_fused_common/layout_fused_layouts.h` | Defines GEMM A/C layouts | Reuse the exact offset helpers for SIMD access and byte-layout tests |

`VX_lmem_dma` provides a useful simple read/wait/write/wait FSM pattern, but assumes equal endpoint widths and write acknowledgements. It cannot be connected unchanged to the 32-byte TMEM / 8-byte LMEM endpoints. Prefer a small bridge controller plus existing bus/width helpers where they actually simplify the implementation. Do not enable the naive backend's general HBM/LMEM DMA node in C4.

## 3. Simple SRAM DMA

### 3.1 TMEM connection without another crossbar

Insert a feature-gated 2:1 request mux and response-owner selection immediately before the existing `u_switch_input.bus_in_if` in `VX_tmem_subsystem`:

```text
existing input_reserved_to_switch --+
                                   +-- exclusive owner mux --> existing u_switch_input
bridge TMEM memory-bus endpoint ----+                              --> existing bank port 1
```

The bridge bypasses the input read-reservation wrapper: the bridge also writes, while that wrapper is intended for GEMM input reads. Keep the existing wrapper on the GEMM branch. Select the request urgency/priority sidebands with the owner; use a fixed nonurgent bridge priority.

The existing bank route accepts reads and writes and TMEM banks return write responses. No new bank requester, bank-port arbiter, or lane-to-bank fabric is needed. TMEM retains its current six requesters per bank.

Ownership is descriptor-wide, not arbitrated on every beat:

- Acquire only after GEMM has retired and all input reservations, local-DMA requests/responses, and SLR pipeline transactions are drained.
- Do not use FSM idle alone as proof of quiescence.
- Block new GEMM descriptor acceptance while the bridge owns the route.
- Hold ownership through the last response and all bridge pipeline drains.
- Return ownership to GEMM only after completion. Never switch response ownership with an outstanding transaction.
- Keep the bridge's operation separate from GEMM input-readiness and GEMM completion counters.

Implementation detail for the SLR boundary: descriptor-wide exclusion is held
at the source controller. The memory-side mux derives its selection from the
crossed bridge request and a local pending bit, held until that transaction's
response enters the return crossing. Between bridge words GEMM remains blocked
by the source controller. This avoids sending the source owner combinationally
across the partition; it does not introduce per-beat competition with GEMM.
Source quiescence uses input acceptance-to-returned-response accounting, source
request valid, reservation occupancy, and local DMA idle. A memory-side request
valid must not be returned combinationally to that decision.

The exact drain signals must be audited in the first implementation milestone. Add a narrow drain indication if current quiescence does not cover a downstream buffer. Do not solve that gap with a new crossbar.

C4 enables `GEMM_SLR_PIPELINE`. Use the existing registered bus-cut primitives for the bridge connection when it crosses an SLR boundary. Their queues count toward outstanding work and completion; an unregistered core-to-TMEM path is not an acceptable shortcut.

### 3.2 LMEM connection

Drive only `dma_local_data_if[0]`, already connected to the DMA side of the LMEM lane arbiter. This single requester can reach every LMEM bank through the existing crossbar. Other bridge DMA ports remain inactive. SIMD continues to use its current LSU/LMEM path.

For C4 at XLEN=64:

- TMEM physical word: 32 bytes (`GEMM_INPUT_DATA_SIZE`).
- LMEM requester word: 8 bytes (`LSU_WORD_SIZE`).
- One TMEM word maps to four sequential LMEM accesses through the same requester.

Use one 32-byte staging register and a two-bit subword index. This intentionally trades throughput for a small first implementation. Do not add parallel LMEM lanes until measured copy cost justifies them.

### 3.3 Transfer contract

Proposed command fields:

| Field | Meaning |
|---|---|
| `direction` | TMEM-to-LMEM or LMEM-to-TMEM |
| `tmem_byte_offset` | Offset in the GEMM TMEM address space |
| `lmem_byte_address` | Address in the core's LMEM window |
| `length_bytes` | Contiguous transfer length |
| `command_sequence` | Identifies the accepted command and its completion |

Initial restrictions: both addresses and length are 32-byte aligned; positive length; validated address ranges; one active command; no automatic queuing. Reject invalid commands before issuing any memory request. A busy submission must return an explicit status without modifying the active command. Counters must handle a simultaneous final completion and status read without losing the completion.

Logical tails are handled by owned, padded SRAM allocations. No arbitrary partial beat or read-modify-write support is required in the DMA. Range checks include the entire padded transfer.

TMEM-to-LMEM sequence:

1. Read one 32-byte TMEM word and capture its response.
2. Store its four 8-byte subwords through LMEM requester 0, waiting for physical destination commit for each store.
3. Advance both addresses and repeat; publish completion after the final committed store and pipeline drain.

LMEM-to-TMEM sequence:

1. Read four consecutive 8-byte LMEM words, one at a time, into the staging register.
2. Write one 32-byte TMEM word and consume its write acknowledgement.
3. Advance both addresses and repeat; publish completion after the final write acknowledgement and pipeline drain.

Reusing the existing TMEM switch preserves its bank/address mapping. Software supplies ordinary TMEM offsets; do not duplicate HBM channel-striping calculations in this bridge.

### 3.4 Completion, ordering, and core liveness

LMEM request acceptance is not a write acknowledgement: the lane arbiter/crossbar can buffer a store, and `VX_local_mem` drops write responses. Add a feature-gated commit pulse for the bridge's requester/source at the physical LMEM bank write. Reuse the established tag-source decoding approach where suitable, without adding naive-only metadata or widening unrelated tags. Register the returning commit indication if needed for timing.

The reverse direction also requires a publication contract for SIMD-produced data:

1. Every producer warp finishes its stores and participates in the release/join operation.
2. The controller waits for prior SIMD LMEM writes to reach SRAM before starting a bridge read.
3. No worker modifies the source buffer until the copy completes.

Audit `vx_fence`, LSU posted-store queues, and the independent MMIO/LMEM paths. A control-hart fence or warp join alone must not be assumed to drain other warps' LMEM stores. Implement `publish_lmem()` using producer-side ordering plus accepted-versus-committed LMEM store tracking, including any queues before that tracking point. If the existing fence does not provide the required admission ordering, add an explicit local-memory drain operation with that contract. This is a required correctness milestone, not an optional optimization.

The bridge must contribute to core/AFU pending-work detection until all transactions retire. Add assertions against early kernel completion, late completion after reset, and sequence reuse while an old transaction remains in flight.

## 4. Control interface and GEMM resident modes

### 4.1 Keep the existing GEMM descriptor layout

The current GEMM descriptor has 44 words; changing that count changes its MMIO entry stride. Keep the existing descriptor layout and legacy output-progress register intact.

Under the feature guard, reuse C4's inactive DMA MMIO window (`DMA_REG_BASE_ADDR`, currently 0x1480 for XLEN=64) for:

- A small bridge capability/control/status register block.
- A per-GEMM-entry extension table containing resident mode flags and the expected allocation generation.
- Resident completion status associated with that entry/generation.
- The LMEM publication/drain control if the ordering audit requires it.

Reuse the existing MMIO routing and lane-response conventions. Define the exact offsets and error codes in one shared hardware/software specification before implementation. Do not reuse the legacy `REG_OUTPUT_PROGRESS` word for a different event.

Extension flags default to zero. Validate an extension's entry/generation against the allocated job, latch it with that job, and clear it on retirement/reset/reallocation. A mismatch is an error, not a silent fallback to HBM output. Legacy software that never touches the extension table retains its original behavior.

### 4.2 Initial resident modes

| Mode | Input behavior | Output behavior | First use |
|---|---|---|---|
| Legacy | Existing HBM loads | Existing HBM stores | Regression baseline |
| `OUTPUT_TMEM` | Existing HBM loads | ACC copy to caller-owned TMEM; no output HBM access | First QK tile |
| `A_TMEM + OUTPUT_TMEM` | A already in TMEM; W/scale/zero still loaded from HBM | ACC copy to TMEM | Later QK tiles and PV |

Restrict resident jobs initially to one DMA tile in each dimension. Software loops over query and KV tiles. Support the existing MXU microtile iterations inside each job. Reject multi-DMA-tile resident descriptors rather than allowing them to overwrite a live output buffer.

All resident addresses refer to the existing scratch-base fields; the extension table only selects their semantics. `A_TMEM` pins the activation source to its designated resident buffer instead of alternating or reloading it. Validate nonoverlapping live Q/P/output/weight/qparam ranges in the software allocator and directed tests.

### 4.3 Required FSM changes

- For `A_TMEM`, suppress the HBM A load and input prefetch. Preserve W/scale/zero loads.
- Adjust tile-ready production and wait targets: the existing load schedule counts A/W/scale/zero events. Skipping A without changing these dependencies would hang or release work too early. Audit both initial and prefetch paths.
- For `OUTPUT_TMEM`, preserve compute completion and ACC-to-TMEM copy fences; suppress the HBM store and its store-count dependency.
- Retire a resident descriptor only after every required ACC copy is physically committed and all child work is drained. Do not let zero issued HBM stores cause immediate retirement while output copies are pending.
- Disable the HBM output-preservation preload for resident jobs. The caller owns the entire padded destination; initialize padding deterministically when allocating/reusing the buffer, and keep inactive rows out of the mathematical result.
- Keep `REG_OUTPUT_PROGRESS` reporting HBM store completions for compatibility. Use the new resident completion status plus descriptor retirement to authorize the bridge.
- Never treat a new job's synchronization-counter reset as releasing software-owned TMEM data. Counter lifetime and SRAM-content lifetime are separate.

The first version waits for the entire resident tile, not individual score microtiles. This avoids interleaving GEMM input traffic, bridge traffic, and vector processing on the borrowed TMEM route.

## 5. Attention schedule and memory lifetime

Use a single persistent device invocation for one attention work unit. Start with head dimension 128, KV tile width 128, and query tiles up to 128 rows. Support short decode rows through the existing physical row padding. Later integrate batching/GQA into `llama_decoder_C4` without changing its K/V quantization semantics.

For each query tile:

```text
initialize LMEM FP32 m = -inf, l = 0, U = 0
initialize owned SRAM padding

for each KV tile j:
    QK(A = HBM Q for the first tile, otherwise resident T_Q,
       W = HBM K_j, output = resident T_O)
    wait for QK retirement and committed resident output
    DMA T_O -> L_work; wait

    SIMD: apply scale and mask to S_j in L_work
          compute m_new, alpha, l_new
          write unnormalized P_j in GEMM-A layout to L_P
    publish_lmem()
    DMA L_P -> T_P; wait

    PV(A = resident T_P, W = HBM V_j, output = resident T_O)
    wait for PV retirement and committed resident output
    DMA T_O -> L_work; wait

    SIMD: U = alpha * U + partial_j; m = m_new; l = l_new

SIMD: O = U / l, with the defined empty-row behavior
write final O to HBM and complete the kernel
```

`T_Q` remains protected throughout the query tile. `T_P` is reusable after PV retires. `T_O` is reusable after its contents have been copied to LMEM. `L_work` holds scores and then the PV partial. For FP16 export, `L_P` aliases `L_work`, so probabilities also reuse that allocation. The implemented FP32 export mode uses a separate FP16 `L_P` allocation. LMEM state `U/m/l/alpha` persists across KV tiles and is disjoint from both buffers.

This schedule needs three SRAM copies per KV tile. With FP16 export, their total byte count is:

\[
B_{copy}=2B_rB_c+2B_rB_c+2B_rd
\]

Here `B_r` denotes physical padded rows and `B_c` denotes the padded KV width. For `B_r=16`, `B_c=d=128`, this is 12 KiB. A single 8-byte LMEM requester needs at least 1,536 LMEM word transfers for those bytes, before TMEM latency, commit waits, and control overhead. This is a traffic lower bound, not a cycle prediction or speedup claim. Measure the actual copy share before adding parallelism.

With FP32 export, scores and PV partials use four bytes per element while probabilities remain FP16: `B_copy = 4*B_r*B_c + 2*B_r*B_c + 4*B_r*d`. The same example transfers 20 KiB and requires at least 2,560 LMEM word transfers. These counts describe the same three-copy schedule, not additional bridge commands or a measured cycle cost.

### 5.1 Layout and padding

Use existing A/C offset helpers. On the target square MXU16 configuration, the current A and C tiled offset formulas agree when dimensions, row padding, and tile parameters agree. Verify that property with byte-level tests; no hardware transpose is needed for the proposed single-tile workspace. Do not generalize it to arbitrary configurations or packed K/V layouts.

K and V retain their existing packed INT4 and scale/zero-point layouts. Advance K, V, and all qparam addresses independently for every KV tile. Match the decoder's QK `WTRANS/QDIR` and PV `WTRANS/QDIR`; the older flash regression's fixed zero values are not a replacement for this integration work. A subregion of a larger tiled tensor is not automatically a compact tile: preserve its physical row stride or explicitly pack it using existing layout helpers. Include that packing cost and storage in decoder measurements.

For a final short KV tile, use correctly padded K/V data and a valid-key mask. Initialize all padded values/qparams to numerically safe values. Mask scores before the max reduction. Handle fully masked rows without evaluating `exp(-inf - -inf)`; a row with no valid keys keeps zero output and zero denominator until a valid block appears.

### 5.2 Initial capacity budget

The C4 memories are separate: 256 KiB TMEM and 1 MiB LMEM. ACC is not part of the software SRAM allocator.

For a maximum `128 x 128` tile, a conservative TMEM allocation is:

| Allocation | Budget |
|---|---:|
| Pinned Q | 32 KiB |
| Resident probability A | 32 KiB |
| Shared QK/PV output | 32 KiB |
| Two packed INT4 weight buffers | 16 KiB |
| Two scale and two zero-point buffers, up to 2 KiB each | 8 KiB |
| Total before alignment/guards | 120 KiB |

The qparam estimate assumes the initial tile sizes and quantization groups of at least 16; verify it with the actual QDIR/WTRANS packing helpers. Do not allocate both complete QK and PV scratch plans independently.

LMEM needs a 32 KiB workspace, 64 KiB FP32 U, and approximately 1.5 KiB for three FP32 row-state arrays at 128 rows. Reserve stack, runtime, and any other kernel scratch explicitly. Do not reuse the existing softmax allocator that partitions essentially all LMEM among warps; use an attention-owned arena with per-warp row assignments.

The implemented optional FP32 export described below doubles the maximum shared TMEM output and LMEM score/PV workspace to 64 KiB each. Applying that format to the conservative table above raises its TMEM budget from 120 KiB to 152 KiB before alignment/guards; Q and probability A remain FP16. Both the standalone and decoder allocators additionally reserve a separate 32 KiB FP16 probability buffer in LMEM for this mode. At 128 rows, LMEM therefore needs 64 KiB workspace + 32 KiB probabilities + 64 KiB FP32 U + 1.5 KiB row state, or 161.5 KiB before other reservations. FP16 aliases probabilities with its 32 KiB workspace and uses 97.5 KiB for those same categories. The actual allocators limit the attention arena to the lower half of LMEM; the upper half remains reserved for runtime/other users.

## 6. Numerical behavior

Use block online softmax with unnormalized probabilities:

\[
m'=\max(m,\max S_j),\quad \alpha=e^{m-m'},\quad P_j=e^{S_j-m'}
\]

\[
\ell'=\alpha\ell+\sum P_j,\qquad U'=\alpha U+P_jV_j,\qquad O=U/\ell.
\]

Compute max, sums, alpha, U, and final normalization in FP32 on SIMD. Convert P to the activation format expected by C4. Rescale the previous output accumulator once per KV tile, not the previous tiles' stored probability matrices. The reference must exercise maxima that increase on later KV tiles.

The first implementation keeps the existing GEMM FP16 output conversion for both QK and PV. Consequently, each PV partial is rounded to FP16 before it is added to LMEM FP32 U. This introduces extra rounding relative to a single long PV GEMM or a design exporting FP32 partials. SRAM fusion does not imply bitwise equivalence to either baseline.

Validate with two references:

1. A tiled hardware-semantics reference reproducing quantization, FP16 P, GEMM output rounding, and FP32 online updates.
2. A higher-precision attention reference using the same quantized K/V values, to measure end-to-end numerical error rather than only agreement with an implementation model.

Before declaring the feature complete, document absolute/relative error, overflow cases, and the application's acceptance tolerance. If FP16 PV export violates that tolerance, add a separately scoped FP32 ACC-export mode through the same SRAM bridge. Do not hide the failure by widening tolerances after seeing results. Direct SIMD access to ACC and a hardware alpha-rescale unit are not required for the initial architecture.

Implementation update (2026-10-25): numerical stress exposed finite-output failures in the FP16 export path, so capability revision 2 implements the conditional FP32 export above. Resident FLAGS[2] selects FP32 output and requires resident-output FLAGS[1]; FP16 remains available for comparison. FP32 uses the same 32-byte bridge and existing ACC-copy completion fences. The tiled reference must match the selected export format. Functional evidence and remaining physical/hardware gates are recorded in `c4_flash_attention_results.md`; this format extension does not itself establish hardware acceptance.

## 7. Implementation milestones

### M0 — Freeze interfaces and ordering contracts

- Confirm elaborated C4 widths, TMEM routing, LMEM tag-source fields, and SLR placement boundaries.
- Specify bridge MMIO offsets, sequence/error semantics, per-entry resident metadata, and generation validation.
- Prove which existing signals establish full GEMM/input-route quiescence.
- Specify and test LMEM physical commit and producer publication ordering, including queues upstream of LMEM arbitration.
- Freeze SRAM allocations and the first supported dimensions, quantization layouts, and numerical acceptance criteria.

Exit: a consistent interface specification; no unresolved completion or memory-ownership assumption.

### M1 — Standalone TMEM–LMEM bridge

- Add the small bridge controller and MMIO block.
- Connect the existing LMEM DMA requester and the owner mux before the existing TMEM input switch.
- Add only the commit/drain and registered crossings required by M0.
- Include bridge activity in core completion handling.

Exit: bidirectional copies pass randomized data/backpressure tests across all banks and transfer boundaries; no HBM transaction is generated by a bridge command.

### M2 — GEMM resident I/O

- Add generation-scoped resident metadata and the single-DMA-tile checks.
- Implement resident output, then resident A, with corrected dependency production and completion.
- Preserve legacy progress behavior and skip resident-output preservation reads from HBM.
- Test QK-like and PV-like jobs with software-owned Q/P/output ranges and multiple sequential descriptors without reset.

Exit: `GEMM -> TMEM -> LMEM -> TMEM -> GEMM` works with no intermediate HBM access and no stale-generation completion.

### M3 — Multi-tile attention kernel

- Add resident mode to `tests/regression/flash_attn`, retaining the legacy path for comparison.
- Replace global intermediate/state buffers with explicit SRAM allocations.
- Implement the sequential schedule, V/qparam address advancement, FP32 U rescaling, masks, and final normalization.
- Extend the reference independently; the current single-tile reference's plain accumulation is insufficient.

Exit: multiple KV tiles pass, including increasing maxima, fully masked tiles, short decode rows, and final partial tiles. Numerical error is reported against both references.

### M4 — Decoder integration and measured evaluation

- Integrate the kernel into `llama_decoder_C4` with its existing KV quantization, GQA grouping, and output layout.
- Compare prefill and decode separately against the existing QK/softmax/PV path.
- Record compute, SIMD, SRAM-copy, control, and HBM traffic costs.
- Produce a new FPGA configuration/alias for the feature; preserve the rev8 candidate mapping and old binaries.

Exit: end-to-end correctness, no intermediate HBM traffic, and a measured performance report. A serialized bridge may initially be slower; report that result rather than claiming speedup from traffic reduction alone.

## 8. Verification matrix and execution rules

| Area | Required cases |
|---|---|
| DMA correctness | Both directions; one word, multiple banks, full tile; randomized stalls; distinct patterns per beat/subword; padding canaries |
| Ordering | Delayed LMEM commit; outstanding SIMD stores at publication; delayed TMEM responses; back-to-back commands; start while busy; reset with work pending |
| Shared route | Delayed GEMM input response at handoff; new GEMM while bridge owns the route; no response delivered to the wrong owner; SLR pipeline drain |
| Validation | Misaligned/zero/overflowing transfers; out-of-range LMEM/TMEM; invalid resident job shape; stale entry/generation |
| Resident GEMM | HBM-to-TMEM output and TMEM-to-TMEM jobs; skipped-A readiness; no output preload/store; inactive rows and padded bytes; multiple descriptors without reset |
| Attention | M=1/4/8/16/128; KV=128/256/384 and nonmultiple tails; distinct K and V per tile; causal/noncausal; all-masked blocks; later larger maxima; GQA |
| Numerical | FP16 PV rounding, extreme logits, alpha underflow, output overflow, FP32 state retention, agreement with both references |
| Compatibility | Feature-off preprocessed/elaborated RTL identity for touched paths; unchanged legacy descriptor stride/progress; legacy GEMM and decoder regressions |
| Physical SRAM paths | Preserve registered transaction links, metadata and RAM ownership checks; apply the core-reset policy above instead of requiring added local reset FF chains. Trace RAM outputs through every combinational hop to first state, including side-input and response-ready closure, on successor checkpoints. Incident RAM nets alone do not cover optimized response-selection logic. Check legal paired RAM placement and final routed timing before accepting the image. |

Trace external DMA addresses as well as bytes: Q/K/V/qparams and final output may access HBM; scores, probabilities, PV partials, and online state must not. Verify this in the persistent kernel, without diagnostic host downloads that would themselves create intermediate traffic. Bridge tests must prove byte identity independently of attention arithmetic.

For execution, source the appropriate `configs/` file before simulation or synthesis, configure a separate build directory, and run tests from that build directory. Use `/usr/bin/gcc` and `/usr/bin/g++` for host-side RTL unittest compilation. Follow `run-bb-common` and use `ci/run_black.sh xrt-vcs-sim` for blackbox RTL tests; do not substitute simx or Verilator rtlsim. Use separate configured build directories for baseline and feature configurations.

Hardware runs require a newly built feature image and its explicit alias. Do not run the old `flash_attn/README.md` command using generic `--fpga-bin C4` as evidence for the rev8 target. No improve GEMM-node synthesis sweep is part of this plan. Use RTL structure, traffic traces, cycles, and the eventual whole-design timing check to evaluate the feature.

## 9. Follow-up optimization boundary

Only after M1–M4 establish correctness and a measured breakdown, consider two staging buffers, several LMEM word requests in flight, or parallel use of additional existing LMEM DMA requesters. Each option must preserve the existing LMEM crossbar dimensions and avoid a new TMEM crossbar.

Do not overlap a bridge transfer with a GEMM that needs the borrowed input route. Such overlap requires a new ownership/dependency design and is not implicit in adding buffering. Q/K/V prefetch overlap, per-microtile streaming softmax, generalized resident weight loads, and new ACC arithmetic are separate follow-up work.

## 10. Completion criteria

- Fusion logic uses the existing core reset directly, without the added two-stage local reset relays; reset state and transaction-crossing correctness remain verified.
- SRAM copies work in both directions without new TMEM routing fabric or SIMD TMEM ports.
- Resident GEMM results and activations can be consumed without HBM round trips.
- Completion means committed destination data, with no dependence on an unrelated later kernel reset or cache flush.
- Multi-KV-tile attention maintains and rescales FP32 online state correctly, within an explicitly recorded numerical tolerance.
- Intermediate attention tensors and state remain in SRAM during normal execution.
- Existing feature-off behavior and legacy GEMM software remain intact.
- C4 prefill/decode correctness, traffic, and timing results are recorded without assuming a speedup.

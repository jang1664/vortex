# GEMM Dispatcher Optimizations — Implementation Plan

Two optimizations targeting the single-warp dispatcher bottleneck observed in
`tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp`. Both can be applied
independently; they compose for maximum speedup.

- Background: `docs/gpu-single-thread-control-stall.md`
- Empirical FSDB stall analysis: `tools/mmio_analysis/RESULTS.md`

## 0. Problem Recap (from FSDB measurement)

Source: `tools/mmio_analysis/RESULTS.md` and a follow-up FSDB pipeline trace
on `build/sim/xrtsim_vcs/vcs_cosim.fsdb` (window 78 µs … 1280 µs,
100 MHz, 10 ns period).

- 1020 `stream_send`s over the GEMM-occupied window. 100 % of MMIO
  writes accepted in **0 wait cycles** (`req_ready` always high). Stall
  ratio on `gemm_ctrl_if[0]` = **0.0 %**.
- `schedule/active_warps` is `0001` for the entire dispatcher window
  (warp 0 only); `thread_masks[0] = 0x01`. The boot stub WSPAWNs warps
  1–3 to run `init_regs_all` / `init_tls_all` and they self-deactivate
  with `vx_tmc_zero()` before `main` does any GEMM work — so the
  dispatcher really runs on **1 warp × 1 thread**.
- Inter-store gap distribution has modes at **7 / 10 / 16 cycles** — these
  are filled by RISC-V scalar instructions (address gen, `arg` loads,
  branches), not by MMIO backpressure. Static disasm confirms 0–11
  scalar instructions between consecutive `stream_send`s.

**Why even back-to-back stores see 7-cycle gaps.** Single-instruction
pipeline trace at 104.6 µs:
- `schedule_fire` → `decode_sched_if.unlock` = **5 cycles** (schedule
  out_buf 1 stage + fetch over icache 2–3 stages + decode 1 stage).
- decode unlock → warp unstall = 1 cycle.
- next `schedule_fire` = +1 cycle.
- Total issue cadence = **7 cyc/instr**.

`VX_schedule.sv:202-204` locks the warp on `schedule_fire` and
`VX_schedule.sv:116-118` only unlocks it at decode. With a single active
warp, `ready_warps == 0000` for ~6 of every 7 cycles — the scheduler
**idles ~85 % of cycles** on the dispatcher path. This holds whether
the in-flight instruction is a wstall op (branch / SFU) or a plain ALU,
since the warp is always locked from fetch through decode.

The bottleneck is therefore **single-warp fetch+decode pipeline depth
locking the only active warp**, with scoreboard hazards / wstall
contributing additional latency on top. A second eligible warp is what
the scheduler is missing.

---

## Optimization 1: Software Helper-Warp DAE

Pure-SW change. Two warps connected by an LMEM ring. Mirrors classical
Decoupled Access/Execute: warp 0 = "access" (compute descriptors), warp 1
= "execute" (issue MMIO writes).

### Why it should help on Vortex

Vortex is in-order single-issue per cycle; with one warp the scheduler has
no fallback when scoreboard hazards (load latency, dependent ALU chain)
arise. Two ready warps let the scheduler hide those bubbles by alternating.

### SW pattern

> **Note on warp activation.** Vortex boots with only warp 0 active.
> The boot stub WSPAWNs warps 1–3 to initialise per-warp state, but
> they self-deactivate (`vx_tmc_zero`) before `main` is reached.
> Therefore the helper-warp DAE kernel **must explicitly re-spawn warp
> 1** at the start of `main`; otherwise warp 1 never enters
> `kernel_entry`, the producer fills the ring, and the kernel
> deadlocks.

Shared producer/consumer state lives in **local memory** addressed via the
`__local_mem()` macro from `<vx_spawn.h>` (`VX_CSR_LOCAL_MEM_BASE + group_id * size`).
Reserve a fixed byte layout at the start of the per-group LMEM window — no
linker-script change is needed. See `tests/regression/conv3/kernel.cpp` for the
canonical pattern.

```c
#include <vx_spawn.h>

constexpr uint32_t RING_LOG2  = 5;            // 32 entries
constexpr uint32_t RING_MASK  = (1u << RING_LOG2) - 1u;

// Fixed offsets inside the per-group LMEM window.
//   [0x000 .. 0x100)  ring[32] of uint64_t  (32 * 8 = 256 bytes)
//   [0x100 .. 0x104)  ring_head    (producer-owned)
//   [0x104 .. 0x108)  ring_tail    (consumer-owned)
//   [0x108 .. 0x10C)  producer_done
constexpr uint32_t LMEM_RING_OFFSET    = 0x000;
constexpr uint32_t LMEM_HEAD_OFFSET    = 0x100;
constexpr uint32_t LMEM_TAIL_OFFSET    = 0x104;
constexpr uint32_t LMEM_DONE_OFFSET    = 0x108;
constexpr uint32_t LMEM_RESERVED_SIZE  = 0x110;

static inline volatile uint64_t* lmem_ring()       {
    return (volatile uint64_t*)((uint8_t*)__local_mem(LMEM_RESERVED_SIZE) + LMEM_RING_OFFSET);
}
static inline volatile uint32_t* lmem_head()       {
    return (volatile uint32_t*)((uint8_t*)__local_mem(LMEM_RESERVED_SIZE) + LMEM_HEAD_OFFSET);
}
static inline volatile uint32_t* lmem_tail()       {
    return (volatile uint32_t*)((uint8_t*)__local_mem(LMEM_RESERVED_SIZE) + LMEM_TAIL_OFFSET);
}
static inline volatile uint32_t* lmem_done()       {
    return (volatile uint32_t*)((uint8_t*)__local_mem(LMEM_RESERVED_SIZE) + LMEM_DONE_OFFSET);
}

static inline void ring_push(uint64_t w) {
    auto* head = lmem_head();
    auto* tail = lmem_tail();
    auto* ring = lmem_ring();
    uint32_t h = *head;
    while ((h - *tail) >= (1u << RING_LOG2)) { /* spin: full */ }
    ring[h & RING_MASK] = w;
    asm volatile ("fence w,w" ::: "memory");      // publish data before head
    *head = h + 1;
}

static inline bool ring_pop(uint64_t* out) {
    auto* head = lmem_head();
    auto* tail = lmem_tail();
    auto* ring = lmem_ring();
    auto* done = lmem_done();
    uint32_t t = *tail;
    while (t == *head) {
        if (*done) return false;                  // drain & exit
    }
    *out = ring[t & RING_MASK];
    asm volatile ("fence r,r" ::: "memory");
    *tail = t + 1;
    return true;
}

static void run_producer(const kernel_arg_t* arg) {
    // existing run_tiled_gemm body, but replace every stream_send(w)
    // with ring_push(w); compute descriptors & ring_push only.
    run_tiled_gemm_via_ring(arg);
    asm volatile ("fence w,w" ::: "memory");
    *lmem_done() = 1;
}

static void run_consumer() {
    uint64_t w;
    while (ring_pop(&w)) stream_send(w);
}

static void kernel_entry() {
    int wid = vx_warp_id();
    vx_tmc_one();
    auto arg = reinterpret_cast<kernel_arg_t*>(csr_read(VX_CSR_MSCRATCH));
    if      (wid == 0) run_producer(arg);
    else if (wid == 1) run_consumer();
    else               vx_tmc_zero();             // warps 2+ stay disabled
}

int main() {
    if (vx_warp_id() != 0) { vx_tmc_zero(); return 0; } // post-boot, only wid==0
    vx_tmc_one();
    // Initialize the LMEM control words before spawning the consumer.
    *lmem_head() = 0;
    *lmem_tail() = 0;
    *lmem_done() = 0;
    asm volatile ("fence w,w" ::: "memory");
    vx_wspawn(2, &kernel_entry);                  // re-activate warp 1
    kernel_entry();                               // also runs on warp 0
    return 0;
}
```

### Notes

- `make_wait` / `make_notify` are still produced as `ring_push` words; the
  consumer issues them via `stream_send` like any other word. Ordering is
  preserved by the FIFO.
- Polling overhead is amortised by ring depth ≥ ~16. With RING_LOG2 = 5 the
  producer typically gets several pushes in before the consumer drains,
  letting both warps spend most cycles doing real work.
- LMEM round-trip per word adds 1 store (push) + 1 load (pop), but the LSU
  accepts both at 1/cycle (verified) so this does not bottleneck.
- **LMEM placement is mandatory** for the ring and its control words.
  Default linkage would put globals in BSS (DRAM), defeating the purpose —
  every push/pop would traverse the cache hierarchy. The kernel addresses
  LMEM via the `__local_mem(size)` macro (`<vx_spawn.h>`), which resolves to
  `VX_CSR_LOCAL_MEM_BASE + __local_group_id * size`. We pick a fixed byte
  layout inside that window (see code above). No `link64.ld` change is needed.
  The canonical reference for this pattern is `tests/regression/conv3/kernel.cpp`.
- **Risk:** if the producer is too fast the consumer becomes the bottleneck
  and the gain is bounded by the consumer's `stream_send` rate. Measure
  first; if so, the *combined* optimization below addresses that side.

### Expected gain

The §0 trace gives a concrete empirical upper bound. Single-warp issue
cadence is 7 cyc/instr with the warp `ready` for only 1 of every 7
cycles. Adding a second warp that stays ready during warp 0's 5-cycle
fetch+decode lock raises steady-state issue throughput to roughly
`(1 + 5/7) ≈ 1.71×`. End-to-end gain is bounded below this by:
- ring push/pop overhead (1 LMEM store + 1 LMEM load per word),
- consumer's own 7-cyc cadence on the bare `stream_send` path,
- residual long-tail gaps (`make_wait` polling, sync points).

Realistic target: **1.3–1.7×** end-to-end.

---

## Optimization 2: 8-Thread Parallel MMIO Burst

Activate all 8 threads of the warp, give each thread its own MMIO stream
slot, and have one `sw` instruction submit 8 command words in 1 cycle.

### Current RTL serialization point (verified)

The LSU and lmem switch already pass per-lane addresses and data through
to the GEMM frontend:

- `VX_lmem_switch.sv:72-86` — per-lane address decoding produces an
  8-bit `is_addr_gemm_mask`.
- `VX_lmem_switch.sv:152-166` — `req_gemm_buf` carries the **full**
  `req_data.mask`, `req_data.addr` (8 entries), `req_data.data` (8 entries)
  into `gemm_ctrl_if`.

The serialization is only inside the GEMM frontend:

- `VX_gemm_job_frontend.sv:123` — `byte_addr = addr_to_byte(addr[0])`
  (lane 0 only).
- `VX_gemm_job_frontend.sv:139` — `issue_if.inst = data[0]` (lane 0 only).

Lanes 1-7's payload is dropped on the floor today. Fixing this is a
contained change in the frontend + downstream queue widening.

### SW interface change

Reserve an 8-slot stream port window (8-byte stride, lane-indexed). The
single-slot legacy address aliases lane 0 of the burst window so unchanged
single-thread `mmio_stream_send` calls remain bit-identical:

```c
//   0x1080            : ALLOC read doorbell
//   0x1088 .. 0x10C7  : 8-slot burst window (lane i at 0x1088 + 8*i)
//                       Lane 0 is the legacy single-slot port.
//   0x1100            : STATE read register (moved up from 0x1090 to make
//                       room for the 8-slot window).
static constexpr uint64_t GEMM_STREAM_ADDR       = 0x1088;     // = burst lane 0
static constexpr uint64_t GEMM_STATE_ADDR        = 0x1100;
static constexpr uint64_t GEMM_STREAM_BURST_ADDR = GEMM_STREAM_ADDR;  // i in 0..7
// per-lane address: GEMM_STREAM_BURST_ADDR + 8*i
```

Variable-width burst send. The dispatcher does **not** wait for 8 pending
words; with *k* words ready it activates *k* threads:

```c
// Active threads = popcount(mask). Words must be in lanes [0..popcount-1].
static inline void stream_send_burst(const uint64_t words[8], int k) {
    // k in 1..8.  Caller has the next k command words ready in words[0..k-1].
    uint32_t mask = (1u << k) - 1u;          // 0x01, 0x03, 0x07, ..., 0xFF
    vx_tmc(mask);
    int lane = vx_thread_id();               // 0..7 within warp
    *reinterpret_cast<volatile uint64_t*>(
        GEMM_STREAM_ADDR + 8*lane) = words[lane];
    vx_tmc_one();
}
```

The LSU already builds per-lane store requests (`mem_req_addr[i]`,
`mem_req_data[i]`) — no scalar code change in the LSU.

**Compiler-emit verified.** `tests/regression/mmio_burst_proto/` builds
exactly this pattern under `-O3` with `+vortex` target feature. The
disasm shows a single `sd a0, 0x88(a1)` per case — the body of
`case_burst8` (`mask=0xFF`) and `case_burst_partial` (`mask=0x0F`) are
byte-for-byte identical, confirming that variable burst width reduces to
a runtime tmask choice with no code-gen difference. The `csrr a1, tid`
(custom CSR `0xCC0`) preceding the store materialises the per-lane
thread id as expected; the compiler does not strip-mine into a serial
sequence.

### Required RTL changes

| Module | File:line | Change | Effort |
|---|---|---|---|
| Address decode in frontend | `VX_gemm_job_frontend.sv:123` | Replace single `addr[0]` decode with per-lane `addr[i]` decode; produce 8 per-lane `req_is_stream`/`req_is_alloc`/`req_is_state` flags. | Low |
| Issue path | `VX_gemm_job_frontend.sv:130-140` | Drive `issue_if` from a sequencer that emits up to 8 words/cycle (or widen `issue_if` to an 8-wide bus and let the constructor pop 1 per cycle). | Medium |
| Mask-aware push | `VX_gemm_job_frontend.sv` (new logic) | Push `popcount(mask & is_stream_lane)` words into the serializer FIFO in lane-id order. Words from inactive lanes (mask bit 0) are skipped. This is what enables the variable-burst SW pattern (`vx_tmc((1<<k)-1)` for *k*<8 pending). | Medium |
| Backpressure | `VX_gemm_job_frontend.sv:131-133` | `req_ready` must reflect downstream capacity for *all valid lanes*, not just lane 0. The simplest form: only assert `req_ready` when the FIFO has room for `popcount(mask & is_stream_lane)` words. | Medium |
| Instruction FIFO | `VX_instruction_if.sv` + new wide FIFO | Either widen `inst` to `[7:0][63:0]` with a per-cycle popcount, or insert an 8→1 serialiser FIFO between frontend and constructor (depth ≥ 16 so 8-word bursts fit). | Medium |
| Cmd constructor | `VX_cmd_constructor.sv:267, 294-308` | If serialiser FIFO is used, **no constructor change** — it still consumes 1 word/cycle. This keeps the high-risk module untouched and is the recommended path. | None (with serialiser FIFO) |
| Parent queue | `VX_gemm_ctrl.sv:118-120` | Optional — only widen if profiling shows it as the bottleneck after the serialiser FIFO is in. | None initially |

The key design choice is **where to absorb the 8→1 fan-in**:

- **Option A — Serialiser FIFO between frontend and constructor.** Front­end
  pushes 8 words/cycle into a wide FIFO; constructor pops 1/cycle as today.
  Minimal change to the constructor; the FIFO depth (≥16) absorbs bursts.
  *Recommended.*
- **Option B — Widen the constructor itself to N words/cycle.** Higher gain
  in steady state but the constructor state machine handles 1-, 2-, and
  3-word commands, so multi-cycle command boundaries require careful
  sequencing logic. Higher risk.

Start with Option A, measure, then consider Option B only if the
constructor becomes the new bottleneck.

### Ordering contract

Simplified relative to the original constraints. The GEMM controller
serves its instruction queue strictly in the order words arrive at the
serializer FIFO output, so SW only needs:

1. **Maintain an in-order SPSC word queue** (the producer of DAE Opt 1
   already does this). Push every command word — `make_dma_word*`,
   `make_mxu_*`, `make_notify`, `make_wait`, `make_clear` — at its
   natural position.
2. **Burst dispatcher pops up to 8 words per warp instruction.** It
   places `words[i]` in lane `i` (lane-id order). The serializer FIFO
   then drains lane 0 → lane 7 within the burst, so word order is
   identical to the queue order.
3. Multi-word commands (DMA = 3, MXU_LOAD_INPUT = 2, MXU_LOAD_QPARAM = 2)
   need no special packing — they may span lane boundaries within a
   burst or even straddle two consecutive bursts. The constructor
   reassembles them from the serial word stream.
4. `make_clear` may also be packed in a burst (no need to flush first).
   It terminates the current job once the FIFO drains past it; any
   subsequent words start the next job.

The only real constraint is "within one warp instruction, lane-id order
defines word order" — which is purely an RTL property of the serializer
push.

### Expected gain

Replacing 8 serial `stream_send`s (8 × ~1 cycle of LSU + N cycles of inter-
store ALU) with one warp instruction (~1 cycle LSU + the same ALU done
in parallel across 8 threads) is potentially **5–8×** for the burst phase
itself. End-to-end benefit depends on what fraction of the kernel runtime
is in `make_dma_word*`/burst-issue regions vs `make_wait` polling on the
GEMM finishing real work.

### Risks

- **Compile-time emit (resolved).** Earlier versions of this proposal
  worried that LLVM might strip-mine a per-lane store into a serial
  sequence. The prototype in `tests/regression/mmio_burst_proto/`
  builds the burst pattern at `-O3` with the production toolchain and
  emits exactly **one `sd`** per case — see "Compiler-emit verified"
  in the SW interface section above.
- **Per-lane data layout.** With the queue-based pattern above, each
  lane simply reads `words[lane]` from a queue snapshot in LMEM/regs;
  the descriptor-builder code stays single-threaded on the producer
  warp (DAE Opt 1) and only the consumer warp's burst-dispatch
  function executes the per-lane store. No need to refactor descriptor
  arithmetic across lanes.
- **`issue_if.ready` granularity.** With Option A the ready signal is
  driven by the serialiser FIFO's free count; ensure it drops *before* the
  FIFO can overflow (account for register stages between LSU and FIFO).
- **Mask propagation through the LSU.** The LSU already carries
  `req_data.mask` to `gemm_ctrl_if[0]` (`VX_lmem_switch.sv:152-166`) so
  partial bursts (mask = `0x0F` etc.) reach the frontend with the
  correct active-lane indication. This must be re-checked once the
  frontend's mask-aware push is in place — specifically that the
  serializer pushes `popcount(mask & is_stream_lane)` words, not 8.

---

## Combined Approach

Optimizations 1 and 2 are orthogonal and compose:

- Helper-warp (Opt 1) splits address gen from MMIO issue.
- Multi-thread burst (Opt 2) accelerates the consumer warp's MMIO-issue
  phase by 5–8× per burst.

The consumer warp in the helper-warp scheme uses the variable-width
burst pattern: with at least 1 ring word ready it raises tmask to
`(1<<k)-1` (where `k = min(8, ring_count)`), executes
`stream_send_burst`, then drops back to `vx_tmc_one` to poll the ring.
The producer warp stays single-thread (compute is inherently serial) and
feeds the ring at its natural rate. Net effect: the dispatcher cost in
cycles per GEMM tile drops by roughly the product of both gains.

Compiler-emit verification of the burst pattern lives at
`tests/regression/mmio_burst_proto/` (`make kernel.dump`).

---

## Suggested Implementation Order

1. **Build & measure helper-warp DAE (SW only).** No RTL risk. Any
   non-negative end-to-end gain is acceptable as a stepping stone — a
   small DAE-only gain still feeds the combined optimization in step 3.
2. **Build & measure 8-thread burst MMIO (Opt 2, RTL Option A).** The
   serialiser-FIFO path is the lowest-risk RTL change. Verify with the
   existing `tools/mmio_analysis/analyze_mmio_stall.py` that the gap
   distribution shifts from 7/10/16-cycle modes toward 2-cycle.
3. **Combine.** Modify the consumer warp in step 1 to use the burst path
   from step 2.
4. **(Optional) Widen constructor (Opt 2 Option B)** only if step 2 + 3
   profiling shows the constructor as the new bottleneck.

---

## Verification Hooks

- **Functional regression:** existing `tests/regression/fpint_gemm_ffn_hw_improve`
  must produce identical outputs at every step.
- **Compiler-emit prototype:** `tests/regression/mmio_burst_proto/`. Run
  `make kernel.dump` and confirm `case_burst8` and `case_burst_partial`
  bodies remain single-`sd` and byte-for-byte identical. Re-check
  whenever the toolchain or `-mllvm` flags change.
- **MMIO stall metric:** rerun `tools/mmio_analysis/analyze_mmio_stall.py`
  after each step. Headline metrics to watch:
  - GEMM accept-to-accept gap distribution (should shift left from the
    current 7 / 10 / 16-cycle modes toward 3–4 cycles after Opt 1).
  - LSU `req_valid` total active time (helper-warp will increase total
    LSU traffic from ring loads/stores; that's expected and OK).
  - GEMM `req_valid` time (should *not* increase as a fraction of valid
    cycles — wait should still be 0).
- **Pipeline trace (Opt 1):** at any 1 µs window inside the dispatcher,
  capture
  `schedule/active_warps`,
  `schedule/stalled_warps`,
  `schedule_if/valid`,
  `decode_sched_if/{valid,unlock}`,
  `gemm_ctrl_if[0]/req_valid`
  via `tools/fsdb_cli` (`fsdb.report` Python API). Expect:
  (a) `active_warps` = `0011` for the duration of the dispatcher
      (instead of `0001` baseline);
  (b) `stalled_warps` low bits oscillate `0001 ↔ 0010` rather than
      `0001 ↔ 0000` — i.e. while one warp is locked in fetch+decode,
      the other is ready and getting picked;
  (c) `schedule_fire` density approximately doubles.
- **Pipeline trace (Opt 2):** capture
  `gemm_ctrl_if[0]/req_data.mask`
  during a burst region. Expect 8-bit mask values matching the SW
  `vx_tmc(mask)` (e.g. `0xFF` full burst, `0x0F` 4-thread partial).
  Confirm the serializer FIFO pushes `popcount(mask)` words per
  accepted handshake.
- **End-to-end cycles:** compare `arg->status = STATUS_OK` cycle vs
  baseline.

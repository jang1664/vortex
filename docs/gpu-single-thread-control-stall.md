# GPU Single-Thread / Control-Warp Stall — Background and Mitigation Techniques

## 1. Problem Framing

In `tests/regression/fpint_gemm_ffn_hw_improve/kernel.cpp`, only core 0 / warp 0 / thread 0 is
active (`vx_tmc_one()`). That single thread streams MMIO command words to the
GEMM node frontend (`stream_send`) interleaved with `make_wait` / `make_notify`
sync ops. From the scheduler's point of view the warp is "active for 1 issue,
stalled for 4–10 cycles, repeat" — classic bad fit for a throughput-oriented
GPU pipeline.

This is fundamentally a **control-thread / dispatcher** workload running on a
SIMT machine:

- No data parallelism to hide latency with — only one lane is live.
- No second warp on the SM to swap in during stalls.
- The gaps between consecutive `stream_send`s (FSDB: 7 / 10 / 16 cyc modes)
  are filled by ordinary RISC-V instructions on the warp — address gen,
  loads from `arg`, branches, scoreboard waits — not by MMIO backpressure.
  Empirically the GEMM frontend accepts every store at 1 cycle (0 % stall
  ratio across 1020 writes); the bottleneck is single-thread issue rate.

Multi-thread / multi-warp re-implementation is unnatural here because the
instruction stream into the accelerator is inherently sequential and ordered.
The literature has converged on several alternatives that fit this pattern.

## 2. Established Mitigation Patterns

### 2.1 Warp Specialization (producer/consumer)

NVIDIA Hopper, CUTLASS Ping-Pong, persistent GEMM kernels, and the recent Tawa
(CGO 2026) work all use *warp specialization*: dedicate **one tiny producer
warp** to driving the asynchronous accelerator (TMA / WGMMA), while consumer
warps handle math. The producer warp looks almost exactly like the loop in
`run_tiled_gemm`: address computation, descriptor build, async issue, barrier.

Key idea: the producer warp is **expected** to be small and stall-prone; what
hides its stalls is the *consumer warps on the same SM*, not its own ILP.

> "Producer warp groups work with TMA and are deliberately kept as lightweight
> as possible … consumer warps are entirely dedicated to computations."
> — CUTLASS / Hopper warp specialization.

Relevance to this kernel: even if you cannot create useful consumer warps on
the Vortex side (because all compute is offloaded to the GEMM accelerator),
*at minimum spawn enough sibling warps to keep the SM's eligible-warp pool
non-empty*. Idle warps doing `nop`/spin do not help, but warps that prepare
the next descriptor batch in registers do.

### 2.2 Persistent Kernel + Async-Everything

Persistent kernels keep one block live for the whole problem and submit
all tiles via async issues, amortizing launch and prologue overhead. Combined
with warp specialization, this matches exactly what `run_tiled_gemm` already
does at the SW level — the GPU-side pattern is to additionally **batch
descriptor builds**: producer warp prepares N future descriptors into shared
memory, then issues them in a tight burst, so the inter-store RISC-V ALU work
is amortised rather than spread across every iteration.

### 2.3 Decoupled Access/Execute (DAE) and Helper-Thread Prefetching

DAE splits a program into an *access stream* (address gen, memory issue) and
an *execute stream* (compute), connected by FIFOs. On in-order cores this
hides memory latency without OoO hardware. ACACES'12 applies DAE specifically
to mobile GPUs and reports performance within 7 % of a 16-warp/core GPU at
34 % less energy — i.e. DAE recovers most of the latency-hiding benefit
without needing dozens of warps.

Helper-thread prefetching is the same idea expressed at the thread level:
spawn a tiny secondary thread that runs ahead, computes addresses, and warms
the cache / issues async loads. For an MMIO-heavy dispatcher this maps to
"separate the address-generation warp from the MMIO-poke warp."

Relevant papers:
- DeSC (MICRO'15) — decoupled supply-compute communication for accelerators.
- "Efficient Data Supply for Hardware Accelerators" (MICRO'16, Cornell).
- Decoupled Affine Computation for SIMT GPUs (ISCA'17) — extracts uniform
  address arithmetic out of the SIMT pipeline.
- Compiler Support for Speculation in DAE (CC'25, arxiv 2501.13553).

### 2.4 AMD GCN/CDNA Scalar Unit — "Free" Co-Issue

GCN co-issues one **scalar ALU** instruction with one vector instruction every
cycle. The scalar unit owns:

- All program flow control (branches, loop counters).
- Wave-uniform address generation (constant base + per-wave offsets).
- Reads from the scalar data cache via a dedicated AGU pipeline.

For the dispatcher loop this means address arithmetic for `make_dma_word*`,
`d_in / d_w / d_sc / d_zp`, `tile_target[b] += 4`, etc. is essentially free
and parallel with any vector work. The Vortex pipeline does not have this
asymmetric scalar/vector split, so today the same arithmetic blocks the only
issue slot. **Adding a scalar/uniform issue path is the single most impactful
microarchitectural fix** for this kernel pattern.

### 2.5 "1-Thread / 1-Warp Mode" — Repurposing SIMT Resources as a CPU

There is a separate line of research that asks the inverse question of warp
specialization: *when only one thread / one warp is live, can we use the
already-present SIMT hardware to behave like a single-core CPU pipeline?*
This is exactly the regime our dispatcher kernel runs in.

#### SIMT-X (Collange et al., ACM TACO 2020)

**Direction matters.** SIMT-X is built **bottom-up from a CPU**, not from a
GPU. The base is an OoO x86-64 superscalar with SMT and a SIMD back-end
(AVX-class). The programmer writes ordinary pthread / OpenMP code; warps
are *not* a programmer-visible concept. The hardware dynamically detects
when multiple SMT threads of the same program are converged and packs
their scalar instructions into one SIMD op on the existing back-end —
"From the point of view of the pipeline back-end, each SIMT warp is
essentially equivalent to an SMT thread running SIMD instructions."

When only one thread is active the warp machinery is a no-op and the core
runs as a plain OoO superscalar: *"SIMT-X performance on single-thread
workload is virtually identical to an equivalently-configured superscalar
core, as the PIRAT holds a single physical mapping per architectural
register."* The relevance for our discussion is the *principle* it
demonstrates — a SIMT execution layer and a scalar CPU execution layer
can share the same back-end resources without one paying overhead for
the other — not the artefact itself, which is a CPU project.

For Vortex, the analogue runs in the **opposite direction**. Vortex is
GPU-base (SIMT, explicit warps, lane mask, no OoO). The SIMT-X-inspired
move is therefore not "add SIMT to a CPU" but "**bypass the SIMT layer
when only one lane is active**" — when `tmask` popcount = 1, drop the
mask/divergence machinery from the critical path and let the surviving
issue/regfile/ALUs behave like a small in-order RISC-V scalar pipeline.
Same end-state as SIMT-X's 1-thread mode, reached from the other side.

#### Temporal SIMT / Spatiotemporal SIMT (Keckler / NVIDIA, CGO 2013, TACO 2015)

Temporal SIMT (T-SIMT) maps an entire warp onto a *single* lane and dispatches
threads in successive cycles. On divergence, threads execute independently
"as a traditional multithreaded MIMD processor." The Spatiotemporal SIMT
(STSIMT) follow-up combines T-SIMT with scalarization for +19.6 % perf and
−26.2 % EDP. The key property for our use: a temporal lane *is* a scalar
in-order pipeline. With only one live thread, the warp degenerates cleanly
into a normal scalar CPU — no idle SIMD lanes wasted, no masking overhead.

#### Scalarization + Affine/Uniform Pipelines

Closely related family of works that detect warp-uniform values at compile
or run time and route them through a dedicated narrow pipeline:

- **Convergence and Scalarization for Data-Parallel Architectures** (Lee,
  Keckler et al., CGO 2013).
- **Spatiotemporal SIMT and Scalarization** (Lucas, Andersch, Juurlink,
  TACO 2015).
- **Decoupled Affine Computation for SIMT GPUs** (Wang & Lin, ISCA 2017).
- **Scalar-Vector GPU Architectures** (Z. Chen, Northeastern PhD thesis).

In the 1-thread/1-warp regime *every* live value is trivially uniform, so
the entire program funnels through the scalar pipeline at high IPC while
the vector lanes idle. This is effectively a "GPU that becomes a CPU" when
parallelism collapses to 1.

#### Production-silicon analogues

- **AMD GCN/CDNA scalar unit** (§2.4) — a real in-order scalar CPU embedded
  in every CU, used for control flow, branch, uniform arithmetic, and scalar
  loads. It co-issues for free with vector ops; in a hypothetical 1-thread
  workload it would carry essentially the entire program.
- **Intel Xe scalar EU** — Intel's PRM describes a *scalar execution unit*
  with "ALU, memory, and control-flow pipelines", "similar to a single-laned
  SIMD unit, but runs much faster with lower hardware complexity." Used for
  command-streamer-style control work.
- **NVIDIA "uniform datapath"** (Turing+) — uniform registers (`UR*`) and a
  uniform-only ALU; the SASS encodes uniform instructions distinctly so the
  scheduler can co-issue them with the per-thread datapath.

These three are the strongest evidence that the "use existing GPU resources
in CPU mode" idea is not just academic — every modern GPU vendor has shipped
some form of scalar/uniform pipeline alongside the SIMT pipeline precisely
to handle dispatcher/control workloads at high IPC.

#### What this implies for Vortex

Vortex today does not have a scalar/uniform issue port — when `tmask=1` the
SIMT pipeline is just executing one lane's worth of work per cycle and
throwing away the rest. Two architectural directions worth considering:

1. **Cheap version (SIMT-X-inspired, but inverted):** detect tmask popcount
   = 1 in issue and let the existing pipeline behave as a small in-order
   scalar CPU — branch predictor on, no per-lane mask logic on the critical
   path, maybe enable simple back-to-back forwarding the SIMT pipeline
   normally does not need. No new datapath. (Note: SIMT-X itself adds SIMT
   to a CPU; here we are doing the reverse — stripping SIMT overhead from
   a GPU when only one lane is live.)
2. **Full version (GCN/Xe-style scalar unit):** add a tiny scalar pipeline
   that co-issues with the SIMT pipeline for warp-uniform integer ops, address
   gen, branches, and scalar loads/stores (including MMIO). This matches what
   the dispatcher kernel actually needs and is the single change with the
   largest expected impact on this workload.

Either approach is consistent with the user's intuition: instead of forcing
the kernel into multi-warp form, change the hardware so that the existing
SIMT resources, in the 1-thread limit, behave like a single-core CPU.

## 3. Recommendations for Vortex

The bottleneck is single-thread issue rate, not the MMIO path. Ordered by
impact:

1. **Scalar/uniform co-issue in the Vortex pipeline.** A small scalar issue
   port for warp-uniform integer ops, branches, and address gen would let
   the inter-store ALU work overlap with `stream_send`s, mirroring GCN's
   scalar ALU. Largest expected impact for this workload.
2. **1-thread fast-path (SIMT-X-style).** Detect `tmask` popcount = 1 in
   issue and let the existing pipeline behave as an in-order scalar CPU
   (branch prediction on, simpler back-to-back forwarding). No new datapath.
3. **Helper-warp / DAE split (SW-only experiment).** Even with one core,
   split dispatcher and address-gen into two warps connected by a small
   shared-memory ring buffer. The address-gen warp runs ahead during the
   dispatcher warp's inter-store gaps. SW analogue of DAE; no RTL changes —
   a good way to measure the upper bound of what scalar co-issue would buy.

## 4. Reading List

- *Tawa: Automatic Warp Specialization for Modern GPUs with Asynchronous
  References* — arXiv 2510.14719 (CGO 2026).
- *Optimal Software Pipelining and Warp Specialization for Tensor Core GPUs* —
  arXiv 2512.18134.
- *A Performance Model for Warp Specialization Kernels* — arXiv 2506.11209.
- CUTLASS Ping-Pong / Persistent GEMM blog posts (PyTorch, Colfax Research).
- *A Decoupled Access/Execute Architecture for Mobile GPUs* — ACACES 2012.
- *Decoupled Affine Computation for SIMT GPUs* — ISCA 2017.
- *DeSC: Decoupled Supply-Compute Communication for Heterogeneous Systems* —
  MICRO 2015.
- *Efficient Data Supply for Hardware Accelerators with Decoupled Memory* —
  MICRO 2016 (Cornell).
- *Compiler Support for Speculation in DAE Architectures* — CC 2025
  (arXiv 2501.13553).
- *GhOST: a GPU Out-of-Order Scheduling Technique for Stall Reduction* —
  ISCA 2024 (Princeton Liberty).
- AMD GCN/CDNA whitepapers and *Chips and Cheese: GCN, AMD's GPU Architecture
  Modernization*.
- NVIDIA Nsight Compute Profiling Guide — warp-state taxonomy (short/long
  scoreboard, no-instruction, dispatch stall).

## Sources

- [Warp Specialization — CMU 15-779 slides](https://www.cs.cmu.edu/~zhihaoj2/15-779/slides/06-warp-specialization.pdf)
- [Tawa: Automatic Warp Specialization (arXiv 2510.14719)](https://arxiv.org/html/2510.14719)
- [Deep Dive on CUTLASS Ping-Pong GEMM](https://pytorch.org/blog/cutlass-ping-pong-gemm-kernel/)
- [CUTLASS Tutorial: GEMM kernel with Pipelining (Colfax)](https://research.colfax-intl.com/cutlass-tutorial-design-of-a-gemm-kernel/)
- [Persistent GEMM in CuTeDSL on Hopper](https://veitner.bearblog.dev/persistent-gemm-in-cutedsl-on-hopper/)
- [ACACES — DAE Architecture for Mobile GPUs (PDF)](https://personals.ac.upc.edu/jmanel/papers/acaces12.pdf)
- [Decoupled Affine Computation for SIMT GPUs (ISCA 2017, PDF)](https://www.cs.utexas.edu/~lin/papers/isca17.pdf)
- [DeSC: Decoupled Supply-Compute (MICRO 2015, PDF)](https://mrmgroup.cs.princeton.edu/papers/taejun_micro15.pdf)
- [Efficient Data Supply for Hardware Accelerators (MICRO 2016, PDF)](https://www.csl.cornell.edu/~tchen/files/accelmem-micro16.pdf)
- [Compiler Support for Speculation in DAE (arXiv 2501.13553)](https://arxiv.org/abs/2501.13553)
- [GhOST: GPU OoO Scheduling for Stall Reduction (ISCA 2024)](https://liberty.princeton.edu/Publications/isca24_ghost.pdf)
- [Nsight Compute Profiling Guide — warp states](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- [Modal GPU Glossary — Warp Execution State](https://modal.com/gpu-glossary/perf/warp-execution-state)
- [Modal GPU Glossary — Latency Hiding](https://modal.com/gpu-glossary/perf/latency-hiding)
- [Volkov, Understanding Latency Hiding on GPUs (Berkeley TR 2016)](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2016/EECS-2016-143.pdf)
- [Chips and Cheese: GCN, AMD's GPU Architecture Modernization](https://chipsandcheese.com/p/gcn-amds-gpu-architecture-modernization)
- [AMD GCN Architecture Whitepaper (PDF)](https://www.site.uottawa.ca/~mbolic/ceg4131/GCN_Architecture_whitepaper.pdf)
- [Unweaving Warp Specialization (Yadav)](https://rohany.github.io/blog/warp-specialization/)
- [SIMT-X: Extending SIMT to Out-of-Order Cores (TACO 2020)](https://dl.acm.org/doi/10.1145/3392032)
- [Spatiotemporal SIMT and Scalarization for Improving GPU Efficiency (TACO 2015)](https://dl.acm.org/doi/10.1145/2811402)
- [Convergence and Scalarization for Data-Parallel Architectures (CGO 2013, PDF)](https://www.cs.utexas.edu/~skeckler/pubs/cgo13.pdf)
- [Scalar-Vector GPU Architectures (Z. Chen, Northeastern PhD thesis, PDF)](https://ece.northeastern.edu/groups/nucar/publications/Zhongliang_Chen_thesis.pdf)
- [Simty: generalized SIMT execution on RISC-V (CARRV 2017, PDF)](https://carrv.github.io/2017/papers/collange-simty-carrv2017.pdf)
- [Intel Iris Xe Render Engine PRM (DG1, PDF)](https://www.x.org/docs/intel/DG1/intel-gfx-prm-osrc-dg1-vol09-renderengine.pdf)

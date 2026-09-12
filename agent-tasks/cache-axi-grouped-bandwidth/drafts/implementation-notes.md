# Grouped AXI implementation notes

The adapter and top changes have been applied to production RTL after freezing
the pre-change RTL snapshot. The adjacent RTL copies match the production files.
See ../results.md for completed verification and all baseline/K1/K2 cycle comparisons.

- `VX_axi_adapter.sv`: P-to-K request arbitration retains full software block address,
  destination, tag, data, strobes and requester index. One `VX_mem_remap` and one
  `VX_axi_write_ack` per group feed only ports `g+s*K`. All H ports remain reachable.
- `NUM_BANKS_OUT` controls K, `NUM_HBM_PORTS` controls H. Top default chooses the
  largest power of two <= min(P,H), with parameter or same-name macro override.
- K=1 selects group zero without zero-width slices; H=K bypasses destination-ready
  selection and response merging. Single requester IDs omit requester bits.
- AXI address output is the complete remapped physical address, with no per-port
  masking. Bank shift remains the existing platform-memory address width minus
  log2(physical banks), independent of adapter address width and K.
- Request xbar buffering is mandatory: a requested zero-sized output buffer is
  promoted to OUT_BUF=2. The library arbiter alone can change winner while stalled.
  Buffered address/destination survives independent AW/W acceptance and no new
  request can replace it until both channels finish. Existing nonzero buffer settings
  remain supported.
- Each group's H/K-to-1 response arbitration uses OUT_BUF=2; H=K is a direct bypass.
  The final K-to-P xbar likewise promotes zero-sized output buffering to 2, ensuring
  stalled cache responses remain stable. Arbitration stores only transport payloads;
  there is no issue-order reconstruction or response reorder buffer.
- Existing compressed tag allocation/release semantics remain: allocate at cache
  request handshake, release at cache response handshake. TAG_BUFFER_SIZE=1 uses
  a safe one-bit index and invalid/non-power-of-two sizes fail explicitly.
- Adapter `busy` is high for present input requests or accepted transactions not yet
  completed. A read retires at its cache response handshake; a write retires at AXI B.
  A 32-bit occupancy counter covers input queues, partial writes, read-return queues,
  output cuts, and external outstanding traffic. Its extended next value detects
  overflow/underflow. Cache drain now requires adapter idle in addition to existing
  cache/downstream conditions; wrapper write-drain logic is untouched.
- Equal 64-byte cache-line/AXI-beat/memory-block geometry is explicitly checked.
  Non-interleaved H>1 configurations fail explicitly rather than using a wrong map.
  Both adapter INTERLEAVE and platform interleave define are checked; physical-bank
  and H/K geometry are checked before simulation traffic.
- Top removes scalar cache wiring, two remappers and full LSU axi_demux. It packs
  adapter H arrays directly into existing per-HBM cuts. DMA restricted demux/mux
  ownership and mux ID extension are unchanged.

## Test request

- test_type: new_tb
- test_path: hw/unittest/axi_adapter
- sim_tool: vcs
- changed_files: hw/rtl/libs/VX_axi_adapter.sv, hw/rtl/Vortex_axi.sv
- test_params: P=2, H=8, K=1/2/4/8; P=1/H=1/K=1; 512-bit data;
  compressed and direct tags, TAG_BUFFER_SIZE=1 and normal queue sizes;
  REQ_OUT_BUF/RSP_OUT_BUF=0 and 2
- notes: Test full remap bank rotations and high address bits independently of K,
  backpressured/independent AW and W with newly arriving competing requests,
  reverse/random response order across same-group HBM endpoints, tag exhaustion
  and release only at cache handshake, exact-once consumption and busy after AR
  acceptance through read retirement / delayed B. Prove sustained request, response
  and write bandwidth for different groups and same-group serialization; cover
  invalid geometry and interleaving configurations. Never synthesize or use Verilator.

Then execute all six planned xrt-vcs-sim kernel gates for K=1 and K=2 with their
own improve/naive configurations. Preserve baseline profiling options (vecadd perf1,
FPINT perf3); compare both total-kernel and GEMM-node cycles for each FPINT shape.

## Baseline prerequisite

By root request, production `VX_gemm_node_naive.sv` was minimally changed before
baseline retry: an existing output DMA bound assertion referenced `output_mt_eff`
before its declaration, which VCS rejects. The same assertion now appears after
that declaration in its own always_ff with equivalent !reset/start/idle gating.
No datapath or functional control was changed.

## Verification state

Draft implementation inspected statically; no simulation or synthesis executed by
the implementation subagent. Root and verification agent own execution and results.

A second pre-existing naive prerequisite guards the simulation-only LMEM checker
with known-low reset (`reset === 1'b0`) to avoid speculative VCS tmerge diagnostics
before reset relays initialize. Both prerequisites are in the frozen baseline.

Final geometry checks also reject output address widths smaller than the physical
platform address and inconsistent DATA_WIDTH/DATA_SIZE overrides. Valid production
geometry and all five negative parameter probes pass the focused test suite.

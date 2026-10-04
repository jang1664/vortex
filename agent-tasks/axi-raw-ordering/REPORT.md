# AXI RAW protection implementation and measurements

## Decision rule
The user requested per-HBM-port write counters first. If the matched performance
loss is at least 3%, implement inflight-write tracking using VX_dp_ram.
Primary comparison: normal-memory TH16/MXU16 softmax_layout_fused cursor,
Q=K=32, batch=head=1, mask1, scale0.125, seed2986547050. Identical kernel binary.
Known reordered-response stress is correctness coverage, not the primary baseline.

## Original baseline
164179 cycles, PASS, reproduced again on 2026-10-04. The saved original
VX_axi_adapter is byte-identical to HEAD, SHA256
9a7103ac591f8e17d8ad001ed586218869c5e749d43c613b80fe2fbe8e078498.
Full logs: baseline_normal.log and baseline/VX_axi_adapter.sv.

## Phase 1: per-port counters
Each physical HBM port counts AW acceptance until B completion. Default capacity
16 is enforced with write backpressure; partial AW/W acceptance can still finish.
A read waits only for its selected port to become empty. Held admission preserves
ARVALID under backpressure. Read responses and B retirement remain independent.
No address/data RAM is introduced in this phase.

State estimate before synthesis: 6 bits per physical port (4 used + full + empty)
plus one admission bit per transport group: 26 live state bits for H4/K2.
Unused almost flags add 8 declared helper bits but are unconnected and removable.
Adders, comparisons, selectors and gates are extra combinational logic; no LUT,
Fmax or BRAM utilization estimate has been verified by synthesis.

Verification iteration 1: PASS via tools/verify_rtl.py, 44 unit cases plus credit
capacities 1/2/3 with 128-cycle delayed B. Original throughput assertions preserved.
Report: verify_phase1.json. Full-system measurements: phase1_port_counter/results.json.

Production source changes do not alter the running FPGA bitstreams or pipeline.


Phase1 full-system VCS:
- Reordered-response stress: PASS, 0 errors, 306482 cycles.
- Normal-memory matched baseline: PASS, 164299 vs 164179 cycles,
  +120 cycles / +0.07309%. Below the 3% primary threshold.
- Matched in-order stress: PASS304410 vs original PASS286220 cycles,
  +18190 cycles / +6.355%. This exceeds the user threshold under matched pressure;
  proceeding to the authorized VX_dp_ram inflight-write tracker.

## Phase 2: exact inflight-write addresses in VX_dp_ram

Implemented `VX_axi_write_hazards` per physical port, default 16 entries. AW
acceptance allocates a RAM slot with the full cache-line address and write ID.
A B response retires the oldest entry with the matching ID; global B ordering
is not required. Reads bypass an empty table. Otherwise, synchronous RAM scans
one valid slot per cycle and permits the read after excluding address conflicts.
Only matching writes must finish; unrelated writes may remain outstanding.
No younger write can arrive on that port while its request-group read is being
checked. An admitted AR remains stable under backpressure.

The ring does not skip occupied allocation slots, so out-of-order B can leave
free slots that are temporarily unavailable. Address scans can delay the request
group's head. These are conservative performance costs, not lost requests.

Verification iteration 2: PASS via tools/verify_rtl.py. 45 adapter cases, plus
directed helper checks for duplicate addresses, repeated IDs, B reordering,
simultaneous AW/B, and held read admission. Same-port unrelated reads explicitly
complete before B. Credit depths 1/2/3 and existing sustained-throughput checks
pass. Full-system VCS compilation also passes.

Resource accounting (logical state, before synthesis): with depth S, address
width A, write ID width I, and L=LOG2UP(S), each port has S*A address RAM bits;
S*I ID bits; 3*S valid/query/match mask bits; 2*L+3 pointer/control bits; and A
synchronous RAM output bits. The adapter also has one held-admission bit per
transport group. At S16/A28/H4, addresses occupy 1792 bits (224 bytes) total,
in four VX_dp_ram instances with OUT_REG=1 and RDW_MODE="R". The address array
is not replicated as an FF-based CAM; IDs still use parallel comparisons.
Physical BRAM/LUT counts and timing require synthesis and are not measured here.

## Final measured comparison

| Memory condition | Original | Per-port count | VX_dp_ram tracker | Tracker vs correct original |
|---|---:|---:|---:|---:|
| Normal | 164179 PASS | 164299 PASS | 164269 PASS | +0.055% |
| Matched in-order stalls | 286220 PASS | 304410 PASS | 291410 PASS | +1.813% |
| Reordered-response stalls | 283695 FAIL (2 errors) | 306482 PASS | 296909 PASS | Not a valid performance baseline |

Both comparable correct baselines are below the 3% threshold with the final
RAM tracker. All three tracker runs have zero functional errors, max_diff
0.000244, and identical kernel SHA256
fde8a343d616acffc607ade3d3d036a287021e1c83645ec0b07097561da5ec82.
The reordered-response baseline is incorrect and is used only as a failure
reproducer; its cycle count is not used for the final overhead claim.

This is a small deterministic TH16/MXU16 softmax probe, not a guarantee across
all kernels/shapes or a measurement of FPGA frequency. Production RTL is fixed;
existing FPGA bitstreams and the running rev3 pipeline still use their original
RTL. A newly synthesized bitstream is required to apply this protection on HW.

Reproduction: from the repository root, use the already configured isolated
`build_axi_raw_port` and run:

```bash
python3 agent-tasks/axi-raw-ordering/measure.py phase2_ram_tracker --cases reordered normal inorder
```

The script sources C4 v4, invokes build-local `ci/run_black.sh xrt-vcs-sim`,
and retains logs, cycle counts, input flags and kernel hashes. Its custom
testbench selection and source snapshots are recorded under this task directory
and `analysis_workspace/latency_on_hw/docs/softmax_l2_vcs_debug_20261004/`.

## Follow-up depth sweep
See [depth_sweep/REPORT.md](depth_sweep/REPORT.md) for depth16..128 matched
softmax measurements and depth16..512 synthetic write throughput.
The default remains16; `AXI_WRITE_PENDING_SIZE` can override it per config.

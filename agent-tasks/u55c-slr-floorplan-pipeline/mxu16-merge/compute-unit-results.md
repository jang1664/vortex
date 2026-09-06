# MXU16 merge: compute and full-node focused verification

Updated: 2026-09-06 23:23 KST. Compute units and corrected full-node fixtures PASS.

## Scope and source identity

- No RTL edits, synthesis, hardware execution, or Git mutations. A narrowly
  approved completion-scoreboard fixture update is described below.
- Frozen RTL digest, including new untracked RTL helpers:
  `2f54f404a8aac5bd2117c167c89878f312a555d82394fac7be7a7387fae5acdd`.
  Recipe: `rg --files hw/rtl | LC_ALL=C sort | xargs sha256sum | sha256sum`.
- Four independent fresh build directories were configured using
  `../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`.
- Corresponding TH16/TCol32 or TH16/TCol16 bigmem config was sourced before
  configure and tests; WLOAD is 4. SLR-off removes the presence-based
  `-DGEMM_SLR_PIPELINE` define, rather than assigning its value to zero.
- Simulator: VCS W-2024.09-SP1; system `/usr/bin/gcc` and `/usr/bin/g++`.
  Tests use `tools/verify_rtl.py unittest --sim vcs --timeout 1800`.
- `project-context`, `CLAUDE.md`, verification agent rules, and the existing
  simulation procedure were consulted. Referenced `harness/rules/testbench.md`
  and `harness/skills/run-test/SKILL.md` are absent; the current deterministic
  verification runner and Makefiles were used instead.

## Compute-unit matrix

All four complete `gemm_unit_v2` suites pass, with no fatal or assertion-error
markers in the simulation logs. No `NDEBUG` override was added.

| Fresh build directory | Geometry | SLR | Config C2 | Result |
|---|---|---:|---:|---|
| `build_merge_compute_mxu32_slr0` | MXU32, W4, DMA8, TMEM8 | 0 | 0 | PASS |
| `build_merge_compute_mxu32_slr1` | MXU32, W4, DMA8, TMEM8 | 1 | 0 | PASS |
| `build_merge_compute_mxu16_slr0` | MXU16, W4, DMA8, TMEM16 | 0 | 1 | PASS |
| `build_merge_compute_mxu16_slr1` | MXU16, W4, DMA8, TMEM16 | 1 | 1 | PASS |

The compute unit does not instantiate the command controller: the MXU16
config's C2 define is **not** evidence of exercising controller timing cuts.

Every suite retains these key coverage markers:

- `QPARAM_PARALLEL_PORTS_PASS simultaneous_64B=1 reg0_reg1=1 consumer_stage_release=1`.
- `M3_D3_RAW_STALL_PASSED rows=3 qdir=row stalls=1 early=0 nominal=3 writes=6`.
- `M5_ACC_READ_WRITE_ARBITRATION_PASSED rows=5 qdir=row write_stalls=2 writes=10`.
- Final `VX_gemm_unit_v2 unittest PASSED` marker.

Evidence in each build: `configure.log`, `config-evidence.txt`,
`gemm-unit-results.json`, and `hw/unittest/gemm_unit_v2/logs/{compile,sim}.log`.

| Image | `simv` SHA256 |
|---|---|
| MXU32 SLR0 | `4180d9df46bb42228b8ef6b137bd50f33dc3f0bf72328c5d932ca4b991d50cda` |
| MXU32 SLR1 | `5df6fee4e8e0bea45f28ee5c6e44a4fa27a8b5914cd402612d8b8ab2c5f12065` |
| MXU16 SLR0 | `2aeebce4f504aff402225e59b585271daa41da37a0846acfc2db9170be543466` |
| MXU16 SLR1 | `06a25074a489275d4f95b53785bf327934ac929e0d8307ff027cb37f36215cf9` |

## Full-node exploratory gate

The existing `gemm_node_improve` test was attempted on both SLR1 builds,
MXU32/C2=0 and MXU16/C2=1, with:

```text
--params 'M=32 N=64 K=128 QBLK=32 WTRANS=0 QDIR=0'
--extra-sim-args '+NO_WAVE +REQUIRE_OUTPUT_DBUF +REQUIRE_COMPLETION_ENDPOINTS'
```

Initial compilation could not find generated `VX_config.h`; configure alone
does not generate this header in a fresh build. Running the existing
`make -C hw config` target resolved the missing-header prerequisite without
source changes. Both full-node images then compiled successfully.

Both simulations stop at 1525 ns with the optional legacy endpoint checker:

```text
tb_VX_gemm_node_improve.sv:3091
COMPLETION_ENDPOINTS child done is not the exact architectural endpoint
```

The checker at lines 3083-3091 directly equates source-side global child
completion with backend `gemm_dma_ctrl_if.done` in the same cycle. This is not
the SLR transport contract: completion crosses back through registered
transport. The failure therefore does not establish a datapath or ownership
regression. However, this full-node attempt is **FAIL**, not a passing
completion/backpressure test, and did not reach its final numerical check.

Evidence: each SLR1 build's `gemm-node-results.json` records the initial
compile prerequisite failure; `gemm-node-configured-results.json` records
the subsequent simulation failure. The latter points to full simulation logs.
No assertion was globally disabled. Rather than drop the optional scoreboard,
the parent approved a narrowly scoped testbench contract update.

### Approved endpoint fixture update

Only `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv` was edited:

- At line 3063, independent testbench FFs sample backend completion and its tag.
  Expected source completion is delayed two cycles with the SLR define and
  remains direct locally. This matches `VX_gemm_dma_transport.sv:87`, whose
  always-ready reverse transport has two SLR FF stages and no launch EB.
  The comparison does not read the source interface as its expected value.
- Node output retirement was already registered one cycle after physical
  completion (`VX_gemm_node.sv:1053`, `:1064`, with an independent RTL assertion
  at `:1208`). A separate testbench FF models this cycle, while a raw physical
  output-completion counter must match final observed retirement count.
- Global DMA tag ownership is independently tracked from source command
  acceptance through expected completion. Unknown, duplicated, or mismatched
  return tags fail; completed commands cannot exceed accepted commands.
- Consecutive global completion cycles are legal for distinct owned commands;
  the old pulse-separation rule is retained for other non-overlap children.
- The same-cycle all-channel completion property remains on the raw backend
  endpoint, not the delayed source notification. Qparam physical endpoints
  and their existing one-cycle retirement checks are retained.
- Final coverage requires no pending return pipeline, no owned global tags,
  and equality of physical output completions and architectural retirements.

Original failing simulation logs are retained as
`gemm-node-legacy-fixture-sim.log` in both SLR1 builds and the MXU16 SLR0 build.
The local MXU16 legacy fixture fails later at 13515 ns due to its raw-versus-
registered output completion assumption, confirming this was not exclusively
an SLR return issue.

### Coverage-shape qualification

After the fixture update, M32/N64/K128 passes numerical checking (2048 outputs)
and the exact endpoint scoreboard on all four builds. However, it fails the
separate output-double-buffer coverage requirement for at least three outer
tiles, multiple K tiles, and M/N edge tiles. These are incomplete coverage
runs, not overall PASS results. Logs are retained as
`gemm-node-insufficient-shape-sim.log`, with runner reports named
`gemm-node-updated-fixture-results.json`.

A subsequent M3/N257/K256 attempt was rejected before command issue by the
existing fixture's N-multiple-of-MXU-width requirement. Logs are preserved as
`gemm-node-invalid-shape-sim.log` and `gemm-node-coverage-results.json`.
The geometry-qualified shape M3/N288/K256/QBLK32 has three N tiles, two K
tiles, an M edge and a 32-column N edge, with legal widths for both MXU
geometries. However, all four runs hit another existing optional fixture
limitation at line 3429: `OUTPUT_DBUF overlapping final-writeback tail models`.
Logs and reports are retained as `gemm-node-short-m-tail-fixture-sim.log`
and `gemm-node-full-coverage-results.json`.

Increasing M to 33 does not avoid that failure: all four configurations fail
the same checker. It starts a tail on `req_valid && packet_ctrl.last`, without
`req_ready`, and tracks only one active tail. Therefore a stalled last packet
or genuinely overlapping tails cannot be represented correctly. No DUT
failure is established by this model-capacity assertion. Further parameter
guessing was stopped, and additional fixture-update authority was requested.
All optional endpoint and output-double-buffer checks remain enabled; these
attempts are **FAIL**, not passing coverage claims. Current logs and
`gemm-node-output-coverage-results.json` record the M33 attempts.

### Approved output-tail fixture update

The parent approved a second narrow change in the same testbench:

- Accept a last input packet only on `req_valid && req_ready`, not during
  every stalled valid-high cycle.
- Replace the single active-tail model with an ordered testbench queue of
  accepted ACC physical-group identifiers and transaction tags.
- On actual `last_write`, compare the oldest accepted tail with
  `acc_result_data_out.ctrl.acc_wr_addr` and `acc_if.wr_req_tag`. The former
  fixed `ctrl_pipe[WRITE_CTRL_IDX]` is upstream of the elastic ACC result
  queue, so it is not the identity of a backpressured physical write.
- Pop the old tail before accepting a new tail on the same edge. Reject
  writeback without a previously accepted tail, tag/group mismatch, or
  premature release of **any** pending tail's physical ACC group.
- Final coverage requires all accepted tails to retire exactly once and the
  queue to drain. Existing output backpressure, numerical parity, group reuse,
  output ordering, same-group exclusion, and directed arbitration probes
  remain enabled.

The M33 legacy-tail failures are retained as
`gemm-node-m33-tail-fixture-sim.log`. Final reruns use the same
M33/N288/K256/QBLK32 shape and both `+REQUIRE_OUTPUT_DBUF` and
`+REQUIRE_COMPLETION_ENDPOINTS`; results are recorded separately in
`gemm-node-final-results.json`.

### Registered ownership contract and final results

The next run passed numerical comparison of 9,504 elements, endpoint
conservation, natural output overlap, backpressure, and ordered final tails in
all four configurations. It then failed the final legacy combinational probe:
that probe expected an unaccepted input-valid offer to make ACC busy in the
same cycle. This was already false in the pre-merge current revision.
`VX_gemm_acc_internal.sv:175` derives busy from registered pending counts;
the existing `gemm_unit_v2` directed test at lines 1473-1532 explicitly accepts
admission-edge output handoff and tests the registered fence afterward.

The full-node probe now checks the correct pre-acceptance property: an input
offer alone must not create combinational ownership or block the old owner's
output handoff. It does not inject an unowned compute command into the node,
force pending counters, or claim a real admission handshake. The live full-node
scoreboard still rejects same-group output handshakes during registered
ownership and checks every pending tail through physical writeback. Actual
admission-edge handoff, subsequent same-group blocking, and retirement are
covered by the four passing `gemm_unit_v2` suites, not by this offer-only probe.

After this test-only correction, deterministic `verify_rtl.py` reports
**PASS for all four full-node configurations**, using M33/N288/K256/QBLK32,
QDIR0/WTRANS0 with both optional coverage switches enabled. Every run compares
9,504 outputs, covers both physical ACC groups and group-0 reuse, observes
output backpressure, and drains output request/response and completion counts.
MXU16 runs retire 288 final tails and 594 output reads; MXU32 runs retire 72
final tails and 297 output reads. RTL physical-output enqueue/commit assertions
remain active, exercising actual local output DMA descriptors in both modes.

Final reports are `gemm-node-registered-contract-results.json` in each of the
four builds. Final compile/simulation logs remain under the unittest's `logs/`.
The immediately preceding failed probe logs are preserved as
`gemm-node-stale-admission-probe-sim.log`; earlier failed reports remain intact.
No RTL changed: the final RTL digest matches the frozen digest above.
Final testbench SHA-256 is
`f5e161a943c3f248e4fcd9338e4fdbd6f35475ea0816c6a9afd2d1dd77cde707`;
its Makefile SHA-256 is
`9712e99306ad5ea81ea75314ed6269852ff4d4c98f83152ba823d1c8c16c5284`.

## Limitations

- Compute-unit PASS is not an end-to-end performance result or 2% regression
  comparison; independent xrt-vcs-sim runs provide that evidence.
- The full-node post-drain directed probe checks offers only; actual
  admission/registered-fence coverage belongs to the compute-unit suite.
- No setup/hold, utilization, placement, routing, or hardware claim is made.

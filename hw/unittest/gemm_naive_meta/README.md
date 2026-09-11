# Staged naive metadata controller test request

Use the `rtl-improve` verification workflow from a configured build directory,
after sourcing the appropriate `configs/` file. This suite requires VCS and
system GCC/G++; it does not run a blackbox workload.

- `test_type`: `new_tb`
- `test_path`: `hw/unittest/gemm_naive_meta`
- `sim_tool`: `vcs`
- Compile/run environment: `TEST=controller BACKEND=naive`.
- Also run `TEST=types BACKEND=naive` and `TEST=types BACKEND=improve` at XLEN64.
- Configurations: TH16 with MXU16 and MXU32; PERF on/off for package/elaboration
  preservation. The controller itself adds no PERF counters.
- Use an absolute configured build test path with `tools/verify_rtl.py unittest`.
  `--params` affects the run invocation, so set TEST/BACKEND in the environment
  before compilation. `--extra-sim-args` selects the cases below.

Default `+CASE=positive` must report `TEST PASSED`. It checks every RID in every
wait slot, delayed nonzero dependencies in every local and DMA wait slot,
independent child progress, SRC_FREE-qualified refill, the four-member fenced
LOAD join, source-version preparation and a stable offer under backpressure,
exact command identity through queues, addresses above 4 GiB, simultaneous
owned notifications, bounded queue capacity, and three invocations without
reset with done delivery delays 17/0/1. Registered executor completion events
are intentionally controlled by the testbench; this proves controller
ownership, not real compute, bank visibility or numerical behavior.

`+CASE=unsupported_wait` must report `TEST PASSED`: RID31 fails closed while
another eligible child runs. It intentionally ends with a blocked command.

These negative cases must fail with the named DUT assertion, not merely the
testbench's fallback fatal or a timeout:

| Case | Required DUT diagnostic |
|---|---|
| `bad_opcode` | `non-real command opcode` |
| `bad_source` | `stale/unready source release` |
| `bad_owner` | `unowned/out-of-order child completion` |
| `duplicate_load` | `duplicate/stale fenced LOAD receipt` |
| `unreleased_load` | `LOAD reused unreleased/stale source generation` |

## Integration boundary

The new `VX_gemm_ctrl_naive_meta` and `VX_gemm_ctrl_naive_meta_if` are staged;
legacy FSM/controller/node wiring is unchanged. There are no transitional
legacy pins in the new interface. It uses improve's real-command low-nibble
encodings: Input7, Weight5, Scale6, Zero10, external LOAD1/STORE2. Integration
must adapt the old external executor byte opcode0x10/0x11. The existing `rd`
tensor selectors I/W/S/Z=0/1/2/3 and Output4 are preserved.

Children are Input0/Weight1/Scale2/Zero3/DMA4. Executors use modport `executor`;
the controller uses `controller`. A prepare handshake reserves the exact same
queued command for source-only work; subsequent issue must release that same
descriptor without fetching twice. The controller checks prepare version
waits, while actual writer/admission fences are carried in the command and
evaluated against the exported registered `sync_value[23]` at the executor.
Local completion is ordered by `done_work_seq`; DMA has one active owner.

`source_free_valid_i` must come from the actual closed-generation/all-engine
source-response join. DMA `done_valid` for LOAD must be fenced by bank commit
before the controller records its member. `executor_quiescent_i` must include
all transport, conversion and physical write work remaining after ordinary
Input ingress completion. G1's terminal Input done must already satisfy the
tile-scoped producer-close/bank-commit fence. These physical obligations are
not replaced by the controller testbench's modeled events.

The new controller stores one command stage plus four depth4 operand queues
and one depth8 DMA queue (25 command words, no explicit output copies), four
depth4 71-bit local inflight records plus one 71-bit DMA record, a 36-bit LOAD
receipt and two 37-bit T joins. It allocates ten prepare offer/sent bits and
one DMA-active bit. Existing FIFO primitive internal pointer/occupancy state
must be included in elaborated accounting; declared record counts fit the
frozen command/notification ceilings. No operand payload or TMEM scheduler is
added. The separate global DMA bank-pending 13-bit fence belongs to the DMA
integration task, not this controller.

Implementation status at handoff: source/static diff checks only; simulations
are delegated. Selecting the improve package branch reproduces HEAD package
text byte-for-byte after removing naive preprocessor branches. Full tool
preprocessing, elaboration/cost and cycle preservation remain verification
requirements.

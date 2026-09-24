# GEMM Unit V2 Node Integration and XRT-VCS Verification Plan

## 1. Goal

Integrate `VX_gemm_unit_v2` with the real `GEMM_IMPROVE` command and input
LDMA path, then verify the integration with the `fpint_gemm_ffn_hw`
application in `xrt-vcs-sim`.

The key RTL change is to make `VX_gemm_node` generate one complete
`gemm_input_ctrl_t` packet for every input data packet admitted into
`VX_gemm_unit_v2`. Accumulation addresses, read/write enables, mode, register
indices, and command completion metadata must be supplied directly by the
node. V2 must only pipeline and consume this metadata; it must not recover
command state or regenerate accumulation addresses internally.

This phase keeps the following properties established by the unit-level
work:

- the V2 input is always ready;
- every accepted input has a fixed writeback latency;
- immediate same-address dependencies use writeback forwarding;
- non-forwarded accumulation reads use the nominal/one-cycle-early scheduler;
- V1 and `VX_gemm_node_naive` remain unchanged.

## 2. Current State

The branch already contains a preliminary packet generator in
`VX_gemm_node.sv`. It derives an accumulation address from a captured command
and an input packet counter and drives `VX_gemm_unit_v2_if.packet_ctrl`.

Before blackbox verification, this logic must be audited and hardened against
the real improve command flow:

- `VX_gemm_fsm` emits `OP_I_LDMA_ARM` with the accumulation base in
  `cmd.rs1_data`, input source address in `cmd.rs2_data`, effective M count in
  `cmd.eff_mt`, and accumulation/register mode in `cmd.flags`;
- the input LDMA may insert bubbles between input requests;
- input-DMA completion is earlier than V2 writeback completion;
- the next command must not overwrite the active command context before its
  final packet is admitted and its final writeback is observed;
- packet metadata must advance on GEMM-unit input admission, not on command
  start, DMA start, or elapsed cycles.

The integration should refine this existing block rather than introduce a
second address generator or encode control metadata into LMEM tags.

### 2.1 Implemented state

The completed implementation now captures a V2-specific input-command
context from `cmd.rs1_data`, `cmd.eff_mt`, and `cmd.flags`, advances packet
metadata only on input admission, and keeps the command active until the
delayed `last_write`. The node no longer treats input-DMA completion as GEMM
completion.

XRT integration also exposed a backend latency difference: FPnew supplies an
internal one-cycle input buffer at operator `LATENCY=0`, whereas the DPI path
is combinational at the same setting. V2 now selects operator latency per
backend so FP16 multiply, FP32 multiply, and FP32 add all remain aligned with
their one-cycle control stages.

## 3. Interface Contract

Retain `VX_gemm_unit_v2_if` as the dedicated node-to-unit sideband interface.
Do not overload `VX_mem_bus_if.req_data.addr`, `tag`, or `flags` with V2-only
control fields.

For every accepted input packet:

```text
input_fire = i_gemm_bus_if.req_valid && i_gemm_bus_if.req_ready

packet_ctrl.valid       = input_fire
packet_ctrl.acc_rd_en   = command.is_accum
packet_ctrl.acc_wr_en   = 1
packet_ctrl.acc_rd_addr = command.acc_base
                        + packet_index * GEMM_PSUM_DATA_SIZE
packet_ctrl.acc_wr_addr = packet_ctrl.acc_rd_addr
packet_ctrl.quant_dir   = command.quant_dir
packet_ctrl.wreg_use_idx = command.wreg_use_idx
packet_ctrl.sreg_use_idx = command.sreg_use_idx
packet_ctrl.zreg_use_idx = command.zreg_use_idx
packet_ctrl.is_load     = !command.is_accum
packet_ctrl.last        = packet_index == packet_count - 1
```

`GEMM_PSUM_DATA_SIZE` is the byte stride of one accumulation-memory row. Read
and write addresses remain separate fields even while the improve command
uses the same address for both.

Use the decoded semantic command fields as the source of truth:

| V2 packet property | Improve command source |
| --- | --- |
| accumulation base | `cmd.rs1_data` |
| packet count | `cmd.eff_mt` |
| accumulation mode | `cmd.flags[3]` |
| quantization direction | `cmd.flags[5]` |
| weight register | `cmd.flags[2]` |
| scale register | `cmd.flags[1]` |
| zero-point register | `cmd.flags[0]` |

Avoid reparsing `cmd.instr[31:4]` for the packet count when `cmd.eff_mt`
already carries that decoded meaning. Assert that `cmd.eff_mt` and the input
LDMA packet count (`cmd.bound`) agree for `OP_I_LDMA_ARM` commands.

`packet_ctrl.last` means the last packet of the current input command. It is
not the kernel's final-K/output-store flag.

## 4. `VX_gemm_node` Changes

### 4.1 Capture a complete input-command context

Replace the loosely populated `gemm_unit_ctrl_t` use with a small V2-specific
node context containing only fields needed by input packet generation:

- `active`;
- `acc_base`;
- `packet_count`;
- `is_accum`;
- `quant_dir`;
- `wreg_use_idx`, `sreg_use_idx`, and `zreg_use_idx`;
- `packet_index`;
- an ingress-complete bit if needed to distinguish final admission from final
  writeback.

Capture the context exactly when a non-notify input command starts. Reject or
assert on a second input command while the current context is active.

The implementation must define the command-start/first-input corner case
explicitly. Use a combinational view of the incoming command when
`input_cmd_start` and `input_fire` coincide; otherwise use the registered
context. This removes dependence on an assumed minimum LDMA startup latency.

### 4.2 Advance metadata only with the data packet

Increment `packet_index` only on `input_fire`. Bubbles must preserve the next
address and all command metadata. Do not increment from `req_valid` alone,
even though V2 currently ties `req_ready` high; using the complete admission
event documents and enforces the interface contract.

Generate `packet_ctrl` from one selected context in a single combinational
block or equivalent packed-structure assignment. This reduces the chance of
mixing live command fields with stale registered fields across command
boundaries.

### 4.3 Separate ingress completion from compute completion

On admission of the packet marked `last`:

- stop accepting further packets for that command;
- retain any context required to validate the delayed completion;
- do not report command completion yet.

Drive `gemm_ctrl_if.input_read_flag.done` from
`gemm_unit_v2_if.last_write`. Keep the input command busy until this pulse so
the controller cannot replace the context while V2 still contains packets.
Clear the active command state exactly once on the final writeback.

`input_read_flag.idle` must describe the node command generator's ability to
accept a new input command, not merely `input_dma_ctrl_if.idle`.

### 4.4 Keep the data path direct and non-blocking

Continue connecting the input TMEM/LDMA request to V2 without a buffering
stage. The sideband and `i_gemm_bus_if.req_data.data` must enter V2 in the same
cycle.

Do not add a ready-dependent FIFO, credit scheme, or command FSM to
`VX_gemm_unit_v2`. Any command lifecycle state belongs in `VX_gemm_node`.

### 4.5 Preserve accumulation scheduling ownership

The node owns only command-to-packet expansion. V2 continues to own:

- fixed sideband delay through the arithmetic pipeline;
- immediate previous-packet same-address forwarding;
- forwarded-read suppression;
- nominal versus one-cycle-early SRAM read issue;
- final SRAM write timing.

The node must preserve commanded base addresses across K blocks. A later
accumulation command using the same base must therefore target the same PSUM
rows as the initial load command.

## 5. Assertions and Observability

Add non-synthesis checks at the node/V2 boundary:

1. `packet_ctrl.valid == input_fire`.
2. A valid packet is emitted only while an input command context exists or a
   command is starting in the same cycle.
3. `packet_count` is non-zero and equals the input LDMA request count.
4. Every accumulation address is aligned to `GEMM_PSUM_DATA_SIZE` and lies
   inside the configured accumulation-memory range.
5. `packet_index` changes only on `input_fire`.
6. Exactly one packet has `last=1` per input command.
7. No packet is admitted after the command's last packet.
8. `last_write` occurs only for a command whose last packet was admitted.
9. Exactly one `done` pulse is produced per non-notify input command.
10. A new input command cannot overwrite a command waiting for final
    writeback.

Expose or retain debug signals for command start, input admission, packet
index, accumulation address, read enable, last admission, last write, and
command done. These are the first signals to inspect if `xrt-vcs-sim` hangs.

## 6. RTL Verification Before Blackbox

### 6.1 V2 unit regression

Re-run `hw/unittest/gemm_unit_v2` to protect:

- fixed latency and always-ready behavior;
- nominal and early accumulation reads;
- immediate same-address forwarding;
- the two-packet `1.0 + 32.0 + 32.0 = 65.0` numerical case.

### 6.2 Improve node regression

Extend the node scoreboard so expected packet metadata is computed from the
issued input command and accepted LDMA packets, independently of the RTL
packet generator. Check:

- first packet metadata;
- address progression over multiple M rows;
- bubbles between input packets;
- load followed by one or more accumulation commands using the same base;
- register-index and quantization-direction changes between commands;
- final admission, delayed `last_write`, and one completion pulse;
- zero conflicts, underflows, dropped packets, and duplicate writes.

Retain at least these numerical regressions:

- `M=32, N=32, K=32`: load-only/partial-DMA-K coverage;
- `M=32, N=32, K=128`: repeated accumulation and early-read regression.

The node test should add a small `M=1, K=64` or equivalent case because it
reuses one PSUM address across K commands and matches the GEMV accumulation
shape more directly.

## 7. XRT-VCS Build and Test Flow

Run all commands from the configured `build` directory. Before invoking VCS,
verify the binary is available with `which vcs`.

```bash
cd build
source ../configs/improve_th32_tcol32_dcache_simx.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix=$HOME/tools/vortex
which vcs
make -C sim/xrtsim_vcs -B FSDB_DUMP= simv
```

The simulation-oriented config preserves `GEMM_IMPROVE`, the V2/node path,
MXU tile size, TMEM/ACC sizes, thread count, cache topology, and memory
topology. It omits only the orthogonal hardware-exp/FPU-DSP defines that made
the original hwexp VCS run exceed the 30-minute integration budget. The
forced `simv` build is required because the `-y` RTL library sources are not
normal make prerequisites.

Use the repository wrapper:

```bash
MAKEFLAGS='FSDB_DUMP=' ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw \
  --args "-m 1 -n 32 -k 32 -q 32 -t 0 -d 0"
```

`MAKEFLAGS='FSDB_DUMP='` overrides the wrapper's environment assignment via
GNU make command-line precedence and avoids full-design FSDB overhead while
retaining the required `ci/run_black.sh` flow.

The XRT-VCS source flow uses the RTL search directories, so the first compile
must confirm that `VX_gemm_unit_v2.sv` and `VX_gemm_unit_v2_if.sv` are found
without adding stale copied RTL. Change an explicit source list only if the
compile log proves it is required.

### Directed blackbox sequence

Run small cases first so failures remain waveform- and log-sized:

| Order | Arguments | Purpose |
| ---: | --- | --- |
| 1 | `-m 1 -n 32 -k 32 -q 32 -t 0 -d 0` | compile and load-only smoke test |
| 2 | `-m 1 -n 32 -k 64 -q 32 -t 0 -d 0` | one PSUM row reused by an accumulation command |
| 3 | `-m 1 -n 32 -k 128 -q 32 -t 0 -d 0` | repeated GEMV-style accumulation |
| 4 | `-m 32 -n 32 -k 64 -q 32 -t 0 -d 0` | multi-row address progression and accumulation |
| 5 | `-m 32 -n 32 -k 128 -q 32 -t 0 -d 0` | established node regression in the full stack |
| 6 | `-m 32 -n 32 -k 64 -q 32 -t 1 -d 0` | weight-layout metadata change |
| 7 | `-m 32 -n 32 -k 64 -q 32 -t 0 -d 1` | QROW metadata and FP16 input-scaler path |

For every run, require:

- application output `PASSED` with zero numerical mismatches;
- normal job/frontend completion with no timeout;
- no VCS assertion, `$error`, `$fatal`, X-propagation, ACC-bank conflict, or
  early-read underflow;
- matching command count, last-admission count, last-write count, and done
  count.

The application currently inserts notify/wait synchronization between GEMM
commands. Therefore these blackbox cases validate repeated PSUM accumulation
but may not create cycle-adjacent same-address input packets. Immediate
forwarding remains proven by the dedicated V2 unittest. If end-to-end
forwarding coverage is required, add a directed node-level stream that emits
the dependency without the application wait; do not claim forwarding
coverage from an xrt run that never observes `admission_forward`.

## 8. Failure Triage Order

1. **Compile/elaboration failure**: check discovery and ordering of the V2
   interface, package type, and module before changing RTL behavior.
2. **No input packets**: trace command dispatch, input LDMA start, and
   `input_fire`.
3. **Input accepted but no completion**: compare packet count, `last`, V2
   pipeline occupancy, `last_write`, and node `done`.
4. **K32 passes but K64/K128 fails**: inspect `is_accum`, repeated base
   address, ACC read issue, and writeback data.
5. **M1 passes but M32 fails**: inspect packet-index increments, row-byte
   address stride, bank selection, and last-packet index.
6. **Only QROW or register-buffer variants fail**: inspect captured command
   flags and ensure a later command cannot alter an in-flight packet's
   sideband.
7. **Numerical output is correct but the app hangs**: inspect delayed
   `last_write`, input command active/idle state, notify, and wait targets.

Use the first failing directed case as the reproducer. Do not widen to the
full application sweep until that case passes cleanly.

## 9. Expected File Changes

Primary changes:

- `hw/rtl/core/gemm/VX_gemm_node.sv`
  - command context capture;
  - admission-driven packet metadata generation;
  - completion/idle ownership;
  - boundary assertions and debug visibility.
- `hw/unittest/gemm_node_improve/tb_VX_gemm_node_improve.sv`
  - independent command-to-packet scoreboard;
  - GEMV-shaped accumulation and lifecycle checks.

Change only if the contract requires it:

- `hw/rtl/VX_gpu_pkg.sv`
  - adjust `gemm_input_ctrl_t` only if a required semantic field is missing.
- `hw/rtl/core/gemm/VX_gemm_unit_v2_if.sv`
  - interface cleanup without changing the fixed-latency contract.
- XRT-VCS source/build files
  - only when the compile log demonstrates a source-discovery problem.

Do not modify as part of this integration:

- `VX_gemm_unit.sv` or `VX_gemm_unit_if.sv`;
- `VX_gemm_node_naive.sv`;
- the V1 unittest;
- the kernel command encoding or `VX_gemm_fsm.sv`, unless blackbox evidence
  proves the existing decoded command contract is incorrect;
- synthesis or FPGA packaging files.

## 10. Completion Criteria

The integration is complete when:

1. every V2 input accepted from the real LDMA path has command-correct,
   cycle-aligned accumulation metadata generated by `VX_gemm_node`;
2. bubbles and command boundaries cannot corrupt packet index, address, mode,
   or register selection;
3. command completion is generated by the delayed final V2 writeback;
4. V2 unit and improve-node unittests pass;
5. the directed `fpint_gemm_ffn_hw` xrt-vcs cases pass, including `M=1` with
   multiple K microtiles and `M=32, N=32, K=128`;
6. no V1/naive behavior is changed;
7. no top-level synthesis or hardware run is performed in this phase.

## 11. Execution Result

Completed on 2026-08-04 with the simulation-oriented TH32 dcache config.

- V2 VCS unittest passed with both FPnew and DPI backends. The immediate
  same-address forwarding case retained one SRAM read, one forwarded consume,
  two writes, and the final value 65.0.
- Improve-node VCS passed the DPI `M=1, N=32, K=64` load-to-accumulate case
  with LDMA gaps and 32/32 numerical outputs matching.
- All seven directed `fpint_gemm_ffn_hw` xrt-vcs cases in section 7 passed
  host numerical comparison and completed normally.
- The original xrt hang was a dropped final write: DPI `LATENCY=0` produced
  scaler data in the INT2FP cycle while write control expected it one cycle
  later. Backend-specific operator latency restored fixed control/data
  alignment.
- No V1, naive-node, GEMM FSM, kernel encoding, synthesis, or hardware path
  was changed for the integration.

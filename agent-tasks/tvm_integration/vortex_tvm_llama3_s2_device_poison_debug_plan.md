# Vortex TVM Llama3 S2 Device-Poison Debug Plan

## 1. Goal

Find and fix the intermittent U55C device-poison observed during long S2 canonical checkpoint
runs, without weakening numerical checks or accepting retries as a workaround.

The accepted result is a full C4/fused S2 run that performs prefill followed by three decode
phases, compares all 32 layers against canonical inputs, and completes repeatedly in a stable XRT
process with no device poison, hang, timeout, retry, or non-finite output.

This task is the stability prerequisite for the separate C1/C2/C3 Llama3 compile plan. It does not
add those backends itself.

## 2. Accepted functional baseline

Freeze the following facts before debugging:

- Vortex branch/revision baseline: `fpint` at or after `88c97164`;
- TVM branch/revision baseline: `fi_system` at or after `e2ca2b0be`;
- C4/fused S2 `(batch=1, prompt=7, cache capacity=16)` completes free-running prefill and three
  decode steps with 128 layer calls, correct cache lengths `7, 8, 9, 10`, and zero retries;
- an isolated S2 decode-3 canonical-input run validates all 32 layers, selects token `29229`, and
  reports normalized/logit relative-L2 `2.643e-5`/`4.716e-5`;
- a fresh-process layer-10 checkpoint run passes with hidden relative-L2 about `1.60e-4`;
- some long full-chain strict checkpoint runs poison the device after approximately layer 10 or
  layer 20 rather than failing at one deterministic tensor value;
- S1, S3, and S4 full free-running paths complete on the same pinned C4 image;
- the same-input numerical evidence does not currently justify an RTL, FSM, AXI, or xclbin change.

Primary starting artifacts are under:

```text
/home/jaeyongjang/project.local/tvm/build/llama3_synthetic_s2_fused_causal_softmax_v1
```

Use the pinned C4 image and profile:

```text
alias: C4_v3
xclbin: /opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c_f100_fpint_64300e5119/bin/vortex_afu.xclbin
fingerprint: 62540fb747aa762d5cfab874e36d1daac7119d8cff3e32d659a104b460383256
config: configs/improve_th32_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh
```

## 3. Definition of device poison

Do not use `device poison` as a generic label for a numerical mismatch. Classify each failure by
the first externally observable signature:

1. a kernel launch or AP-idle wait exceeds its timeout;
2. XRT reports a command, CU, context, or device error;
3. a launch returns but a later unrelated launch cannot start or complete;
4. the process exits while the same BDF remains unusable to a fresh process;
5. only the current process is broken and a fresh process on the same BDF succeeds;
6. the device remains healthy but one output violates the numerical policy.

Only cases 1-5 are device/runtime stability failures. Case 6 follows the normal layer/operator
numerical debugging path.

## 4. Non-goals and safety boundaries

- Do not loosen canonical FP16, cache, code-mismatch, cosine, or relative-L2 thresholds to hide a
  runtime failure.
- Do not add automatic layer retries to an accepted inference path.
- Do not reset, reprogram, or otherwise mutate an FPGA outside the managed Slurm allocation.
- Do not start with RTL simulation. Use it only after an identical physical kernel invocation,
  including input bytes, descriptors, addresses, and prior runtime state, fails operation-locally.
- Do not mix C1/C2/C3 compiler work into this task.
- Do not treat one successful rerun as a fix; the problem is intermittent.

## 5. Reproducer and observability changes

### 5.1 Bounded canonical layer-range replay

Extend the diagnostic runner so one process can execute an explicit phase and inclusive layer
range using recorded canonical inputs, for example `decode_2, layers 8..15`. The runner must:

- feed the captured input hidden and seven cache tensors for the selected layer;
- preserve the exact package, archive slice, VM mode, allocator, and xclbin contract;
- optionally stop after every layer or continue through the range;
- produce the same comparison summary as a full strict run;
- reject a range request unless the reference artifact contains all required tensors.

This is a diagnostic mode, not a production inference shortcut.

### 5.2 Per-invocation event trace

Write a bounded JSONL event stream around every layer invocation. Record at minimum:

- run UUID, Slurm job/step, hostname, U55C BDF/device index;
- Vortex/TVM revisions, package hashes, xclbin hash, profile fingerprint;
- phase, global layer, attempt, VM identity, logical operation group, and cumulative launch count;
- input hidden, output hidden, position, parameter, and cache device addresses and byte sizes;
- allocator and state-transport policy;
- timestamps immediately before launch, after launch, before each required D2H comparison copy,
  and after comparison;
- output hashes and finite/magnitude summary when the invocation returns;
- the first XRT/runtime error string without truncating its causal error line.

Flush each event before the next device action so a process or device failure does not erase the
last successful boundary. Avoid unbounded per-kernel logging during the normal acceptance run.

### 5.3 Device-health probes

Add a small, already validated probe kernel that can be invoked only at explicit diagnostic
boundaries. Use it to distinguish:

- device already unhealthy before the suspect layer;
- suspect layer poisons the device;
- layer completes and a subsequent D2H copy or VM teardown poisons the current process;
- only the long process state is broken while a fresh process remains healthy.

The probe must not reprogram the image or conceal the original failure.

## 6. Controlled experiment matrix

Run one variable at a time with identical S2 tensors and no retries.

| Experiment | Layer execution | Comparison/copy behavior | Purpose |
| --- | --- | --- | --- |
| A | full free-running | final summaries only | reconfirm production baseline |
| B | full canonical inputs | layer comparisons disabled | isolate canonical feeding from D2H diagnostics |
| C | full canonical inputs | hidden comparison only | measure output-copy contribution |
| D | full canonical inputs | hidden plus seven cache outputs | reproduce strict checkpoint load |
| E | one phase at a time | full strict comparison | separate accumulated process state from tensor shape |
| F | bounded layer ranges | full strict comparison | locate first poison boundary |
| G | one suspect layer repeated | fixed addresses | test invocation count without allocation churn |
| H | one suspect layer repeated | controlled address sweep | test address/lifetime dependence |

For G/H, compare pooled and naive allocation only after the fixed-address case. Keep the same
process and programmed image when testing invocation count. Use a fresh managed allocation when
testing whether the BDF remains poisoned across processes.

## 7. Debugging milestones

### Milestone A: Reproduce and classify

1. Run the accepted S2 free trace once to prove the allocation starts healthy.
2. Run the historical full strict command with unique shared-status path and event tracing.
3. Capture the first poison signature and the last completed layer/device action.
4. Immediately test the health probe in the same process when possible.
5. Test the same probe from a fresh process inside the same managed allocation.

**Exit gate:** at least one failure is classified using Section 3, with a durable event trace and
no ambiguity about whether the first failure occurred in kernel execution, D2H comparison,
allocator/lifetime work, or external device state.

### Milestone B: Minimize the trigger

Use the matrix in Section 6 and binary-search phase/layer ranges. Determine the smallest sequence
of operations that changes a healthy run into the classified poison state.

The reproducer must state all of the following explicitly:

- required number and order of layer calls;
- whether layer identity or only call count matters;
- whether canonical versus live tensors matter;
- whether D2H cache comparisons are required;
- whether fixed versus changing addresses matter;
- whether VM creation/destruction or retained VMs matter;
- whether the failure survives a fresh process or requires device recovery.

**Exit gate:** the trigger is reproducible enough to distinguish the leading hypothesis from at
least two alternatives. If the event remains statistically intermittent, record trial counts and
failure frequency rather than claiming determinism.

### Milestone C: Fix the owning layer

Apply the narrowest fix supported by the reproducer:

- runner lifetime/ownership fix if a producer VM or tensor is released too early;
- bounded buffer reuse if allocator churn or address aliasing is causal;
- runtime synchronization/error-propagation fix if an asynchronous copy or command is observed
  past its ownership boundary;
- shared-status isolation fix if independent jobs/processes collide;
- XRT/device-infrastructure escalation with a standalone reproducer if the problem persists below
  the TVM/Vortex runtime boundary;
- compiler/kernel fix only if identical physical kernel inputs reproduce the failure locally.

Do not introduce a sleep, retry, host reconstruction of resident state, or device reset as the
production fix.

**Exit gate:** the reduced reproducer passes its stress threshold and fails again when the causal
fix is intentionally removed or disabled, when such an A/B check is safe and practical.

### Milestone D: Full stability acceptance

Run, with retries disabled:

1. three consecutive S2 full strict canonical chains in one persistent process;
2. three fresh-process S2 full strict canonical chains on managed allocations;
3. one S2 free-running chain;
4. S1 and S4 strict/free regression representatives;
5. the reduced reproducer stress loop.

Every accepted run must preserve exact cache lengths, finite outputs, package/profile identity,
and the stage-aware numerical policy.

**Exit gate:** zero poison, timeout, retry, and non-finite outputs across the matrix. Any device or
infrastructure recovery required between nominal runs is a failure.

## 8. Investigation order

Use this order and stop when evidence identifies the owner:

1. package/xclbin/profile/BDF/shared-status identity;
2. first failing device action and same-process health probe;
3. diagnostic D2H copy volume and ordering;
4. VM/tensor lifetime and allocator address reuse;
5. persistent-process call count and runtime command ownership;
6. fresh-process health on the same managed BDF;
7. generated kernel source and identical-input operation replay;
8. RTL simulation only for a proven operation-local hardware mismatch.

## 9. Required tests and artifacts

- host tests for layer-range and phase validation, missing-reference rejection, and trace schema;
- runner syntax and package/reload regression tests;
- reduced hardware reproducer JSONL logs;
- full S2 strict traces from all acceptance repetitions;
- health-probe results and exact BDF allocation records;
- before/after failure-frequency table;
- an execution report containing the proven root cause, fix, rejected hypotheses, and remaining
  infrastructure limitations.

Do not commit large hardware logs or reference `.npz` files. Commit the plan, source, focused unit
tests, concise report, and small machine-readable summaries; retain bulky artifacts under the TVM
build directory with recorded paths and hashes.

## 10. Final acceptance criteria

The task is complete only when:

1. `device poison` has one precise first-failure signature;
2. a bounded reproducer identifies the causal runtime, runner, compiler, or infrastructure layer;
3. the fix is evidence-driven and does not use retries, sleeps, resets, or weaker numerical gates;
4. S2 full strict canonical inference passes three persistent and three fresh-process repetitions;
5. S1/S4 regressions pass;
6. exact package, xclbin, profile, address, and allocation evidence is retained;
7. no RTL/FSM change is made without an identical-input operation-level hardware mismatch;
8. the result is documented before beginning C1/C2/C3 full package compilation.


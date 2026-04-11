# RTL Improve Loop

Iterative RTL implementation and verification loop. The user provides an improvement idea, then RTL and verification subagents iterate until all tests pass (max 10 iterations).

## Overview

```
User ─── idea ───► Agent ─── implement ───► RTL Subagent
                                                │
                                                ▼
                                          Verify Subagent ◄──┐
                                                │            │
                                            pass? ── No ─── RTL Subagent (fix)
                                                │
                                               Yes
                                                │
                                              Done
```

## Step 1: Idea Alignment

Before any code changes, confirm the improvement idea with the user.

- The user MUST explicitly describe what to improve and why.
- Use `hw_design_json` files (`*.simple.json`) to communicate hardware spec and structure when relevant.
- Identify which modules/files will be affected.
- Agree on the scope — do NOT expand beyond what the user asked.

**Spec document**: Create `agent-tasks/<task_path>/<feature-name>-spec.md` at the start of this step. Update it as the spec is refined through discussion with the user. The spec doc should contain:
- Goal: what is being improved and why
- Scope: affected modules/files
- Design decisions made during discussion
- Constraints and assumptions
- Final agreed spec (marked as "confirmed" before proceeding to Step 2)

Once the idea is confirmed and the spec doc is finalized, proceed to Step 2.

## Step 2: RTL Implementation

Spawn an **RTL Implementation subagent** (`subagent_type: "RTL Implementation"`).

Provide the subagent with:
- The confirmed improvement idea (what and why)
- Affected files and modules
- Relevant architecture context (hw_design_json, docs)
- Any constraints from the user

The RTL subagent:
- Implements the RTL changes
- Determines what tests are needed and prepares a **test request** for the verify subagent:

```
Test Request Format:
- test_type: "unittest" | "blackbox" | "new_tb"
- test_path: e.g., "hw/unittest/gemm_node_improve"
- test_params: e.g., "M=32 N=32 K=128 QBLK=32"
- sim_tool: "vcs" | "verilator"
- changed_files: [list of modified files]
- notes: any special instructions for verification
```

If a new module is added, the RTL subagent must also create the testbench (`test_type: "new_tb"`).

## Step 3: Verification

Spawn a **Verification subagent** (`subagent_type: "Verification"`).

Provide the subagent with:
- The test request from Step 2
- Current iteration number (1-indexed)

The Verification subagent:
- Runs `python tools/verify_rtl.py` with the appropriate arguments
- Does NOT interpret or fix errors — only reports results

```
Report Format (returned by verify_rtl.py):
- status: "pass" | "compile_error" | "sim_fail"
- error_log: relevant log excerpt (truncated to key errors)
- test_name: which test was run
- iteration: N / 10
```

## Step 4: Fix (if needed)

If status is NOT "pass", spawn the **RTL Implementation subagent** again with:
- The verification report (status + error_log)
- The original improvement idea (for context)
- The list of changed files
- Instruction: fix the issue reported, do NOT change the test request unless the test itself is wrong

## Step 5: Loop Control

- Repeat Steps 3-4 until status is "pass" or iteration reaches 10.
- If max iterations reached without pass, STOP and report to user:
  - Summary of all iterations and their failure modes
  - The current state of changes
  - Ask the user how to proceed

## Iteration Log

Append iteration results to `agent-tasks/<task_path>/STATUS.yaml` throughout the loop. Update it after **every** verification iteration. Use the following format per iteration:

```markdown
### <Feature Name> — Iteration N
- **Status**: compile_error | sim_fail | pass
- **Error summary**: (one-line description of what went wrong)
- **Root cause**: (what was actually wrong)
- **Fix applied**: (what the RTL subagent changed)
- **Lesson**: (reusable insight, if any)
```

This log serves two purposes:
1. **During the loop** — prevents the RTL subagent from repeating the same fix. Always include the full log when spawning subagents.
2. **After completion** — the user can review what happened and the lessons learned persist for future work.

## Step 6: Blackbox Tests (after all unit tests pass)

When the test plan includes blackbox tests (Level 2), **invoke the `/run-bb-common` skill** — do NOT run blackbox.sh directly.

The run-bb-common skill knows:
- Required `CONFIGS` environment variables per driver (xrt_vcs needs `-DNUM_THREADS`, `-DLMEM_LOG_SIZE`, etc.)
- Correct `DRIVER` environment variable
- How to interpret pass/fail results

If no blackbox skill exists or it's insufficient, check `harness/rules/testing-*.md` for the exact commands and CONFIGS for each test. **Never run blackbox.sh with empty CONFIGS** — xrt_vcs will silently build with wrong RTL configuration.

## Autonomous Flow (Announce & Proceed)

When a task completes and the next step is ambiguous or there are multiple remaining tasks, the agent should:

1. **Announce** the next task it will proceed with and the reasoning (1-2 sentences).
2. **Proceed immediately** without waiting for user confirmation.
3. The user can interrupt at any time to redirect.

Priority order for remaining tasks (highest first):
1. Fix compile errors or test failures from the current iteration
2. Continue the current verification loop (next iteration)
3. Next item in the remaining work list from `STATUS.yaml`
4. Items listed in the handoff document

**Blocking rule**: Do NOT skip a failing task to move on to the next one. If a task is failing (even if the failure is pre-existing), it must be resolved or explicitly marked as "deferred by user" before proceeding. Downstream tasks may depend on the current one passing.

Do NOT ask "what should I do next?" — decide and proceed. Only ask the user when there is genuine ambiguity that cannot be resolved from context (e.g., two equally valid approaches with different trade-offs).

## Rules

- The main agent orchestrates the loop — subagents do NOT call each other directly.
- Each subagent invocation is independent — always provide full context.
- Verification subagent must use `tools/verify_rtl.py` for deterministic checking — no manual log interpretation.
- RTL subagent must not modify test infrastructure unless `test_type: "new_tb"`.
- On compile errors, RTL subagent fixes syntax/structural issues first before re-verifying.
- **Blackbox tests MUST use `/run-bb-common` skill or follow the exact commands in `harness/rules/testing-*.md`.** Do not improvise blackbox.sh invocations.

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

**Spec document**: Create `docs/rtl-improve/<feature-name>-spec.md` at the start of this step. Update it as the spec is refined through discussion with the user. The spec doc should contain:
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

Maintain `docs/rtl-improve/<feature-name>-log.md` throughout the loop. Update it after **every** verification iteration. Format:

```markdown
# <Feature Name> — Iteration Log

## Iteration 1
- **Status**: compile_error | sim_fail | pass
- **Error summary**: (one-line description of what went wrong)
- **Root cause**: (what was actually wrong)
- **Fix applied**: (what the RTL subagent changed)
- **Lesson**: (reusable insight, if any)

## Iteration 2
...
```

This log serves two purposes:
1. **During the loop** — prevents the RTL subagent from repeating the same fix. Always include the full log when spawning subagents.
2. **After completion** — the user can review what happened and the lessons learned persist for future work.

## Rules

- The main agent orchestrates the loop — subagents do NOT call each other directly.
- Each subagent invocation is independent — always provide full context.
- Verification subagent must use `tools/verify_rtl.py` for deterministic checking — no manual log interpretation.
- RTL subagent must not modify test infrastructure unless `test_type: "new_tb"`.
- On compile errors, RTL subagent fixes syntax/structural issues first before re-verifying.

# Run FSM

Execute a task FSM. The user invokes this with `/run-fsm <task_name>`.

## Steps

1. **Load FSM** — The task argument can be a slash-separated path (e.g., `port-scale/dma-debug`). Read `agent-tasks/<task_path>/fsm.json` and `agent-tasks/<task_path>/STATUS.yaml`.

2. **Parse current state** — Extract the FSM state from the `fsm.state` field in STATUS.yaml:
   ```yaml
   fsm:
     file: fsm.json
     state: ANALYZE
   ```
   If no `fsm` field exists, start from `initial_state` in the FSM JSON and write it.

3. **Display current state** — Show the user:
   - Current state name and description
   - Checklist items for this state
   - Available transitions and their conditions
   - Allowed subagent types

4. **Execute the state** — Perform the work described in the state's `description`:
   - Only launch subagent types listed in `allowed_subagents`
   - Log all actions in STATUS.yaml under `## Progress Log` with timestamps
   - If a step fails, log it in `## Pitfalls` and transition to `on_fail` state

5. **Evaluate checklist** — Before transitioning, confirm each checklist item:
   - Log each item's status (done/not done) in STATUS.yaml
   - ALL items must be done before transitioning

6. **Confidence check** — If the current state has `confidence_check: true` in the FSM JSON:
   - Write a structured claim for the Confidence Check subagent:
     ```
     ## Claim
     <What you believe to be true based on this state's work>

     ## Evidence
     <What you read/observed — specific files, line numbers, test results>

     ## Planned Action
     <What you intend to do in the next state>
     ```
   - Launch the Confidence Check subagent (`subagent_type: "Confidence Check"`)
   - If **FAIL**: log the uncertainties in STATUS.yaml. Resolve each one (read code, run test, or ask user), then re-run the confidence check.
   - If **PASS**: proceed to transition.

7. **Transition** — When checklist is complete (and confidence check passed, if required):
   - Evaluate which transition condition is met
   - Update the `fsm.state` field in STATUS.yaml:
     ```yaml
     fsm:
       file: fsm.json
       state: NEW_STATE
     ```
   - Log the transition: `[HH:MM] FSM: STATE_A → STATE_B (reason)`

8. **Loop** — Go back to step 3 with the new state. Continue until reaching a terminal state (empty transitions).

9. **Done** — When reaching terminal state, report final status to user.

## Subtask Support

- If the task argument contains `/`, treat it as a nested path: `agent-tasks/<path>/STATUS.yaml`
- After parsing current state, if STATUS.yaml has a `parent` field, also read the parent's STATUS.yaml and display parent context (name, state).
- After reaching DONE, propagate state to parent:
  1. Read parent STATUS.yaml (resolve `parent.path` relative to root task dir)
  2. Update `children[].state` for this task to `DONE`
  3. If all children in parent are DONE, remind agent to evaluate parent transitions

## Error Recovery

- If context is lost (compaction), re-read STATUS.yaml to recover the current FSM state
- If the agent is unsure which transition to take, ask the user
- Never skip a checklist item — if it can't be verified, stay in the current state

## Example Session

```
[14:30] FSM: Starting at ANALYZE
[14:30] ANALYZE checklist:
  [ ] Failure reproduced
  [ ] Root cause identified and written in STATUS.yaml
[14:31] Launching Verification subagent to reproduce failure...
[14:35] Verification result: FAIL at output[3][7], got=0x3C00 exp=0x4000
[14:35] ANALYZE checklist:
  [x] Failure reproduced
  [ ] Root cause identified and written in STATUS.yaml
[14:36] Reading VX_gemm_node.sv docs...
[14:40] Root cause: accumulator not cleared between K-tiles
[14:40] ANALYZE checklist:
  [x] Failure reproduced
  [x] Root cause identified and written in STATUS.yaml
[14:40] FSM: ANALYZE → IMPLEMENT (Root cause identified, fix plan described)
```

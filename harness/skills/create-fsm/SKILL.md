# Create FSM

Interactively create a task FSM with the user.

## Steps

1. **Read the schema** — Read `docs/fsm-schema.md` to understand the JSON format and STATUS.yaml schema.

2. **Ask the user** for:
   - Task name (becomes the directory under `claude-tasks/` or under a parent task)
   - Goal of the workflow
   - Rough list of phases/steps
   - If `--parent <parent_path>` is specified, this is a subtask. Verify parent's STATUS.yaml exists at `claude-tasks/<parent_path>/STATUS.yaml`.

3. **Draft the FSM** — Based on the user's description, propose a JSON FSM:
   - Keep it flat and under 10 states
   - Every non-terminal state needs `on_fail`
   - Include a `DONE` terminal state
   - Set `allowed_subagents` based on what each state does
   - Write concrete `checklist` items (not vague — things the agent can actually verify)
   - Write concrete `transitions` conditions

4. **Show the FSM to the user** — Display the JSON and a simple state diagram:
   ```
   ANALYZE → IMPLEMENT → VERIFY → DONE
      ↑__________|           |
      ↑______________________|
   ```

5. **Iterate** — Let the user refine states, transitions, checklist items.

6. **Confidence check on the FSM itself** — Before saving, launch the Confidence Check subagent to verify the FSM accurately captures the user's intent:
   ```
   ## Claim
   This FSM accurately represents the user's intended workflow.

   ## Evidence
   User's stated goal: <summarize>
   User's stated steps: <summarize>
   Proposed FSM: <paste JSON>

   ## Planned Action
   Save this FSM and begin execution.
   ```
   The checker evaluates:
   - Are there user requirements not reflected in any FSM state?
   - Are state descriptions ambiguous (could agent interpret differently than user intended)?
   - Are transition conditions objectively verifiable (not subjective like "analysis complete")?
   - Are checklist items specific enough (file names, line numbers, concrete actions)?
   - Are there missing failure paths or edge cases?

   If **FAIL**: show the uncertainties to the user, resolve them together, update the FSM, and re-run the check.
   If **PASS**: proceed to save.

7. **Save** — Write the final FSM:
   - Root task: `claude-tasks/<task_name>/fsm.json`
   - Subtask: `claude-tasks/<parent_path>/<task_name>/fsm.json`

8. **Initialize STATUS.yaml** — Create STATUS.yaml with parent/children fields:
   ```yaml
   task: <task_name>
   parent: null                    # or {name: <parent>, path: <parent_status_path>} for subtasks
   children: []
   fsm:
     file: fsm.json
     state: <initial_state>
   completed_work: []
   pitfalls: []
   ```
   For subtasks, set `parent.path` relative to the root task directory.

9. **Register in parent** (subtasks only) — Update parent's STATUS.yaml to add the new child:
   ```yaml
   children:
     - name: <task_name>
       path: <path_to_child_status_yaml>   # relative to root task dir
       state: <initial_state>
   ```

10. **Confirm** — Tell the user to run `/run-fsm <task_path>` to start execution.

# Create FSM

Interactively create a task FSM with the user.

## Steps

1. **Read the schema** — Read `docs/fsm-schema.md` to understand the JSON format.

2. **Ask the user** for:
   - Task name (becomes the directory under `docs/`)
   - Goal of the workflow
   - Rough list of phases/steps

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

6. **Save** — Write the final FSM to `docs/<task_name>/fsm.json`.

7. **Initialize STATUS.yaml** — Create `docs/<task_name>/STATUS.yaml`:
   ```yaml
   task: <task_name>
   fsm:
     file: fsm.json
     state: <initial_state>
   completed_work: []
   pitfalls: []
   ```

8. **Confirm** — Tell the user to run `/run-fsm <task_name>` to start execution.

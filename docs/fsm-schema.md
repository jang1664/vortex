# FSM Schema

Task workflows are defined as finite state machines in JSON. Each FSM lives at `docs/<task_name>/fsm.json`.

## JSON Format

```json
{
  "name": "human-readable name",
  "task_name": "directory name under docs/",
  "initial_state": "STATE_A",
  "states": {
    "STATE_A": {
      "description": "What the agent does in this state",
      "checklist": [
        "Item the agent must verify before transitioning"
      ],
      "allowed_subagents": ["RTL Implementation", "Verification"],
      "transitions": {
        "STATE_B": "Condition to move to STATE_B",
        "STATE_C": "Condition to move to STATE_C"
      },
      "on_fail": "STATE_A"
    },
    "DONE": {
      "description": "Terminal state — task complete",
      "checklist": [],
      "allowed_subagents": [],
      "transitions": {},
      "on_fail": null
    }
  }
}
```

## Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Human-readable FSM name |
| `task_name` | string | yes | Task directory name (for `docs/<task_name>/`) |
| `initial_state` | string | yes | Starting state key |
| `states` | object | yes | Map of state_key → state definition |

### State Definition

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `description` | string | yes | What the agent does in this state |
| `checklist` | string[] | yes | Items to verify before transitioning (can be empty) |
| `allowed_subagents` | string[] | yes | Subagent types allowed in this state (empty = none) |
| `transitions` | object | yes | Map of target_state → condition string (empty = terminal) |
| `on_fail` | string\|null | yes | State to go to on failure (null = terminal) |

## Rules

1. **Flat structure** — no nested FSMs. Keep states under 10 per FSM.
2. **Terminal state** — at least one state must have empty `transitions` (typically `DONE`).
3. **on_fail** — every non-terminal state must specify where to go on failure.
4. **allowed_subagents** — enforced by hook. Main agent cannot launch a subagent type not listed for the current state.
5. **checklist** — agent must confirm all items before transitioning. These are logged in STATUS.md.

## STATUS.md Integration

The current FSM state is tracked in STATUS.md with a machine-readable header:

```markdown
<!-- FSM: {"file": "fsm.json", "state": "IMPLEMENT"} -->
```

This line is placed at the top of STATUS.md. The run-fsm skill and hooks parse this to determine the current state.

## Example

```json
{
  "name": "RTL Improve Loop",
  "task_name": "rtl-improve",
  "initial_state": "ANALYZE",
  "states": {
    "ANALYZE": {
      "description": "Analyze the problem: read logs, identify root cause",
      "checklist": [
        "Failure reproduced",
        "Root cause identified and written in STATUS.md"
      ],
      "allowed_subagents": ["Verification"],
      "transitions": {
        "IMPLEMENT": "Root cause identified, fix plan described",
        "DONE": "No fix needed"
      },
      "on_fail": "ANALYZE"
    },
    "IMPLEMENT": {
      "description": "Implement the RTL fix",
      "checklist": [
        "Files modified listed in STATUS.md",
        "Change description written"
      ],
      "allowed_subagents": ["RTL Implementation"],
      "transitions": {
        "VERIFY": "Implementation complete"
      },
      "on_fail": "ANALYZE"
    },
    "VERIFY": {
      "description": "Run tests to verify the fix",
      "checklist": [
        "Test command and result logged in STATUS.md"
      ],
      "allowed_subagents": ["Verification"],
      "transitions": {
        "DONE": "All tests pass",
        "ANALYZE": "Test failed — need re-analysis"
      },
      "on_fail": "ANALYZE"
    },
    "DONE": {
      "description": "Task complete",
      "checklist": [],
      "allowed_subagents": [],
      "transitions": {},
      "on_fail": null
    }
  }
}
```

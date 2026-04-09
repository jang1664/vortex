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

1. **Tasks can be nested** — each subtask has its own FSM. Keep individual FSMs under 10 states.
2. **Terminal state** — at least one state must have empty `transitions` (typically `DONE`).
3. **on_fail** — every non-terminal state must specify where to go on failure.
4. **allowed_subagents** — enforced by hook. Main agent cannot launch a subagent type not listed for the current state.
5. **checklist** — agent must confirm all items before transitioning. These are logged in STATUS.md.

## STATUS.yaml Integration

The current FSM state is tracked in `STATUS.yaml` under the `fsm` field:

```yaml
fsm:
  file: fsm.json
  state: IMPLEMENT
```

The run-fsm skill and hooks parse this to determine the current state.

## STATUS.yaml Schema

### Root Task

```yaml
task: port-scale
parent: null
children:
  - name: dma-axi-debug
    path: dma-axi-debug/STATUS.yaml
    state: IN_PROGRESS
fsm:
  file: fsm.json
  state: IN_PROGRESS
completed_work: [...]
pitfalls: [...]
```

### Subtask

```yaml
task: dma-axi-debug
parent:
  name: port-scale
  path: STATUS.yaml              # relative to root task dir
children: []
fsm:
  file: fsm.json
  state: ANALYZE
completed_work: [...]
pitfalls: [...]
```

### Field Reference

| Field | Type | Description |
|-------|------|-------------|
| `task` | string | Task name |
| `parent` | object\|null | `null` for root tasks |
| `parent.name` | string | Parent task name |
| `parent.path` | string | Path to parent STATUS.yaml, relative to root task dir |
| `children` | array | List of child tasks (empty for leaf nodes) |
| `children[].name` | string | Child task name |
| `children[].path` | string | Path to child STATUS.yaml, relative to root task dir |
| `children[].state` | string | Cached FSM state of child (kept in sync by run-fsm) |
| `fsm.file` | string | Relative path to FSM JSON definition |
| `fsm.state` | string | Current FSM state |
| `completed_work` | array | Completed phases with details |
| `pitfalls` | array | Persistent record of failures and gotchas |

### Path Convention

All paths in `parent.path` and `children[].path` are **relative to the root task directory** (e.g., `docs/port-scale/`). This ensures paths remain valid regardless of nesting depth.

```
docs/port-scale/                          # root task dir
  STATUS.yaml                             # parent: null
  dma-axi-debug/
    STATUS.yaml                           # parent.path: STATUS.yaml
    address-fix/
      STATUS.yaml                         # parent.path: dma-axi-debug/STATUS.yaml
```

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

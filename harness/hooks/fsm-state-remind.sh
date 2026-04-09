#!/bin/bash --norc --noprofile
# PostToolUse hook for Agent: FSM state update reminder
# After a subagent completes, reminds main agent to update STATUS.yaml and evaluate transitions.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only trigger for Agent tool
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

# Find active FSM: deepest non-DONE STATUS.yaml in the task tree
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
source "$(dirname "$0")/_find-active-fsm.sh"

# No active FSM → no-op
if [ -z "$FSM_HEADER" ]; then
    exit 0
fi

TASK_DIR=$(dirname "$STATUS_FILE")
FSM_STATE=$(echo "$FSM_HEADER" | jq -r '.state // empty')
FSM_FILE=$(echo "$FSM_HEADER" | jq -r '.file // empty')
FSM_PATH="$TASK_DIR/$FSM_FILE"

if [ -z "$FSM_STATE" ] || [ ! -f "$FSM_PATH" ]; then
    exit 0
fi

# Get checklist and transitions for current state
CHECKLIST=$(jq -r --arg state "$FSM_STATE" '.states[$state].checklist // [] | .[]' "$FSM_PATH" 2>/dev/null)
TRANSITIONS=$(jq -r --arg state "$FSM_STATE" '.states[$state].transitions // {} | to_entries[] | "  → \(.key): \(.value)"' "$FSM_PATH" 2>/dev/null)

# Check for parent task context
PARENT_INFO=""
PARENT_NAME=$(grep -m1 '^\s*name:' "$STATUS_FILE" | head -1)
# Look for parent under the 'parent:' block (line after 'parent:' that has 'name:')
_in_parent=0
while IFS= read -r line; do
    if echo "$line" | grep -q '^parent:'; then _in_parent=1; continue; fi
    if [ $_in_parent -eq 1 ]; then
        if echo "$line" | grep -q '^\s\+name:'; then
            PARENT_INFO=$(echo "$line" | sed 's/.*name:\s*//' | tr -d ' "'\''')
            break
        fi
        if echo "$line" | grep -q '^[^ ]'; then break; fi
    fi
done < "$STATUS_FILE"

cat <<EOF
FSM REMINDER — Current state: $FSM_STATE${PARENT_INFO:+ (subtask of: $PARENT_INFO)}
Subagent completed. Now:
1. Log the result in $STATUS_FILE with timestamp
2. If the subagent failed, log in pitfalls
3. Evaluate checklist:
$CHECKLIST
4. If all checklist items are done, evaluate transitions:
$TRANSITIONS
5. Update the fsm.state field in STATUS.yaml if transitioning
6. If transitioning to DONE and this is a subtask, update parent's children[].state
EOF

exit 0

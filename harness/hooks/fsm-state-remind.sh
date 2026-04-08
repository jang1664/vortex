#!/bin/bash --norc --noprofile
# PostToolUse hook for Agent: FSM state update reminder
# After a subagent completes, reminds main agent to update STATUS.md and evaluate transitions.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only trigger for Agent tool
if [ "$TOOL_NAME" != "Agent" ]; then
    exit 0
fi

# Find active FSM
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
FSM_HEADER=""
STATUS_FILE=""

for f in "$PROJECT_DIR"/docs/*/STATUS.md; do
    [ -f "$f" ] || continue
    header=$(head -1 "$f" | grep -oP '<!-- FSM: \K.*(?= -->)')
    if [ -n "$header" ]; then
        FSM_HEADER="$header"
        STATUS_FILE="$f"
        break
    fi
done

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

cat <<EOF
FSM REMINDER — Current state: $FSM_STATE
Subagent completed. Now:
1. Log the result in $STATUS_FILE (## Progress Log) with timestamp
2. If the subagent failed, log in ## Pitfalls
3. Evaluate checklist:
$CHECKLIST
4. If all checklist items are done, evaluate transitions:
$TRANSITIONS
5. Update the FSM header in STATUS.md if transitioning
EOF

exit 0

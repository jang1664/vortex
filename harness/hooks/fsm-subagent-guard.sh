#!/bin/bash --norc --noprofile
# PreToolUse hook for Agent: FSM subagent guard
# Blocks subagent launch if the subagent type is not in allowed_subagents for current FSM state.
# If no FSM is active, allows all subagents (no-op).

INPUT=$(cat)
SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# If no subagent_type specified, allow (it's a general-purpose agent)
if [ -z "$SUBAGENT_TYPE" ]; then
    exit 0
fi

# Find active FSM: look for STATUS.yaml files with FSM header
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
FSM_HEADER=""
STATUS_FILE=""

for f in "$PROJECT_DIR"/docs/*/STATUS.yaml; do
    [ -f "$f" ] || continue
    # Extract fsm.state and fsm.file from YAML using grep/sed
    fsm_state=$(grep -m1 '^\s*state:' "$f" | sed 's/.*state:\s*//' | tr -d ' "'\''')
    fsm_file=$(grep -m1 '^\s*file:' "$f" | sed 's/.*file:\s*//' | tr -d ' "'\''')
    if [ -n "$fsm_state" ] && [ -n "$fsm_file" ]; then
        FSM_HEADER="{\"state\":\"$fsm_state\",\"file\":\"$fsm_file\"}"
        STATUS_FILE="$f"
        break
    fi
done

# No active FSM → allow everything
if [ -z "$FSM_HEADER" ]; then
    exit 0
fi

# Parse current state and fsm file
TASK_DIR=$(dirname "$STATUS_FILE")
FSM_STATE=$(echo "$FSM_HEADER" | jq -r '.state // empty')
FSM_FILE=$(echo "$FSM_HEADER" | jq -r '.file // empty')

if [ -z "$FSM_STATE" ] || [ -z "$FSM_FILE" ]; then
    exit 0
fi

FSM_PATH="$TASK_DIR/$FSM_FILE"
if [ ! -f "$FSM_PATH" ]; then
    exit 0
fi

# Check if subagent type is in allowed_subagents for current state
ALLOWED=$(jq -r --arg state "$FSM_STATE" '.states[$state].allowed_subagents // [] | .[]' "$FSM_PATH" 2>/dev/null)

if [ -z "$ALLOWED" ]; then
    # No allowed_subagents defined or empty → block
    echo "{\"decision\":\"block\",\"reason\":\"FSM state '$FSM_STATE' does not allow any subagents. Allowed: none.\"}"
    exit 2
fi

if echo "$ALLOWED" | grep -qxF "$SUBAGENT_TYPE"; then
    exit 0
else
    ALLOWED_LIST=$(echo "$ALLOWED" | tr '\n' ',' | sed 's/,$//')
    echo "{\"decision\":\"block\",\"reason\":\"FSM state '$FSM_STATE' does not allow subagent type '$SUBAGENT_TYPE'. Allowed: [$ALLOWED_LIST].\"}"
    exit 2
fi

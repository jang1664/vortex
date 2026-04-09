#!/bin/bash --norc --noprofile
# Shared helper: find the deepest active (non-DONE) FSM task.
# Source this from hooks — it sets: STATUS_FILE, FSM_HEADER, TASK_DIR, FSM_STATE, FSM_FILE
#
# Algorithm: find all STATUS.yaml under claude-tasks/, skip DONE tasks, pick the deepest path.

PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}"

STATUS_FILE=""
FSM_HEADER=""
TASK_DIR=""
FSM_STATE=""
FSM_FILE=""

_BEST_DEPTH=0

while IFS= read -r f; do
    [ -f "$f" ] || continue

    _state=$(grep -m1 '^\s*state:' "$f" | sed 's/.*state:\s*//' | tr -d ' "'\''')
    _file=$(grep -m1 '^\s*file:' "$f" | sed 's/.*file:\s*//' | tr -d ' "'\''')

    [ -z "$_state" ] || [ -z "$_file" ] && continue
    [ "$_state" = "DONE" ] && continue

    # Count depth: number of path segments between claude-tasks/ and the file
    _rel="${f#$PROJECT_DIR/claude-tasks/}"
    _depth=$(echo "$_rel" | tr '/' '\n' | wc -l)

    if [ "$_depth" -gt "$_BEST_DEPTH" ]; then
        _BEST_DEPTH=$_depth
        STATUS_FILE="$f"
        FSM_STATE="$_state"
        FSM_FILE="$_file"
        TASK_DIR=$(dirname "$f")
        FSM_HEADER="{\"state\":\"$_state\",\"file\":\"$_file\"}"
    fi
done < <(find "$PROJECT_DIR/claude-tasks" -name "STATUS.yaml" 2>/dev/null | sort)

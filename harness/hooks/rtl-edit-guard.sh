#!/bin/bash --norc --noprofile
# PreToolUse hook for Edit|Write: RTL edit guard
# When FSM is active: block RTL edits unless from RTL Implementation subagent
# When no FSM is active: allow all edits (main agent can edit RTL directly)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# Only check RTL files
if ! echo "$FILE_PATH" | grep -qE '/hw/.*\.(sv|vh|v)$'; then
    exit 0
fi

# RTL Implementation and Implementer subagents are always allowed
if [ "$AGENT_TYPE" = "RTL Implementation" ] || [ "$AGENT_TYPE" = "Implementer" ]; then
    exit 0
fi

# Check if FSM is active
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
source "$(dirname "$0")/_find-active-fsm.sh"

# No active FSM → allow main agent to edit RTL
if [ -z "$FSM_HEADER" ]; then
    exit 0
fi

# FSM is active → block unless RTL Implementation subagent
echo '{"decision":"block","reason":"BLOCKED: During FSM run, main agent must not edit RTL files directly. Use RTL Implementation or Implementer subagent instead."}'
exit 2

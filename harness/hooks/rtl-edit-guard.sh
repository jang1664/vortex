#!/bin/bash --norc --noprofile
# PreToolUse hook for Edit|Write: RTL edit guard
# Block RTL file edits unless called from RTL Implementation subagent

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

if echo "$FILE_PATH" | grep -qE '/hw/.*\.(sv|vh|v)$'; then
    if [ "$AGENT_TYPE" != "RTL Implementation" ]; then
        echo '{"decision":"block","reason":"BLOCKED: Main agent must not edit RTL files directly. Use RTL Implementation subagent instead."}'
        exit 2
    fi
fi

exit 0

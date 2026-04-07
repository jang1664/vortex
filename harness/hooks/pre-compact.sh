#!/bin/bash --norc --noprofile
# PreCompact hook: inject context recovery instructions after compaction
# Finds the active task's STATUS.md and tells the agent to read it post-compaction.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Find all docs/*/STATUS.md files
STATUS_FILES=$(find "$PROJECT_DIR/docs" -maxdepth 2 -name "STATUS.md" 2>/dev/null)

if [ -z "$STATUS_FILES" ]; then
    exit 0
fi

# Build a recovery message listing all active tasks
RECOVERY_MSG="Context was compacted. To recover working context, read these files:\\n"
while IFS= read -r f; do
    REL_PATH="${f#$PROJECT_DIR/}"
    RECOVERY_MSG+="- $REL_PATH\\n"
done <<< "$STATUS_FILES"
RECOVERY_MSG+="\\nAlso re-read any relevant spec or handoff files in the same directories."

jq -n --arg msg "$RECOVERY_MSG" '{
  hookSpecificOutput: {
    hookEventName: "PreCompact",
    additionalContext: $msg
  }
}'
exit 0

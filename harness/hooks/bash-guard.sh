#!/bin/bash --norc --noprofile
# PreToolUse hook for Bash: test execution guard + conda inject
# 1) Block test-execution commands (must use Verification subagent)
# 2) Inject conda env activation

TARGET_ENV="vortex"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command')

# --- Test execution guard ---
if echo "$CMD" | grep -qE '(blackbox\.sh|verify_rtl\.py|unittest.*make\s+(run|clean)|make\s+(run|clean).*unittest|/simv\b)'; then
    echo '{"decision":"block","reason":"BLOCKED: Main agent must not run tests directly. Use Verification subagent instead."}'
    exit 2
fi

# --- Conda inject ---
# Skip if already has conda activate/run
if echo "$CMD" | grep -q "conda activate\|conda run"; then
    exit 0
fi

# Check conda env exists
if ! conda info --envs 2>/dev/null | grep -q "^$TARGET_ENV "; then
    echo "BLOCK: conda env '$TARGET_ENV'가 존재하지 않습니다." >&2
    exit 2
fi

# Inject conda activate
WRAPPED="eval \"\$(conda shell.bash hook)\" && conda activate $TARGET_ENV && $CMD"

jq -n --arg cmd "$WRAPPED" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "Injected conda env",
    updatedInput: {
      command: $cmd
    }
  }
}'
exit 0

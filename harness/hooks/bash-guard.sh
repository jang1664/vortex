#!/bin/bash --norc --noprofile
# PreToolUse hook for Bash: test execution guard + conda inject
# When FSM is active: block test execution unless from Verification subagent
# When no FSM is active: allow all commands (main agent can run tests directly)

TARGET_ENV="vortex"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')

# --- Test execution guard (only when FSM is active) ---
if echo "$CMD" | grep -qE '(blackbox\.sh|verify_rtl\.py|unittest.*make\s+(run|clean)|make\s+(run|clean).*unittest|/simv\b)'; then
    # Verification subagent is always allowed
    if [ "$AGENT_TYPE" != "Verification" ]; then
        # Check if FSM is active
        PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
        source "$(dirname "$0")/_find-active-fsm.sh"

        if [ -n "$FSM_HEADER" ]; then
            echo '{"decision":"block","reason":"BLOCKED: During FSM run, main agent must not run tests directly. Use Verification subagent instead."}'
            exit 2
        fi
    fi
fi

# --- Conda inject ---
# Skip if already has conda activate/run
if echo "$CMD" | grep -q "conda activate\|conda run"; then
    exit 0
fi

# Check conda env exists
if ! conda info --envs 2>/dev/null | grep -q "^$TARGET_ENV "; then
    echo "BLOCK: conda env '$TARGET_ENV' does not exist." >&2
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

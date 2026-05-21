#!/bin/bash --norc --noprofile
# PreToolUse hook: 모든 Bash 명령에 conda env 활성화를 주입
TARGET_ENV="vortex"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command')

# 이미 conda activate/run이 있으면 그냥 통과
if echo "$CMD" | grep -q "conda activate\|conda run"; then
    exit 0
fi

# conda env 존재 여부 체크
if ! conda info --envs 2>/dev/null | grep -q "^$TARGET_ENV "; then
    echo "BLOCK: conda env '$TARGET_ENV'가 존재하지 않습니다. 먼저 설치해주세요: conda env create -f vortex.yaml" >&2
    exit 2
fi

# conda activate를 주입 (conda run은 복합 명령에서 문제가 있어서 activate 사용)
WRAPPED="eval \"\$(conda shell.bash hook)\" && conda activate $TARGET_ENV && $CMD"

# jq로 안전하게 JSON 구성 (특수문자/따옴표 이스케이프)
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

source agent-tasks/naive-acc-select/configs/on.sh
CONFIGS="${CONFIGS/-DDMA_SPLIT_RSP_DEPTH=8/-DDMA_SPLIT_RSP_DEPTH=16}"
export CONFIGS

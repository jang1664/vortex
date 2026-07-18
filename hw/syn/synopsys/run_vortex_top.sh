#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VORTEX_HOME="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RESULT_ROOT="${SYN_RESULT_ROOT:-${VORTEX_HOME}/build/hw/syn/synopsys}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 (--alias NAME | --config PATH) [--alias-map PATH]" >&2
  exit 2
fi

RUN_TAG="selected_config"
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; ++i)); do
  case "${ARGS[i]}" in
    --alias)
      if ((i + 1 < ${#ARGS[@]})); then
        RUN_TAG="${ARGS[i + 1]}"
      fi
      ;;
    --alias=*)
      RUN_TAG="${ARGS[i]#--alias=}"
      ;;
    --config)
      if ((i + 1 < ${#ARGS[@]})); then
        RUN_TAG="$(basename "${ARGS[i + 1]}" .sh)"
      fi
      ;;
    --config=*)
      RUN_TAG="$(basename "${ARGS[i]#--config=}" .sh)"
      ;;
  esac
done

if [[ ! "${RUN_TAG}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  RUN_TAG="selected_config"
fi

mkdir -p "${RESULT_ROOT}"
(
  cd "${VORTEX_HOME}"
  SYN_RESULT_ROOT="${RESULT_ROOT}" \
    python3 hw/syn/synopsys/run_syn_vortex_axi.py "$@" \
    |& tee "${RESULT_ROOT}/Vortex_axi_${RUN_TAG}.run.log"
)

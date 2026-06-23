#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="python3"
fi

PLOT="${PLOT:-all}"
OUT_DIR="${OUT_DIR:-outputs_main/figures_script}"

has_arg() {
  local name="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == "${name}" || "${arg}" == "${name}="* ]]; then
      return 0
    fi
  done
  return 1
}

if [[ $# -gt 0 && "${1}" != -* ]]; then
  PLOT="$1"
  shift
fi

if [[ $# -gt 0 && "${1}" != -* ]]; then
  OUT_DIR="$1"
  shift
fi

cmd=("${PYTHON_BIN}" "${SCRIPT_DIR}/plot_notebook.py")
if ! has_arg "--plot" "$@"; then
  cmd+=(--plot "${PLOT}")
fi
if ! has_arg "--out-dir" "$@"; then
  cmd+=(--out-dir "${OUT_DIR}")
fi
if ! has_arg "--x-group-axis" "$@"; then
  cmd+=(--x-group-axis batch)
fi
cmd+=("$@")

printf '+'
printf ' %q' "${cmd[@]}"
printf '\n'
exec "${cmd[@]}"

#!/usr/bin/env bash

# Shared helpers for resolving XRT device indexes and user-function BDFs.
# This file is safe to source; it performs work only when executed directly.

_xrt_device_probe_max() {
  local probe_max="${XRT_DEVICE_PROBE_MAX:-8}"
  if [[ ! "$probe_max" =~ ^[0-9]+$ || "$probe_max" == "0" ]]; then
    probe_max=8
  fi
  echo "$probe_max"
}

fpga_id_to_bdf() {
  case "$1" in
    0) echo "0000:2a:00.1" ;;
    1) echo "0000:3d:00.1" ;;
    *) return 1 ;;
  esac
}

bdf_to_fpga_id() {
  case "$1" in
    0000:2a:00.1|2a:00.1|*:2a:00.1) echo "0" ;;
    0000:3d:00.1|3d:00.1|*:3d:00.1) echo "1" ;;
    *) return 1 ;;
  esac
}

resolve_xrt_smi() {
  local xrt_smi="${XRT_SMI:-/opt/xilinx/xrt/bin/xrt-smi}"
  if [[ "$xrt_smi" == */* ]]; then
    [[ -x "$xrt_smi" ]] && echo "$xrt_smi"
    return
  fi
  command -v "$xrt_smi" || true
}

detect_accessible_xrt_index() {
  local smi="$1"
  local probe_max found=()
  local idx

  [[ -n "$smi" ]] || return 1
  probe_max="$(_xrt_device_probe_max)"

  for ((idx = 0; idx < probe_max; ++idx)); do
    if "$smi" --batch --force examine --device "$idx" --report platform >/dev/null 2>&1; then
      found+=("$idx")
    fi
  done

  if ((${#found[@]} == 0)); then
    return 1
  fi
  if ((${#found[@]} > 1)); then
    echo "WARNING: multiple accessible XRT devices: ${found[*]}; using ${found[0]}" >&2
  fi
  echo "${found[0]}"
}

_detect_xrt_bdf_from_output() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.1)\] ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

detect_xrt_bdf_for_index() {
  local smi="$1"
  local index="$2"
  local output

  [[ -n "$smi" ]] || return 1
  [[ -n "$index" ]] || return 1

  output="$("$smi" examine --device "$index" --report platform 2>&1 || true)"
  _detect_xrt_bdf_from_output <<< "$output"
}

detect_available_xrt_bdf() {
  local smi="$1"
  local output

  [[ -n "$smi" ]] || return 1

  output="$("$smi" examine --report platform 2>&1 || true)"
  _detect_xrt_bdf_from_output <<< "$output"
}

should_auto_detect_fpga_id() {
  local fpga_id="${1:-${FPGA_ID:-auto}}"

  case "$fpga_id" in
    auto|detect|-1) return 0 ;;
  esac

  if [[ -n "${XRT_DEVICE_INDEX:-}" || -n "${XRT_DEVICE_BDF:-}" ]]; then
    return 0
  fi

  if [[ "$fpga_id" == "0" && -n "${SLURM_JOB_ID:-}${SLURM_STEP_ID:-}" && -z "${VORTEX_POWER_FORCE_FPGA_ID:-}" ]]; then
    return 0
  fi

  return 1
}

resolve_fpga_id() {
  local fpga_id="${1:-${FPGA_ID:-auto}}"
  local smi bdf detected

  if [[ -n "${XRT_DEVICE_INDEX:-}" ]]; then
    echo "$XRT_DEVICE_INDEX"
    return
  fi

  if [[ -n "${XRT_DEVICE_BDF:-}" ]] && detected="$(bdf_to_fpga_id "$XRT_DEVICE_BDF")"; then
    echo "$detected"
    return
  fi

  if should_auto_detect_fpga_id "$fpga_id"; then
    smi="$(resolve_xrt_smi)"
    if detected="$(detect_accessible_xrt_index "$smi")"; then
      echo "$detected"
      return
    fi
    if bdf="$(detect_available_xrt_bdf "$smi")" && detected="$(bdf_to_fpga_id "$bdf")"; then
      echo "$detected"
      return
    fi

    if [[ "$fpga_id" == "auto" || "$fpga_id" == "detect" || "$fpga_id" == "-1" ]]; then
      echo "ERROR: could not auto-detect allocated FPGA index" >&2
      return 1
    fi
  fi

  echo "$fpga_id"
}

resolve_xrt_user_bdf() {
  local fpga_id="${1:-${FPGA_ID:-auto}}"
  local smi index bdf

  if [[ -n "${XRT_DEVICE_BDF:-}" ]]; then
    echo "$XRT_DEVICE_BDF"
    return
  fi

  smi="$(resolve_xrt_smi)"

  if [[ -n "${XRT_DEVICE_INDEX:-}" ]]; then
    if bdf="$(detect_xrt_bdf_for_index "$smi" "$XRT_DEVICE_INDEX")"; then
      echo "$bdf"
      return
    fi
    if bdf="$(fpga_id_to_bdf "$XRT_DEVICE_INDEX")"; then
      echo "$bdf"
      return
    fi
    echo "ERROR: could not resolve BDF for XRT_DEVICE_INDEX=${XRT_DEVICE_INDEX}" >&2
    return 1
  fi

  if index="$(resolve_fpga_id "$fpga_id")"; then
    if bdf="$(detect_xrt_bdf_for_index "$smi" "$index")"; then
      echo "$bdf"
      return
    fi
    if bdf="$(fpga_id_to_bdf "$index")"; then
      echo "$bdf"
      return
    fi
  fi

  if bdf="$(detect_available_xrt_bdf "$smi")"; then
    echo "$bdf"
    return
  fi

  echo "ERROR: could not resolve XRT user BDF" >&2
  return 1
}

_xrt_device_detect_usage() {
  cat >&2 <<'EOF'
Usage:
  ci/xrt_device_detect.sh index [fpga_id|auto]
  ci/xrt_device_detect.sh bdf [fpga_id|auto]
  ci/xrt_device_detect.sh xrt-smi
EOF
}

_xrt_device_detect_main() {
  local cmd="${1:-}"
  local fpga_id="${2:-auto}"

  case "$cmd" in
    index)
      resolve_fpga_id "$fpga_id"
      ;;
    bdf)
      resolve_xrt_user_bdf "$fpga_id"
      ;;
    xrt-smi)
      resolve_xrt_smi
      ;;
    *)
      _xrt_device_detect_usage
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _xrt_device_detect_main "$@"
fi

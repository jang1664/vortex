#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./measure_power.sh [fpga_id|auto] [interval_sec] [out_csv] [max_bytes]
#
# Example:
#   ./measure_power.sh auto 0.05 power.csv 1048576
#
# Output columns:
#   timestamp_s, vccint_mv, vccint_ma, p_vccint_w,
#   vcc0v85_mv, vcc0v85_ma, p_0v85_int_w, p_total_w
# max_bytes defaults to 1 MiB; set to 0 for unlimited logging.

FPGA_ID="${1:-auto}"
INTERVAL="${2:-0.01}"
OUT="${3:-fpga_power.csv}"
MAX_BYTES="${4:-1048576}"
XRT_SMI="${XRT_SMI:-/opt/xilinx/xrt/bin/xrt-smi}"
XRT_DEVICE_PROBE_MAX="${XRT_DEVICE_PROBE_MAX:-8}"
if [[ ! "$XRT_DEVICE_PROBE_MAX" =~ ^[0-9]+$ || "$XRT_DEVICE_PROBE_MAX" == "0" ]]; then
  XRT_DEVICE_PROBE_MAX=8
fi

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
  if [[ "$XRT_SMI" == */* ]]; then
    [[ -x "$XRT_SMI" ]] && echo "$XRT_SMI"
    return
  fi
  command -v "$XRT_SMI" || true
}

detect_accessible_xrt_index() {
  local smi="$1"
  local found=()
  local idx

  [[ -n "$smi" ]] || return 1

  for ((idx = 0; idx < XRT_DEVICE_PROBE_MAX; ++idx)); do
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

detect_available_xrt_bdf() {
  local smi="$1"
  local output line

  [[ -n "$smi" ]] || return 1

  output="$("$smi" examine --report platform 2>&1 || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ \[([0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:00\.1)\] ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$output"
  return 1
}

should_auto_detect_fpga_id() {
  case "$FPGA_ID" in
    auto|detect|-1) return 0 ;;
  esac

  if [[ -n "${XRT_DEVICE_INDEX:-}" || -n "${XRT_DEVICE_BDF:-}" ]]; then
    return 0
  fi

  if [[ "$FPGA_ID" == "0" && -n "${SLURM_JOB_ID:-}${SLURM_STEP_ID:-}" && -z "${VORTEX_POWER_FORCE_FPGA_ID:-}" ]]; then
    return 0
  fi

  return 1
}

resolve_fpga_id() {
  local smi bdf detected

  if [[ -n "${XRT_DEVICE_INDEX:-}" ]]; then
    echo "$XRT_DEVICE_INDEX"
    return
  fi

  if [[ -n "${XRT_DEVICE_BDF:-}" ]] && detected="$(bdf_to_fpga_id "$XRT_DEVICE_BDF")"; then
    echo "$detected"
    return
  fi

  if should_auto_detect_fpga_id; then
    smi="$(resolve_xrt_smi)"
    if detected="$(detect_accessible_xrt_index "$smi")"; then
      echo "$detected"
      return
    fi
    if bdf="$(detect_available_xrt_bdf "$smi")" && detected="$(bdf_to_fpga_id "$bdf")"; then
      echo "$detected"
      return
    fi

    if [[ "$FPGA_ID" == "auto" || "$FPGA_ID" == "detect" || "$FPGA_ID" == "-1" ]]; then
      echo "ERROR: could not auto-detect allocated FPGA index" >&2
      return 1
    fi
  fi

  echo "$FPGA_ID"
}

hwmon_from_bdf() {
  local bdf="$1"
  local path

  [[ -n "$bdf" ]] || return 1
  for path in "/sys/bus/pci/devices/${bdf}"/hwmon/hwmon*; do
    [[ -d "$path" ]] || continue
    echo "$path"
    return 0
  done
  return 1
}

default_hwmon_for_fpga_id() {
  local id="$1"
  local bdf hwmon

  case "$id" in
    0)
      if [[ -n "${FPGA_0_HWMON:-}" ]]; then
        echo "$FPGA_0_HWMON"
        return
      fi
      ;;
    1)
      if [[ -n "${FPGA_1_HWMON:-}" ]]; then
        echo "$FPGA_1_HWMON"
        return
      fi
      ;;
  esac

  if bdf="$(fpga_id_to_bdf "$id")" && hwmon="$(hwmon_from_bdf "$bdf")"; then
    echo "$hwmon"
    return
  fi

  case "$id" in
    0) echo "/sys/class/hwmon/hwmon5" ;;
    1) echo "/sys/class/hwmon/hwmon6" ;;
    *)
      echo "ERROR: unsupported FPGA index '$id'" >&2
      return 1
      ;;
  esac
}

FPGA_ID="$(resolve_fpga_id)"
HWMON_DIR="$(default_hwmon_for_fpga_id "$FPGA_ID")"

find_sensor_by_label() {
  local prefix="$1"       # in, curr, power, temp, ...
  local target="$2"       # exact label string
  local f label base

  for f in "$HWMON_DIR"/${prefix}*_label; do
    [[ -e "$f" ]] || continue
    label="$(cat "$f" | xargs)"
    if [[ "$label" == "$target" ]]; then
      base="${f%_label}"
      echo "$base"
      return 0
    fi
  done

  echo "ERROR: cannot find ${prefix}*_label == '$target' in $HWMON_DIR" >&2
  return 1
}

# Voltage sensors: mV
VCCINT_V="$(find_sensor_by_label in   "VCC INT")"
VCC085_V="$(find_sensor_by_label in   "VCC INT BRAM")"

# Current sensors: mA
VCCINT_I="$(find_sensor_by_label curr "VCC INT Current")"
VCC085_I="$(find_sensor_by_label curr "VCC 0V85 Current")"

echo "Using sensors:" >&2
echo "  FPGA index     : ${FPGA_ID}" >&2
if FPGA_BDF="$(fpga_id_to_bdf "$FPGA_ID")"; then
  echo "  FPGA BDF       : ${FPGA_BDF}" >&2
fi
echo "  HWMON dir      : ${HWMON_DIR}" >&2
echo "  VCCINT voltage : ${VCCINT_V}_input" >&2
echo "  VCCINT current : ${VCCINT_I}_input" >&2
echo "  0V85 voltage   : ${VCC085_V}_input" >&2
echo "  0V85 current   : ${VCC085_I}_input" >&2
echo "Logging to: $OUT" >&2
echo "Interval : $INTERVAL sec" >&2
echo "Max CSV  : $MAX_BYTES bytes" >&2

if [[ ! -f "$OUT" ]]; then
  echo "timestamp_s,vccint_mv,vccint_ma,p_vccint_w,vcc0v85_mv,vcc0v85_ma,p_0v85_int_w,p_total_w" > "$OUT"
fi

csv_size_bytes() {
  wc -c < "$OUT" | xargs
}

append_row_if_room() {
  local row="$1"
  local cur_size row_size next_size

  if [[ "$MAX_BYTES" == "0" ]]; then
    printf "%s\n" "$row" | tee -a "$OUT"
    return
  fi

  cur_size="$(csv_size_bytes)"
  row_size=$((${#row} + 1))
  next_size=$((cur_size + row_size))
  if (( next_size <= MAX_BYTES )); then
    printf "%s\n" "$row" | tee -a "$OUT"
  fi
}

while true; do
  ts="$(date +%s.%N)"

  vccint_mv="$(cat "${VCCINT_V}_input")"
  vccint_ma="$(cat "${VCCINT_I}_input")"

  vcc085_mv="$(cat "${VCC085_V}_input")"
  vcc085_ma="$(cat "${VCC085_I}_input")"

  row="$(awk -v ts="$ts" \
             -v v1="$vccint_mv" -v i1="$vccint_ma" \
             -v v2="$vcc085_mv" -v i2="$vcc085_ma" '
    BEGIN {
      p1 = v1 * i1 / 1000000.0;
      p2 = v2 * i2 / 1000000.0;
      pt = p1 + p2;
      printf "%.9f,%d,%d,%.6f,%d,%d,%.6f,%.6f\n", ts, v1, i1, p1, v2, i2, p2, pt;
    }
  ')"
  append_row_if_room "$row"

  sleep "$INTERVAL"
done

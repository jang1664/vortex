#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM INT

# Usage:
#   ./measure_power.sh [fpga_id|auto] [interval_sec] [out_csv] [max_bytes]
#
# Example:
#   ./measure_power.sh auto 0.05 power.csv 1048576
#
# Output columns:
#   timestamp_s, vccint_mv, vccint_ma, p_vccint_w,
#   vcc0v85_mv, vcc0v85_ma, p_0v85_w, vcc_power_w,
#   pcie12v_mv, pcie12v_ma, p_pcie12v_w,
#   pcie3v3_mv, pcie3v3_ma, p_pcie3v3_w,
#   pcie_power_w, total_power_w
# max_bytes defaults to 1 MiB; set to 0 for unlimited logging.

FPGA_ID="${1:-auto}"
INTERVAL="${2:-0.01}"
OUT="${3:-fpga_power.csv}"
MAX_BYTES="${4:-1048576}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/xrt_device_detect.sh"

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

FPGA_ID="$(resolve_fpga_id "$FPGA_ID")"
FPGA_BDF="${XRT_DEVICE_BDF:-}"
if [[ -z "$FPGA_BDF" ]]; then
  FPGA_BDF="$(resolve_xrt_user_bdf "$FPGA_ID" 2>/dev/null || true)"
fi
if [[ -n "$FPGA_BDF" ]] && HWMON_DIR="$(hwmon_from_bdf "$FPGA_BDF")"; then
  :
else
  HWMON_DIR="$(default_hwmon_for_fpga_id "$FPGA_ID")"
fi

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

# PCIe input rails: mV / mA
PCIE12_V="$(find_sensor_by_label in   "12V PEX")"
PCIE12_I="$(find_sensor_by_label curr "12V PEX Current")"
PCIE3V3_V="$(find_sensor_by_label in   "3V3 PEX")"
PCIE3V3_I="$(find_sensor_by_label curr "3V3 PEX Current")"

echo "Using sensors:" >&2
echo "  FPGA index     : ${FPGA_ID}" >&2
if [[ -z "$FPGA_BDF" ]]; then
  FPGA_BDF="$(fpga_id_to_bdf "$FPGA_ID" 2>/dev/null || true)"
fi
if [[ -n "$FPGA_BDF" ]]; then
  echo "  FPGA BDF       : ${FPGA_BDF}" >&2
fi
echo "  HWMON dir      : ${HWMON_DIR}" >&2
echo "  VCCINT voltage : ${VCCINT_V}_input" >&2
echo "  VCCINT current : ${VCCINT_I}_input" >&2
echo "  0V85 voltage   : ${VCC085_V}_input" >&2
echo "  0V85 current   : ${VCC085_I}_input" >&2
echo "  PCIe 12V volt  : ${PCIE12_V}_input" >&2
echo "  PCIe 12V curr  : ${PCIE12_I}_input" >&2
echo "  PCIe 3V3 volt  : ${PCIE3V3_V}_input" >&2
echo "  PCIe 3V3 curr  : ${PCIE3V3_I}_input" >&2
echo "Logging to: $OUT" >&2
echo "Interval : $INTERVAL sec" >&2
echo "Max CSV  : $MAX_BYTES bytes" >&2

if [[ ! -f "$OUT" ]]; then
  echo "timestamp_s,vccint_mv,vccint_ma,p_vccint_w,vcc0v85_mv,vcc0v85_ma,p_0v85_w,vcc_power_w,pcie12v_mv,pcie12v_ma,p_pcie12v_w,pcie3v3_mv,pcie3v3_ma,p_pcie3v3_w,pcie_power_w,total_power_w" > "$OUT"
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
    return
  fi

  : > "${OUT}.truncated"
  echo "Power CSV reached ${MAX_BYTES} bytes; stopping sampler and marking ${OUT}.truncated" >&2
  exit 0
}

while true; do
  ts="$(date +%s.%N)"

  vccint_mv="$(cat "${VCCINT_V}_input")"
  vccint_ma="$(cat "${VCCINT_I}_input")"

  vcc085_mv="$(cat "${VCC085_V}_input")"
  vcc085_ma="$(cat "${VCC085_I}_input")"

  pcie12_mv="$(cat "${PCIE12_V}_input")"
  pcie12_ma="$(cat "${PCIE12_I}_input")"

  pcie3v3_mv="$(cat "${PCIE3V3_V}_input")"
  pcie3v3_ma="$(cat "${PCIE3V3_I}_input")"

  row="$(awk -v ts="$ts" \
             -v v1="$vccint_mv" -v i1="$vccint_ma" \
             -v v2="$vcc085_mv" -v i2="$vcc085_ma" \
             -v pv1="$pcie12_mv" -v pi1="$pcie12_ma" \
             -v pv2="$pcie3v3_mv" -v pi2="$pcie3v3_ma" '
    BEGIN {
      p1 = v1 * i1 / 1000000.0;
      p2 = v2 * i2 / 1000000.0;
      pvcc = p1 + p2;
      pp1 = pv1 * pi1 / 1000000.0;
      pp2 = pv2 * pi2 / 1000000.0;
      ppcie = pp1 + pp2;
      ptotal = pvcc + ppcie;
      printf "%.9f,%d,%d,%.6f,%d,%d,%.6f,%.6f,%d,%d,%.6f,%d,%d,%.6f,%.6f,%.6f\n", ts, v1, i1, p1, v2, i2, p2, pvcc, pv1, pi1, pp1, pv2, pi2, pp2, ppcie, ptotal;
    }
  ')"
  append_row_if_room "$row"

  sleep "$INTERVAL"
done

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OOC_DIR="${ROOT_DIR}/hw/syn/xilinx/gemm_node_ooc"

CONFIG_FILE="${ROOT_DIR}/configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh"
OUTPUT_DIR=""
IP_DIR=""
VIVADO_BIN=""
JOBS=8
RUN_SYNTHESIS=0
WRITE_CHECKPOINT=0
STREAM_RESPONSE_DATA_RAM=""
WIDE_RESPONSE_DATA_RAM=""
ORIGINAL_ARGS=("$@")

TOP="VX_gemm_node_ooc"
PART="xcu55c-fsvh2892-2L-e"
CLOCK_PERIOD_NS="7.000"
SYNTH_STRATEGY="Vivado Synthesis Defaults"
SYNTH_MORE_OPTIONS="-mode out_of_context"

usage() {
  cat <<'EOF'
Usage: ci/run_gemm_node_ooc.sh --output-dir PATH --ip-dir PATH [options]

Generate a reproducible VX_gemm_node U55C OOC manifest.  The default mode is
a dry run: it creates and validates the complete manifest without launching
Vivado.  Synthesis is launched only when --run is present.

Required:
  --output-dir PATH       New directory for the manifest and reports
  --ip-dir PATH           Generated Xilinx floating-point IP root

Options:
  --config-file PATH      Shell config to source (default: TH16 WLOAD4 config)
  --jobs N                Vivado synthesis jobs (default: 8)
  --vivado-bin PATH       Vivado executable for --run
  --write-checkpoint      Retain post_synth.dcp when running synthesis
  --stream-response-data-ram 0|1
                          Override all Input/Weight/S/Z overlap queue payloads
  --wide-response-data-ram 0|1
                          Override Weight wide-switch assembly payload storage
  --run                   Launch Vivado synthesis after manifest generation
  -h, --help              Show this help

The IP root must contain <ip-name>/<ip-name>.xci for the nine GEMM FP IPs.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --ip-dir)
      IP_DIR="${2:?missing value for --ip-dir}"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="${2:?missing value for --config-file}"
      shift 2
      ;;
    --jobs)
      JOBS="${2:?missing value for --jobs}"
      shift 2
      ;;
    --vivado-bin)
      VIVADO_BIN="${2:?missing value for --vivado-bin}"
      shift 2
      ;;
    --write-checkpoint)
      WRITE_CHECKPOINT=1
      shift
      ;;
    --stream-response-data-ram)
      STREAM_RESPONSE_DATA_RAM="${2:?missing value for --stream-response-data-ram}"
      shift 2
      ;;
    --wide-response-data-ram)
      WIDE_RESPONSE_DATA_RAM="${2:?missing value for --wide-response-data-ram}"
      shift 2
      ;;
    --run)
      RUN_SYNTHESIS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "${OUTPUT_DIR}" ]] || fail "--output-dir is required"
[[ -n "${IP_DIR}" ]] || fail "--ip-dir is required"
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
[[ -z "${STREAM_RESPONSE_DATA_RAM}" || "${STREAM_RESPONSE_DATA_RAM}" =~ ^[01]$ ]] \
  || fail "--stream-response-data-ram must be 0 or 1"
[[ -z "${WIDE_RESPONSE_DATA_RAM}" || "${WIDE_RESPONSE_DATA_RAM}" =~ ^[01]$ ]] \
  || fail "--wide-response-data-ram must be 0 or 1"

resolve_from_root() {
  local path="$1"
  if [[ "${path}" != /* ]]; then
    path="${ROOT_DIR}/${path}"
  fi
  readlink -f "${path}"
}

CONFIG_FILE="$(resolve_from_root "${CONFIG_FILE}")"
IP_DIR="$(resolve_from_root "${IP_DIR}")"
if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"
fi

[[ -f "${CONFIG_FILE}" ]] || fail "config file not found: ${CONFIG_FILE}"
[[ -d "${IP_DIR}" ]] || fail "IP directory not found: ${IP_DIR}"
[[ ! -e "${OUTPUT_DIR}" ]] || fail "output path already exists: ${OUTPUT_DIR}"

TEMPLATE_MANIFEST="${OOC_DIR}/sources.list"
WRAPPER="${OOC_DIR}/VX_gemm_node_ooc.sv"
XDC_FILE="${OOC_DIR}/gemm_node_ooc.xdc"
TCL_FILE="${OOC_DIR}/synth.tcl"
[[ -f "${TEMPLATE_MANIFEST}" ]] || fail "source template not found: ${TEMPLATE_MANIFEST}"
[[ -f "${WRAPPER}" ]] || fail "OOC wrapper not found: ${WRAPPER}"
[[ -f "${XDC_FILE}" ]] || fail "constraint not found: ${XDC_FILE}"
[[ -f "${TCL_FILE}" ]] || fail "synthesis Tcl not found: ${TCL_FILE}"

TCL_PARSE_RESULT="$({ TCL_FILE="${TCL_FILE}" tclsh <<'TCL'
set input_file [open $::env(TCL_FILE) r]
set script_text [read $input_file]
close $input_file
if {![info complete $script_text]} {
  puts stderr "incomplete Tcl command structure"
  exit 1
}
puts "PASS"
TCL
} 2>&1)" || fail "Tcl parse-level validation failed: ${TCL_PARSE_RESULT}"

# Source the selected hardware/software configuration exactly once, then add
# only the U55C/XRT synthesis context normally supplied by the XRT Makefile.
CONFIGS=""
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
read -r -a CONFIG_DEFINES <<< "${CONFIGS}"

DEFINES=()
for config_define in "${CONFIG_DEFINES[@]}"; do
  [[ "${config_define}" == -D* ]] \
    || fail "unsupported config token (expected -D...): ${config_define}"
  DEFINES+=("${config_define#-D}")
done

append_define() {
  local requested="$1"
  local requested_name="${requested%%=*}"
  local existing
  for existing in "${DEFINES[@]}"; do
    if [[ "${existing%%=*}" == "${requested_name}" ]]; then
      [[ "${existing}" == "${requested}" ]] \
        || fail "conflicting define for ${requested_name}: ${existing} vs ${requested}"
      return
    fi
  done
  DEFINES+=("${requested}")
}

override_define() {
  local requested="$1"
  local requested_name="${requested%%=*}"
  local index
  for index in "${!DEFINES[@]}"; do
    if [[ "${DEFINES[index]%%=*}" == "${requested_name}" ]]; then
      DEFINES[index]="${requested}"
      return
    fi
  done
  DEFINES+=("${requested}")
}

if [[ -n "${STREAM_RESPONSE_DATA_RAM}" ]]; then
  override_define "I_LMEM_DMA_RESPONSE_DATA_RAM=${STREAM_RESPONSE_DATA_RAM}"
  override_define "W_LMEM_DMA_RESPONSE_DATA_RAM=${STREAM_RESPONSE_DATA_RAM}"
  override_define "SZ_LMEM_DMA_RESPONSE_DATA_RAM=${STREAM_RESPONSE_DATA_RAM}"
fi
if [[ -n "${WIDE_RESPONSE_DATA_RAM}" ]]; then
  override_define "W_TMEM_WIDE_RESPONSE_DATA_RAM=${WIDE_RESPONSE_DATA_RAM}"
fi

append_define "PLATFORM_MEMORY_DATA_SIZE=64"
append_define "PLATFORM_MEMORY_ID_WIDTH=32"
append_define "XLEN_64"
append_define "NDEBUG"
append_define "VIVADO"
append_define "SYNTHESIS"

IP_NAMES=(
  xil_f16mul
  xil_f16mul_latency1
  xil_f16mul_low_latency
  xil_f32add
  xil_f32add_latency1
  xil_f32add_low_latency
  xil_f32mul
  xil_f32mul_latency1
  xil_f32mul_low_latency
)

IP_FILES=()
for ip_name in "${IP_NAMES[@]}"; do
  ip_file="${IP_DIR}/${ip_name}/${ip_name}.xci"
  [[ -f "${ip_file}" ]] || fail "required GEMM floating-point IP not found: ${ip_file}"
  IP_FILES+=("$(readlink -f "${ip_file}")")
done

if [[ "${RUN_SYNTHESIS}" == 1 ]]; then
  if [[ -z "${VIVADO_BIN}" ]]; then
    VIVADO_BIN="$(command -v vivado || true)"
  elif [[ "${VIVADO_BIN}" != /* ]]; then
    VIVADO_BIN="$(command -v "${VIVADO_BIN}" || true)"
  fi
  [[ -n "${VIVADO_BIN}" && -x "${VIVADO_BIN}" ]] \
    || fail "Vivado executable not found; pass --vivado-bin PATH"
  VIVADO_VERSION="$("${VIVADO_BIN}" -version | sed -n '1p')"
else
  if [[ -n "${VIVADO_BIN}" ]]; then
    VIVADO_BIN="$(resolve_from_root "${VIVADO_BIN}")"
  else
    VIVADO_BIN="not-invoked-dry-run"
  fi
  VIVADO_VERSION="not-invoked-dry-run"
fi

mkdir -p "${OUTPUT_DIR}"

RUN_STAGE="manifest"
record_run_status() {
  local status=$?
  {
    echo "status=$([[ ${status} -eq 0 ]] && echo PASS || echo FAIL)"
    echo "exit_code=${status}"
    echo "stage=${RUN_STAGE}"
    echo "mode=$([[ ${RUN_SYNTHESIS} == 1 ]] && echo synthesis || echo dry-run)"
    echo "timestamp=$(date -Iseconds)"
  } > "${OUTPUT_DIR}/run_status.txt"
}
trap record_run_status EXIT

SOURCE_MANIFEST="${OUTPUT_DIR}/sources.f"
DEFINES_MANIFEST="${OUTPUT_DIR}/defines.txt"
SOURCE_HASH_MANIFEST="${OUTPUT_DIR}/source_sha256.txt"
HEADER_HASH_MANIFEST="${OUTPUT_DIR}/include_header_sha256.txt"
INPUT_HASH_MANIFEST="${OUTPUT_DIR}/input_sha256.txt"

for define in "${DEFINES[@]}"; do
  printf '%s\n' "${define}"
done > "${DEFINES_MANIFEST}"

{
  for define in "${DEFINES[@]}"; do
    printf '+define+%s\n' "${define}"
  done
  while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == \#* ]] && continue
    if [[ "${entry}" == +incdir+* ]]; then
      include_path="${entry#+incdir+}"
      [[ "${include_path}" == /* ]] || include_path="${ROOT_DIR}/${include_path}"
      [[ -d "${include_path}" ]] || fail "include directory not found: ${include_path}"
      printf '+incdir+%s\n' "$(readlink -f "${include_path}")"
    else
      source_path="${entry}"
      [[ "${source_path}" == /* ]] || source_path="${ROOT_DIR}/${source_path}"
      [[ -f "${source_path}" ]] || fail "RTL source not found: ${source_path}"
      printf '%s\n' "$(readlink -f "${source_path}")"
    fi
  done < "${TEMPLATE_MANIFEST}"
  printf '%s\n' "${IP_FILES[@]}"
} > "${SOURCE_MANIFEST}"

while IFS= read -r source_entry; do
  [[ "${source_entry}" == +* ]] && continue
  sha256sum "${source_entry}"
done < "${SOURCE_MANIFEST}" > "${SOURCE_HASH_MANIFEST}"

# Include files are compilation inputs too.  Hash the union of all .vh/.svh
# files reachable through the recorded include directories so header drift is
# visible even though Vivado's file list contains only directories for them.
while IFS= read -r header_file; do
  sha256sum "${header_file}"
done < <(
  while IFS= read -r include_entry; do
    include_dir="${include_entry#+incdir+}"
    find "${include_dir}" -type f \( -name '*.vh' -o -name '*.svh' \) -print
  done < <(rg '^\+incdir\+' "${SOURCE_MANIFEST}") | sort -u
) > "${HEADER_HASH_MANIFEST}"

sha256sum \
  "${CONFIG_FILE}" \
  "${TEMPLATE_MANIFEST}" \
  "${WRAPPER}" \
  "${XDC_FILE}" \
  "${TCL_FILE}" \
  "${ROOT_DIR}/ci/run_gemm_node_ooc.sh" \
  > "${INPUT_HASH_MANIFEST}"

printf 'ci/run_gemm_node_ooc.sh' > "${OUTPUT_DIR}/command.txt"
printf ' %q' "${ORIGINAL_ARGS[@]}" >> "${OUTPUT_DIR}/command.txt"
printf '\n' >> "${OUTPUT_DIR}/command.txt"

git -C "${ROOT_DIR}" status --short > "${OUTPUT_DIR}/git_status.txt"

{
  echo "mode=$([[ ${RUN_SYNTHESIS} == 1 ]] && echo synthesis || echo dry-run)"
  echo "top=${TOP}"
  echo "git_revision=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_branch=$(git -C "${ROOT_DIR}" branch --show-current)"
  echo "config_file=${CONFIG_FILE}"
  echo "config_sha256=$(sha256sum "${CONFIG_FILE}" | cut -d' ' -f1)"
  echo "defines_manifest=${DEFINES_MANIFEST}"
  echo "defines_sha256=$(sha256sum "${DEFINES_MANIFEST}" | cut -d' ' -f1)"
  echo "source_manifest=${SOURCE_MANIFEST}"
  echo "source_manifest_sha256=$(sha256sum "${SOURCE_MANIFEST}" | cut -d' ' -f1)"
  echo "source_hash_manifest=${SOURCE_HASH_MANIFEST}"
  echo "include_header_hash_manifest=${HEADER_HASH_MANIFEST}"
  echo "input_hash_manifest=${INPUT_HASH_MANIFEST}"
  echo "floating_point_ip_dir=${IP_DIR}"
  echo "part=${PART}"
  echo "clock_name=core_clock"
  echo "clock_period_ns=${CLOCK_PERIOD_NS}"
  echo "constraint=${XDC_FILE}"
  echo "vivado_bin=${VIVADO_BIN}"
  echo "vivado_version=${VIVADO_VERSION}"
  echo "jobs=${JOBS}"
  echo "synthesis_strategy=${SYNTH_STRATEGY}"
  echo "synthesis_more_options=${SYNTH_MORE_OPTIONS}"
  echo "source_mgmt_mode=None"
  echo "write_checkpoint=${WRITE_CHECKPOINT}"
  echo "tcl_parse_validation=${TCL_PARSE_RESULT}"
} > "${OUTPUT_DIR}/manifest.txt"

if [[ "${RUN_SYNTHESIS}" == 0 ]]; then
  echo "Dry run complete: ${OUTPUT_DIR}"
  echo "Vivado was not invoked. Add --run to launch OOC synthesis."
  exit 0
fi

RUN_STAGE="vivado-synthesis"
TOOL_DIR="${ROOT_DIR}/hw/scripts" \
  "${VIVADO_BIN}" \
  -mode batch \
  -journal "${OUTPUT_DIR}/vivado.jou" \
  -log "${OUTPUT_DIR}/vivado.log" \
  -source "${TCL_FILE}" \
  -tclargs \
    "${TOP}" \
    "${PART}" \
    "${SOURCE_MANIFEST}" \
    "${XDC_FILE}" \
    "${OUTPUT_DIR}" \
    "${JOBS}" \
    "${WRITE_CHECKPOINT}" \
  2>&1 | tee "${OUTPUT_DIR}/console.log"

RUN_STAGE="complete"
echo "OOC synthesis complete: ${OUTPUT_DIR}"

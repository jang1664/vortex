#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ALIAS="C4"
CONFIG_FILE_OVERRIDE=""
DEVICE="xcu55c-fsvh2892-2L-e"
TOP="VX_dma_engine_ooc"
TARGET="engine"
JOBS="8"
OUTPUT_DIR=""
REFERENCE_REPORT=""
WRITE_CHECKPOINT="0"
ENABLE_MISALIGN="0"
PADDING_ENABLED="1"
MISALIGN_PACK_BYTES_OVERRIDE=""
DCACHE_BYTES_OVERRIDE=""
LMEM_BYTES_OVERRIDE=""
FIXED_DIR="-1"
MAX_DIMS="3"
EXTRA_SOURCES=()
EXTRA_DEFINES=()
PYTHON_BIN="${PYTHON:-python3}"
VIVADO_BIN=""
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage: ci/run_dma_ooc.sh [options]

Run synthesis-only Vivado out-of-context compilation for a DMA target.

Options:
  --alias NAME             FPGA config alias (default: C4)
  --config-file PATH       Source this config directly instead of resolving an alias
  --output-dir PATH        New result directory (required)
  --device PART            Vivado device part
  --target NAME            OOC target: engine or node-backend (default: engine)
  --top MODULE             OOC top module (default: VX_dma_engine_ooc)
  --jobs N                 Vivado parallel jobs (default: 8)
  --vivado-bin PATH        Vivado executable (default: PATH or Vivado 2025.1)
  --reference-report PATH  Historical report to record beside the OOC result
  --write-checkpoint       Also retain the large post-synthesis DCP
  --enable-misalign        Elaborate VX_dma_unit_misal instead of aligned DMA
  --padding-enabled 0|1    Enable descriptor padding logic (default: 1)
  --misalign-pack-bytes N  Override MISALIGN_PACK_BYTES for this run
  --dcache-bytes N         Aggregate node-backend Dcache width in bytes (64..512)
  --lmem-bytes N           Aggregate node-backend LMEM width in bytes (64..512)
  --fixed-dir N            Direction mode: -1 (runtime), 0, or 1 (default: -1)
  --max-dims N             Maximum DMA dimensions: 1, 2, or 3 (default: 3)
  --extra-source PATH      Append one explicit SystemVerilog source (repeatable)
  --extra-define NAME      Append one explicit synthesis define (repeatable)
  -h, --help               Show this help

Example:
  ci/run_dma_ooc.sh \
    --alias C4 \
    --enable-misalign \
    --output-dir docs/future_optim/dma_experiments/20260717-010-c4-misaligned-baseline

  ci/run_dma_ooc.sh \
    --target node-backend \
    --config-file configs/improve_th32_tcol32_hwexp_dcache.sh \
    --dcache-bytes 64 \
    --lmem-bytes 256 \
    --fixed-dir -1 \
    --misalign-pack-bytes 16 \
    --output-dir docs/future_optim/dma_experiments/pack16
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)
      ALIAS="${2:?missing value for --alias}"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE_OVERRIDE="${2:?missing value for --config-file}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --device)
      DEVICE="${2:?missing value for --device}"
      shift 2
      ;;
    --target)
      TARGET="${2:?missing value for --target}"
      shift 2
      ;;
    --top)
      TOP="${2:?missing value for --top}"
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
    --reference-report)
      REFERENCE_REPORT="${2:?missing value for --reference-report}"
      shift 2
      ;;
    --write-checkpoint)
      WRITE_CHECKPOINT="1"
      shift
      ;;
    --enable-misalign)
      ENABLE_MISALIGN="1"
      shift
      ;;
    --padding-enabled)
      PADDING_ENABLED="${2:?missing value for --padding-enabled}"
      shift 2
      ;;
    --misalign-pack-bytes)
      MISALIGN_PACK_BYTES_OVERRIDE="${2:?missing value for --misalign-pack-bytes}"
      shift 2
      ;;
    --dcache-bytes)
      DCACHE_BYTES_OVERRIDE="${2:?missing value for --dcache-bytes}"
      shift 2
      ;;
    --lmem-bytes)
      LMEM_BYTES_OVERRIDE="${2:?missing value for --lmem-bytes}"
      shift 2
      ;;
    --fixed-dir)
      FIXED_DIR="${2:?missing value for --fixed-dir}"
      shift 2
      ;;
    --max-dims)
      MAX_DIMS="${2:?missing value for --max-dims}"
      shift 2
      ;;
    --extra-source)
      EXTRA_SOURCES+=("${2:?missing value for --extra-source}")
      shift 2
      ;;
    --extra-define)
      EXTRA_DEFINES+=("${2:?missing value for --extra-define}")
      shift 2
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
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
[[ "${TARGET}" == "engine" || "${TARGET}" == "node-backend" ]] \
  || fail "--target must be engine or node-backend"
[[ "${FIXED_DIR}" == "-1" || "${FIXED_DIR}" == "0" || "${FIXED_DIR}" == "1" ]] \
  || fail "--fixed-dir must be -1, 0, or 1"
[[ "${PADDING_ENABLED}" == "0" || "${PADDING_ENABLED}" == "1" ]] \
  || fail "--padding-enabled must be 0 or 1"
[[ "${MAX_DIMS}" == "1" || "${MAX_DIMS}" == "2" || "${MAX_DIMS}" == "3" ]] \
  || fail "--max-dims must be 1, 2, or 3"
if [[ -n "${MISALIGN_PACK_BYTES_OVERRIDE}" ]]; then
  [[ "${MISALIGN_PACK_BYTES_OVERRIDE}" =~ ^[1-9][0-9]*$ ]] \
    || fail "--misalign-pack-bytes must be a positive integer"
  (( (MISALIGN_PACK_BYTES_OVERRIDE & (MISALIGN_PACK_BYTES_OVERRIDE - 1)) == 0 )) \
    || fail "--misalign-pack-bytes must be a power of two"
fi

validate_node_width() {
  local option="$1"
  local value="$2"
  [[ "${value}" =~ ^[1-9][0-9]*$ ]] \
    || fail "${option} must be an integer from 64 through 512"
  (( value >= 64 && value <= 512 )) \
    || fail "${option} must be from 64 through 512 bytes"
  (( (value & (value - 1)) == 0 )) \
    || fail "${option} must be a power of two"
}

if [[ -n "${DCACHE_BYTES_OVERRIDE}" || -n "${LMEM_BYTES_OVERRIDE}" ]]; then
  [[ "${TARGET}" == "node-backend" ]] \
    || fail "--dcache-bytes and --lmem-bytes require --target node-backend"
  [[ -n "${DCACHE_BYTES_OVERRIDE}" && -n "${LMEM_BYTES_OVERRIDE}" ]] \
    || fail "--dcache-bytes and --lmem-bytes must be specified together"
  validate_node_width "--dcache-bytes" "${DCACHE_BYTES_OVERRIDE}"
  validate_node_width "--lmem-bytes" "${LMEM_BYTES_OVERRIDE}"
  if (( DCACHE_BYTES_OVERRIDE > LMEM_BYTES_OVERRIDE )); then
    WIDTH_RATIO=$(( DCACHE_BYTES_OVERRIDE / LMEM_BYTES_OVERRIDE ))
  else
    WIDTH_RATIO=$(( LMEM_BYTES_OVERRIDE / DCACHE_BYTES_OVERRIDE ))
  fi
  (( WIDTH_RATIO <= 8 )) || fail "aggregate width ratio must not exceed 8:1"
elif [[ "${TARGET}" == "node-backend" ]]; then
  fail "--target node-backend requires explicit --dcache-bytes and --lmem-bytes"
fi

if [[ "${TARGET}" != "node-backend" && "${FIXED_DIR}" != "-1" ]]; then
  fail "--fixed-dir is only valid with --target node-backend"
fi
if [[ "${TARGET}" == "node-backend" && "${PADDING_ENABLED}" != "1" ]]; then
  fail "--padding-enabled 0 is only valid with --target engine"
fi

if [[ "${TARGET}" == "node-backend" ]]; then
  TOP="VX_dma_unit_ooc"
  ENABLE_MISALIGN="1"
  TARGET_HIER_FILTER='u_dma_unit$'
  TARGET_LABEL="DMA node backend"
else
  TARGET_HIER_FILTER='u_dma_engine$'
  TARGET_LABEL="DMA engine"
fi

NORMALIZED_EXTRA_SOURCES=()
for extra_source in "${EXTRA_SOURCES[@]}"; do
  if [[ "${extra_source}" != /* ]]; then
    extra_source="${ROOT_DIR}/${extra_source}"
  fi
  [[ -f "${extra_source}" ]] || fail "extra source not found: ${extra_source}"
  extra_source="$(readlink -f "${extra_source}")"
  for existing_source in "${NORMALIZED_EXTRA_SOURCES[@]}"; do
    [[ "${extra_source}" != "${existing_source}" ]] \
      || fail "duplicate --extra-source: ${extra_source}"
  done
  NORMALIZED_EXTRA_SOURCES+=("${extra_source}")
done

NORMALIZED_EXTRA_DEFINES=()
for extra_define in "${EXTRA_DEFINES[@]}"; do
  [[ "${extra_define}" =~ ^[A-Za-z_][A-Za-z0-9_]*(=[^[:space:]]+)?$ ]] \
    || fail "invalid --extra-define: ${extra_define}"
  for existing_define in "${NORMALIZED_EXTRA_DEFINES[@]}"; do
    [[ "${extra_define}" != "${existing_define}" ]] \
      || fail "duplicate --extra-define: ${extra_define}"
  done
  NORMALIZED_EXTRA_DEFINES+=("${extra_define}")
done

if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"
fi
if [[ -e "${OUTPUT_DIR}" ]]; then
  fail "output path already exists: ${OUTPUT_DIR}"
fi

RESOLVER="${SCRIPT_DIR}/resolve_fpga_bin_alias.py"
ALIAS_MAP="${VORTEX_FPGA_BIN_ALIAS_MAP:-${SCRIPT_DIR}/fpga_bin_alias_map.yaml}"
if [[ -n "${CONFIG_FILE_OVERRIDE}" ]]; then
  if [[ "${CONFIG_FILE_OVERRIDE}" != /* ]]; then
    CONFIG_FILE_OVERRIDE="${ROOT_DIR}/${CONFIG_FILE_OVERRIDE}"
  fi
  [[ -f "${CONFIG_FILE_OVERRIDE}" ]] \
    || fail "config file not found: ${CONFIG_FILE_OVERRIDE}"
  CONFIG_FILE="$(readlink -f "${CONFIG_FILE_OVERRIDE}")"
  CONFIG_SOURCE="direct"
  FPGA_BIN_DIR=""
else
  [[ -f "${RESOLVER}" ]] || fail "alias resolver not found: ${RESOLVER}"
  [[ -f "${ALIAS_MAP}" ]] || fail "alias map not found: ${ALIAS_MAP}"
  mapfile -t ALIAS_VALUES < <(
    "${PYTHON_BIN}" "${RESOLVER}" --alias-map "${ALIAS_MAP}" "${ALIAS}"
  )
  [[ ${#ALIAS_VALUES[@]} -ge 2 ]] || fail "could not resolve alias: ${ALIAS}"
  FPGA_BIN_DIR="${ALIAS_VALUES[0]}"
  CONFIG_FILE="${ALIAS_VALUES[1]}"
  [[ -f "${CONFIG_FILE}" ]] || fail "alias config not found: ${CONFIG_FILE}"
  CONFIG_FILE="$(readlink -f "${CONFIG_FILE}")"
  CONFIG_SOURCE="alias"
fi

if [[ -z "${REFERENCE_REPORT}" && "${TARGET}" == "engine" && -n "${FPGA_BIN_DIR}" ]]; then
  REFERENCE_REPORT="${FPGA_BIN_DIR}/hier_utilization.rpt"
elif [[ -n "${REFERENCE_REPORT}" && "${REFERENCE_REPORT}" != /* ]]; then
  REFERENCE_REPORT="${ROOT_DIR}/${REFERENCE_REPORT}"
fi

if [[ -z "${VIVADO_BIN}" ]]; then
  VIVADO_BIN="$(command -v vivado || true)"
fi
if [[ -z "${VIVADO_BIN}" && -x /tool/Program/Xilinx/2025.1/Vivado/bin/vivado ]]; then
  VIVADO_BIN="/tool/Program/Xilinx/2025.1/Vivado/bin/vivado"
fi
[[ -x "${VIVADO_BIN}" ]] || fail "vivado executable not found: ${VIVADO_BIN:-<unset>}"

# The alias config owns functional RTL defines. These four defines reproduce
# the 64-bit Vivado synthesis context used by the configured Vortex build.
CONFIGS=""
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
if [[ -n "${MISALIGN_PACK_BYTES_OVERRIDE}" ]]; then
  read -r -a CONFIG_ARGS_ORIGINAL <<< "${CONFIGS}"
  CONFIGS=""
  for config_arg in "${CONFIG_ARGS_ORIGINAL[@]}"; do
    if [[ "${config_arg}" != -DMISALIGN_PACK_BYTES=* ]]; then
      CONFIGS+=" ${config_arg}"
    fi
  done
  CONFIGS+=" -DMISALIGN_PACK_BYTES=${MISALIGN_PACK_BYTES_OVERRIDE}"
fi
CONFIGS+=" -DPLATFORM_MEMORY_DATA_SIZE=64 -DPLATFORM_MEMORY_ID_WIDTH=32"
CONFIGS+=" -DXLEN_64 -DNDEBUG -DVIVADO -DSYNTHESIS"
if [[ "${ENABLE_MISALIGN}" == "1" ]]; then
  CONFIGS+=" -DDMA_OOC_ENABLE_MISALIGN"
fi
for extra_define in "${NORMALIZED_EXTRA_DEFINES[@]}"; do
  CONFIGS+=" -D${extra_define}"
done

TOP_GENERICS=""
if [[ "${TARGET}" == "node-backend" ]]; then
  TOP_GENERICS="DCACHE_DATA_SIZE=${DCACHE_BYTES_OVERRIDE}"
  TOP_GENERICS+=" LMEM_DATA_SIZE=${LMEM_BYTES_OVERRIDE}"
  TOP_GENERICS+=" FIXED_DIR=${FIXED_DIR}"
  TOP_GENERICS+=" MAX_DIMS=${MAX_DIMS}"
else
  TOP_GENERICS="ENABLE_PADDING=${PADDING_ENABLED}"
  TOP_GENERICS+=" MAX_DIMS=${MAX_DIMS}"
fi

mkdir -p "${OUTPUT_DIR}"

RUN_STAGE="manifest"
record_run_status() {
  local status=$?
  {
    echo "status=$([[ ${status} -eq 0 ]] && echo PASS || echo FAIL)"
    echo "exit_code=${status}"
    echo "stage=${RUN_STAGE}"
    echo "timestamp=$(date -Iseconds)"
  } > "${OUTPUT_DIR}/run_status.txt"
}
trap record_run_status EXIT

SOURCE_LIST="${OUTPUT_DIR}/sources.txt"
read -r -a CONFIG_ARGS <<< "${CONFIGS}"

# Keep this manifest intentionally explicit. Directory-wide source collection
# parses unrelated core/FPU/AXI modules and makes this focused OOC result depend
# on files that VX_dma_engine never elaborates. Production DMA dependencies
# are listed here; experiment-only modules can be appended through explicit,
# validated --extra-source arguments.
{
  for config_arg in "${CONFIG_ARGS[@]}"; do
    echo "+define+${config_arg#-D}"
  done
  echo "+incdir+${ROOT_DIR}/hw/rtl"
  echo "+incdir+${ROOT_DIR}/hw/rtl/libs"
  echo "+incdir+${ROOT_DIR}/hw/rtl/interfaces"
  echo "+incdir+${ROOT_DIR}/hw/rtl/core"
  echo "+incdir+${ROOT_DIR}/hw/rtl/mem"
  echo "+incdir+${ROOT_DIR}/third_party/axi/include"
  echo "+incdir+${ROOT_DIR}/third_party/axi/.bender/git/checkouts/common_cells-3e2fcccecd7aee7b/include"
  echo "${ROOT_DIR}/third_party/axi/src/axi_pkg.sv"
  echo "${ROOT_DIR}/hw/rtl/VX_gpu_pkg.sv"
  echo "${ROOT_DIR}/third_party/axi/src/axi_intf.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_config_reg_if.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_lookahead_if.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_node_done_if.sv"
  echo "${ROOT_DIR}/hw/rtl/mem/VX_mem_bus_if.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_shift_register.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_pipe_register.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_pipe_buffer.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_stream_buffer.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_pending_size.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_placeholder.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_async_ram_patch.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_dp_ram.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_fifo_queue.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_elastic_buffer.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_mul_u32_pipe.sv"
  echo "${ROOT_DIR}/hw/rtl/libs/VX_reduce_tree.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_mem_remap.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_unit_align.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_gearbox.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_lane_aligner.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_lane_assembler.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_equal_realigner.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_misal_gen_path.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_unit_misal.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_unit.sv"
  echo "${ROOT_DIR}/hw/rtl/mem/VX_dma_engine.sv"
  echo "${ROOT_DIR}/hw/syn/xilinx/dut/VX_dma_unit_ooc.sv"
  echo "${ROOT_DIR}/hw/syn/xilinx/dut/VX_dma_engine_ooc.sv"
  for extra_source in "${NORMALIZED_EXTRA_SOURCES[@]}"; do
    echo "${extra_source}"
  done
} > "${SOURCE_LIST}"

SOURCE_SHA256="${OUTPUT_DIR}/source_sha256.txt"
while IFS= read -r source_entry; do
  [[ "${source_entry}" == +* ]] && continue
  [[ -f "${source_entry}" ]] || fail "source manifest entry not found: ${source_entry}"
  sha256sum "${source_entry}"
done < "${SOURCE_LIST}" > "${SOURCE_SHA256}"

INPUT_SHA256="${OUTPUT_DIR}/input_sha256.txt"
sha256sum \
  "${CONFIG_FILE}" \
  "${ROOT_DIR}/hw/syn/xilinx/dut/project.xdc" \
  "${ROOT_DIR}/hw/syn/xilinx/dut/ooc_synth.tcl" \
  "${ROOT_DIR}/ci/run_dma_ooc.sh" \
  "${ROOT_DIR}/tools/vivado_util.py" \
  > "${INPUT_SHA256}"

printf 'ci/run_dma_ooc.sh' > "${OUTPUT_DIR}/command.txt"
printf ' %q' "${ORIGINAL_ARGS[@]}" >> "${OUTPUT_DIR}/command.txt"
printf '\n' >> "${OUTPUT_DIR}/command.txt"

{
  echo "alias=${ALIAS}"
  echo "alias_map=${ALIAS_MAP}"
  echo "fpga_bin_dir=${FPGA_BIN_DIR}"
  echo "config_source=${CONFIG_SOURCE}"
  echo "config_file=${CONFIG_FILE}"
  echo "top=${TOP}"
  echo "target=${TARGET}"
  echo "device=${DEVICE}"
  echo "jobs=${JOBS}"
  echo "enable_misalign=${ENABLE_MISALIGN}"
  echo "padding_enabled=${PADDING_ENABLED}"
  echo "misalign_pack_bytes_override=${MISALIGN_PACK_BYTES_OVERRIDE:-config-default}"
  echo "dcache_bytes=${DCACHE_BYTES_OVERRIDE:-wrapper-default}"
  echo "lmem_bytes=${LMEM_BYTES_OVERRIDE:-wrapper-default}"
  echo "fixed_dir=${FIXED_DIR}"
  echo "max_dims=${MAX_DIMS}"
  echo "top_generics=${TOP_GENERICS:-none}"
  echo "extra_source_count=${#NORMALIZED_EXTRA_SOURCES[@]}"
  echo "extra_defines=${NORMALIZED_EXTRA_DEFINES[*]:-none}"
  echo "source_list_sha256=$(sha256sum "${SOURCE_LIST}" | cut -d' ' -f1)"
  echo "source_hash_manifest=${SOURCE_SHA256}"
  echo "input_hash_manifest=${INPUT_SHA256}"
  echo "constraint=${ROOT_DIR}/hw/syn/xilinx/dut/project.xdc"
  echo "synthesis_mode=out_of_context"
  echo "source_mgmt_mode=None"
  echo "synth_more_options=-mode out_of_context"
  echo "write_checkpoint=${WRITE_CHECKPOINT}"
  echo "reference_report=${REFERENCE_REPORT}"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_branch=$(git -C "${ROOT_DIR}" branch --show-current)"
  echo "vivado_bin=${VIVADO_BIN}"
  "${VIVADO_BIN}" -version | sed -n '1,5p'
} > "${OUTPUT_DIR}/manifest.txt"

printf '%s\n' "${CONFIGS}" > "${OUTPUT_DIR}/configs.txt"
git -C "${ROOT_DIR}" status --short > "${OUTPUT_DIR}/git_status.txt"

if [[ -f "${REFERENCE_REPORT}" ]]; then
  rg -n "${TARGET_HIER_FILTER}" "${REFERENCE_REPORT}" \
    > "${OUTPUT_DIR}/reference_dma_rows.txt" || true
else
  printf 'Reference report not found: %s\n' "${REFERENCE_REPORT}" \
    > "${OUTPUT_DIR}/reference_dma_rows.txt"
fi

RUN_STAGE="vivado-synthesis"
TOOL_DIR="${ROOT_DIR}/hw/scripts" \
  "${VIVADO_BIN}" \
  -mode batch \
  -journal "${OUTPUT_DIR}/vivado.jou" \
  -log "${OUTPUT_DIR}/vivado_batch.log" \
  -source "${ROOT_DIR}/hw/syn/xilinx/dut/ooc_synth.tcl" \
  -tclargs \
    "${TOP}" \
    "${DEVICE}" \
    "${SOURCE_LIST}" \
    "${ROOT_DIR}/hw/syn/xilinx/dut/project.xdc" \
    "${OUTPUT_DIR}" \
    "${JOBS}" \
    "${WRITE_CHECKPOINT}" \
    "${TOP_GENERICS}" \
  2>&1 | tee "${OUTPUT_DIR}/console.log"

RUN_STAGE="report-parsing"
if [[ "${TARGET}" == "engine" ]]; then
  OOC_TARGET_CSV="${OUTPUT_DIR}/ooc_dma_engine.csv"
else
  OOC_TARGET_CSV="${OUTPUT_DIR}/ooc_dma_unit.csv"
fi
OOC_BUFFERS_CSV="${OUTPUT_DIR}/ooc_dma_buffers.csv"
REFERENCE_TARGET_CSV="${OUTPUT_DIR}/reference_dma_target.csv"

"${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
  "${OUTPUT_DIR}/post_synth_util.rpt" show utilization_by_hierarchy \
  --filter "${TARGET_HIER_FILTER}" --format csv -o "${OOC_TARGET_CSV}"

"${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
  "${OUTPUT_DIR}/post_synth_util.rpt" show utilization_by_hierarchy \
  --filter '[/.](dcache_req_buf|lmem_req_buf|dcache_wr_buf|lmem_wr_buf|wr_slot_buf|response_payload_ram)$' \
  --format csv \
  -o "${OOC_BUFFERS_CSV}"

REFERENCE_AVAILABLE=0
if [[ -f "${REFERENCE_REPORT}" ]]; then
  "${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
    "${REFERENCE_REPORT}" show utilization_by_hierarchy \
    --filter "${TARGET_HIER_FILTER}" --format csv -o "${REFERENCE_TARGET_CSV}"
  if [[ $(wc -l < "${REFERENCE_TARGET_CSV}") -eq 2 ]]; then
    REFERENCE_AVAILABLE=1
  fi
fi

COMPARISON_ROWS="$(
  "${PYTHON_BIN}" - \
    "${OOC_TARGET_CSV}" "${REFERENCE_TARGET_CSV}" "${REFERENCE_AVAILABLE}" <<'PY'
import csv
import pathlib
import sys


def read_one(path):
    with pathlib.Path(path).open(newline="") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if len(rows) != 1:
        raise SystemExit(f"expected one DMA target row in {path}, found {len(rows)}")
    return rows[0]


ooc = read_one(sys.argv[1])
if sys.argv[3] != "1":
    print("Reference report or target hierarchy row was not available.")
    raise SystemExit(0)

reference = read_one(sys.argv[2])
metrics = (
    ("LUT", "total_luts"),
    ("FF", "ffs"),
    ("RAMB36", "ramb36"),
    ("RAMB18", "ramb18"),
    ("URAM", "uram"),
    ("DSP", "dsp_blocks"),
)
for name, field in metrics:
    ooc_value = int(ooc[field])
    reference_value = int(reference[field])
    delta = ooc_value - reference_value
    percent = "n/a" if reference_value == 0 else f"{delta / reference_value:+.2%}"
    print(f"| {name} | {ooc_value} | {reference_value} | {delta} | {percent} |")
PY
)"

cat > "${OUTPUT_DIR}/comparison.md" <<EOF
# ${TARGET_LABEL} OOC Result

- Alias: \`${ALIAS}\`
- Config source: \`${CONFIG_SOURCE}\`
- OOC top: \`${TOP}\`
- OOC target: \`${TARGET}\`
- Aggregate Dcache width: \`${DCACHE_BYTES_OVERRIDE:-wrapper-default}\` bytes
- Aggregate LMEM width: \`${LMEM_BYTES_OVERRIDE:-wrapper-default}\` bytes
- Direction mode: \`${FIXED_DIR}\`
- Maximum dimensions: \`${MAX_DIMS}\`
- Padding enabled: \`${PADDING_ENABLED}\`
- Top generics: \`${TOP_GENERICS:-none}\`
- MISALIGN_PACK_BYTES: \`${MISALIGN_PACK_BYTES_OVERRIDE:-config-default}\`
- Extra defines: \`${NORMALIZED_EXTRA_DEFINES[*]:-none}\`
- Device: \`${DEVICE}\`
- Config: \`${CONFIG_FILE}\`
- Git commit: \`$(git -C "${ROOT_DIR}" rev-parse HEAD)\`
- OOC report: \`post_synth_util.rpt\`
- OOC target row: \`$(basename "${OOC_TARGET_CSV}")\`
- OOC drain buffer rows: \`ooc_dma_buffers.csv\`
- Reference report: \`${REFERENCE_REPORT}\`

| Metric | OOC post-synthesis | Reference report | Delta | Delta (%) |
| --- | ---: | ---: | ---: | ---: |
${COMPARISON_ROWS}

The current report is a post-synthesis result for \`${TOP}\`. Deltas are valid
only when the reference was produced with the same top, config, part,
constraints, Vivado version, and synthesis options. A full-design post-route
reference is recorded only for context and is not directly comparable.
EOF

cat > "${OUTPUT_DIR}/manifest.md" <<EOF
# DMA OOC Experiment Manifest

| Field | Value |
| --- | --- |
| Experiment ID | \`$(basename "${OUTPUT_DIR}")\` |
| Purpose | Produce a reproducible ${TARGET_LABEL} OOC synthesis result |
| Comparison rule | Compare only with an OOC run using identical synthesis inputs |
| Changed production RTL | See \`git_status.txt\` and the parent experiment manifest |
| Config | \`${CONFIG_FILE}\` |
| Config selection | \`${CONFIG_SOURCE}\` |
| Git commit | \`$(git -C "${ROOT_DIR}" rev-parse HEAD)\` |
| Git state | \`git_status.txt\` |
| Vivado | \`$("${VIVADO_BIN}" -version | sed -n '1s/^vivado //p')\` |
| Device | \`${DEVICE}\` |
| OOC top | \`${TOP}\` |
| OOC target | \`${TARGET}\` |
| Aggregate Dcache width | \`${DCACHE_BYTES_OVERRIDE:-wrapper-default}\` bytes |
| Aggregate LMEM width | \`${LMEM_BYTES_OVERRIDE:-wrapper-default}\` bytes |
| Direction mode | \`${FIXED_DIR}\` |
| Maximum dimensions | \`${MAX_DIMS}\` |
| Padding enabled | \`${PADDING_ENABLED}\` |
| Top generics | \`${TOP_GENERICS:-none}\` |
| MISALIGN_PACK_BYTES | \`${MISALIGN_PACK_BYTES_OVERRIDE:-config-default}\` |
| Extra defines | \`${NORMALIZED_EXTRA_DEFINES[*]:-none}\` |
| Constraint | \`hw/syn/xilinx/dut/project.xdc\` |
| Source closure | \`sources.txt\` with hashes in \`source_sha256.txt\` |
| Input hashes | \`input_sha256.txt\` |
| Invocation | \`command.txt\` |
| Unittest | Not run by this synthesis-only script |
| xrt-vcs-sim | Not run by this synthesis-only script |
| OOC synthesis | PASS; see \`post_synth_util.rpt\` and \`post_synth_timing_summary.rpt\` |
| Checkpoint | \`$([[ ${WRITE_CHECKPOINT} -eq 1 ]] && echo retained || echo not-retained)\` |
| Conclusion | Measurement only; record the decision in the parent experiment manifest |

This script performs only the OOC stage. Structural DMA variants must pass the
unittest and xrt-vcs-sim gates required by
\`docs/future_optim/dma_optimization_experiment_rules.md\` before invoking it.
EOF

RUN_STAGE="complete"
echo "DMA OOC synthesis complete: ${OUTPUT_DIR}"

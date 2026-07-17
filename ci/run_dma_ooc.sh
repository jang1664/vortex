#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ALIAS="C4"
DEVICE="xcu55c-fsvh2892-2L-e"
TOP="VX_dma_engine_ooc"
JOBS="8"
OUTPUT_DIR=""
REFERENCE_REPORT=""
WRITE_CHECKPOINT="0"
ENABLE_MISALIGN="0"
PYTHON_BIN="${PYTHON:-python3}"
VIVADO_BIN=""

usage() {
  cat <<'EOF'
Usage: ci/run_dma_ooc.sh [options]

Run synthesis-only Vivado out-of-context compilation for the DMA engine.

Options:
  --alias NAME             FPGA config alias (default: C4)
  --output-dir PATH        New result directory (required)
  --device PART            Vivado device part
  --top MODULE             OOC top module (default: VX_dma_engine_ooc)
  --jobs N                 Vivado parallel jobs (default: 8)
  --vivado-bin PATH        Vivado executable (default: PATH or Vivado 2025.1)
  --reference-report PATH  Historical report to record beside the OOC result
  --write-checkpoint       Also retain the large post-synthesis DCP
  --enable-misalign        Elaborate VX_dma_unit_misal instead of aligned DMA
  -h, --help               Show this help

Example:
  ci/run_dma_ooc.sh \
    --alias C4 \
    --enable-misalign \
    --output-dir docs/future_optim/dma_experiments/20260717-010-c4-misaligned-baseline
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
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --device)
      DEVICE="${2:?missing value for --device}"
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

if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${ROOT_DIR}/${OUTPUT_DIR}"
fi
if [[ -e "${OUTPUT_DIR}" ]]; then
  fail "output path already exists: ${OUTPUT_DIR}"
fi

RESOLVER="${SCRIPT_DIR}/resolve_fpga_bin_alias.py"
ALIAS_MAP="${VORTEX_FPGA_BIN_ALIAS_MAP:-${SCRIPT_DIR}/fpga_bin_alias_map.yaml}"
[[ -f "${RESOLVER}" ]] || fail "alias resolver not found: ${RESOLVER}"
[[ -f "${ALIAS_MAP}" ]] || fail "alias map not found: ${ALIAS_MAP}"

mapfile -t ALIAS_VALUES < <(
  "${PYTHON_BIN}" "${RESOLVER}" --alias-map "${ALIAS_MAP}" "${ALIAS}"
)
[[ ${#ALIAS_VALUES[@]} -ge 2 ]] || fail "could not resolve alias: ${ALIAS}"
FPGA_BIN_DIR="${ALIAS_VALUES[0]}"
CONFIG_FILE="${ALIAS_VALUES[1]}"
[[ -f "${CONFIG_FILE}" ]] || fail "alias config not found: ${CONFIG_FILE}"

if [[ -z "${REFERENCE_REPORT}" ]]; then
  REFERENCE_REPORT="${FPGA_BIN_DIR}/hier_utilization.rpt"
elif [[ "${REFERENCE_REPORT}" != /* ]]; then
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
CONFIGS+=" -DPLATFORM_MEMORY_DATA_SIZE=64 -DPLATFORM_MEMORY_ID_WIDTH=32"
CONFIGS+=" -DXLEN_64 -DNDEBUG -DVIVADO -DSYNTHESIS"
if [[ "${ENABLE_MISALIGN}" == "1" ]]; then
  CONFIGS+=" -DDMA_OOC_ENABLE_MISALIGN"
fi

mkdir -p "${OUTPUT_DIR}"

SOURCE_LIST="${OUTPUT_DIR}/sources.txt"
read -r -a CONFIG_ARGS <<< "${CONFIGS}"

# Keep this manifest intentionally explicit. Directory-wide source collection
# parses unrelated core/FPU/AXI modules and makes this focused OOC result depend
# on files that VX_dma_engine never elaborates.
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
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_unit_misal.sv"
  echo "${ROOT_DIR}/hw/rtl/core/VX_dma_unit.sv"
  echo "${ROOT_DIR}/hw/rtl/mem/VX_dma_engine.sv"
  echo "${ROOT_DIR}/hw/syn/xilinx/dut/VX_dma_engine_ooc.sv"
} > "${SOURCE_LIST}"

{
  echo "alias=${ALIAS}"
  echo "alias_map=${ALIAS_MAP}"
  echo "fpga_bin_dir=${FPGA_BIN_DIR}"
  echo "config_file=${CONFIG_FILE}"
  echo "top=${TOP}"
  echo "device=${DEVICE}"
  echo "jobs=${JOBS}"
  echo "enable_misalign=${ENABLE_MISALIGN}"
  echo "reference_report=${REFERENCE_REPORT}"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_branch=$(git -C "${ROOT_DIR}" branch --show-current)"
  echo "vivado_bin=${VIVADO_BIN}"
  "${VIVADO_BIN}" -version | sed -n '1,5p'
} > "${OUTPUT_DIR}/manifest.txt"

printf '%s\n' "${CONFIGS}" > "${OUTPUT_DIR}/configs.txt"
git -C "${ROOT_DIR}" status --short > "${OUTPUT_DIR}/git_status.txt"

if [[ -f "${REFERENCE_REPORT}" ]]; then
  rg -n -F 'u_dma_engine' "${REFERENCE_REPORT}" \
    > "${OUTPUT_DIR}/reference_dma_rows.txt" || true
else
  printf 'Reference report not found: %s\n' "${REFERENCE_REPORT}" \
    > "${OUTPUT_DIR}/reference_dma_rows.txt"
fi

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
  2>&1 | tee "${OUTPUT_DIR}/console.log"

OOC_ENGINE_CSV="${OUTPUT_DIR}/ooc_dma_engine.csv"
OOC_BUFFERS_CSV="${OUTPUT_DIR}/ooc_dma_buffers.csv"
REFERENCE_ENGINE_CSV="${OUTPUT_DIR}/reference_dma_engine.csv"

"${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
  "${OUTPUT_DIR}/post_synth_util.rpt" show utilization_by_hierarchy \
  --filter 'u_dma_engine$' --format csv -o "${OOC_ENGINE_CSV}"

"${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
  "${OUTPUT_DIR}/post_synth_util.rpt" show utilization_by_hierarchy \
  --filter '[/.](dcache_req_buf|lmem_req_buf|dcache_wr_buf|lmem_wr_buf|wr_slot_buf|response_payload_ram)$' \
  --format csv \
  -o "${OOC_BUFFERS_CSV}"

REFERENCE_AVAILABLE=0
if [[ -f "${REFERENCE_REPORT}" ]]; then
  "${PYTHON_BIN}" "${ROOT_DIR}/tools/vivado_util.py" \
    "${REFERENCE_REPORT}" show utilization_by_hierarchy \
    --filter 'u_dma_engine$' --format csv -o "${REFERENCE_ENGINE_CSV}"
  if [[ $(wc -l < "${REFERENCE_ENGINE_CSV}") -gt 1 ]]; then
    REFERENCE_AVAILABLE=1
  fi
fi

COMPARISON_ROWS="$(
  "${PYTHON_BIN}" - \
    "${OOC_ENGINE_CSV}" "${REFERENCE_ENGINE_CSV}" "${REFERENCE_AVAILABLE}" <<'PY'
import csv
import pathlib
import sys


def read_one(path):
    with pathlib.Path(path).open(newline="") as csv_file:
        rows = list(csv.DictReader(csv_file))
    if len(rows) != 1:
        raise SystemExit(f"expected one DMA engine row in {path}, found {len(rows)}")
    return rows[0]


ooc = read_one(sys.argv[1])
if sys.argv[3] != "1":
    print("Reference report or DMA engine hierarchy row was not available.")
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
# C4 DMA OOC Result

- Alias: \`${ALIAS}\`
- OOC top: \`${TOP}\`
- Device: \`${DEVICE}\`
- Config: \`${CONFIG_FILE}\`
- Git commit: \`$(git -C "${ROOT_DIR}" rev-parse HEAD)\`
- OOC report: \`post_synth_util.rpt\`
- OOC DMA engine row: \`ooc_dma_engine.csv\`
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
| Purpose | Produce a reproducible C4 improve DMA OOC synthesis result |
| Comparison rule | Compare only with an OOC run using identical synthesis inputs |
| Changed production RTL | See \`git_status.txt\` and the parent experiment manifest |
| Config | \`${CONFIG_FILE}\` |
| Git commit | \`$(git -C "${ROOT_DIR}" rev-parse HEAD)\` |
| Git state | \`git_status.txt\` |
| Vivado | \`$("${VIVADO_BIN}" -version | sed -n '1s/^vivado //p')\` |
| Device | \`${DEVICE}\` |
| OOC top | \`${TOP}\` |
| Constraint | \`hw/syn/xilinx/dut/project.xdc\` |
| Unittest | Not run by this synthesis-only script |
| xrt-vcs-sim | Not run by this synthesis-only script |
| OOC synthesis | PASS; see \`post_synth_util.rpt\` and \`post_synth_timing_summary.rpt\` |
| Checkpoint | \`$([[ ${WRITE_CHECKPOINT} -eq 1 ]] && echo retained || echo not-retained)\` |
| Conclusion | Measurement only; record the decision in the parent experiment manifest |

This script performs only the OOC stage. Structural DMA variants must pass the
unittest and xrt-vcs-sim gates required by
\`docs/future_optim/dma_optimization_experiment_rules.md\` before invoking it.
EOF

echo "DMA OOC synthesis complete: ${OUTPUT_DIR}"

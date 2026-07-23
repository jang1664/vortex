#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/../../../../../" && pwd)
BUILD_DIR=${BUILD_DIR:-"${ROOT_DIR}/build"}
CONFIG_FILE=${CONFIG_FILE:-"${ROOT_DIR}/configs/naive_gemm_simd_th16_tcol32.sh"}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [run.py options]

Options:
  --config FILE             Source this config file
  --design-name NAME        Synthesis top (VX_gemm_unit_top or VX_woq_gemm_unit_top)
  --define NAME[=VALUE]     Add a synthesis define (repeatable)
  --build-dir DIR           Configured build directory (default: ${BUILD_DIR})
  -h, --help                Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --config configs/naive_gemm.sh --define MXU_COL_TILE=8
  $(basename "$0") --config configs/improve_th32_tcol32_hwexp_dcache.sh --design-name VX_woq_gemm_unit_top --period-ns 10
  $(basename "$0") --define MXU_COL=16 --period-ns 5 \
      --syn-dir syn_topo_col16.run1
EOF
}

user_defines=()
run_args=()
while (($#)); do
    case "$1" in
        --config)
            (($# >= 2)) || { echo "missing argument for --config" >&2; exit 2; }
            CONFIG_FILE=$2
            shift 2
            ;;
        --design-name)
            (($# >= 2)) || { echo "missing argument for --design-name" >&2; exit 2; }
            case "$2" in
                VX_gemm_unit_top|VX_woq_gemm_unit_top) ;;
                *)
                    echo "invalid --design-name: $2" >&2
                    echo "expected VX_gemm_unit_top or VX_woq_gemm_unit_top" >&2
                    exit 2
                    ;;
            esac
            run_args+=(--design-name "$2")
            shift 2
            ;;
        --define)
            (($# >= 2)) || { echo "missing argument for --define" >&2; exit 2; }
            user_defines+=("$2")
            shift 2
            ;;
        --build-dir)
            (($# >= 2)) || { echo "missing argument for --build-dir" >&2; exit 2; }
            BUILD_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            run_args+=("$1")
            shift
            ;;
    esac
done

# Resolve relative config paths against the repository root.
if [[ "${CONFIG_FILE}" != /* ]]; then
    CONFIG_FILE="${ROOT_DIR}/${CONFIG_FILE}"
fi
[[ -f "${CONFIG_FILE}" ]] || {
    echo "config file not found: ${CONFIG_FILE}" >&2
    exit 2
}

# GEMM dimensions and tiling parameters are -D macros. Forward the selected
# config's macros to DC through run.py, together with explicit --define values.
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
read -r -a config_args <<< "${CONFIGS:-}"
extra_defines=()
for arg in "${config_args[@]}"; do
    if [[ "${arg}" == -D* ]]; then
        extra_defines+=("${arg#-D}")
    fi
done
extra_defines+=("${user_defines[@]}")

mkdir -p "${BUILD_DIR}"
if [[ ! -f "${BUILD_DIR}/config.mk" || ! -f "${BUILD_DIR}/hw/syn/synopsys/Makefile" ]]; then
    echo "[run.sh] configuring ${BUILD_DIR}"
    (
        cd "${BUILD_DIR}"
        "${ROOT_DIR}/configure" --xlen=64 --tooldir=/opt/vortex \
            --prefix="${HOME}/tools/vortex"
    )
fi

for define in "${extra_defines[@]}"; do
    run_args+=(--extra-define "${define}")
done

export VORTEX_HOME=${VORTEX_HOME:-${ROOT_DIR}}
export PROJ_HOME=${PROJ_HOME:-${ROOT_DIR}}
export PYTHONPATH="${ROOT_DIR}/third_party/hwexplorer${PYTHONPATH:+:${PYTHONPATH}}"

echo "[run.sh] config=${CONFIG_FILE}"
echo "[run.sh] build=${BUILD_DIR}"
echo "[run.sh] defines=${#extra_defines[@]}"
exec python3 "${SCRIPT_DIR}/run.py" "${run_args[@]}"

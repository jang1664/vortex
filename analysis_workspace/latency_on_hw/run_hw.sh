#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ./run_hw.sh --input GENERATED_SUITE_DIR --output OUTPUT_DIR [latency_bench args...]
  ./run_hw.sh GENERATED_SUITE_DIR OUTPUT_DIR [latency_bench args...]

Examples:
  ./run_hw.sh --input generated_suites/main --output outputs/main
  ./run_hw.sh generated_suites/test2 outputs/test2 --dry-run
  ./run_hw.sh --input generated_suites/main --output outputs/main --no-latency
  ./run_hw.sh --input generated_suites/main --output outputs/main --no-power
  ./run_hw.sh --input generated_suites/main --output outputs/main --power-min-run-sec 5 --power-max-run-sec 30 --power-max-iterations 512
  ./run_hw.sh --input generated_suites/main --output outputs/main --retry --retry-max-rounds 5
  ./run_hw.sh --input generated_suites/main_all --output outputs/main_all_gemm --filter "kind=gemm"
  ./run_hw.sh --input generated_suites/main_all --output outputs/main_all_prefill_gemm --filter "kind=gemm" --filter "stage=prefill"

Environment overrides:
  STAGES="prefill generation"
  FPGA_BINS="naive_gemm_tcol32 naive_simd improve_tcol32"  # restrict generated bins
EOF
}

INPUT_DIR=""
OUTPUT_DIR=""
positional=()
pass_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      INPUT_DIR="$2"
      shift 2
      ;;
    -o|--output)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --no-latency|--no-power|--power-auto-duration|--no-power-auto-duration)
      pass_args+=("$1")
      shift
      ;;
    --power-min-run-sec|--power-max-run-sec|--power-max-iterations|--power-target-samples|--power-min-interval|--power-max-interval)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --power-min-run-sec=*|--power-max-run-sec=*|--power-max-iterations=*|--power-target-samples=*|--power-min-interval=*|--power-max-interval=*)
      pass_args+=("$1")
      shift
      ;;
    --retry)
      pass_args+=("$1")
      shift
      ;;
    --retry-max-rounds|--retry-timeout-growth|--retry-reset-wait|--retry-reset-cmd)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --retry-max-rounds=*|--retry-timeout-growth=*|--retry-reset-wait=*|--retry-reset-cmd=*)
      pass_args+=("$1")
      shift
      ;;
    --filter)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --filter=*)
      pass_args+=("$1")
      shift
      ;;
    --)
      shift
      pass_args+=("$@")
      break
      ;;
    -*)
      pass_args+=("$@")
      break
      ;;
    *)
      if [[ ${#positional[@]} -lt 2 ]]; then
        positional+=("$1")
      else
        pass_args+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "${INPUT_DIR}" && ${#positional[@]} -ge 1 ]]; then
  INPUT_DIR="${positional[0]}"
fi

if [[ -z "${OUTPUT_DIR}" && ${#positional[@]} -ge 2 ]]; then
  OUTPUT_DIR="${positional[1]}"
fi

INPUT_DIR="${INPUT_DIR:-generated_suites}"
OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
INPUT_DIR="${INPUT_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR%/}"

if [[ ! -d "${INPUT_DIR}" ]]; then
  echo "ERROR: generated suite directory not found: ${INPUT_DIR}" >&2
  exit 1
fi

STAGES="${STAGES:-prefill generation}"

if [[ -z "${FPGA_BINS:-}" ]]; then
  fpga_bins=()
  for stage in ${STAGES}; do
    case "${stage}" in
      prefill|generation)
        ;;
      *)
        echo "ERROR: unsupported stage: ${stage}" >&2
        exit 1
        ;;
    esac

    shopt -s nullglob
    suites=("${INPUT_DIR}/${stage}_merged/${stage}_merged_"*.yaml)
    shopt -u nullglob

    if [[ ${#suites[@]} -eq 0 ]]; then
      echo "ERROR: no merged suites found for ${stage}: ${INPUT_DIR}/${stage}_merged/${stage}_merged_*.yaml" >&2
      exit 1
    fi

    for suite in "${suites[@]}"; do
      fpga_bin="$(basename "${suite}")"
      fpga_bin="${fpga_bin#${stage}_merged_}"
      fpga_bin="${fpga_bin%.yaml}"

      seen=0
      for existing in "${fpga_bins[@]}"; do
        if [[ "${existing}" == "${fpga_bin}" ]]; then
          seen=1
          break
        fi
      done
      if [[ ${seen} -eq 0 ]]; then
        fpga_bins+=("${fpga_bin}")
      fi
    done
  done
  FPGA_BINS="${fpga_bins[*]}"
fi

echo "Running on HW"
echo "INPUT_DIR=${INPUT_DIR}"
echo "OUTPUT_DIR=${OUTPUT_DIR}"
echo "STAGES=${STAGES}"
echo "FPGA_BINS=${FPGA_BINS}"

for stage in ${STAGES}; do
  case "${stage}" in
    prefill|generation)
      ;;
    *)
      echo "ERROR: unsupported stage: ${stage}" >&2
      exit 1
      ;;
  esac

  echo "STAGE=${stage}"
  for fpga_bin in ${FPGA_BINS}; do
    suite="${INPUT_DIR}/${stage}_merged/${stage}_merged_${fpga_bin}.yaml"
    out_dir="${OUTPUT_DIR}/${fpga_bin}"

    if [[ ! -f "${suite}" ]]; then
      echo "ERROR: suite not found for ${stage}/${fpga_bin}: ${suite}" >&2
      exit 1
    fi

    echo "FPGA_BIN=${fpga_bin} SUITE=${suite} OUT_DIR=${out_dir}"
    STAGE="${stage}" SUITE="${suite}" OUT_DIR="${out_dir}" \
      "${SCRIPT_DIR}/run_fpga_bin.sh" "${fpga_bin}" "${pass_args[@]}"
  done
done

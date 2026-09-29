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
  FPGA_BINS="C1 C3 C4"  # restrict generated bins
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
    --power-min-run-sec|--power-max-run-sec|--power-max-iterations|--power-target-samples|--power-latency-interval|--power-min-interval|--power-max-interval)
      if [[ $# -lt 2 ]]; then
        echo "Error: $1 requires a value" >&2
        usage
        exit 1
      fi
      pass_args+=("$1" "$2")
      shift 2
      ;;
    --power-min-run-sec=*|--power-max-run-sec=*|--power-max-iterations=*|--power-target-samples=*|--power-latency-interval=*|--power-min-interval=*|--power-max-interval=*)
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

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then PYTHON_BIN="python3"; fi
export STAGES
exec "${PYTHON_BIN}" "${SCRIPT_DIR}/workflow.py" run \
  --input "${INPUT_DIR}" --output "${OUTPUT_DIR}" "${pass_args[@]}"

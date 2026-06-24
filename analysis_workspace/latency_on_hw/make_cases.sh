#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PYTHON_BIN="${PYTHON:-${HOME}/.conda/envs/vortex/bin/python}"
if [[ ! -x "${PYTHON_BIN}" ]]; then
    PYTHON_BIN="python3"
fi

usage() {
    cat >&2 <<'EOF'
Usage:
  ./make_cases.sh --input SUITE_DIR --output GENERATED_SUITE_DIR [--model-prefix PREFIX]
  ./make_cases.sh SUITE_DIR [GENERATED_SUITE_DIR]

Examples:
  ./make_cases.sh --input suites/main --output generated_suites/main
  ./make_cases.sh --input suites/main_all --output generated_suites/llama3_8b_main_all --model-prefix llama3_8b
  ./make_cases.sh suites/test2 generated_suites/test2

Defaults:
  GENERATED_SUITE_DIR defaults to generated_suites when omitted.
  MODEL_PREFIX defaults to llama2_7b.
EOF
}

SUITE_DIR=""
OUTPUT_DIR=""
MODEL_PREFIX="llama2_7b"
positional=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--input)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            SUITE_DIR="$2"
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
        --model-prefix)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            MODEL_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

if [[ $# -gt 0 ]]; then
    positional+=("$@")
fi

if [[ ${#positional[@]} -gt 2 ]]; then
    echo "Error: too many positional arguments" >&2
    usage
    exit 1
fi

if [[ -z "${SUITE_DIR}" && ${#positional[@]} -ge 1 ]]; then
    SUITE_DIR="${positional[0]}"
fi

if [[ -z "${OUTPUT_DIR}" && ${#positional[@]} -ge 2 ]]; then
    OUTPUT_DIR="${positional[1]}"
fi

OUTPUT_DIR="${OUTPUT_DIR:-generated_suites}"

if [[ -z "${SUITE_DIR}" ]]; then
    echo "Error: --input SUITE_DIR is required" >&2
    usage
    exit 1
fi

SUITE_DIR="${SUITE_DIR%/}"
OUTPUT_DIR="${OUTPUT_DIR%/}"
if [[ ! -d "${SUITE_DIR}" ]]; then
    echo "Error: suite directory does not exist: ${SUITE_DIR}" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

clean_suite_dir() {
    local out_dir="$1"
    mkdir -p "${out_dir}"
    find "${out_dir}" -maxdepth 1 -type f -name '*.yaml' -delete
}

generate_suite() {
    local suite="$1"
    local out_dir="$2"
    clean_suite_dir "${out_dir}"
    "${PYTHON_BIN}" -m tools.latency_bench generate-suites --suite "${suite}" --out "${out_dir}" --overwrite
}

generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_prefill_C1.yaml" "${OUTPUT_DIR}/C1_prefill"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_prefill_C2.yaml" "${OUTPUT_DIR}/C2_prefill"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_prefill_C3.yaml" "${OUTPUT_DIR}/C3_prefill"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_prefill_C4_alone.yaml" "${OUTPUT_DIR}/C4_alone_prefill"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_prefill_C4_fused.yaml" "${OUTPUT_DIR}/C4_fused_prefill"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_generation_C1.yaml" "${OUTPUT_DIR}/C1_generation"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_generation_C2.yaml" "${OUTPUT_DIR}/C2_generation"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_generation_C3.yaml" "${OUTPUT_DIR}/C3_generation"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_generation_C4_alone.yaml" "${OUTPUT_DIR}/C4_alone_generation"
generate_suite "${SUITE_DIR}/${MODEL_PREFIX}_generation_C4_fused.yaml" "${OUTPUT_DIR}/C4_fused_generation"

clean_suite_dir "${OUTPUT_DIR}/prefill_merged"
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob "${OUTPUT_DIR}/C1_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C2_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C3_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_alone_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_fused_prefill/*.yaml" \
    --out "${OUTPUT_DIR}/prefill_merged" \
    --group-by-fpga-bin \
    --overwrite

clean_suite_dir "${OUTPUT_DIR}/generation_merged"
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob "${OUTPUT_DIR}/C1_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C2_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C3_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_alone_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_fused_generation/*.yaml" \
    --out "${OUTPUT_DIR}/generation_merged" \
    --group-by-fpga-bin \
    --overwrite

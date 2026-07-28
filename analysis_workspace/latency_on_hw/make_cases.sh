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
  ./make_cases.sh --input SUITE_DIR --output GENERATED_SUITE_DIR [override options]
  ./make_cases.sh SUITE_DIR [GENERATED_SUITE_DIR]

Examples:
  ./make_cases.sh --input suites/llama2_7b --output generated_suites/llama2_7b
  ./make_cases.sh --input suites/llama3_8b --output generated_suites/llama3_8b
  ./make_cases.sh --input suites/main --output generated_suites/main_b1_s512 --batches 1 --seq-lens 512
  ./make_cases.sh --input suites/main --output generated_suites/main_custom --prefill-batches 1,2 --generation-batches 8 --prefill-seq-lens 512,1024 --generation-seq-lens 4096
  ./make_cases.sh suites/test2 generated_suites/test2

Override options:
  --batches LIST                 Override batch values for both prefill and generation.
  --seq-lens LIST                Override sequence values for both prefill and generation.
  --prefill-batches LIST         Override prefill batch values.
  --generation-batches LIST      Override generation batch values.
  --prefill-seq-lens LIST        Override prefill sequence values.
  --generation-seq-lens LIST     Override generation sequence values.

Defaults:
  GENERATED_SUITE_DIR defaults to generated_suites when omitted.
  Override options default to the values already encoded in each input YAML.
  SUITE_DIR should contain one model family; matching multiple files for the same case is an error.
  Each generated suite directory includes model_structure.json, model_structure.layout,
  and model_structure.text dumps for all expanded workload configurations.
EOF
}

SUITE_DIR=""
OUTPUT_DIR=""
BATCHES=""
SEQ_LENS=""
PREFILL_BATCHES=""
GENERATION_BATCHES=""
PREFILL_SEQ_LENS=""
GENERATION_SEQ_LENS=""
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
        --batches|--batch-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            BATCHES="$2"
            shift 2
            ;;
        --prefill-batches|--prefill-batch-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            PREFILL_BATCHES="$2"
            shift 2
            ;;
        --generation-batches|--generation-batch-list|--gen-batches|--gen-batch-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            GENERATION_BATCHES="$2"
            shift 2
            ;;
        --seq-lens|--seq-len-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            SEQ_LENS="$2"
            shift 2
            ;;
        --prefill-seq-lens|--prefill-seq-len-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            PREFILL_SEQ_LENS="$2"
            shift 2
            ;;
        --generation-seq-lens|--generation-seq-len-list|--gen-seq-lens|--gen-seq-len-list)
            if [[ $# -lt 2 ]]; then
                echo "Error: $1 requires a value" >&2
                usage
                exit 1
            fi
            GENERATION_SEQ_LENS="$2"
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

GENERATE_ARGS=()
if [[ -n "${BATCHES}" ]]; then
    GENERATE_ARGS+=(--batches "${BATCHES}")
fi
if [[ -n "${PREFILL_BATCHES}" ]]; then
    GENERATE_ARGS+=(--prefill-batches "${PREFILL_BATCHES}")
fi
if [[ -n "${GENERATION_BATCHES}" ]]; then
    GENERATE_ARGS+=(--generation-batches "${GENERATION_BATCHES}")
fi
if [[ -n "${SEQ_LENS}" ]]; then
    GENERATE_ARGS+=(--seq-lens "${SEQ_LENS}")
fi
if [[ -n "${PREFILL_SEQ_LENS}" ]]; then
    GENERATE_ARGS+=(--prefill-seq-lens "${PREFILL_SEQ_LENS}")
fi
if [[ -n "${GENERATION_SEQ_LENS}" ]]; then
    GENERATE_ARGS+=(--generation-seq-lens "${GENERATION_SEQ_LENS}")
fi

shopt -s nullglob

find_suite() {
    local suffix="$1"
    local matches=("${SUITE_DIR}"/*"${suffix}".yaml)
    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "Error: no suite YAML matching *${suffix}.yaml in ${SUITE_DIR}" >&2
        exit 1
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "Error: multiple suite YAMLs match *${suffix}.yaml in ${SUITE_DIR}" >&2
        printf '  %s\n' "${matches[@]}" >&2
        echo "Use a suite directory containing one model family." >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

clean_suite_dir() {
    local out_dir="$1"
    mkdir -p "${out_dir}"
    find "${out_dir}" -maxdepth 1 -type f -name '*.yaml' -delete
}

generate_suite() {
    local suite="$1"
    local out_dir="$2"
    clean_suite_dir "${out_dir}"
    "${PYTHON_BIN}" -m tools.latency_bench generate-suites \
        --suite "${suite}" \
        --out "${out_dir}" \
        --overwrite \
        --dump-model-structures \
        "${GENERATE_ARGS[@]}"
}

generate_suite_by_suffix() {
    local suffix="$1"
    local out_dir="$2"
    local suite
    suite="$(find_suite "${suffix}")"
    generate_suite "${suite}" "${out_dir}"
}

generate_suite_by_suffix "prefill_C1" "${OUTPUT_DIR}/C1_prefill"
generate_suite_by_suffix "prefill_C2" "${OUTPUT_DIR}/C2_prefill"
generate_suite_by_suffix "prefill_C3" "${OUTPUT_DIR}/C3_prefill"
# generate_suite_by_suffix "prefill_C4_alone" "${OUTPUT_DIR}/C4_alone_prefill"
generate_suite_by_suffix "prefill_C4_fused" "${OUTPUT_DIR}/C4_fused_prefill"
generate_suite_by_suffix "generation_C1" "${OUTPUT_DIR}/C1_generation"
generate_suite_by_suffix "generation_C2" "${OUTPUT_DIR}/C2_generation"
generate_suite_by_suffix "generation_C3" "${OUTPUT_DIR}/C3_generation"
# generate_suite_by_suffix "generation_C4_alone" "${OUTPUT_DIR}/C4_alone_generation"
generate_suite_by_suffix "generation_C4_fused" "${OUTPUT_DIR}/C4_fused_generation"

clean_suite_dir "${OUTPUT_DIR}/prefill_merged"
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob "${OUTPUT_DIR}/C1_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C2_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C3_prefill/*.yaml" \
    # --suite-glob "${OUTPUT_DIR}/C4_alone_prefill/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_fused_prefill/*.yaml" \
    --out "${OUTPUT_DIR}/prefill_merged" \
    --group-by-fpga-bin \
    --overwrite

clean_suite_dir "${OUTPUT_DIR}/generation_merged"
"${PYTHON_BIN}" -m tools.latency_bench merge-suites \
    --suite-glob "${OUTPUT_DIR}/C1_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C2_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C3_generation/*.yaml" \
    # --suite-glob "${OUTPUT_DIR}/C4_alone_generation/*.yaml" \
    --suite-glob "${OUTPUT_DIR}/C4_fused_generation/*.yaml" \
    --out "${OUTPUT_DIR}/generation_merged" \
    --group-by-fpga-bin \
    --overwrite

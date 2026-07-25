#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_ROOT="${SCRIPT_DIR}/output_figure"

if (( $# != 1 )) || [[ -z "$1" ]]; then
    echo "Usage: $0 TARGET_DIR" >&2
    exit 2
fi

readonly TARGET="$1"
readonly RESULTS=(
    "figures_prepare"
    "figures_script/llama_e2e_gemm_layout_vector_stacked"
    "figures_script/llama_energy_gemm_layout_vector_stacked"
    "figures_script/llama_gemm_only"
    "figures_script/llama_gemm_only_energy"
    "figures_script/llama_gemm_only_no_area_norm"
)

# Validate every source before changing the target, so a partial result set is
# never copied.
for result in "${RESULTS[@]}"; do
    if [[ ! -d "${SOURCE_ROOT}/${result}" ]]; then
        echo "Error: result directory does not exist: ${SOURCE_ROOT}/${result}" >&2
        exit 1
    fi
done

mkdir -p -- "$TARGET"

for result in "${RESULTS[@]}"; do
    destination="${TARGET}/${result}"
    mkdir -p -- "$destination"
    cp -a -- "${SOURCE_ROOT}/${result}/." "$destination/"
    echo "Copied ${result} -> ${destination}"
done

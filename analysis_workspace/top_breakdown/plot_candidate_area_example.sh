#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"

cd "$repo_dir"

python \
    analysis_workspace/top_breakdown/get_area_of_candidates.py \
    --sram-type HD \
    --naive-acc \
    --c1-lmem-kib 2048 \
    --c2-lmem-kib 1536 --c2-acc-kib 512 \
    --c3-lmem-kib 1536 --c3-acc-kib 512 \
    --c4-lmem-kib 1024 --c4-acc-kib 512 --c4-tmem-kib 512 \
    --plot \
    --output-dir analysis_workspace/top_breakdown/candidate_area_results/2mib_hd_naive_acc_separate

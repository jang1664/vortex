#!/usr/bin/env bash
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
    echo "Usage: $0 USER@HOST [REMOTE_28LPP_DIR]" >&2
    exit 1
fi

remote=$1
remote_root=${2:-/home/data/memory_compiler/28LPP}
local_root=/home/data/memory_compiler/28LPP

macros=(
    cmos28lpp_ra1w_hs_512x64m8
    cmos28lpp_ra1w_hs_1024x64m8
    cmos28lpp_ra1w_hs_2048x64m8
    cmos28lpp_ra1w_hs_4096x64m8
    cmos28lpp_ra1w_hs_8192x64m16
    cmos28lpp_rf1_hs_64x128m2
)

printf -v remote_sec '%q' "$remote_root/genSEC"
printf -v remote_ndm '%q' "$remote_root/genNDM"
ssh "$remote" "mkdir -p $remote_sec $remote_ndm"

sec_sources=()
ndm_sources=()
for macro in "${macros[@]}"; do
    sec_sources+=("$local_root/genSEC/$macro")
    ndm_sources+=("$local_root/genNDM/$macro")
done

scp -r "${sec_sources[@]}" "$remote:$remote_root/genSEC/"
scp -r "${ndm_sources[@]}" "$remote:$remote_root/genNDM/"

#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../.." && pwd)
source /home/jaeyongjang/project.local/tvm/build/c4_nodsp_fsm_update_20261007_220215/environment.sh
source "$repo/configs/improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion.sh"
export CC=/usr/bin/gcc CXX=/usr/bin/g++
unset DEBUG DEBUG_AXI PERF PROFILE MAKEFLAGS XCL_EMULATION_MODE XRT_DEVICE_INDEX XRT_DEVICE_BDF
cd "$repo/build_c4_unified_mmio_hw"
evidence="$repo/agent-tasks/c4-attention-slowdown/runs/iteration1"
mkdir "$evidence/validation"
alias_name=improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_sram_fusion_unified_mmio_r1

check_flash() {
    local name=$1 app_args=$2
    echo "RUN standalone $name"
    timeout --signal=TERM --kill-after=30s 300 ./ci/run_black.sh hw \
        --fpga-bin "$alias_name" --app flash_attn --args "$app_args" \
        >"$evidence/validation/$name.log" 2>&1
    rg -q '^PASSED$' "$evidence/validation/$name.log"
    echo "PASS standalone $name"
}

check_flash legacy_single '-m 4 -n 128'
check_flash fp16_multitile '-r -m 4 -n 256'
check_flash fp32_multitile '-r -f -m 4 -n 256'
check_flash fp16_mask_tail '-r -m 16 -n 257 -c -p 0'
check_flash fp32_mask_tail '-r -f -m 16 -n 257 -c -p 0'

for case in llama3-8b_decode_p16_c32 llama3-8b_decode_p128_c256 llama3-8b_prefill128; do
    for backend in legacy resident; do
        echo "RUN CPU reference $case $backend"
        timeout 300 "$py" "$repo/tests/regression/llama_decoder_C4/reference.py" compare \
            --fixture "$repo/build_c4_sram_fusion/fixtures/resident_attention/$case" \
            --output "$evidence/$backend/$case" \
            >"$evidence/validation/$case.$backend.reference.log" 2>&1
    done
    timeout 300 "$py" "$repo/tests/regression/llama_decoder_C4/compare_attention_backends.py" \
        --legacy "$evidence/legacy/$case" --resident "$evidence/resident/$case" \
        >"$evidence/validation/$case.backends.log" 2>&1
    echo "PASS CPU references and backend comparison $case"
done

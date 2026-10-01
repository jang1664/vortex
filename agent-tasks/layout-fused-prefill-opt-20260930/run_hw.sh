#!/usr/bin/env bash
set -euo pipefail
task_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "${task_dir}/../.." && pwd)
phase=${1:-smoke}
export PYTHON=/home/jaeyongjang/.conda/envs/vortex/bin/python
export XILINX_XRT=/opt/xilinx/xrt
export RISCV_TOOLCHAIN_PATH=/opt/vortex_profiles/rv64imaf_zfh_lp64f/riscv64-gnu-toolchain
export LIBC_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libc64
export LIBCRT_VORTEX=/opt/vortex_profiles/rv64imaf_zfh_lp64f/libcrt64
alias_name=improve_th16_tcol16_m16_t8_bigmem_all_bram_v2
mkdir -p "${task_dir}/logs" "${task_dir}/raw"
printf 'Slurm job=%s phase=%s\n' "${SLURM_JOB_ID:-none}" "${phase}"

run_case() {
    local label=$1 build=$2 app=$3 args=$4
    shift 4
    local log="${task_dir}/logs/${phase}_${label}_$(date +%Y%m%dT%H%M%S).log"
    printf 'Starting %s\n' "${label}"
    python3 - "${task_dir}" "${label}" "${build}" "${app}" "${args}" "${log}" <<'PY_MANIFEST'
import datetime, hashlib, json, os, pathlib, sys
out, label, build, app, args, log = sys.argv[1:]
root = pathlib.Path(out).parent.parent
binary = root / build / 'tests' / 'regression' / app / 'kernel.vxbin'
record = dict(timestamp=datetime.datetime.now().astimezone().isoformat(),
              label=label, build=build, app=app, args=args, log=log,
              slurm_job_id=os.environ.get('SLURM_JOB_ID'),
              kernel_vxbin_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
with (pathlib.Path(out) / 'run_manifest.jsonl').open('a') as f:
    f.write(json.dumps(record) + '\n')
PY_MANIFEST
    cd "${repo_dir}/${build}"
    set +e
    timeout --kill-after=15s 300s ci/run_black.sh hw \
        --fpga-bin "${alias_name}" --run-only --app "${app}" \
        --args "${args}" "$@" > "${log}" 2>&1
    local result=$?
    set -e
    printf '%s\t%s\n' "${label}" "${result}" >> "${task_dir}/exit_codes.tsv"
    printf 'Finished %s exit=%s\n' "${label}" "${result}"
    tail -5 "${log}"
    return "${result}"
}

if [[ ${phase} == final_checks ]]; then
    for repeat in 1 2 3; do
        for implementation in control final standalone; do
            app=softmax_layout_fused
            build="build_layout_${implementation}"
            if [[ ${implementation} == standalone ]]; then app=softmax; build=build_layout_final; fi
            run_case "softmax_${implementation}_1024_${repeat}" "${build}" "${app}" \
                '-batch 1 -heads 1 -seqq 1024 -seqk 1024 -mask 1 -scale 1'
        done
    done
    for args in \
        '-batch 2 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' \
        '-batch 2 -heads 2 -seqq 7 -seqk 65 -seqk-stride 80 -mask 0' \
        '-batch 1 -heads 1 -seqq 3 -seqk 65537 -seqk-stride 65552 -mask 0'; do
        for app in softmax_layout_fused softmax; do
            run_case "${app}_$(echo "${args}" | tr ' ' '_')" build_layout_final "${app}" "${args} -scale 1"
        done
    done
    for pattern in zeros constant ties tiny large; do
        for cache in v k; do
            args="-k 17 -n 128 -q 128 -d 1 --input-pattern ${pattern} --emit-correction-qparams"
            if [[ ${cache} == k ]]; then
                args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric'
            else
                args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric'
            fi
            run_case "quant_${cache}_${pattern}" build_layout_final kv_cache_quant_layout_fused_w4a16 "${args}"
        done
    done
fi

if [[ ${phase} == edges ]]; then
    for repeat in 1 2 3; do
        for implementation in control refined; do
            run_case "softmax_${implementation}_masked_1024_${repeat}" "build_layout_${implementation}" softmax_layout_fused \
                '-batch 1 -heads 1 -seqq 1024 -seqk 1024 -mask 1 -scale 1' || true
        done
    done
    for pattern in zeros constant ties tiny large; do
        for cache in v k; do
            args="-k 17 -n 128 -q 128 -d 1 --input-pattern ${pattern} --emit-correction-qparams"
            if [[ ${cache} == k ]]; then
                args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric'
            else
                args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric'
            fi
            run_case "quant_${cache}_${pattern}" build_layout_refined kv_cache_quant_layout_fused_w4a16 "${args}" || true
        done
    done
fi

if [[ ${phase} == coverage ]]; then
    for args in \
        '-batch 2 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' \
        '-batch 2 -heads 2 -seqq 7 -seqk 65 -seqk-stride 80 -mask 0' \
        '-batch 1 -heads 1 -seqq 128 -seqk 128 -mask 1' \
        '-batch 1 -heads 1 -seqq 1024 -seqk 1024 -mask 1' \
        '-batch 1 -heads 1 -seqq 19 -seqk 4096 -mask 0'; do
        label="softmax_$(echo "${args}" | tr ' ' '_')"
        run_case "${label}" build_layout_chunk softmax_layout_fused "${args} -scale 1"
        run_case "standalone_${label}" build_layout_chunk softmax "${args} -scale 1"
    done
    for mode in spinquant_signed_symmetric spinquant_signed_asymmetric legacy_uint4_asymmetric; do
        for cache in v k; do
            args="-k 130 -n 128 -q 128 -d 1 --quant-mode ${mode} --emit-correction-qparams"
            if [[ ${cache} == k ]]; then
                args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled'
            else
                args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled'
            fi
            run_case "chunk_${cache}_${mode}" build_layout_chunk kv_cache_quant_layout_fused_w4a16 "${args}"
        done
    done
    for cache in v k; do
        args='-k 1024 -n 128 -q 128 -d 1 --emit-correction-qparams'
        if [[ ${cache} == k ]]; then
            args+=' -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_asymmetric'
        else
            args+=' -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric'
        fi
        run_case "chunk_${cache}_1024" build_layout_chunk kv_cache_quant_layout_fused_w4a16 "${args}"
    done
fi

if [[ ${phase} == fp32 ]]; then
    for repeat in 1 2 3 4 5; do
        run_case "cursor_masked_${repeat}" build_layout_variants softmax_layout_fused \
            '-batch 1 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1'
    done
    for mode in spinquant_signed_symmetric spinquant_signed_asymmetric; do
        run_case "quant_thread_v_${mode}" build_layout_fp32 kv_cache_quant_layout_fused_w4a16 \
            "-k 130 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode ${mode} --emit-correction-qparams"
        run_case "quant_thread_k_${mode}" build_layout_fp32 kv_cache_quant_layout_fused_w4a16 \
            "-k 130 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode ${mode} --emit-correction-qparams"
    done
fi

if [[ ${phase} == baseline_quant ]]; then
    run_case quant_baseline_v_padding build_layout_baseline kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams' || true
    run_case quant_baseline_k_padding build_layout_baseline kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams' || true
fi

if [[ ${phase} == diagnose ]]; then
    run_case softmax_standalone_masked build_layout_baseline softmax \
        '-batch 1 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' || true
    run_case softmax_generic_masked build_layout_baseline softmax_layout_fused \
        '-batch 1 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' || true
    run_case softmax_cursor_unmasked build_layout_variants softmax_layout_fused \
        '-batch 2 -heads 2 -seqq 7 -seqk 65 -seqk-stride 80 -mask 0' || true
    run_case quant_warp_v_padding build_layout_variants kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams' || true
    run_case quant_warp_k_padding build_layout_variants kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams' || true
fi

if [[ ${phase} == smoke ]]; then
    # Inspect the historical default separately; its failure is diagnostic.
    run_case softmax_baseline_masked build_layout_baseline softmax_layout_fused \
        '-batch 1 -heads 1 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1' || true
    run_case softmax_cursor_masked build_layout_variants softmax_layout_fused \
        '-batch 1 -heads 2 -seqq 19 -seqk 33 -seqk-stride 40 -mask 1'
    run_case softmax_cursor_unmasked build_layout_variants softmax_layout_fused \
        '-batch 2 -heads 2 -seqq 7 -seqk 65 -seqk-stride 80 -mask 0'
    run_case quant_warp_v_padding build_layout_variants kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 0 --gemm-qdir 1 --layout-from gemm_c_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams'
    run_case quant_warp_k_padding build_layout_variants kv_cache_quant_layout_fused_w4a16 \
        '-k 130 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled --quant-mode spinquant_signed_symmetric --emit-correction-qparams'
fi

if [[ ${phase} == perf || ${phase} == perf_refined || ${phase} == perf_final ]]; then
    candidate=chunk
    if [[ ${phase} == perf_refined ]]; then candidate=refined; fi
    if [[ ${phase} == perf_final ]]; then candidate=final; fi
    for seq in 1024 4096; do
        for cache in k v; do
            if [[ ${cache} == k ]]; then
                common="-k ${seq} -n 128 -q 128 -d 1 -t 1 --quant-mode spinquant_signed_asymmetric"
                fused=' --gemm-qdir 0 --source-transposed --layout-from gemm_a_tiled'
            else
                common="-k ${seq} -n 128 -q 128 -d 1 -t 0 --quant-mode spinquant_signed_symmetric"
                fused=' --gemm-qdir 1 --layout-from gemm_c_tiled --source-total-n 4096 --head-col-offset 0'
            fi
            for implementation in control "${candidate}" standalone; do
                app=kv_cache_quant_layout_fused_w4a16
                build="build_layout_${implementation}"
                args="${common}${fused}"
                if [[ ${implementation} == standalone ]]; then
                    app=kv_cache_quant_w4a16
                    build="build_layout_${candidate}"
                    args="${common}"
                fi
                label="quant_${cache}_${implementation}_${seq}"
                run_case "verify_${label}" "${build}" "${app}" "${args}"
                run_case "${label}" "${build}" "${app}" \
                    "${args} --copy-inputs --warmup=1 --iterations=3 --csv --output=${task_dir}/raw/${label}.csv" --bench
            done
        done
        for implementation in control "${candidate}" standalone; do
            app=softmax_layout_fused
            build="build_layout_${implementation}"
            if [[ ${implementation} == standalone ]]; then
                app=softmax
                build="build_layout_${candidate}"
            fi
            args="-batch 1 -heads 1 -seqq ${seq} -seqk ${seq} -mask 1 -scale 1"
            label="softmax_${implementation}_${seq}"
            run_case "verify_${label}" "${build}" "${app}" "${args}"
            run_case "${label}" "${build}" "${app}" \
                "${args} --copy-inputs --warmup=1 --iterations=3 --csv --output=${task_dir}/raw/${label}.csv" --bench
        done
    done
fi

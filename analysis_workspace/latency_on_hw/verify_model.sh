mkdir -p outputs

python ../../tools/workload/gen_kernel_cfgs.py \
    --model llama2-7b \
    --stage prefill \
    --prefill-seq-len 8 \
    --variant all_sgemm_tcu \
    --format layout > outputs/prefill_all_sgemm_tcu_cfgs.txt

python ../../tools/workload/gen_kernel_cfgs.py \
    --model llama2-7b \
    --stage prefill \
    --prefill-seq-len 8 \
    --variant attn_sgemm_tcu_fpint_gemm_naive \
    --format layout > outputs/prefill_attn_sgemm_tcu_fpint_gemm_naive_cfgs.txt

python ../../tools/workload/gen_kernel_cfgs.py \
    --model llama2-7b \
    --stage prefill \
    --prefill-seq-len 8 \
    --variant all_fpint_gemm_naive \
    --format layout > outputs/prefill_all_fpint_gemm_naive_cfgs.txt

python ../../tools/workload/gen_kernel_cfgs.py \
    --model llama2-7b \
    --stage prefill \
    --prefill-seq-len 8 \
    --variant all_fpint_gemm_improve_alone_layout \
    --format layout > outputs/prefill_all_fpint_improve_alone_cfgs.txt

python ../../tools/workload/gen_kernel_cfgs.py \
    --model llama2-7b \
    --stage prefill \
    --prefill-seq-len 8 \
    --variant all_fpint_gemm_improve_fused_layout \
    --format layout > outputs/prefill_all_fpint_improve_fused_cfgs.txt
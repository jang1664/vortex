#!/bin/bash

# Bench-binary flags (--warmup, --iterations, --csv, --output=PATH,
# --output-append) are passed through --args alongside the app's shape flags.
# blackbox.sh only owns --bench (the toggle that selects <app>_bench instead
# of <app>).

# Absolute path: the bench binary runs from tests/regression/<app>/ (because
# blackbox.sh does `make -C "$APP_PATH"`), so a relative --output=PATH would
# resolve there, not next to this script. Anchor it to the script's cwd.
OUT_DIR="$(pwd)/bench_logs/llama2-7b"
mkdir -p "$OUT_DIR"

# temporary
python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/m128k128n128.csv -m 128 -n 128 -k 128 -q 32 -t 0 -d 0"

# llama2-7b, qblk=32, seqlen=128
# python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/qkvo_proj_s128_q32.csv -m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0"
# python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/gate_up_proj_s128_q32.csv -m 128 -n 11008 -k 4096 -q 32 -t 0 -d 0"
# python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/down_proj_s128_q32.csv -m 128 -n 4096 -k 11008 -q 32 -t 0 -d 0"
# python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/attn_qkT_s128.csv -m 128 -n 128 -k 128 -q 128 -t 1 -d 0"
# python ci/runblack.py hw --bench --app=fpint_gemm_ffn_hw_improve --args="--warmup=3 --iterations=10 --csv --output=$OUT_DIR/attn_pv_s128.csv -m 128 -n 128 -k 128 -q 128 -t 0 -d 1"
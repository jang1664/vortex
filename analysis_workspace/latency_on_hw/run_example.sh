#!/bin/bash
# ----------------------------------------------------------
# compoase
# ----------------------------------------------------------
python run_compose.py \
  --llama2-results outputs_llama2_main.C3_C4_v3 \
  --llama3-results outputs_llama3_main.C3_C4_v3 \
  --llama2-suites generated_suites/llama2_7b_main_full_v2.C3_C4_v3 \
  --llama3-suites generated_suites/llama3_8b_main_full_v2.C3_C4_v3 \
  --raw-db-subdirs C1,C3,C4_v3  \
  --out composed_results.C3_C4_v3

# ----------------------------------------------------------
# prepare
# ----------------------------------------------------------
python prepare.py \
  --composed-csv composed_results.C3_C4_v3/combined/composed.csv \
  --out-tokens 128 \
  --workers 4 \
  --output-root figure_prepare.C3_C4_v3

# ----------------------------------------------------------
# plot
# ----------------------------------------------------------
python plot.py \
  --plot all --out-tokens 128 --workers 4 \
  --prepared-root figure_prepare.C3_C4_v3 \
  --out-dir figure_output.C3_C4_v3

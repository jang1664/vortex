#!/bin/bash

# python run_compose.py \
#   --llama2-results outputs_llama2_main \
#   --llama3-results outputs_llama3_main \
#   --llama2-suites generated_suites/llama2_7b_main_full \
#   --llama3-suites generated_suites/llama3_8b_main_full \
#   --out composed_results.old_c3_c4 

# python run_compose.py \
#   --llama2-results outputs_llama2_main.new_c4 \
#   --llama3-results outputs_llama3_main.new_c4 \
#   --llama2-suites generated_suites/llama2_7b_main_full.new_c4 \
#   --llama3-suites generated_suites/llama3_8b_main_full.new_c4 \
#   --raw-db-subdirs C1,C3,C4_2  \
#   --out composed_results.new_c4 

python run_compose.py \
  --llama2-results outputs_llama2_main.C3_v3_C4_v3 \
  --llama3-results outputs_llama3_main.C3_v3_C4_v3 \
  --llama2-suites generated_suites/llama2_7b_main_full.C3_v3_C4_v3 \
  --llama3-suites generated_suites/llama3_8b_main_full.C3_v3_C4_v3 \
  --raw-db-subdirs C1,C3_v3,C4_v3  \
  --out composed_results.C3_v3_C4_v3 
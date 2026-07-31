#!/bin/bash
# python prepare.py \
#   --composed-csv composed_results.old_c3_c4/combined/composed.csv \
#   --out-tokens 128 \
#   --workers 4 \
#   --output-root figure_prepare.old_c3_c4

# python prepare.py \
#   --composed-csv composed_results.new_c4/combined/composed.csv \
#   --out-tokens 128 \
#   --workers 4 \
#   --output-root figure_prepare.new_c4

python prepare.py \
  --composed-csv composed_results.C3_v3_C4_v3/combined/composed.csv \
  --out-tokens 128 \
  --workers 4 \
  --output-root figure_prepare.C3_v3_C4_v3
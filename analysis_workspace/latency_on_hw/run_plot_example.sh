#!/bin/bash

# python plot.py \
#   --plot all --out-tokens 128 --workers 4 \
#   --prepared-root figure_prepare.old_c3_c4 \
#   --out-dir figure_output.old_c3_c4

# python plot.py \
#   --plot all --out-tokens 128 --workers 4 \
#   --prepared-root figure_prepare.new_c4 \
#   --out-dir figure_output.new_c4

python plot.py \
  --plot all --out-tokens 128 --workers 4 \
  --prepared-root figure_prepare.C3_v3_C4_v3 \
  --out-dir figure_output.C3_v3_C4_v3
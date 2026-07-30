#!/bin/bash

# python plot.py \
#   --plot all --out-tokens 128 --workers 4 \
#   --prepared-root figure_prepare.old_c3_c4 \
#   --out-dir figure_output.old_c3_c4

python plot.py \
  --plot all --out-tokens 128 --workers 4 \
  --prepared-root figure_prepare.new_c4 \
  --out-dir figure_output.new_c4
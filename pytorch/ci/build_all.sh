#!/bin/zsh

CONFIGS="-DFPU_FPNEW" \
make all 2>&1 | tee build.log
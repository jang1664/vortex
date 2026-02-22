#!/bin/bash

make clean

# make sim M=4 K=32 N=32 TEST=M4K32N32
# make sim M=8 K=32 N=32 TEST=M8K32N32
# make sim M=32 K=32 N=32 TEST=M32K32N32
# make sim M=2 K=32 N=64 TEST=M2K32N64
make sim M=2 K=32 N=128 TEST=M2K32N128
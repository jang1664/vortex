#!/bin/bash
# Smoke test for VX_sp_ram_compiled / VX_dp_ram_compiled.
# Instantiates every inventory shape via the wrapper and resolves the Samsung
# 28LPP macros from /home/data/memory_compiler/28LPP/genSEC.
set -e
cd "$(dirname "$0")"

VORTEX=$(realpath ../../..)
RTL=$VORTEX/hw/rtl
MACRO_ROOT=/home/data/memory_compiler/28LPP/genSEC

INC="+incdir+$RTL+$RTL/libs+$(pwd)"

# Each macro is in its own dir named after the module. -y looks for
# <modulename>.v in each path; we pass them all so VCS can pull on demand.
LIB_PATHS=""
for d in cmos28lpp_ra1w_hd_8192x64m16 \
         cmos28lpp_ra1w_hs_2048x128m8 \
         cmos28lpp_ra1w_hs_1024x128m8 \
         cmos28lpp_rf1_hd_64x128m2 \
         cmos28lpp_ra2_hd_1024x18m16 \
         cmos28lpp_ra2_hd_64x23m4 \
         cmos28lpp_rf2_hd_16x146m1 \
         cmos28lpp_rf2_hd_16x44m1 \
         cmos28lpp_rf2w_hd_64x128m1; do
    LIB_PATHS+=" -y $MACRO_ROOT/$d/"
done
LIB_EXT="+libext+.v"

# clean
rm -rf AN.DB work.lib++ csrc simv.daidir .vcs vc_hdrs.h ucli.key
rm -f simv

vlogan -nc -sverilog -full64 -kdb -q -timescale=1ns/1ps \
    +define+SYNTHESIS +define+NDEBUG +define+XLEN_64 \
    +define+COMPILED_SRAM_28LPP \
    "$INC" \
    $LIB_PATHS $LIB_EXT \
    $RTL/libs/VX_sp_ram_compiled.sv \
    $RTL/libs/VX_dp_ram_compiled.sv \
    test_compiled.sv

vcs -nc -sverilog -full64 -q -timescale=1ns/1ps test_compiled_top -o simv 2>&1 | tail -3

./simv -q 2>&1 | grep -E "test_compiled|finish|Error"

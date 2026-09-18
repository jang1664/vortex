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

# NOTE: a few HS macro models (e.g. rf1_hs_64x128m2, hs_8192x64m16) are not
# pulled in through `-y` library resolution, so pass the behavioral models
# explicitly — same as hw/syn/synopsys/run_syn_vortex_axi.py does for DC.
MACRO_V=""
for d in cmos28lpp_ra1w_hd_8192x64m16 \
         cmos28lpp_ra1w_hd_2048x64m16 \
         cmos28lpp_ra1w_hd_1024x64m8 \
         cmos28lpp_ra1w_hs_8192x64m16 \
         cmos28lpp_ra1w_hs_2048x128m8 \
         cmos28lpp_ra1w_hs_1024x128m8 \
         cmos28lpp_ra1w_hs_256x128m8 \
         cmos28lpp_rf1_hd_64x128m2 \
         cmos28lpp_rf1_hs_64x128m2 \
         cmos28lpp_ra2_hd_1024x18m16 \
         cmos28lpp_ra2_hd_64x23m4 \
         cmos28lpp_rf2_hd_16x146m1 \
         cmos28lpp_rf2_hd_16x160m1 \
         cmos28lpp_rf2_hd_16x64m1 \
         cmos28lpp_rf2_hd_16x44m1 \
         cmos28lpp_rf2_hd_8x64m1 \
         cmos28lpp_rf2w_hd_64x128m1; do
    MACRO_V+=" $MACRO_ROOT/$d/$d.v"
done

# clean
rm -rf AN.DB work.lib++ csrc simv.daidir .vcs vc_hdrs.h ucli.key
rm -f simv

vlogan -nc -sverilog -full64 -kdb -q -timescale=1ns/1ps \
    +define+SYNTHESIS +define+NDEBUG +define+XLEN_64 \
    +define+COMPILED_SRAM_28LPP \
    "$INC" \
    $MACRO_V \
    $RTL/libs/VX_sp_ram_compiled.sv \
    $RTL/libs/VX_dp_ram_compiled.sv \
    test_compiled.sv

vcs -nc -sverilog -full64 -q -timescale=1ns/1ps test_compiled_top -o simv 2>&1 | tail -3

./simv -q 2>&1 | grep -E "test_compiled|finish|Error"

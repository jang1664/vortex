#!/bin/bash
# Reproduce the SRAM-parameter dump used to populate sram_inventory.md.
#
# Output is the resolved depth/width/MSHR-DATAW for every RAM-instantiating
# module under the .envrc configuration (+ SYNTHESIS/NDEBUG/XLEN_64).
#
# Usage: ./run.sh
#   - Requires VCS in $PATH (vlogan, vcs).
#   - Operates in the current working directory; creates simv + scratch.
set -e
cd "$(dirname "$0")"

VORTEX=$(realpath ../../..)
RTL=$VORTEX/hw/rtl

INC="+incdir+$RTL+$RTL/libs+$RTL/interfaces+$RTL/core+$RTL/core/gemm+$RTL/cache+$RTL/mem+$RTL/fpu+$RTL/tcu+$RTL/tcu/bhf+$RTL/verification+$RTL/afu/xrt+$(pwd)"

# clean
rm -rf AN.DB work.lib++ csrc simv.daidir .vcs vc_hdrs.h ucli.key
rm -f simv

# vlogan: macro overrides come from _predefs.sv (NOT +define+, see note)
vlogan -nc -sverilog -full64 -kdb -q "$INC" \
  _predefs.sv \
  $RTL/VX_gpu_pkg.sv \
  $RTL/fpu/VX_fpu_pkg.sv \
  $RTL/verification/cf_math_util_pkg.sv \
  $RTL/verification/VX_utils_pkg.sv \
  $RTL/tcu/VX_tcu_pkg.sv \
  dump.sv

# elaborate + sim
vcs -nc -sverilog -full64 -q dump_top -o simv
./simv -q

# Note: VCS +define+NDEBUG / +define+XLEN_64 on the command line did not
# propagate consistently to the package-included VX_config.vh in this flow.
# A pre-defined include (_predefs.sv → _predefs.svh) is the reliable workaround.

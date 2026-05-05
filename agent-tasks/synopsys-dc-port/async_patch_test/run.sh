#!/bin/bash
# Smoke test for VX_async_ram_patch: elaborates the patch with each of the
# three RTL sites' parameters, on both the non-SYNOPSYS (Vivado-style
# placeholder shim) and SYNOPSYS (flop-array) paths.
#
# Usage: ./run.sh
#   - Requires VCS in $PATH (vlogan, vcs).
#   - Operates in the current working directory; creates simv + scratch.
set -e
cd "$(dirname "$0")"

VORTEX=$(realpath ../../..)
RTL=$VORTEX/hw/rtl
INC="+incdir+$RTL+$RTL/libs+$(pwd)"

run_one() {
    local LABEL="$1"; shift
    echo "============================================================"
    echo "[$LABEL]"
    echo "============================================================"
    rm -rf AN.DB work.lib++ csrc simv.daidir .vcs vc_hdrs.h ucli.key
    rm -f simv
    vlogan -nc -sverilog -full64 -kdb -q "$@" "$INC" \
        test_patch_predefs.sv \
        $RTL/libs/VX_placeholder.sv \
        $RTL/libs/VX_async_ram_patch.sv \
        test_patch.sv
    vcs -nc -sverilog -full64 -q test_patch_top -o simv
    ./simv -q | grep -E "test_patch|finish"
}

run_one "non-SYNOPSYS path (Vivado-style placeholder shim)"
run_one "SYNOPSYS path (sync-write + async-read flop array)" "+define+SYNOPSYS"
echo "============================================================"
echo "Both paths compiled and ran."

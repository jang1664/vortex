#!/usr/bin/env bash
# Standalone VCS/Verdi FSDB smoke test (Tier 1).
#
# Exercises the same bind-based FSDB injection pattern that the real Vortex
# hw_emu flow needs, but with *no* Vitis involvement — so it isolates whether
# vcs_fsdb_init.sv itself, the bind resolution, and the Verdi PLI linkage
# are correct. Runs in under a minute.
#
# Pass criteria:
#   1. vlogan/vcs complete without error.
#   2. ./simv runs to $finish without "Undefined system task $fsdbDump*".
#   3. vortex.fsdb is produced with non-trivial size (> ~1 KB).
#
# If any of these fail, the issue is in the SV or PLI environment, not in
# the Vitis packaging pipeline — no point rebuilding Vitis yet.

set -euo pipefail

cd "$(dirname "$0")"

# ---- environment (mirrors what Vortex's Vitis build uses) -------------------
export VG_GNU_PACKAGE=${VG_GNU_PACKAGE:-/tool/Program/synopsys/vcs_gnu/W-2024.09-SP1/linux}
# The vg_gnu source script references unset vars; relax -u for it.
set +u
# shellcheck disable=SC1091
source "$VG_GNU_PACKAGE/source_me_gcc920_64.sh"
set -u

export VCS_HOME=${VCS_HOME:-/tool/Program/synopsys/vcs/W-2024.09-SP1}
export PATH="$VCS_HOME/bin:$PATH"
export VCS_ARCH_OVERRIDE=linux

export VERDI_HOME=${VERDI_HOME:-/tool/Program/synopsys/verdi/W-2024.09-SP1}
if [[ ! -d "$VERDI_HOME/share/PLI/VCS/LINUX64" ]]; then
    echo "ERROR: Verdi PLI not found at $VERDI_HOME/share/PLI/VCS/LINUX64" >&2
    exit 1
fi
export LD_LIBRARY_PATH="$VERDI_HOME/share/PLI/VCS/LINUX64:${LD_LIBRARY_PATH:-}"

# ---- clean previous run -----------------------------------------------------
rm -rf csrc simv simv.daidir AN.DB .vlogan.log
rm -f ./*.fsdb ./*.log ./ucli.key

# ---- vlogan: parse SV into work library -------------------------------------
# +define+VCS_FSDB_DUMP: arms the `ifdef guard in vcs_fsdb_init.sv.
# No -kdb flags here (to match Vortex's compile.sh which also omits them;
# mixing -kdb asymmetrically across stages triggers ANA-KDB-ICS).
echo "[1/3] vlogan..."
vlogan -full64 -sverilog -timescale=1ns/1ps \
    +define+VCS_FSDB_DUMP \
    -l vlogan.log \
    tiny_dut.sv tiny_tb.sv vcs_fsdb_init.sv

# ---- vcs: elaborate top and link simv --------------------------------------
# -debug_access+all: required so $fsdbDump* system tasks are provided by PLI.
echo "[2/3] vcs elab..."
vcs -full64 -debug_access+all -l elaborate.log \
    tiny_tb \
    -o simv

# ---- simv: run and dump -----------------------------------------------------
echo "[3/3] simv..."
./simv -l simulate.log

# ---- verdict ----------------------------------------------------------------
echo ""
echo "=========================================="
echo "  RESULT"
echo "=========================================="
if [[ -f vortex.fsdb ]]; then
    size=$(stat -c '%s' vortex.fsdb)
    echo "PASS: vortex.fsdb generated ($size bytes)"
else
    echo "FAIL: vortex.fsdb NOT generated"
fi
echo ""
echo "--- simulate.log: fsdb/novas/verdi lines ---"
grep -iE 'fsdb|novas|verdi' simulate.log || echo "(none — system tasks silently no-op'd?)"
echo ""
echo "--- elaborate.log: bind resolution ---"
grep -iE 'bind|u_vcs_fsdb_dump_init' elaborate.log || echo "(no bind trace — elaborate may not have resolved the bind)"

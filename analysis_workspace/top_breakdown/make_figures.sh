#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

usage() {
    cat <<'EOF'
Usage: ./make_figures.sh

Regenerate top_breakdown figures from:
  build/hw/syn/synopsys/top_analysis/Vortex_axi_improve_th32_tcol32_hwexp_dcache/top/reports/14_Vortex_axi.mapped.area.rpt

Environment:
  PYTHON=/path/to/python   Python interpreter to use (default: python3)

Options:
  -h, --help               Show this help text
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

find_python() {
    if [ -n "${PYTHON:-}" ]; then
        printf '%s\n' "$PYTHON"
        return 0
    fi

    local candidate resolved
    for candidate in \
        "$HOME/anaconda3/bin/python" \
        "$HOME/miniconda3/bin/python" \
        python3.11 python3.10 python3.9 python3
    do
        resolved=""
        if resolved="$(command -v "$candidate" 2>/dev/null)"; then
            :
        elif [ -x "$candidate" ]; then
            resolved="$candidate"
        else
            continue
        fi

        if "$resolved" - <<'PY' >/dev/null 2>&1
import importlib
for name in ("matplotlib", "pandas", "hwexplorer"):
    importlib.import_module(name)
PY
        then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    echo "error: no Python interpreter with matplotlib, pandas, and hwexplorer found" >&2
    echo "       set PYTHON=/path/to/python and retry" >&2
    return 1
}

python_bin="$(find_python)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"
syn_dir="$repo_dir/build/hw/syn/synopsys/top_analysis/Vortex_axi_improve_th32_tcol32_hwexp_dcache/top"

"$python_bin" breakdown.py --syn-dir "$syn_dir"

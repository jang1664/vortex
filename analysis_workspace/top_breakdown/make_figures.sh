#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

usage() {
    cat <<'EOF'
Usage: ./make_figures.sh [nt8|nt32 ...]

Regenerate top_breakdown figures. With no run names, regenerates both nt8
and nt32.

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

runs=("$@")
if [ "${#runs[@]}" -eq 0 ]; then
    runs=(nt32)
fi

for run in "${runs[@]}"; do
    case "$run" in
        nt8|nt32)
            ;;
        *)
            echo "error: unknown run: $run" >&2
            usage >&2
            exit 2
            ;;
    esac
    "$python_bin" breakdown.py --run "$run"
done

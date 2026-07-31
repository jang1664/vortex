#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

extract_breakdown=false

usage() {
    cat <<'EOF'
Usage: ./make_figures.sh [--extract]

Generate Figure 10 and retain FPxFP/WKV/WoQ efficiency data.

Environment:
  PYTHON=/path/to/python   Python interpreter to use (default: auto-detected)

Options:
  --extract                Refresh both CSVs from synthesis reports
  -h, --help               Show this help text
EOF
}

find_python() {
    if [ -n "${PYTHON:-}" ]; then
        printf '%s\n' "$PYTHON"
        return 0
    fi

    local candidate resolved conda_bin conda_base conda_python
    conda_python=""
    if conda_bin="$(command -v conda 2>/dev/null)"; then
        if conda_base="$("$conda_bin" info --base 2>/dev/null)"; then
            conda_python="$conda_base/bin/python"
        fi
    fi

    for candidate in \
        "$conda_python" \
        "$HOME/anaconda3/bin/python" \
        "$HOME/miniconda3/bin/python" \
        python python3.11 python3.10 python3.9 python3
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
importlib.import_module("matplotlib")
PY
        then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    echo "error: no Python interpreter with matplotlib and numpy found" >&2
    echo "       set PYTHON=/path/to/python and retry" >&2
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --extract)
            extract_breakdown=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

python_bin="$(find_python)"

if "$extract_breakdown"; then
    "$python_bin" extract.py
fi

for input in wkvwoq_breakdown.csv fpxfp_wkv_woq_efficiency.csv; do
    if [ ! -s "$input" ]; then
        echo "error: missing required input: $script_dir/$input" >&2
        echo "       run with --extract where the synthesis reports are available" >&2
        exit 1
    fi
done

"$python_bin" plot.py

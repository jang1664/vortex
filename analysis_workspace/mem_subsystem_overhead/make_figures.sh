#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

skip_extract=0

usage() {
    cat <<'EOF'
Usage: ./make_figures.sh [--skip-extract]

Regenerate mem_subsystem_overhead CSVs and figures.

Environment:
  PYTHON=/path/to/python   Python interpreter to use (default: python3)

Options:
  --skip-extract           Reuse existing area.csv and routing.csv
  -h, --help               Show this help text
EOF
}

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
for name in ("matplotlib", "numpy"):
    importlib.import_module(name)
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
        --skip-extract)
            skip_extract=1
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

if [ "$skip_extract" -eq 0 ]; then
    "$python_bin" extract.py
fi

"$python_bin" plot.py

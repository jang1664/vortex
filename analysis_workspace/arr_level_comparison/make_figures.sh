#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

python_bin="${PYTHON:-python3}"
skip_extract=0

usage() {
    cat <<'EOF'
Usage: ./make_figures.sh [--skip-extract]

Regenerate arr_level_comparison figures and tables.

Environment:
  PYTHON=/path/to/python   Python interpreter to use (default: python3)

Options:
  --skip-extract           Reuse existing data.csv and wkvwoq_breakdown.csv
  -h, --help               Show this help text
EOF
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

if [ "$skip_extract" -eq 0 ]; then
    "$python_bin" extract.py
fi

"$python_bin" plot.py
"$python_bin" scale_array_size.py

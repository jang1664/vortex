#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

python_bin="${PYTHON:-python3}"

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

runs=("$@")
if [ "${#runs[@]}" -eq 0 ]; then
    runs=(nt8 nt32)
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

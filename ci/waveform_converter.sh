#!/usr/bin/env bash
set -euo pipefail

show_usage() {
  cat <<'EOF'
Usage:
  vcd_to_fsdb.sh [mode] [files...]
  vcd_to_fsdb.sh --mode <fst2vcd|vcd2fsdb|fst2fsdb> [files...]

Modes:
  fst2vcd   : *.fst -> reports/<name>.vcd
  vcd2fsdb  : *.vcd -> reports/<name>.fsdb
  fst2fsdb  : *.fst -> reports/<name>.fsdb (via temporary VCD)

Examples:
  ./ci/vcd_to_fsdb.sh *.vcd
  ./ci/vcd_to_fsdb.sh a.vcd b.vcd
  ./ci/vcd_to_fsdb.sh fst2vcd reports/*.fst
  ./ci/vcd_to_fsdb.sh --mode fst2fsdb "reports/*.fst"

Options:
  -m, --mode <mode>      Explicit mode.
  -o, --out-dir <dir>    Output directory (default: reports).
  -h, --help             Show this message.

Notes:
  - If mode is omitted, it is inferred from input extensions:
      *.vcd -> vcd2fsdb, *.fst -> fst2fsdb
  - If no files are provided, defaults are taken from <out-dir>:
      fst2vcd/fst2fsdb -> <out-dir>/*.fst
      vcd2fsdb         -> <out-dir>/*.vcd
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

has_glob_chars() {
  [[ "$1" == *'*'* || "$1" == *'?'* || "$1" == *'['* ]]
}

expand_inputs() {
  local -n _out_arr=$1
  shift

  local token
  for token in "$@"; do
    if [[ -f "$token" ]]; then
      _out_arr+=("$token")
      continue
    fi

    if has_glob_chars "$token"; then
      local matches=()
      mapfile -t matches < <(compgen -G "$token" || true)
      if ((${#matches[@]} == 0)); then
        echo "Warning: no files matched '$token'" >&2
        continue
      fi
      local m
      for m in "${matches[@]}"; do
        [[ -f "$m" ]] && _out_arr+=("$m")
      done
      continue
    fi

    die "input file not found: $token"
  done
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found in PATH"
}

infer_mode() {
  local files=("$@")
  local all_vcd=1
  local all_fst=1
  local f ext

  for f in "${files[@]}"; do
    ext="${f##*.}"
    case "$ext" in
      vcd) all_fst=0 ;;
      fst) all_vcd=0 ;;
      *)
        all_vcd=0
        all_fst=0
        ;;
    esac
  done

  if ((all_vcd)); then
    echo "vcd2fsdb"
    return
  fi
  if ((all_fst)); then
    echo "fst2fsdb"
    return
  fi
  die "cannot infer mode from mixed/unknown extensions, use --mode"
}

MODE=""
OUT_DIR="reports"
RAW_INPUTS=()

while (($#)); do
  case "$1" in
    -h|--help)
      show_usage
      exit 0
      ;;
    -m|--mode)
      shift
      (($#)) || die "missing value after --mode"
      MODE="$1"
      ;;
    --mode=*)
      MODE="${1#*=}"
      ;;
    -o|--out-dir|--outdir)
      shift
      (($#)) || die "missing value after --out-dir"
      OUT_DIR="$1"
      ;;
    --out-dir=*|--outdir=*)
      OUT_DIR="${1#*=}"
      ;;
    fst2vcd|vcd2fsdb|fst2fsdb)
      if [[ -z "$MODE" && ${#RAW_INPUTS[@]} -eq 0 ]]; then
        MODE="$1"
      else
        RAW_INPUTS+=("$1")
      fi
      ;;
    --)
      shift
      while (($#)); do
        RAW_INPUTS+=("$1")
        shift
      done
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      RAW_INPUTS+=("$1")
      ;;
  esac
  shift
done

[[ "$MODE" == "" || "$MODE" == "fst2vcd" || "$MODE" == "vcd2fsdb" || "$MODE" == "fst2fsdb" ]] || die "invalid mode: $MODE"

INPUTS=()
if ((${#RAW_INPUTS[@]} > 0)); then
  expand_inputs INPUTS "${RAW_INPUTS[@]}"
fi

if [[ -z "$MODE" ]]; then
  if ((${#INPUTS[@]} == 0)); then
    die "no input files provided"
  fi
  MODE="$(infer_mode "${INPUTS[@]}")"
fi

if ((${#INPUTS[@]} == 0)); then
  case "$MODE" in
    fst2vcd|fst2fsdb)
      expand_inputs INPUTS "$OUT_DIR/*.fst"
      ;;
    vcd2fsdb)
      expand_inputs INPUTS "$OUT_DIR/*.vcd"
      ;;
  esac
fi

if ((${#INPUTS[@]} == 0)); then
  die "no input files to process"
fi

case "$MODE" in
  fst2vcd) require_cmd fst2vcd ;;
  vcd2fsdb) require_cmd vcd2fsdb ;;
  fst2fsdb)
    require_cmd fst2vcd
    require_cmd vcd2fsdb
    ;;
esac

mkdir -p "$OUT_DIR"

count=0
for file in "${INPUTS[@]}"; do
  base="${file##*/}"
  case "$MODE" in
    fst2vcd)
      out_vcd="$OUT_DIR/${base}.vcd"
      echo "[fst2vcd] $file -> $out_vcd"
      fst2vcd "$file" -o "$out_vcd"
      ;;
    vcd2fsdb)
      out_fsdb="$OUT_DIR/${base}.fsdb"
      echo "[vcd2fsdb] $file -> $out_fsdb"
      vcd2fsdb "$file" -o "$out_fsdb"
      ;;
    fst2fsdb)
      out_vcd="$OUT_DIR/${base}.vcd"
      out_fsdb="$OUT_DIR/${base}.fsdb"
      echo "[fst2fsdb] $file -> $out_fsdb"
      fst2vcd "$file" -o "$out_vcd"
      vcd2fsdb "$out_vcd" -o "$out_fsdb"
      rm -f "$out_vcd"
      ;;
  esac
  ((++count))
done

echo "Done: mode=$MODE, files=$count, out_dir=$OUT_DIR"

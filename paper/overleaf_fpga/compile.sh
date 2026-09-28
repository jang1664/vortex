#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage:"
  echo "  $0 main.tex [out_dir] [--shell-escape]"
  echo
  echo "Examples:"
  echo "  $0 main.tex"
  echo "  $0 main.tex _outputs"
  echo "  $0 main.tex _outputs --shell-escape"
  exit 1
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
fi

MAIN="$1"
OUT_DIR="${2:-_outputs}"
SHELL_ESCAPE="${3:-}"

if [[ ! -f "$MAIN" ]]; then
  echo "ERROR: main tex file not found: $MAIN" >&2
  exit 1
fi

if [[ "$SHELL_ESCAPE" != "" && "$SHELL_ESCAPE" != "--shell-escape" ]]; then
  echo "ERROR: unknown option: $SHELL_ESCAPE" >&2
  usage
fi

if ! command -v latexmk >/dev/null 2>&1; then
  echo "ERROR: latexmk not found in PATH" >&2
  exit 1
fi

if ! command -v pdflatex >/dev/null 2>&1; then
  echo "ERROR: pdflatex not found in PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

MAIN_BASE="$(basename "$MAIN" .tex)"
LOG_FILE="$OUT_DIR/$MAIN_BASE.log"
BLG_FILE="$OUT_DIR/$MAIN_BASE.blg"
BBL_FILE="$OUT_DIR/$MAIN_BASE.bbl"

PDFLATEX_CMD="pdflatex -interaction=nonstopmode -file-line-error"

if [[ "$SHELL_ESCAPE" == "--shell-escape" ]]; then
  PDFLATEX_CMD="$PDFLATEX_CMD -shell-escape"
fi

echo "MAIN      : $MAIN"
echo "OUT_DIR   : $OUT_DIR"
echo "PDFLATEX  : $PDFLATEX_CMD"
echo

set +e
latexmk \
  -pdf \
  -outdir="$OUT_DIR" \
  -pdflatex="$PDFLATEX_CMD %O %S" \
  "$MAIN"

STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "ERROR: latexmk failed with status $STATUS"

  if [[ -f "$LOG_FILE" ]]; then
    echo
    echo "==== LaTeX errors from $LOG_FILE ===="
    grep -nE "^!|Emergency stop|Fatal error|Undefined control sequence|LaTeX Error|File .* not found" "$LOG_FILE" | head -80 || true

    echo
    echo "==== Undefined refs/citations ===="
    grep -nE "undefined|Citation .* undefined|Reference .* undefined" "$LOG_FILE" | head -80 || true
  else
    echo "No log file found: $LOG_FILE"
  fi

  if [[ -f "$BLG_FILE" ]]; then
    echo
    echo "==== BibTeX log from $BLG_FILE ===="
    cat "$BLG_FILE"
  else
    echo
    echo "No BibTeX log found: $BLG_FILE"
    echo "Check whether bibliography commands exist in the .aux file:"
    echo "  grep -n \"bibstyle\\|bibdata\\|citation\" \"$OUT_DIR/$MAIN_BASE.aux\""
    echo
    echo "You can also try manually:"
    echo "  bibtex \"$OUT_DIR/$MAIN_BASE\""
  fi

  exit "$STATUS"
fi

echo
echo "Build succeeded."

if [[ -f "$OUT_DIR/$MAIN_BASE.pdf" ]]; then
  echo "PDF: $OUT_DIR/$MAIN_BASE.pdf"
fi

if [[ ! -f "$BBL_FILE" ]]; then
  echo
  echo "Warning: .bbl file not found: $BBL_FILE"
  echo "If this document has citations, check:"
  echo "  grep -n \"bibstyle\\|bibdata\\|citation\" \"$OUT_DIR/$MAIN_BASE.aux\""
fi
#!/usr/bin/env bash
set -Eeuo pipefail

# Dump document-level metadata and metadata carried by embedded PDF objects.
# The report is intentionally verbose: anonymization leaks are often stored in
# imported vector figures rather than in the top-level PDF Info dictionary.

readonly PROGRAM_NAME="${0##*/}"

usage() {
  cat <<EOF
Usage: $PROGRAM_NAME [options] PDF

Inspect a PDF for author names and other identity-bearing metadata.

Options:
  -o, --output DIR       Write the report to DIR (must not already be nonempty).
  -n, --name TEXT        Search all reports for TEXT; may be repeated.
  -t, --timeout SECONDS  Limit each PDF parser/metadata command (default: 60).
  --fail-on-match    Exit with status 3 when a requested name is found.
  --no-images        Do not extract raster images with pdfimages.
  -h, --help             Show this help.

The default report directory is:
  ./_outputs/pdf-metadata-audit/<pdf-name>-<timestamp>-<pid>

Tools used:
  Required: pdfinfo, mutool, strings, timeout
  Optional: exiftool (richer EXIF/XMP output), pdfimages, pdfdetach, file

The timeout can also be set with PDF_METADATA_TIMEOUT_SECONDS. A command-line
--timeout value takes precedence.

Exit status:
  0  Scan completed (including matches unless --fail-on-match was used)
  1  Invalid input or scan failure
  2  Invalid command-line usage
  3  Requested name found with --fail-on-match

Security note: treat PDFs as untrusted input and run this in an appropriately
sandboxed environment. PDF parser vulnerabilities are outside this script's
control.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'ERROR: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

append_heading() {
  local heading="$1"
  local destination="$2"
  {
    printf '\n[%s]\n' "$heading"
    printf '%*s\n' "$((${#heading} + 2))" '' | tr ' ' '-'
  } >>"$destination"
}

run_pdf_tool() {
  timeout --foreground --signal=TERM --kill-after=5s "${parser_timeout_seconds}s" "$@"
}

tool_failure_reason() {
  case "$1" in
    124|137) printf 'timed out after %s seconds' "$parser_timeout_seconds" ;;
    *) printf 'failed with exit status %s' "$1" ;;
  esac
}

mark_scan_incomplete() {
  scan_incomplete=1
  coverage_issues+=("$1")
}

output_dir=""
extract_images=1
fail_on_match=0
parser_timeout_seconds="${PDF_METADATA_TIMEOUT_SECONDS:-60}"
declare -a requested_names=()
declare -a positional=()
declare -a coverage_issues=()
scan_incomplete=0

while (($# > 0)); do
  case "$1" in
    -o|--output)
      (($# >= 2)) || usage_error "$1 requires a directory"
      output_dir="$2"
      shift 2
      ;;
    -n|--name)
      (($# >= 2)) || usage_error "$1 requires text"
      [[ -n "$2" ]] || usage_error "$1 cannot be empty"
      requested_names+=("$2")
      shift 2
      ;;
    -t|--timeout)
      (($# >= 2)) || usage_error "$1 requires a positive integer"
      parser_timeout_seconds="$2"
      shift 2
      ;;
    --fail-on-match)
      fail_on_match=1
      shift
      ;;
    --no-images)
      extract_images=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

((${#positional[@]} == 1)) || usage_error "provide exactly one PDF path"
[[ "$parser_timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
  || usage_error "timeout must be a positive integer number of seconds"

readonly input_pdf_arg="${positional[0]}"
printf -v input_pdf_arg_quoted '%q' "$input_pdf_arg"
[[ -f "$input_pdf_arg" ]] || die "PDF not found: $input_pdf_arg_quoted"
[[ -r "$input_pdf_arg" ]] || die "PDF is not readable: $input_pdf_arg_quoted"

# An absolute path prevents filenames beginning with '-' from being interpreted
# as options by PDF utilities that do not consistently honor `--`.
if [[ "$input_pdf_arg" == /* ]]; then
  readonly input_pdf="$input_pdf_arg"
else
  readonly input_pdf="$PWD/$input_pdf_arg"
fi

require_command pdfinfo
require_command mutool
require_command strings
require_command timeout

pdf_magic="$(LC_ALL=C head -c 5 -- "$input_pdf" 2>/dev/null || true)"
printf -v input_pdf_quoted '%q' "$input_pdf"
[[ "$pdf_magic" == "%PDF-" ]] || die "file does not start with a PDF header: $input_pdf_quoted"

pdf_basename="${input_pdf##*/}"
pdf_stem="${pdf_basename%.*}"
if [[ -z "$output_dir" ]]; then
  output_dir="_outputs/pdf-metadata-audit/${pdf_stem}-$(date '+%Y%m%d-%H%M%S')-$$"
fi

# Normalize before passing the path to utilities such as find. In particular,
# a user-supplied relative directory beginning with '-' must not be parsed as
# a find expression or option.
if [[ "$output_dir" != /* ]]; then
  output_dir="$PWD/$output_dir"
fi
printf -v output_dir_quoted '%q' "$output_dir"

if [[ -d "$output_dir" ]] && find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "output directory is not empty; refusing to overwrite it: $output_dir_quoted"
fi

umask 077
mkdir -p "$output_dir"

readonly summary_report="$output_dir/00-summary.txt"
readonly document_report="$output_dir/01-document-metadata.txt"
readonly object_dump="$output_dir/02-pdf-object-dump.txt"
readonly xmp_stream_report="$output_dir/02a-xmp-metadata-streams.txt"
readonly suspect_report="$output_dir/03-suspect-metadata.txt"
readonly unicode_report="$output_dir/04-decoded-unicode-strings.txt"
readonly image_list_report="$output_dir/05-embedded-images-list.txt"
readonly image_metadata_report="$output_dir/06-embedded-images-metadata.txt"
readonly attachment_report="$output_dir/07-embedded-files-list.txt"
readonly name_match_report="$output_dir/08-requested-name-matches.txt"
readonly tool_report="$output_dir/09-tool-availability.txt"
readonly image_dir="$output_dir/extracted-images"

: >"$document_report"
: >"$xmp_stream_report"
: >"$suspect_report"
: >"$unicode_report"
: >"$image_list_report"
: >"$image_metadata_report"
: >"$attachment_report"
: >"$name_match_report"
: >"$tool_report"

for tool in pdfinfo mutool strings timeout exiftool pdfimages pdfdetach file iconv xxd; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%-12s %s\n' "$tool" "$(command -v "$tool")" >>"$tool_report"
  else
    printf '%-12s MISSING\n' "$tool" >>"$tool_report"
  fi
done

append_heading "pdfinfo" "$document_report"
if run_pdf_tool pdfinfo "$input_pdf" >>"$document_report" 2>&1; then
  :
else
  status=$?
  die "pdfinfo could not parse the PDF ($(tool_failure_reason "$status"))"
fi

append_heading "PDF trailer Info dictionary" "$document_report"
if run_pdf_tool mutool show "$input_pdf" trailer.Info >>"$document_report" 2>&1; then
  :
else
  status=$?
  reason="$(tool_failure_reason "$status")"
  printf 'ERROR: mutool trailer.Info %s.\n' "$reason" >>"$document_report"
  mark_scan_incomplete "PDF trailer Info dictionary scan $reason"
fi

append_heading "Catalog Metadata stream" "$document_report"
if run_pdf_tool mutool show "$input_pdf" trailer.Root.Metadata >>"$document_report" 2>&1; then
  :
else
  status=$?
  reason="$(tool_failure_reason "$status")"
  printf 'ERROR: mutool catalog metadata scan %s.\n' "$reason" >>"$document_report"
  mark_scan_incomplete "catalog Metadata stream scan $reason"
fi

append_heading "ExifTool document metadata" "$document_report"
if command -v exiftool >/dev/null 2>&1; then
  if run_pdf_tool exiftool -a -u -G1 -s -ee -- "$input_pdf" >>"$document_report" 2>&1; then
    :
  else
    status=$?
    reason="$(tool_failure_reason "$status")"
    printf 'ERROR: ExifTool document scan %s.\n' "$reason" >>"$document_report"
    mark_scan_incomplete "ExifTool document scan $reason"
  fi
else
  printf 'SKIPPED: exiftool is not installed. Install ExifTool for richer EXIF/XMP decoding.\n' \
    >>"$document_report"
fi

# `mutool show -g ... grep` prints each PDF object on a single line and exposes
# imported vector-figure Info dictionaries such as /PTEX.InfoDict. This is the
# most important scan for LaTeX papers: pdfinfo only reports the outer PDF.
if run_pdf_tool mutool show -g "$input_pdf" grep >"$object_dump" 2>&1; then
  :
else
  status=$?
  die "mutool object dump $(tool_failure_reason "$status")"
fi

# The one-line object listing exposes metadata object references but not their
# decoded stream bodies. Decode every object explicitly identified as PDF
# Metadata or XML so embedded XMP packets participate in all later searches.
declare -A xmp_object_refs=()
while read -r object_number generation_number; do
  [[ -n "$object_number" && -n "$generation_number" ]] || continue
  xmp_object_refs["$object_number $generation_number"]=1
done < <(
  LC_ALL=C sed -nE \
    's#^([0-9]+) ([0-9]+) obj .*\/(Type[[:space:]]*\/Metadata|Subtype[[:space:]]*\/XML)([^[:alnum:]_]|$).*#\1 \2#p' \
    "$object_dump" | sort -n -k1,1 -k2,2 -u
)

if ((${#xmp_object_refs[@]} == 0)); then
  printf 'No /Type /Metadata or /Subtype /XML objects found.\n' >"$xmp_stream_report"
else
  printf 'Decoded embedded XMP/XML metadata streams\n' >"$xmp_stream_report"
  printf '=========================================\n' >>"$xmp_stream_report"
  while read -r object_number generation_number; do
    append_heading "Object $object_number $generation_number R" "$xmp_stream_report"
    if run_pdf_tool mutool show "$input_pdf" "$object_number" >>"$xmp_stream_report" 2>&1; then
      :
    else
      status=$?
      reason="$(tool_failure_reason "$status")"
      printf 'ERROR: metadata object decode %s.\n' "$reason" >>"$xmp_stream_report"
      mark_scan_incomplete "XMP/XML object $object_number $generation_number R decode $reason"
    fi
  done < <(printf '%s\n' "${!xmp_object_refs[@]}" | sort -n -k1,1 -k2,2)
fi

metadata_pattern='Author|Creator|Producer|Title|Subject|Keywords|Owner|Artist|By-line|Byline|Copyright|Credit|Description|Comment|Company|Organization|PTEX[.]FileName|PTEX[.]InfoDict|Metadata|xmp:|dc:creator|photoshop:|iptc:|exif:'
{
  printf 'Potentially identity-bearing PDF object metadata\n'
  printf '===============================================\n'
  append_heading "Object listing matches" /dev/stdout
  LC_ALL=C grep -Ein "$metadata_pattern" "$object_dump" || true
  append_heading "Decoded XMP/XML stream matches" /dev/stdout
  LC_ALL=C grep -Ein "$metadata_pattern" "$xmp_stream_report" || true
} >"$suspect_report"

# PDF strings commonly store non-ASCII names as UTF-16 hex strings, e.g.
# <FEFF...>. Decode unique BOM-prefixed strings so grep can see the real name.
if command -v iconv >/dev/null 2>&1 && command -v xxd >/dev/null 2>&1; then
  {
    while IFS= read -r encoded; do
      [[ -n "$encoded" ]] || continue
      hex="${encoded#<}"
      hex="${hex%>}"
      payload="${hex:4}"
      if [[ "${hex^^}" == FEFF* ]]; then
        decoded="$(printf '%s' "$payload" | xxd -r -p 2>/dev/null | iconv -f UTF-16BE -t UTF-8 2>/dev/null || true)"
      else
        decoded="$(printf '%s' "$payload" | xxd -r -p 2>/dev/null | iconv -f UTF-16LE -t UTF-8 2>/dev/null || true)"
      fi
      [[ -n "$decoded" ]] && printf '%s\t%s\n' "$encoded" "$decoded"
    done < <(LC_ALL=C grep -Eho '<(FEFF|feff|FFFE|fffe)[0-9A-Fa-f]+>' \
      "$object_dump" "$xmp_stream_report" | sort -u)

    # MuPDF may render a PDF UTF-16 literal string with octal escapes instead
    # of hexadecimal syntax, for example (\376\377\000J\000o\000h\000n).
    while IFS= read -r encoded; do
      [[ -n "$encoded" ]] || continue
      literal="${encoded:1:${#encoded}-2}"
      bom="${literal:0:8}"
      payload="${literal:8}"
      printf_payload="${payload//\\/\\0}"
      if [[ "$bom" == '\376\377' ]]; then
        decoded="$(printf '%b' "$printf_payload" | iconv -f UTF-16BE -t UTF-8 2>/dev/null || true)"
      else
        decoded="$(printf '%b' "$printf_payload" | iconv -f UTF-16LE -t UTF-8 2>/dev/null || true)"
      fi
      [[ -n "$decoded" ]] && printf '%s\t%s\n' "$encoded" "$decoded"
    done < <(LC_ALL=C grep -Eho '\((\\376\\377|\\377\\376)(\\[0-7]{3}|[^()])*\)' \
      "$document_report" "$object_dump" "$xmp_stream_report" | sort -u)
  } >"$unicode_report"
  unicode_decoding_status="complete"
else
  printf 'SKIPPED: decoding requires iconv and xxd.\n' >"$unicode_report"
  unicode_decoding_status="unavailable (iconv and/or xxd missing)"
fi

append_heading "Decoded UTF-16 values used by suspect metadata" "$suspect_report"
declare -A suspect_encoded_values=()
while IFS= read -r encoded; do
  [[ -n "$encoded" ]] && suspect_encoded_values["$encoded"]=1
done < <(LC_ALL=C grep -Eo \
  '<(FEFF|feff|FFFE|fffe)[0-9A-Fa-f]+>|\((\\376\\377|\\377\\376)(\\[0-7]{3}|[^()])*\)' \
  "$suspect_report" | sort -u)

while IFS=$'\t' read -r encoded decoded; do
  [[ -n "$encoded" && -n "$decoded" ]] || continue
  if [[ -n "${suspect_encoded_values[$encoded]:-}" ]]; then
    printf '%s\t%s\n' "$encoded" "$decoded" >>"$suspect_report"
  fi
done <"$unicode_report"

if command -v pdfimages >/dev/null 2>&1; then
  image_scan_status="complete"
  if run_pdf_tool pdfimages -list "$input_pdf" >"$image_list_report" 2>&1; then
    :
  else
    status=$?
    reason="$(tool_failure_reason "$status")"
    printf 'ERROR: pdfimages list %s.\n' "$reason" >>"$image_list_report"
    mark_scan_incomplete "embedded image listing $reason"
    image_scan_status="incomplete"
  fi
  if ((extract_images)); then
    mkdir -p "$image_dir"
    if run_pdf_tool pdfimages -all -p "$input_pdf" "$image_dir/image" >>"$image_list_report" 2>&1; then
      :
    else
      status=$?
      reason="$(tool_failure_reason "$status")"
      printf 'ERROR: pdfimages extraction %s.\n' "$reason" >>"$image_list_report"
      mark_scan_incomplete "embedded image extraction $reason"
      image_scan_status="incomplete"
    fi

    while IFS= read -r -d '' image_file; do
      append_heading "${image_file#"$output_dir/"}" "$image_metadata_report"
      if command -v file >/dev/null 2>&1; then
        if run_pdf_tool file -- "$image_file" >>"$image_metadata_report" 2>&1; then
          :
        else
          status=$?
          reason="$(tool_failure_reason "$status")"
          printf 'ERROR: file metadata inspection %s.\n' "$reason" >>"$image_metadata_report"
          mark_scan_incomplete "image file-type inspection $reason"
        fi
      fi
      if command -v exiftool >/dev/null 2>&1; then
        if run_pdf_tool exiftool -a -u -G1 -s -ee -- "$image_file" \
          >>"$image_metadata_report" 2>&1; then
          :
        else
          status=$?
          reason="$(tool_failure_reason "$status")"
          printf 'ERROR: ExifTool image scan %s.\n' "$reason" >>"$image_metadata_report"
          mark_scan_incomplete "ExifTool image scan $reason"
        fi
      else
        LC_ALL=C run_pdf_tool strings -a -n 4 -- "$image_file" \
          | grep -Ei "$metadata_pattern" \
          | head -n 200 >>"$image_metadata_report" || true
      fi
    done < <(find "$image_dir" -type f -print0 | sort -z)
  else
    printf 'Raster extraction disabled with --no-images.\n' >>"$image_metadata_report"
    image_scan_status="disabled by request"
  fi
else
  printf 'SKIPPED: pdfimages is not installed.\n' >"$image_list_report"
  printf 'SKIPPED: pdfimages is not installed.\n' >"$image_metadata_report"
  image_scan_status="skipped (pdfimages unavailable)"
fi

if command -v pdfdetach >/dev/null 2>&1; then
  if run_pdf_tool pdfdetach -list "$input_pdf" >"$attachment_report" 2>&1; then
    :
  else
    status=$?
    reason="$(tool_failure_reason "$status")"
    printf 'ERROR: pdfdetach attachment scan %s.\n' "$reason" >>"$attachment_report"
    mark_scan_incomplete "embedded-file listing $reason"
  fi
else
  printf 'SKIPPED: pdfdetach is not installed.\n' >"$attachment_report"
fi

# Search only generated reports, never extracted binary payloads. Fixed-string
# matching avoids treating names containing regex characters as expressions.
match_count=0
for requested_name in "${requested_names[@]}"; do
  printf '[name] %s\n' "$requested_name" >>"$name_match_report"
  current_count="$({
    grep -iFn -- "$requested_name" \
      "$document_report" "$object_dump" "$suspect_report" "$unicode_report" \
      "$xmp_stream_report" "$image_list_report" "$image_metadata_report" \
      "$attachment_report" 2>/dev/null || true
  } | tee -a "$name_match_report" | wc -l | tr -d ' ')"
  if ((current_count > 0)); then
    match_count=$((match_count + current_count))
  else
    printf 'NO MATCH\n' >>"$name_match_report"
  fi
  printf '\n' >>"$name_match_report"
done

if ((${#requested_names[@]} == 0)); then
  printf 'No --name values supplied. Review 03-suspect-metadata.txt and 04-decoded-unicode-strings.txt manually.\n' \
    >"$name_match_report"
fi

image_count=0
if [[ -d "$image_dir" ]]; then
  image_count="$(find "$image_dir" -type f -print | wc -l | tr -d ' ')"
fi

unicode_count="$(LC_ALL=C awk -F '\t' 'NF >= 2 && $1 != "" && $2 != "" { count++ } END { print count + 0 }' \
  "$unicode_report")"
suspect_count="$(grep -Ec '^[0-9]+:' "$suspect_report" || true)"

if ((scan_incomplete)); then
  scan_completeness="INCOMPLETE"
else
  scan_completeness="complete"
fi

{
  printf 'PDF metadata audit summary\n'
  printf '==========================\n'
  printf 'Input PDF:             %s\n' "$input_pdf"
  printf 'Input SHA-256:         '
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$input_pdf" | awk '{print $1}'
  else
    printf 'unavailable\n'
  fi
  printf 'Report directory:      %s\n' "$output_dir"
  printf 'Parser timeout:        %s seconds per command\n' "$parser_timeout_seconds"
  printf 'Scan completeness:     %s\n' "$scan_completeness"
  printf 'Image scan:            %s\n' "$image_scan_status"
  printf 'Suspect object lines:  %s\n' "$suspect_count"
  printf 'Decoded UTF strings:   %s\n' "$unicode_count"
  printf 'UTF decoding coverage: %s\n' "$unicode_decoding_status"
  printf 'Extracted raster files:%s\n' " $image_count"
  printf 'Requested-name matches:%s\n' " $match_count"
  if ((scan_incomplete)); then
    printf '\nCoverage issues:\n'
    printf -- '- %s\n' "${coverage_issues[@]}"
  fi
  printf '\nInterpretation:\n'
  printf -- '- A zero requested-name match does not prove anonymity.\n'
  printf -- '- Inspect 03-suspect-metadata.txt for imported vector-figure Info dictionaries.\n'
  printf -- '- Inspect 04-decoded-unicode-strings.txt for names hidden as UTF-16 PDF strings.\n'
  printf -- '- pdfimages covers raster XObjects; vector figure metadata is primarily in 02/03.\n'
  printf -- '- Creator/Producer fields often name software rather than a person.\n'
} >"$summary_report"

printf 'Report written to: %q\n' "$output_dir"
printf 'Requested-name matches: %s\n' "$match_count"
printf 'Review first: %q\n' "$suspect_report"
printf 'Decoded strings: %q\n' "$unicode_report"

if ((scan_incomplete)); then
  exit 1
fi

if ((fail_on_match && match_count > 0)); then
  exit 3
fi

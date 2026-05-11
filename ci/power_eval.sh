#!/bin/bash
#SBATCH --job-name=vortex_pwr
#SBATCH --gres=fpga:u55c:1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=2:00:00
#SBATCH --output=%x_%j.log

# power_eval.sh
#   Run fpint_gemm_ffn_hw on the U55C FPGA while sampling board power via
#   xrt-smi, then report per-shape: avg latency, idle/run/peak power, and
#   idle-subtracted energy per iteration.
#
#   Usage:
#     sbatch build/ci/power_eval.sh                 # full sweep, default iters
#     ITERS=40 sbatch build/ci/power_eval.sh        # more iterations
#     SHAPES="medium" ./build/ci/power_eval.sh      # run a single shape only

set -u

FPGA_BIN_DIR=${FPGA_BIN_DIR:-/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint_noDcache_L2cache_c8c5d0d4f3/bin}
PLATFORM=${PLATFORM:-xilinx_u55c_gen3x16_xdma_3_202210_1}
CONFIGS=${CONFIGS:--DNUM_THREADS=8}
ITERS=${ITERS:-3}                  # outer loop (blackbox.sh invocations)
INTERVAL=${INTERVAL:-0.1}          # power sampling period (seconds)
IDLE_SAMPLES=${IDLE_SAMPLES:-25}
SHAPES=${SHAPES:-small medium llama_ffn}
# POWER_MODE=1 → app skips host-side reference + verification (fast).
# Set to 0 if you want correctness-checked runs (much slower).
POWER_MODE=${POWER_MODE:-1}
OUTDIR=${OUTDIR:-power_eval_$(date +%Y%m%d_%H%M%S)}
XRT_SMI=${XRT_SMI:-/opt/xilinx/xrt/bin/xrt-smi}

mkdir -p "$OUTDIR"
echo "Output dir: $OUTDIR"

SUMMARY="$OUTDIR/summary.log"
{
  echo "================================================================"
  echo "power_eval.sh run started at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  FPGA_BIN_DIR=$FPGA_BIN_DIR"
  echo "  PLATFORM=$PLATFORM"
  echo "  CONFIGS=$CONFIGS"
  echo "  ITERS=$ITERS  INTERVAL=${INTERVAL}s  POWER_MODE=$POWER_MODE"
  echo "  SHAPES='$SHAPES'"
  echo "================================================================"
} | tee "$SUMMARY"

# xrt-smi -f JSON only writes to a file via -o; we use a per-process scratch file.
JSON_TMP=$(mktemp -t xrt_elec.XXXXXX.json)
trap 'rm -f "$JSON_TMP"' EXIT

# Auto-detect device BDF (device_id field) by writing the electrical report
# to JSON and parsing it.  Falls back to no -d flag if detection fails.
$XRT_SMI --batch --force examine -r electrical -f JSON -o "$JSON_TMP" >/dev/null 2>&1
DEV=$(python3 -c '
import json
try:
    d = json.load(open("'"$JSON_TMP"'"))
    print(d["devices"][0]["device_id"])
except Exception:
    pass
' 2>/dev/null)
echo "FPGA device BDF: ${DEV:-(auto)}"

sample_power () {
  $XRT_SMI --batch --force examine ${DEV:+-d $DEV} -r electrical -f JSON -o "$JSON_TMP" \
    >/dev/null 2>&1
  python3 -c '
import json
try:
    d = json.load(open("'"$JSON_TMP"'"))
    el = d["devices"][0].get("electrical", {})
    p = el.get("power_consumption_watts")
    print(p if p is not None else "nan")
except Exception:
    print("nan")
' 2>/dev/null
}

shape_args () {
  # Per-shape REPS sized for kernel duty ~85% over the run window (matching the
  # fpint_tcu reference runs). Sizing rule: r·t ≈ 5.67·s where t = per-rep kernel
  # latency and s = per-iter host setup (~10–22 s; XRT init, data-gen, DRAM upload).
  # -p enables power-mode in the app (skips host-side verification).
  local pflag=""
  [ "$POWER_MODE" = "1" ] && pflag=" -p"
  case "$1" in
    small)     echo "-m 512  -n 512  -k 512  -q 32 -t 0 -d 0 -r 8000${pflag}" ;;
    medium)    echo "-m 1024 -n 1024 -k 1024 -q 32 -t 0 -d 0 -r 1000${pflag}" ;;
    llama_ffn) echo "-m 512  -n 4096 -k 4096 -q 32 -t 0 -d 0 -r 100${pflag}" ;;
    # Llama2-7B mappings (prefill seq=512 / 2K, decode seq=1)
    qkv_512)        echo "-m 512  -n 4096  -k 4096  -q 32 -t 0 -d 0 -r 400${pflag}" ;;
    qkv_2k)         echo "-m 2048 -n 4096  -k 4096  -q 32 -t 0 -d 0 -r 150${pflag}" ;;
    gate_up_512)    echo "-m 512  -n 11008 -k 4096  -q 32 -t 0 -d 0 -r 200${pflag}" ;;
    gate_up_2k)     echo "-m 2048 -n 11008 -k 4096  -q 32 -t 0 -d 0 -r 80${pflag}" ;;
    down_512)       echo "-m 512  -n 4096  -k 11008 -q 32 -t 0 -d 0 -r 200${pflag}" ;;
    down_2k)        echo "-m 2048 -n 4096  -k 11008 -q 32 -t 0 -d 0 -r 80${pflag}" ;;
    decode_qkv)     echo "-m 1    -n 4096  -k 4096  -q 32 -t 0 -d 0 -r 5000${pflag}" ;;
    decode_gate_up) echo "-m 1    -n 11008 -k 4096  -q 32 -t 0 -d 0 -r 2000${pflag}" ;;
    decode_down)    echo "-m 1    -n 4096  -k 11008 -q 32 -t 0 -d 0 -r 2000${pflag}" ;;
    *)         echo "" ;;
  esac
}

run_one () {
  local TAG=$1
  local ARGS
  ARGS=$(shape_args "$TAG")
  if [ -z "$ARGS" ]; then
    echo "[skip] unknown shape: $TAG"; return
  fi

  local OUT=$OUTDIR/power_${TAG}.csv
  local LOGD=$OUTDIR/${TAG}_logs
  mkdir -p "$LOGD"
  {
    echo "================================================================"
    echo "[$TAG] args: $ARGS  iters=$ITERS  interval=${INTERVAL}s"
    echo "================================================================"
  } | tee -a "$SUMMARY"

  echo "timestamp_s,power_w,phase" > "$OUT"

  # idle baseline
  for _ in $(seq 1 $IDLE_SAMPLES); do
    P=$(sample_power)
    echo "$(date +%s.%N),${P:-nan},idle" >> "$OUT"
    sleep "$INTERVAL"
  done

  # run-phase sampler in background
  (
    while true; do
      P=$(sample_power)
      echo "$(date +%s.%N),${P:-nan},run" >> "$OUT"
      sleep "$INTERVAL"
    done
  ) &
  local SAMPLER=$!

  local FAIL=0
  local T0 T1
  T0=$(date +%s.%N)
  for i in $(seq 1 $ITERS); do
    FPGA_BIN_DIR=$FPGA_BIN_DIR TARGET=hw PLATFORM=$PLATFORM \
      CONFIGS="$CONFIGS" \
      ./ci/blackbox.sh --driver=xrt --app=fpint_gemm_ffn_hw --args="$ARGS" \
      > "$LOGD/iter_${i}.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      FAIL=$((FAIL+1))
      echo "  iter $i FAILED (rc=$rc); tail of log:"
      tail -10 "$LOGD/iter_${i}.log" | sed 's/^/    /'
    fi
  done
  T1=$(date +%s.%N)

  kill "$SAMPLER" 2>/dev/null
  wait "$SAMPLER" 2>/dev/null

  python3 - "$OUT" "$T0" "$T1" "$ITERS" "$TAG" "$FAIL" "$LOGD" <<'PY' | tee -a "$OUTDIR/summary.log"
import csv, glob, os, re, sys
path, t0, t1, iters, tag, fail, logd = sys.argv[1:]
t0 = float(t0); t1 = float(t1); iters = int(iters); fail = int(fail)
wall = t1 - t0
CLK_HZ = 100e6

idle, run = [], []
with open(path) as f:
    for r in csv.DictReader(f):
        try:
            v = float(r["power_w"])
        except (TypeError, ValueError):
            continue
        (idle if r["phase"] == "idle" else run).append(v)

def stat(xs):
    if not xs: return float("nan"), float("nan"), float("nan")
    return sum(xs)/len(xs), max(xs), min(xs)

# Aggregate PERF cycles across all iter logs.  The Vortex runtime emits one
# PERF line per process (representing per-rep cycles, not the cumulative);
# we parse REPS from each log's banner and extrapolate the total kernel time.
per_rep_cycles_sum = 0   # sum of (per-rep cycles) over all iter logs (=cycles_per_rep × n_logs)
n_perf_logs = 0          # number of iter logs that produced a PERF line
total_reps  = 0          # total kernel reps actually executed (REPS_per_log × n_logs)
for log_path in sorted(glob.glob(os.path.join(logd, "iter_*.log"))):
    reps_in_log = 1
    cycles_in_log = None
    with open(log_path) as f:
        for line in f:
            m = re.search(r"REPS=(\d+)", line)
            if m: reps_in_log = int(m.group(1))
            m = re.search(r"PERF:.*cycles=(\d+)", line)
            if m: cycles_in_log = int(m.group(1))
    if cycles_in_log is not None:
        per_rep_cycles_sum += cycles_in_log
        n_perf_logs        += 1
        total_reps         += reps_in_log

P_idle_avg, _, _           = stat(idle)
P_run_avg, P_run_max, _    = stat(run)
dP_avg  = P_run_avg - P_idle_avg
dP_peak = P_run_max - P_idle_avg

kernel_lat_s   = (per_rep_cycles_sum / n_perf_logs / CLK_HZ) if n_perf_logs else float("nan")
kernel_total_s = kernel_lat_s * total_reps if n_perf_logs else 0.0
duty = (kernel_total_s / wall * 100) if wall > 0 else float("nan")

E_total = P_run_avg * wall
E_kernel_avg  = dP_avg  * kernel_total_s   # idle-subtracted kernel energy (run-window-avg power)
E_kernel_peak = dP_peak * kernel_total_s   # using peak ΔP (upper bound)

print(f"[{tag}] iters={iters} ({fail} failed)  total_reps={total_reps} (over {n_perf_logs} logs)  wall={wall:.2f}s")
print(f"        kernel-only latency : {kernel_lat_s*1e3:.3f} ms/rep   (kernel total {kernel_total_s:.2f}s, duty {duty:.1f}%)")
print(f"        P_idle={P_idle_avg:6.3f} W  P_run_avg={P_run_avg:6.3f} W  P_run_max={P_run_max:6.3f} W")
print(f"        ΔP_avg={dP_avg:+.3f} W   ΔP_peak={dP_peak:+.3f} W")
print(f"        E_kernel(ΔP_avg×t_kernel) = {E_kernel_avg:6.3f} J  → per-rep {E_kernel_avg/max(total_reps,1)*1e3:.2f} mJ")
print(f"        E_kernel(ΔP_peak×t_kernel)= {E_kernel_peak:6.3f} J  → per-rep {E_kernel_peak/max(total_reps,1)*1e3:.2f} mJ")
PY
}

for s in $SHAPES; do
  run_one "$s"
done

echo "================================================================"
echo "Done. CSVs and per-iter logs under: $OUTDIR"

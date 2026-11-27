"""Check the Qwen3 KIVI layouts against the dense kernel on one allocated U55C."""
import argparse
import csv
import os
from pathlib import Path
import re
import statistics
import subprocess


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new log and CSV directory")
    args = parser.parse_args()
    wrapper = Path("ci/run_black.sh").resolve()
    if not Path("config.mk").is_file() or not wrapper.is_file():
        parser.error("run from a configured build directory")
    if not os.environ.get("SLURM_JOB_ID"):
        parser.error("allocate one U55C for the whole comparison")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    board = None
    alias = "improve_th16_tcol16_m16_t8_bigmem_all_bram_spread_v4_nodsp_fix_sub_norm"
    fused_app = "kivi_quant_layout_fused"

    def measure(name, app, options, golden=False):
        nonlocal board
        log = out / (name + ".log")
        cmd = [str(wrapper), "hw", "--fpga-bin", alias, "--app", app]
        if not golden:
            cmd.append("--bench")
            sample_csv = log.with_suffix(".csv")
            options += f" --warmup=1 --iterations=3 --csv --output={sample_csv}"
        with log.open("w") as stream:
            subprocess.run(cmd + ["--args", options], stdout=stream,
                           stderr=subprocess.STDOUT, check=True)
        text = log.read_text()
        devices = set(re.findall(r"\[VXDRV\] XRT device:.*?bdf=([^,]+)", text))
        if len(devices) != 1 or board is not None and devices != {board}:
            raise RuntimeError(f"{log}: unexpected XRT board {devices}")
        board, = devices
        if golden:
            if "PASSED!" not in text:
                raise RuntimeError(f"{log}: missing golden check")
            return
        perf = re.findall(r"\[bench-perf\] iteration=(\d+)/3 begin\s+"
                          r"PERF: instrs=\d+, cycles=(\d+),[^\n]*\n"
                          r"\[bench-perf\] iteration=\1/3 end", text)
        if [i for i, _ in perf] != ["1", "2", "3"]:
            raise RuntimeError(f"{log}: missing device-cycle samples")
        return statistics.median(int(cycles) for _, cycles in perf)

    def compare(name, dense, fused):
        measure(name + "_gold", fused_app, fused, golden=True)
        a = measure(name + "_dense", "kv_cache_quant_w4a16", dense)
        b = measure(name + "_fused", fused_app, fused)
        writer.writerow([name, board, a, b, b/a])
        results.flush()
        print(f"{name}: {b}/{a} = {b/a:.3f}", flush=True)
        return b <= 1.5*a

    passed = True
    with (out / "cycles.csv").open("w", newline="") as results:
        writer = csv.writer(results)
        writer.writerow(["case", "board", "dense_cycles", "fused_cycles", "ratio"])
        for length in range(1, 33):
            base = f"-k {length} -n 128 -q 32 -d 0 -t 1 --quant-mode kivi_int_zp"
            fused = (f"{base} --source-transposed --gemm-qdir 1 --cache-update append"
                     f" --cache-capacity 65536 --cache-position {1023+length}")
            passed &= compare(f"decode_K_{length}", base + " --kivi-update-key", fused)
        base = "-k 1 -n 128 -q 32 -d 1 -t 0 --quant-mode kivi_int_zp"
        for rows in (8, 64):
            fused = (f"{base} --gemm-qdir 1 --cache-update append --cache-capacity 65536"
                     f" --cache-position 1024 --layout-from gemm_c_tiled"
                     f" --source-total-k {rows} --source-total-n 1024")
            passed &= compare(f"decode_V_{rows}", base, fused)
        for length in (1024, 2048, 4096, 8192, 16384, 32768):
            base = f"-k {length} -n 128 -q 32 --quant-mode kivi_int_zp"
            key = base + " -d 0 -t 1"
            value = base + " -d 1 -t 0"
            passed &= compare(f"prefill_K_{length}", key, key + " --source-transposed --gemm-qdir 1")
            passed &= compare(f"prefill_V_{length}", value, value +
                              " --layout-from gemm_c_tiled --source-total-n 1024 --gemm-qdir 1")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(run())

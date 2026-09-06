#!/usr/bin/env python3
"""Fresh-build directed transport regressions; never cleans prior artifacts."""
import concurrent.futures
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
PROFILES = [
    ("select_release", "tmem_dma_bank_select", "improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh", 64, 8, 65536, 1),
    ("select_debug", "tmem_dma_bank_select", "improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh", 64, 8, 65536, 0),
    ("pair_deep", "tmem_dma_write_ack_filter", "improve_th16_tcol16_m16_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem8.sh", 32, 8, 65536, 1),
    ("pair_legacy", "tmem_dma_write_ack_filter", "improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh", 32, 16, 32768, 1),
    ("direct_legacy", "tmem_dma_write_ack_filter", "improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh", 64, 8, 65536, 1),
]

def run(profile):
    name, test, config, width, banks, capacity, ndebug = profile
    build = ROOT / ("build_dma4_units_iter1_" + name)
    artifact = TASK / "units_iter1" / name
    build.mkdir(exist_ok=False)
    artifact.mkdir(parents=True, exist_ok=False)
    sourced = subprocess.check_output(["bash", "-c", 'source "$1"; env -0', "bash", str(ROOT / "configs" / config)])
    env = dict(item.split("=", 1) for item in sourced.decode().split("\0") if "=" in item)
    env.update(CC="/usr/bin/gcc", CXX="/usr/bin/g++", PATH="/usr/bin:" + env["PATH"],
               TMEM_BYTES=str(width), TMEM_BANKS=str(banks), TMEM_BANK_SIZE=str(capacity), NDEBUG=str(ndebug))
    (artifact / "manifest.json").write_text(json.dumps({"profile": profile, "CONFIGS": env["CONFIGS"], "build": str(build)}, indent=2))
    with (artifact / "configure.log").open("w") as log:
        subprocess.run(["../configure", "--xlen=64", "--tooldir=/opt/vortex", "--prefix=" + env["HOME"] + "/tools/vortex"], cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    test_path = build / "hw/unittest" / test
    command = ["python3", str(ROOT / "tools/verify_rtl.py"), "unittest", "--path", str(test_path), "--sim", "vcs", "--timeout", "60"]
    print("START " + name, flush=True)
    result = subprocess.run(command, cwd=build, env=env, capture_output=True, text=True)
    (artifact / "verify.json").write_text(result.stdout)
    (artifact / "verify.stderr").write_text(result.stderr)
    errors = []
    for log in (test_path / "logs").glob("*.log"):
        for index, line in enumerate(log.open(errors="replace"), 1):
            if re.search(r"(?:Error:|Fatal:|Error-\[)", line, re.I):
                errors.append({"file": str(log), "line": index, "text": line.rstrip()})
    verified = json.loads(result.stdout)
    summary = {"name": name, "returncode": result.returncode, "verify": verified, "strict_errors": errors,
               "pass": result.returncode == 0 and verified["status"] == "pass" and not errors}
    (artifact / "result.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)
    return summary

if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(run, PROFILES))
    (TASK / "units_iter1" / "results.json").write_text(json.dumps(results, indent=2))
    raise SystemExit(0 if all(item["pass"] for item in results) else 1)

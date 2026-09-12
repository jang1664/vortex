#!/usr/bin/env python3
import hashlib, json, os, shlex, shutil, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BUILD = ROOT / "build_fpint_latency_improve_vcs"
OUT = TASK / "p4-verification/improve-units-iteration1"
OUT.mkdir(parents=True, exist_ok=False)
assert (BUILD / "config.mk").exists()
for suite in ("microtile_readiness_scheduler", "tmem_wide_read_switch", "tmem_read_req_reservation", "tensor_mem_bank"):
    directory = BUILD / "hw/unittest" / suite
    directory.mkdir(parents=True, exist_ok=True)
    for source in (ROOT / "hw/unittest" / suite).glob("*mk"):
        shutil.copy2(source, directory / source.name)
    if (ROOT / "hw/unittest" / suite / "Makefile").exists():
        shutil.copy2(ROOT / "hw/unittest" / suite / "Makefile", directory / "Makefile")
    params = "-B"
    if suite == "microtile_readiness_scheduler":
        defines = "SIMULATION NDEBUG XLEN_64 " + " ".join(x[2:] for x in shlex.split(os.environ["CONFIGS"]) if x.startswith("-D"))
        params += " " + shlex.quote("DEFINES_=" + defines)
    target = OUT / suite
    target.mkdir()
    cmd = ["python3", str(ROOT / "tools/verify_rtl.py"), "unittest", "--path", str(directory), "--sim", "vcs", "--params=" + params]
    result = subprocess.run(cmd, cwd=BUILD, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (target / "result.json").write_text(result.stdout)
    (target / "command.json").write_text(json.dumps(cmd, indent=2)+"\n")
    for log in ("compile.log", "sim.log"):
        src = directory / "logs" / log
        if src.exists(): shutil.copy2(src, target / log)
    print(suite, result.returncode, result.stdout[-700:], flush=True)
    if result.returncode: break

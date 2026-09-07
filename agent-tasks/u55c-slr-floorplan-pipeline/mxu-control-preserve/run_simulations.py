#!/usr/bin/env python3
"""Run fresh TH32/t4+t8 W4 simulation preflight, never synthesis or cleanup.

Build directories must already be configured. The two profiles run in parallel;
cases within a profile run serially. Existing raw evidence is never overwritten.
"""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess


TASK = Path(__file__).resolve().parent
ROOT = TASK.parents[2]
PARENT = TASK.parent
MANIFEST = TASK / "simulation-manifest.json"
SUFFIXES = {".sv", ".v", ".vh", ".svh"}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def rtl_sources():
    return {str(p.relative_to(ROOT)): sha(p)
            for p in sorted((ROOT / "hw/rtl").rglob("*"))
            if p.is_file() and p.suffix in SUFFIXES}


def config_flags(config):
    return subprocess.check_output(
        ["bash", "-c", 'source "$1"; printf "%s" "$CONFIGS"',
         "simulation-config", str(ROOT / config)], text=True, cwd=ROOT)


def run_profile(profile):
    build = ROOT / f"build_mxu_preserve_{profile}"
    # Profile spelling is th32_t4, while source naming includes the MXU geometry.
    config = f"configs/improve_th32_tcol32_m32_t{profile[-1]}_bigmem.sh"
    if not (build / "config.mk").exists():
        raise RuntimeError(f"Unconfigured build: {build}")
    record = {"profile": profile, "status": "running", "config": config,
              "final_config_sha256": sha(ROOT / config),
              "base_configs": config_flags(config),
              "build": str(build.relative_to(ROOT)), "suites": []}
    env = dict(os.environ, SIMLIB_DIR=str(ROOT / "build/vcs_simlib"),
               CC="/usr/bin/gcc", CXX="/usr/bin/g++")
    for runner, folder in ((PARENT / "measure_gemm.py", "evidence"),
                           (PARENT / "four-config-pnr/measure_overlap.py", "overlap-evidence")):
        out = build / folder
        command = ["python3", str(runner), "--build", str(build), "--out", str(out),
                   "--config", config, "--repeat", "1", "--timeout", "300"]
        with (build / f"{folder}-runner.log").open("x") as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                    stderr=subprocess.STDOUT)
        summary_path = out / "summary.json"
        summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
        runs = summary.get("runs", [])
        record["suites"].append({"summary": str(summary_path.relative_to(ROOT)),
                                 "summary_sha256": sha(summary_path) if summary_path.exists() else None,
                                 "returncode": result.returncode,
                                 "config_sha256_at_start": summary.get("config_sha256"),
                                 "extra_configs": summary.get("extra_configs"), "runs": runs})
        expected = 4 if folder == "evidence" else 3
        if result.returncode != 0 or len(runs) != expected or any(
                r.get("status") != "pass" or not r.get("response_slot_metrics")
                or not all(s.get("complete_and_balanced") for s in r["response_slot_metrics"].values())
                for r in runs):
            record["status"] = "fail"
            return record
        print(f"{profile} {folder}: {len(runs)} PASS", flush=True)
    record["status"] = "pass" if sha(ROOT / config) == record["final_config_sha256"] else "source_changed"
    return record


def main():
    if MANIFEST.exists():
        raise RuntimeError("Preserve the existing simulation manifest; use a new iteration")
    sources = rtl_sources()
    manifest = {"status": "running", "started_at": datetime.now().isoformat(timespec="seconds"),
                "source_root": str(ROOT),
                "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "rtl_sources": sources, "rtl_file_count": len(sources),
                "rtl_manifest_sha256": hashlib.sha256("".join(
                    f"{h}  {p}\n" for p, h in sources.items()).encode()).hexdigest(),
                "blackbox_mode": "xrt-vcs-sim", "app": "fpint_gemm_ffn_hw",
                "simlib_dir": str(ROOT / "build/vcs_simlib"), "repeat_per_case": 1,
                "timeout_seconds": 300, "profiles": []}
    MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            manifest["profiles"] = list(pool.map(run_profile, ("th32_t4", "th32_t8")))
        manifest["rtl_unchanged_through_simulation"] = rtl_sources() == sources
        manifest["total_functional_runs"] = sum(len(s["runs"]) for p in manifest["profiles"] for s in p["suites"])
        manifest["status"] = "functional_pass_directed_pending" if (
            manifest["rtl_unchanged_through_simulation"] and manifest["total_functional_runs"] == 14
            and all(p["status"] == "pass" for p in manifest["profiles"])) else "fail"
    except Exception as error:
        manifest["status"] = "fail"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["completed_at"] = datetime.now().isoformat(timespec="seconds")
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Simulation manifest: {manifest['status']}", flush=True)
    return 0 if manifest["status"] == "functional_pass_directed_pending" else 1


if __name__ == "__main__":
    raise SystemExit(main())

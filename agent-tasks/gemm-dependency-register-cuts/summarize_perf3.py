#!/usr/bin/env python3
"""Summarize exact GEMM counter deltas without mixing host cycle metrics."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def main():
    manifests = {variant: json.loads((ROOT / f"build_gemm_depcuts_{variant}" /
                 "perf3-evidence/manifest.json").read_text()) for variant in ("original", "cuts0", "cuts1")}
    summary = {"source_snapshot_equal_current_off_on": manifests["cuts0"]["rtl_files"] == manifests["cuts1"]["rtl_files"],
               "config_hashes": {v: m["config_sha256"] for v, m in manifests.items()},
               "source_snapshot_difference_original_current": [
                   p for p, h in manifests["original"]["rtl_files"].items()
                   if manifests["cuts0"]["rtl_files"].get(p) != h],
               "cases": [], "validation": {}}
    for variant, manifest in manifests.items():
        if manifest["status"] != "pass" or len(manifest["runs"]) != 14 or any(
                r["status"] != "pass" for r in manifest["runs"]):
            raise RuntimeError(f"Incomplete or failed suite: {variant}")
    for case in dict.fromkeys(r["case"] for r in manifests["cuts0"]["runs"]):
        values = {variant: [r["gemm_perf"][0]["total_cycles"] for r in manifest["runs"] if r["case"] == case]
                  for variant, manifest in manifests.items()}
        if any(len(v) != 2 or v[0] != v[1] for v in values.values()):
            raise RuntimeError(f"Non-reproducible samples need explicit treatment: {case} {values}")
        off, on = values["cuts0"][0], values["cuts1"][0]
        summary["cases"].append({"case": case, "samples": values, "delta_cycles": on - off,
                                  "delta_percent": round(100 * (on - off) / off, 4),
                                  "current_off_equals_original": values["original"] == values["cuts0"]})
    for artifact in ("kernel.vxbin", "fpint_gemm_ffn_hw"):
        hashes = {r["application_artifacts_sha256"][artifact]
                  for variant in ("cuts0", "cuts1") for r in manifests[variant]["runs"]}
        summary["validation"][artifact] = {"unique_hashes": sorted(hashes), "identical": len(hashes) == 1}
    print(json.dumps(summary, indent=2))
    (Path(__file__).resolve().parent / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

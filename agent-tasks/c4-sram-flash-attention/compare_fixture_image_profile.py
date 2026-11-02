#!/usr/bin/env python3
"""Read-only metadata gate; does not certify loaded FPGA, RTL ABI or tensor bytes."""
import argparse
import dataclasses
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
from vortex_binmgr import parse_config_stamp, read_manifest
from tvm.support.vortex import load_vortex_accelerator_profile, parse_vortex_configs
from tvm.relax.backend.vortex.layout import ImproveProfile

CASES = [f"{m}_decode_p{p}_c{c}" for m in ("llama3-8b", "llama2-7b")
         for p, c in ((16, 32), (128, 160), (128, 256))]
CASES += [f"llama3-8b_prefill{s}" for s in (16, 128, 144)]


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def profile(path):
    p = load_vortex_accelerator_profile(path)
    layout = ImproveProfile.from_target(p.target)
    layout.validate()
    attrs = {str(k): str(v) for k, v in p.target.attrs.items()
             if str(k) not in ("vortex_accelerator_profile_fingerprint",
                               "vortex_accelerator_profile_configs")}
    return p, dataclasses.asdict(layout), attrs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--new-manifest", type=Path)
    parser.add_argument("--new-config-stamp", type=Path)
    args = parser.parse_args()
    if bool(args.new_manifest) != bool(args.new_config_stamp):
        parser.error("new manifest and actual build config stamp are required together")
    records, errors = [], []
    baseline = None
    for case in CASES:
        root = args.fixtures / case
        meta = json.loads((root / "fixture.json").read_text())
        archive = json.loads((root / "parameters/manifest.json").read_text())
        old, layout, attrs = profile(meta["manifest"])
        if meta["profile_fingerprint"] != old.fingerprint:
            errors.append(f"{case}: fixture/profile fingerprint mismatch")
        if archive["profile_fingerprint"] != old.fingerprint:
            errors.append(f"{case}: parameter archive fingerprint mismatch")
        if archive["profile"] != json.loads(json.dumps(layout)):
            errors.append(f"{case}: parameter archive layout profile mismatch")
        if baseline is None:
            baseline = old, layout, attrs
        elif layout != baseline[1] or attrs != baseline[2] or old.macros != baseline[0].macros:
            errors.append(f"{case}: different fixture producer profile")
        records.append({"case": case, "fingerprint": old.fingerprint,
                        "manifest": str(Path(meta["manifest"]).resolve()),
                        "metadata_sha256": {p: digest(root / p) for p in
                            ("fixture.json", "config.txt", "tensors.tsv", "parameters/manifest.json")}})
    result = {"scope": "all-nine fixture and actual-image metadata comparison only",
              "hardware_acceptance": False, "tensor_content_validation": False,
              "cases": records, "old_layout": baseline[1], "old_target": baseline[2]}
    if args.new_manifest:
        if args.new_manifest.resolve() == Path(baseline[0].manifest_path).resolve():
            errors.append("old fixture manifest cannot stand in for new image")
        packaged = read_manifest(args.new_manifest.parent)
        if args.new_manifest.name != "manifest.json" or packaged is None:
            errors.append("new image requires its actual schema-v2 sibling manifest.json")
        new, layout, attrs = profile(args.new_manifest)
        stamp = parse_config_stamp(args.new_config_stamp)
        if not stamp or parse_vortex_configs(stamp.get("CONFIGS", "")) != new.macros:
            errors.append("new manifest params.CONFIGS differs from actual build stamp")
        resolved = packaged.get("resolved_params", {}).get("CONFIGS") if packaged else None
        if resolved is not None and parse_vortex_configs(resolved) != new.macros:
            errors.append("new params.CONFIGS and resolved_params.CONFIGS disagree")
        delta = {k: {"old": baseline[0].macros.get(k), "new": new.macros.get(k),
                     "old_present": k in baseline[0].macros, "new_present": k in new.macros}
                 for k in sorted(set(baseline[0].macros) | set(new.macros))
                 if (k in baseline[0].macros, baseline[0].macros.get(k)) !=
                    (k in new.macros, new.macros.get(k))}
        if (set(delta) != {"GEMM_SRAM_FUSION"}
                or "GEMM_SRAM_FUSION" not in new.macros
                or new.macros.get("GEMM_SRAM_FUSION") not in (None, "1")):
            errors.append("unexpected macro delta: manual source review required")
        if layout != baseline[1] or attrs != baseline[2]:
            errors.append("normalized packing/capability profile differs")
        result["new_image"] = {"manifest": str(args.new_manifest.resolve()),
                               "manifest_sha256": digest(args.new_manifest),
                               "config_stamp_sha256": digest(args.new_config_stamp),
                               "fingerprint": new.fingerprint, "macro_delta": delta,
                               "id": packaged.get("id") if packaged else None}
    result.update(errors=errors, metadata_comparison_pass=not errors and bool(args.new_manifest),
                  new_image_pending=not bool(args.new_manifest))
    print(json.dumps(result, indent=2))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

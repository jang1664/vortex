"""Publish a verified, explicitly mixed-image revision without relabeling reused rows."""
import csv
import hashlib
import json
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))
from tools.latency_bench.raw_db import _normalize_args
DOC = Path(__file__).resolve().parent

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def key(row):
    return row["app"], _normalize_args(row["args"])

def read(p):
    with p.open(newline="") as f:
        reader = csv.DictReader(f)
        return reader.fieldnames, list(reader)

def main():
    rev = json.loads((DOC / "revision.json").read_text())
    app = rev["app"]
    spec = rev["snapshot"]["candidates"]["C4"]
    ready = []
    delta = []
    result = {"source_tag": rev["source_tag"], "tag": rev["tag"], "models": {}}
    for model, info in rev["models"].items():
        src, dst = Path(info["source"]), Path(info["output"])
        for label, digest in info["raw_sha256"].items():
            assert sha(src / label / "raw_db.csv") == digest, (model, label, "rev4 changed")
            assert sha(dst / label / "raw_db.csv") == digest, (model, label, "rev5 baseline changed")
        fields, original = read(src / "C4/raw_db.csv")
        _, measured = read(dst / "C4/refresh_fpint_gemm_ffn_hw/raw_db.csv")
        old = {key(r): r for r in original if r["app"] == app}
        new = {key(r): r for r in measured}
        assert len(new) == len(measured) == info["target_count"]
        assert new.keys() == old.keys(), (model, "physical shape set changed")
        for k, row in new.items():
            assert row["app"] == app and row["status"] == "pass"
            assert row["fpga_bin_alias"] == spec["alias"] and row["xclbin_sha256"] == spec["xclbin_sha256"]
            assert row["measure_latency"] == row["measure_power"] == "1"
            assert not row["failure_reason"] and not row["power_parse_error"]
            assert float(row["fpga_cycle"]) > 0 and int(row["power_samples"]) >= 3
            assert (row["warmup"], row["iterations"]) == (old[k]["warmup"], old[k]["iterations"])
            ident = json.loads((dst / "C4/refresh_fpint_gemm_ffn_hw/runs" / row["run_id"] / "fpga_identity.json").read_text())
            for field in ("hostname", "xrt_device_bdf"):
                assert ident[field] == info["board"][field], (model, "board changed")
            before, after = float(old[k]["fpga_cycle"]), float(row["fpga_cycle"])
            delta.append({"model": model, "args": row["args"], "before_cycles": before,
                          "after_cycles": after, "cycle_delta_pct": 100 * (after / before - 1),
                          "before_board_power_w": old[k]["power_total_avg_w"],
                          "after_board_power_w": row["power_total_avg_w"],
                          "before_dynamic_power_w": old[k]["power_dynamic_avg_w"],
                          "after_dynamic_power_w": row["power_dynamic_avg_w"]})
        updated = [new[key(r)] if r["app"] == app else r for r in original]
        assert [r for r in updated if r["app"] != app] == [r for r in original if r["app"] != app]
        assert len(updated) == len(original)
        ready.append((model, dst, fields, updated))
        result["models"][model] = {"replaced": len(new), "preserved_c4": info["preserved_c4_count"],
                                   "C1_C3_byte_identical": True, "board": info["board"]["xrt_device_bdf"]}
    for model, dst, fields, updated in ready:
        output = dst / "C4/raw_db.csv"
        temp = output.with_suffix(".rev5.tmp")
        with temp.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fields)
            writer.writeheader(); writer.writerows(updated)
        temp.replace(output)
        result["models"][model]["published_raw_sha256"] = sha(output)
        for label in ("C1", "C3"):
            assert sha(dst / label / "raw_db.csv") == rev["models"][model]["raw_sha256"][label]
    with (DOC / "comparison.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(delta[0]))
        writer.writeheader(); writer.writerows(delta)
    result["status"] = "complete"
    result["provenance"] = "Only C4 fpint_gemm_ffn_hw rows use the new image; all other rows retain original rev4 metadata and values."
    (DOC / "completion.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()

"""Verify that only the frozen QK/reorder physical rows changed in rev5_v2."""
import csv
import hashlib
import json
from pathlib import Path

DOC = Path(__file__).resolve().parent
BASELINE = json.loads((DOC / "baseline.json").read_text())
SELECTION = json.loads((DOC / "selection.json").read_text())


def read(path):
    with path.open(newline="") as source:
        return {row["exec_key"]: row for row in csv.DictReader(source)}


def main():
    summary = {"status": "complete", "source_tag": BASELINE["source_tag"],
               "tag": "rev5_v2", "scope": BASELINE["scope"], "models": {}}
    comparison = []
    for model, spec in BASELINE["models"].items():
        src, dst = Path(spec["source"]), Path(spec["output"])
        for label, expected_hash in spec["raw_sha256"].items():
            original = src / label / "raw_db.csv"
            assert hashlib.sha256(original.read_bytes()).hexdigest() == expected_hash, original
            if label != "C1":
                assert hashlib.sha256((dst / label / "raw_db.csv").read_bytes()).hexdigest() == expected_hash
        before, after = read(src / "C1/raw_db.csv"), read(dst / "C1/raw_db.csv")
        targets = {c["exec_key"]: c for stage in SELECTION["models"][model].values()
                   for c in stage["physical_cases"]}
        assert set(after) == set(before) | set(targets), model
        untouched = {key: row for key, row in before.items() if key not in targets}
        assert all(after[key] == row for key, row in untouched.items()), model
        for key, target in targets.items():
            row = after[key]
            assert row["app"] == target["app"] and row["status"] == "pass", (model, target)
            assert row["measure_latency"] == row["measure_power"] == "1", (model, key)
            assert float(row["fpga_cycle"]) > 0 and int(row["power_samples"]) >= 3
            assert not row["failure_reason"] and not row["power_parse_error"], (model, key)
            for field in ("log_file", "raw_csv"):
                assert str(dst) in row[field] and Path(row[field]).is_file(), (model, key, field)
            run = dst / "C1/runs" / row["run_id"]
            variant = json.loads((run / "kernel_variants.json").read_text())["apps"][row["app"]]
            assert variant["source_identity"] == SELECTION["source_identities"][row["app"]]
            identity = json.loads((run / "fpga_identity.json").read_text())
            assert identity["xrt_device_bdf"] == spec["board"]["xrt_device_bdf"]
            old = before.get(key)
            if old:
                assert old["run_id"] != row["run_id"]
            comparison.append(dict(model=model, stage=target["stage"], name=target["name"],
                app=row["app"], args=row["args"], old_cycles=old["fpga_cycle"] if old else "",
                new_cycles=row["fpga_cycle"], delta_percent=(100 * (float(row["fpga_cycle"]) /
                    float(old["fpga_cycle"]) - 1)) if old else "",
                elapsed_wall_s=row["elapsed_wall_s"], run_id=row["run_id"]))
        summary["models"][model] = dict(
            remeasured_qk=sum(c["app"] == "sgemm_tcu" for c in targets.values()),
            added_reorders=sum(c["app"] == "head_concat" for c in targets.values()),
            preserved_C1_rows=len(untouched), C3_C4_byte_identical=True,
            original_raw_databases_unchanged=True, board=identity,
            source_board=spec["board"])
    with (DOC / "comparison.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(comparison[0]))
        writer.writeheader()
        writer.writerows(comparison)
    (DOC / "completion.json").write_text(json.dumps(summary, indent=2) + "\n")
    report = "\n".join(
        "Status: complete. All selected latency/power measurements passed."
        if line.startswith("Status:") else line
        for line in (DOC / "README.md").read_text().splitlines()) + "\n"
    if "Verified: original Rev5 raw databases unchanged" not in report:
        report += "\nVerified: original Rev5 raw databases unchanged; non-target C1 rows preserved; C3/C4 raw DBs byte-identical.\n"
        report += "\nArtifacts: `selection.json`, `completion.json`, `comparison.csv`, `workflow.log`, and `correctness/SUMMARY.md`.\n"
    (DOC / "README.md").write_text(report)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

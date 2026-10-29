#!/usr/bin/env python3
"""Join strict decoder DMA, AFU, completion and command-ledger receipts.

This is attention-boundary traffic evidence, never a full decoder pass.
Numerical context comparison is an independent required test receipt.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
FLASH = ROOT / "tests/regression/flash_attn"
sys.path.insert(0, str(FLASH))
sys.path.insert(0, str(ROOT / "tools"))
from decoder_traffic_manifest import DecoderTrafficManifest, integer, require
from gemm_command_overlap_summary import read_trace


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""): h.update(block)
    return h.hexdigest()


def verify_inputs(manifest, receipt_path):
    receipt = json.loads(receipt_path.read_text())
    snapshot = Path(manifest.data["snapshot"]["path"]).resolve()
    expected_path = Path(receipt["snapshot"])
    if not expected_path.is_absolute(): expected_path = ROOT / expected_path
    require(snapshot == expected_path.resolve(), "snapshot receipt path mismatch")
    require(receipt["model"] == manifest.data["model"], "snapshot model mismatch")
    expected_names = {name for name, b in manifest.buffers.items()
                      if b["role"] not in {"context"} and not b["role"].startswith("pad_")}
    require(len(receipt["files"]) == 49 and {f["name"] for f in receipt["files"]} == expected_names,
            "missing or duplicate snapshot input hashes")
    for entry in receipt["files"]:
        path = snapshot / (entry["name"] + ".bin")
        require(path.stat().st_size == entry["bytes"] == manifest.buffers[entry["name"]]["bytes"],
                "snapshot byte count mismatch")
        require(digest(path) == entry["sha256"], f"snapshot hash mismatch: {path}")
    require(digest(snapshot / "buffers.tsv") == receipt["catalog_sha256"], "snapshot catalog changed")
    path = Path(receipt["snapshot_receipt"])
    if not path.is_absolute(): path = ROOT / path
    require(digest(path) == receipt["snapshot_receipt_sha256"], "snapshot receipt changed")
    # Historical P16 receipts predate the explicit kind field. Only that exact
    # one-tile case may use the archived device-snapshot default.
    default_kind = "device-snapshot" if manifest.tiles == 1 else None
    kind = receipt.get("kind", default_kind)
    require(kind == manifest.data["snapshot"].get("kind", default_kind),
            "snapshot input provenance kinds disagree")
    require(kind == ("device-snapshot" if manifest.tiles == 1 else "cpu-fixture-input"),
            "unsupported input provenance for this replay shape")
    if kind == "cpu-fixture-input":
        require(Path(manifest.data["snapshot"]["provenance"]).resolve() == path.resolve(),
                "manifest provenance does not match the input receipt")
        provenance = json.loads(path.read_text())
        require(provenance["schema"] == "c4_attention_input_provenance_v1"
                and provenance["kind"] == kind and provenance["full_decoder_pass"] is False
                and provenance["model"] == manifest.data["model"], "invalid CPU input provenance")
        fixture = Path(manifest.data["fixture"]).resolve()
        require(Path(provenance["snapshot"]).resolve() == snapshot
                and Path(provenance["fixture"]).resolve() == fixture,
                "CPU input provenance paths disagree")
        source = Path(provenance["source_npz"]["path"])
        require(source.resolve() == (fixture / "reference.npz").resolve()
                and digest(source) == provenance["source_npz"]["sha256"],
                "CPU updated-reference NPZ changed or was substituted")
        require(provenance["updated_cache_keys"] == [f"cache_{i}" for i in range(6)],
                "CPU inputs must use all six updated cache arrays")
        if manifest.prefill:
            checks = provenance.get("checks")
            require(provenance.get("cache_source_stage") == "prefill"
                    and isinstance(checks, dict) and checks.get("prefill_cache_outputs") is True,
                    "prefill inputs require explicit prefill cache-output provenance")
        capacity = manifest.data["model"]["capacity"]
        if capacity in (144, 160):
            require(provenance.get("physical_padding") == dict(logical_capacity=capacity,
                    value_execution_rows=256, value_zero_rows=[capacity,256],
                    key_input_bytes=capacity*64, key_adapter_bytes=16384),
                    "CPU inputs require explicit canonical V padding before packing")
    return dict(input_files=49, input_bytes=sum(f["bytes"] for f in receipt["files"]),
                input_receipt_sha256=digest(receipt_path), input_kind=kind)


def verify_completion(manifest, path):
    data = json.loads(path.read_text())
    require(data.get("schema") == "c4_decoder_attention_completion_v1"
            and data.get("full_decoder_pass") is False, "invalid completion scope")
    require(len(data["records"]) == manifest.record_count, "missing completion records")
    phases = collections.Counter()
    for index, record in enumerate(data["records"]):
        require(record["index"] == index, "completion record order mismatch")
        a = record["attention"]
        tiles = manifest.tiles
        tile_bytes = integer(manifest.data["records"][index]["attention"]["query_rows_pad"]) * 128 * 2
        expected = dict(status=1, completed_kv_tiles=tiles, current_kv_tile=tiles-1,
                        dma_sequence=3*tiles+1,
                        sram_copy_bytes=((5*tiles+2) if manifest.fp32 else (3*tiles+1))*tile_bytes,
                        qk_progress_events=tiles*(128//16), pv_progress_events=tiles*(128//16))
        require(all(integer(a[k]) == v for k,v in expected.items()), "record completion/copy counters disagree")
        names = ("gemm_submit_cycles", "gemm_wait_cycles", "sram_copy_cycles", "simd_cycles")
        total = integer(a["total_cycles"])
        values = [integer(a[k]) for k in names]
        require(total > 0 and all(v > 0 for v in values) and sum(values) <= total,
                "missing/inconsistent phase intervals")
        phases.update(dict(zip(names, values)))
        phases["total_cycles"] += total
        phases["other_control_cycles"] += total-sum(values)
        phases["sram_copy_bytes"] += integer(a["sram_copy_bytes"])
    kernel_cycles = integer(data["cycles"])
    require(kernel_cycles >= phases["total_cycles"], "attention intervals exceed complete kernel cycles")
    return dict(passed=True, records=manifest.record_count, phases=dict(phases), kernel_cycles=kernel_cycles,
                outside_attention_intervals=kernel_cycles-phases["total_cycles"],
                outside_interval_scope="Includes input adapters, batch/runtime control and startup/exit; not pure adapter time")


def verify_ledger(path, expected_jobs):
    trace = read_trace(path, "decoder_attention")
    jobs = {s["job"]: s for s in trace.summaries}
    require(len(jobs) == len(trace.summaries) == expected_jobs, "missing/duplicate final job")
    require({r["job"] for r in trace.commands} == set(jobs), "timeline jobs differ from summary jobs")
    require({r["job"] for r in trace.classes} == set(jobs), "class jobs differ from summary jobs")
    out = {}
    for job, summary in sorted(jobs.items()):
        records = [r for r in trace.commands if r["job"] == job]
        classes = [r for r in trace.classes if r["job"] == job]
        require(summary["emitted"] == summary["issued"] == summary["completed"] == len(records)
                and summary["incomplete"] == 0, "incomplete command lifecycle")
        require(len({r["uid"] for r in records}) == len(records), "duplicate command UID")
        for r in records:
            require(r["emit"] <= r["issue"] <= r["done"]
                    and r["queue"] == r["issue"]-r["emit"]
                    and r["service"] == r["done"]-r["issue"], "invalid command interval")
        require(len({c["class"] for c in classes}) == len(classes), "duplicate command class")
        require({r["class"] for r in records} <= {c["class"] for c in classes}, "missing command class")
        for c in classes:
            cr = [r for r in records if r["class"] == c["class"]]
            require(c["count"] == len(cr) and c["queue_cycles"] == sum(r["queue"] for r in cr)
                    and c["service_cycles"] == sum(r["service"] for r in cr), "class accounting mismatch")
        children = {}
        require(all(r["child"] in range(6) for r in records), "unknown command child")
        for child in range(6):
            cr = sorted([r for r in records if r["child"] == child], key=lambda r:(r["issue"],r["uid"]))
            events = collections.Counter()
            for r in cr:
                events[r["issue"]] += 1
                events[r["done"]] -= 1
            active = peak = 0
            for cycle, delta in sorted(events.items()):
                active += delta
                require(active >= 0, "negative inflight occupancy")
                peak = max(peak, active)
            require(active == 0, "child did not drain")
            if child < 5:
                require(peak <= (4 if child < 4 else 1), "child exceeds queue capacity")
                require([r["uid"] for r in cr] == [r["uid"] for r in
                        sorted(cr,key=lambda r:(r["done"],r["issue"],r["uid"]))], "child FIFO reordered")
            children[child] = dict(peak_inflight=peak, records=len(cr),
                same_edge_issue_completion_cycles=sorted({r["issue"] for r in cr}&{r["done"] for r in cr}))
        # Retain the original overlapping-input witness, in addition to bounds.
        require(children[0]["peak_inflight"] > 1, "missing overlapping input commands")
        out[job] = dict(summary=summary, children=children, classes=classes)
    return dict(passed=True, jobs=out,
        compute_pipeline_active_cycles_total=sum(s["compute_pipeline_cycles"] for s in jobs.values()),
        note="Compute activity overlaps memory service; GEMM wait includes loads/polling. Do not sum overlapping intervals.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("manifest", "completion", "input-receipt", "kernel-elf", "app-log", "trace", "output"):
        parser.add_argument("--"+name, required=True, type=Path)
    args = parser.parse_args()
    result = dict(passed=False, full_decoder_pass=False,
                  scope="Complete decoder attention replay; numerical comparison separate")
    try:
        manifest = DecoderTrafficManifest(args.manifest)
        result["scope"] = ("All eight production attention records, Llama3 decode "
                           f"P{manifest.data['model']['past_kv']}/C{manifest.data['model']['capacity']}; "
                           "numerical comparison separate")
        if manifest.prefill:
            result["scope"] = "All 64 production attention records, Llama3 prefill S144; numerical comparison separate"
        manifest.check_app(args.app_log.read_text())
        result["inputs"] = verify_inputs(manifest, args.input_receipt)
        result["completion"] = verify_completion(manifest, args.completion)
        dma_path = args.output.with_name(args.output.stem+"_dma.json")
        external_path = args.output.with_name(args.output.stem+"_external.json")
        for script, output in (("check_dma_trace.py", dma_path),("check_external_trace.py", external_path)):
            command = [sys.executable, str(FLASH/script), "--app-log", str(args.app_log),
                       "--trace", str(args.trace), "--decoder-manifest", str(args.manifest),
                       "--output", str(output)]
            if script == "check_external_trace.py": command += ["--dma-audit", str(dma_path), "--kernel-elf", str(args.kernel_elf)]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            result[script] = json.loads(output.read_text())
        result["ledger"] = verify_ledger(args.trace, manifest.expected_jobs)
        result["passed"] = True
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        result["error"] = str(error)
    result["evidence_sha256"] = {name: digest(getattr(args,name)) for name in
                                ("manifest","completion","input_receipt","kernel_elf","app_log","trace")
                                if getattr(args,name).is_file()}
    args.output.write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({k:v for k,v in result.items() if k in {"passed","full_decoder_pass","error","scope"}},indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

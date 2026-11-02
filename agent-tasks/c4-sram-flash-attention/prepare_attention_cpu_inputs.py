#!/usr/bin/env python3
"""Pack C4 P128/C160, P128/C256 or prefill S144 CPU attention inputs without a device.

Use the same TVM Python environment as llama_decoder_C4/reference.py. These
inputs establish an attention-only numerical/traffic test, not decoder output.
"""
import argparse
from contextlib import nullcontext
from dataclasses import asdict
import hashlib
import inspect
import json
from pathlib import Path
import sys

import numpy as np

ROOT = next(parent for parent in Path(__file__).resolve().parents
            if (parent / "tests/regression/llama_decoder_C4/reference.py").is_file())
sys.path.insert(0, str(ROOT / "tests/regression/llama_decoder_C4"))
import reference as ref

MODEL = dict(name="llama3-8b", batch=1, seq=1, stage="decode", past_kv=128,
             capacity=256, q_heads=32, kv_heads=8, head_dim=128)
CACHE_KEYS = [f"cache_{i}" for i in range(6)]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            value.update(block)
    return value.hexdigest()


def file_record(path):
    path = Path(path).resolve(strict=True)
    return dict(path=str(path), sha256=digest(path))


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-reference-sha256", required=True)
    args = parser.parse_args()
    fixture = args.fixture.resolve(strict=True)
    output = args.output.resolve()
    require(not output.exists(), "output must be a new directory")
    require(not output.is_relative_to(fixture), "output must be outside the immutable fixture")
    source = fixture / "reference.npz"
    source_record = file_record(source)
    require(source_record["sha256"] == args.expected_reference_sha256,
            "reference NPZ does not match the independently supplied hash")
    metadata = json.loads((fixture / "fixture.json").read_text())
    cfg = metadata["config"]
    capacity = cfg["cache_capacity"]
    prefill = metadata["decoder_stage"] == "prefill"
    sequence = 144 if prefill else 1
    past = 0 if prefill else 128
    require(capacity == 144 if prefill else capacity in (160, 256),
            "CPU input preparation requires prefill C144 or decode C160/C256")
    model = {**MODEL, "capacity": capacity, "seq": sequence, "past_kv": past,
             "stage": "prefill" if prefill else "decode"}
    expected_cfg = dict(batch_size=1, query_length=sequence, cache_capacity=capacity,
                        hidden_size=4096, intermediate_size=14336,
                        num_attention_heads=32, num_key_value_heads=8, head_dim=128,
                        kv_group_size=128, rms_reduction_width=16,
                        kv_quantize_fp16_arithmetic=True)
    require(metadata["model"] == MODEL["name"]
            and metadata["decoder_stage"] == model["stage"] and metadata["past_kv_len"] == past
            and all(cfg[k] == value for k, value in expected_cfg.items()),
            "only full Llama3 decode B1/S1/P128/C160 or C256, or prefill B1/S144/P0/C144 is supported")
    expected_text = dict(model="llama3-8b", batch=1, seq=sequence, hidden=4096, ffn=14336,
                         q_heads=32, kv_heads=8, head_dim=128, stage=model["stage"],
                         past_kv=past, cache_capacity=capacity)
    text_config = dict(line.split() for line in (fixture / "config.txt").read_text().splitlines())
    if prefill:
        for key, value in (("stage", "prefill"), ("past_kv", "0"), ("cache_capacity", "144")):
            text_config.setdefault(key, value)
    require(all(text_config.get(k) == str(v) for k, v in expected_text.items()),
            "config.txt and fixture.json disagree")
    profile_path = Path(metadata["manifest"]).resolve(strict=True)
    accelerator = ref.load_vortex_accelerator_profile(str(profile_path))
    profile = ref.ImproveProfile.from_target(accelerator.target)
    expected_profile = dict(dma_mt=128, dma_nt=128, dma_kt=128, mxu_kt=16, mxu_nt=16,
                            row_alignment=8, qparam_slot_alignment=512,
                            num_dma_channels=4, num_tmem_banks=8, tmem_bank_size=32768)
    require(accelerator.fingerprint == metadata["profile_fingerprint"]
            and all(getattr(profile, k) == v for k, v in expected_profile.items()),
            "fixture must use the matching rev8 C4 packing profile")

    source_files = [Path(__file__), Path(ref.__file__),
                    Path(inspect.getsourcefile(ref.plan_improve_layout)),
                    Path(inspect.getsourcefile(ref.load_vortex_accelerator_profile)),
                    fixture / "fixture.json", fixture / "config.txt", profile_path,
                    source]
    if not prefill:
        source_files.append(fixture / "initial_cache.npz")
    sources = [file_record(path) for path in dict.fromkeys(path.resolve() for path in source_files)]
    packed = {}
    catalog = []
    changes = {}

    def add(name, array, layout, matrices=1, rows=1, cols=1, expected_bytes=None):
        array = np.ascontiguousarray(array)
        require(array.nbytes == expected_bytes, f"unexpected packed byte count: {name}")
        packed[name] = array
        catalog.append(f"{name}\t{layout}\t{matrices}\t{rows}\t{cols}\t{array.nbytes}\n")

    with np.load(source, allow_pickle=False) as values, (
            nullcontext(None) if prefill else np.load(fixture / "initial_cache.npz", allow_pickle=False)) as initial:
        matrices, rows = (32, 144) if prefill else (8, 4)
        padded_rows = (rows + 7) // 8 * 8
        for name, layout in (("q_hadamard", "a"), ("context", "c")):
            logical_value = values[name]
            require(logical_value.shape == (1, 32, sequence, 128)
                    and logical_value.dtype == np.dtype("float16")
                    and np.isfinite(logical_value).all(), f"invalid logical {name}")
            grouped = logical_value.reshape(matrices, rows, 128)
            # Invert the existing logical reader using its index map. This
            # preserves its exact stripe/microtile ABI without a second formula.
            physical = np.zeros(matrices * padded_rows * 128, dtype="float16")
            indices = ref.logical(np.arange(physical.size), layout, matrices, rows, 128, profile.mxu_kt)
            physical[indices] = grouped
            roundtrip = ref.logical(physical, layout, matrices, rows, 128, profile.mxu_kt)
            require(roundtrip.tobytes() == grouped.tobytes(), f"{name} packing roundtrip failed")
            add(name, physical, layout, matrices, rows, 128, matrices*padded_rows*128*2)

        for is_key, first in ((True, 0), (False, 3)):
            plan = ref.plan_improve_layout(1, capacity if is_key else 128,
                                          128 if is_key else 256, 128,
                                          is_key, 0 if is_key else 1, profile)
            for offset, suffix, dtype, columns in ((0, "weight", "uint8", 64),
                                                    (1, "scale", "float16", 1),
                                                    (2, "zero", "int16", 1)):
                key = f"cache_{first + offset}"
                value = values[key]
                require(value.shape == (1, 8, capacity, columns)
                        and value.dtype == np.dtype(dtype), f"invalid {key}")
                require(np.isfinite(value).all(), f"nonfinite {key}")
                if not prefill:
                    before = initial[key]
                    require(before.shape == value.shape and before.dtype == value.dtype,
                            f"invalid initial {key}")
                    require(np.array_equal(value[:, :, :128], before[:, :, :128])
                            and np.array_equal(value[:, :, 129:], before[:, :, 129:]),
                            f"{key} changed outside appended row 128")
                    changed = int(np.count_nonzero(value[:, :, 128] != before[:, :, 128]))
                    require(changed > 0, f"{key} is not the updated reference cache")
                    changes[key] = changed
                for head in range(8):
                    name = f'{"key" if is_key else "value"}.0.{head}.{suffix}'
                    canonical = value[0, head]
                    if not is_key and capacity < 256:
                        # C++ pads V's execution K to a complete DMA tile.
                        # Pad canonical rows before tiling: compact tiled tails
                        # have different N-microtile strides and cannot be appended.
                        canonical = np.pad(canonical, ((0, 256-capacity), (0, 0)))
                        require(np.array_equal(canonical[:capacity], value[0, head])
                                and not np.any(canonical[capacity:]), f"invalid V padding: {name}")
                    data = (ref.prepack_improve_weight(canonical, plan) if offset == 0
                            else ref.prepack_improve_qparam(canonical, plan, dtype))
                    expected_bytes = (capacity*64 if is_key else 16384) if offset == 0 else (1024 if is_key else 4096)
                    add(name, data, "fixture", expected_bytes=expected_bytes)

    require(len(packed) == 50, "expected 49 inputs plus independent reference context")
    # Validate every source before writing; never mutate the fixture or an old receipt.
    require(all(digest(entry["path"]) == entry["sha256"] for entry in sources),
            "source changed during packing")
    output.mkdir(parents=True)
    files = []
    for name, data in packed.items():
        path = output / f"{name}.bin"
        data.tofile(path)
        files.append(dict(name=name, bytes=path.stat().st_size, **file_record(path)))
    (output / "buffers.tsv").write_text("".join(catalog))
    catalog_hash = digest(output / "buffers.tsv")
    provenance = dict(schema="c4_attention_input_provenance_v1", kind="cpu-fixture-input",
                      full_decoder_pass=False, model=model, snapshot=str(output), fixture=str(fixture),
                      source_npz=source_record, updated_cache_keys=CACHE_KEYS,
                      profile=dict(**file_record(profile_path), fingerprint=accelerator.fingerprint,
                                   layout_fields=asdict(profile)), sources=sources, files=files,
                      catalog_sha256=catalog_hash,
                      reference_context=next(entry for entry in files if entry["name"] == "context"),
                      physical_padding=dict(logical_capacity=capacity, value_execution_rows=256,
                                            value_zero_rows=[capacity, 256],
                                            key_input_bytes=capacity*64, key_adapter_bytes=16384),
                      checks=dict(q_context_logical_roundtrip_bitexact=True,
                                  input_count=49, device_execution=False))
    if prefill:
        # These are prefill-produced cache outputs; there is no decode append source.
        provenance["cache_source_stage"] = "prefill"
        provenance["checks"]["prefill_cache_outputs"] = True
    else:
        provenance["initial_cache_npz"] = file_record(fixture / "initial_cache.npz")
        provenance["checks"].update(unchanged_cache_rows_except_128=True,
                                    changed_elements_at_row_128=changes)
    receipt_path = output / "provenance.json"
    write_json(receipt_path, provenance)
    receipt = dict(kind="cpu-fixture-input", model=model, snapshot=str(output),
                   snapshot_receipt=str(receipt_path), snapshot_receipt_sha256=digest(receipt_path),
                   catalog_sha256=catalog_hash,
                   files=[{k: entry[k] for k in ("name", "bytes", "sha256")}
                          for entry in files if entry["name"] != "context"])
    write_json(output / "input_manifest.json", receipt)
    print(f"CPU_ATTENTION_INPUTS_PREPARED {output} inputs=49 full_decoder_pass=false")


if __name__ == "__main__":
    main()

"""Validated address/byte contract for complete decoder GQA replays.

The first supported case is deliberately explicit. Additional shapes must add
independent layout expectations before they can be accepted by this auditor.
"""
import collections
import json
from pathlib import Path

LMEM_BASE = 0x1FFC00000
LMEM_SIZE = 1 << 20
ROLES = {"q", "k_weight", "k_scale", "k_zero", "v_weight", "v_scale", "v_zero",
         "context", "pad_k_weight", "pad_v_weight", "pad_v_scale", "pad_v_zero"}


def integer(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def require(condition, message):
    if not condition:
        raise ValueError(message)


class DecoderTrafficManifest:
    def __init__(self, path):
        self.path = Path(path)
        self.data = json.loads(self.path.read_text())
        d = self.data
        require(isinstance(d, dict), "manifest must be a JSON object")
        require(d.get("schema") == "c4_decoder_attention_traffic_v1", "wrong manifest schema")
        require(isinstance(d.get("model"), dict), "manifest model must be a JSON object")
        expected_model = dict(name="llama3-8b", batch=1,
                              q_heads=32, kv_heads=8, head_dim=128)
        require(all(d["model"].get(k) == v for k, v in expected_model.items()),
                "this audit requires complete Llama3 attention")
        shape = (d["model"].get("past_kv"), d["model"].get("capacity"))
        self.prefill = (d["model"].get("stage"), d["model"].get("seq"), shape) == ("prefill", 144, (0, 144))
        decode = (d["model"].get("stage"), d["model"].get("seq")) == ("decode", 1)
        require(self.prefill or (decode and shape in {(16, 32), (128, 160), (128, 256)}),
                "supported replay shapes are decode P16/C32, P128/C160, P128/C256 and prefill S144")
        self.record_count = 64 if self.prefill else 8
        self.tiles = 1 if shape == (16, 32) else 2
        small_cache = self.tiles == 1
        key_padded = shape[1] < self.tiles * 128
        expected_geometry = dict(banks=32, ports=4, beat_bytes=64, address_bits=34,
                                 cores=1, warps=4, threads=16)
        require(d["geometry"] == expected_geometry, "wrong C4 geometry")
        require(d["backend"] in {"resident", "resident-fp32"}, "wrong backend")
        self.fp32 = d["backend"] == "resident-fp32"
        self.buffers = {}
        for b in d["buffers"]:
            name, base, size = b["name"], integer(b["base"]), integer(b["bytes"])
            require(name not in self.buffers and b["role"] in ROLES, "duplicate name or unknown buffer role")
            require(base > 0 and base % 64 == 0 and size > 0 and size % 64 == 0,
                    "tensor range must contain complete aligned cache lines")
            self.buffers[name] = dict(b, base=base, bytes=size)
        query_bytes = 1179648 if self.prefill else 16384
        expected = {"q_hadamard": ("q", query_bytes), "context": ("context", query_bytes)}
        for head in range(8):
            suffix = f"0.{head}"
            for tensor, short in (("key", "k"), ("value", "v")):
                qparam_bytes = 512 if small_cache else (1024 if short == "k" else 4096)
                weight_bytes = shape[1]*64 if short == "k" else (2048 if small_cache else 16384)
                for field, size in (("weight", weight_bytes),
                                    ("scale", qparam_bytes), ("zero", qparam_bytes)):
                    expected[f"{tensor}.{suffix}.{field}"] = (f"{short}_{field}", size)
            for name, role, size in (("key_pad", "pad_k_weight", 8192*self.tiles),
                                     ("value_pad", "pad_v_weight", 8192),
                                     ("value_scale_pad", "pad_v_scale", 2048),
                                     ("value_zero_pad", "pad_v_zero", 2048)):
                if small_cache or (key_padded and name == "key_pad"):
                    expected[f"attention.{name}.{suffix}"] = (role, size)
        require(set(self.buffers) == set(expected), "missing or unexpected tensor allocation (including spills)")
        for name, (role, size) in expected.items():
            b = self.buffers[name]
            require((b["role"], b["bytes"]) == (role, size), f"wrong role/size: {name}")
            require(b["base"] + size <= LMEM_BASE or b["base"] >= LMEM_BASE + LMEM_SIZE,
                    "HBM tensor overlaps LMEM")
        self.ranges = {name: (b["base"], b["bytes"]) for name, b in self.buffers.items()}
        self.writable = {name for name, b in self.buffers.items()
                         if b["role"] == "context" or b["role"].startswith("pad_")}
        a, dispatch = d["arguments"], d["dispatch"]
        self.args_base = integer(a["base"])
        self.dispatch_base = integer(dispatch["base"])
        require(integer(a["record_bytes"]) > 0 and integer(a["bytes"]) == self.record_count * integer(a["record_bytes"]),
                "argument array count/stride mismatch")
        if self.prefill:
            require(integer(a["record_bytes"]) == 512, "prefill requires the production 512-byte argument record")
        require(integer(dispatch["args_base"]) == self.args_base and dispatch["count"] == self.record_count
                and dispatch["operation"] == 10 and dispatch["bytes"] == 16,
                "dispatch must launch the complete production attention operation")
        self.runtime_ranges = {}
        for name, obj in (("arguments", a), ("dispatch", dispatch)):
            base, size = integer(obj["base"]), integer(obj["bytes"])
            require(base > 0 and size > 0, "invalid runtime allocation")
            self.runtime_ranges[name] = (base & ~63, ((base % 64 + size + 63) // 64) * 64)
        self.check_disjoint(dict(self.ranges, **self.runtime_ranges))
        self.expected_beats = collections.Counter()
        self.expected_bytes = collections.Counter()
        require(len(d["records"]) == self.record_count, "missing attention records")
        for index, record in enumerate(d["records"]):
            head = index // 2 if self.prefill else 4 * index
            kv_head = head // 4
            row = 128 * (index % 2) if self.prefill else 0
            rows = (16 if row else 128) if self.prefill else 4
            padded_rows = rows if self.prefill else 8
            tile_bytes = padded_rows * 128 * 2
            query_offset = (144 * head + row) * 256 if self.prefill else index * 2048
            require(all(record[k] == v for k, v in dict(index=index, batch=0,
                    query_head_start=head, kv_head=kv_head, row_start=row).items()), "wrong attention record order")
            attn = record["attention"]
            fixed = dict(query_rows=rows, query_rows_pad=padded_rows,
                         kv_length=144 if self.prefill else shape[0]+1, kv_tile=128, head_dim=128,
                         qk_qblk=128, qk_wtrans=1, qk_qdir=0, pv_qblk=128, pv_wtrans=0,
                         pv_qdir=1, causal=int(self.prefill), pv_only=0, resident=1, debug_export=0,
                         debug_stage=0, output_tiled=1, query_position_base=row, output_fp32=int(self.fp32))
            require(all(integer(attn[k]) == v for k, v in fixed.items()), "unsupported/tampered attention arguments")
            require(all(integer(attn[k]) == 0 for k in attn if k.startswith("debug_") and k.endswith("_base")),
                    "diagnostic intermediate exports are forbidden")
            suffix = f"0.{kv_head}"
            destinations = dict(q_base=("q_hadamard", query_offset),
                output_base=("context", query_offset),
                k_weight_base=(f"attention.key_pad.{suffix}" if key_padded else f"key.{suffix}.weight", 0),
                k_scale_base=(f"key.{suffix}.scale", 0), k_zero_base=(f"key.{suffix}.zero", 0),
                v_weight_base=(f"attention.value_pad.{suffix}" if small_cache else f"value.{suffix}.weight", 0),
                v_scale_base=(f"attention.value_scale_pad.{suffix}" if small_cache else f"value.{suffix}.scale", 0),
                v_zero_base=(f"attention.value_zero_pad.{suffix}" if small_cache else f"value.{suffix}.zero", 0))
            for field, (name, offset) in destinations.items():
                require(integer(attn[field]) == self.buffers[name]["base"] + offset, f"wrong {field} group mapping")
            sources = {"key_source": f"key.{suffix}.weight", "value_source": f"value.{suffix}.weight",
                       "value_scale_source": f"value.{suffix}.scale", "value_zero_source": f"value.{suffix}.zero"}
            for field, name in sources.items():
                padded = key_padded if field == "key_source" else small_cache
                expected_source = self.buffers[name]["base"] if padded else 0
                require(integer(record[field]) == expected_source, f"wrong adapter {field}")
            require(record["key_source_bytes"] == (shape[1]*64 if key_padded else 0)
                    and record["key_padded_bytes"] == (8192*self.tiles if key_padded else 0)
                    and record["value_source_rows"] == (32 if small_cache else 0), "wrong adapter geometry")
            for tensor, size in (("k_weight",8192),("k_scale",512),("k_zero",512),
                                 ("v_weight",8192),("v_scale",2048),("v_zero",2048)):
                require(integer(attn[tensor+"_tile_bytes"]) == size, "wrong tile stride")
            arena = dict(score_base=tile_bytes*(2 if self.fp32 else 1), probability_base=tile_bytes,
                         partial_base=tile_bytes*(2 if self.fp32 else 1), accumulator_base=rows*128*4,
                         row_max_base=rows*4, row_sum_base=rows*4, row_alpha_base=rows*4)
            for field, size in arena.items():
                base = integer(attn[field])
                require(LMEM_BASE <= base and base+size <= LMEM_BASE+(LMEM_SIZE//2),
                        f"attention intermediate outside reserved LMEM: {field}")
            if self.prefill:
                # Independently specified layout: only score/probability/partial
                # reuse is allowed; accumulator and row state must remain live.
                cursor = LMEM_BASE + arena["score_base"]
                offsets = dict(score_base=LMEM_BASE, partial_base=LMEM_BASE, probability_base=LMEM_BASE)
                if self.fp32:
                    offsets["probability_base"] = cursor
                    cursor += tile_bytes
                for field in ("accumulator_base", "row_max_base", "row_sum_base", "row_alpha_base"):
                    offsets[field] = cursor
                    cursor += (arena[field] + 31) & ~31
                require(all(integer(attn[k]) == v for k, v in offsets.items()),
                        "wrong prefill LMEM live-state layout")
            for tensor, size in (("q",tile_bytes),("k_weight",8192),("k_scale",256),("k_zero",256),
                                 ("v_weight",8192),("v_scale",2048),("v_zero",2048)):
                field = tensor+"_base"
                name = destinations[field][0]
                base = integer(attn[field])
                # Q remains resident across KV tiles. K/V advance by allocated
                # tile stride; K qparams load 256 B within each 512 B slot.
                for tile in range(1 if tensor == "q" else self.tiles):
                    tile_base = base + (tile * integer(attn[tensor+"_tile_bytes"]) if tensor != "q" else 0)
                    require(self.buffers[name]["base"] <= tile_base
                            and tile_base+size <= self.buffers[name]["base"]+self.buffers[name]["bytes"],
                            f"GEMM read exceeds tensor allocation: {name}")
                    for offset in range(0, size, 64): self.expected_beats[tile_base+offset] += 1
                    self.expected_bytes[name] += size
        require(sum(self.expected_bytes.values()) == (3866624 if self.prefill else (184320 if small_cache else 352256)),
                "internal expected-byte derivation mismatch")
        self.expected_jobs = 2 * self.record_count * self.tiles

    @staticmethod
    def check_disjoint(ranges):
        entries = sorted((base, base+size, name) for name, (base, size) in ranges.items())
        for first, second in zip(entries, entries[1:]):
            require(first[1] <= second[0], f"overlapping role envelopes: {first[2]} / {second[2]}")

    def check_app(self, app):
        require("ATTENTION_TRAFFIC_REPLAY PASSED full_decoder_pass=0" in app,
                "requires terminal successful replay, not a partial/full-decoder success alias")
        require(f"DECODER_ATTENTION_REPLAY records={self.record_count} diagnostics=0" in app,
                "requires all records without diagnostic exports")

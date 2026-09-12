#!/usr/bin/env python3
"""Source-grounded planned contract; no RTL execution or visibility proof."""
import argparse
import hashlib
import heapq
import json
import random
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
MT = KT = NT = 128
QBLK = 32

def ceildiv(a, b):
    return (a + b - 1) // b

# Exact source anchors fail closed on source drift. These are provenance checks,
# not an SV interpreter or a substitute for comparing emitted RTL descriptors.
ANCHORS = {
    "tests/regression/fpint_gemm_ffn_hw_naive/main.cpp": [
        "DMA_MT * DMA_KT * 2ull", "DMA_KT * ((DMA_NT + 1ull) / 2ull)",
        "groups_tile * DMA_NT * 2ull", "DMA_KT * ng_tile     * 2ull",
        "DMA_MT * DMA_NT * 4ull", "alloc(lmem_obuf_bytes,  kargs.lmem_obuf_base)",
        "alloc(lmem_psum_bytes,  kargs.lmem_psum_base)"],
    "hw/rtl/core/gemm/VX_gemm_fsm_naive.sv": [
        "Tile scan order: kt fastest -> mt -> nt.",
        "n_nt_mxu = (nt_mxu_q + 1 == nt_mxu_dim) ? 0 : (nt_mxu_q + 1)",
        "n_kt_mxu = (nt_mxu_q + 1 == nt_mxu_dim) ? (kt_mxu_q + 1) : kt_mxu_q",
        "return (t >> 1) + 1", "in_ready_target_cur = 4*gen_cur + 4",
        "lmem_out_slice = job_q.lmem_psum_base + 64'(n0_out) * MT * FP32_BYTES",
        "c.stride   = job_q.lmem_obuf_base + 64'(n0_out) * FP16_BYTES",
        "make_instr(OP_I_LDMA_ARM, in_bytes)",
        "tile_mxu_base      = tile_cur_q * u32_t'(MXU_PER_TILE_MAX)"],
    "hw/rtl/core/gemm/VX_gemm_node_naive.sv": [
        "input_dma_ctrl_if.src_strides[0]  = KT*16/8",
        ".cmd_final_wr_stride(`MEM_ADDR_WIDTH'(NT * 2))",
        "psum_wr_lmem_bus_if[p].req_ready", "&& !packetizer_active"],
    "hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv": [
        "assign store_done = (state_q == S_POLL_R_WAIT)",
        "write-through traffic has reached HBM"],
    "hw/rtl/VX_gpu_pkg.sv": [
        "GEMM_RID_T0 = 0", "GEMM_RID_G0 = 3", "GEMM_RID_O = 4",
        "GEMM_RID_T1 = 5", "GEMM_RID_G1 = 8", "GEMM_RID_ZP_CONSUME1 = 20"],
}

def provenance():
    result = {}
    for filename, anchors in ANCHORS.items():
        raw = (ROOT / filename).read_bytes()
        text = raw.decode()
        lines = {}
        for anchor in anchors:
            assert anchor in text, (filename, anchor)
            lines[anchor] = text[:text.index(anchor)].count("\n") + 1
        result[filename] = {"sha256": hashlib.sha256(raw).hexdigest(), "anchors": lines}
    return result

def regions(qdir):
    quant = KT * ceildiv(NT, QBLK) * 2 if qdir else ceildiv(KT, QBLK) * NT * 2
    sizes = [("I", MT * KT * 2), ("W", KT * ceildiv(NT, 2)), ("SC", quant), ("ZP", quant)]
    result = {}
    cursor = 0
    for name, size in sizes:
        for bank in range(2):
            cursor = ceildiv(cursor, 64) * 64
            result[f"{name}{bank}"] = [cursor, cursor + size]
            cursor += ceildiv(size, 64) * 64
    for name, size in [("OBUF", MT * NT * 2), ("PBUF", MT * NT * 4)]:
        cursor = ceildiv(cursor, 64) * 64
        result[name] = [cursor, cursor + size]
        cursor += ceildiv(size, 64) * 64
    intervals = sorted(result.values())
    assert all(a[1] <= b[0] for a, b in zip(intervals, intervals[1:]))
    assert cursor == 0x2d000
    return result

def stream(m, k, n, mxu, qdir, wtrans):
    assert mxu in (16, 32) and k % mxu == 0
    rr = regions(qdir)
    commands = []
    d = 0
    owner = 0
    for nt in range(ceildiv(n, NT)):
        for mt in range(ceildiv(m, MT)):
            owner += 1
            rows, cols = min(MT, m - mt * MT), min(NT, n - nt * NT)
            for kt in range(ceildiv(k, KT)):
                ck = min(KT, k - kt * KT)
                bank, generation = d % 2, d // 2 + 1
                for kb in range(ck // mxu):
                    for nb in range(ceildiv(cols, mxu)):
                        k0, n0 = kb * mxu, nb * mxu
                        global_k = kt * KT + k0
                        c = dict(ordinal=len(commands), work_seq=d * (KT // mxu) * (NT // mxu)
                                 + kb * ceildiv(cols, mxu) + nb + 1,
                                 owner=owner, dma_tile=d, mt=mt, nt=nt, kt=kt, kb=kb, nb=nb,
                                 source_bank=bank, source_generation=generation,
                                 rows=rows, columns=min(mxu, cols - n0), global_k=global_k,
                                 accumulate=global_k != 0, last_k=global_k + mxu >= k)
                        c["terminal"] = c["last_k"] and nb + 1 == ceildiv(cols, mxu)
                        c["input_base"] = rr[f"I{bank}"][0] + k0 * 2
                        c["psum_base"] = rr["PBUF"][0] + n0 * MT * 4
                        c["final_base"] = rr["OBUF"][0] + n0 * 2
                        c["weight_base"] = rr[f"W{bank}"][0] + (n0 * (KT // 2) + k0 // 2
                                                                             if wtrans else k0 * (NT // 2) + n0 // 2)
                        qoffset = k0 * ceildiv(NT, QBLK) * 2 + (n0 // QBLK) * 2 if qdir else (k0 // QBLK) * NT * 2 + n0 * 2
                        c["scale_base"] = rr[f"SC{bank}"][0] + qoffset
                        c["zero_base"] = rr[f"ZP{bank}"][0] + qoffset
                        c["admission_wait"] = {"rid": 4, "target": owner - 1}
                        c["completion"] = {"rid": 8 if c["terminal"] else 3, "increment": 1,
                                             "event": "tile_final_write_fence" if c["terminal"] else "registered_ingress"}
                        def contained(region, base, stride, row_count, width):
                            lo, hi = rr[region]
                            assert lo <= base and base + (row_count - 1) * stride + width <= hi
                        contained(f"I{bank}", c["input_base"], KT * 2, rows, mxu * 2)
                        contained("PBUF", c["psum_base"], mxu * 4, rows, mxu * 4)
                        contained("OBUF", c["final_base"], NT * 2, rows, mxu * 2)
                        contained(f"W{bank}", c["weight_base"], (KT if wtrans else NT) // 2, mxu, mxu // 2)
                        for name, field in [("SC", "scale_base"), ("ZP", "zero_base")]:
                            contained(f"{name}{bank}", c[field], ceildiv(NT, QBLK) * 2 if qdir else NT * 2,
                                      mxu if qdir else ceildiv(mxu, QBLK),
                                      ceildiv(mxu, QBLK) * 2 if qdir else mxu * 2)
                        commands.append(c)
                d += 1
    per_slice = defaultdict(list)
    for c in commands:
        per_slice[c["owner"], c["nb"]].append(c["global_k"])
    assert all(values == list(range(0, k, mxu)) for values in per_slice.values())
    assert sum(c["terminal"] for c in commands) == owner
    return commands

class DAG:
    def __init__(self):
        self.parents = defaultdict(set)
        self.kinds = {}

    def add(self, node, kind, *parents):
        self.kinds[node] = kind
        self.parents[node].update(parents)
        for p in parents:
            self.parents[p]
        return node

    def order(self):
        children = defaultdict(list)
        indegree = {v: len(p) for v, p in self.parents.items()}
        for v, parents in self.parents.items():
            for p in parents:
                children[p].append(v)
        ready = [v for v, count in indegree.items() if not count]
        heapq.heapify(ready)
        result = []
        while ready:
            node = heapq.heappop(ready)
            result.append(node)
            for child in children[node]:
                indegree[child] -= 1
                if not indegree[child]:
                    heapq.heappush(ready, child)
        assert len(result) == len(indegree), "Cyclic contract"
        assert set(self.kinds) == set(self.parents), "Missing event producer"
        return result

    def schedule(self, order, seed):
        rng = random.Random(seed)
        end = {}
        for node in order:
            delay = rng.randrange(1, 13)
            if self.kinds[node] in ("visible_write", "external_store_done"):
                delay += rng.randrange(1, 1000001)
            end[node] = max((end[p] for p in self.parents[node]), default=0) + delay
        return end

def dependency_graph(commands):
    graph = DAG()
    graph.add("store:0", "initial_store_counter")
    by_dma, by_owner = defaultdict(list), defaultdict(list)
    for c in commands:
        by_dma[c["dma_tile"]].append(c)
        by_owner[c["owner"]].append(c)
    source_checks, admit_checks, writer_checks = [], [], []
    for d, local in by_dma.items():
        waits = [f"source_free:{d-2}"] if d >= 2 else []
        for resource in ("I", "W", "SC", "ZP"):
            graph.add(f"external_load:{d}:{resource}", "load_visible", *waits)
        graph.add(f"tile_ready:{d}", "T_ready", *(f"external_load:{d}:{r}" for r in ("I", "W", "SC", "ZP")))
        joins = []
        for c in local:
            i = c["ordinal"]
            for r in ("I", "W", "SC", "ZP"):
                node = graph.add(f"read:{i}:{r}", "source_read_captured", f"tile_ready:{d}")
                joins.append(node)
        graph.add(f"source_free:{d}", "SRC_FREE_generation_join", *joins)
        if d >= 2:
            source_checks.append((f"source_free:{d-2}", f"external_load:{d}:I"))
    last_writer_consumer, last_slice_write = {}, {}
    for c in commands:
        i, owner = c["ordinal"], c["owner"]
        bank = i % 2
        installs = []
        for r in ("W", "SC", "ZP"):
            deps = [f"read:{i}:{r}"]
            if (r, bank) in last_writer_consumer:
                deps.append(last_writer_consumer[r, bank])
                writer_checks.append((last_writer_consumer[r, bank], f"install:{i}:{r}"))
            installs.append(graph.add(f"install:{i}:{r}", "register_install", *deps))
            last_writer_consumer[r, bank] = f"consume:{i}:{r}"
        graph.add(f"admit:{i}", "input_admission", f"store:{owner-1}", *installs,
                  *([f"ingress:{i-1}"] if i else []))
        graph.add(f"ingress:{i}", "registered_ingress", f"admit:{i}", f"read:{i}:I")
        for r in ("W", "SC", "ZP"):
            graph.add(f"consume:{i}:{r}", "register_consume", f"ingress:{i}")
        if not c["terminal"]:
            graph.add(f"G0:{i}", "ordinary_completion", f"ingress:{i}")
        deps = [f"ingress:{i}"]
        key = owner, c["nb"]
        if key in last_slice_write:
            deps.append(last_slice_write[key])
        graph.add(f"compute:{i}", "compute_result", *deps)
        last_slice_write[key] = graph.add(f"write:{i}", "visible_write", f"compute:{i}")
        admit_checks.append((f"store:{owner-1}", f"admit:{i}"))
    for owner, local in by_owner.items():
        terminal = local[-1]["ordinal"]
        graph.add(f"closed:{owner}", "closed_producer", f"ingress:{terminal}")
        graph.add(f"G1:{owner}", "tile_final_write_fence", f"closed:{owner}",
                  *(f"write:{c['ordinal']}" for c in local))
        graph.add(f"store:{owner}", "external_store_done", f"G1:{owner}")
    order = graph.order()
    schedules = []
    for seed in range(16):
        end = graph.schedule(order, seed)
        for before, after in source_checks + admit_checks + writer_checks:
            assert end[before] < end[after]
        for owner, local in by_owner.items():
            assert max(end[f"write:{c['ordinal']}"] for c in local) < end[f"G1:{owner}"] < end[f"store:{owner}"]
        schedules.append({"seed": seed, "makespan_model_units": max(end.values())})
    # Negative control: a terminal fence waiting on its own STORE creates a cycle.
    graph.parents["G1:1"].add("store:1")
    try:
        graph.order()
    except AssertionError:
        pass
    else:
        raise AssertionError("Self-store dependency was not rejected")
    graph.parents["G1:1"].remove("store:1")
    return dict(nodes=len(graph.parents), edges=sum(map(len, graph.parents.values())),
                owners=len(by_owner), source_generations=len(by_dma),
                schedules=schedules, self_store_cycle_rejected=True,
                scope="Software dependency DAG only; event completion semantics and bounded transport storage are assumptions, not RTL proofs")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-trace", type=Path,
                        help="Optional JSON list of real RTL Input descriptors in canonical fields; exact equality required")
    args = parser.parse_args()
    evidence = dict(source=provenance(), regions={str(q): regions(q) for q in (0, 1)}, cases=[])
    base = None
    for mxu in (16, 32):
        for qdir in (0, 1):
            for wtrans in (0, 1):
                for shape in ((4, 512, 512), (256, 512, 512), (129, 160, 145)):
                    commands = stream(*shape, mxu, qdir, wtrans)
                    evidence["cases"].append(dict(shape=shape, mxu=mxu, qdir=qdir, wtrans=wtrans,
                                                  inputs=len(commands), bounds_and_slice_k_order="PASS"))
                    if mxu == 16 and qdir == wtrans == 0 and shape == (4, 512, 512):
                        base = commands
    assert len(base) == 1024
    middle = base[256:768]
    adjacent = list(zip(middle, middle[1:]))
    eligible = [(a["ordinal"], b["ordinal"]) for a, b in adjacent if a["owner"] == b["owner"] and a["nb"] != b["nb"]]
    excluded = [(a["ordinal"], b["ordinal"]) for a, b in adjacent if (a["ordinal"], b["ordinal"]) not in eligible]
    assert len(adjacent) == 511 and len(eligible) == 510 and excluded == [(511, 512)]
    evidence["window"] = dict(first=256, last=767, adjacent=511, eligible=510, excluded=excluded,
                              required_successful_pairs=255, expected_selected_input_rows=2048)
    evidence["graph"] = dependency_graph(base)
    evidence["resource_mapping"] = {
        "T_ready": {"rids": [0, 5], "target": "source_generation", "producer": "all four actual external operand load completions visible"},
        "installed_W": {"rids": [1, 6], "producer": "actual W install"},
        "installed_SC": {"rids": [11, 13], "producer": "actual scale install"},
        "installed_ZP": {"rids": [12, 14], "producer": "actual zero-point install"},
        "consume_W": {"rids": [15, 16], "producer": "last actual W bank-generation consumer"},
        "consume_SC": {"rids": [17, 18], "producer": "last actual SC bank-generation consumer"},
        "consume_ZP": {"rids": [19, 20], "producer": "last actual ZP bank-generation consumer"},
        "G0": {"rid": 3, "increment": 1, "producer": "ordinary registered ingress completion"},
        "G1_OUTPUT_READY": {"rid": 8, "increment": 1, "producer": "terminal real Input tile-scoped final-write fence"},
        "O_STORE_DONE": {"rid": 4, "increment": 1, "producer": "actual completed external store under proved visibility contract"},
        "SRC_FREE": {"rids": [21, 22], "target": "source_generation", "producer": "join all I/W/SC/ZP captured source responses with no future reads"},
        "ACC_FREE": {"rids": [9, 10], "naive_producer": None, "naive_consumer": None},
    }
    evidence["source_generations"] = [dict(dma_tile=d, bank=d % 2, generation=d // 2 + 1,
        t_rid=5 if d % 2 else 0, source_free_rid=22 if d % 2 else 21,
        previous_generation=d // 2 if d >= 2 else 0,
        joined_reads=sum(c["dma_tile"] == d for c in base) * 4) for d in range(16)]
    evidence["rtl_trace_compared"] = False
    if args.input_trace:
        assert json.loads(args.input_trace.read_text()) == base, "RTL descriptor stream differs from contract"
        evidence["rtl_trace_compared"] = True
    (TASK / "p0-contract-inputs.json").write_text(json.dumps(base, indent=2) + "\n")
    (TASK / "p0-contract-results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"cases": len(evidence["cases"]), "window": evidence["window"],
                      "graph_nodes": evidence["graph"]["nodes"], "graph_edges": evidence["graph"]["edges"],
                      "owners": evidence["graph"]["owners"], "acyclic": True,
                      "rtl_trace_compared": evidence["rtl_trace_compared"]}, indent=2))

if __name__ == "__main__":
    main()

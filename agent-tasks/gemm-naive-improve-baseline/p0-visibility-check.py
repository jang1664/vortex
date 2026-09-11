#!/usr/bin/env python3
"""Read-only strict-preedge retained FSDB audit of naive physical boundaries."""
import argparse
from collections import defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import fsdb_cli
TASK = Path(__file__).resolve().parent
AFU = "/tb_vcs_xrtsim/dut"
CORE = AFU + "/vortex_axi/vortex/g_clusters[0]/cluster/g_sockets[0]/socket/g_cores[0]/core"
NODE = CORE + "/gemm_node_naive"
LOCAL = CORE + "/mem_unit/local_mem"
DMA = CORE + "/u_VX_dma_node/u_dma_unit/g_misaligned/u_impl"

def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1048576), b""):
            digest.update(chunk)
    return digest.hexdigest()

def paths():
    p = {"clk": NODE + "/clk", "reset": NODE + "/reset"}
    for n in ("gemm_wr_lane_pending_r", "gemm_done_drained", "packetizer_command_done",
              "gemm_wr_lane_push", "gemm_wr_lane_pop"):
        p[n] = NODE + "/" + n
    p["store_done"] = NODE + "/u_VX_gemm_dma_ctrl_naive/store_done"
    p["cfg"] = NODE + "/u_VX_gemm_ctrl_naive/cfg_start_fire"
    for n in ("vx_cache_drain", "vx_pending_writes_empty", "ap_done_raw", "ap_done_pending"):
        p[n] = AFU + "/" + n
    for n in ("active_dir", "slot_occupancy_r", "dcache_req_pending_r", "lmem_req_pending_r",
              "src_req_fire", "src_rsp_fire", "dst_req_fire", "rd_state", "wr_state"):
        p["dma_" + n] = DMA + "/" + n
    p["dma_done"] = CORE + "/u_VX_dma_node/done_if/valid"
    for n in ("valid", "ready", "rw", "addr", "data", "byteen"):
        p["bank_" + n] = LOCAL + "/per_bank_req_" + n
    for lane in range(8):
        for n in ("req_valid", "req_ready", "req_data.addr", "req_data.data", "req_data.byteen"):
            p[f"lane{lane}_" + n] = NODE + f"/psum_wr_lmem_bus_if[{lane}]/" + n
    return p

def capture(wave):
    def one(item):
        key, path = item
        r = fsdb_cli.report(str(wave), [path])
        assert r.data_rows, path
        return key, dict(path=path, values=r.data_rows)
    with ThreadPoolExecutor(max_workers=4) as pool:
        return dict(pool.map(one, paths().items()))

def sample(signals):
    positions = {k: 0 for k in signals if k != "clk"}
    values = {k: None for k in positions}
    prev, edge = None, -1
    for time, bit in signals["clk"]["values"]:
        rising = prev == "0" and bit == "1"
        prev = bit
        if not rising:
            continue
        edge += 1
        for key in positions:
            rows, pos = signals[key]["values"], positions[key]
            while pos < len(rows) and int(rows[pos][0]) < int(time):
                values[key] = rows[pos][1]
                pos += 1
            positions[key] = pos
        yield edge, int(time), values

def number(v, key, width=None, index=0):
    raw = v[key]
    if raw is None:
        return None
    if width is not None:
        raw = raw.zfill((index + 1) * width)
        high = len(raw) - index * width
        raw = raw[high-width:high]
    return int(raw, 2) if set(raw) <= {"0", "1"} else None

def audit(signals):
    pending = defaultdict(deque)
    accepted, committed, reads = 0, 0, defaultdict(int)
    latencies, drain_pending, read_violations = [], [], []
    dma_jobs, store_events, afu_events = [], [], []
    request_count = response_count = destination_count = 0
    previous_done = previous_afu = False
    for edge, time, v in sample(signals):
        if number(v, "reset") != 0:
            continue
        active = number(v, "dma_active_dir")
        request_count += number(v, "dma_src_req_fire") == 1
        response_count += number(v, "dma_src_rsp_fire") == 1
        destination_count += number(v, "dma_dst_req_fire") == 1
        for lane in range(8):
            prefix = f"lane{lane}_"
            if number(v, prefix + "req_valid") == number(v, prefix + "req_ready") == 1:
                address = (number(v, prefix + "req_data.addr") & ((1 << 17) - 1)) * 8
                if 0x15000 <= address < 0x2d000:
                    pending[address].append((edge, number(v, prefix + "req_data.data"), number(v, prefix + "req_data.byteen")))
                    accepted += 1
        for bank in range(16):
            if number(v, "bank_valid", 1, bank) == number(v, "bank_ready", 1, bank) == 1:
                address = (number(v, "bank_addr", 13, bank) * 16 + bank) * 8
                if not 0x15000 <= address < 0x2d000:
                    continue
                if number(v, "bank_rw", 1, bank):
                    assert pending[address], ("Bank write without prior node ownership", edge, address)
                    prior, data, mask = pending[address].popleft()
                    assert data == number(v, "bank_data", 64, bank), ("Data mismatch", edge, address)
                    assert mask == number(v, "bank_byteen", 8, bank), ("Mask mismatch", edge, address)
                    latencies.append(edge - prior)
                    committed += 1
                else:
                    region = "OBUF" if address < 0x1d000 else "PBUF"
                    reads[region] += 1
                    if pending[address]:
                        read_violations.append(dict(edge=edge, address=hex(address), pending=len(pending[address])))
        in_flight = sum(map(len, pending.values()))
        if number(v, "gemm_done_drained"):
            drain_pending.append(dict(edge=edge, bank_writes_pending=in_flight))
        done = number(v, "dma_done") == 1
        if done and not previous_done:
            record = dict(edge=edge, store=bool(active), source_requests=request_count,
                          source_responses=response_count, destination_requests=destination_count,
                          slots=number(v, "dma_slot_occupancy_r"),
                          source_request_buffer=number(v, "dma_lmem_req_pending_r"),
                          destination_request_buffer=number(v, "dma_dcache_req_pending_r"))
            assert request_count == response_count, record
            assert record["slots"] == record["source_request_buffer"] == record["destination_request_buffer"] == 0, record
            dma_jobs.append(record)
            request_count = response_count = destination_count = 0
        previous_done = done
        if number(v, "store_done"):
            assert dma_jobs and dma_jobs[-1]["store"], ("Store released without store worker completion", edge)
            assert dma_jobs[-1]["edge"] <= edge
            store_events.append(dict(edge=edge, worker_done_edge=dma_jobs[-1]["edge"], pending_bank_writes=in_flight))
        afu = number(v, "ap_done_raw") == 1
        if afu and not previous_afu:
            assert number(v, "vx_cache_drain") == number(v, "vx_pending_writes_empty") == 1
            afu_events.append(dict(edge=edge, cache_drain=True, axi_pending_empty=True))
        previous_afu = afu
    assert accepted == committed and not any(pending.values())
    assert not read_violations, read_violations[:3]
    assert len(store_events) == 4 and len(drain_pending) == 1024
    stores = [x for x in dma_jobs if x["store"]]
    assert len(stores) == 4 and all(x["source_requests"] == x["source_responses"] for x in stores)
    return dict(accepted_node_writes=accepted, committed_bank_writes=committed,
                observed_node_to_bank_cycles=dict(min=min(latencies), max=max(latencies)),
                compute_drain_events=len(drain_pending),
                compute_drain_events_with_uncommitted_bank_writes=sum(x["bank_writes_pending"] > 0 for x in drain_pending),
                max_uncommitted_at_compute_drain=max(x["bank_writes_pending"] for x in drain_pending),
                local_reads=dict(reads), read_overtake_violations=read_violations,
                store_workers=stores, store_done_events=store_events, afu_done_events=afu_events,
                scope="One retained corrected naive M4/QCOL/WTRANS0 invocation only; no general stalled-overlap proof")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--run", type=Path, default=TASK / "p0-baseline/naive-m4-retry1")
    args = p.parse_args()
    wave_sha = sha(args.run / "wave.fsdb")
    snapshot = TASK / "p0-visibility-signals.json"
    if snapshot.exists():
        saved = json.loads(snapshot.read_text())
        assert saved["wave"] == str((args.run / "wave.fsdb").resolve())
        assert saved["wave_sha256"] == wave_sha, "Wave changed since capture"
        signals = saved["signals"]
    else:
        signals = capture(args.run / "wave.fsdb")
        snapshot.write_text(json.dumps(dict(wave=str((args.run / "wave.fsdb").resolve()), wave_sha256=wave_sha, signals=signals)) + "\n")
    result = audit(signals)
    result["wave"] = str((args.run / "wave.fsdb").resolve())
    result["wave_sha256"] = wave_sha
    manifest = json.loads((args.run / "manifest.json").read_text())
    result["source_config_manifest"] = str((args.run / "manifest.json").resolve())
    result["source_config_manifest_sha256"] = sha(args.run / "manifest.json")
    result["source_hashes"] = {}
    for filename in (
        "hw/rtl/core/gemm/VX_gemm_dma_ctrl_naive.sv", "hw/rtl/core/gemm/VX_gemm_node_naive.sv",
        "hw/rtl/core/gemm/VX_gemm_acc_lmem.sv", "hw/rtl/core/VX_dma_unit_misal.sv",
        "hw/rtl/core/VX_job_dispatcher.sv", "hw/rtl/core/VX_job_desc_mmio_regs.sv",
        "hw/rtl/core/VX_mem_unit.sv", "hw/rtl/mem/VX_local_mem.sv",
        "hw/rtl/libs/VX_sp_ram.sv", "hw/rtl/afu/xrt/VX_afu_wrap.sv",
        "hw/rtl/libs/VX_axi_write_drain.sv", "hw/rtl/cache/VX_cache_bank.sv"):
        digest = sha(ROOT / filename)
        assert digest == manifest["source_hashes"][filename], filename
        result["source_hashes"][filename] = digest
    (TASK / "p0-visibility-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()

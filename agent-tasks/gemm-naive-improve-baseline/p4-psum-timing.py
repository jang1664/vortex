#!/usr/bin/env python3
"""Measure tagged PSUM transaction stages in a completed actual naive capture."""
import argparse, importlib.util, json, re, statistics
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("base",HERE/"p0-install-check.py")
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
p=argparse.ArgumentParser();p.add_argument("run",type=Path);args=p.parse_args()
out=args.run/"psum-timing";out.mkdir(exist_ok=False)
m=json.loads((args.run/"manifest.json").read_text());assert m["passed"] and not m["source_changes_during_run"]
paths={"clk":"clk","reset":"reset"}
for key in ("txn_accept_valid","txn_accept_tag","txn_accept_rd_en","txn_accept_wr_en","txn_accept_rd_addr","txn_accept_wr_addr","txn_retire_valid","txn_retire_tag","wr_req_valid","wr_req_ready","wr_req_tag","rd_rsp_valid","rd_rsp_ready","rd_rsp_tag"):
    paths[key]="gemm_acc_if/"+key
for key in ("rd_lmem_fire","rsp_lmem_fire","rd_issue_slot","rsp_slot","read_slot_tag","rd_issue_candidate_raw_block"):
    paths[key]="u_VX_gemm_acc_lmem/"+key

def read(item):
    key,path=item;r=base.fsdb_cli.report(str(args.run/"wave.fsdb"),[base.NODE+"/"+path]);assert r.data_rows,path
    return key,dict(path=path,unit=r.time_unit,values=[[int(t),int(v,2) if re.fullmatch("[01]+",v) else None] for t,v in r.data_rows])
with ThreadPoolExecutor(max_workers=4) as pool: signals=dict(pool.map(read,paths.items()))
(out/"signals.json").write_text(json.dumps(signals))
tx={};last_writer={};slot_owner={};raw_cycles=0
for edge,time,v in base.rising_samples(signals):
    if v["reset"]!=0:continue
    if v["txn_accept_valid"]:
        tag=v["txn_accept_tag"];assert tag not in tx
        t=dict(tag=tag,accept=edge,rd_en=v["txn_accept_rd_en"],wr_en=v["txn_accept_wr_en"],rd_addr=v["txn_accept_rd_addr"],wr_addr=v["txn_accept_wr_addr"])
        if t["rd_en"]:t["producer"]=last_writer.get(t["rd_addr"])
        tx[tag]=t
        if t["wr_en"]:last_writer[t["wr_addr"]]=tag
    if v["wr_req_valid"] and v["wr_req_ready"]:
        t=tx[v["wr_req_tag"]];assert "write" not in t;t["write"]=edge
    if v["rd_lmem_fire"]:
        slot=v["rd_issue_slot"];tag=(v["read_slot_tag"]>>(32*slot))&0xffffffff
        t=tx[tag];assert t["rd_en"] and "read_issue" not in t
        t["read_issue"]=edge;slot_owner[slot]=tag
    if v["rsp_lmem_fire"]:
        t=tx[slot_owner[v["rsp_slot"]]];assert "read_response" not in t;t["read_response"]=edge
    if v["rd_rsp_valid"] and v["rd_rsp_ready"]:
        t=tx[v["rd_rsp_tag"]];assert "core_response" not in t;t["core_response"]=edge
    if v["txn_retire_valid"]:
        t=tx[v["txn_retire_tag"]];assert "retire" not in t;t["retire"]=edge
    raw_cycles+=v["rd_issue_candidate_raw_block"]==1
reads=[t for t in tx.values() if t["rd_en"]]
assert tx and reads
for t in tx.values():
    assert t["accept"]<=t["write"]<=t["retire"]
    if t["rd_en"]:
        assert t["accept"]<=t["read_issue"]<=t["read_response"]<=t["core_response"]<=t["write"]
        assert t["producer"] is not None
        producer=tx[t["producer"]]
        assert producer["accept"]<t["accept"] and producer["write"]<=t["read_issue"] and producer["retire"]<=t["read_issue"]
def stats(values):return dict(count=len(values),minimum=min(values),median=statistics.median(values),maximum=max(values),mean=statistics.mean(values))
metrics={
"accepted_to_write":stats([t["write"]-t["accept"] for t in tx.values()]),
"read_round_trip":stats([t["read_response"]-t["read_issue"] for t in reads]),
"response_to_core":stats([t["core_response"]-t["read_response"] for t in reads]),
"core_response_to_write":stats([t["write"]-t["core_response"] for t in reads]),
"producer_write_to_read_issue":stats([t["read_issue"]-tx[t["producer"]]["write"] for t in reads]),
"same_address_accept_revisit":stats([t["accept"]-tx[t["producer"]]["accept"] for t in reads])}
(out/"transactions.json").write_text(json.dumps(list(tx.values()),indent=2)+"\n")
result=dict(status="pass",transactions=len(tx),reads=len(reads),metrics=metrics,raw_candidate_block_cycles=raw_cycles,
 scope="Actual tagged acceptance, producer write acceptance, ordered safe wide read, assembled LMEM response, core response and retirement. Write acceptance is not a physical bank-commit timestamp; per-bank visibility needs separate proof.")
(out/"result.json").write_text(json.dumps(result,indent=2)+"\n");print(json.dumps(result,indent=2))

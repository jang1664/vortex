#!/usr/bin/env python3
"""Independent generation-zero QCOL accepted S/Z payload oracle for metadata node."""
import argparse, importlib.util, json, re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location("base",HERE/"p0-install-check.py");base=importlib.util.module_from_spec(sp);sp.loader.exec_module(base)
p=argparse.ArgumentParser();p.add_argument("run",type=Path);args=p.parse_args()
out=args.run/"install-oracle";out.mkdir(exist_ok=False)
m=json.loads((args.run/"manifest.json").read_text());assert m["passed"] and not m["source_changes_during_run"]
assert [m[k] for k in ("m","k","n","qdir","wtrans")]==[4,512,512,0,0]
commands=json.loads((args.run/"service/commands.json").read_text())
service=json.loads((args.run/"service/result.json").read_text());assert service["wave_sha256"]==base.sha(args.run/"wave.fsdb")
paths={"clk":"clk","reset":"reset","cfg":"cfg_start_fire","base_lo":"issue_if/regs[11]","base_hi":"issue_if/regs[12]"}
for e,label in enumerate(("s","z")):
    prefix=f"quant_executor/g_engine[{e}]/executor/"
    for key in ("cmd_valid","cmd_ready","done_valid","done_ready","done_work_seq"):
        paths[label+"_"+key]=prefix+key
    for key in ("work_seq","rs2_data","flags","naive_source_buffer","naive_source_generation"):
        paths[label+"_cmd_"+key]=prefix+"cmd."+key
    for key in ("install_id_o","install_bank_o"):
        paths[label+"_"+key]=prefix+"dma/"+key
    bus=f"quant_gemm_bus_if[{e}]/"
    for key in ("req_valid","req_ready","req_data.data","req_data.byteen"):
        paths[label+"_"+key.replace(".","_")]=bus+key
    paths[label+"_write"]="gemm_unit_v2_if/"+("scale" if e==0 else "zero_point")+"_register_write"
    paths[label+"_bank"]="u_VX_gemm_compute_core/"+("scale_reg_idx" if e==0 else "zp_reg_idx")
def read(item):
    key,path=item;r=base.fsdb_cli.report(str(args.run/"wave.fsdb"),[base.NODE+"/"+path]);assert r.data_rows,path
    return key,dict(path=path,unit=r.time_unit,values=[[int(t),int(v,2) if re.fullmatch("[01]+",v) else None] for t,v in r.data_rows])
with ThreadPoolExecutor(max_workers=4) as pool:signals=dict(pool.map(read,paths.items()))
(out/"signals.json").write_text(json.dumps(signals))
records=[];accepted={x:{} for x in ("s","z")};done={x:[] for x in accepted};origin=None
for edge,time,v in base.rising_samples(signals):
    if v["reset"]!=0:continue
    if v["cfg"]:assert origin is None;origin=v["base_lo"]+(v["base_hi"]<<32)
    for label in ("s","z"):
        q=lambda key:v[label+"_"+key]
        if q("cmd_valid") and q("cmd_ready"):
            seq=q("cmd_work_seq");assert seq not in accepted[label]
            descriptor=commands[seq-1]["descriptor"];assert descriptor["work_seq"]==seq
            offset=descriptor["scale_base" if label=="s" else "zero_base"]
            assert q("cmd_rs2_data")==origin+offset
            assert q("cmd_naive_source_buffer")==descriptor["source_bank"] and q("cmd_naive_source_generation")==descriptor["source_generation"]
            accepted[label][seq]=dict(edge=edge,bank=(q("cmd_flags")>>1)&1,descriptor=descriptor)
        if q("write"):
            seq=q("install_id_o");owner=accepted[label][seq];d=owner["descriptor"]
            assert q("req_valid")==q("req_ready")==1
            assert q("bank")==q("install_bank_o")==owner["bank"]
            assert q("req_data_byteen")==0xffffffff
            payload=q("req_data_data");assert payload is not None
            records.append(dict(resource=label,generation=seq,edge=edge,row=d["global_k"]//32,col=d["nt"]*128+d["nb"]*16,
                                actual=[(payload>>(16*i))&65535 for i in range(16)]))
        if q("done_valid") and q("done_ready"):done[label].append(q("done_work_seq"))
assert len(records)==2048
for label in ("s","z"):
    assert list(accepted[label])==done[label]==list(range(1,1025))
    assert [r["generation"] for r in records if r["resource"]==label]==list(range(1,1025))
errors=base.mismatches(records);assert not errors,errors[:3]
result=dict(status="pass",accepted_installs=len(records),checked_fp16_or_int16_words=32768,
            fault_controls=base.fault_controls(records),lane_fault_census=base.lane_fault_census(records),
            scope="Actual accepted S/Z installs, independent canonical logical data and command identity. Negative controls mutate captured payload copies; no live RTL fault injection or QROW proof.")
(out/"records.json").write_text(json.dumps(records,indent=2)+"\n")
(out/"result.json").write_text(json.dumps(result,indent=2)+"\n");print(json.dumps(result,indent=2))

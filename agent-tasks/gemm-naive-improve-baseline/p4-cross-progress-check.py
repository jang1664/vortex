#!/usr/bin/env python3
"""Check finite writer hold and opposite S/Z progress in an actual full-core run."""
import argparse, importlib.util, json,re
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
HERE=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location("base",HERE/"p0-install-check.py");base=importlib.util.module_from_spec(sp);sp.loader.exec_module(base)
p=argparse.ArgumentParser();p.add_argument("run",type=Path);p.add_argument("--blocked",choices=("s","z"),required=True);args=p.parse_args()
out=args.run/"cross-progress";out.mkdir(exist_ok=False)
m=json.loads((args.run/"manifest.json").read_text());assert m["passed"] and not m["source_changes_during_run"]
assert [m[k] for k in ("m","k","n","wtrans","repeat")]==[3,64,64,0,1]
assert m["directed_stimulus"]["sha256"]==base.sha(args.run/"stimulus.tcl")
blocked=0 if args.blocked=="s" else 1
assert f"g_engine[{blocked}]" in (args.run/"stimulus.tcl").read_text()
paths={"clk":"clk","reset":"reset","cfg":"cfg_start_fire","job_done":"done_if/valid"}
for e in (0,1):
 pre=f"quant_executor/g_engine[{e}]/executor/"
 for key in ("writer_release","source_done_valid","source_done_work_seq","done_valid","done_ready","done_work_seq"):
  paths[f"e{e}_"+key]=pre+key
 paths[f"e{e}_writer_gate"]=pre+"dma/writer_released_r"
 for key in ("req_valid","req_ready"):
  paths[f"e{e}_"+key]=f"quant_gemm_bus_if[{e}]/"+key

def read(item):
 key,path=item;r=base.fsdb_cli.report(str(args.run/"wave.fsdb"),[base.NODE+"/"+path]);assert r.data_rows,path
 return key,dict(path=path,unit=r.time_unit,values=[[int(t),int(v,2) if re.fullmatch("[01]+",v) else None] for t,v in r.data_rows])
with ThreadPoolExecutor(max_workers=4) as pool:signals=dict(pool.map(read,paths.items()))
assert all(v["unit"]=="1ps" for v in signals.values())
(out/"signals.json").write_text(json.dumps(signals))
events={e:dict(installs=[],done=[],sources=[]) for e in (0,1)};cfg=None;completion=None;hold_cycles=0
for edge,time,v in base.rising_samples(signals):
 if v["reset"]!=0:continue
 if v["cfg"]:assert cfg is None;cfg=edge
 if cfg is None:continue
 if time<100000000:
  hold_cycles+=1;assert v[f"e{blocked}_writer_gate"]==0
 for e in (0,1):
  prefix=f"e{e}_"
  if v[prefix+"req_valid"] and v[prefix+"req_ready"]:events[e]["installs"].append(dict(edge=edge,time=time))
  if v[prefix+"done_valid"] and v[prefix+"done_ready"]:events[e]["done"].append(dict(edge=edge,time=time,id=v[prefix+"done_work_seq"]))
  if v[prefix+"source_done_valid"]:events[e]["sources"].append(dict(edge=edge,time=time,id=v[prefix+"source_done_work_seq"]))
 if v["job_done"]:completion=edge
assert hold_cycles>100 and completion is not None
assert not [x for x in events[blocked]["installs"] if x["time"]<100000000]
other=1-blocked;early=[x for x in events[other]["done"] if x["time"]<100000000]
assert early, "Opposite engine did not independently install/complete while writer blocked"
for e in (0,1):
 assert [x["id"] for x in events[e]["done"]]==list(range(1,17))
 assert sorted(x["id"] for x in events[e]["sources"])==list(range(1,17))
 assert len(events[e]["installs"])==16*(16 if m["qdir"] else 1)
result=dict(status="pass",blocked=args.blocked,qdir=m["qdir"],hold_cycles_after_cfg=hold_cycles,
 opposite_completions_during_hold=early,events=events,completion_edge=completion,
 scope="Actual controller, independent S/Z DMA, shared physical LMEM and GEMM installs; finite UCLI writer-release block followed by successful numerical completion. No unbounded stall or arbitrary-fairness claim.")
(out/"result.json").write_text(json.dumps(result,indent=2)+"\n");print(json.dumps({k:result[k] for k in ("status","blocked","qdir","hold_cycles_after_cfg","opposite_completions_during_hold")},indent=2))

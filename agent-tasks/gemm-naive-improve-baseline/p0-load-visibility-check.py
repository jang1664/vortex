#!/usr/bin/env python3
"""Read-only extension of the retained M4 FSDB visibility snapshot."""
import importlib.util,json
from pathlib import Path
TASK=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("base",TASK/"p0-visibility-check.py")
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
saved=json.loads((TASK/"p0-visibility-signals.json").read_text())
wave=Path(saved["wave"]);assert b.sha(wave)==saved["wave_sha256"]
extra_path=TASK/"p0-load-visibility-signals.json"
paths={"load_issue":b.DMA+"/gen_dst_fire", "load_mask":b.DMA+"/gen_lmem_wr_byteen",
       "bank_tag":b.LOCAL+"/per_bank_req_tag"}
if extra_path.exists():
 extra=json.loads(extra_path.read_text());assert extra["wave_sha256"]==saved["wave_sha256"]
else:
 signals={}
 for key,path in paths.items():
  report=b.fsdb_cli.report(str(wave),[path]);assert report.data_rows,path
  signals[key]=dict(path=path,values=report.data_rows)
 extra=dict(wave_sha256=saved["wave_sha256"],signals=signals)
 extra_path.write_text(json.dumps(extra)+"\n")
signals={**saved["signals"],**extra["signals"]}
pending=reserved=committed=0;last_done=False;jobs=[];last_load_commit=None
waiting_job=None; classified_dma_commits=0
for edge,time,v in b.sample(signals):
 if b.number(v,"reset")!=0:continue
 reserve=0
 if b.number(v,"dma_active_dir")==0 and b.number(v,"load_issue")==1:
  mask=b.number(v,"load_mask");assert mask is not None
  reserve=sum(bool((mask>>(8*i))&255) for i in range(16))
 commit=0
 for bank in range(16):
  if b.number(v,"bank_valid",1,bank)==b.number(v,"bank_ready",1,bank)==b.number(v,"bank_rw",1,bank)==1:
   address=(b.number(v,"bank_addr",13,bank)*16+bank)*8
   tag=b.number(v,"bank_tag",12,bank)
   assert tag is not None
   is_dma=((tag>>10)&1)==1 and ((tag>>8)&3)==1
   assert is_dma == (address<0x15000), (edge,bank,address,tag)
   if is_dma:
    commit+=1;last_load_commit=edge;classified_dma_commits+=1
 pending+=reserve-commit;reserved+=reserve;committed+=commit
 assert pending>=0,(edge,pending,reserve,commit)
 if waiting_job is not None and pending==0:
  waiting_job["all_load_words_committed_edge"]=edge
  waiting_job["cycles_after_worker_done"]=edge-waiting_job["edge"]
  waiting_job=None
 done=b.number(v,"dma_done")==1
 if done and not last_done:
  jobs.append(dict(edge=edge,store=bool(b.number(v,"dma_active_dir")),pending_load_words=pending,
                   reserved_words=reserved,committed_words=committed,last_load_commit=last_load_commit))
  if not jobs[-1]["store"]:
   if pending: waiting_job=jobs[-1]
   else:
    jobs[-1]["all_load_words_committed_edge"]=edge
    jobs[-1]["cycles_after_worker_done"]=0
 last_done=done
assert pending==0
out=dict(wave=str(wave),wave_sha256=saved["wave_sha256"],reserved_load_words=reserved,
         committed_load_words=committed,classified_dma_commits=classified_dma_commits,worker_done_records=jobs,
         load_done_with_pending=sum(not x["store"] and x["pending_load_words"]!=0 for x in jobs),
         scope="Current M4 snapshot; DMA route-tag bank classification cross-checked with source regions; not arbitrary-stall proof",
         source_snapshot_sha256=b.sha(TASK/"p0-visibility-signals.json"), extra_snapshot_sha256=b.sha(extra_path),
         source_config_manifest_sha256=b.sha(wave.parent/"manifest.json"))
(TASK/"p0-load-visibility-results.json").write_text(json.dumps(out,indent=2)+"\n")
print('Loads with pending bank words at worker done:',out['load_done_with_pending'])
print('Reserved/committed load words:',reserved,committed)
print('Representative load records:',[x for x in jobs if not x['store']][:4])

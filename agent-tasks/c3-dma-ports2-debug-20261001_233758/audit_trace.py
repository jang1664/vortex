from pathlib import Path
from collections import defaultdict
import json,re
record=json.loads((Path(__file__).parent/'experiment.json').read_text())
reports=[]
for name in ['ports2_original','ports2_reorder']:
 p=Path(record['output'])/name/'gemm_naive/simv.log'
 events=defaultdict(list)
 for line in p.open(errors='replace'):
  m=re.search(r'DMA_CMP (\w+) .*? t=(\d+) (.*)',line)
  if not m:continue
  d=dict(re.findall(r'(\w+)=([^ ]+)',m[3]));d['time']=int(m[2]);d['raw']=line.rstrip();events[m[1]].append(d)
 expected=[[] for i in range(16)]
 for e in events['LM_REQ']:
  for lane in range(16):
   mask=(int(e['byteen'],16)>>(lane*8))&255
   if mask:
    expected[lane].append((int(e['byte_addr'],16)//8+lane,(int(e['data'],16)>>(lane*64))&((1<<64)-1),mask,int(e['write'])))
 errors=[];checked=0
 for lane in range(16):
  actual=[e for e in events['LM_LANE_REQ'] if int(e['lane'])==lane]
  for exp,e in zip(expected[lane],actual):
   got=(int(e['word_addr'],16),int(e['data'],16),int(e['byteen'],16),int(e['write']))
   checked+=1
   if exp!=got:errors.append(dict(lane=lane,expected=exp,actual=got))
 done=[e for e in events['DONE'] if int(e['pending'])!=0 or int(e['reserved'])!=0]
 report=dict(name=name,events={k:len(v) for k,v in events.items()},lmem_lane_events_checked=checked,lmem_lane_mapping_errors=errors[:10],lmem_lane_mapping_error_count=len(errors),done_with_outstanding_writes=done,tag_mismatch_count=len(events['TAG_MISMATCH']),first_tag_mismatches=events['TAG_MISMATCH'][:4])
 reports.append(report)
(Path(__file__).parent/'trace_audit.json').write_text(json.dumps(reports,indent=2)+'\n')
for r in reports:print({k:v for k,v in r.items() if k not in ['first_tag_mismatches','done_with_outstanding_writes','lmem_lane_mapping_errors']})

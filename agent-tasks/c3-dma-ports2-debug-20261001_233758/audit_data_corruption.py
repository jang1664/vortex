from pathlib import Path
import json,re,collections
out=Path(__file__).parent
outputs={};inputs={}
for name in ['ports2_original','ports2_reorder']:
 output={};inp={};desc=0
 for line in (out/name/'gemm_naive/simv.log').open(errors='replace'):
  if 'DMA_CMP DESC ' in line:desc+=1
  kind=None
  if 'DMA_CMP DC_REQ ' in line and 'write=1 ' in line:kind='output'
  if desc==1 and 'DMA_CMP LM_REQ ' in line and 'write=1 ' in line:kind='input'
  if kind is None:continue
  d=dict(re.findall(r'(\w+)=([^ ]+)',line));addr=int(d['byte_addr'],16)
  data=int(d['data'],16).to_bytes(128,'little');mask=int(d['byteen'],16)
  for i,b in enumerate(data):
   if not ((mask>>i)&1):continue
   if kind=='input':inp[addr+i]=b
   elif 0x2a000<=addr+i<0x3a000:output[addr+i]=b
 outputs[name]=output;inputs[name]=inp
assert all(len(v)==65536 for v in outputs.values())
diffs=[]
for i in range(128*256):
 addr=0x2a000+2*i
 a=bytes(outputs['ports2_original'][addr+j] for j in range(2))
 b=bytes(outputs['ports2_reorder'][addr+j] for j in range(2))
 if a!=b:diffs.append((i//256,i%256))
inputdiff=[a for a,v in inputs['ports2_original'].items() if v!=inputs['ports2_reorder'].get(a)]
report={'output_bytes_covered':{k:len(v) for k,v in outputs.items()},
 'output_fp16_bitwise_differences':len(diffs),'rows':dict(collections.Counter(r for r,c in diffs)),
 'column_min':min(c for r,c in diffs),'column_max':max(c for r,c in diffs),
 'first_input_descriptor_changed_bytes':len(inputdiff),
 'input_rows':dict(collections.Counter((a-0x1ffc00000)//256 for a in inputdiff))}
(out/'data_corruption_audit.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))

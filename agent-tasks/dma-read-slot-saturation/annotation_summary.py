"""Derive review metrics from the FSDB transition caches made by analyze.py."""
import json
from pathlib import Path
import numpy as np
TASK=Path(__file__).resolve().parent
summary={}
for case in ['improve16-m4','naive32-m4','improve16-m256','naive32-m256']:
 p=TASK/'captures'/case;d=json.loads((p/'result.json').read_text());cfg=d['boundaries']['cfg'];end=d['boundaries']['done'];times=np.arange(cfg,end)*10000+5000
 def sample(name):
  a=np.load(p/(name+'.npz'));idx=np.searchsorted(a['t'],times,side='left')-1
  assert np.all(idx>=0)
  v=a['v'][idx];assert np.all(v>=0);return v
 dma=sample('dma_busy')==1
 weight=(sample('prealigner_out_valid')==1)&(sample('pre_meta_valid_out')==1)&(sample('weight_ready')==0)
 psum=(sample('post_txn_count')>0)&(sample('post_head_psum_ready')==0)&(sample('post_head_scaled_ready')==1)
 if psum.any():psum&=(sample('acc_result_credit')>0)|(sample('acc_result_commit')==1)
 iv=sample('req_valid')==1;ir=sample('req_ready')==1
 assert int(weight.sum())==d['weight_wait']
 assert int(psum.sum())==d['psum_only_wait']
 def longest(mask):
  diff=np.diff(np.r_[False,mask,False].astype(int));s=np.flatnonzero(diff==1);e=np.flatnonzero(diff==-1)
  if not len(s):return None
  j=np.argmax(e-s);return dict(start=int(cfg+s[j]),end_exclusive=int(cfg+e[j]),cycles=int(e[j]-s[j]))
 r=dict(boundaries=d['boundaries'],phases=d['phases'],phase_activity=d['phase_activity'],weight_wait=int(weight.sum()),weight_wait_dma_idle=int((weight&~dma).sum()),psum_only_wait=int(psum.sum()),psum_only_wait_dma_idle=int((psum&~dma).sum()),weight_and_psum_wait=int((weight&psum).sum()),longest_input_stream=longest(iv&ir))
 if case.startswith('improve'):
  units=sum((sample(f'unit{i}_dma_is_active')==1)&(sample(f'unit{i}_active_dir')==0) for i in range(8))
  r['eight_channels_read_active_cycles']=int((units==8).sum());r['longest_eight_channels_read_active']=longest(units==8)
 summary[case]=r
out=TASK/'annotations/summary.json';out.write_text(json.dumps(summary,indent=2)+'\n')
print(out)

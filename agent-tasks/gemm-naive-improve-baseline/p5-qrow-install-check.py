#!/usr/bin/env python3
"""Current independent S/Z engines: exact QROW masked install oracle."""
import argparse,importlib.util,json,hashlib,re
from pathlib import Path
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('qrow',HERE/'p0-install-qrow.py');qrow=importlib.util.module_from_spec(spec);spec.loader.exec_module(qrow)
base=qrow.base
p=argparse.ArgumentParser();p.add_argument('run',type=Path);p.add_argument('--mxu',type=int,choices=[16,32],required=True);a=p.parse_args()
out=a.run/'qrow-install-oracle';out.mkdir(exist_ok=False)
m=json.loads((a.run/'manifest.json').read_text());assert m['passed'] and not m['source_changes_during_run']
assert m['tagged'] and m['repeat']>=2 and (m['k'],m['n'],m['qdir'])==(64,64,1) and 1<=m['m']<=a.mxu
width=2*a.mxu;count=(64//a.mxu)**2
paths={k:base.NODE+'/'+v for k,v in {'clk':'clk','reset':'reset','cfg':'cfg_start_fire','qdir':'issue_if/regs[39]','wtrans':'issue_if/regs[38]'}.items()}
for e,label in enumerate(('s','z')):
 pre=base.NODE+f'/quant_executor/g_engine[{e}]/executor/'
 for key in ('cmd_valid','cmd_ready','done_valid','done_ready','done_work_seq'):
  paths[label+'_'+key]=pre+key
 for key in ('work_seq','rs1_data','flags','bound','stride','groups_eff'):
  paths[label+'_cmd_'+key]=pre+'cmd.'+key
 for key in ('install_id_o','install_segment_o','install_bank_o'):
  paths[label+'_'+key]=pre+'dma/'+key
 for key in ('req_valid','req_ready','req_data.data','req_data.byteen','req_data.addr'):
  paths[label+'_'+key.replace('.','_')]=base.NODE+f'/quant_gemm_bus_if[{e}]/'+key
 paths[label+'_write']=base.NODE+'/gemm_unit_v2_if/'+('scale' if e==0 else 'zero_point')+'_register_write'
 paths[label+'_bank']=base.NODE+'/u_VX_gemm_compute_core/'+('scale_reg_idx' if e==0 else 'zp_reg_idx')
signals=qrow.capture(a.run/'wave.fsdb',paths);(out/'signals.json').write_text(json.dumps(signals))
records=[];owners={};done=set();jobs=0;generation=-1;resetting=False
for edge,time,v in base.rising_samples(signals):
 if v['reset']==1:
  if not resetting:
   assert all(o['segments']==a.mxu for o in owners.values())
   owners={};resetting=True
  continue
 if v['reset']!=0:continue
 resetting=False
 if v['cfg']==1:
  generation=jobs;jobs+=1;assert (v['qdir'],v['wtrans'])==(1,m['wtrans'])
 for label in ('s','z'):
  q=lambda key:v[label+'_'+key]
  if q('cmd_valid')==q('cmd_ready')==1:
   seq=q('cmd_work_seq');assert 1<=seq<=count and (label,seq) not in owners
   assert (q('cmd_bound'),q('cmd_stride'),q('cmd_groups_eff'))==(a.mxu,8,2)
   assert q('cmd_flags')&4
   mk,mn=divmod(seq-1,64//a.mxu)
   owners[label,seq]=dict(row=mk*a.mxu,col=mn*a.mxu//32,dest=q('cmd_rs1_data'),bank=(q('cmd_flags')>>1)&1,segments=0)
  if q('write')==1:
   seq=q('install_id_o');o=owners[label,seq];segment=o['segments']
   assert segment<a.mxu and segment==q('install_segment_o')
   destination=o['dest']+segment*2;mask=3<<(destination%width)
   assert q('req_valid')==q('req_ready')==1
   assert q('bank')==q('install_bank_o')==o['bank']
   assert q('req_data_byteen')==mask and q('req_data_addr')==destination//width*width
   records.append(dict(resource=label,host_generation=generation,work_seq=seq,segment=segment,row=o['row']+segment,col=o['col'],byteen=mask,actual=qrow.words(q('req_data_data'),a.mxu),edge=edge))
   o['segments']+=1
  if q('done_valid')==q('done_ready')==1:
   seq=q('done_work_seq');key=(generation,label,seq)
   assert key not in done and owners[label,seq]['segments']==a.mxu;done.add(key)
assert jobs==m['repeat'] and len(records)==jobs*2*count*a.mxu
assert done=={(g,l,s) for g in range(jobs) for l in ('s','z') for s in range(1,count+1)}
assert not qrow.errors(records),qrow.errors(records)[:3]
lookup={(r['host_generation'],r['resource'],r['work_seq'],r['segment']):r for r in records}
controls=[]
for label in ('s','z'):
 target=lookup[1,label,1,5];old=lookup[0,label,1,5];active=(target['byteen'].bit_length()-1)//2
 for name,lo,length in [('element',active,1),('mapped_8B_lane',active//4*4,4),('whole_install_beat',0,a.mxu)]:
  changed=dict(target,actual=list(target['actual']));changed['actual'][lo:lo+length]=old['actual'][lo:lo+length]
  assert len(qrow.errors([changed]))==1;controls.append(dict(resource=label,fault=name,detected=True))
stale=0
for g in range(1,jobs):
 for label in ('s','z'):
  for seq in range(1,count+1):
   changed=[dict(lookup[g,label,seq,s],actual=list(lookup[g-1,label,seq,s]['actual'])) for s in range(a.mxu)]
   assert len(qrow.errors(changed))==a.mxu;stale+=1
result=dict(status='pass',mxu=a.mxu,wtrans=m['wtrans'],jobs=jobs,accepted_masked_installs=len(records),owned_command_completions=len(done),mismatches=0,representative_controls=controls,previous_job_stale_commands_detected=stale,wave_sha256=base.sha(a.run/'wave.fsdb'),manifest_sha256=base.sha(a.run/'manifest.json'),scope='Actual accepted masked register installs and owned completion IDs. Negative controls modify captured install payload copies; mapped lane chunks are not physical source-response correlation or live injection.')
(out/'records.json').write_text(json.dumps(records,indent=2)+'\n');(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

#!/usr/bin/env python3
"""Relate physical DMA frontend completions to owned metadata LOAD/T-ready."""
import importlib.util,json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
TASK=Path(__file__).resolve().parent
sp=importlib.util.spec_from_file_location('b',TASK/'p4-visibility-check.py');b=importlib.util.module_from_spec(sp);sp.loader.exec_module(b)
run=TASK/'p4-regression/naive-m4-final1';physical=json.loads((run/'physical-visibility-signals.json').read_text());fence=json.loads((run/'load-fence/signals.json').read_text());wave=Path(physical['wave']);assert physical['wave_sha256']==fence['wave_sha256']==b.sha(wave)
assert json.loads((run/'load-fence/result.json').read_text())['status']=='pass'
out=run/'load-readiness';out.mkdir(exist_ok=False)
paths={}
for k in ('cmd_valid','cmd_ready','done_valid','done_ready','done_work_seq'):paths[k]=b.NODE+'/dma_executor/'+k
for k in ('instr','work_seq','rd','naive_source_buffer','naive_source_generation'):paths['cmd_'+k]=b.NODE+'/dma_executor/cmd.'+k
for bank,rid in enumerate((0,5)):paths['t'+str(bank)]=b.NODE+f'/control/controller/sync_q[{rid}]'
def read(item):
 k,p=item;r=b.fsdb_cli.report(str(wave),[p]);assert r.data_rows,p
 return k,dict(path=p,values=r.data_rows)
with ThreadPoolExecutor(max_workers=4) as pool:extra=dict(pool.map(read,paths.items()))
(out/'signals.json').write_text(json.dumps(dict(wave_sha256=physical['wave_sha256'],signals=extra)))
signals={**physical['signals'],**fence['signals'],**extra}
owner=None;expected_t=[0,0];members={};commands=[];publishes=[];active=False
for edge,time,v in b.sample(signals):
 n=lambda k:b.number(v,k)
 if n('reset')!=0:continue
 if n('cfg'):active=True
 if not active:continue
 assert [n('t0'),n('t1')]==expected_t,(edge,[n('t0'),n('t1')],expected_t)
 if n('cmd_valid')==n('cmd_ready')==1:
  assert owner is None
  owner=dict(issue_edge=edge,opcode=n('cmd_instr')&15,seq=n('cmd_work_seq'),member=n('cmd_rd')&3,bank=n('cmd_naive_source_buffer'),generation=n('cmd_naive_source_generation'),frontend_edge=None)
  assert owner['opcode'] in (1,2)
 if n('front_done')==n('front_ready')==1:
  assert owner is not None and owner['frontend_edge'] is None
  owner['frontend_edge']=edge
 if n('done_valid')==n('done_ready')==1:
  assert owner is not None and n('done_work_seq')==owner['seq'] and owner['frontend_edge'] is not None and owner['frontend_edge']<edge
  owner['completion_edge']=edge;commands.append(owner)
  if owner['opcode']==1:
   bank=owner['bank'];gen=owner['generation'];key=(bank,gen)
   seen=members.setdefault(key,set());assert owner['member'] not in seen;seen.add(owner['member'])
   if seen=={0,1,2,3}:
    assert gen==expected_t[bank]+1
    expected_t[bank]=gen;publishes.append(dict(bank=bank,generation=gen,completion_edge=edge,visible_edge=edge+1))
  owner=None
assert owner is None and len(commands)==68 and len(publishes)==16 and expected_t==[8,8]
assert all(x=={0,1,2,3} for x in members.values())
result=dict(status='pass',commands=len(commands),load_commands=sum(c['opcode']==1 for c in commands),store_commands=sum(c['opcode']==2 for c in commands),four_member_t_publications=len(publishes),final_t=expected_t,publication_records=publishes,command_records=commands,wave_sha256=physical['wave_sha256'],scope='Actual current M4 owned external command completions each follow one fenced physical DMA frontend handshake. Every T0/T1 generation advances only after distinct I/W/S/Z LOAD completions. No T-ready values taken as the expected oracle.')
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if not k.endswith('_records')},indent=2))

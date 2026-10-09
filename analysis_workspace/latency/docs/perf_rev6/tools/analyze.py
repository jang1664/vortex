#!/usr/bin/env python3
"""Stream simulator evidence; distinguish observed bandwidth from DMA endpoint counts."""
import csv,json,math,re,statistics
from pathlib import Path
OUT=Path(__file__).resolve().parents[1]
def ratio(a,b):return a/b if b else 0.0
def parse(path):
    groups={}
    with path.open() as stream:
        for line in stream:
            if not line.startswith('FINE '):continue
            _,group,rest=line.rstrip().split(' ',2)
            vals={k:int(v) for k,v in re.findall(r'([a-z_]+)=(\d+)',rest)}
            if group=='TMEM':
                bank=re.search(r'g_bank\[(\d+)\]',rest)
                if bank:vals['bank']=int(bank.group(1))
            groups.setdefault(group,[]).append(vals)
    return groups
def stats(windows,hz):
    if not windows:return {}
    values=[(w['rd_bytes']+w['wr_bytes'])*hz/w['cycles']/1e9 for w in windows]
    return dict(count=len(values),min=min(values),max=max(values),avg=statistics.mean(values),median=statistics.median(values),zero_pct=100*sum(v==0 for v in values)/len(values))
def main():
    data=[]
    for status in sorted((OUT/'raw').glob('*.json')):
        if status.name.endswith('.model.json'):continue
        rec=json.loads(status.read_text())
        if not isinstance(rec,dict) or rec.get('status')!='passed' or 'case' not in rec:continue
        key=status.stem
        g=parse(OUT/'raw'/f'{key}.simv.log')
        model=json.loads((OUT/'raw'/f'{key}.model.json').read_text())
        hz=model['logic_freq_hz']
        core=g['core'][0];node=g['gemm_node'][0];mx=g['gemm_unit'][0];axi=g['AXI'][0];ga=g['GEMM_AXI'][0]
        case=rec['case'];useful=2*case['m']*case['n']*case['k'];peak=2*int(model['defines']['MXU_ROW'])*int(model['defines']['MXU_COL'])
        row=dict(key=key,candidate=rec['candidate'],case=case,raw=g,model_sha=model['sha256'],logic_hz=hz,
            gemm_cycles=node['total_cycles'],core_cycles=core['busy_cycles'],pipeline_cycles=g['CORE'][0]['pipeline_cycles'],
            input_fire=mx['input_fire'],gemm_us=node['total_cycles']/hz*1e6,core_us=core['busy_cycles']/hz*1e6,
            input_util_pct=100*ratio(mx['input_fire'],node['total_cycles']),pipeline_util_pct=100*ratio(g['CORE'][0]['pipeline_cycles'],node['total_cycles']),
            useful_gflops=ratio(useful*hz,node['total_cycles'])/1e9,effective_peak_pct=100*ratio(useful,peak*node['total_cycles']),
            useful_flops=useful,ops_per_input_fire=ratio(useful,mx['input_fire']),
            hbm_core_gbps=ratio((axi['rd_bytes']+axi['wr_bytes'])*hz,axi['cycles'])/1e9,
            hbm_core_rd_bytes=axi['rd_bytes'],hbm_core_wr_bytes=axi['wr_bytes'],
            hbm_gemm_gbps=ratio((ga['rd_bytes']+ga['wr_bytes'])*hz,ga['cycles'])/1e9,
            hbm_gemm_rd_bytes=ga['rd_bytes'],hbm_gemm_wr_bytes=ga['wr_bytes'],
            core_windows=stats(g.get('WINDOW',[]),hz),gemm_windows=stats(g.get('GEMM_WINDOW',[]),hz),
            lmem_physical=g['LMEM_PHYSICAL'][0],lmem_perf=g['lmem'][0],
            tmem={k:sum(x[k] for x in g.get('TMEM',[])) for k in ['rd_bytes','wr_bytes','collision_cycles','collision_denied','blocked']})
        row.update(weight_fire=mx['weight_fire'],
            logical_m=case.get('logical_m',case['m']),logical_n=case.get('logical_n',case['n']),logical_k=case.get('logical_k',case['k']),
            argument_m=case['m'],argument_n=case['n'],argument_k=case['k'],
            dma_union_active_cycles=core['dma_union_active_cycles'],
            overlap_dma_pipeline_cycles=core['overlap_dma_mxu'],
            dma_pipeline_overlap_pct=100*ratio(core['overlap_dma_mxu'],core['dma_union_active_cycles']))
        assert core['overlap_dma_mxu'] <= core['dma_union_active_cycles']
        if 'b64_' in case['id']:
            assert peak==512
            assert case['m']==64 and case['q']==32 and case['t']==0 and case['d']==0
            expected_inputs=case['m']*math.ceil(case['n']/16)*math.ceil(case['k']/16)
            assert mx['input_fire']==expected_inputs,(key,'batch64 invocation geometry')
            headers=[line for line in (OUT/'raw'/f'{key}.log').open() if line.startswith('M=')]
            assert len(headers)==1
            for name,value in [('M',case['m']),('N',case['n']),('K',case['k']),('QBLK',case['q']),('WTRANS',case['t']),('QDIR',case['d']),('REPS',1)]:
                match=re.search(r'\b'+name+r'=(\d+)',headers[0])
                assert match and int(match[1])==value,(key,'host geometry',name)
        if case['id'].endswith('_m4'):
            assert case['m']==4 and case['q']==32 and case['t']==0 and case['d']==0
            assert peak==512
            # For these aligned, single-core shapes the accepted input rows
            # distinguish real M=4 from execution rounded to M=8 or M=16.
            assert mx['input_fire']==4*(case['n']//16)*(case['k']//16), (key,'real M=4 input count')
            headers=[line for line in (OUT/'raw'/f'{key}.log').open() if line.startswith('M=')]
            assert len(headers)==1 and re.match(r'M=4(?:\s|,)',headers[0]), (key,'host M=4')
            for name, value in [('N',case['n']),('K',case['k']),('QBLK',32),('WTRANS',0),('QDIR',0)]:
                match=re.search(r'\b'+name+r'=(\d+)',headers[0])
                assert match and int(match[1])==value, (key,'host geometry',name)
        for main,window,tail in [('AXI','WINDOW','WINDOW_TAIL'),('GEMM_AXI','GEMM_WINDOW','GEMM_WINDOW_TAIL')]:
            parts=g.get(window,[])+g.get(tail,[])
            for field in ['cycles','rd_bytes','wr_bytes']:
                assert sum(x[field] for x in parts)==g[main][0][field],(key,main,field)
        assert ga['cycles']==node['total_cycles'],(key,'GEMM phase cycle gate mismatch')
        assert axi['cycles']==core['busy_cycles'],(key,'core gate mismatch')
        if rec['candidate']=='c3':
            assert row['lmem_physical']['rd_bytes']==row['lmem_perf']['reads']*row['lmem_physical']['bytes_per_word'],(key,'LMEM read accounting')
            assert row['lmem_physical']['wr_bytes']<=row['lmem_perf']['writes']*row['lmem_physical']['bytes_per_word'],(key,'LMEM write enables')
        else:
            local_reads=sum(g[name][0]['rd_bytes'] for name in ['lmem_dma_input','lmem_dma_weight','lmem_dma_sz'])
            assert row['tmem']['rd_bytes']==local_reads+g['hbm_dma.aggregate'][0]['wr_bytes'],(key,'TMEM read endpoint accounting')
            assert row['tmem']['wr_bytes']==g['hbm_dma.aggregate'][0]['rd_bytes']+g['lmem_dma_output'][0]['wr_bytes'],(key,'TMEM write endpoint accounting')
        assert mx['input_fire']>0 and useful>0
        data.append(row)
    (OUT/'measurements.json').write_text(json.dumps(data,indent=2))
    columns=['key','gemm_cycles','core_cycles','gemm_us','core_us','input_fire','input_util_pct','pipeline_util_pct','useful_gflops','effective_peak_pct','hbm_core_gbps','hbm_gemm_gbps','hbm_core_rd_bytes','hbm_core_wr_bytes','hbm_gemm_rd_bytes','hbm_gemm_wr_bytes','weight_fire','dma_union_active_cycles','overlap_dma_pipeline_cycles','dma_pipeline_overlap_pct','logical_m','logical_n','logical_k','argument_m','argument_n','argument_k']
    with (OUT/'measurements.csv').open('w') as stream:
        writer=csv.DictWriter(stream,fieldnames=columns,lineterminator='\n');writer.writeheader();writer.writerows({k:r[k] for k in columns} for r in data)
    print('parsed and validated',len(data),'cases')
    for r in data:print(r['key'],r['gemm_cycles'],round(r['input_util_pct'],2),round(r['hbm_core_gbps'],3),r['lmem_perf']['bank_stalls'],r['tmem']['collision_denied'])
if __name__=='__main__':main()

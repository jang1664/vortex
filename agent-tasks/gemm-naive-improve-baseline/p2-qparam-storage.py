#!/usr/bin/env python3
"""Static elaborated per-engine declarations, not synthesized mapped cost."""
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[2]
TASK = Path(__file__).resolve().parent
BUILD = ROOT / 'build_p0_storage_rev3'

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def inventory(path):
    xml = ET.parse(path).getroot()
    net = xml.find('netlist')
    types = {x.get('id'):x for x in net.find('typetable')}
    modules = {x.get('name'):x for x in net.findall('module')}
    files = {x.get('id'):x.get('filename') for x in xml.find('files')}
    def number(node):
        m = re.fullmatch(r"(\d+)'s?([hbd])([0-9a-fA-F]+)",node.get('name'))
        assert m
        return int(m[3], {'h':16,'b':2,'d':10}[m[2]])
    def width(key):
        t = types[key]
        if t.tag == 'basicdtype':
            return abs(int(t.get('left','0'))-int(t.get('right','0')))+1
        if t.tag in ('packarraydtype','unpackarraydtype'):
            r=t.find('range')
            return (abs(number(r[0])-number(r[1]))+1)*width(t.get('sub_dtype_id'))
        if t.tag in ('refdtype','enumdtype'):
            return width(t.get('sub_dtype_id'))
        if t.tag == 'structdtype':
            return sum(width(x.get('sub_dtype_id')) for x in t)
        raise AssertionError(ET.tostring(t))
    rows=[]
    def visit(cell):
        mod=modules.get(cell.get('submodname'))
        if mod is None:
            assert cell.get('submodname').startswith('VX_mem_bus_if')
            return
        written=set()
        for assignment in mod.findall('.//assigndly'):
            lhs=assignment[-1]
            while lhs.tag in ('sel','arraysel'): lhs=lhs[0]
            assert lhs.tag=='varref'
            written.add(lhs.get('name'))
        variables={}
        for var in mod.findall('.//var'):
            if var.get('name') in written:
                assert var.get('name') not in variables
                variables[var.get('name')]=var
        assert variables.keys()==written
        for name,var in variables.items():
            bits=width(var.get('dtype_id'))
            hier=cell.get('hier')+'.'+name
            payload=0
            # Only the lane response RAM and FIFO RAM/head can carry operands.
            if '.response_ram.' in hier and name in ('ram','rdata_r'):
                payload=bits
            if '.response_fifo.' in hier and name in ('ram','data_out_r'):
                dtype=types[var.get('dtype_id')]
                if dtype.tag in ('unpackarraydtype','packarraydtype') and name=='ram':
                    elem=width(dtype.get('sub_dtype_id'))
                    payload=(bits//elem)*64
                else:
                    payload=64
            loc=var.get('loc','').split(',')
            rows.append(dict(hierarchy=hier,name=name,bits=bits,payload_bits=payload,
                             metadata_bits=bits-payload,source=files.get(loc[0]),line=loc[1] if len(loc)>1 else None))
        for child in cell.findall('cell'): visit(child)
    visit(xml.find('cells/cell'))
    return rows

def main():
    assert (BUILD/'config.mk').exists()
    config=subprocess.check_output(['bash','-c', 'source configs/naive_gemm_th16_tcol16_hwexp_dcache_sxbar_f16.sh; printf \'%s\' "$CONFIGS"'],cwd=ROOT,text=True)
    for mxu in (16,32):
        selected=[x for x in shlex.split(config) if not any(x.startswith('-D'+k+'=') for k in ('MXU_ROW','MXU_COL','MXU_COL_TILE','LMEM_NUM_PORTS'))]
        selected += [f'-DMXU_ROW={mxu}',f'-DMXU_COL={mxu}',f'-DMXU_COL_TILE={mxu}',f'-DLMEM_NUM_PORTS={mxu}']
        path=BUILD/f'p2-qparam-storage{mxu}.xml'
        command=['verilator','--xml-only','--xml-output',str(path),'--top-module','p2_qparam_storage_probe','-Wno-fatal','-DSYNTHESIS','-DNDEBUG','-DXLEN_64',*selected,
                 '+incdir+'+str(ROOT/'hw/rtl'),'+incdir+'+str(ROOT/'hw/rtl/core/gemm')]
        for d in ('libs','core/gemm','mem'): command += ['-y',str(ROOT/'hw/rtl'/d)]
        command += [str(ROOT/'hw/rtl/VX_gpu_pkg.sv'),str(TASK/'p2-qparam-storage-probe.sv')]
        with (BUILD/f'p2-qparam-storage{mxu}.log').open('w') as log:
            subprocess.run(command,cwd=BUILD,stdout=log,stderr=subprocess.STDOUT,check=True)
        rows=inventory(path)
        totals={k:sum(r[k] for r in rows) for k in ('bits','payload_bits','metadata_bits')}
        assert totals['payload_bits']==448*8*(mxu//16),totals
        assert totals['metadata_bits'] <= (6996 if mxu==16 else 10280),totals
        files={x.get('filename') for x in ET.parse(path).getroot().find('files') if str(ROOT/'hw/rtl') in x.get('filename','')}
        result=dict(mxu=mxu,status='pass',totals=totals,records=rows,command=command,source_hashes={f:sha(f) for f in files},
                    xml_sha256=sha(path),script_sha256=sha(__file__),probe_sha256=sha(TASK/'p2-qparam-storage-probe.sv'),
                    scope='one independent engine, generated sequential declarations, not optimized synthesis cost',
                    perf_added_bits=0)
        (TASK/f'p2-qparam-storage{mxu}.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(dict(mxu=mxu,**totals)))
if __name__=='__main__': main()

"""Prove improve preprocessed RTL identity against the pre-edit snapshot."""
import concurrent.futures,hashlib,json,re,shlex,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
NEW=ROOT/'hw/rtl';OLD=TASK/'identity/before-rtl';OUT=TASK/'identity';OUT.mkdir(parents=True,exist_ok=True)
baseline_files=json.loads((TASK/'baseline.json').read_text())['files']
missing=[f for f in baseline_files if not (TASK/'before'/f).is_file()]
if missing:raise RuntimeError('Missing pre-edit RTL snapshots; refusing current-vs-current identity: '+', '.join(missing))
# Overlay baseline copies onto the current unchanged tree. Includes resolve within
# the overlay, so dependent sources also see the original package/header.
for src in NEW.rglob('*'):
 if src.is_file():
  dst=OLD/src.relative_to(NEW);dst.parent.mkdir(parents=True,exist_ok=True)
  baseline=TASK/'before/hw/rtl'/src.relative_to(NEW)
  target=baseline if baseline.exists() else src
  if not dst.exists():dst.symlink_to(target.resolve())
flags=shlex.split(subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',str(ROOT/'agent-tasks/dma-read-slot-saturation/improve/depth16.sh')],cwd=ROOT,text=True))
scope={Path(x) for x in ['.','libs','interfaces','core','core/gemm','mem','cache','fpu','verification','afu/xrt']}
files=sorted({p.relative_to(tree) for tree in [OLD,NEW] for p in tree.rglob('*') if p.name != 'VX_mem_bus_split.sv' and p.suffix in ('.sv','.v') and p.parent.relative_to(tree) in scope})
def preprocess(tree,rel,ndebug):
 path=tree/rel
 if not path.exists():return ''
 dirs=sorted({p.parent for ext in ['*.vh','*.svh'] for p in tree.rglob(ext)} | {ROOT/'third_party/axi/include',ROOT/'third_party/cvfpu/src/common_cells/include',ROOT/'third_party/cvfpu/src',ROOT/'third_party/axi/src',ROOT/'hw/dpi'})
 args=['verilator','-E','-DXLEN_64','-DPERF_ENABLE','-DGEMM_LATENCY_OBSERVER','-DSIMULATION','-DSV_DPI','-DVCS','-DNOXRT','-DASSERTS_OFF',*(['-DNDEBUG'] if ndebug else []),*flags,*[f'+incdir+{d}' for d in dirs],str(path)]
 p=subprocess.run(args,cwd=ROOT,text=True,capture_output=True)
 if p.returncode:raise RuntimeError(str(rel)+' '+p.stderr[-1500:])
 text='\n'.join(line.strip() for line in p.stdout.splitlines() if line.strip() and not line.lstrip().startswith('`line'))
 # These macros derive private instance identifiers from __LINE__. Rename
 # bijectively by first occurrence, preserving all references and counts.
 names={};counts={}
 def rename(match):
  token=match[0];kind=match[1]
  if token not in names:
   counts[kind]=counts.get(kind,0)+1;names[token]=f'__{kind}CANON{counts[kind]}'
  return names[token]
 return re.sub(r'\b__(buffer_ex|pop_count_ex)[0-9]+\b',rename,text)
def check(item):
 rel,ndebug=item;a=preprocess(OLD,rel,ndebug);b=preprocess(NEW,rel,ndebug)
 if a!=b:
  key=str(rel).replace('/','__')+f'.ndebug{int(ndebug)}';(OUT/(key+'.before')).write_text(a);(OUT/(key+'.after')).write_text(b)
 return {'file':str(rel),'ndebug':ndebug,'identical':a==b,'sha256_before':hashlib.sha256(a.encode()).hexdigest(),'sha256_after':hashlib.sha256(b.encode()).hexdigest()}
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(check,[(r,n) for r in files for n in [False,True]]))
 (OUT/'result.json').write_text(json.dumps(results,indent=2)+'\n')
 bad=[x for x in results if not x['identical']];print(json.dumps(dict(checks=len(results),different=bad)),flush=True)
 assert not bad,'Improve preprocessing changed'

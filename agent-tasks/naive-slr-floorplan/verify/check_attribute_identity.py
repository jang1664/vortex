#!/usr/bin/env python3
"""Check selected RTL while allowing only the added naive weight-TX preservation attribute."""
import concurrent.futures,hashlib,importlib.util,json,shlex,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; TASK=ROOT/'agent-tasks/naive-slr-floorplan'
OUT=TASK/'runs/attribute-preserve-v1'; NEW=ROOT/'build_naive_slr_attribute_source/hw/rtl'
spec=importlib.util.spec_from_file_location('identity',TASK/'check_identity.py');identity=importlib.util.module_from_spec(spec);spec.loader.exec_module(identity)
anchor='if (1) begin : g_slr_mxu_weight_tx\n'
added=anchor+'(* DONT_TOUCH = "TRUE" *)\n'
for backend in ['improve','naive']:
 old=TASK/'snapshot/rtl' if backend=='improve' else ROOT/'build_naive_slr_candidate_source/hw/rtl'
 config=ROOT/f'build_naive_slr_attribute_source/configs/verify_{backend}_on.sh'
 identity.flags=shlex.split(subprocess.check_output(['bash','-c','source "$1"; printf "%s" "$CONFIGS"','bash',str(config)],text=True))
 files=sorted({p.relative_to(tree) for tree in [old,NEW] for p in tree.rglob('*') if p.suffix in ('.sv','.v') and p.parent.relative_to(tree) in identity.scope})
 def check(item):
  rel,ndebug,slr=item;a=identity.preprocess(old,rel,ndebug,slr);raw=identity.preprocess(NEW,rel,ndebug,slr)
  count=raw.count(added) if backend=='naive' else 0
  expected=int(backend=='naive' and slr and str(rel)=='core/gemm/VX_gemm_compute_core.sv')
  assert count==expected,(str(rel),ndebug,slr,count,expected)
  b=raw.replace(added,anchor) if backend=='naive' else raw
  same=a==b
  if not same:
   prefix=OUT/f"{backend}-{str(rel).replace('/','__')}-{ndebug}-{slr}"
   prefix.with_suffix('.before').write_text(a);prefix.with_suffix('.after').write_text(b)
  return dict(file=str(rel),ndebug=ndebug,slr=slr,equivalent=same,removed_exact_attribute_count=count,sha256_before=hashlib.sha256(a.encode()).hexdigest(),sha256_after_raw=hashlib.sha256(raw.encode()).hexdigest(),sha256_after_comparison=hashlib.sha256(b.encode()).hexdigest())
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: results=list(pool.map(check,[(p,n,s) for p in files for n in [False,True] for s in [False,True]]))
 passed=len(results)==1148 and all(r['equivalent'] for r in results)
 record=dict(passed=passed,checks=len(results),backend=backend,before=str(old),after=str(NEW),removed_attribute=added if backend=='naive' else None,removed_attribute_total=sum(r['removed_exact_attribute_count'] for r in results),normalization='Existing check_identity.py preprocessor line-directive removal and bijective generated private identifier canonicalization; naive additionally removes only the exact weight-TX attribute anchor above.',results=results)
 (OUT/f'{backend}-identity.json').write_text(json.dumps(record,indent=2)+'\n')
 print(backend,passed,len(results),record['removed_attribute_total'],flush=True)
 assert passed

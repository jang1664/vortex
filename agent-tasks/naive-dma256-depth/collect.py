#!/usr/bin/env python3
"""Classify completed immutable simulation manifests, including detached runs."""
import hashlib,importlib.util,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];TASK=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('verify_rtl',ROOT/'tools/verify_rtl.py');verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)
def collect(out):
 mp=out/'manifest.json'
 if not mp.exists():return None
 m=json.loads(mp.read_text())
 if m.get('state')!='finished':return None
 w=(out/'wrapper.log').read_text(errors='replace');s=(out/'simv.log').read_text(errors='replace') if (out/'simv.log').exists() else '';combined=w+'\n'+s
 variant=out.parent.name;case=out.name
 gemm=[int(x) for x in re.findall(r'^GEMM_LATENCY_DONE .*?\bL_gemm=(\d+)',s,re.M)];core=[int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),',w,re.M)]
 changed=m.get('source_changes_during_run');frozen=not changed;artifact_details=None
 ap=out/'running_artifacts.json'
 if changed and ap.exists():
  a=json.loads(ap.read_text());bad=[f for f,h in a['artifacts'].items() if not Path(f).exists() or hashlib.sha256(Path(f).read_bytes()).hexdigest()!=h]
  allowed={'hw/rtl/mem/VX_mem_bus_split.sv','hw/rtl/VX_config.vh','hw/rtl/core/VX_mem_unit.sv','hw/rtl/core/VX_dma_node.sv','configs/naive_th16_tcol16_m16_L32_bigmem_all_bram_D256.sh'}
  frozen=not bad and set(changed)<=allowed and a['configs']==m['configs']
  artifact_details=dict(changed_artifacts=bad,count=len(a['artifacts']),capture=a['captured'],allowed_post_launch_source_edits=sorted(allowed))
 r=dict(variant=variant,case=case,wrapper_returncode=m.get('returncode'),gemm_cycles=gemm,core_cycles=core,configs=m['configs'],source_changes=changed,artifact_identity=artifact_details,provenance_valid=frozen,strict_failure=verify.has_strict_failure(combined),tool_pass=verify.check_pass(combined))
 r['passed']=m.get('returncode')==0 and r['tool_pass'] and not r['strict_failure'] and frozen and len(gemm)==len(core)==1
 if variant in ['l16','l32','improve']:
  prior=next(x for x in json.loads((TASK/'baseline_attestation.json').read_text()) if x['variant']==variant and x['case']==case)
  r['baseline_identity']=not prior['pre_edit_differences'] and prior['passed'] and gemm==prior['gemm'] and core==prior['core'];r['passed'] &= r['baseline_identity']
 (out/'result.json').write_text(json.dumps(r,indent=2)+'\n');return r
if __name__=='__main__':
 for out in (list(map(Path,sys.argv[1:])) if len(sys.argv)>1 else sorted((TASK/'runs').glob('*/*'))):
  if not out.is_dir():continue
  r=collect(out)
  if r:print(r['variant'],r['case'],r['passed'],r['gemm_cycles'],r['core_cycles'],flush=True)

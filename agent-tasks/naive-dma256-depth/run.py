#!/usr/bin/env python3
"""Run frozen, isolated xrt-vcs-sim depth experiments and classify evidence."""
import argparse, hashlib, importlib.util, json, os, re, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
TASK=Path(__file__).resolve().parent
RUNNER=ROOT/'agent-tasks/gemm-naive-improve-baseline/run_baseline.py'
spec=importlib.util.spec_from_file_location('verify_rtl',ROOT/'tools/verify_rtl.py')
verify=importlib.util.module_from_spec(spec);spec.loader.exec_module(verify)

def main():
 p=argparse.ArgumentParser();p.add_argument('variants',nargs='+');p.add_argument('--cases',nargs='+',default=['m4','m256']);p.add_argument('--keep-going',action='store_true');a=p.parse_args();failed=False
 for variant in a.variants:
  config=TASK/'configs'/f'{variant}.sh'
  build=ROOT/f'build_naive_dma256_{variant}_vcs'
  build.mkdir(exist_ok=True)
  if not (build/'config.mk').exists():
   with (build/'configure.log').open('w') as log:
    subprocess.run(['../configure','--xlen=64','--tooldir=/opt/vortex',f'--prefix={Path.home()}/tools/vortex'],cwd=build,stdout=log,stderr=subprocess.STDOUT,check=True)
  for case in a.cases:
   out=TASK/'runs'/variant/case
   if (out/'result.json').exists():
    if not json.loads((out/'result.json').read_text())['passed']:raise RuntimeError(f'Previous failure: {out}')
    continue
   if out.exists():raise RuntimeError(f'Incomplete evidence: {out}')
   out.parent.mkdir(parents=True,exist_ok=True)
   m={'m4':4,'m256':256}[case]
   cmd=[sys.executable,str(RUNNER),'improve' if variant=='improve' else 'naive','--m',str(m),'--k','512','--n','512','--qdir','0','--wtrans','0','--repeat','1','--timeout','7200','--build',str(build),'--output',str(out),'--config',str(config)]
   if case==a.cases[0]:cmd.append('--rebuild')
   print(f'START {variant} {case}',flush=True)
   with (out.parent/f'{case}_runner.log').open('w') as log:rc=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT).returncode
   if not (out/'manifest.json').exists():raise RuntimeError(f'No manifest: {out}')
   manifest=json.loads((out/'manifest.json').read_text())
   wrapper=(out/'wrapper.log').read_text(errors='replace');sim=(out/'simv.log').read_text(errors='replace') if (out/'simv.log').exists() else ''
   combined=wrapper+'\n'+sim
   gemm=[int(x) for x in re.findall(r'^GEMM_LATENCY_DONE .*?\bL_gemm=(\d+)',sim,re.M)]
   core=[int(x) for x in re.findall(r'^PERF: instrs=\d+, cycles=(\d+),',wrapper,re.M)]
   result=dict(variant=variant,case=case,returncode=rc,wrapper_returncode=manifest.get('returncode'),gemm_cycles=gemm,core_cycles=core,source_changes=manifest.get('source_changes_during_run'),strict_failure=verify.has_strict_failure(combined),tool_pass=verify.check_pass(combined),configs=manifest['configs'])
   result['passed']=rc==0 and manifest.get('returncode')==0 and result['tool_pass'] and not result['strict_failure'] and result['source_changes']==[] and len(gemm)==len(core)==1
   if variant in ['l16','l32','improve']:
    prior=next(x for x in json.loads((TASK/'baseline_attestation.json').read_text()) if x['variant']==variant and x['case']==case)
    result['baseline_identity']=not prior['pre_edit_differences'] and prior['passed'] and gemm==prior['gemm'] and core==prior['core']
    result['passed'] &= result['baseline_identity']
   if not result['passed']:result['errors']=verify.extract_errors(combined)
   (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
   print(json.dumps(result),flush=True)
   if not result['passed']:
    failed=True
    if not a.keep_going:return 1
    break
 return int(failed)
if __name__=='__main__':sys.exit(main())

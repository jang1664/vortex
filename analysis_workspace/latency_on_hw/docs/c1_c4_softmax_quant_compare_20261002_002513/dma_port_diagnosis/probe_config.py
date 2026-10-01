from pathlib import Path
import json,os,subprocess,shlex,re
r=json.loads(Path('/tmp/vortex_vector_compare_active.json').read_text());src=Path(r['source']);out=Path(r['output'])/'dma_port_diagnosis';env=os.environ.copy();env.update(PATH='/usr/bin:'+env['PATH'],CC='/usr/bin/gcc',CXX='/usr/bin/g++')
results=[]
for cfg in r['configs']:
 folder=Path(cfg['build'])/'config_probe';folder.mkdir(exist_ok=True)
 raw=subprocess.check_output(['bash','-c','source "$1"; printf "%s\n" "$CONFIGS"','bash',str(src/'configs'/cfg['config'])],text=True)
 command=['vcs','-full64','-sverilog','-timescale=1ns/1ps','+define+SIMULATION','+define+VCS','+define+NDEBUG','+define+XLEN_64','+incdir+'+str(src/'hw/rtl')]+[t.replace('-D','+define+',1) for t in shlex.split(raw)]+[str(src/'hw/rtl/VX_gpu_pkg.sv'),str(out/'tb_config_probe.sv'),'-top','tb_config_probe']
 with (out/(cfg['key']+'_probe_compile.log')).open('w') as f:subprocess.run(command,cwd=folder,env=env,stdout=f,stderr=subprocess.STDOUT,check=True)
 run=subprocess.run(['./simv'],cwd=folder,env=env,text=True,capture_output=True,check=True);(out/(cfg['key']+'_probe_sim.log')).write_text(run.stdout+run.stderr)
 match=re.search('CONFIG_PROBE (.*)',run.stdout);assert match,run.stdout
 values=dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',match[1]))
 result=dict(candidate=cfg['key'],values=values);results.append(result);print(result,flush=True)
(out/'config_probe_results.json').write_text(json.dumps(results,indent=2)+'\n')

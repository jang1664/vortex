import json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from fsdb_cli.backends import run_fsdbdebug
from fsdb_cli.parsers import parse_tree_vars
name=sys.argv[1]; out=ROOT/'docs/hw_analysis/improve_vs_naive/fsdb_m4'/name
stack=[]; paths=[]
for line in run_fsdbdebug(['-tree'],str(out/'m4.fsdb')).splitlines():
 s=line.strip()
 if s.startswith('Scope:'):stack.append(s.split()[2])
 elif s=='Upscope:':stack.pop()
 elif s.startswith('Var:'):
  vs=parse_tree_vars(s)
  if not vs:continue
  v=vs[0]; scope='/'.join(stack)
  if 'core' in stack or len(stack)<=2:
   if re.search(r'perf|fire|busy|valid|ready|state|active|cmd|count|stall|idle|wait|bound|credit',v.name,re.I):
    paths.append('/'+scope+'/'+v.name)
(out/'signals.json').write_text(json.dumps(paths,indent=2)+'\n')
print(name,len(paths),'indexed')
for path in paths:
 if '/accel_perf/' in path:print(path)

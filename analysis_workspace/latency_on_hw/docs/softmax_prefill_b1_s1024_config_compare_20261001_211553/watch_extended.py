from pathlib import Path
import json,os,signal,time,subprocess,sys
folder=Path(__file__).parent
record=json.loads((folder/'extended_supervision.json').read_text())
start=time.monotonic()
def active(pid):
    path=Path(f'/proc/{pid}/stat')
    if not path.exists():return False
    text=path.read_text()
    return text[text.rfind(')')+2:].split()[0]!='Z'
while any(active(pid) for pid in record['child_pids']):
    remaining=[pid for pid in record['child_pids'] if active(pid)]
    (folder/'live_status.json').write_text(json.dumps({'time':time.time(),'active_child_pids':remaining,'extended_seconds':round(time.monotonic()-start)},indent=2)+'\n')
    if time.monotonic()-start>record['maximum_remaining_seconds']:
        print('Extended watchdog limit reached; resuming original timeout supervisor.',flush=True)
        break
    time.sleep(5)
os.kill(record['runner_pid'],signal.SIGCONT)
print('All requested tests ended; resumed result collector.',flush=True)
for _ in range(30):
    results=folder/'results.json'
    if results.exists():
        data=json.loads(results.read_text())
        if all((folder/f"config_{r['index']}/result.json").exists() for r in data):
            subprocess.run([sys.executable,str(folder/'summarize.py')],check=True)
            print(json.dumps(data,indent=2),flush=True)
            break
    time.sleep(1)

"""Sequential VCS depth sweep in one configured build; abort on failure."""
from pathlib import Path
import argparse
import json
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--depths', nargs='+', type=int, default=[32,64,128])
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
for depth in args.depths:
    phase = f'depth_sweep/depth{depth}'
    cmd = [sys.executable, '-u', str(repo/'agent-tasks/axi-raw-ordering/measure.py'), phase,
           '--write-depth', str(depth), '--cases', 'inorder']
    subprocess.run(cmd, cwd=repo, check=True)
    data = json.loads((repo/'agent-tasks/axi-raw-ordering'/phase/'results.json').read_text())
    if len(data) != 1 or not data[0]['passed']:
        raise SystemExit(f'depth {depth}: test failed; see retained logs')
    if len(data[0]['depth_stats']) != 4 or any(x['depth'] != depth for x in data[0]['depth_stats']):
        raise SystemExit(f'depth {depth}: missing or mismatched instrumentation')

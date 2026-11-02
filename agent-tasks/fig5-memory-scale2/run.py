#!/usr/bin/env python3
"""Measure the missing 2x memory points using the original Fig. 5 RTL/flow."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

TASK = Path(__file__).resolve().parent
BASE = TASK.parent / 'fpga-v2-resource-study/results'
spec = importlib.util.spec_from_file_location('fig5_run', TASK.parent / 'fig5-fpga/run.py')
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)
flow.strip_comments = lambda s: re.sub(r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*', '', s, flags=re.S)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def main():
    build = Path.cwd()
    assert (build / 'config.mk').is_file(), 'Use a configured build directory'
    revision = subprocess.check_output(['git', '-C', str(flow.ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == '1e4b367cca8f1a11cff74ce6b428079621b3a398'
    harness = read(BASE / 'provenance/harness.json')
    for name in ('run.py', 'synth.tcl', 'report.tcl'):
        path = Path('agent-tasks/fig5-fpga') / name
        assert sha(TASK.parents[1] / path) == harness[str(path)], path
    for path, expected in read(BASE / 'provenance/rtl_support.json').items():
        assert sha(flow.ROOT / path) == expected, path
    flow.POINTS = {}
    manifests = {}
    for old, new in [('lmem_8', 'lmem_16'), ('cache_1', 'cache_2'), ('axi_1', 'axi_2')]:
        manifest = read(BASE / 'reports' / old / 'manifest.json')
        params = dict(manifest['generics'])
        keys = ['NUM_REQS', 'NUM_BANKS'] if old.startswith('lmem') else ['NUM_REQS', 'NUM_BANKS', 'MEM_PORTS'] if old.startswith('cache') else ['NUM_PORTS_IN']
        for key in keys:
            params[key] *= 2
        flow.POINTS[new] = (manifest['top'], params)
        manifests[manifest['top']] = manifest
        assert shlex.split(os.environ['CONFIGS']) == manifest['defines']
        assert not (build / 'fig5_fpga' / new / 'post_opt.dcp').exists(), 'Use a fresh build'

    # Check exact preprocessed RTL identity before changing only top parameters.
    prepare = flow.prepare
    def checked_prepare(top, dest, defines):
        files = prepare(top, dest, defines)
        expected = {Path(p).name: h for p, h in manifests[top]['sources'].items()}
        actual = {Path(p).name: sha(p) for p in files.read_text().splitlines()}
        assert actual == expected, (top, 'Archived RTL source hash mismatch')
        return files
    flow.prepare = checked_prepare

    # Enable the original production assertions for a geometry-only smoke test.
    if '--prepare-only' not in sys.argv:
        out = build / 'axi_geometry_check'
        out.mkdir(exist_ok=True)
        defines = [d for d in shlex.split(os.environ['CONFIGS']) if d != '-DSYNTHESIS'] + ['-DSIMULATION']
        files = prepare('VX_axi_adapter', out / 'sources', defines).read_text().splitlines()
        tb = out / 'axi_geometry_probe.sv'
        tb.write_text('''module axi_geometry_probe;
 VX_axi_adapter #(.NUM_PORTS_IN(2), .NUM_BANKS_OUT(32), .NUM_HBM_PORTS(32),
 .INTERLEAVE(1), .DATA_WIDTH(512), .ADDR_WIDTH_IN(28), .ADDR_WIDTH_OUT(34),
 .TAG_WIDTH_IN(16), .TAG_WIDTH_OUT(16)) dut(.clk(1'b0), .reset(1'b1));
 initial begin
  #1;
  if ($size(dut.m_axi_arvalid)!=32 || $size(dut.m_axi_awvalid)!=32
      || $bits(dut.m_axi_araddr[0])!=34 || $bits(dut.mem_req_addr[0])!=28
      || dut.PORTS_PER_GROUP!=1 || dut.NUM_PORTS_IN!=2)
    $fatal(1,"Incorrect AXI geometry");
  $display("AXI GEOMETRY PASSED requests=2 groups=32 HBM_ports=32 address_bits=34");
  $finish;
 end
endmodule
''')
        cmd = ['verilator', '--binary', '--timing', '--top-module', 'axi_geometry_probe',
               '-Wno-fatal', '-j', '2', '-MAKEFLAGS', 'CXX=/usr/bin/g++ CC=/usr/bin/gcc', *files, str(tb)]
        with (out / 'compile.log').open('w') as log:
            subprocess.run(cmd, cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True)
        log = subprocess.check_output([str(out / 'obj_dir/Vaxi_geometry_probe')], text=True)
        (out / 'run.log').write_text(log)
        assert 'AXI GEOMETRY PASSED' in log
        (out / 'result.json').write_text(json.dumps(dict(status='pass', input_ports=2, physical_ports=32, address_bits=34, log=log), indent=2) + '\n')
        print(log, flush=True)
    flow.main()


if __name__ == '__main__':
    main()

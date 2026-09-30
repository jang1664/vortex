#!/usr/bin/env python3
"""Apply only the three documented dimension changes in an isolated RTL checkout."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path
PIN = 'f1f6303b112e060e56f0512294bd86f2be373b26'
def sha(b): return hashlib.sha256(b).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('rtl',type=Path);a=p.parse_args()
    root=a.rtl.resolve()
    assert subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()==PIN
    changes={
      'hw/rtl/VX_config.vh':[(r'(?m)^`define MXU_ROW 32', '`define MXU_ROW 16'),(r'(?m)^`define MXU_COL 32', '`define MXU_COL 16')],
      'hw/rtl/tcu/VX_tcu_pkg.sv':[(r'localparam TCU_DP = 0;', 'localparam TCU_DP = 2;')]}
    manifest=[]
    for name,edits in changes.items():
        original=subprocess.check_output(['git','-C',str(root),'show',PIN+':'+name])
        modified=original.decode()
        for pattern,replacement in edits:
            modified,count=re.subn(pattern,replacement,modified);assert count==1,(name,pattern,count)
        target=root/name
        assert target.read_bytes() in (original,modified.encode()), 'Unexpected local modification: '+name
        target.write_text(modified)
        manifest.append(dict(file=name,before_sha256=sha(original),after_sha256=sha(modified.encode()),edits=edits))
    dest=root/'build-mxu16-fpga';dest.mkdir(exist_ok=True)
    (dest/'rtl_edits.json').write_text(json.dumps(dict(base_commit=PIN,changes=manifest),indent=2)+'\n')
    print(dest)
if __name__=='__main__':main()

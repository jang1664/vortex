#!/usr/bin/env python3
"""Render the compact Table VI from measured resource counts, not hand values."""
import argparse
import csv
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('results',type=Path,nargs='?',default=Path(__file__).parent/'results')
a=p.parse_args();out=a.results
points={r['point']:r for r in json.loads((out/'resources.json').read_text())}
base=points['fp_tcu_128'];rows=[]
for name,label,precision in [('fp_tcu_128','FP TCU',r'FP$\times$FP'),
                            ('woq_16x16',r'WoQ \fpint{} GEMM Engine',r'\fpint{}'),
                            ('wkv_16x16',r'WKV \fpint{} GEMM Engine',r'\fpint{}')]:
 r=points[name]
 rows.append(dict(point=name,unit=label,precision=precision,
                  relative_GOPS_per_kLUT=r['GOPS_per_kLUT']/base['GOPS_per_kLUT'],
                  relative_GOPS_per_DSP=r['GOPS_per_DSP']/base['GOPS_per_DSP']))
text=r'''\begin{table}[t]
\centering
\caption{Relative nominal compute-engine efficiency at 100\,MHz,
normalized to the 128-MAC/cycle FP TCU.
WoQ and WKV use 16$\times$16 MXUs (256 MAC/cycle).}
\label{tab:array-level}
\setlength{\tabcolsep}{3pt}
\begin{tabularx}{\columnwidth}{@{}>{\raggedright\arraybackslash}Xccc@{}}
\toprule
Unit & Precision & GOPS/kLUT & GOPS/DSP \\
\midrule
'''
for r in rows:
 text+=f"{r['unit']} & {r['precision']} & {r['relative_GOPS_per_kLUT']:.2f} & {r['relative_GOPS_per_DSP']:.2f} \\\\\n"
text+=r'''\bottomrule
\end{tabularx}
\end{table}
'''
(out/'table6.tex').write_text(text)
(out/'table6.json').write_text(json.dumps(rows,indent=2)+'\n')
with (out/'table6.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
print(text)

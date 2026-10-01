#!/usr/bin/env python3
"""Replay compact paper figures from measured, archived JSON."""
import argparse,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
p=argparse.ArgumentParser();p.add_argument('results',type=Path,nargs='?',default=Path(__file__).parent/'results');p.add_argument('--engine-only',action='store_true');a=p.parse_args();out=a.results
plt.rcParams.update({'font.size':10,'pdf.fonttype':42,'ps.fonttype':42,'axes.spines.top':False,'axes.spines.right':False})
def save(fig,name):
 fig.savefig(out/(name+'.pdf'),bbox_inches='tight');fig.savefig(out/(name+'.png'),bbox_inches='tight',dpi=180);plt.close(fig)
parts=json.loads((out/'engine_breakdown.json').read_text())
colors=['#19395f','#27ae60','#527faa','#b4c9e1','#8b8b8b','#cccccc']
fig,axes=plt.subplots(1,2,figsize=(8,3.6))
for ax,key,scale,label in zip(axes,['LUT','DSP'],[1000,1],['LUT (thousands)','DSP48E2']):
 bottom=np.zeros(2)
 groups=[g for g in parts['woq_16x16'] if g['component']!='ACC hard memory']
 for i,g in enumerate(groups):
  values=np.array([next(x for x in parts[n] if x['component']==g['component'])[key]/scale for n in ['woq_16x16','wkv_16x16']])
  ax.bar([0,1],values,bottom=bottom,label=g['component'],color=colors[i],edgecolor='white',linewidth=.4,width=.55);bottom+=values
 ax.set_xticks([0,1],['WoQ','WKV']);ax.set_ylabel(label);ax.set_ylim(0,max(bottom)*1.15)
 for x,v in enumerate(bottom):ax.text(x,v+max(bottom)*.025,f'{v:,.3f}' if scale==1000 else f'{v:,.0f}',ha='center')
h,l=axes[0].get_legend_handles_labels();fig.legend(h,l,loc='upper center',bbox_to_anchor=(.5,-.02),ncol=3,frameon=False,fontsize=9)
fig.tight_layout();save(fig,'engine_resource_breakdown')
if a.engine_only:raise SystemExit(0)
rows=json.loads((out/'comparison.json').read_text())
r=[rows[2+i]['GOPS_per_kLUT']/rows[i]['GOPS_per_kLUT'] for i in [0,1]]
fig,ax=plt.subplots(figsize=(5.8,3.5));x=np.arange(2);w=.28
ax.bar(x-w/2,[1,1],w,color='#888888',label='FP TCU (128 MAC/cycle)')
ax.bar(x+w/2,r,w,color='#286296',label='FP-INT (256 MAC/cycle)')
for i in range(2):
 for xx,v in [(x[i]-w/2,1),(x[i]+w/2,r[i])]:ax.text(xx,v+.04,f'{v:.2f}×',ha='center',fontweight='bold')
ax.set_xticks(x,['Engine only','+ Memory subsystem']);ax.set_ylabel('Relative nominal\nGOPS/kLUT')
ax.set_ylim(0,max(1,*r)*1.35);ax.axhline(1,color='gray',linestyle='--',linewidth=.6);ax.legend(frameon=False,fontsize=9,loc='upper right')
ax.set_axisbelow(True);ax.grid(axis='y',alpha=.2);fig.tight_layout();save(fig,'memory_scaling')

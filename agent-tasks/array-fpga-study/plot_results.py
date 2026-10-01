#!/usr/bin/env python3
"""Replay figures entirely from archived JSON; Vivado is not needed."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

plt.rcParams.update({'font.size':10,'pdf.fonttype':42,'ps.fonttype':42,'axes.spines.top':False,'axes.spines.right':False})
COLORS=['#4477AA','#EE6677','#228833','#CCBB44','#66CCEE','#AA3377','#BBBBBB','#332288','#88CCEE','#44AA99','#999933','#882255']

def save(fig,out,name):
    fig.savefig(out/(name+'.pdf'),bbox_inches='tight')
    fig.savefig(out/(name+'.png'),bbox_inches='tight',dpi=180)
    plt.close(fig)

def c4(out):
    data=json.loads((out/'c4_resources.json').read_text())
    groups=data['groups'];keys=['LUT','FF','DSP','BRAM36eq','URAM']
    total=dict(data['accelerator']);total['BRAM36eq']=total['RAMB36']+total['RAMB18']/2
    fig,ax=plt.subplots(figsize=(9.4,5.5));bottom=np.zeros(len(keys))
    for i,g in enumerate(groups):
        val=np.array([100*g[k]/total[k] for k in keys]);ax.bar(range(len(keys)),val,bottom=bottom,label=g['component'],color=COLORS[i],edgecolor='white',linewidth=.3,width=.6);bottom+=val
    ax.set_xticks(range(len(keys)),['LUT','FF','DSP','BRAM36 eq.','URAM']);ax.set_ylim(0,108)
    ax.set_ylabel('Share of accelerator resource (%)')
    for i,k in enumerate(keys):ax.text(i,102,f"{total[k]:,}",ha='center',fontsize=9)
    ax.set_title('C4 resource breakdown — existing U55C post-route build',pad=18)
    ax.legend(loc='upper center',bbox_to_anchor=(.5,-.12),ncol=3,frameon=False,fontsize=8)
    fig.text(.5,-.20,'Denominator: vortex_afu_1; shell excluded. ACC hard memory excludes LUT/FF glue.\nHistorical C4 uses URAM; separate from the OOC engine comparison.',ha='center',fontsize=8)
    save(fig,out,'c4_resource_breakdown')

def engines(out):
    table=json.loads((out/'engine_resources.json').read_text());parts=json.loads((out/'engine_breakdown.json').read_text())
    names=['woq_derived_native','wkv_native']
    fig,axs=plt.subplots(1,2,figsize=(8,4))
    for ax,key,scale,label in zip(axs,['LUT','DSP'],[1000,1],['LUT (thousands)','DSP48E2']):
        bottom=np.zeros(2)
        for i,g in enumerate(parts[names[0]]):
            if g['component']=='ACC hard memory': continue
            v=np.array([parts[n][i][key]/scale for n in names]);ax.bar(range(2),v,bottom=bottom,label=g['component'],color=COLORS[i],width=.55,edgecolor='white',linewidth=.3);bottom+=v
        ax.set_xticks([0,1],['WoQ derived','WKV']);ax.set_ylabel(label)
        ax.set_ylim(0,max(bottom)*1.13)
        for x,v in enumerate(bottom): ax.text(x,v*1.02,f'{v:,.3f}' if scale==1000 else f'{v:,.0f}',ha='center',fontsize=9)
    handles,labels=axs[0].get_legend_handles_labels();fig.legend(handles,labels,loc='upper center',bbox_to_anchor=(.5,-.02),ncol=3,fontsize=8,frameon=False)
    fig.suptitle('Native FPGA mapping: matched WoQ / WKV engine')
    fig.text(.5,-.25,'Vivado OOC synthesis + RAM patch + opt_design. Same 256 KiB ACC.\nHierarchy attribution is not causal removal cost; total differences are reported separately.',ha='center',fontsize=8)
    fig.tight_layout();save(fig,out,'engine_resource_breakdown')
    fig,axs=plt.subplots(1,2,figsize=(8,3.6))
    for ax,key,title in zip(axs,['GOPS_per_kLUT','GOPS_per_DSP'],['Nominal GOPS / kLUT','Nominal GOPS / DSP']):
        vals=[r[key] for r in table];ax.bar(range(3),vals,color=[COLORS[0],COLORS[2],COLORS[1]],width=.6);ax.set_xticks(range(3),['FP TCU','WoQ derived','WKV']);ax.set_ylabel(title);ax.set_ylim(0,max(vals)*1.18)
        for i,v in enumerate(vals):ax.text(i,v*1.03,f'{v:.3f}',ha='center')
    fig.suptitle('FPGA compute-engine resource efficiency')
    fig.text(.5,-.07,'100 MHz reference, 2 operations/MAC. Nominal compute peak; no achieved Fmax claim.\nGEMM includes 256 KiB ACC; TCU is not iso-storage. Both LUT and DSP costs matter.',ha='center',fontsize=8)
    fig.tight_layout();save(fig,out,'engine_resource_efficiency')
    columns=['Engine','MAC/cycle','LUT','FF','DSP','BRAM36eq','URAM','GOPS*','GOPS/kLUT*','GOPS/DSP*']
    labels=['FP TCU','WoQ derived','WKV']
    cells=[[labels[i],r['MAC_per_cycle'],f"{r['LUT']:,}",f"{r['FF']:,}",r['DSP'],f"{r['BRAM36eq']:g}",r['URAM'],f"{r['nominal_GOPS']:.1f}",f"{r['GOPS_per_kLUT']:.3f}",f"{r['GOPS_per_DSP']:.3f}"] for i,r in enumerate(table)]
    fig,ax=plt.subplots(figsize=(12,2.3));ax.axis('off');tab=ax.table(cellText=cells,colLabels=columns,loc='center',cellLoc='center');tab.auto_set_font_size(False);tab.set_fontsize(9);tab.scale(1,1.7)
    ax.set_title('Table VI candidate: FPGA compute-engine resources',pad=12)
    fig.text(.5,.01,'* Nominal peak at common 100 MHz reference; synthesis-only, native DSP mapping.\nWoQ/WKV contain equal 256 KiB ACC; TCU has different storage scope. Power and Fmax not measured.',ha='center',fontsize=8)
    save(fig,out,'engine_resources_table')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('results',type=Path,nargs='?',default=Path(__file__).parent/'results');a=p.parse_args()
    if (a.results/'c4_resources.json').exists():c4(a.results)
    if (a.results/'engine_resources.json').exists():engines(a.results)

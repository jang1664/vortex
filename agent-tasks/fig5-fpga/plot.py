#!/usr/bin/env python3
"""Regenerate figures from committed numeric results; Vivado is not required."""
import argparse
import json
from pathlib import Path


def plot_memory(rows, output):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axs = plt.subplots(1, 3, figsize=(9, 3.2), layout='constrained')
    for ax, base, wide, title in zip(axs, rows[::2], rows[1::2], ['LMEM: 16 → 64 banks', 'Cache: 2 → 8 banks', 'AXI: 2 → 8 input ports']):
        vals=[base['LUT']/1000, wide['LUT']/1000]
        ax.bar(['Small', 'Expanded'], vals, color=['#607d8b', '#e09436'])
        ax.set(title=title, ylabel='Total LUTs (thousands)', ylim=(0, max(vals)*1.27))
        ax.spines[['top', 'right']].set_visible(False)
        for i, val in enumerate(vals): ax.text(i,val+max(vals)*.025,f'{val:.1f}k',ha='center',fontsize=10)
        ax.text(.5,.93,f'{wide["LUT"]/base["LUT"]:.2f}× LUT',transform=ax.transAxes,ha='center')
    fig.suptitle('U55C memory-fabric scaling — standalone synthesis + RAM fix + opt_design', fontsize=11)
    fig.savefig(output / 'memory_scaling.png', dpi=180)
    fig.savefig(output / 'memory_scaling.pdf')


def plot_comparison(memory, rows, output):
    mem = {row['point']: row for row in memory}
    engines = [row for row in rows if row['scope'] == 'engine only']
    ratios = [rows[2+i]['nominal_GOPS_per_kLUT']/rows[i]['nominal_GOPS_per_kLUT'] for i in (0, 1)]
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,axs=plt.subplots(1,2,figsize=(9,3.6),layout='constrained')
    colors=['#607d8b','#e09436']
    for j,lab in enumerate(['FP TCU (256 MAC/cycle)','FP-INT (1024 MAC/cycle)']):
        vals=[1,1] if j==0 else ratios
        pos=[i+(j-.5)*.34 for i in [0,1]]
        axs[0].bar(pos,vals,.34,label=lab,color=colors[j])
        for x,v in zip(pos,vals): axs[0].text(x,v+.04,f'{v:.2f}×',ha='center',fontsize=9)
    axs[0].set(xticks=[0,1],xticklabels=['Engine only','+ Memory subsystem'],ylabel='Relative nominal GOPS/kLUT',ylim=(0,max(1,*ratios)*1.3))
    axs[0].legend(fontsize=8,loc='upper right')
    for j,e in enumerate(engines):
        names=['lmem_16','cache_2','axi_2'] if j==0 else ['lmem_64','cache_8','axi_8']
        bottom=0
        for label,val,col in [('Engine',e['LUT'],'#456a82'),('LMEM',mem[names[0]]['LUT'],'#e09436'),('Cache',mem[names[1]]['LUT'],'#70a28a'),('AXI adapter',mem[names[2]]['LUT'],'#aa86b8')]:
            axs[1].bar(j,val/1000,bottom=bottom,color=col,label=label if j==0 else None)
            bottom+=val/1000
        axs[1].text(j,bottom+3,f'{bottom:.1f}k',ha='center',fontsize=9)
    axs[1].set(xticks=[0,1],xticklabels=['FP TCU + small fabric','FP-INT + expanded fabric'],ylabel='LUTs (thousands)')
    axs[1].margins(y=.25);axs[1].legend(fontsize=8,loc='upper left')
    for ax in axs: ax.spines[['top','right']].set_visible(False)
    fig.suptitle('Fig. 5 FPGA draft: separately synthesized block costs\nOOC synthesis + opt_design; nominal throughput at 100 MHz, no routing',fontsize=10)
    fig.savefig(output/'fig5_fpga_feasibility.png',dpi=180)
    fig.savefig(output/'fig5_fpga_feasibility.pdf')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path, help='Saved results directory')
    parser.add_argument('--output', type=Path, required=True, help='Directory for regenerated PDF/PNG')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    memory = json.loads((args.results/'memory_resources.json').read_text())
    comparison = json.loads((args.results/'comparison.json').read_text())
    plot_memory(memory, args.output)
    plot_comparison(memory, comparison, args.output)

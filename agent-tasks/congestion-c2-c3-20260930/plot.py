import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

root = Path(__file__).resolve().parent
data = json.loads((root / 'parsed-reports.json').read_text())
fig, axes = plt.subplots(1, 2, figsize=(10.8, 4.8), sharey=True)
for ax, (label, d) in zip(axes, data.items()):
    x = np.arange(3)
    for metric, offset, color, text in [
        ('CLB LUTs', -0.19, '#3675b7', 'LUT'),
        ('Block RAM Tile', 0.19, '#dc8d2c', 'BRAM')]:
        values = [d['slr_utilization'][metric][f'SLR{i}']['percent'] for i in x]
        bars = ax.bar(x + offset, values, width=0.36, color=color, label=text)
        ax.bar_label(bars, labels=[f'{v:.1f}%' for v in values], fontsize=9, padding=3)
    worst = 1 if label == 'C2' else 0
    ax.axvspan(worst - 0.43, worst + 0.43, color='#ba302a', alpha=0.09)
    ax.text(worst, 109, 'Level 7 hotspot', ha='center', fontsize=10, color='#ad302b')
    ax.set_xticks(x, ['SLR0', 'SLR1', 'SLR2\nMXU target'])
    ax.set_ylim(0, 119)
    ax.set_yticks(range(0, 101, 20))
    ax.set_title(label + (' — TCU + naive GEMM' if label == 'C2' else ' — naive GEMM'))
    ax.grid(axis='y', alpha=0.2)
    ax.set_axisbelow(True)
    ax.spines[['top','right']].set_visible(False)
    ax.legend(loc='lower right')
axes[0].set_ylabel('Whole-SLR resource utilization (%)')
fig.suptitle('C2/C3 post-place congestion: peak windows are outside MXU SLR2', fontsize=13)
fig.text(0.5, 0.015, 'Bars: whole-SLR utilization. Shading: SLR containing reported level-7 windows.\nLocal hotspot BRAM utilization is 97–99%; these bars are not routing-congestion percentages.', ha='center', fontsize=9)
fig.tight_layout(rect=[0, 0.09, 1, 0.94])
fig.savefig(root / 'slr-utilization.png', dpi=180)
fig.savefig(root / 'slr-utilization.svg')

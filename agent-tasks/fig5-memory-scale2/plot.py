#!/usr/bin/env python3
"""Draw paired Fig. 5 variants from measured 2x and archived 4x results."""
import argparse
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('results', type=Path, nargs='?', default=Path(__file__).parent / 'results')
parser.add_argument('--output', type=Path)
parser.add_argument('--factors', type=int, nargs='+', choices=(2, 4), default=(2, 4))
parser.add_argument('--combined', action='store_true', help='Show engine only and both memory profiles on one graph')
args = parser.parse_args()
out = args.output or args.results
out.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({'font.size': 10, 'pdf.fonttype': 42, 'ps.fonttype': 42,
                     'axes.spines.top': False, 'axes.spines.right': False})
jobs = [('combined', args.factors)] if args.combined else [(f'{factor}x', [factor]) for factor in args.factors]
for name, factors in jobs:
    profiles = [json.loads((args.results / f'comparison_{factor}x.json').read_text()) for factor in factors]
    engine_ratio = profiles[0][2]['GOPS_per_kLUT'] / profiles[0][0]['GOPS_per_kLUT']
    ratios = [engine_ratio] + [rows[3]['GOPS_per_kLUT'] / rows[1]['GOPS_per_kLUT'] for rows in profiles]
    fig, ax = plt.subplots(figsize=(6.8, 3.1) if args.combined else (5.8, 3.5))
    x, width = np.arange(len(ratios)), .28
    edge = dict(edgecolor='#444444', linewidth=1) if args.combined else {}
    ax.bar(x-width/2, np.ones(len(x)), width, color='#888888', label='FP TCU (128 MAC/cycle)', **edge)
    ax.bar(x+width/2, ratios, width, color='#286296', label='FP-INT (256 MAC/cycle)', **edge)
    for i in range(len(x)):
        for pos, value in ((x[i]-width/2, 1), (x[i]+width/2, ratios[i])):
            ax.text(pos, value+.04, f'{value:.2f}×', ha='center', fontweight='bold')
    labels = ['Engine only'] + [f'x{factor}\n+Memory subsystem' for factor in factors] if args.combined else ['Engine only', '+ Memory subsystem']
    ax.set_xticks(x, labels)
    ax.set_ylabel('Relative nominal\nGOPS/kLUT', fontweight='bold' if args.combined else 'normal')
    if not args.combined:
        ax.set_title(f'{factors[0]}× memory-fabric scaling', fontsize=11)
    ax.set_ylim(0, 2.05 if args.combined else 2.2)
    ax.set_yticks(np.arange(0, 2.1, .5))
    ax.axhline(1, color='gray', linestyle='-' if args.combined else '--', linewidth=1 if args.combined else .6)
    ax.legend(frameon=False, loc='upper right', prop={'size': 9, 'weight': 'bold' if args.combined else 'normal'},
              handlelength=.7 if args.combined else 2, handletextpad=.4)
    if args.combined:
        center = (x[1] + x[-1]) / 2 + width / 2
        for i in range(1, len(x)):
            is_2x = factors[i-1] == 2
            offset = 0 if is_2x else .08
            ax.annotate('', xy=(x[i]+width/2, ratios[i]+(.13 if is_2x else .17)),
                        xytext=(x[i]+width/2-offset, 1.46 if is_2x else 1.40),
                        arrowprops=dict(arrowstyle='->', color='red', lw=1.2, shrinkB=0 if is_2x else 2))
        ax.text(center, 1.52, 'Memory subsystem overhead', color='red', fontsize=10,
                fontweight='bold', ha='center', va='center',
                bbox=dict(boxstyle='square,pad=.35', edgecolor='red', facecolor='white', linewidth=1.2))
    ax.set_axisbelow(True)
    ax.grid(axis='y', alpha=.2)
    fig.tight_layout()
    for extension in ('pdf', 'png'):
        fig.savefig(out / f'fig5_{name}.{extension}', bbox_inches='tight', dpi=180)
    plt.close(fig)

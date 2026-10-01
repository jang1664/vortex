#!/usr/bin/env python3
"""Build a readable comparison and static charts from comparison.csv."""
import csv
import json
import statistics
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

OUT = Path(__file__).resolve().parent
items = json.loads((OUT / "inventory.json").read_text())
with (OUT / "comparison.csv").open() as stream:
    rows = list(csv.DictReader(stream))
for row in rows:
    for key in ["synth_or_linked_used", "postroute_used", "delta_used", "relative_change_pct", "before_util_pct", "postroute_util_pct", "util_delta_pp"]:
        row[key] = float(row[key]) if row[key] else None
kernel = {(r["design"], r["resource"]): r for r in rows if r["scope"] == "kernel"}
complete = [i for i in items if i["status"] == "complete"]

LABELS = {
    "base_t8": "Baseline T8",
    "tcu_th16_c1": "TCU T16",
    "tcu_th32_c1": "TCU T32",
    "C1": "C1 / TCU T32 rev2",
    "tcu_th32_c1_rev3": "TCU T32 rev3",
    "naive_gemm_th16_tcol32_hwexp_dcache_pack16": "Naive T16",
    "C3": "C3 / Naive T32",
    "naive_gemm_th16_b32_tcol32_hwexp_dcache_sxbar_f16": "Naive T16 sxbar f16",
    "C3_v2": "C3_v2 / Naive T8 sxbar f16",
    "C3_v3": "C3_v3 / Naive T8 bigmem",
    "improve_th16_tcol32_hwexp_dcache_rev2": "Improve T16 rev2",
    "C4": "C4 / Improve T32",
    "improve_th32_tcol32_hwexp_dcache_sxbar": "Improve T32 sxbar",
    "improve_th32_tcol32_hwexp_dcache_sxbar_f16": "Improve T32 sxbar f16",
    "C4_2": "C4_2 / Improve T32 f16 v4",
    "C4_v2_noperf": "C4_v2_noperf",
    "C4_v3": "C4_v3 / Improve T32 bigmem",
}


def num(value, signed=False):
    return f"{value:+,.1f}".removesuffix(".0") if signed else f"{value:,.1f}".removesuffix(".0")


def family(item):
    alias = item["aliases"][0]
    return "baseline" if alias.startswith("base_") else "TCU" if alias.startswith("tcu_") else "naive GEMM" if alias.startswith("naive_") else "improve GEMM"


text = [
    "# 합성 대비 PnR utilization 비교 (2026-09-30)", "",
    f"`ci/fpga_bin_alias_map.yaml`의 {sum(len(i['aliases']) for i in items)}개 alias를 {len(items)}개 고유 binary 경로로 묶었다. 최종 checkpoint를 통해 직접 비교 가능한 design은 {len(complete)}개다. 중복 alias를 통계 표본으로 중복 계산하지 않았다.", "",
    "## 비교 기준", "",
    "- 합성: 각 binary의 `ulp_vortex_afu_1_0_synth_1_ulp_vortex_afu_1_0_utilization_synth.rpt`.",
    "- PnR: 저장된 `level0_wrapper_postroute_physopt.dcp`를 열어 `report_utilization -cells [get_cells level0_i/ulp/vortex_afu_1]`로 새로 추출. 타이밍 제약 재로딩은 생략하되 배치·배선 데이터는 그대로 사용했다.",
    "- 자원 범위: 합성과 PnR 모두 동일한 Vortex 커널. shell 및 Vitis 연결 로직은 제외.",
    "- 변화량 = PnR − 합성. 상대 변화율 = 변화량 / 합성 × 100. utilization 변화(pp) = 변화량 / U55C 전체 자원 수 × 100.",
    "- BRAM은 36 Kb tile 단위: RAMB36 + RAMB18/2. URAM/DSP는 개수. 합성이 0인 자원의 상대 변화율은 정의하지 않는다.",
    "- 기존 `hier_utilization.rpt`는 `pre_opt_hook.tcl`에서 생성된다. 헤더의 `Physopt postRoute`는 이미 구현된 shell 때문에 표시되는 상태이며, 커널의 route 완료 여부를 뜻하지 않는다. 최종 PnR 비교에 사용하지 않았다.",
    "- 별도 `full` 비교는 shell 포함 linked pre-opt 보고서와 최종 DCP 전체 utilization을 비교한다. 커널 합성과 shell 포함 전체 utilization을 직접 빼지 않았다.", "",
    "## 자원별 경향", "",
    "| 자원 | design 수 | 상대 변화율 평균 | 중앙값 | 최소 ~ 최대 | utilization 변화(pp) 평균 |",
    "|---|---:|---:|---:|---:|---:|",
]
summary = []
for resource in ["LUT", "FF", "BRAM tile", "URAM", "DSP"]:
    values = [kernel[i["design"], resource] for i in complete]
    relative = [r["relative_change_pct"] for r in values if r["relative_change_pct"] is not None]
    stats = {"resource": resource, "design_count": len(values), "relative_defined_count": len(relative),
             "mean_relative_pct": statistics.mean(relative), "median_relative_pct": statistics.median(relative),
             "min_relative_pct": min(relative), "max_relative_pct": max(relative),
             "mean_util_delta_pp": statistics.mean(r["util_delta_pp"] for r in values),
             "min_delta_used": min(r["delta_used"] for r in values), "max_delta_used": max(r["delta_used"] for r in values)}
    summary.append(stats)
    text.append(f"| {resource} | {len(values)} | {stats['mean_relative_pct']:+.3f}% | {stats['median_relative_pct']:+.3f}% | {min(relative):+.3f}% ~ {max(relative):+.3f}% | {stats['mean_util_delta_pp']:+.3f} |")
lut_stats, ff_stats = summary[:2]
text += ["", f"커널 LUT는 {abs(lut_stats['max_relative_pct']):.2f}~{abs(lut_stats['min_relative_pct']):.2f}% 감소하고, FF는 {abs(ff_stats['max_relative_pct']):.2f}~{abs(ff_stats['min_relative_pct']):.2f}% 감소했다. LUT의 최대 감소도 5% 이내여서 이 표본에서는 자원 개수가 크게 바뀐다고 보기는 어렵다. 다만 증가·감소율이 수 %인 차이는 area 비교에 반영하는 것이 맞다."]
text += ["", "평균과 중앙값은 design별 상대 변화율에 동일한 가중치를 적용했다. URAM 합성이 0인 design은 URAM 상대 변화율 평균에서 제외한다.", "", "## design별 커널 비교", "",
         "| Design | LUT 합성 → PnR | LUT Δ (상대율) | FF 합성 → PnR | FF Δ (상대율) | BRAM Δ | URAM Δ | DSP Δ |",
         "|---|---:|---:|---:|---:|---:|---:|---:|"]
for item in complete:
    design = item["design"]
    lut, ff, bram, uram, dsp = [kernel[design, r] for r in ["LUT", "FF", "BRAM tile", "URAM", "DSP"]]
    text.append(f"| {LABELS.get(design, design)} | {num(lut['synth_or_linked_used'])} → {num(lut['postroute_used'])} | {num(lut['delta_used'], True)} ({lut['relative_change_pct']:+.2f}%) | {num(ff['synth_or_linked_used'])} → {num(ff['postroute_used'])} | {num(ff['delta_used'], True)} ({ff['relative_change_pct']:+.2f}%) | {num(bram['delta_used'], True)} | {num(uram['delta_used'], True)} | {num(dsp['delta_used'], True)} |")
text += ["", "## 계열별 평균", "", "| 계열 | design 수 | LUT 상대 변화율 평균 | FF 상대 변화율 평균 |", "|---|---:|---:|---:|"]
for group in ["baseline", "TCU", "naive GEMM", "improve GEMM"]:
    members = [i for i in complete if family(i) == group]
    if members:
        avg = [statistics.mean(kernel[i['design'], r]['relative_change_pct'] for i in members) for r in ['LUT', 'FF']]
        text.append(f"| {group} | {len(members)} | {avg[0]:+.3f}% | {avg[1]:+.3f}% |")
text += ["", "서로 다른 빌드의 관측값이므로 thread 수·메모리 구성·RTL 변경·PnR directive 중 어떤 요소가 차이를 유발했는지는 이 비교만으로 분리할 수 없다.",
         "", "## shell 포함 전체 design 및 placement 이후 변화", "",
         "| 자원 | 전체 linked → 최종 PnR 상대 변화율 평균 | 범위 |", "|---|---:|---:|"]
for resource in ["LUT", "FF", "BRAM tile", "URAM", "DSP"]:
    values = [r['relative_change_pct'] for r in rows if r['scope'] == 'full' and r['resource'] == resource and r['relative_change_pct'] is not None]
    if values:
        text.append(f"| {resource} | {statistics.mean(values):+.3f}% | {min(values):+.3f}% ~ {max(values):+.3f}% |")
with (OUT / 'stages.csv').open() as stream:
    stages = {(r['design'], r['stage'], r['resource']): float(r['used']) for r in csv.DictReader(stream)}
checked, differing = [], []
for item in complete:
    design = item['design']
    resources = ['LUT', 'FF', 'BRAM tile', 'URAM', 'DSP']
    if not all((design, 'full_final', r) in stages for r in resources):
        continue
    checked.append(design)
    if any(stages[design, 'full_placed', r] != stages[design, 'full_final', r] for r in resources):
        differing.append(design)
text += ["", f"전체 placed 보고서와 최종 route+physopt 보고서를 대조한 {len(checked)}개 design 중 주요 자원 개수가 달라진 design은 {len(differing)}개다. 합성 이후 감소분의 대부분은 placement까지 이미 반영되었다."]
if differing:
    text.append("")
for design in differing:
    delta = [f"{r} {num(stages[design, 'full_final', r] - stages[design, 'full_placed', r], True)}" for r in resources if stages[design, 'full_final', r] != stages[design, 'full_placed', r]]
    text.append(f"- `{design}`의 placed → 최종 변화: {', '.join(delta)}.")
text += ["",
         "범위 혼용 예: C4의 커널 합성 LUT 566,829개와 shell 포함 최종 LUT 715,432개를 직접 비교하면 +26.22%로 보인다. 동일 커널의 최종 LUT는 558,582개이므로 실제 변화는 −1.45%다.",
         "", "## 비교 불가 design", ""]
for item in items:
    if item['status'] != 'complete':
        text.append(f"- `{'; '.join(item['aliases'])}`: `{item['status']}`. `{item['binary_path']}`")
text += ["", "`base_t32`에는 합성 및 placed 보고서는 남아 있으나 최종 checkpoint가 없다. 이를 최종 PnR 표본에 포함하지 않았다.", "", "## alias와 결과 파일", "", "| 표시 이름 | 등록 alias |", "|---|---|"]
for item in items:
    text.append(f"| {LABELS.get(item['design'], item['design'])} | {'; '.join('`'+a+'`' for a in item['aliases'])} |")
text += ["", "- `comparison.csv`: 자원별 개수, 상대 변화율, utilization(%), 변화(pp), 원본 보고서 경로.",
         "- `stages.csv`: 커널 합성·최종, 전체 linked·placed·최종의 원시 값.",
         "- `alias_coverage.csv`: 모든 등록 alias의 분석 가능 여부.",
         "- `inventory.json`: binary 경로, build ID/params, checkpoint 및 보고서 provenance.",
         "- `reports/`: 재추출한 utilization 보고서와 Vivado 실행 로그, 보관한 합성 보고서.",
         "- `summary.json`: 자원별 요약 통계.",
         "- `utilization_comparison.png`, `relative_changes.png`: 모든 분석 design의 정적 비교 그림.", "",
         "재실행: `python3 analyze.py --extract --jobs 2` (기존 최종 보고서 재사용), 이후 `python3 summarize.py`. analyze.py는 PyYAML, summarize.py는 matplotlib 및 NumPy가 필요하다.", ""]
(OUT / "README.md").write_text("\n".join(text))
(OUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

labels = [LABELS.get(i['design'], i['design']) for i in complete]
y = np.arange(len(labels))
fig, axes = plt.subplots(1, 2, figsize=(14, 9), sharey=True)
for axis, resource in zip(axes, ['LUT', 'FF']):
    axis.barh(y - .18, [kernel[i['design'], resource]['before_util_pct'] for i in complete], height=.34, label='After synthesis', color='#9aa9b5')
    axis.barh(y + .18, [kernel[i['design'], resource]['postroute_util_pct'] for i in complete], height=.34, label='After route + physopt', color='#2673a5')
    axis.set_xlabel('Kernel utilization / whole U55C capacity (%)')
    axis.set_title(resource)
    axis.grid(axis='x', alpha=.2)
    axis.set_axisbelow(True)
axes[0].set_yticks(y, labels)
axes[0].invert_yaxis()
handles, legend_labels = axes[0].get_legend_handles_labels()
fig.legend(handles, legend_labels, loc='lower center', ncol=2, bbox_to_anchor=(.62, .005))
fig.suptitle('Vortex kernel: synthesis vs final implementation', fontsize=14)
fig.tight_layout(rect=(0, .05, 1, 1))
fig.savefig(OUT / 'utilization_comparison.png', dpi=180)
plt.close(fig)
fig, axis = plt.subplots(figsize=(12, 9))
for offset, resource, color in [(-.18, 'LUT', '#2673a5'), (.18, 'FF', '#d87528')]:
    values = [kernel[i['design'], resource]['relative_change_pct'] for i in complete]
    axis.barh(y + offset, values, height=.34, label=resource, color=color)
    for position, value in zip(y + offset, values):
        axis.text(value - .1 if value < 0 else value + .1, position, f'{value:+.2f}%', ha='right' if value < 0 else 'left', va='center', fontsize=8)
axis.set_yticks(y, labels)
axis.invert_yaxis()
axis.axvline(0, color='black', linewidth=.7)
axis.set_xlim(min(r['relative_change_pct'] for (design, resource), r in kernel.items() if resource in ['LUT', 'FF']) - 1, .5)
axis.set_xlabel('(Final implementation − synthesis) / synthesis (%)')
axis.set_title('Resource count changes within the same Vortex kernel')
axis.grid(axis='x', alpha=.2)
axis.set_axisbelow(True)
axis.legend(loc='lower left')
fig.tight_layout()
fig.savefig(OUT / 'relative_changes.png', dpi=180)
plt.close(fig)
print(json.dumps(summary, indent=2))

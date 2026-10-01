#!/usr/bin/env python3
"""Attribute C4-C3 prefill differences in the user-selected September 20 figure."""
import csv
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SNAPSHOT = "th16_20260920_c4_slots16_v2r1"
MODELS = ("llama2_7b", "llama3_8b")
SEQS = (1024, 2048, 4096, 8192, 16384, 32768)
VARIANTS = {
    "all_fpint_gemm_naive_spinquant": "C3",
    "all_fpint_gemm_improve_fused_layout_spinquant": "C4",
}
csv.field_size_limit(20_000_000)


def group(name, backend):
    if "gemm" in backend:
        return "GEMM"
    if name.startswith("kv_cache_quant_"):
        return "KV quantization"
    if name == "attn_softmax":
        return "Softmax"
    if name.startswith("rope_"):
        return "RoPE"
    if "layernorm" in name:
        return "RMSNorm"
    if name == "spinquant_r4_mlp_hadamard":
        return "MLP Hadamard"
    return "Other vector"


def write_csv(name, rows):
    with (HERE / name).open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)


def analyze():
    details, summaries, source_records = [], [], []
    for model in MODELS:
        prepared = next((ROOT / f"figure_prepare.{SNAPSHOT}").glob(
            f"{model}_e2e_no_area_norm_gemm_layout_vector*/excel_figure_data.csv"
        ))
        figure_rows = {}
        with prepared.open() as f:
            last = {}
            for r in csv.DictReader(f):
                for k in ("stage", "batch", "seq"):
                    last[k] = r[k] or last.get(k, "")
                    r[k] = last[k]
                if r["stage"] == "Prefill" and r["candidate"] in ("C3", "C4"):
                    figure_rows[(int(r["seq"][:-1]) * 1024, r["candidate"])] = r

        selected = {}
        source = ROOT / f"composed_results.{SNAPSHOT}" / model / "composed.csv"
        print(f"Streaming {model}: {source.stat().st_size:,} bytes", flush=True)
        with source.open() as f:
            for r in csv.DictReader(f):
                if r["stage"] != "prefill" or r["variant"] not in VARIANTS:
                    continue
                seq = int(r["prefill_seq_len"])
                if seq not in SEQS or float(r["batch"]) != 1:
                    continue
                candidate = VARIANTS[r["variant"]]
                key = (seq, candidate, r["name"])
                assert key not in selected, key
                assert r["compose_status"] == "pass", key
                assert r["latency_resolution_kind"] == "measured", key
                assert math.isclose(float(r["weighted_latency_us"]),
                                    float(r["latency_us"]) * float(r["effective_calls"]),
                                    rel_tol=1e-10), key
                selected[key] = r
        assert len(selected) == 288, (model, len(selected))
        for seq in SEQS:
            records = {c: {name: r for (s, cand, name), r in selected.items()
                           if s == seq and cand == c} for c in ("C3", "C4")}
            assert records["C3"].keys() == records["C4"].keys()
            totals = {c: sum(float(r["weighted_latency_us"]) for r in rs.values())
                      for c, rs in records.items()}
            for c in ("C3", "C4"):
                assert math.isclose(float(figure_rows[(seq, c)]["total"]),
                                    totals[c] / totals["C3"], rel_tol=1e-10)
            gap = totals["C4"] - totals["C3"]
            current = []
            for name, a in records["C3"].items():
                b = records["C4"][name]
                assert float(a["effective_calls"]) == float(b["effective_calls"])
                c3, c4 = float(a["weighted_latency_us"]), float(b["weighted_latency_us"])
                for c, r, weight in (("C3", a, c3), ("C4", b, c4)):
                    k = f"{name}::{r['backend']}"
                    normalized = float(figure_rows[(seq, c)].get(k, "") or 0)
                    assert math.isclose(normalized, weight / totals["C3"],
                                        rel_tol=1e-9, abs_tol=1e-12), (model, seq, c, k)
                row = {
                    "model": model, "seq_len": seq, "name": name,
                    "group": group(name, a["backend"]),
                    "c3_backend": a["backend"], "c4_backend": b["backend"],
                    "effective_calls": float(a["effective_calls"]),
                    "c3_per_call_us": float(a["latency_us"]),
                    "c4_per_call_us": float(b["latency_us"]),
                    "c3_weighted_us": c3, "c4_weighted_us": c4,
                    "delta_us": c4 - c3, "delta_s": (c4 - c3) / 1e6,
                    "kernel_slowdown_pct": (c4 / c3 - 1) * 100,
                    "delta_pp_of_c3_total": (c4 - c3) / totals["C3"] * 100,
                    "share_of_net_gap_pct": (c4 - c3) / gap * 100,
                    "c3_source_fpga_bin_labels": a["source_fpga_bin_labels"],
                    "c4_source_fpga_bin_labels": b["source_fpga_bin_labels"],
                }
                current.append(row)
                for c, r in (("C3", a), ("C4", b)):
                    source_records.append({"model": model, "seq_len": seq,
                        "candidate": c, "name": name, **{k: r[k] for k in (
                            "case_id", "app", "backend", "args", "latency_us",
                            "effective_calls", "weighted_latency_us", "compose_status",
                            "latency_resolution_kind", "source_raw_dbs", "selected_run_id",
                            "selected_timestamp_utc", "source_fpga_bin_labels",
                            "source_fpga_bin_aliases", "source_xclbin_sha256s")}})
            positive = sum(max(r["delta_us"], 0) for r in current)
            savings = -sum(min(r["delta_us"], 0) for r in current)
            assert math.isclose(positive - savings, gap, rel_tol=1e-10)
            for r in current:
                r["share_of_positive_regressions_pct"] = max(r["delta_us"], 0) / positive * 100
            summary = {"model": model, "seq_len": seq,
                       "c3_total_s": totals["C3"] / 1e6,
                       "c4_total_s": totals["C4"] / 1e6,
                       "delta_s": gap / 1e6,
                       "c4_slowdown_pct": gap / totals["C3"] * 100,
                       "figure_c3_relative_to_c4": totals["C3"] / totals["C4"],
                       "positive_regressions_s": positive / 1e6,
                       "savings_s": savings / 1e6}
            for category in ("Softmax", "KV quantization", "RoPE", "RMSNorm",
                             "MLP Hadamard", "Other vector", "GEMM"):
                summary[category + "_delta_pp"] = sum(
                    r["delta_pp_of_c3_total"] for r in current if r["group"] == category)
            assert math.isclose(sum(v for k, v in summary.items() if k.endswith("_delta_pp")),
                                summary["c4_slowdown_pct"], rel_tol=1e-10)
            summaries.append(summary)
            details.extend(sorted(current, key=lambda r: -r["delta_us"]))
            print(model, seq, f"C4 slowdown {summary['c4_slowdown_pct']:.4f}%", flush=True)
    write_csv("kernel_breakdown.csv", details)
    write_csv("summary.csv", summaries)
    (HERE / "measurement_sources.json").write_text(json.dumps(source_records, indent=2) + "\n")
    report(details, summaries)
    chart(summaries)


def report(details, summaries):
    lines = ["# C3 대비 C4 prefill latency breakdown", "",
        "대상: `figure_output.th16_20260920_c4_slots16_v2r1/llama_e2e_no_area_norm_stacked/llama_e2e_latency_no_area_norm_stacked.png`.", "",
        "C4는 Llama2 prefill에서 2.30–3.29%, Llama3에서 2.34–4.26% 느리다. "
        "Llama2 1k–4k에서는 V KV-cache quantization, 8k–32k에서는 softmax가 가장 큰 단일 kernel 증가 요인이다. "
        "Llama3에서는 모든 context에서 softmax가 최대 증가 요인이고 Q RoPE가 다음이다.", "",
        "C4 GEMM의 개선과 일부 Hadamard 개선이 vector/layout kernel의 지연 증가를 상쇄하지만, 전체 지연은 증가한다.", "",
        "## 계산 및 측정 근거", "",
        "- 동일 snapshot의 `composed.csv`를 스트리밍하여 batch=1, prefill, 1k–32k, C3/C4만 선택했다.",
        "- 각 kernel의 모델 전체 시간 = `latency_us × effective_calls`. 32개 layer와 head별 호출 횟수를 반영한다.",
        "- Δ = C4 − C3. `Δ pp = Δ / C3 전체 시간 × 100`. 양수는 지연 증가, 음수는 개선이다.",
        "- 그림은 C4=1로 정규화하지만, 아래 기여도는 C3 전체 시간을 분모로 쓴다. Area normalization은 적용하지 않았다.",
        "- 모델별 24 kernel × 6 context × 2 candidate = 288개 측정 행을 사용했다. 전체 576개가 `pass` / `measured`; interpolation/추정은 없다.",
        "- 모든 kernel 값과 전체 합이 그림의 name/backend별 CSV와 일치하는지 확인했다.",
        "- **C3의 standalone vector kernel도 C4 bitstream에서 측정되었다.** C3 GEMM만 C3 bitstream, C4 GEMM 및 layout_fused vector는 C4 bitstream이다. "
        "따라서 vector 차이는 같은 bitstream에서 standalone와 layout_fused 구현을 비교한 결과다.",
        "- C3 GEMM alias: `naive_th16_tcol16_m16_L16_bigmem_all_bram_acc_base_pnr`.",
        "- C4 alias: `improve_th16_tcol16_m16_t8_bigmem_all_bram_v2`.",
        "- 이 값은 kernel 측정값으로 합성한 E2E 시간이다. 실제 한 번의 모델 실행 전체를 직접 측정한 시간과 구분해야 한다.", "",
        "## Context별 기여도", "",
        "아래 모든 기여도는 C3 전체 시간 대비 **percentage point (pp)**. 그룹 합은 C4의 전체 지연 증가율과 같다.", ""]
    for model in MODELS:
        lines.extend([f"### {model}", "",
            "| Context | C4 지연 증가 | Softmax | KV quant 합 | RoPE 합 | RMSNorm 합 | MLP Hadamard | 기타 vector | GEMM |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|"])
        for s in (r for r in summaries if r["model"] == model):
            values = [f"{s['seq_len']//1024}k", f"{s['c4_slowdown_pct']:.3f}%"]
            values += [f"{s[k + '_delta_pp']:+.3f}" for k in (
                "Softmax", "KV quantization", "RoPE", "RMSNorm", "MLP Hadamard", "Other vector", "GEMM")]
            lines.append("| " + " | ".join(values) + " |")
        lines.append("")
    lines.extend(["## Kernel별 상세: 1k 및 32k", "",
        "C3/C4 시간은 호출 횟수를 반영한 **모델 전체 누적 초(s)**. 순증가 기여율은 개선분 상쇄 때문에 100%를 넘을 수 있다. "
        "증가분 내 비중은 양수 Δ만 합산한 값을 분모로 사용한다.", ""])
    for model in MODELS:
        for seq in (1024, 32768):
            subset = [r for r in details if r["model"] == model and r["seq_len"] == seq]
            top = subset[:6]
            improvements = sorted(subset, key=lambda r: r["delta_us"])[:3]
            lines.extend([f"### {model}, {seq//1024}k", "",
                "| Kernel | C3 s | C4 s | Δ s | Kernel 증감 | Δ pp | 증가분 내 비중 | 순증가 기여율 |",
                "|---|---:|---:|---:|---:|---:|---:|---:|"])
            for r in top + improvements:
                lines.append(f"| `{r['name']}` | {r['c3_weighted_us']/1e6:.3f} | {r['c4_weighted_us']/1e6:.3f} "
                    f"| {r['delta_s']:+.3f} | {r['kernel_slowdown_pct']:+.2f}% "
                    f"| {r['delta_pp_of_c3_total']:+.3f} | {r['share_of_positive_regressions_pct']:.1f}% "
                    f"| {r['share_of_net_gap_pct']:+.1f}% |")
            lines.append("")
    lines.extend(["## 해석", "",
        "- Softmax kernel은 두 모델 모두 1k에서 약 16%, 32k에서 약 6.1% 느리다. Context가 길어질수록 attention 행렬이 커지면서 E2E에 대한 softmax 차이의 기여는 증가한다.",
        "- 1k에서 V KV quantization은 약 2.8배, Q RoPE는 약 2.7배 느리다. KV quant 호출 횟수는 Llama2에서 1024회, Llama3에서 256회이므로 Llama2에서 더 크게 기여한다.",
        "- 그림의 layout은 각 fused vector kernel의 양수 C4−C3 차이 합이다. 별도 layout kernel의 직접 측정값이 아니라 fusion 전후 차이로 분류한 값이다. 차이 전체를 layout 메모리 접근만의 비용이라고 확정할 수는 없다.", "",
        "## Artifacts", "",
        "- [全24 kernel × 全6 context × 2 model](kernel_breakdown.csv)",
        "- [Context별 절대 시간과 기여도](summary.csv)",
        "- [측정 case·인자·run ID·bitstream hash](measurement_sources.json)",
        "- [재현 script](analyze.py)",
        "- [증가와 감소 기여를 나눈 그림](delta_breakdown.png)", "",
        "재현: `conda run --no-capture-output -n vortex python analysis_workspace/latency_on_hw/diagnostics/prefill_c3_vs_c4_th16_20260920/analyze.py`", ""])
    (HERE / "README.md").write_text("\n".join(lines))


def chart(summaries):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    categories = ("Softmax", "KV quantization", "RoPE", "RMSNorm", "MLP Hadamard", "Other vector", "GEMM")
    colors = ("#d55e00", "#e69f00", "#cc79a7", "#b3a2cc", "#009e73", "#999999", "#0072b2")
    fig, axes = plt.subplots(2, 1, figsize=(10, 7), sharex=True)
    for ax, model in zip(axes, MODELS):
        ss = [r for r in summaries if r["model"] == model]
        pos, neg = [0.] * 6, [0.] * 6
        for category, color in zip(categories, colors):
            vals = [r[category + "_delta_pp"] for r in ss]
            up, down = [max(v, 0) for v in vals], [min(v, 0) for v in vals]
            ax.bar(range(6), up, bottom=pos, color=color, label=category)
            ax.bar(range(6), down, bottom=neg, color=color)
            pos = [a + b for a, b in zip(pos, up)]
            neg = [a + b for a, b in zip(neg, down)]
        net = [r["c4_slowdown_pct"] for r in ss]
        ax.plot(range(6), net, "ko--", label="Net C4 slowdown")
        for i, v in enumerate(net):
            ax.annotate(f"{v:.2f}%", (i, v), xytext=(0, 8), textcoords="offset points", ha="center", fontsize=9)
        ax.axhline(0, color="black", linewidth=.8)
        ax.set_title(model.replace("_", " "), loc="left")
        ax.set_ylabel("C4 - C3 / C3 total (pp)")
        ax.grid(axis="y", alpha=.2)
    axes[-1].set_xticks(range(6), [f"{s//1024}k" for s in SEQS])
    axes[-1].set_xlabel("Prefill context length (batch=1)")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=4, frameon=False)
    fig.tight_layout(rect=(0, 0, 1, .9))
    for suffix in ("png", "svg"):
        fig.savefig(HERE / f"delta_breakdown.{suffix}", dpi=170)
    plt.close(fig)


if __name__ == "__main__":
    analyze()

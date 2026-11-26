"""Plot absolute metrics for all 96 Qwen model workloads."""

from plot import BAR_PALETTE

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


def plot_absolute_metrics(out):
    df = pd.read_csv(out / "model_numbers.csv")
    assert len(df) == 96
    stages = [("prefill", 1)] + [("generation", b) for b in (1, 4, 64)]
    candidates = ("C1", "C2", "C3", "C4")
    lengths = [1024, 2048, 4096, 8192, 16384, 32768]
    styles = ["o", "s", "^", "D"]
    with plt.rc_context(
        {"font.size": 9, "pdf.fonttype": 42, "axes.spines.top": False, "axes.spines.right": False}
    ):
        fig, axes = plt.subplots(3, 4, figsize=(11.4, 6.7), sharex="col")
        for col in range(1, 4):
            axes[1, col].sharey(axes[1, 0])
            axes[2, col].sharey(axes[2, 0])
        for col in (2, 3):
            axes[0, col].sharey(axes[0, 1])
        for col, (stage, batch) in enumerate(stages):
            title = "Prefill · B1" if stage == "prefill" else f"Decode · B{batch}"
            axes[0, col].set_title(title, loc="left")
            for i, c in enumerate(candidates):
                sub = df[(df.stage == stage) & (df.batch == batch) & (df.candidate == c)].set_index(
                    "seq_len"
                )
                sub = sub.loc[lengths]
                time = sub["TTFT_ms" if stage == "prefill" else "mean_TPOT_ms"] / 1000.0
                series = [
                    time,
                    sub.latency_weighted_board_power_W,
                    sub.J_per_token_power_fpga_dequant_dynamic_W,
                ]
                for row, y in enumerate(series):
                    ax = axes[row, col]
                    assert np.isfinite(y).all() and y.gt(0).all()
                    ax.plot(
                        range(6),
                        y,
                        color=BAR_PALETTE[i],
                        marker=styles[i],
                        linewidth=1.55,
                        markersize=3.4,
                        label=c,
                    )
            for row, ylabel in enumerate(
                (
                    "TTFT (s)" if stage == "prefill" else "Mean TPOT (s)",
                    "Board power (W)",
                    "Energy (J/token)",
                )
            ):
                ax = axes[row, col]
                ax.set_ylabel(ylabel if col == 0 or (row == 0 and col == 1) else "")
                ax.grid(axis="y", alpha=0.24)
                if row in (0, 2):
                    ax.set_yscale("log")
            axes[2, col].set_xticks(range(6), [f"{n//1024}K" for n in lengths])
            axes[2, col].set_xlabel("Context (tokens)")
        handles, labels = axes[0, 0].get_legend_handles_labels()
        fig.legend(handles, labels, ncol=4, loc="upper center", frameon=False)
        fig.tight_layout(rect=(0, 0, 1, 0.94))
        for fmt in ("pdf", "png"):
            fig.savefig(out / ("model_metrics." + fmt), dpi=300, bbox_inches="tight")
        plt.close(fig)


def plot_qk(directory):
    data = pd.read_csv(directory / "decode_qk_first_step.csv").sort_values("gen_kv_len")
    assert len(data) == 3 and data[["C2_resolution", "C4_resolution"]].eq("measured").all().all()
    with plt.rc_context(
        {"font.size": 9, "axes.spines.top": False, "axes.spines.right": False, "pdf.fonttype": 42}
    ):
        fig, ax = plt.subplots(figsize=(5.5, 3.0), layout="constrained")
        x = np.arange(len(data))
        for offset, column, label, color in [
            (-0.18, "C2_ms", "C2 · FP16 TCU", "#2171B5"),
            (0.18, "C4_ms", "C4 · INT4 Q-ROW", "#74A45A"),
        ]:
            ax.bar(x + offset, data[column], width=0.34, color=color, label=label, zorder=2)
        ax.set(
            yscale="log",
            ylabel="QK kernel latency (ms)",
            xlabel="Initial context (tokens)",
            xticks=x,
            xticklabels=[f"{v//1024}K" for v in data.gen_kv_len],
            ylim=(0.1, 560),
        )
        for i, row in enumerate(data.itertuples()):
            ax.text(
                i,
                max(row.C2_ms, row.C4_ms) * 1.18,
                f"{row.C2_over_C4:.1f}×",
                ha="center",
                fontsize=8,
            )
        ax.grid(axis="y", alpha=0.24)
        ax.legend(loc="upper left", frameon=False, ncol=2)
        for fmt in ("pdf", "png"):
            fig.savefig(directory / ("decode_qk_first_step." + fmt), dpi=300)
        plt.close(fig)

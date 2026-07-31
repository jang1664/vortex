"""Generate Figure 10 from the cached WKV/WoQ synthesis breakdown."""

from __future__ import annotations

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
BREAKDOWN_CSV = HERE / "wkvwoq_breakdown.csv"
ONE_COL_WIDTH = 3.5

WKV_WOQ_GROUPS = [
    (
        "MXU",
        {
            "u_mxu",
        },
        "#17365d",
    ),
    (
        "Preprocess",
        {
            "u_pre_proc_pipe_buffer",
            "u_prealigner",
            "u_prealign_blk_idx_pipe",
            "u_prealign_max_exp_pipe",
            "u_in_pipe",
            "u_act_reduce",
            "u_zp_mul_out_reg",
            "u_act_reduce_shl_vec",
        },
        "#4c78a8",
    ),
    (
        "Postprocess",
        {
            "u_out_scaler_vec",
            "u_int2fp_vec",
            "u_accumulator_vec",
            "u_acc_rd_fifo",
            "u_merger_vec",
            "u_merge_out_reg",
            "u_scaler_bypass_pipe",
            "u_f32_to_f16_vec",
            *{
                f"gen_mxu_output_dly_{index}__u_mxu_output_dly_pipe"
                for index in range(32)
            },
        },
        "#b7c9e2",
    ),
    (
        "Misc",
        {
            "u_misc",
        },
        "#8c8c8c",
    ),
    (
        "Input scaler",
        {
            "u_in_scaler_vec",
        },
        "#2ca25f",
    ),
]


def load_grouped_wkv_woq_breakdown() -> dict[str, list[float] | list[str]]:
    """Load module rows and aggregate them into Figure 10 datapath groups."""
    if not BREAKDOWN_CSV.is_file():
        raise FileNotFoundError(f"missing Figure 10 input: {BREAKDOWN_CSV}")

    rows: dict[str, dict[str, float]] = {}
    reported_totals: dict[str, float] | None = None
    with BREAKDOWN_CSV.open(newline="") as input_file:
        for row in csv.DictReader(input_file):
            instance = row["instance"]
            if instance == "total":
                reported_totals = {
                    "wkv_power": float(row["WKV_uW"]) / 1000.0,
                    "woq_power": float(row["WoQ_uW"]) / 1000.0,
                    "wkv_area": float(row["WKV_area_um2"]) / 1e6,
                    "woq_area": float(row["WoQ_area_um2"]) / 1e6,
                }
                continue
            rows[instance] = {
                "wkv_power": float(row["WKV_uW"]) / 1000.0,
                "woq_power": float(row["WoQ_uW"]) / 1000.0,
                "wkv_area": float(row["WKV_area_um2"]) / 1e6,
                "woq_area": float(row["WoQ_area_um2"]) / 1e6,
            }

    assigned = [
        instance
        for _, members, _ in WKV_WOQ_GROUPS
        for instance in members
    ]
    duplicate_instances = sorted(
        {instance for instance in assigned if assigned.count(instance) > 1}
    )
    if duplicate_instances:
        raise ValueError(
            "Figure 10 assigns modules to multiple groups: "
            + ", ".join(duplicate_instances)
        )

    unknown_instances = sorted(set(rows) - set(assigned))
    missing_instances = sorted(set(assigned) - set(rows))
    if unknown_instances or missing_instances:
        details = []
        if unknown_instances:
            details.append("unassigned modules: " + ", ".join(unknown_instances))
        if missing_instances:
            details.append("missing modules: " + ", ".join(missing_instances))
        raise ValueError("Figure 10 grouping mismatch; " + "; ".join(details))

    if reported_totals is not None:
        for metric, reported_total in reported_totals.items():
            component_total = sum(row[metric] for row in rows.values())
            if abs(component_total - reported_total) > 1e-6:
                raise ValueError(
                    f"Figure 10 {metric} total mismatch: "
                    f"components={component_total}, total row={reported_total}"
                )

    def aggregate(metric: str) -> list[float]:
        return [
            sum(rows[instance][metric] for instance in members)
            for _, members, _ in WKV_WOQ_GROUPS
        ]

    return {
        "labels": [label for label, _, _ in WKV_WOQ_GROUPS],
        "colors": [color for _, _, color in WKV_WOQ_GROUPS],
        "wkv_power": aggregate("wkv_power"),
        "woq_power": aggregate("woq_power"),
        "wkv_area": aggregate("wkv_area"),
        "woq_area": aggregate("woq_area"),
    }


def normalize_to_wkv(
    wkv_values: list[float],
    woq_values: list[float],
) -> tuple[list[float], list[float]]:
    """Normalize both candidates to the corresponding WKV total."""
    wkv_total = sum(wkv_values)
    if wkv_total <= 0:
        raise ValueError("Figure 10 cannot normalize a zero-valued WKV total")
    return (
        [value / wkv_total for value in wkv_values],
        [value / wkv_total for value in woq_values],
    )


def fig10_wkv_vs_woq_relative_breakdown() -> tuple[Path, ...]:
    """Plot relative WKV/WoQ power and area breakdowns."""
    breakdown = load_grouped_wkv_woq_breakdown()
    labels = breakdown["labels"]
    colors = breakdown["colors"]
    wkv_power, woq_power = normalize_to_wkv(
        breakdown["wkv_power"],
        breakdown["woq_power"],
    )
    wkv_area, woq_area = normalize_to_wkv(
        breakdown["wkv_area"],
        breakdown["woq_area"],
    )

    with plt.rc_context(
        {
            "font.size": 4.5,
            "axes.titlesize": 4.5,
            "axes.labelsize": 4.5,
            "xtick.labelsize": 4.5,
            "ytick.labelsize": 4.5,
            "legend.fontsize": 4.5,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
            "svg.fonttype": "none",
        }
    ):
        figure, axes = plt.subplots(
            2,
            1,
            figsize=(ONE_COL_WIDTH, 1.44),
            gridspec_kw={"hspace": 0.45},
        )
        candidates = ["WKV", "WoQ"]

        def draw_relative_stacked_h(
            axis,
            wkv_values: list[float],
            woq_values: list[float],
            title: str,
        ):
            totals = [0.0, 0.0]
            handles = []
            for label, color, wkv_value, woq_value in zip(
                labels,
                colors,
                wkv_values,
                woq_values,
            ):
                values = [wkv_value, woq_value]
                bars = axis.barh(
                    candidates,
                    values,
                    left=totals,
                    height=0.42,
                    color=color,
                    label=label,
                    edgecolor="white",
                    linewidth=0.45,
                )
                handles.append(bars[0])
                totals = [
                    total + value for total, value in zip(totals, values)
                ]

            x_max = max(totals) * 1.14
            axis.set_xlim(0, x_max)
            axis.set_title(title)
            axis.set_xlabel("")
            axis.set_xticks([])
            axis.tick_params(
                axis="x",
                which="both",
                bottom=False,
                labelbottom=False,
            )
            axis.text(
                totals[0] + x_max * 0.015,
                0,
                f"{totals[0]:.1f}",
                ha="left",
                va="center",
            )
            axis.text(
                totals[1] + x_max * 0.015,
                1,
                f"{totals[1]:.2f}×",
                ha="left",
                va="center",
            )
            return handles, totals

        handles, power_totals = draw_relative_stacked_h(
            axes[0],
            wkv_power,
            woq_power,
            "power",
        )
        _, area_totals = draw_relative_stacked_h(
            axes[1],
            wkv_area,
            woq_area,
            "area",
        )

        figure.legend(
            handles,
            labels,
            loc="lower center",
            bbox_to_anchor=(0.5, 0.02),
            ncol=5,
            columnspacing=0.8,
            handlelength=1.2,
            handletextpad=0.4,
            framealpha=0.95,
        )
        figure.subplots_adjust(
            left=0.08,
            right=0.93,
            top=0.94,
            bottom=0.23,
            hspace=0.45,
        )
        outputs = []
        for extension in ("png", "pdf", "svg"):
            output = HERE / f"fig10_wkv_vs_woq_relative_breakdown.{extension}"
            figure.savefig(output, dpi=300, bbox_inches="tight")
            outputs.append(output)
        plt.close(figure)

    print(
        f"[fig10] wrote {', '.join(str(output) for output in outputs)}; "
        f"WoQ/WKV power={power_totals[1]:.3f}, "
        f"area={area_totals[1]:.3f}"
    )
    return tuple(outputs)


def main() -> None:
    fig10_wkv_vs_woq_relative_breakdown()


if __name__ == "__main__":
    main()

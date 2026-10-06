"""Batch-one input/output sweeps using prefill and decode-prefix components."""
from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
from typing import Sequence

import numpy as np
import pandas as pd

import prepare


DEFAULT_OUTPUT_TOKENS = (1, 4, 16, 64, 128)
CANDIDATES = ("C1", "C2", "C3", "C4")
COMPOSED_COLUMNS = (
    "model", "stage", "variant", "name", "app", "kind", "backend", "op",
    "batch", "prefill_seq_len", "gen_kv_len", "output_token_index", "out_tokens",
    "calls_per_forward", "fpga_cycle", "fpga_period_s", "weighted_latency_us",
    "compose_status", "power_pcie_avg_w", "power_idle_pcie_avg_w",
    "latency_resolution_kind", "power_resolution_kind",
)


def _token_values(values: str | Sequence[int], label: str) -> tuple[int, ...]:
    if isinstance(values, str):
        values = values.split(",")
    parsed = []
    for value in values:
        number = float(value)
        if not np.isfinite(number) or number <= 0 or not number.is_integer():
            raise ValueError(f"{label} must contain positive integers")
        parsed.append(int(number))
    if not parsed:
        raise ValueError(f"{label} cannot be empty")
    return tuple(sorted(set(parsed)))


def read_sweep_components(path: Path, models: Sequence[str]) -> pd.DataFrame:
    """Read only the small numeric/component subset of large composed CSVs."""
    frames = []
    for chunk in pd.read_csv(
        path, usecols=lambda column: column in COMPOSED_COLUMNS,
        chunksize=12000, low_memory=False,
    ):
        keep = chunk["model"].isin(models) & pd.to_numeric(chunk["batch"]).eq(1)
        if keep.any():
            frames.append(chunk.loc[keep])
    if not frames:
        raise ValueError("composed CSV has no batch-1 rows for the requested models")
    return pd.concat(frames, ignore_index=True)


def _validate_components(rows: pd.DataFrame, decode_steps: int) -> None:
    """Require every component's decode prefix, not just the union of its steps."""
    keys = ["model", "variant", "stage", "input_tokens", "name", "app", "backend", "op"]
    if rows.duplicated(keys + ["output_token_index"]).any():
        raise ValueError("duplicate prefill/decode component rows in the requested sweep")
    generation = rows.loc[rows["stage"].eq("generation")]
    if decode_steps:
        counts = generation.groupby(keys, dropna=False)["output_token_index"].agg(["count", "nunique"])
        if counts.empty or (counts.ne(decode_steps)).any().any():
            raise ValueError("incomplete decode prefix: each component needs every requested step")


def build_input_output_breakdown(
    composed: pd.DataFrame,
    *,
    models: Sequence[str],
    source_out_tokens: int,
    input_tokens: str | Sequence[int] | None = None,
    output_tokens: str | Sequence[int] = DEFAULT_OUTPUT_TOKENS,
    power_metric: str = "power_fpga_dequant_dynamic_W",
) -> pd.DataFrame:
    """Sum prefill plus O-1 decode steps; divide total joules by O (batch=1)."""
    outputs = _token_values(output_tokens, "output tokens")
    max_decode = max(outputs) - 1
    if source_out_tokens <= 0 or max_decode > source_out_tokens:
        raise ValueError("requested output length exceeds the source decode-step count")
    required = set(COMPOSED_COLUMNS) - {"latency_resolution_kind", "power_resolution_kind"}
    missing = required - set(composed.columns)
    if missing:
        raise ValueError(f"composed CSV missing columns: {sorted(missing)}")
    label_map = prepare.plot_label_maps(include_c4_alone=False)["variant"]
    rows = composed.loc[
        composed["model"].isin(models)
        & pd.to_numeric(composed["batch"], errors="coerce").eq(1)
        & composed["variant"].map(label_map).isin(CANDIDATES)
    ].copy()
    rows["candidate"] = rows["variant"].map(label_map)
    rows["stage"] = rows["stage"].astype(str).str.lower()
    rows["input_tokens"] = pd.to_numeric(rows["prefill_seq_len"], errors="coerce").where(
        rows["stage"].eq("prefill"), pd.to_numeric(rows["gen_kv_len"], errors="coerce")
    )
    rows["output_token_index"] = pd.to_numeric(rows["output_token_index"], errors="coerce").fillna(0)
    rows = rows.loc[
        rows["stage"].eq("prefill")
        | (rows["stage"].eq("generation")
           & pd.to_numeric(rows["out_tokens"], errors="coerce").eq(source_out_tokens)
           & rows["output_token_index"].between(1, max_decode))
    ].copy()
    available = [set(rows.loc[rows["model"].eq(model) & rows["stage"].eq("prefill"), "input_tokens"])
                 for model in models]
    common_inputs = set.intersection(*available) if available else set()
    inputs = _token_values(sorted(common_inputs) if input_tokens is None else input_tokens, "input tokens")
    if not set(inputs).issubset(common_inputs):
        raise ValueError("requested input length has no batch-1 prefill data for every model")
    rows = rows.loc[rows["input_tokens"].isin(inputs)].copy()
    stages = ("prefill", "generation") if max_decode else ("prefill",)
    present = set(rows.groupby(["model", "candidate", "input_tokens", "stage"]).groups)
    for model in models:
        for candidate in CANDIDATES:
            for length in inputs:
                for stage in stages:
                    if (model, candidate, length, stage) not in present:
                        raise ValueError(f"missing batch-1 {stage} data: {model}/{candidate}/{length}")
    if not rows["compose_status"].isin(("pass", "estimated")).all():
        raise ValueError("requested sweep contains unresolved composed components")
    if not rows["output_token_index"].mod(1).eq(0).all():
        raise ValueError("decode step indices must be integers")
    _validate_components(rows, max_decode)

    latency = rows.loc[prepare.filter_latency_dequantization_kernels(rows)].copy()
    latency["latency_s"] = pd.to_numeric(latency["weighted_latency_us"], errors="coerce") / 1e6
    if not (np.isfinite(latency["latency_s"]) & latency["latency_s"].ge(0)).all():
        raise ValueError("missing or invalid latency in the requested sweep")
    energy_components = rows.loc[prepare.filter_energy_dequantization_kernels(rows)].copy()
    for column in ("fpga_period_s", "calls_per_forward"):
        numeric = pd.to_numeric(energy_components[column], errors="coerce")
        if not (np.isfinite(numeric) & numeric.gt(0)).all():
            raise ValueError(f"missing or invalid {column} in the requested sweep")
    energy = prepare._vectorized_energy_rows(
        energy_components,
        power_metrics=(power_metric,),
    )
    if (energy[["energy_missing_cycle", "energy_missing_power"]].any().any()
        or not (np.isfinite(energy["kernel_energy_j"]) & energy["kernel_energy_j"].ge(0)).all()
        or not (pd.to_numeric(energy["fpga_period_s"], errors="coerce") > 0).all()):
        raise ValueError("missing or invalid cycle/clock/power data in the requested sweep")

    keys = ["model", "candidate", "input_tokens"]
    def totals(frame: pd.DataFrame, value: str):
        prefill = frame.loc[frame["stage"].eq("prefill")].groupby(keys)[value].sum()
        decode = frame.loc[frame["stage"].eq("generation")].groupby(keys + ["output_token_index"])[value].sum()
        return prefill, decode.groupby(level=keys).cumsum()

    prefill_latency, decode_latency = totals(latency, "latency_s")
    prefill_energy, decode_energy = totals(energy, "kernel_energy_j")
    variant_map = rows.set_index("candidate")["variant"].to_dict()
    records = []
    for model in models:
        for length in inputs:
            for output in outputs:
                for candidate in CANDIDATES:
                    key = (model, candidate, length)
                    step = output - 1
                    pl = float(prefill_latency.loc[key])
                    pe = float(prefill_energy.loc[key])
                    dl = float(decode_latency.loc[key + (step,)]) if step else 0.0
                    de = float(decode_energy.loc[key + (step,)]) if step else 0.0
                    records.append(dict(
                        model=model, candidate=candidate, variant=variant_map[candidate], batch=1,
                        input_tokens=length, output_tokens=output, source_out_tokens=source_out_tokens,
                        decode_steps=step, prefill_latency_s=pl, decode_latency_s=dl, e2e_latency_s=pl+dl,
                        prefill_energy_j=pe, decode_energy_j=de,
                        prefill_energy_per_output_token_j=pe/output,
                        decode_energy_per_output_token_j=de/output,
                        energy_per_output_token_j=(pe+de)/output, power_metric=power_metric,
                    ))
    return pd.DataFrame.from_records(records)


def _input_output_sort_key(label: str) -> tuple[float, int]:
    import plot
    length, output = label.strip("[]").split(":")
    return plot._seq_sort_key(length), int(output)


def run_input_output_sweep(
    composed_csv: Path,
    out_dir: Path,
    *,
    models: Sequence[str],
    source_out_tokens: int,
    input_tokens: str | Sequence[int] | None,
    output_tokens: str | Sequence[int],
    power_metric: str,
    knobs,
    y_scale: str = "linear",
    figure_width: float | None = None,
) -> None:
    import plot

    components = read_sweep_components(composed_csv, models)
    data = build_input_output_breakdown(
        components, models=models, source_out_tokens=source_out_tokens,
        input_tokens=input_tokens, output_tokens=output_tokens, power_metric=power_metric,
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    data.to_csv(out_dir / "input_output_breakdown.csv", index=False)
    labels = plot.LLAMA_MODEL_LABELS
    row_specs = tuple((labels[model], "E2E") for model in models)
    group_count = data[["input_tokens", "output_tokens"]].drop_duplicates().shape[0]
    style = replace(
        knobs, figsize=(figure_width or max(7.16, group_count * 0.68 + 2), 3.1), row_height=3.1,
        dpi=min(knobs.dpi, 300), title=None, relative=True,
        relative_baseline_candidate=plot.RELATIVE_BASELINE_CANDIDATE,
        stack_groups=(), stack_palette=("#08306B", "#6BAED6"), legend_order=("Prefill", "Decode"),
        subplot_title_template="{model}", subplot_title_replacements=(), subplot_title_fontsize=12,
        stage_y_labels={}, stage_y_lims={}, y_lim=None,
        x_label="[input tokens:output tokens]", x_group_axis="batch", x_group_labels_inside=True,
        x_tick_label_rotation=45, stage_x_tick_label_rotations={}, stage_bar_width_scales={},
        axis_label_fontsize=11, tick_label_fontsize=8,
        legend_position="top", legend_title=None, legend_ncol=2, legend_fontsize=12, legend_y=0.99,
        legend_loc=None, legend_bbox_to_anchor=None,
        tight_layout_rect=(0, 0, 1, 0.94), tight_layout_pad=0.2, tight_layout_h_pad=0.5,
        stage_subplot_gap_scales={}, stage_transition_gap_scale=1, save_pad_inches=0.05,
    )
    specifications = (
        ("latency", "prefill_latency_s", "decode_latency_s", "Relative E2E latency (C4=1)",
         "llama_input_output_latency_prefill_decode_stacked.png"),
        ("energy", "prefill_energy_per_output_token_j", "decode_energy_per_output_token_j",
         "Relative energy/token (C4=1)",
         f"llama_input_output_energy_per_token_{plot._energy_plot_metric_label(power_metric)}_prefill_decode_stacked.png"),
    )
    for metric, prefill, decode, y_label, filename in specifications:
        model_csvs = []
        for model in models:
            subset = data.loc[data["model"].eq(model)]
            table = pd.DataFrame({
                "out_tokens": source_out_tokens, "stage": "E2E", "batch": 1,
                "seq": [f"[{plot._format_seq_for_excel(s)}:{o}]"
                        for s, o in zip(subset["input_tokens"], subset["output_tokens"])],
                "candidate": subset["candidate"], "Prefill": subset[prefill], "Decode": subset[decode],
                "total": subset[prefill] + subset[decode],
            })
            path = out_dir / "data" / metric / model / "excel_figure_data.csv"
            path.parent.mkdir(parents=True, exist_ok=True)
            table.to_csv(path, index=False)
            model_csvs.append((model, labels[model], path))
        plot.plot_model_stacked_bars(
            model_csvs, out_dir, filename=filename, data_label=f"input/output {metric}",
            knobs=replace(style, y_label=y_label), row_specs=row_specs,
            seq_sort_key=_input_output_sort_key, candidate_tick_labels=True, y_scale=y_scale,
        )
    manifest = dict(
        composed_csv=str(composed_csv.resolve()), source_out_tokens=source_out_tokens,
        batch=1, models=list(models), input_tokens=sorted(data["input_tokens"].unique().tolist()),
        output_tokens=sorted(data["output_tokens"].unique().tolist()), power_metric=power_metric,
        y_scale=y_scale, relative=True, relative_baseline_candidate=style.relative_baseline_candidate,
        value_labels=style.value_labels, hadamard="included", area_normalized=False,
        relative_formula="each segment / C4 total for the same model, input and output length",
        latency_formula="prefill + sum(decode steps 1 through output_tokens-1)",
        energy_formula="(prefill joules + decode-prefix joules) / output_tokens",
        rows=len(data), source_size_bytes=composed_csv.stat().st_size,
        latency_resolution_counts=components.get("latency_resolution_kind", pd.Series(dtype=str)).value_counts().to_dict(),
        power_resolution_counts=components.get("power_resolution_kind", pd.Series(dtype=str)).value_counts().to_dict(),
    )
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {out_dir / 'input_output_breakdown.csv'} ({len(data)} rows)")

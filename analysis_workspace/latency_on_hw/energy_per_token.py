from __future__ import annotations

import csv
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


PREFILL_STAGE = "prefill"
GENERATION_STAGE = "generation"
DEFAULT_STAGE_ORDER = (PREFILL_STAGE, GENERATION_STAGE)
POWER_SUMMARY_FIELDS = (
    "stage",
    "batch",
    "seq_len",
    "variant",
    "tokens",
    "total_energy_j",
    "joules_per_token",
    "component_count",
    "energy_component_count",
    "measured_power_count",
    "imputed_power_count",
    "missing_power_count",
    "missing_latency_count",
    "complete",
)


@dataclass(frozen=True)
class PowerCandidate:
    row: Mapping[str, Any]
    fpga_bin_label: str
    app: str
    args: str
    stage: str
    shape: dict[str, Any]
    numeric_shape: dict[str, float]
    categorical_shape: dict[str, str]
    power_avg_w: float
    power_samples: int


@dataclass(frozen=True)
class PowerResolution:
    candidate: PowerCandidate | None
    resolution: str
    scope: str
    distance: float | None


@dataclass(frozen=True)
class EnergyPlotResult:
    rows: Any
    summary: Any
    rows_csv: Path
    summary_csv: Path
    figure_path: Path


class PowerResolver:
    def __init__(self, candidates: Iterable[PowerCandidate]) -> None:
        self._candidates = list(candidates)
        self._by_exact: dict[tuple[str, str, str], list[PowerCandidate]] = {}
        self._by_fpga_app: dict[tuple[str, str], list[PowerCandidate]] = {}
        self._by_app: dict[str, list[PowerCandidate]] = {}
        for candidate in self._candidates:
            self._by_exact.setdefault(
                (candidate.fpga_bin_label, candidate.app, candidate.args),
                [],
            ).append(candidate)
            self._by_fpga_app.setdefault(
                (candidate.fpga_bin_label, candidate.app),
                [],
            ).append(candidate)
            self._by_app.setdefault(candidate.app, []).append(candidate)

    @property
    def candidates(self) -> list[PowerCandidate]:
        return list(self._candidates)

    def resolve(self, row: Mapping[str, Any]) -> PowerResolution:
        fpga_bin_label = _target_fpga_bin_label(row)
        app = _text(row.get("app"))
        args = _text(row.get("args"))
        exact = self._by_exact.get((fpga_bin_label, app, args), ())
        if exact:
            return PowerResolution(
                candidate=_best_exact_candidate(exact),
                resolution="measured",
                scope="exact",
                distance=0.0,
            )

        target_shape = _shape_for_row(row)
        target_numeric, target_categorical = _split_shape(target_shape)
        target_stage = _stage(row)
        scoped_candidates = self._by_fpga_app.get((fpga_bin_label, app), ())
        scope = "same_fpga_app"
        if not scoped_candidates:
            scoped_candidates = self._by_app.get(app, ())
            scope = "same_app"
        if not scoped_candidates:
            return PowerResolution(
                candidate=None,
                resolution="missing",
                scope="none",
                distance=None,
            )

        best_distance = math.inf
        best_candidate: PowerCandidate | None = None
        for candidate in scoped_candidates:
            distance = _shape_distance(
                target_numeric=target_numeric,
                target_categorical=target_categorical,
                target_stage=target_stage,
                candidate=candidate,
            )
            if _candidate_rank(distance, target_stage, candidate) < _candidate_rank(
                best_distance,
                target_stage,
                best_candidate,
            ):
                best_distance = distance
                best_candidate = candidate

        return PowerResolution(
            candidate=best_candidate,
            resolution="imputed" if best_candidate is not None else "missing",
            scope=scope if best_candidate is not None else "none",
            distance=best_distance if best_candidate is not None else None,
        )


def read_power_records(raw_dbs: Sequence[str | Path]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for raw_db in raw_dbs:
        path = Path(raw_db)
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            rows.extend(dict(row) for row in reader)
    return rows


def build_power_resolver(raw_dbs: Sequence[str | Path]) -> PowerResolver:
    return PowerResolver(_power_candidates(read_power_records(raw_dbs)))


def energy_rows_from_records(
    composed_records: Iterable[Mapping[str, Any]],
    raw_dbs: Sequence[str | Path],
    *,
    idle_power_w: float,
    include_idle_power: bool = False,
) -> list[dict[str, Any]]:
    resolver = build_power_resolver(raw_dbs)
    rows: list[dict[str, Any]] = []
    for row in composed_records:
        rows.append(
            energy_row_from_record(
                row,
                resolver=resolver,
                idle_power_w=idle_power_w,
                include_idle_power=include_idle_power,
            )
        )
    return rows


def energy_row_from_record(
    row: Mapping[str, Any],
    *,
    resolver: PowerResolver,
    idle_power_w: float,
    include_idle_power: bool = False,
) -> dict[str, Any]:
    resolution = resolver.resolve(row)
    candidate = resolution.candidate
    weighted_latency_us = _weighted_latency_us(row)
    tokens = _token_count(row)

    raw_power_w: float | None = None
    effective_power_w: float | None = None
    if candidate is not None:
        raw_power_w = candidate.power_avg_w
        effective_power_w = raw_power_w if include_idle_power else max(raw_power_w - idle_power_w, 0.0)

    kernel_energy_j: float | None = None
    joules_per_token_component: float | None = None
    if weighted_latency_us is not None and effective_power_w is not None:
        kernel_energy_j = weighted_latency_us * effective_power_w / 1_000_000.0
        if tokens and tokens > 0:
            joules_per_token_component = kernel_energy_j / tokens

    output = dict(row)
    output.update(
        {
            "energy_stage": _stage(row),
            "energy_batch": _batch(row),
            "energy_seq_len": _seq_len(row),
            "energy_tokens": tokens,
            "power_resolution": resolution.resolution,
            "power_match_scope": resolution.scope,
            "power_distance": resolution.distance,
            "power_source_case_id": candidate.row.get("case_id", "") if candidate else "",
            "power_source_fpga_bin_label": candidate.fpga_bin_label if candidate else "",
            "power_source_app": candidate.app if candidate else "",
            "power_source_args": candidate.args if candidate else "",
            "power_source_shape_json": candidate.row.get("shape_json", "") if candidate else "",
            "power_source_samples": candidate.power_samples if candidate else "",
            "raw_power_w": raw_power_w,
            "idle_power_w": idle_power_w,
            "include_idle_power": include_idle_power,
            "effective_power_w": effective_power_w,
            "energy_weighted_latency_us": weighted_latency_us,
            "kernel_energy_j": kernel_energy_j,
            "joules_per_token_component": joules_per_token_component,
            "energy_missing_latency": weighted_latency_us is None,
            "energy_missing_power": candidate is None,
        }
    )
    return output


def summarize_energy_rows(rows: Iterable[Mapping[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, Any, Any, str], dict[str, Any]] = {}
    for row in rows:
        stage = _text(row.get("energy_stage")) or _stage(row)
        batch = row.get("energy_batch")
        if batch in (None, ""):
            batch = _batch(row)
        seq_len = row.get("energy_seq_len")
        if seq_len in (None, ""):
            seq_len = _seq_len(row)
        variant = _text(row.get("variant"))
        key = (stage, batch, seq_len, variant)
        group = groups.setdefault(
            key,
            {
                "stage": stage,
                "batch": batch,
                "seq_len": seq_len,
                "variant": variant,
                "tokens": row.get("energy_tokens") or _token_count(row),
                "total_energy_j": 0.0,
                "component_count": 0,
                "energy_component_count": 0,
                "measured_power_count": 0,
                "imputed_power_count": 0,
                "missing_power_count": 0,
                "missing_latency_count": 0,
            },
        )
        group["component_count"] += 1
        energy = _to_float(row.get("kernel_energy_j"))
        if energy is not None:
            group["total_energy_j"] += energy
            group["energy_component_count"] += 1
        if row.get("energy_missing_latency") is True or _to_float(row.get("energy_weighted_latency_us")) is None:
            group["missing_latency_count"] += 1
        resolution = _text(row.get("power_resolution"))
        if resolution == "measured":
            group["measured_power_count"] += 1
        elif resolution == "imputed":
            group["imputed_power_count"] += 1
        else:
            group["missing_power_count"] += 1

    summary = []
    for group in groups.values():
        tokens = _to_float(group.get("tokens"))
        complete = (
            group["missing_power_count"] == 0
            and group["missing_latency_count"] == 0
            and tokens is not None
            and tokens > 0
        )
        group["complete"] = complete
        has_energy = group["energy_component_count"] > 0 and tokens is not None and tokens > 0
        group["joules_per_token"] = group["total_energy_j"] / tokens if has_energy else None
        summary.append(group)

    summary.sort(key=_summary_sort_key)
    return summary


def write_energy_csvs(
    rows: Sequence[Mapping[str, Any]],
    summary: Sequence[Mapping[str, Any]],
    out_dir: str | Path,
) -> tuple[Path, Path]:
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    rows_csv = out_path / "energy_kernel_rows.csv"
    summary_csv = out_path / "energy_summary.csv"
    _write_dict_csv(rows_csv, rows)
    _write_dict_csv(summary_csv, summary, preferred_fields=POWER_SUMMARY_FIELDS)
    return rows_csv, summary_csv


def plot_energy_per_token(
    plot_result: Any,
    *,
    raw_dbs: Sequence[str | Path],
    out_dir: str | Path,
    idle_power_w: float,
    include_idle_power: bool = False,
    title: str | None = None,
    label_maps: Mapping[str, Mapping[Any, str]] | None = None,
    value_orders: Mapping[str, Sequence[Any]] | None = None,
    palette: Sequence[str] | None = None,
) -> EnergyPlotResult:
    pd, plt = _import_plotting_modules()
    records = _records_from_plot_result(plot_result)
    rows = energy_rows_from_records(
        records,
        raw_dbs,
        idle_power_w=idle_power_w,
        include_idle_power=include_idle_power,
    )
    summary = summarize_energy_rows(rows)
    rows_csv, summary_csv = write_energy_csvs(rows, summary, out_dir)

    summary_df = pd.DataFrame(summary)
    rows_df = pd.DataFrame(rows)
    figure_path = Path(out_dir) / "energy_per_token.png"
    _plot_summary_dataframe(
        summary_df,
        figure_path,
        title=title,
        label_maps=label_maps or {},
        value_orders=value_orders or {},
        palette=palette,
        include_idle_power=include_idle_power,
    )
    return EnergyPlotResult(
        rows=rows_df,
        summary=summary_df,
        rows_csv=rows_csv,
        summary_csv=summary_csv,
        figure_path=figure_path,
    )


def _power_candidates(rows: Iterable[Mapping[str, Any]]) -> list[PowerCandidate]:
    candidates: list[PowerCandidate] = []
    for row in rows:
        power_avg_w = _to_float(row.get("power_avg_w"))
        power_samples = _to_int(row.get("power_samples"))
        if power_avg_w is None or power_samples is None or power_samples <= 0:
            continue
        shape = _shape_for_row(row)
        numeric_shape, categorical_shape = _split_shape(shape)
        candidates.append(
            PowerCandidate(
                row=row,
                fpga_bin_label=_text(row.get("fpga_bin_label")),
                app=_text(row.get("app")),
                args=_text(row.get("args")),
                stage=_stage(row),
                shape=shape,
                numeric_shape=numeric_shape,
                categorical_shape=categorical_shape,
                power_avg_w=power_avg_w,
                power_samples=power_samples,
            )
        )
    return candidates


def _records_from_plot_result(plot_result: Any) -> list[Mapping[str, Any]]:
    composed = getattr(plot_result, "composed", plot_result)
    if hasattr(composed, "to_dict"):
        return list(composed.to_dict(orient="records"))
    return list(composed)


def _import_plotting_modules() -> tuple[Any, Any]:
    try:
        import matplotlib.pyplot as plt
        import pandas as pd
    except ImportError as exc:
        raise RuntimeError(
            "plot_energy_per_token requires pandas and matplotlib; "
            "the CSV-only helpers can be used without those packages"
        ) from exc
    return pd, plt


def _plot_summary_dataframe(
    summary_df: Any,
    figure_path: Path,
    *,
    title: str | None,
    label_maps: Mapping[str, Mapping[Any, str]],
    value_orders: Mapping[str, Sequence[Any]],
    palette: Sequence[str] | None,
    include_idle_power: bool,
) -> None:
    _, plt = _import_plotting_modules()
    figure_path.parent.mkdir(parents=True, exist_ok=True)
    if summary_df.empty:
        fig, ax = plt.subplots(figsize=(8, 3))
        ax.text(0.5, 0.5, "No energy rows", ha="center", va="center")
        ax.axis("off")
        fig.savefig(figure_path, bbox_inches="tight", dpi=160)
        plt.close(fig)
        return

    plottable = summary_df[summary_df["joules_per_token"].notna()].copy()
    if plottable.empty:
        fig, ax = plt.subplots(figsize=(9, 3))
        ax.text(0.5, 0.5, "No plottable energy rows", ha="center", va="center")
        ax.axis("off")
        fig.savefig(figure_path, bbox_inches="tight", dpi=160)
        plt.close(fig)
        return

    stages = _ordered_values(plottable["stage"].tolist(), value_orders.get("stage"), default_order=DEFAULT_STAGE_ORDER)
    batches = _ordered_numeric_values(plottable["batch"].tolist())
    seq_values = _ordered_numeric_values(plottable["seq_len"].tolist())
    variants = _ordered_values(plottable["variant"].tolist(), value_orders.get("variant"))
    colors = list(palette or _default_palette())

    nrows = max(len(stages), 1)
    ncols = max(len(batches), 1)
    fig_width = max(8.0, 3.2 * ncols + 1.5)
    fig_height = max(3.6, 3.0 * nrows + 1.0)
    fig, axes = plt.subplots(nrows, ncols, squeeze=False, figsize=(fig_width, fig_height), sharey=False)
    width = min(0.75 / max(len(variants), 1), 0.22)

    for row_index, stage in enumerate(stages):
        for col_index, batch in enumerate(batches):
            ax = axes[row_index][col_index]
            subset = plottable[
                (plottable["stage"].astype(str) == str(stage))
                & (plottable["batch"].astype(str) == str(batch))
            ]
            x_positions = list(range(len(seq_values)))
            for variant_index, variant in enumerate(variants):
                offset = (variant_index - (len(variants) - 1) / 2.0) * width
                values = []
                complete_values = []
                for seq_len in seq_values:
                    matched = subset[
                        (subset["variant"].astype(str) == str(variant))
                        & (subset["seq_len"].astype(str) == str(seq_len))
                    ]
                    if matched.empty:
                        values.append(math.nan)
                        complete_values.append(True)
                    else:
                        values.append(float(matched.iloc[0]["joules_per_token"]))
                        complete_values.append(bool(matched.iloc[0]["complete"]))
                bars = ax.bar(
                    [pos + offset for pos in x_positions],
                    values,
                    width=width,
                    label=_label("variant", variant, label_maps),
                    color=colors[variant_index % len(colors)],
                    edgecolor="#222222",
                    linewidth=0.5,
                )
                for bar, is_complete in zip(bars, complete_values):
                    if not is_complete:
                        bar.set_hatch("//")
                        bar.set_alpha(0.7)
            ax.set_title(
                f"{_label('stage', stage, label_maps)}, batch={_format_value(batch)}",
                fontsize=10,
            )
            ax.set_xticks(x_positions)
            ax.set_xticklabels([_format_value(value) for value in seq_values], rotation=0)
            ax.set_xlabel("sequence length")
            ax.set_ylabel("J/token")
            ax.grid(axis="y", color="#dddddd", linewidth=0.7)
            ax.set_axisbelow(True)

    handles, labels = axes[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 1.02), ncol=min(len(labels), 4))
    if not plottable["complete"].astype(bool).all():
        fig.text(
            0.5,
            -0.01,
            "Hatched bars have at least one kernel without a matched or imputed power value.",
            ha="center",
            va="top",
            fontsize=9,
        )
    default_title = "E2E energy per token"
    power_mode = "including idle power" if include_idle_power else "idle power subtracted"
    fig.suptitle(f"{title or default_title} ({power_mode})", y=1.08, fontsize=13)
    fig.tight_layout()
    fig.savefig(figure_path, bbox_inches="tight", dpi=180)
    plt.close(fig)


def _shape_for_row(row: Mapping[str, Any]) -> dict[str, Any]:
    shape = _parse_shape(row.get("shape_json"))
    for key in ("batch", "seq_len"):
        value = row.get(key)
        if value not in (None, ""):
            shape.setdefault(key, value)
    return _normalize_shape_keys(shape)


def _parse_shape(value: Any) -> dict[str, Any]:
    if value in (None, ""):
        return {}
    if isinstance(value, Mapping):
        return dict(value)
    if not isinstance(value, str):
        return {}
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return {}
    return dict(parsed) if isinstance(parsed, Mapping) else {}


def _normalize_shape_keys(shape: Mapping[str, Any]) -> dict[str, Any]:
    normalized = {}
    for key, value in shape.items():
        normalized[str(key).strip().lower()] = value
    return normalized


def _split_shape(shape: Mapping[str, Any]) -> tuple[dict[str, float], dict[str, str]]:
    numeric: dict[str, float] = {}
    categorical: dict[str, str] = {}
    for key, value in shape.items():
        number = _to_float(value)
        if number is not None:
            numeric[key] = number
        elif value not in (None, ""):
            categorical[key] = str(value)
    return numeric, categorical


def _shape_distance(
    *,
    target_numeric: Mapping[str, float],
    target_categorical: Mapping[str, str],
    target_stage: str,
    candidate: PowerCandidate,
) -> float:
    distance = 0.0
    numeric_keys = set(target_numeric) | set(candidate.numeric_shape)
    for key in numeric_keys:
        left = target_numeric.get(key)
        right = candidate.numeric_shape.get(key)
        if left is None or right is None:
            distance += 4.0
        else:
            distance += abs(math.log2((max(left, 0.0) + 1.0) / (max(right, 0.0) + 1.0)))

    categorical_keys = set(target_categorical) | set(candidate.categorical_shape)
    for key in categorical_keys:
        left = target_categorical.get(key)
        right = candidate.categorical_shape.get(key)
        if left is None or right is None:
            distance += 1.0
        elif left != right:
            distance += 2.0

    if target_stage and candidate.stage and target_stage != candidate.stage:
        distance += 1.0
    return distance


def _candidate_rank(
    distance: float,
    target_stage: str,
    candidate: PowerCandidate | None,
) -> tuple[float, int, int, str, str]:
    if candidate is None:
        return (math.inf, 1, 0, "", "")
    stage_mismatch = int(bool(target_stage and candidate.stage and target_stage != candidate.stage))
    return (
        distance,
        stage_mismatch,
        -candidate.power_samples,
        candidate.fpga_bin_label,
        candidate.args,
    )


def _best_exact_candidate(candidates: Iterable[PowerCandidate]) -> PowerCandidate:
    return min(candidates, key=lambda candidate: (-candidate.power_samples, candidate.args))


def _weighted_latency_us(row: Mapping[str, Any]) -> float | None:
    weighted = _to_float(row.get("weighted_latency_us"))
    if weighted is not None:
        return weighted
    latency = _to_float(row.get("latency_us"))
    calls = _to_float(row.get("calls_per_forward")) or 1.0
    return latency * calls if latency is not None else None


def _token_count(row: Mapping[str, Any]) -> float | None:
    stage = _stage(row)
    batch = _batch(row)
    seq_len = _seq_len(row)
    if batch is None:
        return None
    if stage == GENERATION_STAGE:
        return batch
    if seq_len is None:
        return None
    return batch * seq_len


def _batch(row: Mapping[str, Any]) -> int | None:
    for key in ("batch", "energy_batch"):
        value = _to_int(row.get(key))
        if value is not None:
            return value
    shape = _shape_for_row(row)
    value = _to_int(shape.get("batch"))
    if value is not None:
        return value
    match = re.search(r"(?:^|_)batch(\d+)(?:_|$)", _text(row.get("case_id")))
    return int(match.group(1)) if match else None


def _seq_len(row: Mapping[str, Any]) -> int | None:
    for key in ("seq_len", "energy_seq_len"):
        value = _to_int(row.get(key))
        if value is not None:
            return value
    shape = _shape_for_row(row)
    for key in ("seq_len", "seq", "seqq", "seqk", "tokens"):
        value = _to_int(shape.get(key))
        if value is not None:
            return value
    case_id = _text(row.get("case_id"))
    for pattern in (
        r"(?:^|_)prefill_seq_len(\d+)(?:_|$)",
        r"(?:^|_)gen_kv_len(\d+)(?:_|$)",
        r"(?:^|_)generation_seq_len(\d+)(?:_|$)",
        r"(?:^|_)seq_len(\d+)(?:_|$)",
    ):
        match = re.search(pattern, case_id)
        if match:
            return int(match.group(1))
    return None


def _stage(row: Mapping[str, Any]) -> str:
    return _text(row.get("stage") or row.get("energy_stage")).lower()


def _target_fpga_bin_label(row: Mapping[str, Any]) -> str:
    for key in ("expected_fpga_bin_label", "fpga_bin_label"):
        value = _text(row.get(key))
        if value:
            return value
    labels = _text(row.get("source_fpga_bin_labels"))
    if labels:
        return labels.split(";")[0].strip()
    return ""


def _summary_sort_key(row: Mapping[str, Any]) -> tuple[Any, ...]:
    stage = _text(row.get("stage"))
    try:
        stage_index = DEFAULT_STAGE_ORDER.index(stage)
    except ValueError:
        stage_index = len(DEFAULT_STAGE_ORDER)
    return (
        stage_index,
        _numeric_sort_value(row.get("batch")),
        _numeric_sort_value(row.get("seq_len")),
        _text(row.get("variant")),
    )


def _ordered_values(
    values: Sequence[Any],
    order: Sequence[Any] | None = None,
    *,
    default_order: Sequence[Any] = (),
) -> list[Any]:
    unique = list(dict.fromkeys(values))
    configured = list(order or default_order)
    ordered = [value for value in configured if str(value) in {str(item) for item in unique}]
    ordered.extend(sorted((value for value in unique if str(value) not in {str(item) for item in ordered}), key=str))
    return ordered


def _ordered_numeric_values(values: Sequence[Any]) -> list[Any]:
    unique = list(dict.fromkeys(values))
    return sorted(unique, key=_numeric_sort_value)


def _numeric_sort_value(value: Any) -> tuple[int, float | str]:
    number = _to_float(value)
    if number is None:
        return (1, _text(value))
    return (0, number)


def _label(axis: str, value: Any, label_maps: Mapping[str, Mapping[Any, str]]) -> str:
    axis_map = label_maps.get(axis, {})
    if value in axis_map:
        return str(axis_map[value])
    text_value = str(value)
    for raw_value, label in axis_map.items():
        if str(raw_value) == text_value:
            return str(label)
    return _format_value(value)


def _format_value(value: Any) -> str:
    number = _to_float(value)
    if number is not None and number.is_integer():
        return str(int(number))
    return str(value)


def _default_palette() -> tuple[str, ...]:
    return (
        "#08306B",
        "#2171B5",
        "#6BAED6",
        "#00441B",
        "#238B45",
        "#74C476",
        "#7F2704",
        "#D94801",
    )


def _write_dict_csv(
    path: Path,
    rows: Sequence[Mapping[str, Any]],
    *,
    preferred_fields: Sequence[str] = (),
) -> None:
    fieldnames = list(preferred_fields)
    for row in rows:
        for field in row:
            if field not in fieldnames:
                fieldnames.append(field)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: _csv_value(row.get(field)) for field in fieldnames})


def _csv_value(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return value


def _to_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    if isinstance(value, bool):
        return float(value)
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _to_int(value: Any) -> int | None:
    number = _to_float(value)
    if number is None:
        return None
    return int(number)


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    return str(value)

"""Rebuild the Qwen3 model tables and paper figures from a single-board run."""

import argparse
import json
from pathlib import Path
import sys

import numpy as np
import pandas as pd

FLOW = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(FLOW), str(FLOW.parents[1])]
import plot
import prepare
from metric_figures import plot_absolute_metrics, plot_qk
from paper_figures import paper_figures


def verify_board(raw):
    keys = ("hostname", "xrt_device_bdf")
    ledger = json.loads((raw / "model_fpga.json").read_text())
    expected = tuple(ledger[k] for k in keys)
    for label in ("C1", "C3", "C4"):
        records = list((raw / label).rglob("fpga_identity.json"))
        if not records:
            raise ValueError(f"No board identities for {label}")
        for path in records:
            identity = json.loads(path.read_text())
            if tuple(identity[k] for k in keys) != expected:
                raise ValueError(f"Board identity differs from {expected} in {path}")


def component_table(rows, values, *, include_dequant):
    keys = ["model", "stage", "batch", "seq_len", "candidate"]
    compact = rows.groupby(keys + ["name", "backend"])[values].sum().reset_index()
    compact["component"] = compact.name + plot.NAME_BACKEND_SEPARATOR + compact.backend
    wide = compact.pivot(index=keys, columns="component", values=values).fillna(0.0)
    wide = wide.reset_index().rename(columns={"seq_len": "seq"})
    result = plot._build_gemm_layout_stack(
        pd, wide, include_vector=True, include_dequant=include_dequant
    )
    expected = compact.groupby(keys)[values].sum()
    got = result.rename(columns={"seq": "seq_len"}).set_index(keys).total
    np.testing.assert_allclose(got.reindex(expected.index), expected, rtol=1e-8, atol=1e-10)
    return result


def first_step_qk(df, out):
    # Report the first decode step from the same measurements used in model totals.
    qk = df.loc[
        df.stage.eq("generation")
        & df.batch.eq(1)
        & df.name.eq("attn_qkT")
        & df.gen_kv_len.isin((1024, 8192, 32768))
        & df.candidate.isin(("C2", "C4"))
    ].copy()
    first_step = qk.groupby(["gen_kv_len", "candidate"]).output_token_index.transform("min")
    qk = qk[qk.output_token_index.eq(first_step)]
    assert len(qk) == 6 and not qk.duplicated(["gen_kv_len", "candidate"]).any()
    qk["kernel_ms"] = qk.latency_us / 1000.0
    qk["logical_kv_tokens"] = qk.gen_kv_len + 1
    qk["gemm_N_tokens"] = ((qk.logical_kv_tokens + 31) // 32) * 32
    qk_table = qk.pivot(
        index=["gen_kv_len", "logical_kv_tokens", "gemm_N_tokens"],
        columns="candidate",
        values="kernel_ms",
    ).rename(columns=lambda c: c + "_ms")
    qk_table["C2_over_C4"] = qk_table.C2_ms / qk_table.C4_ms
    qk_table = qk_table.join(
        qk.pivot(
            index=qk_table.index.names, columns="candidate", values="latency_resolution_kind"
        ).add_suffix("_resolution")
    )
    (out / "kernel_latency").mkdir(parents=True, exist_ok=True)
    qk_table.to_csv(out / "kernel_latency/decode_qk_first_step.csv", float_format="%.10g")
    plot_qk(out / "kernel_latency")


def model_metrics(source, out):
    required = {
        "stage",
        "batch",
        "gen_kv_len",
        "prefill_seq_len",
        "out_tokens",
        "variant",
        "name",
        "kind",
        "backend",
        "weighted_latency_us",
        "power_avg_w",
        "fpga_cycle_avg",
        "calls_per_forward",
        "fpga_period_s",
        "seq_len",
        "output_token_index",
        "fpga_cycle",
        "latency_us",
        "metric",
        "model",
        "power_resolution_kind",
        "latency_resolution_kind",
        "case_id",
        "fpga_bin_label",
        "power_pcie_avg_w",
        "power_idle_pcie_avg_w",
        "power_idle_avg_w",
        "power_dynamic_avg_w",
    }
    df = pd.read_csv(source, usecols=lambda col: col in required, low_memory=False)
    df["seq_len"] = np.where(df.stage.eq("prefill"), df.prefill_seq_len, df.gen_kv_len)
    df["candidate"] = df.variant.map(prepare.plot_label_maps(include_c4_alone=False)["variant"])
    assert df.candidate.notna().all()
    if set(df.loc[df.stage.eq("generation"), "out_tokens"]) != {128}:
        raise ValueError("Expected 128 decode steps")
    first_step_qk(df, out)
    group = ["stage", "batch", "seq_len", "candidate"]
    lat = df.loc[prepare.filter_latency_dequantization_kernels(df)].copy()
    assert lat[["weighted_latency_us", "power_avg_w"]].notna().all().all()
    lat["board_w_us"] = lat.power_avg_w * lat.weighted_latency_us
    a = lat.groupby(group)[["weighted_latency_us", "board_w_us"]].sum()
    a["latency_weighted_board_power_W"] = a.board_w_us / a.weighted_latency_us
    a["TTFT_ms"] = (a.weighted_latency_us / 1000).where(
        a.index.get_level_values("stage") == "prefill"
    )
    a["mean_TPOT_ms"] = (a.weighted_latency_us / 128000).where(
        a.index.get_level_values("stage") == "generation"
    )
    energy = df.loc[prepare.filter_energy_dequantization_kernels(df)]
    costs = prepare._vectorized_energy_rows(energy)
    assert not costs.energy_missing_power.any() and not costs.kernel_energy_j.isna().any()
    b = (
        costs.groupby(group + ["power_metric"])
        .joules_per_token_component.sum()
        .unstack("power_metric")
    )
    b = b.rename(columns=lambda name: "J_per_token_" + name)
    summary = (
        a.drop(columns=["weighted_latency_us", "board_w_us"]).join(b, how="inner").sort_index()
    )
    assert (
        len(summary) == 96 and summary.TTFT_ms.count() == 24 and summary.mean_TPOT_ms.count() == 72
    )
    summary.to_csv(out / "model_numbers.csv", float_format="%.10g")
    lat_parts = component_table(lat, "weighted_latency_us", include_dequant=False)
    parts = ["gemm", "vector", "layout", "total"]
    denom = np.where(lat_parts.stage.eq("generation"), 128000.0, 1000.0)
    lat_parts[parts] = lat_parts[parts].div(denom, axis=0)
    lat_parts = lat_parts.rename(columns={v: v + "_ms" for v in parts})
    lat_parts.to_csv(out / "TTFT_TPOT_breakdown_ms.csv", index=False, float_format="%.10g")
    energy_parts = []
    for metric, rows in costs.groupby("power_metric", sort=False):
        component = component_table(rows, "joules_per_token_component", include_dequant=True)
        component["power_metric"] = metric
        energy_parts.append(component)
    pd.concat(energy_parts, ignore_index=True).to_csv(
        out / "energy_breakdown_J_per_token.csv", index=False, float_format="%.10g"
    )

    plot_absolute_metrics(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path, help="outputs_qwen3_kivi_<tag> directory")
    parser.add_argument(
        "--output", type=Path, help="Report destination (defaults to run directory)"
    )
    args = parser.parse_args()
    run = args.run.resolve()
    prefix = "outputs_qwen3_kivi_"
    if not run.name.startswith(prefix):
        parser.error(f"Run directory must start with {prefix}")
    tag = run.name[len(prefix) :]
    out = args.output.resolve() if args.output else run
    verify_board(run / "raw")
    out.mkdir(parents=True, exist_ok=True)
    model_metrics(run / f"composed_results.{tag}/qwen3_8b/composed.csv", out)
    paper_figures(run / f"figure_prepare.{tag}", out / "paper_format")


if __name__ == "__main__":
    main()

"""Progression roofline: vanilla memory-bound decode → compute-bound by
adding one optimization at a time. Drawn against a single FP16 roofline
so the visual story is unambiguous: the workload crosses the ridge by
stacking KV-cache + weight-quant + KV-quant optimizations and ends up
deep in the compute-bound region — which is exactly the regime where
compute-side quantization (FPINT in the paper body) matters.

A second panel shows prefill at the same baseline conditions: prefill
is already compute-bound from the start, so memory-cap optimizations do
not buy much; the decode side is where the progression actually moves.

Each decode step changes ONE thing relative to the previous one. The
base architecture matches Llama-3-8B (H=4096, L=32, n_h=32, ffn=14336),
which natively uses GQA with n_kv=8 (4:1). The "MHA baseline" step is
a counterfactual that pretends Llama-3-8B were deployed without GQA,
just to make the GQA step's value visible.

  step 1: baseline       MHA  (n_kv=32), b=1,   fp16 W, fp16 KV
  step 2: + large batch  MHA,             b=256, fp16,   fp16 KV
  step 3: + GQA (4:1)    GQA  (n_kv=8),   b=256, fp16,   fp16 KV
  step 4: + MLA          MLA,             b=256, fp16,   fp16 KV
  step 5: + INT4 weight  MLA,             b=256, INT4,   fp16 KV
  step 6: + INT4 KV      MLA,             b=256, INT4,   INT4 KV

MQA is intentionally omitted (model-quality issues; not deployed).

Output: analysis_workspace/llm_analysis/figures/progression_roofline.{pdf,png,svg}
"""

import argparse
from dataclasses import replace
from pathlib import Path
import sys

import matplotlib as mpl
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import FancyArrowPatch

# Keep text as editable <text> elements in the SVG (default would convert
# fonts to paths, which Inkscape cannot select as text).
mpl.rcParams["svg.fonttype"] = "none"


def find_repo_root(start: Path) -> Path:
    path = start.resolve()
    if path.is_file():
        path = path.parent
    for candidate in (path, *path.parents):
        if (candidate / "third_party" / "llm-analysis").is_dir():
            return candidate
    raise RuntimeError("could not find Vortex repo root with third_party/llm-analysis")


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = find_repo_root(SCRIPT_DIR)
LLM_ANALYSIS_ROOT = REPO_ROOT / "third_party" / "llm-analysis"
LLM_ANALYSIS_SCRIPTS = LLM_ANALYSIS_ROOT / "scripts"

for import_path in (LLM_ANALYSIS_ROOT, LLM_ANALYSIS_SCRIPTS):
    import_path_str = str(import_path)
    if import_path_str not in sys.path:
        sys.path.insert(0, import_path_str)


def provide_llm_analysis_cli_dependency_stubs():
    try:
        import fire  # noqa: F401
    except ModuleNotFoundError:
        import types

        def _missing_fire(*_args, **_kwargs):
            raise RuntimeError(
                "Install the optional 'fire' package to run llm_analysis "
                "config/analysis modules as CLIs.")

        sys.modules["fire"] = types.SimpleNamespace(Fire=_missing_fire)


provide_llm_analysis_cli_dependency_stubs()

from llm_analysis.config import ModelConfig  # noqa: E402
from paper_arith_intensity_sweep import analyze  # noqa: E402


BASE = ModelConfig(
    name="base_Llama3_8B_MHA",
    num_layers=32,
    n_head=32,
    hidden_dim=4096,
    vocab_size=128256,
    max_seq_len=8192,
    num_key_value_heads=32,  # counterfactual MHA; real Llama-3-8B is GQA(8)
    ffn_embed_dim=14336,
    model_type="llama",
    mlp_gated_linear_units=True,
)


def make_gqa(n_kv: int, name: str) -> ModelConfig:
    return replace(BASE, num_key_value_heads=n_kv, name=name,
                   num_key_value_groups=None, attention_type=None)


def make_mla(name: str) -> ModelConfig:
    return replace(
        BASE, name=name,
        num_key_value_heads=None, num_key_value_groups=None,
        attention_type=None,
        kv_lora_rank=512,
        q_lora_rank=1536,
        qk_rope_head_dim=64,
        qk_nope_head_dim=128,
        v_head_dim=128,
    )


SEQ = 1024

# (label, model, batch, weight_bytes, kv_bytes)
DECODE_STEPS = [
    ("MHA\nb=1",       BASE,                          1,   2,   2),
    ("+batch\nb=256",  BASE,                          256, 2,   2),
    ("+GQA",           make_gqa(8, "base_GQA"),       256, 2,   2),
    ("+MLA",           make_mla("base_MLA"),          256, 2,   2),
    ("+W4",            make_mla("base_MLA_w4"),       256, 0.5, 2),
    ("+KV4",           make_mla("base_MLA_w4_kv4"),   256, 0.5, 0.5),
]

# Prefill: a few representative points to make the "already compute-bound"
# observation. MLA-related steps are intentionally omitted here — in
# prefill MLA only changes OI by ~5–10% versus MHA at the same batch,
# so it adds visual clutter without changing the message. The story is
# carried by batch size and weight quantization alone.
PREFILL_STEPS = [
    ("MHA\nb=1",      BASE, 1,  2,   2),
    ("+batch\nb=64",  BASE, 64, 2,   2),
    ("+W4\nb=64",     BASE, 64, 0.5, 2),
]

# A100-SXM-80GB FP16 roofline
PEAK_FP16_TFLOPS = 312
HBM_GBS = 2039
DEFAULT_OUT_DIR = SCRIPT_DIR / "figures"
ONE_COLUMN_FIGSIZE = (3.45, 4.15)  # Matplotlib order: width, height in inches.
SAVE_DPI = 600

SUPTITLE_FONTSIZE = 8.5
TITLE_FONTSIZE = 7.0
AXIS_LABEL_FONTSIZE = 6.7
TICK_FONTSIZE = 5.8
ROOFLINE_TEXT_FONTSIZE = 5.2
LEGEND_FONTSIZE = 5.5
MARKER_SIZE = 32
LINEWIDTH = 0.9


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate the LLM-analysis progression roofline figure.")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="output directory for progression_roofline.* files")
    parser.add_argument(
        "--formats",
        nargs="+",
        default=("pdf", "png", "svg"),
        choices=("pdf", "png", "svg"),
        help="figure formats to write")
    return parser.parse_args(argv)


def resolve_out_dir(path: Path) -> Path:
    path = path.expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    return path


def draw_roofline(ax, peak_tflops, hbm_gbs, label):
    bw = hbm_gbs * 1e9
    peak = peak_tflops * 1e12
    ridge = peak / bw

    xs_left = [0.5, ridge]
    ys_left = [0.5 * bw, ridge * bw]
    ax.plot(xs_left, ys_left, color="black", linewidth=LINEWIDTH)
    ax.plot([ridge, 1e6], [peak, peak],
            color="black", linewidth=LINEWIDTH, label=label)
    ax.axvline(ridge, color="gray", linestyle=":", linewidth=0.55)
    ax.text(ridge * 1.10, peak * 0.12,
            f"ridge\n{ridge:.0f}",
            fontsize=ROOFLINE_TEXT_FONTSIZE, color="gray")
    return bw, peak, ridge


def compute_points(steps, phase, bw, peak):
    points = []
    for label, mcfg, batch, wb, kvb in steps:
        r = analyze(mcfg, batch, SEQ, phase,
                    weight_bytes=wb, act_bytes=2, kv_bytes_per_elem=kvb)
        x = r.intensity
        y = min(x * bw, peak)
        points.append((label, x, y, batch, wb, kvb, r))
        print(f"[{phase:7s}] {label.replace(chr(10),' '):28s} OI={x:7.2f}  "
              f"weight={r.weight_GB:6.2f}GB  kv={r.kv_GB:6.2f}GB  "
              f"flops={r.flops_T:6.2f}T  ach={y/1e12:6.1f}TF/s")
    return points


def format_legend_label(label: str) -> str:
    return label.replace("\n", ", ")


def plot_progression(ax, points, cmap_name="plasma", show_arrows=True):
    cmap = plt.get_cmap(cmap_name)
    n = len(points)
    handles = []
    for i, (label, x, y, b, wb, kvb, _r) in enumerate(points):
        color = cmap(0.05 + 0.85 * i / max(1, n - 1))
        ax.scatter(x, y, s=MARKER_SIZE, color=color, edgecolors="black",
                   linewidths=0.45, zorder=5)
        handles.append(Line2D(
            [0], [0],
            marker="o", linestyle="",
            markerfacecolor=color, markeredgecolor="black",
            markeredgewidth=0.45, markersize=3.5,
            label=format_legend_label(label),
        ))
        if show_arrows and i > 0:
            xp, yp = points[i - 1][1], points[i - 1][2]
            ax.add_patch(FancyArrowPatch(
                (xp, yp), (x, y),
                arrowstyle="->,head_length=4,head_width=2.5",
                color=color, linewidth=0.75, zorder=4,
                connectionstyle="arc3,rad=0.0"))
    return handles


def main(argv=None):
    args = parse_args(argv)

    fig, axes = plt.subplots(2, 1, figsize=ONE_COLUMN_FIGSIZE, sharex=True)

    # Shared x-axis range so the HBM-bandwidth slope visibly matches
    # across the two panels (same FP16 roofline ⇒ same slope on screen).
    XLIM = (0.5, 1e5)

    # ---- LEFT: decode progression ----
    ax = axes[0]
    bw, peak, ridge = draw_roofline(
        ax, PEAK_FP16_TFLOPS, HBM_GBS,
        f"A100 FP16 roofline (peak {PEAK_FP16_TFLOPS} TFLOPS)")

    decode_points = compute_points(DECODE_STEPS, "decode", bw, peak)

    decode_handles = plot_progression(ax, decode_points)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(*XLIM)
    ax.set_ylim(3e11, peak * 2.1)
    ax.set_ylabel("FLOP/s", fontsize=AXIS_LABEL_FONTSIZE)
    ax.set_title(f"Decode, seq={SEQ}", fontsize=TITLE_FONTSIZE)
    ax.tick_params(axis="both", labelsize=TICK_FONTSIZE)
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(handles=decode_handles, loc="lower right", ncol=2,
              fontsize=LEGEND_FONTSIZE, frameon=False,
              handlelength=0.9, handletextpad=0.25,
              columnspacing=0.5, labelspacing=0.25)

    # ---- BOTTOM: prefill (already compute-bound) ----
    ax = axes[1]
    bw, peak, ridge = draw_roofline(
        ax, PEAK_FP16_TFLOPS, HBM_GBS,
        f"A100 FP16 roofline (peak {PEAK_FP16_TFLOPS} TFLOPS)")

    prefill_points = compute_points(PREFILL_STEPS, "prefill", bw, peak)

    prefill_handles = plot_progression(ax, prefill_points, show_arrows=False)

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(*XLIM)
    ax.set_ylim(3e11, peak * 2.1)
    ax.set_xlabel("Arithmetic intensity (FLOP/byte)",
                  fontsize=AXIS_LABEL_FONTSIZE)
    ax.set_ylabel("FLOP/s", fontsize=AXIS_LABEL_FONTSIZE)
    ax.set_title(f"Prefill, seq={SEQ}", fontsize=TITLE_FONTSIZE)
    ax.tick_params(axis="both", labelsize=TICK_FONTSIZE)
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(handles=prefill_handles, loc="lower right", ncol=1,
              fontsize=LEGEND_FONTSIZE, frameon=False,
              handlelength=0.9, handletextpad=0.25, labelspacing=0.25)

    fig.suptitle("A100 FP16 roofline progression",
                 fontsize=SUPTITLE_FONTSIZE, y=0.93)

    out_dir = resolve_out_dir(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(rect=[0, 0, 1, 0.965], h_pad=0.65)
    for ext in args.formats:
        path = out_dir / f"progression_roofline.{ext}"
        fig.savefig(path, dpi=SAVE_DPI)
        print(f"wrote {path}")
    plt.close(fig)


if __name__ == "__main__":
    main()

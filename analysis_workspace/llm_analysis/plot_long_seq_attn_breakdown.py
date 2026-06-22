"""Long-sequence prefill compute breakdown.

Motivation: existing FPINT-style designs only accelerate the linear-layer
GEMMs and treat the attention core (QK^T, score·V) as free. That is fine in
short-context decoding where attention is cheap, but during prefill the core
is O(N^2) in sequence length while linear is O(N). Past a few-k context the
attention share crosses linear and eventually dominates — so a linear-only
accelerator cannot move TTFT in the long-context regime.

This figure makes that point quantitatively: normalized stacked bars
(linear vs attention core) across sequence length, with the attention share
annotated inside each bar.

Definitions (prefill, batch = 1, Llama-3 family with real GQA n_kv=8):
  - linear         = Q/K/V/O projections + MLP (gated, 3 matmuls)
  - attention core = QK^T + score·V

Four panels: Llama-3.2 1B, Llama-3.2 3B, Llama-3 8B, Llama-3 70B. Smaller
models reach the attention-dominant regime at shorter sequence lengths
because their linear share is relatively smaller.

Output: analysis_workspace/llm_analysis/figures/long_seq_attn_breakdown.{pdf,png,svg}
"""

import argparse
from pathlib import Path
import sys

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np

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

llm_analysis_root_str = str(LLM_ANALYSIS_ROOT)
if llm_analysis_root_str not in sys.path:
    sys.path.insert(0, llm_analysis_root_str)


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


LLAMA32_1B = ModelConfig(
    name="Llama-3.2 1B",
    num_layers=16,
    n_head=32,
    hidden_dim=2048,
    vocab_size=128256,
    max_seq_len=131072,
    num_key_value_heads=8,
    ffn_embed_dim=8192,
    model_type="llama",
    mlp_gated_linear_units=True,
)

LLAMA32_3B = ModelConfig(
    name="Llama-3.2 3B",
    num_layers=28,
    n_head=24,
    hidden_dim=3072,
    vocab_size=128256,
    max_seq_len=131072,
    num_key_value_heads=8,
    ffn_embed_dim=8192,
    model_type="llama",
    mlp_gated_linear_units=True,
)

LLAMA3_8B = ModelConfig(
    name="Llama-3 8B",
    num_layers=32,
    n_head=32,
    hidden_dim=4096,
    vocab_size=128256,
    max_seq_len=131072,
    num_key_value_heads=8,
    ffn_embed_dim=14336,
    model_type="llama",
    mlp_gated_linear_units=True,
)

LLAMA3_70B = ModelConfig(
    name="Llama-3 70B",
    num_layers=80,
    n_head=64,
    hidden_dim=8192,
    vocab_size=128256,
    max_seq_len=131072,
    num_key_value_heads=8,
    ffn_embed_dim=28672,
    model_type="llama",
    mlp_gated_linear_units=True,
)

MODELS = [LLAMA32_1B, LLAMA32_3B, LLAMA3_8B, LLAMA3_70B]

SEQS = [1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072]
BATCH = 1
DEFAULT_OUT_DIR = SCRIPT_DIR / "figures"
ONE_COLUMN_FIGSIZE = (3.45, 3.25)  # Matplotlib order: width, height in inches.
SAVE_DPI = 600

TITLE_FONTSIZE = 7.5
AXIS_LABEL_FONTSIZE = 7.0
TICK_FONTSIZE = 6.0
ANNOTATION_FONTSIZE = 5.8
LEGEND_FONTSIZE = 6.4
BAR_WIDTH = 0.88
MIN_LABEL_ATTENTION_SHARE = 0.30


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate the long-sequence attention breakdown figure.")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="output directory for long_seq_attn_breakdown.* files")
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


def linear_flops_prefill(m: ModelConfig, b: int, s: int) -> int:
    """Q/K/V/O projection + MLP FLOPs, summed over all layers."""
    H = m.hidden_dim
    n_h = m.n_head
    n_kv = m.num_key_value_heads
    head_dim = H // n_h
    gates = 3 if m.mlp_gated_linear_units else 2

    qo_proj = 2 * 2 * b * s * H * H
    kv_proj = 2 * 2 * b * s * H * (n_kv * head_dim)
    mlp = 2 * gates * b * s * H * m.ffn_embed_dim
    return m.num_layers * (qo_proj + kv_proj + mlp)


def attn_core_flops_prefill(m: ModelConfig, b: int, s: int) -> int:
    """QK^T + score·V FLOPs, summed over all layers."""
    H = m.hidden_dim
    n_h = m.n_head
    head_dim = H // n_h

    qkT = 2 * b * n_h * s * s * head_dim
    scoreV = 2 * b * n_h * s * s * head_dim
    return m.num_layers * (qkT + scoreV)


def fmt_seq(s: int) -> str:
    if s >= 1024:
        return f"{s // 1024}k"
    return str(s)


def plot_one(ax, model: ModelConfig, show_xlabel: bool):
    linear = np.array(
        [linear_flops_prefill(model, BATCH, s) for s in SEQS], dtype=float
    )
    attn = np.array(
        [attn_core_flops_prefill(model, BATCH, s) for s in SEQS], dtype=float
    )
    total = linear + attn
    linear_share = linear / total
    attn_share = attn / total
    attn_pct = attn_share * 100.0

    linear_T = linear / 1e12
    attn_T = attn / 1e12

    print(f"\n== {model.name} ==")
    for s, lin, at, pct in zip(SEQS, linear_T, attn_T, attn_pct):
        print(f"  seq={s:>6d}  linear={lin:10.2f} TF  attn={at:11.2f} TF  "
              f"attn%={pct:5.1f}")

    x = np.arange(len(SEQS))
    c_lin = "#4C78A8"
    c_att = "#E45756"

    ax.bar(x, linear_share, BAR_WIDTH,
           label="Linear",
           color=c_lin, edgecolor="black", linewidth=0.5)
    ax.bar(x, attn_share, BAR_WIDTH, bottom=linear_share,
           label="Attention core",
           color=c_att, edgecolor="black", linewidth=0.5)

    for i, (lin_share, at_share, pct) in enumerate(
            zip(linear_share, attn_share, attn_pct)):
        if at_share < MIN_LABEL_ATTENTION_SHARE:
            continue
        label_y = lin_share + at_share * 0.5
        ax.text(x[i], label_y,
                f"{pct:.0f}%",
                ha="center", va="center",
                fontsize=ANNOTATION_FONTSIZE, color="white",
                fontweight="bold", rotation=90)

    ax.set_xticks(x)
    ax.set_xticklabels([fmt_seq(s) for s in SEQS], fontsize=TICK_FONTSIZE,
                       rotation=45, ha="right")
    ax.tick_params(axis="y", labelsize=TICK_FONTSIZE)
    if show_xlabel:
        ax.set_xlabel("Sequence length", fontsize=AXIS_LABEL_FONTSIZE)
    else:
        ax.set_xticklabels([])
    ax.set_title(model.name, fontsize=TITLE_FONTSIZE)
    ax.set_ylim(0, 1.0)
    ax.set_xlim(-0.5, len(SEQS) - 0.5)
    ax.grid(True, axis="y", alpha=0.3)


def main(argv=None):
    args = parse_args(argv)

    fig, axes = plt.subplots(
        2, 2, figsize=ONE_COLUMN_FIGSIZE, sharey=True
    )
    axes = axes.flatten()

    for i, (ax, model) in enumerate(zip(axes, MODELS)):
        plot_one(ax, model, show_xlabel=i >= 2)

    axes[0].set_ylabel("FLOP fraction", fontsize=AXIS_LABEL_FONTSIZE)
    axes[2].set_ylabel("FLOP fraction", fontsize=AXIS_LABEL_FONTSIZE)
    handles, labels = axes[-1].get_legend_handles_labels()
    fig.legend(handles, labels, loc="lower center", ncol=2,
               bbox_to_anchor=(0.5, 0.04),
               fontsize=LEGEND_FONTSIZE, framealpha=0.95)

    fig.suptitle(
        f"Prefill FLOP breakdown (batch = {BATCH})",
        fontsize=TITLE_FONTSIZE,
        y=0.93,
    )

    out_dir = resolve_out_dir(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(rect=[0, 0.10, 1, 0.955], h_pad=0.6, w_pad=0.5)
    for ext in args.formats:
        path = out_dir / f"long_seq_attn_breakdown.{ext}"
        fig.savefig(path, dpi=SAVE_DPI)
        print(f"wrote {path}")
    plt.close(fig)


if __name__ == "__main__":
    main()

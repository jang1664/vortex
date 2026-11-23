"""Render the published Llama panel types for the final single-card Qwen3 run."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

FLOW = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(FLOW), str(FLOW.parents[1])]
os.environ.setdefault("MPLBACKEND", "Agg")

import matplotlib
import plot

matplotlib.rcParams["pdf.fonttype"] = 42


def render_panels(work, prepared):
    record = FLOW / "docs/prefill_rev5_v2_decode_rev5_20261009/render_commands.json"
    original = json.loads(record.read_text())
    for panel in ("gemm", "e2e", "energy"):
        cmd = original[panel]
        family = cmd[cmd.index("--plot") + 1]
        previous_csv = Path(next(v.partition("=")[2] for v in cmd if v.startswith("llama3_8b=")))
        table = (
            prepared
            / previous_csv.parent.name.replace("llama3_8b", "qwen3_8b", 1)
            / previous_csv.name
        )
        assert table.is_file(), table
        knobs = getattr(plot.PLOT_KNOBS, family)
        knobs.figsize = (3.65, 2.35)
        knobs.row_height = 1.12
        knobs.legend_y = 1.00
        knobs.tight_layout_rect = (0, 0, 1, 0.91)
        knobs.save_pad_inches = 0.035
        args = [
            "--plot",
            family,
            "--out-tokens",
            "128",
            "--workers",
            "1",
            "--models",
            "qwen3_8b",
            "--prepared-root",
            str(prepared),
            "--out-dir",
            str(work),
            "--formats",
            "pdf",
            "--model-data",
            f"qwen3_8b={table}",
        ]
        if "--power-metric" in cmd:
            args.extend(["--power-metric", cmd[cmd.index("--power-metric") + 1]])
        if plot.main(args) != 0:
            raise RuntimeError(f"Failed to render {family}")
        (pdf,) = (work / family).glob("*.pdf")
        shutil.copyfile(pdf, work / (panel + ".pdf"))


def assemble(work, dest, name, body):
    style = r"""\documentclass[border=2pt]{standalone}
\usepackage{graphicx}
\usepackage[T1]{fontenc}
\usepackage{tgtermes,tgheros}
\begin{document}
\setlength{\tabcolsep}{0pt}
"""
    key = r"\sffamily\fontsize{6.5}{8}\selectfont Bars from left to right: C1, C2, C3, C4. Each group is normalized to C4."
    tex = style + body.replace("CANDIDATEKEY", key) + "\n" + r"\end{document}"
    (work / f"{name}.tex").write_text(tex)
    subprocess.run(
        ["pdflatex", "-halt-on-error", "-interaction=batchmode", f"{name}.tex"],
        cwd=work,
        check=True,
    )
    shutil.copyfile(work / f"{name}.pdf", dest / f"{name}.pdf")
    subprocess.run(
        [
            "pdftoppm",
            "-png",
            "-singlefile",
            "-r",
            "300",
            str(dest / f"{name}.pdf"),
            str(dest / name),
        ],
        check=True,
    )


def paper_figures(prepared, dest):
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest) as temporary:
        work = Path(temporary)
        render_panels(work, prepared)
        assemble(
            work,
            dest,
            "qwen3_latency",
            r"""
\begin{tabular}{c@{\hspace{9pt}}c}
\includegraphics[width=3.55in]{gemm.pdf} & \includegraphics[width=3.55in]{e2e.pdf} \\
\textbf{\small (a) GEMM-only latency.} & \textbf{\small (b) Model latency (TTFT/TPOT).} \\[2pt]
\multicolumn{2}{c}{CANDIDATEKEY}
\end{tabular}""",
        )
        assemble(
            work,
            dest,
            "qwen3_energy",
            r"""
\begin{tabular}{c}
\includegraphics[width=3.55in]{energy.pdf} \\[1pt]
CANDIDATEKEY
\end{tabular}""",
        )

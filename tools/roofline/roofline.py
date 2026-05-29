"""
Hierarchical Roofline Model Analyzer
=====================================
Jupyter notebook 환경에서 사용 가능한 hierarchical roofline 시각화/분석 도구.
ipywidgets 기반 interactive 모드 지원.

Usage:
    from roofline import RooflineModel

    model = RooflineModel()
    model.add_compute("MXU INT8", 2048)
    model.add_bw("HBM", 460)
    model.add_workload("GEMM", oi=128)

    # Static plot
    model.plot()
    model.summary()

    # Interactive dashboard
    model.interactive()
"""

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from dataclasses import dataclass, field
from typing import Optional
from copy import deepcopy

try:
    import ipywidgets as widgets
    from IPython.display import display, clear_output
    HAS_WIDGETS = True
except ImportError:
    HAS_WIDGETS = False


# ── Data classes ──

@dataclass
class ComputeCeiling:
    name: str
    peak_gflops: float
    color: Optional[str] = None
    linestyle: str = "-"


@dataclass
class BWCeiling:
    name: str
    peak_gbs: float
    color: Optional[str] = None
    linestyle: str = "-"


@dataclass
class Workload:
    name: str
    oi: float
    achieved_gflops: Optional[float] = None
    computes: Optional[list[str]] = None   # None = all compute ceilings
    bws: Optional[list[str]] = None        # None = all BW ceilings
    overlap: bool = True                   # True=double-buffered (min), False=serial (harmonic)


@dataclass
class RidgePoint:
    compute_name: str
    bw_name: str
    oi: float
    perf: float


@dataclass
class BottleneckResult:
    workload_name: str
    oi: float
    attainable_gflops: float
    bottleneck: str
    regime: str


class RooflineModel:
    """Hierarchical Roofline Model for design-space exploration."""

    COMPUTE_COLORS = ["#534AB7", "#993556", "#D85A30", "#639922"]
    BW_COLORS = ["#1D9E75", "#378ADD", "#BA7517", "#D85A30", "#854F0B"]
    WORKLOAD_COLOR = "#A32D2D"
    WORKLOAD_MARKER = "o"

    def __init__(self):
        self.computes: list[ComputeCeiling] = []
        self.bws: list[BWCeiling] = []
        self.workloads: list[Workload] = []

    # ── Builder API (chaining 지원) ──

    def add_compute(self, name: str, peak_gflops: float,
                    color: Optional[str] = None, linestyle: str = "-"):
        if color is None:
            color = self.COMPUTE_COLORS[len(self.computes) % len(self.COMPUTE_COLORS)]
        self.computes.append(ComputeCeiling(name, peak_gflops, color, linestyle))
        return self

    def add_bw(self, name: str, peak_gbs: float,
               color: Optional[str] = None, linestyle: str = "-"):
        if color is None:
            color = self.BW_COLORS[len(self.bws) % len(self.BW_COLORS)]
        self.bws.append(BWCeiling(name, peak_gbs, color, linestyle))
        return self

    def add_workload(self, name: str, oi: float,
                     achieved_gflops: Optional[float] = None,
                     computes: Optional[list[str]] = None,
                     bws: Optional[list[str]] = None,
                     overlap: bool = True):
        """Add a workload point.

        Args:
            computes: list of compute ceiling names that apply (None = all).
            bws: list of BW ceiling names that apply (None = all).
            overlap: True = double-buffered (min model, standard roofline).
                     False = serial (harmonic mean, no overlap).
        """
        self.workloads.append(Workload(name, oi, achieved_gflops, computes, bws, overlap))
        return self

    def clear(self):
        self.computes.clear()
        self.bws.clear()
        self.workloads.clear()
        return self

    # ── Analysis ──

    def _attainable(self, oi: float,
                    compute_filter: Optional[list[str]] = None,
                    bw_filter: Optional[list[str]] = None,
                    overlap: bool = True,
                    ) -> tuple[float, str, str]:
        # Compute ceiling: min of all applicable compute ceilings
        comp_perf = float("inf")
        comp_name = ""
        for c in self.computes:
            if compute_filter is not None and c.name not in compute_filter:
                continue
            if c.peak_gflops < comp_perf:
                comp_perf = c.peak_gflops
                comp_name = c.name

        # BW ceiling: min of all applicable BW ceilings (× OI)
        bw_perf = float("inf")
        bw_name = ""
        for b in self.bws:
            if bw_filter is not None and b.name not in bw_filter:
                continue
            bp = b.peak_gbs * oi
            if bp < bw_perf:
                bw_perf = bp
                bw_name = b.name

        if overlap:
            # Standard roofline: perfect overlap → min
            perf = min(comp_perf, bw_perf)
        else:
            # No overlap (serial): harmonic mean
            # 1/Perf = 1/comp + 1/bw  →  Perf = comp*bw / (comp+bw)
            if comp_perf == float("inf") and bw_perf == float("inf"):
                perf = float("inf")
            elif comp_perf == float("inf"):
                perf = bw_perf
            elif bw_perf == float("inf"):
                perf = comp_perf
            else:
                perf = (comp_perf * bw_perf) / (comp_perf + bw_perf)

        if perf <= 0 or perf == float("inf"):
            return perf, "", ""

        # Determine bottleneck from the tighter ceiling
        if comp_perf <= bw_perf:
            bottleneck = comp_name
            regime = "compute-bound"
        else:
            bottleneck = bw_name
            regime = "memory-bound"
        if not overlap:
            regime += " (serial)"

        return perf, bottleneck, regime

    def ridge_points(self) -> list[RidgePoint]:
        results = []
        for c in self.computes:
            for b in self.bws:
                ridge_oi = c.peak_gflops / b.peak_gbs
                results.append(RidgePoint(c.name, b.name, ridge_oi, c.peak_gflops))
        return results

    def analyze(self) -> list[BottleneckResult]:
        results = []
        for w in self.workloads:
            perf, bottleneck, regime = self._attainable(w.oi, w.computes, w.bws, w.overlap)
            results.append(BottleneckResult(w.name, w.oi, perf, bottleneck, regime))
        return results

    # ── Text output ──

    def summary(self):
        print("=" * 70)
        print("RIDGE POINTS")
        print("=" * 70)
        for rp in self.ridge_points():
            print(f"  {rp.compute_name} x {rp.bw_name}:  "
                  f"OI = {rp.oi:.2f} FLOPs/B  ({rp.perf:.0f} GFLOPS)")
        print()
        print("=" * 70)
        print("WORKLOAD BOTTLENECK ANALYSIS")
        print("=" * 70)
        print(f"  {'Workload':<25} {'OI':>8} {'Attainable':>12} {'Bottleneck':<20} {'Regime':<18} {'Resources'}")
        print(f"  {'-'*25} {'-'*8} {'-'*12} {'-'*20} {'-'*18} {'-'*20}")
        for w, r in zip(self.workloads, self.analyze()):
            res_parts = []
            if w.computes is not None:
                res_parts.append("C:[" + ",".join(w.computes) + "]")
            if w.bws is not None:
                res_parts.append("B:[" + ",".join(w.bws) + "]")
            res_str = " ".join(res_parts) if res_parts else "(all)"
            print(f"  {r.workload_name:<25} {r.oi:>8.2f} "
                  f"{r.attainable_gflops:>10.1f}  "
                  f"{r.bottleneck:<20} {r.regime:<18} {res_str}")

    # ── Static plot ──

    def plot(self, ax=None, figsize=(12, 7), oi_range=(0.1, 1024),
             title="Hierarchical Roofline Model",
             show_ridge=True, show_annotations=True,
             workload_fontsize=10, ceiling_fontsize=10,
             save_path: Optional[str] = None, dpi=150):
        if ax is None:
            fig, ax = plt.subplots(figsize=figsize)
        else:
            fig = ax.figure

        oi_min, oi_max = oi_range
        oi = np.logspace(np.log10(oi_min), np.log10(oi_max), 500)

        # BW ceilings
        for b in self.bws:
            perf = b.peak_gbs * oi
            ax.plot(oi, perf, color=b.color, linewidth=2, linestyle=b.linestyle, alpha=0.8)
            label_oi = oi_min * 3
            label_perf = b.peak_gbs * label_oi
            ax.annotate(f"{b.name}\n{b.peak_gbs} GB/s",
                        xy=(label_oi, label_perf),
                        fontsize=ceiling_fontsize, color=b.color, fontweight="bold",
                        rotation=38, rotation_mode="anchor", ha="left", va="bottom")

        # Compute ceilings
        for c in self.computes:
            ax.axhline(y=c.peak_gflops, color=c.color, linewidth=2,
                       linestyle=c.linestyle, alpha=0.8)
            ax.annotate(f"{c.name} ({c.peak_gflops:.0f} GFLOPS)",
                        xy=(oi_max * 0.7, c.peak_gflops),
                        fontsize=ceiling_fontsize, color=c.color, fontweight="bold",
                        ha="right", va="bottom")

        # Composite envelope (overlap = min)
        envelope = np.full_like(oi, float("inf"))
        for c in self.computes:
            envelope = np.minimum(envelope, c.peak_gflops)
        for b in self.bws:
            envelope = np.minimum(envelope, b.peak_gbs * oi)
        ax.plot(oi, envelope, color="black", linewidth=2.5, alpha=0.3, zorder=0)
        ax.fill_between(oi, envelope, alpha=0.03, color="black")

        # Serial envelope (no overlap = harmonic mean)
        has_serial = any(not w.overlap for w in self.workloads)
        if has_serial and self.computes and self.bws:
            comp_min = min(c.peak_gflops for c in self.computes)
            bw_min = min(b.peak_gbs for b in self.bws)
            serial_env = (comp_min * bw_min * oi) / (comp_min + bw_min * oi)
            ax.plot(oi, serial_env, color="black", linewidth=1.5,
                    linestyle="--", alpha=0.2, zorder=0, label="serial (no overlap)")

        # Ridge points
        if show_ridge:
            for rp in self.ridge_points():
                if oi_min <= rp.oi <= oi_max:
                    ax.plot(rp.oi, rp.perf, "o", color="gray", markersize=8,
                            markerfacecolor="white", markeredgewidth=1.5, zorder=5)
                    ax.annotate(f"  OI={rp.oi:.1f}", xy=(rp.oi, rp.perf),
                                fontsize=8, color="gray", va="bottom")

        # Workloads
        for w in self.workloads:
            if w.achieved_gflops is not None:
                wx, wy = w.oi, w.achieved_gflops
            else:
                wy, _, _ = self._attainable(w.oi, w.computes, w.bws, w.overlap)
                wx = w.oi
            marker = self.WORKLOAD_MARKER if w.overlap else "v"
            ax.plot(wx, wy, marker, color=self.WORKLOAD_COLOR,
                    markersize=8, zorder=10, markeredgecolor="white", markeredgewidth=0.5)
            if show_annotations:
                ax.axvline(x=w.oi, color=self.WORKLOAD_COLOR, linewidth=0.5,
                           linestyle=":", alpha=0.3)
                tag = "" if w.overlap else " [serial]"
                ax.annotate(f" {w.name}{tag}\n OI={w.oi:.1f}",
                            xy=(wx, wy), xytext=(8, -5), textcoords="offset points",
                            fontsize=workload_fontsize, color=self.WORKLOAD_COLOR,
                            va="top", ha="left")

        # Axes
        ax.set_xscale("log")
        ax.set_yscale("log")
        ax.set_xlim(oi_range)
        all_perfs = [c.peak_gflops for c in self.computes]
        all_perfs += [b.peak_gbs * oi_min for b in self.bws]
        if all_perfs:
            y_lo = min(all_perfs) * 0.3
            y_hi = max(c.peak_gflops for c in self.computes) * 3 if self.computes else 1e4
            ax.set_ylim(y_lo, y_hi)
        ax.set_xlabel("Operational Intensity (FLOPs/Byte)", fontsize=13)
        ax.set_ylabel("Attainable Performance (GFLOPS)", fontsize=13)
        ax.set_title(title, fontsize=15, fontweight="bold", pad=15)
        ax.grid(True, which="both", alpha=0.15, linewidth=0.5)
        ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
        ax.yaxis.set_major_formatter(ticker.ScalarFormatter())
        ax.tick_params(labelsize=11)
        plt.tight_layout()

        if save_path:
            fig.savefig(save_path, dpi=dpi, bbox_inches="tight")
            print(f"Saved to {save_path}")

        plt.show()
        return fig, ax

    # ── Sweep helpers ──

    def sweep_bw(self, bw_name: str, values: list[float], figsize=(14, 5)):
        fig, axes = plt.subplots(1, len(values), figsize=figsize, sharey=True)
        if len(values) == 1:
            axes = [axes]
        original = [BWCeiling(b.name, b.peak_gbs, b.color, b.linestyle) for b in self.bws]
        for idx, val in enumerate(values):
            for b in self.bws:
                if b.name == bw_name:
                    b.peak_gbs = val
            ax = axes[idx]
            oi = np.logspace(-1, 3, 500)
            for b in self.bws:
                ax.plot(oi, b.peak_gbs * oi, color=b.color, linewidth=1.5, alpha=0.7, linestyle=b.linestyle)
            for c in self.computes:
                ax.axhline(y=c.peak_gflops, color=c.color, linewidth=1.5, alpha=0.7)
            for w in self.workloads:
                perf, _, regime = self._attainable(w.oi, w.computes, w.bws, w.overlap)
                color = "#378ADD" if regime == "compute-bound" else "#D85A30"
                ax.plot(w.oi, perf, "o", color=color, markersize=6, zorder=10)
                ax.annotate(w.name, xy=(w.oi, perf), fontsize=7,
                            xytext=(3, -3), textcoords="offset points", color=color, va="top")
            ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlim(0.1, 1024)
            ax.set_title(f"{bw_name} = {val} GB/s", fontsize=11)
            ax.set_xlabel("OI (FLOPs/B)", fontsize=10)
            if idx == 0: ax.set_ylabel("GFLOPS", fontsize=10)
            ax.grid(True, which="both", alpha=0.1); ax.tick_params(labelsize=9)
        self.bws = original
        plt.suptitle(f"Sweep: {bw_name} bandwidth", fontsize=13, fontweight="bold")
        plt.tight_layout(); plt.show()

    def sweep_compute(self, compute_name: str, values: list[float], figsize=(14, 5)):
        fig, axes = plt.subplots(1, len(values), figsize=figsize, sharey=True)
        if len(values) == 1:
            axes = [axes]
        original = [ComputeCeiling(c.name, c.peak_gflops, c.color, c.linestyle) for c in self.computes]
        for idx, val in enumerate(values):
            for c in self.computes:
                if c.name == compute_name:
                    c.peak_gflops = val
            ax = axes[idx]
            oi = np.logspace(-1, 3, 500)
            for b in self.bws:
                ax.plot(oi, b.peak_gbs * oi, color=b.color, linewidth=1.5, alpha=0.7, linestyle=b.linestyle)
            for c in self.computes:
                ax.axhline(y=c.peak_gflops, color=c.color, linewidth=1.5, alpha=0.7)
            for w in self.workloads:
                perf, _, regime = self._attainable(w.oi, w.computes, w.bws, w.overlap)
                color = "#378ADD" if regime == "compute-bound" else "#D85A30"
                ax.plot(w.oi, perf, "o", color=color, markersize=6, zorder=10)
                ax.annotate(w.name, xy=(w.oi, perf), fontsize=7,
                            xytext=(3, -3), textcoords="offset points", color=color, va="top")
            ax.set_xscale("log"); ax.set_yscale("log"); ax.set_xlim(0.1, 1024)
            ax.set_title(f"{compute_name} = {val} GFLOPS", fontsize=11)
            ax.set_xlabel("OI (FLOPs/B)", fontsize=10)
            if idx == 0: ax.set_ylabel("GFLOPS", fontsize=10)
            ax.grid(True, which="both", alpha=0.1); ax.tick_params(labelsize=9)
        self.computes = original
        plt.suptitle(f"Sweep: {compute_name} peak compute", fontsize=13, fontweight="bold")
        plt.tight_layout(); plt.show()

    # ══════════════════════════════════════════════════════════════
    #  Interactive Dashboard (ipywidgets)
    # ══════════════════════════════════════════════════════════════

    def interactive(self, figsize=(11, 6), oi_range=(0.1, 1024)):
        """
        ipywidgets 기반 interactive dashboard.

        - Compute/BW ceiling: slider + 직접 입력
        - Workload: log-slider로 OI 조절
        - +/x 버튼으로 항목 추가/삭제
        - Apply: 현재 값을 model 객체에 반영
        - Reset: model 객체의 원래 값으로 복원
        """
        if not HAS_WIDGETS:
            raise ImportError("ipywidgets 필요: pip install ipywidgets")

        state = {
            "computes": deepcopy(self.computes),
            "bws": deepcopy(self.bws),
            "workloads": deepcopy(self.workloads),
        }

        plot_out = widgets.Output()
        table_out = widgets.Output()
        controls_out = widgets.Output()

        def redraw():
            tmp = RooflineModel()
            tmp.computes = state["computes"]
            tmp.bws = state["bws"]
            tmp.workloads = state["workloads"]

            with plot_out:
                clear_output(wait=True)
                fig, ax = plt.subplots(figsize=figsize)
                tmp.plot(ax=ax, oi_range=oi_range, show_annotations=True,
                         title="Hierarchical Roofline (interactive)")

            with table_out:
                clear_output(wait=True)
                results = tmp.analyze()
                if results:
                    lines = []
                    lines.append(f"  {'Workload':<22} {'OI':>7} "
                                 f"{'GFLOPS':>10} {'Bottleneck':<18} {'Regime'}")
                    lines.append(f"  {chr(9472)*22} {chr(9472)*7} "
                                 f"{chr(9472)*10} {chr(9472)*18} {chr(9472)*15}")
                    for r in results:
                        tag = "C " if r.regime == "compute-bound" else "M "
                        lines.append(
                            f"  {r.workload_name:<22} {r.oi:>7.1f} "
                            f"{r.attainable_gflops:>10.1f} "
                            f"{r.bottleneck:<18} {tag}{r.regime}")
                    print("\n".join(lines))
                ridges = tmp.ridge_points()
                if ridges:
                    print("\n  Ridge points:")
                    for rp in ridges:
                        print(f"    {rp.compute_name} x {rp.bw_name}: "
                              f"OI = {rp.oi:.2f}")

        def rebuild_controls():
            with controls_out:
                clear_output(wait=True)
                rows = []

                # ── Compute ──
                rows.append(widgets.HTML(
                    "<b style='font-size:14px;'>Compute ceilings</b>"))
                for i, c in enumerate(state["computes"]):
                    idx = i
                    name_w = widgets.Text(
                        value=c.name, layout=widgets.Layout(width="130px"))
                    slider_w = widgets.FloatSlider(
                        value=c.peak_gflops,
                        min=1, max=max(c.peak_gflops * 4, 10000),
                        step=1, readout_format=".0f",
                        layout=widgets.Layout(width="260px"),
                        style={"handle_color": c.color})
                    text_w = widgets.FloatText(
                        value=c.peak_gflops,
                        layout=widgets.Layout(width="80px"))
                    widgets.link((slider_w, "value"), (text_w, "value"))
                    label_w = widgets.HTML(
                        "<span style='font-size:12px;color:#888;'>GFLOPS</span>")
                    del_w = widgets.Button(
                        description="\u2715",
                        layout=widgets.Layout(width="32px"),
                        button_style="danger")

                    def mk_upd(ii):
                        def f(change):
                            state["computes"][ii].peak_gflops = change["new"]
                            redraw()
                        return f
                    def mk_ren(ii):
                        def f(change):
                            state["computes"][ii].name = change["new"]
                            redraw()
                        return f
                    def mk_del(ii):
                        def f(_):
                            state["computes"].pop(ii)
                            rebuild_controls(); redraw()
                        return f

                    slider_w.observe(mk_upd(idx), names="value")
                    name_w.observe(mk_ren(idx), names="value")
                    del_w.on_click(mk_del(idx))
                    rows.append(widgets.HBox(
                        [name_w, slider_w, text_w, label_w, del_w],
                        layout=widgets.Layout(gap="4px", align_items="center")))

                add_c = widgets.Button(description="+ Compute",
                                       layout=widgets.Layout(width="110px"))
                def on_add_c(_):
                    col = self.COMPUTE_COLORS[
                        len(state["computes"]) % len(self.COMPUTE_COLORS)]
                    state["computes"].append(ComputeCeiling("New", 256, col))
                    rebuild_controls(); redraw()
                add_c.on_click(on_add_c)
                rows.append(add_c)

                # ── BW ──
                rows.append(widgets.HTML(
                    "<br><b style='font-size:14px;'>Bandwidth ceilings</b>"))
                for i, b in enumerate(state["bws"]):
                    idx = i
                    name_w = widgets.Text(
                        value=b.name, layout=widgets.Layout(width="130px"))
                    slider_w = widgets.FloatSlider(
                        value=b.peak_gbs,
                        min=1, max=max(b.peak_gbs * 4, 50000),
                        step=1, readout_format=".0f",
                        layout=widgets.Layout(width="260px"),
                        style={"handle_color": b.color})
                    text_w = widgets.FloatText(
                        value=b.peak_gbs,
                        layout=widgets.Layout(width="80px"))
                    widgets.link((slider_w, "value"), (text_w, "value"))
                    label_w = widgets.HTML(
                        "<span style='font-size:12px;color:#888;'>GB/s</span>")
                    del_w = widgets.Button(
                        description="\u2715",
                        layout=widgets.Layout(width="32px"),
                        button_style="danger")

                    def mk_upd(ii):
                        def f(change):
                            state["bws"][ii].peak_gbs = change["new"]
                            redraw()
                        return f
                    def mk_ren(ii):
                        def f(change):
                            state["bws"][ii].name = change["new"]
                            redraw()
                        return f
                    def mk_del(ii):
                        def f(_):
                            state["bws"].pop(ii)
                            rebuild_controls(); redraw()
                        return f

                    slider_w.observe(mk_upd(idx), names="value")
                    name_w.observe(mk_ren(idx), names="value")
                    del_w.on_click(mk_del(idx))
                    rows.append(widgets.HBox(
                        [name_w, slider_w, text_w, label_w, del_w],
                        layout=widgets.Layout(gap="4px", align_items="center")))

                add_b = widgets.Button(description="+ Bandwidth",
                                       layout=widgets.Layout(width="110px"))
                def on_add_b(_):
                    col = self.BW_COLORS[
                        len(state["bws"]) % len(self.BW_COLORS)]
                    state["bws"].append(BWCeiling("New", 100, col))
                    rebuild_controls(); redraw()
                add_b.on_click(on_add_b)
                rows.append(add_b)

                # ── Workloads ──
                rows.append(widgets.HTML(
                    "<br><b style='font-size:14px;'>Workloads</b>"))
                compute_names = [c.name for c in state["computes"]]
                bw_names = [b.name for b in state["bws"]]
                for i, w in enumerate(state["workloads"]):
                    idx = i
                    name_w = widgets.Text(
                        value=w.name, layout=widgets.Layout(width="150px"))
                    slider_w = widgets.FloatLogSlider(
                        value=max(w.oi, 0.1), base=10, min=-1, max=4,
                        step=0.01, readout_format=".2f",
                        layout=widgets.Layout(width="240px"))
                    text_w = widgets.FloatText(
                        value=w.oi,
                        layout=widgets.Layout(width="80px"))
                    widgets.link((slider_w, "value"), (text_w, "value"))
                    label_w = widgets.HTML(
                        "<span style='font-size:12px;color:#888;'>FLOPs/B</span>")

                    # Compute ceiling selector
                    comp_sel = widgets.SelectMultiple(
                        options=compute_names,
                        value=w.computes if w.computes is not None else compute_names,
                        layout=widgets.Layout(width="130px", height="40px"),
                        description="C:",
                        style={"description_width": "16px"})
                    # BW ceiling selector
                    bw_sel = widgets.SelectMultiple(
                        options=bw_names,
                        value=w.bws if w.bws is not None else bw_names,
                        layout=widgets.Layout(width="130px", height="40px"),
                        description="B:",
                        style={"description_width": "16px"})

                    # Overlap toggle
                    ovl_w = widgets.Checkbox(
                        value=w.overlap,
                        description="overlap",
                        layout=widgets.Layout(width="90px"),
                        style={"description_width": "auto"})

                    del_w = widgets.Button(
                        description="\u2715",
                        layout=widgets.Layout(width="32px"),
                        button_style="danger")

                    def mk_upd(ii):
                        def f(change):
                            state["workloads"][ii].oi = change["new"]
                            redraw()
                        return f
                    def mk_ren(ii):
                        def f(change):
                            state["workloads"][ii].name = change["new"]
                            redraw()
                        return f
                    def mk_comp_sel(ii):
                        def f(change):
                            sel = list(change["new"])
                            all_c = [c.name for c in state["computes"]]
                            state["workloads"][ii].computes = None if set(sel) == set(all_c) else sel
                            redraw()
                        return f
                    def mk_bw_sel(ii):
                        def f(change):
                            sel = list(change["new"])
                            all_b = [b.name for b in state["bws"]]
                            state["workloads"][ii].bws = None if set(sel) == set(all_b) else sel
                            redraw()
                        return f
                    def mk_ovl(ii):
                        def f(change):
                            state["workloads"][ii].overlap = change["new"]
                            redraw()
                        return f
                    def mk_del(ii):
                        def f(_):
                            state["workloads"].pop(ii)
                            rebuild_controls(); redraw()
                        return f

                    slider_w.observe(mk_upd(idx), names="value")
                    name_w.observe(mk_ren(idx), names="value")
                    comp_sel.observe(mk_comp_sel(idx), names="value")
                    bw_sel.observe(mk_bw_sel(idx), names="value")
                    ovl_w.observe(mk_ovl(idx), names="value")
                    del_w.on_click(mk_del(idx))
                    rows.append(widgets.HBox(
                        [name_w, slider_w, text_w, label_w, comp_sel, bw_sel, ovl_w, del_w],
                        layout=widgets.Layout(gap="4px", align_items="center")))

                add_w = widgets.Button(description="+ Workload",
                                       layout=widgets.Layout(width="110px"))
                def on_add_w(_):
                    state["workloads"].append(Workload("New", 10.0))
                    rebuild_controls(); redraw()
                add_w.on_click(on_add_w)
                rows.append(add_w)

                # ── Action buttons ──
                rows.append(widgets.HTML("<br>"))
                apply_btn = widgets.Button(
                    description="Apply to model",
                    icon="check",
                    layout=widgets.Layout(width="150px"),
                    button_style="info")
                def on_apply(_):
                    self.computes = deepcopy(state["computes"])
                    self.bws = deepcopy(state["bws"])
                    self.workloads = deepcopy(state["workloads"])
                    with table_out:
                        print("\n  [OK] Applied to model object. "
                              "Use m.plot() / m.summary() outside.")
                apply_btn.on_click(on_apply)

                reset_btn = widgets.Button(
                    description="Reset",
                    icon="undo",
                    layout=widgets.Layout(width="100px"))
                def on_reset(_):
                    state["computes"] = deepcopy(self.computes)
                    state["bws"] = deepcopy(self.bws)
                    state["workloads"] = deepcopy(self.workloads)
                    rebuild_controls(); redraw()
                reset_btn.on_click(on_reset)

                save_btn = widgets.Button(
                    description="Save PNG",
                    icon="save",
                    layout=widgets.Layout(width="110px"),
                    button_style="success")
                def on_save(_):
                    tmp = RooflineModel()
                    tmp.computes = state["computes"]
                    tmp.bws = state["bws"]
                    tmp.workloads = state["workloads"]
                    tmp.plot(figsize=figsize, oi_range=oi_range,
                             save_path="roofline.png", dpi=200,
                             title="Hierarchical Roofline")
                    with table_out:
                        print("  [OK] Saved to roofline.png")
                save_btn.on_click(on_save)

                rows.append(widgets.HBox(
                    [apply_btn, reset_btn, save_btn],
                    layout=widgets.Layout(gap="8px")))

                display(widgets.VBox(rows))

        # ── Assemble ──
        rebuild_controls()
        redraw()

        dashboard = widgets.VBox([
            plot_out,
            table_out,
            widgets.HTML("<hr style='border:0;border-top:1px solid #ddd;margin:8px 0;'>"),
            controls_out,
        ])
        display(dashboard)


# ══════════════════════════════════════════════════════════
#  OI 계산 유틸리티
# ══════════════════════════════════════════════════════════

def gemm_oi(M: int, K: int, N: int, elem_bytes: int = 2) -> float:
    """GEMM algorithmic OI = 2MKN / ((MK+KN+MN)*elem_bytes)."""
    flops = 2 * M * K * N
    data = (M * K + K * N + M * N) * elem_bytes
    return flops / data


def gemm_oi_tiled(Tm: int, Tk: int, Tn: int, elem_bytes: int = 2) -> float:
    """Tiled GEMM 한 tile의 OI."""
    return gemm_oi(Tm, Tk, Tn, elem_bytes)


def hong_kung_oi(sram_bytes: int, elem_bytes: int = 2) -> float:
    """Hong-Kung bound -> optimal OI ~ sqrt(S/3) / elem_bytes."""
    S_elems = sram_bytes / elem_bytes
    return np.sqrt(S_elems / 3) / elem_bytes


def attention_oi(seq_len: int, head_dim: int, elem_bytes: int = 2) -> float:
    """Self-attention OI (FlashAttention-style)."""
    flops = 4 * seq_len * seq_len * head_dim
    data = 3 * seq_len * head_dim * elem_bytes + 2 * seq_len * elem_bytes
    return flops / data


# ── Presets ──

def u55c_preset() -> RooflineModel:
    """Alveo U55C preset."""
    m = RooflineModel()
    m.add_compute("DSP INT8 (9024 DSPs)", 9024 * 2 * 0.45)
    m.add_compute("DSP FP32 (est.)", 9024 * 0.45 / 2)
    m.add_bw("BRAM/URAM (~35 TB/s)", 35000)
    m.add_bw("HBM2 32PC (460 GB/s)", 460, linestyle="--")
    m.add_bw("PCIe Gen3x16 (16 GB/s)", 16, linestyle=":")
    return m


if __name__ == "__main__":
    m = RooflineModel()
    m.add_compute("MXU INT8", 2048)
    m.add_compute("Vector FP32", 128)
    m.add_bw("SRAM", 8000)
    m.add_bw("HBM", 460)
    m.add_bw("PCIe", 16)
    m.add_workload("GEMM (4096^2)", oi=gemm_oi(4096, 4096, 4096, 1))
    m.add_workload("GEMM (512^2)", oi=gemm_oi(512, 512, 512, 1))
    m.add_workload("Attention (S=2048)", oi=attention_oi(2048, 64, 2))
    m.add_workload("LayerNorm", oi=0.5)
    m.add_workload("Softmax", oi=1.2)
    m.plot()
    m.summary()

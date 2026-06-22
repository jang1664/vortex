# HPCA Figure Notes

This is a local checklist for figures intended for an HPCA-style two-column
paper. Always confirm the current conference author kit before submission.

## Figure Size

Set Matplotlib `figsize` to the final size used in the paper, then choose font
sizes. Do not make a large figure and shrink it in LaTeX, because the text will
shrink with it.

Common presets:

- One-column figure: `figsize=(3.45, H)`
- Two-column figure: `figsize=(7.16, H)`
- PNG export for review: use `dpi=600`
- Preferred camera-ready export: use PDF or SVG when the pipeline accepts it

For Matplotlib, `figsize=(width, height)` is in inches.

## Font Sizes

Use these as starting points at final figure size:

- Main figure title: `7-8 pt`
- Subplot title: `7-8 pt`
- Axis label: `7 pt`
- Tick label: `6-7 pt`
- Legend: `6-7 pt`
- Bar/data label: `5.5-7 pt`

Avoid text below `5.5 pt` unless it is not essential. If text is unreadable at
one-column width, simplify the plot before increasing the canvas size.

## Plot Rules

- Use final-size fonts directly in the plotting script.
- Prefer short axis labels and short legend entries.
- Keep repeated y-axis labels only on the first column when subplots share a
  y-axis.
- Use PDF/SVG for LaTeX when possible; use high-DPI PNG only when raster output
  is required.
- Check the final rendered PDF, not only the standalone PNG.
- Avoid long titles inside the plot if the caption can carry the explanation.

## PowerPoint Figure Tips

PowerPoint is useful for diagrams, overview figures, and small manual edits,
but it is easy to lose paper-scale consistency. Treat the slide as the final
figure canvas.

- Set the slide size to the final target size before drawing.
  - One-column figure: `3.45 in x H`
  - Two-column figure: `7.16 in x H`
- Use the same font family as the paper when possible. Otherwise use a standard
  sans-serif font consistently across all PowerPoint figures.
- Use final-size text directly. Good starting points:
  - labels and callouts: `6-8 pt`
  - section headers inside the figure: `7-9 pt`
  - small annotations: avoid below `5.5 pt`
- Keep line widths consistent. Thin lines often disappear after PDF rendering;
  use roughly `0.5-1.0 pt` for normal lines and `1.0-1.5 pt` for emphasis.
- Align objects using PowerPoint's align and distribute tools instead of manual
  dragging.
- Keep colors consistent with Python-generated plots. Copy hex colors from the
  plotting scripts when mixing PowerPoint diagrams with Matplotlib figures.
- Avoid gradients, shadows, transparency, and decorative effects unless they
  carry information. They often rasterize poorly or distract in print.
- Group related objects before moving or resizing. Resize the group only if the
  text remains readable at the target paper width.
- Prefer vector export for paper inclusion:
  - best: export to PDF and include the PDF in LaTeX
  - acceptable: export to SVG if the LaTeX/toolchain handles it cleanly
  - fallback: export PNG at high resolution only when vector export breaks
- After export, inspect the final compiled paper PDF at 100% zoom and print
  scale. PowerPoint can look fine on the slide but become too small in the
  paper.
- Keep a `.pptx` source file next to the exported figure so future edits do not
  require reconstructing the diagram.

## Current LLM-Analysis Figure

The long-sequence attention breakdown figure is configured as a one-column
figure:

```python
ONE_COLUMN_FIGSIZE = (3.45, 3.25)
SAVE_DPI = 600

TITLE_FONTSIZE = 7.5
AXIS_LABEL_FONTSIZE = 7.0
TICK_FONTSIZE = 6.0
ANNOTATION_FONTSIZE = 5.8
LEGEND_FONTSIZE = 6.4
```

Generate it from the Vortex repo root:

```bash
python analysis_workspace/llm_analysis/plot_long_seq_attn_breakdown.py
```

Outputs:

```text
analysis_workspace/llm_analysis/figures/long_seq_attn_breakdown.pdf
analysis_workspace/llm_analysis/figures/long_seq_attn_breakdown.png
analysis_workspace/llm_analysis/figures/long_seq_attn_breakdown.svg
```

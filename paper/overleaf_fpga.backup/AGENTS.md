# Agent Instructions

This repository is a LaTeX manuscript workspace.

## Build Artifacts

When running LaTeX or related build commands, always put generated files under `_outputs/`.
The `_outputs/` directory is gitignored, so it is safe for `.aux`, `.log`, `.out`, `.pdf`, and other temporary build artifacts.

Use this pattern for XeLaTeX:

```bash
mkdir -p _outputs
xelatex -interaction=nonstopmode -halt-on-error -output-directory=_outputs _main.tex
```

If multiple LaTeX passes are needed, rerun the same command with `-output-directory=_outputs`.
Do not run LaTeX in a way that writes build artifacts into the repository root.

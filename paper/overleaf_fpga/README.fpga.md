# ACM / FPGA layout preview

`main.tex` uses the supplied `acmart-primary/acmart-primary` template's
two-column `sigconf` layout and `ACM-Reference-Format` bibliography style.
The unmodified `acmart.cls` and `ACM-Reference-Format.bst` are copied next to
`main.tex` so the project also works when uploaded to Overleaf.

The current options are `sigconf,anonymous,nonacm`: anonymous authors, with
publication metadata and rights blocks omitted for a local preview. Set the
options and metadata required by the target FPGA call for papers before
submission. No conference year, submission ID, DOI, or author details are assumed.

From this directory, run:

```sh
bash compile.sh main.tex
```

The PDF is `_outputs/main.pdf`; the LaTeX and BibTeX logs are
`_outputs/main.log` and `_outputs/main.blg`. Plain `latexmk main.tex` also
uses `_outputs/` via `.latexmkrc`.

On this host, missing TeX Live packages and font maps were installed under
`_outputs/texmf`, `_outputs/texmf-config`, and `_outputs/texmf-var`.
`.latexmkrc` uses those directories when present. Other machines need a TeX
installation with the ACM template dependencies, including Libertine,
Inconsolata, and NewTX fonts; Overleaf provides these packages.

The original IEEE/HPCA source is backed up at
`_outputs/main.ieee-original.tex`. The ACM draft before prose shortening is
saved as `_outputs/main.before-10pages.tex` and
`_outputs/main.before-10pages.pdf`.

The prose was shortened against the [FPGA 2027 long-paper limit](https://wp.isfpga.org/call-for-papers/)
of 10 pages excluding references. The current PDF ends its body approximately
80% down the second column of page 10 and has 12 pages including references,
which begin on page 10. Methodology and contribution details were restored
from the original after the initial shortening. The more condensed version
is backed up as `_outputs/main.before-fill80.tex` and `.pdf`.
Edits focus on repeated motivation and overview prose. Detailed engine,
memory-system, and runtime explanations and the evaluation result analysis
are retained. All 15 figure blocks, 6 tables, displayed equations, and 42
citation keys are preserved. The wide latency figure is queued earlier and
pending floats are placed before the conclusion.

Font sizes, line spacing, margins, and figure sizes were unchanged during
shortening. Float-to-text gaps remain fixed at one body-text line; ragged
page bottoms prevent those gaps from stretching to fill columns.
Verification results are saved in `_outputs/shortening-verification.json`.
The existing bibliography has incomplete metadata, and figures lack ACM
accessibility descriptions; these produce nonfatal warnings.

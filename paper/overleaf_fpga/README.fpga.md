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
82% down the second column of page 10 and has 12 pages including references,
which begin on page 10. Methodology and contribution details were restored
from the original after the initial shortening. The more condensed version
is backed up as `_outputs/main.before-fill80.tex` and `.pdf`.
Edits focus on repeated motivation and overview prose. Detailed engine,
memory-system, and runtime explanations and the evaluation result analysis
are retained, with a shorter accuracy-evaluation introduction. All 15 figures,
6 tables, displayed equations, and 42 citation keys remain. The wide latency figure is queued earlier and
pending floats are placed before the conclusion.

The ACM template's float spacing, list layout, and flush-bottom page alignment
are restored. Manual vertical skips and table row-height overrides were removed.
The hardware-configuration table now spans both columns at the default text
size instead of using a reduced font. Margins, body font size, line spacing,
and figure sizes are unchanged. Local table column widths remain specific
to each table.
The preceding draft is backed up as `_outputs/main.before-template-reset.tex`
and `.pdf`. Current verification results are in
`_outputs/template-reset-verification.json`.
The existing bibliography has incomplete metadata, and figures lack ACM
accessibility descriptions; these produce nonfatal warnings.

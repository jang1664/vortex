;; -*- lexical-binding: t; -*-

(TeX-add-style-hook
 "main"
 (lambda ()
   (TeX-add-to-alist 'LaTeX-provided-class-options
                     '(("IEEEtran" "10pt" "conference")))
   (TeX-add-to-alist 'LaTeX-provided-package-options
                     '(("cite" "") ("amsmath" "") ("amssymb" "") ("amsfonts" "") ("algorithmic" "") ("graphicx" "") ("textcomp" "") ("xcolor" "") ("url" "hyphens") ("fancyhdr" "") ("hyperref" "")))
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "href")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "hyperimage")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "hyperbaseurl")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "nolinkurl")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "url")
   (add-to-list 'LaTeX-verbatim-macros-with-braces-local "path")
   (add-to-list 'LaTeX-verbatim-macros-with-delims-local "path")
   (TeX-run-style-hooks
    "latex2e"
    "hpca-template"
    "IEEEtran"
    "IEEEtran10"
    "cite"
    "amsmath"
    "amssymb"
    "amsfonts"
    "algorithmic"
    "graphicx"
    "textcomp"
    "xcolor"
    "url"
    "fancyhdr"
    "hyperref")
   (TeX-add-symbols
    "hpcayear"
    "hpcasubmissionnumber"
    "hpcapubid"
    "hpcaauthors"
    "hpcaaffiliation"
    "hpcaemail")
   (LaTeX-add-labels
    "table:formatting")
   (LaTeX-add-bibliographies
    "refs"))
 :latex)


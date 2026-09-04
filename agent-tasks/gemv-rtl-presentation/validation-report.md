# GEMV RTL Presentation Validation Report

## Deliverable

- Presentation: `gemv-rtl-architecture.pptx`
- Slide count: 18
- Format: 16:9 widescreen
- Language: Korean, with RTL signal/module names preserved
- Speaker notes: one Korean source/evidence note per slide

## Automated checks

- PPTX ZIP package integrity: PASS
- Slide XML count: 18
- Speaker-note XML count: 18
- Embedded vector slide assets: 18 SVG files
- Compatibility fallback assets: 18 PNG files
- Source SVG XML parsing: PASS for all 18 slides
- Preview render count: 18
- Preview dimensions: 800 × 450 for every slide
- Manifest count and sequence: 18 entries, numbered 1 through 18
- Generator JavaScript syntax: PASS
- Git whitespace check for the generator: PASS

## Visual review

All 18 full-slide SVG assets were rendered to PNG and reviewed through
`contact-sheet.png`. The final deck uses a white background, square light-gray
panels, muted section colors, and no gradients, shadows, decorative grid, or
progress dots. Slides 2 through 17 use one top bullet panel followed by hardware
block diagrams and/or timing diagrams. Explanatory floating cards were removed;
boxed elements in the diagram area represent hardware modules only. The
schematics use distinct symbols for SRAM banks, FIFOs, DMA engines, MAC arrays,
arbiters, FSMs, pipeline registers, muxes, scoreboards/tag tables, address
generators, counters, and packet/control tokens. Dashed control and feedback
rails are separated from solid datapath buses.

Slide 4 was redrawn as a paper-style before/after schematic. The before side
shows a centralized ACC RD/WR counter block fanning out to the FIFO, MAC array,
and ACC SRAM. The after side uses distinct FIFO, multiplier, pipeline-register,
MAC-array, post-process mux, RAW mux, and SRAM-bank symbols, with a parallel
control-token pipeline carrying address, R/W intent, sequence, generation, and
last metadata.

The remaining architecture slides were reviewed with the same criterion:
every visual must expose a dataflow, ownership boundary, dependency, ordering
fence, or timing consequence. Timing-only slides are kept where cycle overlap
or blocking behavior communicates the point more directly than another
schematic.

All titles, bullet explanations, diagram captions, timing labels, footers, PPT
metadata, manifest titles, and speaker notes are localized in Korean. Hardware
acronyms, RTL signal names, module names, and protocol terms such as
ready/valid remain unchanged where translation would obscure the implementation
contract. Korean text uses the Noto Sans CJK KR font with standard PowerPoint
fallbacks.

Slide 5 explains the GEMM-unit ready/backpressure change with a before/after
schematic and timing comparison. The before side makes the W/S/Z admission
gate and visible frontend latency explicit. The after side separates elastic
PRE and POST ready regions from the five-cycle fixed MXU island, places exact
W/S/Z bank-generation checks at the real consumers, and shows the six-entry
merged-result FIFO with registered credit return.

The environment does not provide LibreOffice or PowerPoint. The PPTX embeds
the reviewed full-slide SVG assets directly and also contains PNG fallbacks,
so the reviewed artwork and the PowerPoint slide artwork are the same assets.

## Regeneration

The generator requires `pptxgenjs` version 4.0.1 or a compatible release and
loads visible-text translations from `ko-translations.json`.
One reproducible invocation is:

```bash
presentation_deps_dir=$(mktemp -d /tmp/gemv-ppt-deps.XXXXXX)
npm install --prefix "$presentation_deps_dir" pptxgenjs@4.0.1
NODE_PATH="$presentation_deps_dir/node_modules" \
  node agent-tasks/gemv-rtl-presentation/generate-presentation.cjs
```

The generator writes the PPTX, the 18 source SVGs, and the slide manifest.

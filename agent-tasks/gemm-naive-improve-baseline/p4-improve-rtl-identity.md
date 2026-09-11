# Improve RTL preservation evidence

The binding user criterion is RTL identity, not synthesized cost matching.
No synthesis was run for this check.

Full improve GEMM-node hierarchy and logic XML compare identically between the
P0 corrected-source baseline and the current candidate at TH16/MXU16 and
TH16/MXU32. The check preserves every semantic AST node, value, width,
identifier, reference, and name. Only file provenance tables, source-location
attributes, and XML indentation are excluded from comparison.

| Geometry | Logic AST elements | Hierarchical cells | Specialized modules | Variable declarations | Result |
|---|---:|---:|---:|---:|---|
| MXU16 | 213111 | 3436 | 222 | 10721 | Exact identity |
| MXU32 | 450577 | 10028 | 214 | 12726 | Exact identity |

These are RTL structural counts, not mapped resource costs. Complete AST
identity covers the elaborated interfaces, state/queue declarations, pipeline
and ready/valid expressions within this node. Shared core/memory integration
outside the node is covered separately by the 88 selected-RTL preprocessing
comparisons in p1-isolation/iteration15/result.json, including PERF on/off.
The full-node XML run uses SYNTHESIS/NDEBUG without PERF; it is static elaboration,
not functional Verilator simulation. Existing VCS M4/M256 improve regressions
also have exactly zero GEMM and core-cycle delta against P0.

## Reproducibility and limitations

- Commands, tool outputs, private source copies, XML and hashes are retained in
  p4-improve-rtl/{baseline,candidate}{16,32}-iteration3/.
- p4-improve-rtl/comparison.json records exact canonical SHA256 equality.
- p4-improve-rtl/provenance.json verifies all 335 baseline RTL files against the
  frozen archive and all candidate RTL hashes against the live source tree.
- Both revisions use the same improve config and unchanged flattened node
  wrapper. PLATFORM_MEMORY_ID_WIDTH=8 matches the wrapper AXI ID parameter.
- The configured build directory is build_p0_boundary_storage_rev3. The tool is
  Verilator 5.028 in XML-only mode. No mapped netlist is produced.
- This frontend cannot elaborate dotted interface $bits parameter constants.
  Identical private copies of VX_slr_mem_bus expand request width to
  `1 + ADDR_WIDTH + 9*DATA_SIZE + FLAGS_WIDTH + TAG_WIDTH`, response width to
  `8*DATA_SIZE + TAG_WIDTH`, and response-tag width to TAG_WIDTH. These follow
  the packed fields of the unchanged VX_mem_bus_if exactly. The production RTL
  and frozen snapshots are untouched; substitutions are recorded per run.
- Vendor floating-point modules have the same opaque port declarations in both
  elaborations; this does not inspect vendor internal logic or estimate its cost.
- Attempts 1/2 retain the missing platform define and dotted-$bits frontend
  diagnostics. Attempt 3 passes for both revisions and geometries.

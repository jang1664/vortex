# R3 external-audit query cost

This is a read-only diagnosis of the frozen R3 OOC checkpoint with SHA-256
`133de6af5d735182ec45514c941291c2f9144dddaf60c1f541f72e513a2f9955`.
No ownership inventory, placement, synthesis or production-file change was
performed. Evidence is under `logs/r3_clock_query_probe/`.

| Query | Result | Measured seconds |
|---|---:|---:|
| Exact canonical `ap_clk` net | 1 object | 0.000548 |
| All segments of `ap_clk` | 8489 objects, all unique names | 0.178934 |
| Leaf pins from the single canonical clock net | 295102 objects | 0.150053 |
| Bulk leaf NAME / DIRECTION / REF_PIN_NAME | 295102 values each | 1.325695 / 0.838342 / 0.818091 |
| Ports from all 8489 clock segments | Not completed | More than 444 seconds |
| Ports from the single canonical clock net | `ap_clk` | 0.032210 |

The all-segment `get_ports` query itself demonstrably has pathological cost.
The original unfiltered all-segment leaf expansion was deliberately not repeated;
this probe does not identify which internal query the uninstrumented original
audit was executing. Querying leaf pins and ports from a single canonical net
avoids redundant hierarchy traversal while preserving the connected group.

Local Vivado help was captured in `query_help.log`. The supported
`-top_net_of_hierarchical_group` option returns the highest-level segment(s) of
a hierarchical net. The candidate resolves **each** selected net with
`get_nets -quiet -segments -top_net_of_hierarchical_group $net_name`, requires
exactly one result, and uses that object for both leaf-pin and port queries.
It preserves original report labels, topology errors and all other checks.

Actual probe session 7948 exited zero after eight non-clock groups with 5–11
segments and 2–99 pins. Old all-segment and canonical queries produced identical
deduplicated leaf names, port lists, and driver/sink counts. Case 7 begins below
`gemm_node/dma_local_data_if...`, but its canonical net belongs to the enclosing
core, outside `gemm_node`; the complete one-driver/two-sink connectivity is
preserved. This explicitly checks a hierarchy exit, not merely a local net name.

The isolated candidate and full-report mock fixture are in `mock/`.
`test_canonical_equivalence.tcl` passed 43 checks covering internal/lateral
segments, duplicated endpoints, 1000 unrelated clock sinks, unchanged report
bytes/acceptance, direct ports, multiple drivers, unresolved placement,
ambiguous pin spelling, empty nets, truncated bulk properties and ambiguous
canonical-net cardinality. `canonical_query.patch` is the minimal proposal;
`canonical_proof.json` records source/log hashes. Root independently reviews
and applies any helper change.

After the scoped alternative and equivalence checks passed, diagnostic session
2530 was deliberately superseded, terminal exit 143. Its partial timings and
native-query boundary remain in `run.log` and `diagnostic_supersession.json`.
This was not a timeout failure or a physical-audit result. Original audit 79337,
R4 implementation and legacy decoder 5987 were untouched. The original probe's
optional config-source failure under zsh is recorded in `launch_notes.txt`;
the successful canonical probe used bash and sourced the C4 fusion config.
Neither read-only probe depends on CONFIGS to query the opened DCP.

The direct `ap_clk` top port remains an explicit topology-review condition in
the candidate. This performance change does not waive that condition or claim
physical SLR acceptance.

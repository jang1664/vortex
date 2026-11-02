# R3 external audit: per-net array dedup candidate

- Scope: task-only audit helper, no production RTL/floorplan or running process edits.
- Candidate: `logs/r3_clock_loop_probe/mock/audit_fusion_external_slr.candidate.tcl`
- Baseline: same directory, `audit_fusion_external_slr.before.tcl` (frozen canonical helper).
- Patch: `logs/r3_clock_loop_probe/array_dedup.patch`.
- Independent verifier/root must review and apply; active helper is not changed by author.

The only algorithm change replaces the per-net `seen` dictionary with a fresh
local Tcl array. `array unset seen; array set seen {}` resets it on every net.
`info exists seen($name)` and `set seen($name) 1` replace the equivalent dictionary
membership/insertion. The exact typed-object foreach, first occurrence order,
bulk-property cardinality, directions, destinations, top-level ports, topology,
metadata, classification and report formatting remain unchanged. No raw name
is substituted for a typed object.

## Actual evidence

All actual queries use the same R3 OOC DCP SHA
`133de6af5d735182ec45514c941291c2f9144dddaf60c1f541f72e513a2f9955`.

The bounded original loop probe is session43275, log `run.log` under the evidence
directory. Native canonical/leaf queries, all bulk properties and ports together
took only seconds. Exact dictionary loop reached 10000 pins in16.686s and
20000 in125.729s, then took its explicit in-loop bound. A following string-only
loop retained dictionary dedup and remained slow. Its outer900s cap remains
unchanged; no false completion is claimed.

No-DCP synthetic session25732 exited0: same generated strings and loop took
32.1s for16000 in Vivado, versus19ms for30000 in ordinary tclsh. Bounded phase
microbenchmark90626 exited0 and isolated dictionary insertion: dict-only5000
2.614s/10000 10.476s; scalar lappend20000 53ms, nested lappend65ms, array dedup77ms,
array dedup plus destination array103ms. Tcl8.6.13 command origin/proc/execution
trace and local-variable trace inspection found no Tcl wrapper or trace. This
identifies an observed Vivado dictionary cost, without claiming its internal
implementation cause is known.

Actual full-clock array probe6579 exited0. It kept the original typed-object
foreach and traversed all295102 pins in6.116s:295102 unique,0drivers,295102
destinations,0unexpected directions. Independent sorted NAME set comparison
matched all295102 entries in1.840s. Typed object owner queries succeeded at
indices0/9999/19999/100000/295101, including real bracketed cell names. There are
no duplicate names on this actual clock; therefore every loop iteration appends
in original bulk-property/object order. Duplicated first-occurrence order is
checked by the byte-identical complete mock reports below. This clock still
has one top port and zero primitive drivers; neither condition is waived.

## Full-report equivalence

Run:

```bash
tclsh agent-tasks/c4-sram-flash-attention/logs/r3_clock_loop_probe/mock/test_array_equivalence.tcl
```

Author run exited0 with43 checks. It compares complete TSV/summary/unowned
reports byte-for-byte, acceptance, and metadata query counts for same-SLR,
cross-SLR, unresolved placement, top-port, multiple-driver, ambiguous-terminal,
empty-net and malformed bulk/canonical cases. Every net has duplicated pin
names; repeated internal/lateral selections of the same canonical net verify
that dedup is cleared per net. Feature names contain brackets and parentheses.
Unrelated clock fanout remains1000 sinks. Identical rows establish ordering as
well as set membership.

The initial mock failed because its single-object `get_property` returned a
one-element Tcl list with literal braces around bracketed names, unlike the
scalar Vivado property result used by metadata. Both baseline and candidate
failed the same classification. Corrected only this mock's single-object return;
the original script/log are preserved as `test_array_equivalence.v1.tcl` and
`mock_equivalence_v1.log`. No production behavior was changed to satisfy it.

Review the three-line logic replacement, rerun complete equivalence independently,
and inspect actual timing/count/type receipts. Only then may root apply the
task helper and explicitly supersede the slow old audit for this validated
algorithm revision. Do not classify the old live audit as failed due solely to
elapsed observation time. Its process and R4 remain untouched by this author.

# User update: finish with ordinary xrt-vcs-sim PASS checks

The user instructed: "너가 하고 있는 reset 관련된 너무 fine한 test는 안 해도 돼.
xrt-vcs-sim 으로 돌려서 PASS하는 것 까지만 체크해줘."

For the remaining validation, run ordinary xrt-vcs-sim on the final RTL and
check numerical PASS. Stop adding or running fine-grained reset tests. No new
directed reset/stall tests or further waveform studies are needed to finish this
validation step. The previously completed measurements and RTL-identity evidence
remain available; this instruction does not turn an omitted test into a PASS.

The final smoke/regression covers the requested TH16/MXU16 M4 and M256 shapes
with K=N512 and corrected vectors. Preserve source/config/result provenance.
Finish implementation cleanup and address any actual failure from these runs.
The existing prohibitions on improve synthesis and further S/Z bidirectional
forced-stall runs remain in effect. Frozen P0 evidence is unchanged.

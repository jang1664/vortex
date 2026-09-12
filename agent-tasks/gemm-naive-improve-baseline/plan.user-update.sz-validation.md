# User update: S/Z validation scope

This binding update supersedes the mandatory bidirectional S/Z forced-stall
progress tests in plan.rev3.md section 6.1 and p0-progress-contract.md.

The user instructed that these tests are unnecessary for this task: scheduling
is controlled by dependency metadata, and the concerning scenario has not been
observed in the ordinary simulations reviewed so far.

- Do not launch further S/Z bidirectional forced-stall or cross-progress runs.
- Do not require completion of the QCOL/QROW by blocked-Scale/blocked-Zero
  matrix for acceptance. Mark this gate as not required by the user, not passed.
- Keep dependency-metadata scheduling checks, ordinary numerical simulation,
  and the independent Scale/Zero engine design requirements.
- Retain existing directed captures and analysis as reference only. The QCOL
  Scale-hold iteration3 numerical and cross-progress checks passed; this is
  evidence for that single stimulus, not a completed bidirectional matrix.
- This scope decision does not prove the concerning scenario impossible and
  does not waive a real scheduling or correctness failure if one is observed.

The frozen plan and P0 contract remain unchanged as baseline records. Read this
update together with plan.user-update.rtl-preservation.md for current execution.

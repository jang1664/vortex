# Latency test migration

The existing gemm_latency_observer TEST=controller BACKEND=naive entry now
compiles VX_naive_gemm_control and the shared naive_meta_control testbench.
It no longer references the retired explicit WAIT/NOTIFY controller, FSM, sync
helper or their interfaces. The testbench checks actual metadata command
execution with independently timestamped completion/store edges. Configure
DELIVERY_DELAY and STORE_DELAY through simulator plusargs; the12-case geometry
matrix is recorded in p5-controller-endpoints.md.

The old tb_controller.sv is now improve-only. Its improve-selected content,
modeled quiescence and six jobs with D0/1/17 and STORE delays0/7 are retained.
Both public test entry paths pass VCS with explicit XLEN64. Production RTL was
not changed in this migration.

Evidence: p5-verification/latency-migration-iteration1/improve and
p5-verification/latency-migration-iteration2/naive. The first naive attempt's
compile/run backend mismatch and corrective invocation are retained in its
diagnosis.md. For verify_rtl.py, export BACKEND/TEST and MAKEFLAGS=-B because
--params affects make run only; do not rely on it for compile-time selection.

The remaining legacy synchronization references are in the old gemm_node
fixture and the naive_node_integration source manifest. Those must migrate
before deleting the legacy RTL helpers.

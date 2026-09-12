# Naive Input context verification request

Iteration 1; test_type `new_tb`; simulator VCS. Configure a build directory
with XLEN64 and source the naive TH16/MXU16 configuration. Run this directory's
generated Makefile through `tools/verify_rtl.py unittest --path ABSOLUTE_PATH
--sim vcs`. Repeat with MXU32 and its matching LMEM port geometry. The Makefile
explicitly selects XLEN64; the fixture checks the actual 1,805-bit context allocation
at the frozen 34-bit physical address width.

The production helper is staged `VX_naive_input_contexts.sv`, guarded entirely
by `GEMM_NAIVE`. It contains four 449-bit records and three two-bit pointers plus
a three-bit count. Admission advances at accepted packet end. Ordered completion
uses the registered ingress-complete bit for ordinary work, and additionally
requires the exact terminal work's physical fence for terminal work. The node
must generate that fence from closed producer state and actual bank commits.
This fixture supplies the explicit fence input; it does not prove the node's
physical fence implementation.

The test exercises a full four-entry queue, next-command ingress while previous
completion is backpressured, simultaneous full-queue retirement/enqueue, delayed
terminal completion and wrong terminal identity, O-owner input blocking, GEMM
input backpressure, packet-end versus final-output mode, carried W/S/Z targets,
addresses above 4 GiB, exact accepted packet count, ordered completions, and
completed-context reuse without reset. It does not use forced DUT state.

No simulation pass is claimed before independent verification. The helper must
replace the old packetizer context array during node integration; it must not
be instantiated alongside another context array. Input data ownership, actual
S/W/Z consume checks, PSUM hazards and source-read completion joins remain node
integration responsibilities. The source-generation fields stored here are not
themselves evidence that all memory responses have been captured.

Iteration 1 failed the time-zero allocation check: the frozen interface map
over-added the listed context fields by 100 bits per record. The actual sum is
204 address/stride + 42 count/index + 10 flags + 96 W/S/Z targets + 32 work ID
+ 32 O target + 33 source owner = 449 bits, with no missing field. Four records
plus nine pointer/count bits use 1,805 bits, below the frozen 2,205-bit ceiling.
Iteration 2 corrects the static arithmetic and fixture expectation; it adds no
padding or storage and changes no functional logic. The frozen map is retained
as historical allocation evidence. Independent VCS rerun is required.

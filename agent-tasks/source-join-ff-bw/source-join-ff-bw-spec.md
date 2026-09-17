# Source join event register and geometry widths

Status: confirmed by user implementation plan on 2026-09-17.

Register closure valid/buffer/generation/count and all four read-done valid/work IDs together inside VX_naive_source_join. Preserve the owner feedback loop, full 32-bit input count validation, ports and MMIO. Block quiescence with pending events, clear valid on reset and assert drained invocation starts.

Narrow knum/nnum/product/kb_q/nb_q in VX_gemm_fsm_naive_meta from geometry while preserving clamp/ceil arithmetic and 32-bit count outputs. Changes stay inside GEMM_NAIVE.

Measure before/after --perf 3 compute_cycles for M=1,4,256, K=N=256, QBLK=32, QDIR=WTRANS=0, REPS=1 using the specified naive TCU base PnR config. Preserve raw logs, source/config/tool/binary identity. Verify source join, FSM oracle and integrated control in VCS for MXU16/32, including malformed inputs. Prove improve preprocessed RTL identity and zero GEMM/core cycle delta using the existing TH16/MXU16 all-BRAM config; no improve synthesis.

After successful validation run local run_hw.sh in build/hw/syn/xilinx/xrt with the exact config, unique source_join_ff_bw timestamp postfix, SLR floorplan, default place/route, FAST_MODE=0, no PERF/DEBUG. Check 10ns constraint and final xclbin clock. Report timing, hold, failing endpoints, resources and worst paths versus previous base run; distinguish bitstream, packaging and 100MHz closure.

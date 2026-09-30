# Native FPGA WoQ ablation — confirmed

User approved the analysis plan with “ㄱㄱ”. Goal: replace ASIC Table VI and Fig. 15 resource evidence with reproducible FPGA-native measurements.

Scope: experiment-only snapshot/wrapper of production VX_gemm_unit_top, compile-time QDIR_COL and weight address direction bit[1]=0, preserving buffer bit[0]. No production RTL or manuscript edits. Same ACC capacity/config, IP and clock as Fig. 5. Reuse TCU/WKV only after source/IP compatibility checks. Default native DSP mapping; no DSP-free run, board power or Fmax claims.

Functional verification compares derived WoQ with unrestricted WKV driven legal Q-COL/row-load inputs. Cover scale/zero, K accumulation, buffer swaps, backpressure/reset; validate WKV Q-ROW/column-load separately where supported. Log actual verification limitations. C4 routed resource breakdown is separate from OOC scope. See PLAN.md for full agreed decisions and deliverables.

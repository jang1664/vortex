# Real synthesized-checkpoint hook regression

## Scope and method

The verification uses Vivado 2025.1 (SW build 6140274) and the existing
TH32/t4 and TH32/t8 synthesized kernel checkpoints from the failed source
implementation builds. A dedicated `build_slr_hook_check` directory was
configured with XLEN64 after sourcing the TH32/t4 config. Each subsequent
Vivado invocation sources its matching TH32 config before launch.

The reusable driver is [check-kernel-dcp.tcl](check-kernel-dcp.tcl). It accepts
`reproduce|updated checkpoint hook_directory output_directory 4|8`.

- `reproduce` loads the historical `xrt_backup/floorplan.tcl`, requires the
  exact observed dotted command-receiver classification failure, and checks
  that no user SLR pblock was created.
- `updated` runs inventory, marked-group validation, exact FF Q-to-D link
  validation and partition-boundary-net validation before applying full-SLR
  pblocks in memory. It then requires precisely three pblocks and exact leaf
  membership. The driver exits nonzero on any unexpected result.
- Neither mode saves a checkpoint or runs synthesis, optimization, placement,
  routing, or a source-build retry. Raw logs and TSV reports are stored only
  in ignored `build_slr_hook_check` subdirectories.

The verification-agent references to `harness/rules/testbench.md`,
`harness/skills/run-test/SKILL.md`, and
`harness/skills/add-test-case/SKILL.md` are absent in this checkout. This task
does not run an RTL simulator: deterministic Vivado return codes, explicit
PASS markers and generated report checks are used instead.

## Original artifacts

For `N=4` or `N=8`, the input checkpoint is:

```text
build_four_config_pnr_th32_tN/hw/syn/xilinx/xrt/
  improve_th32_tcol32_m32_tN_bigmem_slr_v1_xilinx_u55c_gen3x16_xdma_3_202210_1_hw/
  _x/link/vivado/vpl/prj/prj.runs/ulp_vortex_afu_1_0_synth_1/ulp_vortex_afu_1_0.dcp
```

| Artifact | SHA256 before testing |
|---|---|
| TH32/t4 kernel DCP | `035ee8f5c7009ed499d212a54c9b6f0cdfe964cd9a26becb54e684953b9f4818` |
| TH32/t8 kernel DCP | `da9c3a27fd0e2bb328a821711eeac3bae35de7c9fc90779aef5784a6ef27124e` |
| Both snapshot `floorplan.tcl` files | `102b2fb3d1750fed077e7d55b7c88c8e08a830931ec06e2300aa232f5eff6f05` |
| Both snapshot `slr_floorplan_report.tcl` files | `657a60133319059d26fe9ac5f316d6e3febdf3776ac57b7860323fbb74eaf366` |

## Results

| Check | TH32/t4 | TH32/t8 |
|---|---|---|
| Original failure reproduced | PASS, exit 0 | PASS, exit 0 |
| Updated read-only checks, iteration 1 | FAIL, exit 1 | FAIL, exit 1 |
| Final inventory and required geometry/hierarchy | PASS | PASS |
| Final marked-group presence | PASS | PASS |
| Final strict direct-pair validation | FAIL, 160 errors | FAIL, 160 errors |
| Final partition-boundary validation | Not reached | Not reached |
| Final full-SLR application | Not reached | Not reached |

Historical snapshots fail on exactly the same primitive in both checkpoints:

```text
u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/FSM_onehot_state_q[5]_i_7
```

The original inventory discovers 1,307,521 primitive leaves for t4 and
1,386,188 for t8 before reproducing the classification failure. Log paths:
`build_slr_hook_check/reproduce_t4/vivado.log` and
`build_slr_hook_check/reproduce_t8/vivado.log`. Both include the explicit
`PASS: DCP regression mode=reproduce` marker and exit 0. No user pblock was
created by this reproduction.

### Updated-source iteration 1

Started 2026-09-07 10:10 KST; logs are
`build_slr_hook_check/updated_v1_t{4,8}/vivado.log`.

| Source hook | SHA256 at launch |
|---|---|
| `floorplan.tcl` | `76d8841501a08749b3d2705a01d706f7a6c913169468428a62294cdf0cc65458` |
| `slr_floorplan_report.tcl` | `7278f05846f1f4ea1bb58f6770a51929b0306c21118845d388a7c9c113c100eb` |

Both runs fail closed before any pblock mutation on four unclassified leaves:

| Relative leaf (same on both checkpoints) | Type | Finding |
|---|---|---|
| `g_slr.u_link/u_rx/read_q0__0` | LUT1 | Lifted pointer helper lost stream identity |
| `g_slr.u_link/u_rx/write_q0__0` | LUT1 | Lifted pointer helper lost stream identity |
| `u_tmem_subsystem/g_output_slr_completion.output_done_pending_q_reg` | FDRE | Additional dotted generate boundary |
| `u_tmem_subsystem/g_output_slr_completion.output_write_pending_q_reg` | FDRE | Additional dotted generate boundary |

Both complete diagnostic TSVs are stored as `slr_unclassified_leaves.tsv`
alongside the corresponding iteration-1 log. Source hashes were unchanged at
the end of both runs. This is not an updated-source PASS; marked groups,
direct pairs and boundary nets were not reached. A separate read-only
`diagnose` driver mode is used to dump pin-level connectivity of the two
lifted LUTs, without inferring or assigning their ownership from names.

### Connectivity diagnostic

The first diagnostic-only target query matched six LUT1 helpers, not the two
root-level helpers assumed by its cardinality assertion, and exited before
dumping connectivity. Four additional helpers retain partial memory stream
identity under `u_tmem_subsystem/u_slr/u_{request,response}`. The bounded
diagnostic now includes all six to compare synthesis lifting across streams;
this changes no hook or ownership rule. Updated diagnostic logs are stored
under `build_slr_hook_check/diagnose_v2_t{4,8}`.

Both diagnostic reruns exit 0. Their complete connectivity TSVs are byte
identical (SHA256
`658d96517617de99c8ec6f7aa091128f22a8759512cf648768bbb31f94fd18af`).
The initial dump contains 77,631 rows because each hierarchical net segment
repeats its leaf pins. All conclusions below deduplicate actual leaf pin
identity; the driver now queries the complete segment set once per target
pin for future dumps.

Both root-level helpers are inverters (`LUT1 INIT=2'h1`) with exactly one
input driver and one output load:

```text
u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/read_q_reg[0]/Q
  -> g_slr.u_link/u_rx/read_q0__0/I0 -> O
  -> u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/read_q_reg[0]/D

u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/write_q_reg[0]/Q
  -> g_slr.u_link/u_rx/write_q0__0/I0 -> O
  -> u_gemm_dma_transport/u_commands/g_slr.u_link/u_rx/write_q_reg[0]/D
```

These are local command-receiver pointer toggles, not shared helpers between
opposing SLRs. A future hook recovery rule can use this explicit connectivity
proof; the fragment `g_slr.u_link` alone cannot establish ownership.

The four memory-side sibling helpers similarly connect only to the input
request reservation's request receiver (SLR0) or response receiver (SLR1).
The response read-pointer input comes from `read_q_reg[0]_rep/Q`, while its
output drives `read_q_reg[0]/D`; this is an observed replica naming case,
not an ownership exception.

### Updated-source iteration 2

The hooks now recognize the additional output-completion generate spelling
and resolve only structurally proven, unmarked lifted LUT1 pointer
self-loops to a retained stream-receiver endpoint. Runs use
`build_slr_hook_check/updated_v2_t{4,8}/vivado.log`.

| Source hook | SHA256 at launch |
|---|---|
| `floorplan.tcl` | `c42f4b566a920c44dbb96b559f7624e5608ab6727a21c43dd7900d908496fc76` |
| `slr_floorplan_report.tcl` | `7278f05846f1f4ea1bb58f6770a51929b0306c21118845d388a7c9c113c100eb` |

Both final runs exited 1 (t4 at 10:31:00 KST, t8 at 10:31:25 KST on
2026-09-07). The original hierarchy-name failure is fixed and the two root
pointer helpers are recovered only after direct local FF feedback proof.
However, a separate, genuine marked-endpoint preservation check fails:

| Final measurement | TH32/t4 | TH32/t8 |
|---|---:|---:|
| Total primitive leaves | 1,307,521 | 1,386,188 |
| Owned SLR0 leaves | 68,695 | 126,958 |
| Owned SLR1 leaves | 233,004 | 234,834 |
| Owned SLR2 leaves | 143,932 | 144,082 |
| Connectivity-proven root helper recoveries | 2 | 2 |
| Marked FFs | 10,594 | 10,596 |
| Valid direct TX-to-RX pairs | 5,248 | 5,249 |
| Literal tied-off RX FFs | 3 | 3 |
| Invalid input block-index RX links | 160 | 160 |

All 160 `# ERROR` rows in each `checked_slr_links.tsv` belong to
`g_slr_mxu_input_rx.control_q_reg[block_idx][row][bit]`, with exactly
32 distinct MXU rows and 5 bits per row. Each D pin is driven directly by
an **unmarked** FF in `u_prealign_blk_idx_pipe`, not a marked TX FF. There
are no other error categories in those two reports. Example below omits
the common kernel/GEMM-node/compute-core prefix:

```text
u_prealign_blk_idx_pipe/g_register.g_pipe_regs[0].pipe_register/
  g_shift_register/g_shift.g_partial_reset.g_stages[0].g_stage_0.pipe_reg[0][0]/Q
  -> g_slr_mxu_input_rx.control_q_reg[block_idx][0][0]/D
```

Relevant RTL in `hw/rtl/core/gemm/VX_gemm_compute_core.sv`:

- Line 1383 instantiates `u_prealign_blk_idx_pipe`; line 1388 feeds it
  `prealigner_blk_idx`.
- Lines 1537-1539 declare the intended TX `control_q` with `USER_SLL_REG`
  and `SHREG_EXTRACT`, but without `DONT_TOUCH`. The neighboring data FF
  declaration at line 1543 does have `DONT_TOUCH`.
- Line 1548 captures the same block-index input into TX control.
- Line 1562 captures TX control into RX control.

**Inference:** synthesis appears to have merged equivalent TX block-index
FFs into the existing prealigner delay FFs, losing the marked TX identity.
The netlist proves the resulting unmarked-Q-to-marked-D connections; this
report does not claim a particular synthesis merge message was found.

The strict guard remains enabled. No attribute was added to the DCP, no
unmarked driver was accepted as a marked TX, and no RTL change was made to
hide the failure. Resolving this new endpoint-preservation issue requires
separate RTL/physical-boundary consideration and subsequent verification.

The driver stops on the strict link failure **before** partition-boundary
checking or full-SLR pblock application. Therefore full post-init success
and in-memory pblock application are **not proven** by this run.

## Preservation and final state

Final SHA256 checks match both source-hook hashes recorded for iteration 2,
both original kernel DCP hashes, and all four historical snapshot-hook hashes
recorded above. No DCP was saved or modified, and all test Vivado processes
have exited. No synthesis, `opt_design`, placement, routing, P&R retry, or
RTL simulation was launched. Vivado's checkpoint-open log includes its
normal netlist-loading/unisim transformation messages, not an implementation
run.

## Limitations

- These are synthesized kernel DCPs, not platform-linked or post-opt DCPs.
  HMSS/platform logic and nested platform RP behavior are not represented.
- Unplaced source checkpoints cannot prove Laguna SITE/BEL pairing, actual
  routed SLR crossings, congestion, timing, or successful bitstream generation.
- This regression does not claim that future RTL changes preserving neither
  transport identity nor ownership are safe; such changes must fail closed.
- Historical implementation builds remain failed artifacts. No P&R run is
  resumed by this test.

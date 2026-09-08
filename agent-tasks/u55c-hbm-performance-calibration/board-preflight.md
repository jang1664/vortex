# Read-only board preflight

Revalidated 2026-09-08 22:28 KST with the same single-task allocation and
read-only command. New reports: `build_hbm_reference/board_readonly_20260908_2228.{json,log}`.
Device remains HEALTHY and MIG calibrated; loaded UUID is now
`f02148a2-349e-c58b-cfad-32a5d7115c14`, still not the candidate. No xclbin was
loaded or altered by this query. The allocation ended; this is not a reservation.
Candidate runtime-clock verification remains pending.

Observed 2026-09-08 14:59 Asia/Seoul. No xclbin was loaded, reset or changed.
An immediate, single-task Slurm FPGA allocation was used for device inspection:

```sh
srun --ntasks=1 --immediate=10 --gres=fpga:u55c:1 \
  --cpus-per-task=1 --mem=1G --time=00:02:00 \
  /opt/xilinx/xrt/bin/xrt-smi examine --device 0000:2a:00.1 \
  --report platform dynamic-regions memory --format JSON \
  --output /home/jaeyongjang/project.local/vortex_base/build_hbm_reference/board_readonly_20260908_1459.json
```

The command exited zero. Human-readable output is saved in
`build_hbm_reference/board_readonly_20260908_1459.log`. Results are observations
of the loaded image at that instant, not a reservation or guarantee of the
device's state during a later job.

| Item | Observation |
| --- | --- |
| BDF | 0000:2a:00.1 |
| Platform VBNV | xilinx_u55c_gen3x16_xdma_base_3 |
| Device status | HEALTHY |
| MIG calibrated | true |
| Loaded xclbin UUID | 66d7a49f-7959-3676-ea7c-dd25813f9ef3 |
| Candidate `temp` xclbin UUID | 04277889-d0a3-bd1d-c32e-72ef96e153c3 |
| Current DATA_CLK | 100 MHz |
| Current KERNEL_CLK | 500 MHz |
| Current hbm_aclk | 450 MHz |
| Current compute unit | vortex_afu:vortex_afu_1, IDLE |

The loaded UUID is **not** the candidate UUID. Consequently these clocks do
not establish the candidate's runtime clock gate. Do not infer the Vortex
`ap_clk` from the human-readable name KERNEL_CLK alone; verify the actual
clock connection for the selected xclbin. The candidate metadata records the
requested/achieved `ulp_ucs_aclk_kernel_00` frequency as 100 MHz.

The report also shows satellite controller version 7.1.17 versus expected
7.1.23. Record this environment difference; do not update firmware as part of
calibration without separate user direction. This preflight does not establish
whether the version difference affects this workload.

The first help query without `--ntasks=1` launched two tasks under inherited
Slurm defaults. Enumeration also reported an inaccessible second device and
required an explicit BDF. Repeating with one task and the listed allocated BDF
succeeded. Keep future inspections within allocated devices; do not attempt to
access devices denied by the allocation.

For the eventual hardware workload, use the mandated `ci/run_black.sh hw`
path and verified alias. Record the loaded UUID and effective clocks during
that allocation after runtime load, then match VCS clocks. Hardware workload
execution, repeatability and error comparisons remain outstanding.

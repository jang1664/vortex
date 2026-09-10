# MXU16 all-BRAM source PnR

Completed: **100MHz timing PASS**, final WNS +0.003ns, routing errors0.
See [results.md](results.md). Monitoring ended on 2026-09-10.

User requested MXU16 with 4 HBM ports, 4 DMA channels and 8 TMEM arrays,
using BRAM for all previously URAM-backed SRAMs.

Config: `configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh`.
It sources the existing TH16/MXU16/t8 config and selects TMEM, ACC and local
memory BRAM explicitly. Geometry remains WLOAD=4, eight 32B-wide 64KiB TMEM
arrays (512KiB total), four 64B HBM/DMA channels and 1MiB local memory.
Small FF/LUTRAM queues and platform-internal IP are unchanged.

Use the recent all-BRAM experiment's full-SLR pipeline/floorplan, 100MHz target,
SSI_SpreadSLLs placement, AlternateCLBRouting, no ultrathreads and no congestion
early-fail gate. SLR validation hooks remain enabled. No RTL changes or DCP retry.

```bash
python3 agent-tasks/u55c-slr-floorplan-pipeline/timing-cuts-pnr/run.py \
  --config configs/improve_th16_tcol16_m16_t8_bigmem_all_bram.sh \
  --postfix spread_v1 --monitor-interval 1800
```

The runner sources the config before configure and records source hashes.
It refuses existing build/evidence directories. Monitoring interval is metadata;
the assistant schedules actual 30-minute checks through `status.py`.

Historical MXU16/t8 simulation passed seven cases before this all-BRAM profile
was added (see `agent-tasks/m16-timing-config-validation/results.md`). The memory
selection RTL was tested in the MXU32 all-BRAM task. This request launches physical
verification without claiming a fresh exact-profile xrt-vcs-sim pass.

At completion, check route status, 10ns setup/hold slack, achieved kernel-00
frequency, actual memory mapping, per-SLR utilization and SLR hook results.

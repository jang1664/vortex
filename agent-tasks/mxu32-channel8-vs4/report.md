# MXU32: eight channels versus four channels

## Conditions

Both profiles use MXU32x32, thread16, C2 timing cuts and 512 KiB total TMEM.
This comparison changes HBM ports, DMA channels and TMEM banks together,
as requested. Both use direct one-channel/one-bank routing, not the
previous DMA4/TMEM8 address-selected bank route.

| Parameter | Eight-channel profile | Four-channel profile |
| --- | ---: | ---: |
| NUM_HBM_PORTS | 8 | 4 |
| NUM_DMA_CHANNELS | 8 | 4 |
| NUM_TMEM_BANKS | 8 | 4 |
| TMEM_BANK_SIZE | 64 KiB | 128 KiB |
| TMEM physical word | 64 B | 64 B |
| Words per bank | 1024 | 2048 |
| Total TMEM | 512 KiB | 512 KiB |
| Physical platform HBM pseudo-channels | 32 | 32 |

Configs added (existing configs preserved):

- `configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm8_tmem8.sh`
- `configs/improve_th16_tcol32_m32_hwexp_dcache_sxbar_f16_bigmem_hbm4_tmem4.sh`

Only the four configuration parameters at the top of the table differ;
all other defines match. No additional RTL/runtime/kernel edits were needed
in this task. The current worktree includes the previous task's uncommitted
TMEM routing/depth support; both builds capture the same 369-file source
snapshot rather than relying solely on HEAD.

## Verification and measurement

Both direct-path bank tests passed in fresh configured builds through
`tools/verify_rtl.py`, with no mixed-case Error/Fatal messages. The four-bank
test includes retaining distinct payloads at rows1023 and2047 to detect
truncation of the added row-address bit, as well as late write-ACK filtering.

Performance runs use fresh simulators and source each config before building:

```sh
./ci/run_black.sh xrt-vcs-sim --perf 3 --app fpint_gemm_ffn_hw \
  --args "-m M -k 256 -n 256 -q 32 -d 0 -t 0 -r 1"
```

M=1,4,256, three independent launches per shape/profile. The metric is
GEMM-node `total_cycles` on `PERF: jobs=... total_cycles=... busy_cycles=...`,
not CPU cycles or host time. Performance runs omit `--debug`; both retain
C2 cuts. The strict parser is reused from the preceding comparison and
rejects nonfatal VCS `Error:` messages even when the application prints PASSED.

Exact defines, source/config hashes and build roots are in `ch8/manifest.json`
and `ch4/manifest.json`. Per-case logs/counters are preserved under `ch*/m*_r*/`.
Simulator/kernel identities and source integrity are checked across runs.

## Results

Completed 2026-09-06 at 17:21 KST. Both unit profiles and all18 blackbox
launches PASS with no detected simulator errors. Source/config integrity
and per-profile simulator/kernel identities remained unchanged. Both profiles
used the same kernel binary and matching job counts for each M.

The following values are GEMM-node `total_cycles` medians of three launches.
Positive percentage means more cycles with four channels.

| M | Eight channels | Four channels | Extra cycles | Four-channel cycle increase |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 756 | 816 | 60 | +7.94% |
| 4 | 784 | 824 | 40 | +5.10% |
| 256 | 17,783 | 18,077 | 294 | +1.65% |

| M | Eight-channel raw repeats | Eight-channel range | Four-channel raw repeats | Four-channel range |
| ---: | --- | --- | --- | --- |
| 1 | 756,755,756 | 755-756 | 816,816,816 | 816-816 |
| 4 | 784,784,785 | 784-785 | 824,824,824 | 824-824 |
| 256 | 17786,17783,17779 | 17779-17786 | 18077,18077,18077 | 18077-18077 |

For these K=N256 shapes, halving the complete channel/bank organization at
constant TMEM capacity increases cycles by approximately1.65-7.94%. The
relative cycle penalty is smallest for M256. The repeated-run ranges are
smaller than the differences between configurations.

Evidence: [comparison.json](comparison.json), [eight-channel runs](ch8/results.json),
[four-channel runs](ch4/results.json), and `runner.log`. Exact commands and
wrapper/simulator logs are preserved per case.

This is a whole eight-channel versus four-channel configuration comparison,
not an isolation of DMA, HBM-port or bank-arbitration effects. Results do not
establish post-route Fmax, area, power or board performance. No PnR/hardware
run or commit was performed.

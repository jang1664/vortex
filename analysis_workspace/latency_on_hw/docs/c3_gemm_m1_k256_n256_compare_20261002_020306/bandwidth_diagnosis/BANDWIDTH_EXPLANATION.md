# Why two DMA D-cache ports do not improve this M=1 GEMM

For M=1, K=N=256, WTRANS=0 and QDIR=0, the dominant weight DMA descriptor reads **64-byte segments at 128-byte source strides**. The two-port DMA has a 128-byte aggregate bus, but only one of its two 64-byte cache lanes is active for each weight segment. It does not fetch both N tiles together. Reducing D-cache banks from four to two also concentrates each tile's weight requests into one bank.

Two separately configured control runs were executed sequentially in the same repository `build/` using `ci/run_black.sh xrt-vcs-sim`. Each changes one define from the frozen v2 config; response reordering remains enabled in both. No functional RTL or source config was edited.

## Measured controls

| Config | D-cache banks | DMA D-cache ports | Core cycles | Instructions | Check |
|---|---:|---:|---:|---:|---|
| Original | 4 | 1 | 9,806 | 6,563 | PASS |
| v2 | 2 | 2 | 10,321 | 6,605 | PASS |
| v2: DMA ports only 2 -> 1 | 2 | 1 | 10,248 | 6,599 | PASS |
| v2: D-cache banks only 2 -> 4 | 4 | 2 | 9,884 | 6,569 | PASS |

With all other v2 settings held fixed:

- Reducing DMA ports from two to one saves **73 cycles**, 10,321 -> 10,248.
- Restoring four D-cache banks saves **437 cycles**, 10,321 -> 9,884.
- Original versus v2 differs by **515 cycles**. Restoring banks recovers about **84.9%** of that observed penalty. The four-bank/two-port control still costs 78 cycles more than the original config.

The single-define control effects are not an additive decomposition: they share the same baseline and the combined change was not measured. The residual includes other config changes and their interactions. All four runs pass the host numerical reference, use the same 100 MHz model logic frequency, and have identical kernel SHA-256. These are full-kernel core cycles from one cold launch per variant; instruction count changes include completion polling.

## Effective weight width

The physical widths are set by `hw/rtl/core/VX_core.sv:133` and `hw/rtl/core/VX_dma_node.sv:42`:

```text
DMA aggregate bytes = DMA_DCACHE_PORTS * DCACHE_WORD_SIZE
                    = 1 * 64 = 64 bytes (original)
                    = 2 * 64 = 128 bytes (v2)
```

This is a port-width ceiling. Accepted requests, active lane masks, cache hits/misses, memory-system backpressure and segment layout determine useful bytes per cycle.

`hw/rtl/core/gemm/VX_naive_external_dma_executor.sv:311` constructs the WTRANS=0 descriptor:

```text
NT = 128                       # GEMM DMA tile width
N_orig = 256
seg_size = NT / 2 = 64 bytes    # packed INT4, one tile row
src_stride = N_orig / 2 = 128 bytes
row_count = KT = 128
```

Because source stride is 128 rather than 64 bytes, the contiguous-row coalescing condition at line 429 is false. Each row remains a separate segment; the other 64 bytes of that 128-byte DRAM row belong to the adjacent N tile.

`VX_mem_bus_split` uses byte enables to determine active lanes (`hw/rtl/mem/VX_mem_bus_split.sv:79`), so the second half of the 128-byte bus is inactive for that descriptor. Successive rows do not become a single two-lane request. The weight tile is 8 KiB: 128 segments × 64 bytes. There are four K/N tiles for this shape, totaling 32 KiB of weight payload, so the weight traffic is substantial despite M=1.

Input, scales, zero points and output have different segment widths; some can use both DMA lanes. This report does not claim every transfer is limited to one lane.

## Cache bank concentration

`hw/rtl/cache/VX_cache.sv:304` selects the bank from low cache-line address bits. With 64-byte cache lines:

```text
bank = (byte_address >> 6) & (bank_count - 1)
```

The recorded weight base is `0x11000`. The first N tile reads these rows:

| Byte address | 2-bank selection | 4-bank selection | Active 128-byte DMA half |
|---|---:|---:|---:|
| 0x11000 | 0 | 0 | 0 |
| 0x11080 | 0 | 2 | 0 |
| 0x11100 | 0 | 0 | 0 |
| 0x11180 | 0 | 2 | 0 |

The second N tile starts 64 bytes later: its two-bank requests all use bank 1, whereas four banks alternate banks 1 and 3. Thus two DMA ports do not spread one descriptor's weight requests over both banks. Four banks distribute those requests across two bank pipelines and their per-bank MSHR capacity (the default `DCACHE_MSHR_SIZE` is 16 per bank).

The address mapping and controlled bank-count measurement support bank concentration as the larger cause here. Detailed bank-stall/MSHR occupancy counters were not captured, so the 437-cycle improvement is not decomposed into individual cache stalls.

## Added transport cost

With two DMA ports, `VX_mem_unit.sv:470` selects the splitter rather than the direct one-port connection. The splitter has registered lane request buffers and the enabled response reorder store. It also inserts buffered CPU/DMA arbitration on CPU cache lane 1 (`VX_mem_unit.sv:491`). These extra paths exist even when only one DMA lane has payload.

The measured two-to-one-port control saves 73 cycles. That measurement changes width, splitting, response reassembly and the second CPU lane's arbitration together; it does not isolate their individual contributions.

## Artifacts and scope

- `config_dma1.sh` / `config_bank4.sh` and their `.diff` files record the single define changes.
- `results.json`, per-case `result.json`, `command.sh`, configs, compiler/simulator logs and model manifests retain the evidence.
- `experiment.json` and `run_compare.py` reproduce these controls in `build/`.
- The final build simulator corresponds to the last diagnostic, v2 with four D-cache banks. Source configs remain unchanged.

A four-bank/two-port config is faster than v2 for this measured shape, but changing DMA port count alone does not recover the original result. Cache geometry and descriptor access layout need to be considered alongside aggregate port width.

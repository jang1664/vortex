# GEMM_IMPROVE MXU 16x16 Support Plan

## 1. Objective

Add a compile-time `MXU_ROW=16`, `MXU_COL=16` profile while preserving the
existing 32x32 profile. The executable acceptance gate is a five-case
functional matrix using:

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "..."
```

run from a build directory configured with the new 16x16 profile. The same
compiled image must pass five selected M/N/K shapes covering logical tails,
both weight orientations, both quantization directions, multiple MXU tiles,
and an outer-tile boundary. Performance measurement and optimization are a
separate follow-up activity.

This is a correctness-first plan with the final MXU16 memory organization
included from the start. The HBM DMA and AXI beat remain 64 bytes. The MXU16
profile instead uses 32-byte physical TMEM banks and 32-byte logical I/W/S/Z/O
local-DMA beats. Each 64-byte HBM-DMA access is split across, or joined from,
two consecutive 32-byte TMEM banks in parallel. The legacy MXU32 profile keeps
its existing 64-byte TMEM-bank organization.

## 2. Scope and milestones

### Milestone A: MXU16 xrt-vcs-sim functional acceptance

- make `MXU_ROW` and `MXU_COL` configuration overrides effective;
- add a sibling 16x16 configuration;
- make the IMPROVE TMEM local paths and physical banks 32 bytes wide;
- keep the HBM DMA 64 bytes wide and map each channel to a consecutive pair of
  32-byte banks without serializing the two halves;
- preserve the MXU-dependent tile-major layout in the active host test and
  RTL FSM;
- ensure every external HBM DMA command is a whole number of 64-byte blocks;
- pass the five-case `fpint_gemm_ffn_hw` xrt-vcs-sim functional matrix in
  Phase 6 with numerical verification enabled.

### Milestone B: compatibility and extended correctness coverage

- rerun a representative functional subset on the 32x32 profile to prove
  compatibility;
- add randomized and longer stress coverage after the five-case MXU16 gate is
  stable;
- keep synthesis, timing, and application performance validation separate
  from functional correctness.

### Milestone C: keep secondary software models and kernels consistent

- remove hard-coded 32x32 dimensions from the simx GEMM model;
- generalize or explicitly deprecate the legacy `kernel/src/fi_gemm.c` path;
- validate XRT upload/download interleaving without changing its 64-byte
  physical block contract.

Hardware synthesis, timing closure, cycle-count comparison, and throughput
benchmarking are follow-up gates after RTL simulation correctness. They are not
required for Milestone A.

## 3. Source-derived current behavior

### 3.1 Configuration

`configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh` sets
`NUM_THREADS=16` and `MXU_COL_TILE=32`, but does not set the MXU dimensions.
The `th16` portion of the name is the thread count, not the MXU row count.

`hw/rtl/VX_config.vh` currently defines `MXU_ROW=32` and `MXU_COL=32`
unconditionally. Therefore command-line definitions cannot cleanly select a
16x16 profile, and the generated `build/hw/VX_config.h` also exposes the 32x32
values to host and kernel compilation.

For the default `MXU_WLOAD_NUM=4`, the important widths are:

| Quantity | Formula in bytes | MXU 32x32 | MXU 16x16 |
| --- | ---: | ---: | ---: |
| Input beat | `2 * MXU_ROW` | 64 | 32 |
| Weight beat | `MXU_COL * MXU_WLOAD_NUM * 4 / 8` | 64 | 32 |
| Scale/ZP beat | `2 * MXU_COL` | 64 | 32 |
| Output beat | `2 * MXU_COL` | 64 | 32 |
| Partial-sum beat | `4 * MXU_COL` | 128 | 64 |
| Complete packed weight micro-tile | `MXU_ROW * MXU_COL / 2` | 512 | 128 |
| Weight beats per command | `MXU_ROW / MXU_WLOAD_NUM` | 8 | 4 |

The existing `MXU_COL_TILE=32` is invalid for a 16-column MXU. The new profile
must use `MXU_COL_TILE=16`. With the current pipeline settings this is expected
to retain `MXU_OUT_DLY=5`, but elaboration and the compute-unit tests must prove
that rather than relying on the arithmetic informally.

### 3.2 Active layout and command ownership

The active regression is `tests/regression/fpint_gemm_ffn_hw/`. Its device
kernel only allocates/programs a GEMM job descriptor and waits for completion.
The host owns DRAM packing and scratch allocation; `VX_gemm_fsm.sv` owns all
per-tile and per-micro-tile addresses and command sizes.

The active tile-major layouts are already mostly expressed through
`GEMM_MXU_KT=MXU_ROW` and `GEMM_MXU_NT=MXU_COL`:

- Input: `[mt][kt][kb][m][MXU_KT]` FP16. Each `(mt,kt)` slot reserves
  `align_up(cur_m, 8) * cur_k * 2` bytes.
- Weight, `WTRANS=0`:
  `[kt][nt_mxu][kb][MXU_KT][MXU_NT/2]` packed INT4 bytes.
- Weight, `WTRANS=1`:
  `[kt][nt_mxu][kb][MXU_NT][MXU_KT/2]` packed INT4 bytes.
- QCOL scale/ZP: one 512-byte-aligned `(kt,nt_dma)` slot whose body is
  `[nb][groups_per_kt][MXU_NT]` FP16/INT16.
- QROW scale/ZP: one 512-byte-aligned `(kt,nt_dma)` slot whose body is
  `[nb][kt_element][ceil(MXU_NT/QBLK)]` FP16/INT16.
- Output: `[mt][nt_mxu][m][MXU_NT]` FP16. Each N micro-tile reserves
  `align_up(cur_m, 8) * MXU_NT * 2` bytes.

The formulas are parameterized, but several comments still call the internal
TMEM representation row-major or explicitly say 32-wide. Those comments must
be corrected alongside the code so the layout ABI is not re-hardened later.

There is one functional tail bug that becomes visible with MXU16. QCOL slot
sizing and filling use `cur_k / QBLK`, while the FSM issues
`ceil(cur_k / QBLK)` groups. With `cur_k=16` and `QBLK=32`, software reserves
and fills zero groups while RTL consumes one. Host and RTL slot geometry must
both use ceiling division for the last K tile.

### 3.3 TMEM local width coupling

`VX_gemm_node.sv` exposes stream-specific widths at its GEMM interfaces, but
instantiates `VX_tmem_subsystem` with a common `GEMM_DATA_SIZE=MEM_BLOCK_SIZE`.
Inside `VX_tmem_subsystem.sv`:

- input, scale, zero-point, and output local buses are fixed at 64 bytes;
- their read reservations and `VX_tmem_switch` instances are fixed at 64
  bytes;
- the input and qparam overlap DMA engines require source and destination beat
  widths to be equal;
- the weight path uses `VX_tmem_wide_read_switch`, which requires the logical
  weight beat to be at least one 64-byte bank word.

The 16x16 profile therefore fails structurally even though the GEMM unit ports
themselves are macro-sized. A 32-byte scale or input address would also alias
if it were shifted as a 64-byte word address.

The existing physical topology is eight 64-byte banks, one per HBM-DMA
channel. For MXU16, simply changing those eight banks to 32 bytes would force
one 64-byte HBM beat to use the same single-port bank for two cycles. The
target topology therefore uses sixteen 32-byte banks. HBM-DMA channel `c` owns
the consecutive pair `2*c` and `2*c+1`, while a local 32-byte address naturally
selects one of the sixteen banks.

`VX_mem_bus_split.sv` is currently used by the general DMA to scatter an
aggregate LMEM or D-cache beat over physical lanes, and by the NAIVE GEMM node
for wide Input/SZ/Output and write paths. It is not currently used by the
IMPROVE TMEM subsystem. It is an ordered lane splitter/joiner, not a tagged
out-of-order reorder buffer: it queues responses independently per lane and
zips the FIFO heads. The NAIVE PSUM read path uses the separate
`VX_gemm_psum_read_ooo_join` when responses from different physical bank sets
can cross request order.

The generic splitter is larger than necessary for one fixed TMEM bank pair. It
instantiates a two-entry request skid and an eight-entry response skid for
every lane, and its optional lane-mask mode adds an eight-entry context FIFO.
It also reports aggregate request acceptance when both lane requests enter the
skids, before both requests necessarily reach the physical banks. That
completion boundary is undesirable for HBM-to-TMEM writes because the GEMM FSM
may start a local read after DMA completion. Use its handshake pattern as a
reference, but implement a dedicated two-bank adapter whose aggregate write is
accepted only after both physical banks have accepted their halves.

### 3.4 External HBM DMA granularity

`VX_gemm_tmem_dma_ctrl.sv` treats every logical DMA command as a sequence of
64-byte words:

```text
decode_num_words = decode_seg_size >> log2(MEM_BLOCK_SIZE)
```

It discards any byte remainder. Each per-channel descriptor always programs a
64-byte segment. This behavior is safe only when the command size is a
multiple of 64; the current controller does not reject a bad size.

For the first 16x16 implementation, do not add a byte-partial HBM protocol.
Instead define:

```text
hbm_transfer_bytes = align_up(logical_payload_bytes, 64)
```

and issue that value only for `OP_DMA_LD` and `OP_DMA_ST`. Local MXU DMA
commands retain their exact 32-byte logical beat sizes.

The existing layout already reserves enough tail space:

- input and output use an 8-row slot; with a 16-element FP16 vector, each row
  is 32 bytes and the slot is at least the next 64-byte boundary;
- scale and zero-point reserve a 512-byte-aligned slot;
- a 16x16 packed weight micro-tile is 128 bytes and needs no extra rounding.

All host buffers are zero-initialized before logical data is written. Input and
qparam rounded load bytes are therefore deterministic. An output store may
write unspecified TMEM padding into the reserved padded row area, but it must
never cross the output slot boundary and verification must continue to ignore
padded rows/columns. If deterministic output padding later becomes an ABI
requirement, add an explicit zero-fill rather than relying on stale TMEM data.

The existing channel-slot assertion also remains required:
`src[8:6] == dst[8:6]` for eight channels and 64-byte blocks. On the TMEM side,
`dst[5]` selects the low/high bank within the channel pair. The layout tests
must prove this for every external tile, not only for the base allocation.

### 3.5 Runtime and secondary paths

`runtime/xrt/vortex.cpp` maps host transfers using the 64-byte cache/HBM block
and already aligns allocation/transfer fragments at that physical granularity.
MXU vector width is not part of this runtime mapping. No XRT functional change
is expected for Milestone A; changing XRT interleaving to 32 bytes would be
incorrect.

`sim/simx/gemm_node.h` hard-codes `MXU_KT=32` and `MXU_NT=32`. Its address
formulas otherwise use those constants and can be made profile-driven.
`kernel/src/fi_gemm.c` is a legacy command-stream path with separate 32x32
constants and assumptions. Neither file is on the first xrt-vcs-sim RTL
arithmetic path, but both must be handled before claiming repository-wide
16x16 support.

## 4. Target contracts

### 4.1 Configuration contract

1. `MXU_ROW` and `MXU_COL` are guarded defaults in `VX_config.vh`.
2. Keep the existing 32x32 config behavior and make its dimensions explicit.
3. Add
   `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh` with:

   ```text
   MXU_ROW=16
   MXU_COL=16
   MXU_COL_TILE=16
   MXU_WLOAD_NUM=4
   NUM_TMEM_BANKS=16
   TMEM_BANK_SIZE=32768
   ```

4. Keep runtime DMA tiles at `MT=NT=KT=128` for the first milestone. They are
   distinct from the MXU micro-tile.
5. Add compile-time checks that runtime DMA KT/NT are divisible by MXU KT/NT,
   widths are integral bytes, and every supported local width ratio to the
   physical TMEM-bank width is an integer power of two.
6. Preserve total TMEM capacity across profiles: MXU32 uses
   `8 * 65536 bytes`, while MXU16 uses `16 * 32768 bytes`. Both organizations
   retain 1024 words per physical bank.

### 4.2 Layout contract

Create one documented set of pure size/offset helpers, mirrored exactly
between the active host/benchmark and `VX_gemm_fsm.sv`. At minimum, freeze and
test these values:

```text
mxu_k_bytes       = MXU_KT * 2
mxu_n_bytes       = MXU_NT * 2
weight_micro_bytes= MXU_KT * MXU_NT / 2
groups_per_kt     = ceil(cur_k / QBLK)          # QCOL tail included
ng_per_mxu_nt     = ceil(MXU_NT / QBLK)         # QROW duplicate footprint
hbm_xfer_bytes    = align_up(payload_bytes, 64)
```

Keep `N_logical/K_logical` separate from the MXU-aligned execution values used
in the job descriptor. Padded A/W/qparams remain neutral and padded output is
never verified or exposed as logical output.

Every helper must use checked 64-bit products for host allocation and address
calculation before narrowing into 32-bit command fields.

### 4.3 TMEM bank and DMA-width contract

Decouple the physical TMEM-bank width from the HBM-DMA width:

```text
MXU16 local DMA:                 1 x 32B
physical TMEM organization:    16 x 32B banks
HBM-DMA TMEM side per channel:  2 x 32B bank lanes
HBM-DMA core and AXI side:       1 x 64B
```

The HBM DMA remains a 64-byte transaction engine. Do not convert its
descriptor traversal, response slots, burst counts, or AXI data path to 32
bytes. Instead, split each 64-byte TMEM-side request into two 32-byte bank
requests and join the two responses for a TMEM-to-HBM read. Track two request
acceptance bits so one accepted half is not replayed while the other bank is
stalled. Do not place a second deep request queue at this boundary.

For eight HBM-DMA channels and sixteen MXU16 banks, freeze this mapping:

```text
channel      = byte_addr[8:6]
pair_half    = byte_addr[5]
physical_bank= {channel, pair_half} = 2 * channel + pair_half
bank_line    = byte_addr >> 9
```

Thus channel `c` owns consecutive banks `2*c` and `2*c+1`. A 64-byte DMA
request accesses both banks at the same `bank_line`; a 32-byte local-DMA
request accesses exactly one. The ordinary 16-bank, 32-byte `VX_tmem_switch`
bank selection also resolves to `byte_addr[8:5]`, so local and HBM-DMA paths
share one physical mapping.

Add a small `VX_tmem_dma_pair_adapter` specialized for two fixed physical
banks. Drive each bank's local address directly from the 64-byte DMA word
address; do not append a lane-select bit because the output port already
selects the bank. The request path contains only per-half accepted state and an
optional timing register justified by timing results. Aggregate `req_ready`
means both physical bank requests have fired, not merely that they were
queued.

The response path needs a skew join, not an associative reorder buffer. Each
physical TMEM bank is single-port, produces responses in accepted-request
order, and a new aggregate request is not admitted until both halves of the
previous request have been accepted. Therefore the two lane streams have the
same transaction order even when their response cycles differ. Use a shallow
elastic FIFO per half, join only the two FIFO heads, return the original DMA
tag, and assert that both head tags match. Start with depth two; increase it
only if measured bank-contention skew justifies the area.

External GEMM DMA commands are 64-byte integral, so both 32-byte banks are
always active. Do not enable lane-mask tracking or partial-pair context storage
on this path. Bank byte enables are the fixed low/high halves of the 64-byte
request. Rounded logical tails are transferred as ordinary full 64-byte beats.

Give the subsystem separate parameters for `HBM_DMA_DATA_SIZE=64` and physical
`DATA_SIZE`, which is 32 for MXU16 and remains 64 for the legacy MXU32 profile.
Give input, weight, scale/zero-point, and output named local buses at their
logical widths where the current uniform interface arrays prevent different
elaboration-time widths.

For MXU16, all I/W/S/Z/O local-DMA source and destination interfaces are 32
bytes and match the physical bank width. No 32-to-64 local adapter is present.
For the existing MXU32 profile, keep the current eight 64-byte banks and its
existing equal/wide weight routing. Partial sum remains a separate 64-byte
MXU16 accumulator path and does not change the I/W/S/Z/O TMEM contract.

### 4.4 Response-ordering contract

Use reorder state only where responses can cross logical request order:

- HBM AXI reads use one ID per DMA channel and retain the existing FIFO tag
  association. Do not add an AXI reorder buffer.
- The two fixed TMEM banks owned by one HBM-DMA channel preserve order within
  each lane. The pair adapter only absorbs latency skew and zips matching FIFO
  heads. Do not add tag-indexed response slots there.
- Input, Weight, Scale, and Zero local DMA reads can target different banks
  through `VX_tmem_switch`; the switch may return whichever bank responds
  first. Retain their existing tag-indexed response slots and ordered logical
  drain.
- Output local DMA writes do not consume TMEM read data. Drain write
  acknowledgements without adding data-reorder storage.
- Any future wide local read that can have requests outstanding across
  different bank sets must use a tagged OOO join like the NAIVE PSUM path,
  rather than the ordered `VX_mem_bus_split` head zip.

## 5. Implementation phases

### Phase 0: freeze the 32x32 baseline

1. Use a dedicated configured 32x32 build directory so generated files and
   VCS artifacts cannot be reused by the 16x16 build.
2. Record preprocessor values for all widths in the table above.
3. Run the default active blackbox once and retain its pass log and command.
4. Record representative FSM command/address traces for one QCOL and one QROW
   case. These are the compatibility oracle, not cycle-count acceptance gates.

### Phase 1: configuration and generated-header propagation

Files:

- `hw/rtl/VX_config.vh`
- `configs/improve_th16_tcol32_hwexp_dcache_sxbar_f16_bigmem.sh`
- new `configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh`

Actions:

1. Guard the MXU row/column defaults with `ifndef`.
2. Make both profile files state row, column, column tile, and weight-load
   count explicitly. Make the MXU16 profile also state sixteen TMEM banks and
   a 32 KiB per-bank size; keep the MXU32 profile at eight 64 KiB banks.
3. Confirm configure regenerates `build/hw/VX_config.h` with 16, 16, and 16
   for the new profile.
4. Add static checks for square 16/32 support initially. Rectangular MXUs are
   not implied by this work.
5. Compile/elaborate the compute unit before changing data movement. Resolve
   any accumulator address or latency expression that still assumes 32.

### Phase 2: freeze and correct the tile-major layout

Files:

- `tests/regression/fpint_gemm_ffn_hw/common.h`
- `tests/regression/fpint_gemm_ffn_hw/main.cpp`
- `tests/regression/fpint_gemm_ffn_hw/bench_main.cpp`
- `tests/regression/tile_input_a/`
- `tests/regression/tile_weight_w4a16/`
- `tests/regression/tile_scale_zp_w4a16/`
- `tests/regression/detile_output/`
- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/unittest/gemm_fsm/`

Actions:

1. Keep all micro-tile dimensions sourced from `MXU_ROW/COL`; remove stale
   32-specific comments and debug arithmetic.
2. Change QCOL last-tile group sizing/filling from floor division to ceiling
   division in both host entry points, the standalone scale/ZP layout kernel,
   and the RTL `scale_slot_bytes` helper.
3. Factor or share pure host layout helpers between `main.cpp` and
   `bench_main.cpp` so functional and benchmark packing cannot diverge.
4. Add checked helpers for payload bytes, reserved slot bytes, and 64-byte HBM
   transfer bytes. Assert `transfer <= reserved` at every call site.
5. Preserve the existing layout ordering. Do not introduce a second 16x16-only
   layout ABI.
6. Extend the FSM unit test to compare every emitted external and local
   command address/size against an independent software calculation for both
   profiles.
7. Run the standalone input/weight/scale-ZP tilers and output detiler as layout
   producer/consumer contract tests at MXU16. Audit fused layout producers such
   as `rms_norm_layout_fused` and `silu_layout_fused` before declaring the
   kernel-side layout ecosystem complete.

### Phase 3: add 32-byte TMEM banks with paired 64-byte HBM-DMA access

Files:

- `hw/rtl/mem/VX_tmem_subsystem.sv`
- `hw/rtl/mem/VX_tmem_switch.sv`
- new `hw/rtl/mem/VX_tmem_dma_pair_adapter.sv`
- `hw/rtl/mem/VX_mem_bus_split.sv` as a behavior reference only
- `hw/rtl/mem/VX_tensor_mem_bank.sv`
- `hw/rtl/core/gemm/VX_lmem_dma_misal.sv`
- `hw/rtl/core/gemm/VX_gemm_node.sv`
- new or extended TMEM subsystem, switch, and split/join unit tests under
  `hw/unittest/`

Actions:

1. Replace the implicit common `DATA_SIZE=MEM_BLOCK_SIZE` contract with
   separate physical-bank and HBM-DMA widths. Keep `VX_dma_engine` and its
   `dma_to_tmem` aggregate interfaces at 64 bytes.
2. Instantiate sixteen 32-byte physical banks for MXU16. Preserve total
   capacity by using 32 KiB per bank; keep the legacy eight-by-64-byte generate
   branch for MXU32.
3. For every HBM-DMA channel, split one 64-byte request into two parallel
   32-byte requests and connect them to physical banks `2*c` and `2*c+1`.
   Join both responses before returning a read response to the DMA engine.
4. Drive both physical SRAM addresses directly with aggregate DMA word `w`.
   Do not generate and then strip a lane-select address bit.
5. Implement the write request path with two accepted bits and no deep skid
   queues. Assert aggregate acceptance only after both bank-port handshakes.
6. Implement the read/ack response path with two shallow ordered FIFOs and a
   matching-head join. Assert head-tag equality and do not add associative
   reorder slots or lane-mask context storage.
7. Preserve lane-specific byte enables while requiring both lanes active for
   every accepted external GEMM DMA command.
8. Instantiate 32-byte local-DMA, reservation, and switch buses for MXU16
   I/W/S/Z/O. Update every local address-width parameter to shift by five.
9. Use the normal 16-bank switch for MXU16 weight because its logical beat is
   32 bytes. Retain the existing equal/wide weight routing for MXU32 and other
   supported 64/128/256/512-byte configurations.
10. Normalize route tags across the two profile branches. Retain tag-indexed
    reorder only in local-DMA read queues; do not silently truncate tags at
    bank ports.
11. Add compile-time assertions for the supported organizations:
   `HBM_DMA_DATA_SIZE / DATA_SIZE == NUM_BANKS / NUM_DMA_CHANNELS`, with ratios
   one for MXU32 and two for MXU16.

Required 16x16 local command expectations with `MXU_WLOAD_NUM=4`:

| Command | Logical size |
| --- | ---: |
| One input row | 32 B |
| One weight beat | 32 B |
| Complete weight command | 4 beats / 128 B |
| QCOL scale or ZP micro-load, QBLK=32 | 32 B |
| QROW scale or ZP micro-load, QBLK=32 | 32 B |
| One output row | 32 B |

### Phase 4: make external DMA block sizing explicit

Files:

- `hw/rtl/core/gemm/VX_gemm_fsm.sv`
- `hw/rtl/core/gemm/VX_gemm_tmem_dma_ctrl.sv`
- `hw/unittest/gemm_fsm/`
- relevant TMEM DMA controller unit tests

Actions:

1. Round only HBM `DMA_LD/DMA_ST` sizes to 64 bytes. Do not round local
   `I/W/SC/ZP/O` commands.
2. Add a controller assertion that every accepted external command size is
   nonzero and divisible by `MEM_BLOCK_SIZE`; this converts silent truncation
   into an immediate diagnostic.
3. Retain and test the source/destination channel-slot equality assertion.
4. Verify rounded input/qparam loads do not overwrite the next scratch buffer.
5. Verify rounded output stores remain inside their reserved padded slot.
6. Keep per-channel descriptors at 64 bytes; do not change HBM port width or
   runtime bank interleaving.
7. Verify each per-channel TMEM descriptor word reaches both banks in that
   channel's consecutive pair, with the same bank-local line address.

For the smallest useful tail case, `M=1, N=16, K=16, QBLK=32`, expect:

| Buffer | Payload | External transfer | Reserved space |
| --- | ---: | ---: | ---: |
| Input | 32 B | 64 B | 256 B input slot |
| Weight | 128 B | 128 B | 128 B body |
| QCOL scale | 32 B | 64 B | 512 B slot |
| QCOL ZP | 32 B | 64 B | 512 B slot |
| Output micro-tile | 32 B | 64 B | 256 B output slot |

### Phase 5: prepare the integrated xrt-vcs-sim gate

Use a separate configured build directory for the 16x16 profile. Source the
new config before configure and run all targets from that build directory:

```bash
source ../configs/improve_th16_tcol16_hwexp_dcache_sxbar_f16_bigmem.sh
../configure --xlen=64 --tooldir=/opt/vortex --prefix="${HOME}/tools/vortex"
```

VCS `simv` does not reliably track RTL dependencies. Use a fresh 16x16 build
directory or explicitly clean/rebuild `sim/xrtsim_vcs` before accepting a
result. Build the RTL and application once, then use that same generated MXU16
image for all five cases below. A rebuild between cases would weaken the proof
that one configuration supports the complete matrix.

If a case fails, classify the first failure before editing:

- compile/elaboration width or static assertion;
- local DMA descriptor rejected because a 32-byte size reached a stale
  64-byte logical engine;
- HBM-DMA pair split/join, tag, or bank-local-address failure;
- TMEM bank/address aliasing between consecutive 32-byte vectors;
- external DMA size/channel-slot assertion;
- GEMM completion hang;
- numerical mismatch with the first `(m,n,k)` and active QDIR/WTRANS.

### Phase 6: five-case MXU16 functional matrix

Run exactly the following initial acceptance matrix with `QBLK=32` and one
verified repetition per invocation. `QDIR=0` is QCOL, `QDIR=1` is QROW,
`WTRANS=0` is the normal weight layout, and `WTRANS=1` is the transposed weight
layout.

| Case | M | N | K | WTRANS | QDIR | Primary coverage |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 2 | 32 | 128 | 0 | 0 | Existing default, exact N tile, multiple K micro-tiles |
| 2 | 1 | 16 | 16 | 1 | 0 | 32B logical tails, partial QCOL group, transposed weights |
| 3 | 3 | 17 | 17 | 0 | 1 | Odd N/K padding, QROW parameters, normal weights |
| 4 | 31 | 48 | 80 | 1 | 1 | Multiple N/K micro-tiles, QROW, transposed weights |
| 5 | 129 | 129 | 129 | 0 | 0 | M/N/K outer-tile boundaries and final QCOL tail |

Invoke the wrapper once per row so each failure has an unambiguous command and
log:

```bash
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 2 -n 32 -k 128 -q 32 -t 0 -d 0 -r 1"
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 1 -n 16 -k 16 -q 32 -t 1 -d 0 -r 1"
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 3 -n 17 -k 17 -q 32 -t 0 -d 1 -r 1"
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 31 -n 48 -k 80 -q 32 -t 1 -d 1 -r 1"
ci/run_black.sh xrt-vcs-sim --app fpint_gemm_ffn_hw --args "-m 129 -n 129 -k 129 -q 32 -t 0 -d 0 -r 1"
```

Every case must use reference checking: do not pass `-p`, `--bench`, power
options, or any other option that skips numerical verification. A PASS requires
all of the following, not merely a zero wrapper exit status:

- the log identifies `MXU_ROW=16`, `MXU_COL=16`, and `MXU_COL_TILE=16`;
- the application prints the requested logical M/N/K values and the expected
  WTRANS/QDIR values;
- the run completes without an RTL assertion, timeout, or GEMM completion
  hang;
- the application prints `PASSED` after output comparison;
- a separate result table records the command, log path, and PASS/FAIL for all
  five rows.

The four QDIR/WTRANS combinations all appear in the matrix. Cases 2 and 3 are
the focused local-vector and logical-tail checks, while Case 5 proves that the
same image crosses the outer M/N/K tile boundaries.

After the five MXU16 cases pass, rebuild the legacy 32x32 profile in its own
configured build directory and run a representative correctness subset as the
Milestone B compatibility gate. Randomized sweeps and larger stress shapes are
also Milestone B work; they are not allowed to replace any of the five required
MXU16 cases.

Do not set a cycle-count, latency, throughput, or utilization threshold in
this phase. Capture such counters if they are already present in the logs, but
do not use them for PASS/FAIL. Performance benchmarking and optimization get a
separate plan after functional correctness is established.

### Phase 7: simx, legacy kernel, and runtime closure

Files:

- `sim/simx/gemm_node.h`
- `sim/simx/gemm_node.cpp`
- `kernel/src/fi_gemm.c`
- `kernel/include/vx_tvm_gemm.h`
- `runtime/xrt/vortex.cpp`

Actions:

1. Replace simx's 32x32 constants with generated configuration macros and
   update register-buffer sizes/comments. Use it as a differential layout
   oracle only after it matches the RTL profile.
2. Replace legacy kernel constants with `MXU_ROW/COL` and audit every
   instruction size/stride. If that path cannot honor 32-byte logical beats,
   mark it unsupported at compile time instead of silently producing a wrong
   command stream.
3. Confirm `vx_mem_alloc_aligned`, upload, and download handle the exact padded
   host buffer sizes on the 16x16 profile. Retain 64-byte XRT physical bank
   mapping and `BANK_INTERLEAVE` behavior.
4. Add a build/profile identifier or startup diagnostic if mixed 16x16 host,
   kernel, and RTL artifacts are otherwise difficult to detect.

## 6. Unit-test requirements

### Paired-bank split/join and TMEM routing

- one 64B HBM-DMA write scatters its low/high halves to consecutive 32B banks;
- one 64B HBM-DMA read joins responses from both banks in the correct order;
- both halves use the same bank-local line address;
- lane 0 can accept before lane 1, and vice versa, without replay or loss;
- either half of one pair can respond first, but FIFO heads from different
  aggregate requests are never mixed;
- no-stall traffic accepts one 64B aggregate request per cycle;
- DMA completion cannot precede acceptance of both physical bank writes;
- byte enables activate and preserve each 32B lane independently;
- local 32B accesses select exactly one of sixteen banks across bank and
  bank-wrap boundaries;
- DMA channel `c` can access only banks `2*c` and `2*c+1`;
- original tags are restored exactly after the pair join;
- the MXU32 eight-bank 64B path and existing wide-weight tests remain passing.

### FSM/layout

- exact DRAM and TMEM addresses for every I/W/S/Z/O command;
- exact logical local sizes and rounded external sizes;
- no overlap between a rounded transfer and the following slot;
- QCOL `K=16, QBLK=32` emits and stores one group;
- QCOL group reuse across two 16-wide K micro-tiles;
- QROW group behavior across two 16-wide N micro-tiles;
- output detiling ignores N and M padding;
- both weight transpose layouts.

### Compute/accumulator

- 16x16 elaboration with `MXU_COL_TILE=16`;
- weight-load sequence contains four 32-byte beats;
- FP16 input, INT4 weight, scale/ZP preprocessing, accumulation, and FP16
  writeback match the software reference;
- accumulator bank/depth address calculations remain in range for both
  profiles;
- back-to-back jobs do not leak output padding or register-bank contents.

## 7. Acceptance criteria

Milestone A is complete when:

1. the new config generates `MXU_ROW=16`, `MXU_COL=16`, and
   `MXU_COL_TILE=16` in RTL and C/C++ builds;
2. all 16x16 widths elaborate without truncation warnings or width assertions;
3. TMEM tests prove correct 64B-to-two-bank scatter, two-bank-to-64B join,
   bank-local address, byte-enable, data, tag, and independent-backpressure
   behavior;
4. every external DMA command is asserted to be 64-byte integral;
5. all five Phase 6 commands run against the same MXU16 image and print
   `PASSED` after numerical verification;
6. the five-case result table contains the command and retained log path for
   every row, with no RTL assertion, timeout, or completion hang.

Milestone B is complete when the selected 32x32 compatibility cases and the
additional randomized/long-running correctness cases pass. It does not include
performance sign-off.

Repository-wide 16x16 support is complete only after simx and any retained
legacy kernel path either pass their corresponding tests or reject the profile
explicitly.

## 8. Risks and controls

- **Partial pair acceptance:** one 32B bank may accept before its partner.
  Retain a sent bit per lane until the aggregate request completes so an
  accepted half is never replayed.
- **Pair-response mismatch:** the two bank responses may return in different
  cycles. Zip only matching FIFO heads, assert equal tags, and test both
  half-arrival orders under backpressure. Do not pay for associative reorder
  unless a future bank fabric can reorder within one lane.
- **Early DMA completion:** a generic buffered splitter can acknowledge the
  wide write when both lane skids accept it, before either bank commits it.
  Define aggregate ready at the physical-bank handshakes or explicitly include
  adapter drain in DMA done.
- **Bank-local address error:** a generic splitter appends a lane bit, but an
  already-selected physical bank needs the original 64-byte word address.
  Drive the dedicated pair-adapter lane addresses directly and assert equality.
- **Bank ownership permutation:** the current multi-bank DMA mapping uses
  `c + k*NUM_DMA_CHANNELS`, which produces non-consecutive banks. Change the
  MXU16 pair mapping to `2*c+k` and cross-check it against local switch
  selection `{byte_addr[8:6], byte_addr[5]}`.
- **Address-unit mismatch:** a 32-byte local address shifted by six instead of
  five aliases two vectors. Name HBM-DMA, local-DMA, and physical-bank address
  units separately and assert conversions.
- **Silent HBM truncation:** the current right shift drops a remainder. Add the
  controller assertion before depending on host padding.
- **QCOL partial group loss:** floor division makes K=16 reserve zero groups.
  Use ceiling division consistently in packing, slot sizing, FSM strides, and
  tests.
- **Rounded store data is stale:** padding is not a logical result. Prove the
  rounded store remains inside reserved space; zero it explicitly only if a
  later consumer observes padding.
- **Mixed artifacts:** generated config headers and VCS binaries can remain
  stale. Use separate configured build directories and print the active MXU
  profile in the test log.
- **32x32 regression:** keep a compile-time legacy branch with eight 64-byte
  banks and the current equal/wide weight path; run both profiles.
- **Accidental serialization:** a single 32-byte DMA-to-TMEM port would halve
  peak bulk-transfer bandwidth. Require two independently buffered 32-byte
  bank lanes per HBM channel and add a no-stall throughput test proving one
  completed 64-byte aggregate beat per cycle.
- **Resource regression:** sixteen half-width bank arbiters add control logic
  even though total SRAM bits and aggregate data width are unchanged. Compare
  post-synthesis LUT/FF/URAM use after correctness; do not assume an area win.

## 9. Explicit non-goals for the first milestone

- changing the 64-byte HBM DMA, AXI, or XRT physical-width contract;
- converting the HBM DMA descriptor engine or AXI burst accounting to 32-byte
  beats;
- runtime-selectable MXU size in one bitstream;
- rectangular MXUs;
- new QBLK values beyond the existing QBLK=32 contract;
- redesigning the IMPROVE tile-major layout ordering;
- FPGA place-and-route or timing sign-off;
- cycle-count comparison, latency/throughput benchmarking, utilization
  targets, or performance optimization.

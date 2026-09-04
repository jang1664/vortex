# VX_tmem_dma_pair_adapter

## Purpose

`VX_tmem_dma_pair_adapter` is the fixed 2:1 boundary between one 64B HBM-DMA
TMEM channel and two consecutive 32B physical TMEM banks in the 16x16 MXU
profile. It is deliberately narrower than a generic bus splitter: routing is
known at elaboration time and no associative reorder context is required.

```text
DMA channel c, 64B
          |
          +-- low  32B --> physical bank 2*c
          `-- high 32B --> physical bank 2*c+1
```

Both physical lanes receive the same aggregate bank-local word address. The
lane number selects a physical bank and is not appended to the address.
Request data and byte enables are sliced low/high without modification; flags
and the zero-extended aggregate tag are copied to both lanes.

## Request handshake

The adapter has no deep request skid buffer. When only one bank accepts, a
per-lane sent bit suppresses duplicate issue to that bank while the upstream
request remains valid and stable. Aggregate `req_ready` is asserted only when
both lane handshakes have occurred, including handshakes from earlier cycles.
Thus every accepted 64B request corresponds to exactly one request on each
physical bank.

Simulation assertions check request stability after partial acceptance, equal
lane addresses, and completion only after both physical handshakes.

## Response join

Each lane has a two-entry ordered response FIFO. The aggregate response is
valid only when both FIFO heads exist and their tags match. The low and high
32B data heads are concatenated back into the original 64B order. A retiring
aggregate response frees both FIFO heads together and permits same-cycle lane
refill.

Tag equality is an assertion and a functional join condition. The adapter does
not search for matching tags, reorder responses, or retain request masks.
Ordering is supplied independently by each physical bank port; the shallow
FIFOs only absorb bounded response skew and downstream backpressure.

## Static contract

- `HBM_DMA_DATA_SIZE == 2 * DATA_SIZE`
- `DATA_SIZE` is a positive power of two
- `BANK_TAG_WIDTH >= TAG_WIDTH`
- response FIFO depth is two

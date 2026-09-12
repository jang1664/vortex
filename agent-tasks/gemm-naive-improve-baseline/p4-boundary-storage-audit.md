# Candidate integrated node storage audit

Static XML declaration evidence at th16/MXU16 and th16/MXU32. This is not a
mapped resource report or functional proof. The P0 artifacts remain unchanged.

`p4-boundary-storage-inventory.py` inventories every sequential declaration in
the actual node hierarchy, including interface registers and generated scopes.
The task-local node snapshot substitutes only the exact probe tag-width constant
for an interface-array `$bits` expression unsupported by this XML frontend.
The commit input is tied off for declaration elaboration only. Vendor arithmetic
IP is opaque: 48/96 instances are retained and never counted as spare storage.

## Payload capacity

| Disjoint transport scope | P0 bytes MXU16 / MXU32 | Candidate bytes MXU16 / MXU32 |
|---|---:|---:|
| Input dedicated transport and lane staging | 928 / 1856 | 832 / 1664 |
| Combined S/Z replaced by independent S and Z | 928 / 1856 | 896 / 1792 |
| Weight assembly and response queue | 288 / 1088 | 288 / 1088 |
| ACC LMEM read slots, response hold, final hold | 608 / 1216 | 608 / 1216 |
| PSUM physical join and response FIFO | 448 / 896 | 448 / 896 |
| Final and PSUM write lane staging | 192 / 384 | 192 / 384 |
| Shared ordinary and PSUM lane arbiters | 512 / 1024 | 512 / 1024 |
| Removed legacy local output DMA and read split | 928 / 1856 | 0 / 0 |
| Total within this boundary | 4832 / 10176 | 3776 / 8064 |

The removed local output path is not used to fund another buffer. Every retained
or replaced transport independently stays within its P0 payload budget. Constant
request-data fields and inactive arbiter positions are not available capacity.
These totals exclude architectural compute banks, LMEM allocations, and external
DMA infrastructure; they do not establish a whole-system cost gate.

The retained ACC, PSUM join, write splitters, arbiters, compute and job frontend
have exactly matching sequential object names, modules and widths versus P0 at
both geometries (`p4-boundary-storage-comparison.json`). This proves declaration
capacity preservation, not unchanged behavior. Weight payload objects are counted
individually: assembly, response RAM and its registered output remain 288/1088 B.
Weight metadata, including its adapter, is now 2584/3361 bits.

The integrated Input inventory matches the dedicated Input ledger object for
object after resolving XML generate-scope naming. It retains 16 source slots,
four contexts, and 832/1664 B including per-lane queues and registered copies.
Its other state is 4620/5040 bits.

Each independent S/Z engine retains eight native response slots, four queue
entries per physical lane, and 448/896 B including registered copies. Actual
integration uses one fewer response FIFO tag bit than the standalone probe:
its four/eight lanes each save five control bits (four entries plus head).
Thus each integrated DMA has 2240/2464 control bits, versus the standalone
2260/2504; no payload is removed by this difference. Including the two prepared
flags and unbuffered pair-arbiter selection state, the complete quant pair has
4498/4962 other bits. It does not allocate a shared ordered response queue.

## Remaining audit scope

`p4-boundary-storage-module-totals.json` lists all remaining state, including the
new controller, source-generation join, external-DMA adapter and terminal owner.
Named command/notification/context and external-LOAD metadata allocations now
pass p5-metadata-allocation.md, including the complete external programmer and
source-generation state. Integrated ownership/release and physical boundary
evidence still needs final reconciliation with the plan. This document does not claim those gates
complete or substitute declaration totals for candidate synthesis/timing checks.

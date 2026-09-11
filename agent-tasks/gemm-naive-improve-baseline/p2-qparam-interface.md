# P2 independent naive quant engine integration contract

Implementation: `hw/rtl/core/gemm/VX_naive_qparam_dma.sv`, with local descriptor types in `VX_naive_qparam_types.vh`. Instantiate separately for S and Z under `GEMM_NAIVE`. No shared RTL was modified; improve has no new instantiated logic or altered primitive parameters. No top-level node/controller connection is included in this bounded implementation.

## Admission, activation and completion

| Port(s) | Contract |
|---|---|
| `cmd_valid_i`, `cmd_ready_o`, `cmd_id_i[31:0]`, `cmd_payload_i[234:0]` | Admit exactly one prepared descriptor. Owns a queue record until actual final installation. `cmd_id` is work identity, unique among live descriptors; internal sequence is independent and increments per admission. Four records, eight physical response slots per engine. |
| `activate_valid_i`, `activate_ready_o`, `activate_id_i[31:0]` | Activate the already prepared owner when the controller ordinary issue dependencies become ready. Searches the exact owned work ID. Same-cycle admission+activation is supported. Activation never admits another record or restarts fetching. |
| `writer_head_valid_o`, `writer_head_payload_o[234:0]`, `writer_head_id_o[31:0]`, `writer_release_i` | Expose the ordered install head. Node evaluates its exact `dest.writer_wait` against the correct S/Z consume version; release latches only after activation and remains true until head retirement. Do not substitute source-ready or another bank's counter. |
| `lane_bus_if[DATA_BYTES/8]` | Full 8-byte physical LMEM reads. Tag is the reserved 3-bit slot, zero-extended to the existing bus width. Node arbitration must retain engine identity and remove its routing bits on return. Different lanes and tags may return in any order, exactly once per accepted request. No tag reuse before install releases its old slot. |
| `install_valid_o`, `install_ready_i`, `install_data_o`, `install_byteen_o`, `install_addr_o[15:0]`, `install_bank_o` | Actual byte-enabled register-write boundary. `addr` is destination native-beat index, not bytes. Data, mask, address, bank and identities remain stable while stalled. No extra payload stage is budgeted in a node adapter. |
| `install_id_o`, `install_sequence_o`, `install_segment_o[15:0]`, `install_last_o` | Identity and segment of the actual accepted write; stable with its payload. |
| `source_done_valid_o`, `source_done_id_o`, `source_done_sequence_o`, `source_done_buffer_o`, `source_done_generation_o` | Registered one-cycle, ordered source-read completion event. All segments' full physical lane responses are captured into owned engine storage and no future read remains for this descriptor. Independent from activation, consume fences and installation. Join into the exact source generation externally. There is no event backpressure; the node must accept simultaneous S/Z pulses. |
| `install_done_valid_o`, `install_done_ready_i`, `install_done_id_o`, `install_done_sequence_o`, `install_done_bank_o`, `install_done_target_o` | Registered ordered completion only after the final actual register-write handshake. Event and identity hold until accepted. A full completion register backpressures a later final write, without adding operand storage. |
| `cmd_occupancy_o`, `slot_occupancy_o` | Current bounded owned-record/slot counts, for assertions and directed tests. |

The controller adapter has two paths. Without an earlier prepare, one ordinary command handshake performs one admission plus same-ID activation. If prepare has already admitted the stable head, record that fact in the already budgeted adapter/controller metadata and issue only activation later. Simultaneous prepare and ordinary issue still produce one admission. Never hold `cmd_valid_i` asserted again for an already prepared head: the engine rejects duplicate live work identities in simulation. The adapter must not acknowledge ordinary issue until activation handshakes. Engine installation completion, not preparation or activation, drives the executor's ordered done interface.

The engine-local compact descriptor is an adapter representation, not an ISA-specific replacement for `gemm_unified_cmd_t`.

## Compact mapping, MSB to LSB

`cmd_payload = {source131, destination104}`. Types are available through `VX_NAIVE_QPARAM_TYPES` after including the header within module scope.

| Source field | Bits | Meaning |
|---|---:|---|
| `base` | 34 | LMEM physical byte address of first useful segment byte; corresponding unified command source address. |
| `stride` | 32 | Source byte stride between segments. |
| `segments` | 16 | Number of actual nonempty segments; queue and source/install counters use exactly this count. |
| `useful_bytes` | 16 | Actual useful bytes per segment; no guessed inactive payload. |
| `buffer_id` | 1 | Source-buffer owner ID, independent from destination bank. |
| `generation` | 32 | Exact source-generation identity for SRC_FREE joining. |

| Destination field | Bits | Meaning |
|---|---:|---|
| `bank` | 1 | S/Z register bank. |
| `qrow` | 1 | Retained layout identity for adapter/debug; explicit strides drive the physical mapping. |
| `offset` | 16 | First destination byte offset. |
| `stride` | 16 | Destination byte stride per segment. |
| `writer_wait` | 38 | Opaque exact consume wait (`valid + RID5 + target32` from the node's agreed local encoding). Engine never substitutes a guessed counter. |
| `install_target` | 32 | Exact bank installation generation for completion. |

For baseline QCOL, source stride is NT*2, segment count is ceil(MXU_K/qblk), useful bytes are the actual enabled N elements times two, and destination follows the existing bank layout. For baseline QROW, source stride is ceil(NT/qblk)*2, segments are actual K rows, useful bytes are ceil(MXU_N/qblk)*2, and destination stride is that useful segment width. Preserve the existing command's source/destination offsets and tail bounds in the node mapper; do not derive missing legacy fields inside this engine.

Each segment must fit within one source native beat and one destination native beat. The engine fetches the aligned full native source beat, then combinationally selects useful bytes and places them under the exact destination mask. FP16 alignment, nonzero bounds, source address overflow, destination address overflow and boundary crossing are asserted. Native size is 32 or 64 bytes, MEM_ADDR_WIDTH is 34. There is no generalized byte-assembly payload RAM outside the budget. Reject an unsupported descriptor rather than wrap or silently truncate it.

## Owned storage and ordering

Eight response slots are banked by physical 8-byte lane. Each lane has a four-entry response FIFO and registered head, followed by its 8-slot RAM bank and registered RAM output. Lane tags select reserved ownership directly. Arrival masks join metadata only; no payload copy is hidden in a join table. Ordered installation selects the matching command sequence and segment after every lane has written its RAM bank. Source completion can precede the writer fence; slot reuse waits for actual installation.

The unchanged `VX_mem_bus_split` cannot implement the required arbitrary per-lane tag reordering: it joins FIFO heads under equal-tag order. The unchanged common stream queue accepts complete wide responses rather than individual lane writes. A full extra reassembly buffer would exceed the frozen payload budget. This naive-only engine therefore implements the compact ownership queue and banked RAM explicitly, reusing unchanged FIFO and RAM primitives. There is no TMEM scheduler dependency.

Static generated declaration accounting (`p2-qparam-storage.py`, `p2-qparam-storage{16,32}.json`) passes:

| Per independent engine | MXU16 | MXU32 |
|---|---:|---:|
| Eight native response slots | 256 B | 512 B |
| Registered response RAM output | 32 B | 64 B |
| Four-entry 8-byte lane FIFO RAMs | 128 B | 256 B |
| Registered lane FIFO heads | 32 B | 64 B |
| Operand subtotal | **448 B** | **896 B** |
| Metadata declarations (NDEBUG) | **2,260 bits** | **2,504 bits** |
| PERF-specific added state | 0 | 0 |

Both engines total 896/1,792 B, below old combined quant 928/1,856 B. Metadata is below frozen 6,996/10,280 bits per engine. This is exact generated declaration accounting, not synthesized mapped cost or proof of a full-node ledger. Controller adapter records remain in their separately budgeted scope.

## Verification request

- `test_type: new_tb`
- `test_path: hw/unittest/naive_qparam_dma`
- `sim_tool: vcs`
- Run from a freshly configured build (`../configure --xlen=64 --tooldir=/opt/vortex --prefix="$HOME/tools/vortex"`) after sourcing the naive th16 config. Use `tools/verify_rtl.py unittest --path <configured-build>/hw/unittest/naive_qparam_dma --sim vcs --timeout 600` with CONFIGS exported. Repeat with MXU_ROW/COL/COL_TILE=32 and LMEM_NUM_PORTS=32.
- New files: engine/header plus unittest Makefile, vcs.mk and TB. No production application or blackbox changes.
- Four cases per geometry: QCOL/QROW, each resource blocked in turn. Four descriptors, eight slots, both banks, source-generation-sensitive immutable byte images, reordered tags/lanes, one shared request grant per lane, stable request/install stalls, and exact source/install completion identities.
- Selected resource first installs generation0; its next same-bank writer reaches an unsatisfied consume fence. From this established blocked cut, complementary source service is held for exactly 257 cycles. Then actual request <=64 cycles; actual complementary capture/install <=32,768; all owners retire <=262,144. The prelude is bounded separately by the overall watchdog. The reachable consumer releases only after both actual matching installs, never on a fabricated completion.
- Request delay coverage includes every value 0..15; install delays include 0,1,7,15; accepted responses return within64. Actual complementary response and install must overlap the other blocked writer. Peak descriptor counts must reach4 each, blocked response slots8. One resource uses delayed prepare/activate, the other same-edge admission/activation. VCS results are pending separate verification; static lint is not a functional pass.

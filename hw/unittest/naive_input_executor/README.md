# Physical Input DMA and context integration

Use a configured XLEN64 build, source the matching naive TH16/MXU16 or MXU32
configuration, and invoke `tools/verify_rtl.py unittest --path ABSOLUTE_BUILD_PATH
--sim vcs`. NDEBUG is an additional minimum-tag-width check.

The fixture instantiates the actual `VX_naive_input_executor`, native operand
DMA and sole four-entry packet context array. It returns independently delayed
and reordered physical lane responses from an immutable byte image above 4 GiB.
It verifies source preparation before activation, four queued commands filling
all 16 response slots while GEMM is stopped, actual payload and packet metadata,
next-command ingress while previous completion is backpressured, O admission,
exact terminal work identity, retained terminal completion, and rolling slot
reuse over a 32-row command. Physical source completion is checked independently
from packet ingress and command completion.

Input reuses the same naive-only lane-banked operand engine as S/Z, with
RESPONSE_SLOTS=16 and LANE_FIFO_DEPTH=8. S/Z defaults remain 8/4. This preserves
the old Input slot count and physical lane FIFO depth while avoiding the old
wide-response join's assumption of identical lane response ordering. Only legal
full-native-beat aligned Input sources are used; no generic misalignment
buffer is needed. Preparation allocates a DMA descriptor; ordinary issue
atomically activates that owner and allocates its context exactly once.

Static XML declaration inventory in `p3-input-storage.py` reports payload
**832/1,664 bytes** and metadata **4,620/5,040 bits** for MXU16/32, including the
single context array and one prepared bit. Payload is 16 RAM beats + one RAM
head + eight lane FIFO beats + one lane FIFO head, or 26 native beats. The old
dedicated Input transport used 928/1,856 bytes; three native-beat alignment/output
copies are absent. This is not a mapped-resource or whole-node ledger.

MXU16, MXU32 and MXU16 NDEBUG tests pass. Both original independent S/Z suites
and representative quant-pair cases were rerun after parameterization. Refreshed
S/Z static inventories remain exactly 448/896 bytes and 2,260/2,504 control bits
per engine; previous reports are archived with the test evidence.

These are actual Input transport/context tests with a modeled GEMM sink and
terminal fence. They do not prove GEMM arithmetic, actual terminal producer
closure or integrated bank visibility. The old node must replace its Input
transport and packetizer with this executor; it must not retain another context
array or duplicate the old lane response buffers.

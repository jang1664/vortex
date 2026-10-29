# VX_sram_dma

`VX_sram_dma` copies contiguous padded buffers between the C4 GEMM TMEM and SIMD LMEM. It has one 32-byte staging register, one active command, and one outstanding memory transaction. It does not allocate SRAM or arbitrate ownership with GEMM.

## Command interface

The command is accepted on `cmd_valid_i && cmd_ready_o`. `cmd_direction_i=0` copies TMEM to LMEM; `1` copies LMEM to TMEM. `cmd_tmem_addr_i` is a 64-bit TMEM byte offset, `cmd_lmem_addr_i` is a 64-bit LMEM system byte address, and `cmd_length_i` is a positive 32-byte multiple. Both addresses must be 32-byte aligned. The parameterized address ranges are checked before any request is issued; subtraction-based checks reject arithmetic overflow.

`cmd_sequence_i` is returned in `done_sequence_o`. `done_valid_o` pulses once on success or validation failure. `error_o` is 0 for success, 1 for zero length, 2 for alignment, and 3 for range. Sequence and error remain visible until another command is accepted. `busy_o` remains asserted during the completion pulse and deasserts in the following idle cycle. A command presented while busy is not accepted; the MMIO controller should return its own busy status rather than enqueue it.

## Memory protocol

The TMEM endpoint uses 32-byte words and requires a response for both reads and writes. The LMEM endpoint uses 8-byte words and read responses only. TMEM-to-LMEM copies issue four LMEM stores for each TMEM read. Each store must receive `lmem_write_commit_i` before the next store is sent. The pulse may coincide with request acceptance or arrive later; it must identify a physical SRAM write belonging to this DMA. LMEM-to-TMEM copies collect four LMEM read responses and wait for the TMEM write acknowledgement.

`VX_mem_bus_if` addresses are word addresses. The controller converts its byte addresses once when driving each endpoint; byte order is preserved. All request byte enables are set because the contract permits only whole padded words.

The caller must publish SIMD source writes, acquire exclusive TMEM-route ownership, and drain the old route before accepting a DMA command. It must retain ownership through `busy_o` deassertion. External bus cuts must preserve ordering and propagate physical commit/response events. A system reset must reset the DMA and its associated transport together; a controller-only reset cannot cancel a request already accepted downstream.

## Verification

`hw/unittest/sram_dma` supplies byte-addressed independent SRAM models with randomized request stalls, delayed responses, delayed physical LMEM commits, and same-cycle commits. It checks both directions, all bank-select values, 32 KiB tiles, destination canaries, request counts, busy command isolation, invalid ranges/alignment/zero length, overflow, and reset with an outstanding read. Run from a configured build directory through `tools/verify_rtl.py unittest --path <build>/hw/unittest/sram_dma --sim vcs` after sourcing the C4 configuration.

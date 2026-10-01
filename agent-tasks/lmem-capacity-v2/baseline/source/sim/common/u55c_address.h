// U55C 8-high HBM row/bank/column mapping with bank-group interleaving.
#pragma once
#include <cstdint>

namespace vortex {

// Convert the byte AXI address to the linear ChRaBaRoCo mapper's byte address.
// Functional RAM remains indexed by the original AXI address. Only timing uses
// this bijection. Ch[33:30] and PC[29] remain unchanged.
// AXI: SID[28], row[27:14], BG1[13], BA[12:11], col[10:6], BG0[5], byte[4:0].
// Linear: BG[28:26], BA[25:24], row[23:10], col[9:5], byte[4:0].
inline uint64_t u55c_rbc_interleaved_address(uint64_t address) {
    return (address & ~((uint64_t(1) << 29) - 1))
         | (address & 31)
         | (((address >> 6) & 31) << 5)
         | (((address >> 14) & 16383) << 10)
         | (((address >> 11) & 3) << 24)
         | (((address >> 5) & 1) << 26)
         | (((address >> 13) & 1) << 27)
         | (address & (uint64_t(1) << 28));
}

} // namespace vortex

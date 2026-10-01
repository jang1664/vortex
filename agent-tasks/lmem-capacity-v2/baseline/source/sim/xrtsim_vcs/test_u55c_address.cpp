#include "u55c_address.h"
#include <cassert>
#include <iostream>

int main() {
    using vortex::u55c_rbc_interleaved_address;
    // One-hot bit permutation proves bijection and all aperture boundaries.
    uint64_t outputs = 0;
    for (unsigned bit = 0; bit < 34; ++bit) {
        auto value = u55c_rbc_interleaved_address(uint64_t(1) << bit);
        assert(value && !(value & (value - 1)) && !(outputs & value));
        outputs |= value;
    }
    assert(outputs == (uint64_t(1) << 34) - 1);
    assert(u55c_rbc_interleaved_address(32) == (uint64_t(1) << 26));
    assert(u55c_rbc_interleaved_address(64) == 32);
    assert(u55c_rbc_interleaved_address(16384) == 1024);
    for (uint64_t pc = 0; pc < 32; ++pc) {
        const auto low = pc << 29;
        const auto high = ((pc + 1) << 29) - 1;
        assert(u55c_rbc_interleaved_address(low) == low);
        assert(u55c_rbc_interleaved_address(high) == high);
    }
    std::cout << "U55C address permutation tests passed\n";
}

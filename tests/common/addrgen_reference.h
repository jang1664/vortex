#ifndef VORTEX_TESTS_ADDRGEN_REFERENCE_H
#define VORTEX_TESTS_ADDRGEN_REFERENCE_H

#include <array>
#include <cstdint>

namespace vortex {
namespace test {

struct AddrGenDescriptor {
  uint64_t base = 0;
  std::array<int64_t, 3> stride = {{0, 0, 0}};
  std::array<uint32_t, 3> bound = {{0, 0, 0}};
};

class AddrGenReferenceIterator {
 public:
  explicit AddrGenReferenceIterator(const AddrGenDescriptor& descriptor)
      : descriptor_(descriptor), valid_(descriptor.bound[0] != 0
                                    && descriptor.bound[1] != 0
                                    && descriptor.bound[2] != 0) {}

  bool valid() const {
    return valid_;
  }

  bool next(uint64_t* address) {
    if (!valid_)
      return false;

    *address = descriptor_.base + offset_[0] + offset_[1] + offset_[2];
    advance();
    return true;
  }

 private:
  void advance() {
    for (uint32_t dim = 0; dim < 3; ++dim) {
      if (uint64_t(index_[dim]) + 1 < descriptor_.bound[dim]) {
        ++index_[dim];
        offset_[dim] += static_cast<uint64_t>(descriptor_.stride[dim]);
        return;
      }
      index_[dim] = 0;
      offset_[dim] = 0;
    }
    valid_ = false;
  }

  AddrGenDescriptor descriptor_;
  std::array<uint32_t, 3> index_ = {{0, 0, 0}};
  std::array<uint64_t, 3> offset_ = {{0, 0, 0}};
  bool valid_;
};

}  // namespace test
}  // namespace vortex

#endif

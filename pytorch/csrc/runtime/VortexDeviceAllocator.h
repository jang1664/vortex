#pragma once

#include <c10/core/Allocator.h>
#include <c10/core/CachingDeviceAllocator.h>
#include <c10/core/Device.h>
#include <c10/util/flat_hash_map.h>
#include <include/Macros.h>

#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace c10::vortex {

/// Top-level allocator registered with PyTorch via REGISTER_ALLOCATOR.
class VortexDeviceAllocator final : public c10::DeviceAllocator {
 public:
  VortexDeviceAllocator();

  at::DataPtr allocate(size_t nbytes) override;
  at::DeleterFnPtr raw_deleter() const override;
  void copy_data(void* dest, const void* src, std::size_t count) const final;

  bool initialized() override;
  void emptyCache(MempoolId_t mempool_id = {0, 0}) override;
  void recordStream(const DataPtr& ptr, c10::Stream stream) override;
  c10::CachingDeviceAllocator::DeviceStats getDeviceStats(c10::DeviceIndex device) override;
  void resetAccumulatedStats(c10::DeviceIndex device) override;
  void resetPeakStats(c10::DeviceIndex device) override;

  void freeMemory(void* ptr);
  uint64_t memoryAllocated(c10::DeviceIndex device) const;
  uint64_t memoryReserved(c10::DeviceIndex device) const;
  uint64_t maxMemoryAllocated(c10::DeviceIndex device) const;
  uint64_t maxMemoryReserved(c10::DeviceIndex device) const;
  void resetPeakMemoryStats(c10::DeviceIndex device);
  bool isCachingEnabled() const;

 private:
  struct Block {
    size_t requested_size;
    size_t rounded_size;
    bool cache_eligible;
    bool in_use;
  };

  size_t roundSmallBlock(size_t nbytes) const;
  bool shouldBypassCache(size_t nbytes) const;
  bool tryAllocRuntime(size_t nbytes, void** out_ptr);
  void releaseBlockToRuntime(void* ptr, const Block& block, bool was_cached);
  void clearFreeCacheLocked();
  void updatePeaksLocked();
  void updateGlobalMemLimitLocked();

  c10::CachingDeviceAllocator::DeviceStats stats_;
  mutable std::recursive_mutex mutex_;
  ska::flat_hash_map<void*, Block> blocks_;
  std::unordered_map<size_t, std::vector<void*>> free_bins_;

  uint64_t memory_allocated_{0};
  uint64_t memory_reserved_{0};
  uint64_t max_memory_allocated_{0};
  uint64_t max_memory_reserved_{0};
  uint64_t cached_free_bytes_{0};
  uint64_t cache_limit_bytes_{0};
  bool cache_limit_initialized_{false};

  double cache_fraction_{0.8};
  size_t large_alloc_threshold_{16ull * 1024ull * 1024ull}; // 16 MiB
  size_t min_bin_size_{512};
  bool caching_enabled_{true};
  bool debug_logs_{false};
};

VORTEX_EXPORT void allocator_empty_cache();
VORTEX_EXPORT uint64_t allocator_memory_allocated(c10::DeviceIndex device = 0);
VORTEX_EXPORT uint64_t allocator_memory_reserved(c10::DeviceIndex device = 0);
VORTEX_EXPORT uint64_t allocator_max_memory_allocated(c10::DeviceIndex device = 0);
VORTEX_EXPORT uint64_t allocator_max_memory_reserved(c10::DeviceIndex device = 0);
VORTEX_EXPORT void allocator_reset_peak_memory_stats(c10::DeviceIndex device = 0);
VORTEX_EXPORT bool allocator_is_caching_enabled();

} // namespace c10::vortex

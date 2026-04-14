#include "VortexDeviceAllocator.h"
#include "VortexFunctions.h"
#include "VortexRuntime.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include <c10/util/Exception.h>
#include <c10/util/irange.h>

using namespace c10::CachingAllocator;

namespace c10::vortex {

namespace {

constexpr size_t kAggregate = static_cast<size_t>(StatType::AGGREGATE);
constexpr size_t kDefaultMinBin = 512;
constexpr size_t kDefaultLargeAllocThreshold = 16ull * 1024ull * 1024ull;
constexpr double kDefaultCacheFraction = 0.8;

size_t next_power_of_two(size_t v) {
  if (v <= 1) {
    return 1;
  }
  --v;
  v |= v >> 1;
  v |= v >> 2;
  v |= v >> 4;
  v |= v >> 8;
  v |= v >> 16;
  if (sizeof(size_t) >= 8) {
    v |= v >> 32;
  }
  return v + 1;
}

double get_env_double(const char* key, double default_value) {
  const char* v = std::getenv(key);
  if (!v || *v == '\0') {
    return default_value;
  }
  char* end = nullptr;
  double parsed = std::strtod(v, &end);
  if (end == v || !std::isfinite(parsed)) {
    return default_value;
  }
  return parsed;
}

size_t get_env_size_mb(const char* key, size_t default_mb) {
  const char* v = std::getenv(key);
  if (!v || *v == '\0') {
    return default_mb * 1024ull * 1024ull;
  }
  char* end = nullptr;
  unsigned long long parsed = std::strtoull(v, &end, 10);
  if (end == v) {
    return default_mb * 1024ull * 1024ull;
  }
  return static_cast<size_t>(parsed * 1024ull * 1024ull);
}

bool get_env_bool(const char* key, bool default_value) {
  const char* v = std::getenv(key);
  if (!v || *v == '\0') {
    return default_value;
  }
  return (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 ||
          std::strcmp(v, "TRUE") == 0 || std::strcmp(v, "yes") == 0 ||
          std::strcmp(v, "YES") == 0);
}

bool get_allocator_mode_cached() {
  const char* v = std::getenv("TORCH_VORTEX_ALLOCATOR_MODE");
  if (!v || *v == '\0') {
    return true;
  }
  if (std::strcmp(v, "naive") == 0 || std::strcmp(v, "off") == 0 ||
      std::strcmp(v, "0") == 0) {
    return false;
  }
  // Any other value (cached/on/1/unknown) defaults to cached mode.
  return true;
}

VortexDeviceAllocator g_allocator;

void deleteVortexMemory(void* ptr) {
  g_allocator.freeMemory(ptr);
}

} // namespace

VortexDeviceAllocator::VortexDeviceAllocator() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  cache_fraction_ = get_env_double("TORCH_VORTEX_CACHE_FRACTION", kDefaultCacheFraction);
  cache_fraction_ = std::max(0.0, std::min(1.0, cache_fraction_));
  large_alloc_threshold_ =
      get_env_size_mb("TORCH_VORTEX_LARGE_ALLOC_THRESHOLD_MB", 16);
  if (large_alloc_threshold_ == 0) {
    large_alloc_threshold_ = kDefaultLargeAllocThreshold;
  }
  min_bin_size_ = kDefaultMinBin;
  caching_enabled_ = get_allocator_mode_cached();
  debug_logs_ = get_env_bool("TORCH_VORTEX_ALLOCATOR_DEBUG", false);
}

size_t VortexDeviceAllocator::roundSmallBlock(size_t nbytes) const {
  size_t rounded = next_power_of_two(std::max(nbytes, min_bin_size_));
  return rounded;
}

bool VortexDeviceAllocator::shouldBypassCache(size_t nbytes) const {
  return !caching_enabled_
      || nbytes >= large_alloc_threshold_
      || VortexRuntime::instance().getMemoryAlignment() != 0;
}

void VortexDeviceAllocator::updateGlobalMemLimitLocked() {
  if (cache_limit_initialized_) {
    return;
  }
  auto& rt = VortexRuntime::instance();
  uint64_t global_mem = rt.globalMemSize();
  cache_limit_bytes_ = static_cast<uint64_t>(global_mem * cache_fraction_);
  cache_limit_initialized_ = true;
}

bool VortexDeviceAllocator::tryAllocRuntime(size_t nbytes, void** out_ptr) {
  void* ptr = nullptr;
  auto& rt = VortexRuntime::instance();
  uint64_t requested_alignment = rt.getMemoryAlignment();
  auto ret = (requested_alignment != 0)
      ? vortexMallocAligned(&ptr, nbytes, requested_alignment)
      : vortexMalloc(&ptr, nbytes);
  if (ret != kVortexSuccess || ptr == nullptr) {
    *out_ptr = nullptr;
    return false;
  }
  *out_ptr = ptr;
  return true;
}

void VortexDeviceAllocator::releaseBlockToRuntime(void* ptr, const Block& block, bool was_cached) {
  auto ret = vortexFree(ptr);
  if (ret != kVortexSuccess) {
    TORCH_WARN("vortexFree failed for pointer ", ptr);
    return;
  }
  stats_.num_device_free++;
  stats_.reserved_bytes[kAggregate].decrease(block.rounded_size);
  if (was_cached) {
    stats_.inactive_split_bytes[kAggregate].decrease(block.rounded_size);
    cached_free_bytes_ -= block.rounded_size;
  }
  memory_reserved_ -= block.rounded_size;
  blocks_.erase(ptr);
}

void VortexDeviceAllocator::clearFreeCacheLocked() {
  for (auto& [_, ptrs] : free_bins_) {
    while (!ptrs.empty()) {
      void* ptr = ptrs.back();
      ptrs.pop_back();
      auto it = blocks_.find(ptr);
      if (it == blocks_.end()) {
        continue;
      }
      if (it->second.in_use) {
        continue;
      }
      releaseBlockToRuntime(ptr, it->second, /*was_cached=*/true);
    }
  }
  free_bins_.clear();
}

void VortexDeviceAllocator::updatePeaksLocked() {
  max_memory_allocated_ = std::max(max_memory_allocated_, memory_allocated_);
  max_memory_reserved_ = std::max(max_memory_reserved_, memory_reserved_);
}

at::DataPtr VortexDeviceAllocator::allocate(size_t nbytes) {
  constexpr int current_device_index = 0;
  auto curr_device = c10::Device(c10::DeviceType::PrivateUse1, current_device_index);
  if (nbytes == 0) {
    return {nullptr, nullptr, &deleteVortexMemory, curr_device};
  }

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  updateGlobalMemLimitLocked();

  const bool bypass_cache = shouldBypassCache(nbytes);
  const size_t rounded_size = bypass_cache ? nbytes : roundSmallBlock(nbytes);

  void* data = nullptr;
  if (!bypass_cache) {
    auto fit = free_bins_.find(rounded_size);
    if (fit != free_bins_.end() && !fit->second.empty()) {
      data = fit->second.back();
      fit->second.pop_back();
      if (fit->second.empty()) {
        free_bins_.erase(fit);
      }
      auto it = blocks_.find(data);
      TORCH_CHECK(it != blocks_.end(), "Cached block missing from metadata");
      auto& block = it->second;
      TORCH_CHECK(!block.in_use, "Cached block unexpectedly active");
      block.in_use = true;
      block.requested_size = nbytes;
      cached_free_bytes_ -= block.rounded_size;
      memory_allocated_ += nbytes;
      stats_.allocated_bytes[kAggregate].increase(nbytes);
      stats_.active_bytes[kAggregate].increase(nbytes);
      stats_.requested_bytes[kAggregate].increase(nbytes);
      stats_.inactive_split_bytes[kAggregate].decrease(block.rounded_size);
      updatePeaksLocked();
      return {data, data, &deleteVortexMemory, curr_device};
    }
  }

  bool ok = tryAllocRuntime(rounded_size, &data);
  if (!ok) {
    stats_.num_alloc_retries++;
    clearFreeCacheLocked();
    ok = tryAllocRuntime(rounded_size, &data);
  }
  if (!ok) {
    stats_.num_ooms++;
    TORCH_CHECK(
        false,
        "Failed to allocate ",
        nbytes,
        " bytes on Vortex device. ",
        "Allocated: ",
        memory_allocated_,
        " bytes, Reserved: ",
        memory_reserved_,
        " bytes");
  }

  stats_.num_device_alloc++;
  memory_allocated_ += nbytes;
  memory_reserved_ += rounded_size;
  stats_.allocated_bytes[kAggregate].increase(nbytes);
  stats_.active_bytes[kAggregate].increase(nbytes);
  stats_.requested_bytes[kAggregate].increase(nbytes);
  stats_.reserved_bytes[kAggregate].increase(rounded_size);
  updatePeaksLocked();

  blocks_[data] = Block{
      nbytes,
      rounded_size,
      !bypass_cache,
      true,
  };
  return {data, data, &deleteVortexMemory, curr_device};
}

at::DeleterFnPtr VortexDeviceAllocator::raw_deleter() const {
  return &deleteVortexMemory;
}

void VortexDeviceAllocator::copy_data(void* dest, const void* src, std::size_t count) const {
  auto ret = vortexMemcpy(dest, src, count, kDeviceToDevice);
  TORCH_CHECK(ret == kVortexSuccess, "Failed to copy ", count, " bytes on Vortex device");
}

bool VortexDeviceAllocator::initialized() {
  return c10::vortex::device_count() > 0;
}

void VortexDeviceAllocator::freeMemory(void* ptr) {
  if (!ptr) {
    return;
  }

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  auto it = blocks_.find(ptr);
  if (it == blocks_.end()) {
    (void)vortexFree(ptr);
    return;
  }

  auto& block = it->second;
  if (!block.in_use) {
    return;
  }

  block.in_use = false;
  memory_allocated_ -= block.requested_size;
  stats_.allocated_bytes[kAggregate].decrease(block.requested_size);
  stats_.active_bytes[kAggregate].decrease(block.requested_size);
  block.requested_size = 0;

  const bool keep_cached = block.cache_eligible &&
      caching_enabled_ &&
      (cached_free_bytes_ + block.rounded_size <= cache_limit_bytes_);
  if (keep_cached) {
    free_bins_[block.rounded_size].push_back(ptr);
    cached_free_bytes_ += block.rounded_size;
    stats_.inactive_split_bytes[kAggregate].increase(block.rounded_size);
    return;
  }
  releaseBlockToRuntime(ptr, block, /*was_cached=*/false);
}

c10::CachingDeviceAllocator::DeviceStats VortexDeviceAllocator::getDeviceStats(c10::DeviceIndex device) {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return stats_;
}

void VortexDeviceAllocator::resetAccumulatedStats(c10::DeviceIndex device) {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  for (const auto stat_type : c10::irange(static_cast<size_t>(StatType::NUM_TYPES))) {
    stats_.allocated_bytes[stat_type].reset_accumulated();
    stats_.reserved_bytes[stat_type].reset_accumulated();
    stats_.active_bytes[stat_type].reset_accumulated();
    stats_.inactive_split_bytes[stat_type].reset_accumulated();
    stats_.requested_bytes[stat_type].reset_accumulated();
  }
  stats_.num_alloc_retries = 0;
  stats_.num_ooms = 0;
  stats_.num_sync_all_streams = 0;
  stats_.num_device_alloc = 0;
  stats_.num_device_free = 0;
}

void VortexDeviceAllocator::resetPeakStats(c10::DeviceIndex device) {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  for (const auto stat_type : c10::irange(static_cast<size_t>(StatType::NUM_TYPES))) {
    stats_.allocated_bytes[stat_type].reset_peak();
    stats_.reserved_bytes[stat_type].reset_peak();
    stats_.active_bytes[stat_type].reset_peak();
    stats_.inactive_split_bytes[stat_type].reset_peak();
    stats_.requested_bytes[stat_type].reset_peak();
  }
  stats_.oversize_allocations.reset_peak();
  stats_.oversize_segments.reset_peak();
}

void VortexDeviceAllocator::emptyCache(MempoolId_t /*mempool_id*/) {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  clearFreeCacheLocked();
}

void VortexDeviceAllocator::recordStream(const DataPtr& /*ptr*/, c10::Stream /*stream*/) {
  // Vortex is synchronous — no stream tracking needed.
}

uint64_t VortexDeviceAllocator::memoryAllocated(c10::DeviceIndex device) const {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return memory_allocated_;
}

uint64_t VortexDeviceAllocator::memoryReserved(c10::DeviceIndex device) const {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return memory_reserved_;
}

uint64_t VortexDeviceAllocator::maxMemoryAllocated(c10::DeviceIndex device) const {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return max_memory_allocated_;
}

uint64_t VortexDeviceAllocator::maxMemoryReserved(c10::DeviceIndex device) const {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return max_memory_reserved_;
}

bool VortexDeviceAllocator::isCachingEnabled() const {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return caching_enabled_;
}

void VortexDeviceAllocator::resetPeakMemoryStats(c10::DeviceIndex device) {
  check_device_index(device);
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  max_memory_allocated_ = memory_allocated_;
  max_memory_reserved_ = memory_reserved_;
  resetPeakStats(device);
}

void allocator_empty_cache() {
  g_allocator.emptyCache();
}

uint64_t allocator_memory_allocated(c10::DeviceIndex device) {
  return g_allocator.memoryAllocated(device);
}

uint64_t allocator_memory_reserved(c10::DeviceIndex device) {
  return g_allocator.memoryReserved(device);
}

uint64_t allocator_max_memory_allocated(c10::DeviceIndex device) {
  return g_allocator.maxMemoryAllocated(device);
}

uint64_t allocator_max_memory_reserved(c10::DeviceIndex device) {
  return g_allocator.maxMemoryReserved(device);
}

void allocator_reset_peak_memory_stats(c10::DeviceIndex device) {
  g_allocator.resetPeakMemoryStats(device);
}

bool allocator_is_caching_enabled() {
  return g_allocator.isCachingEnabled();
}

REGISTER_ALLOCATOR(c10::DeviceType::PrivateUse1, &g_allocator);

} // namespace c10::vortex

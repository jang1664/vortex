#include "VortexDeviceAllocator.h"
#include "VortexFunctions.h"
#include "VortexRuntime.h"

#include <c10/util/Exception.h>
#include <c10/util/irange.h>

using namespace c10::CachingAllocator;

namespace c10::vortex {

constexpr size_t kAggregate = static_cast<size_t>(StatType::AGGREGATE);

// ============ DeviceMemoryAllocator ============

DeviceMemoryAllocator::DeviceMemoryAllocator(c10::DeviceIndex device_index)
    : device_index_(device_index) {}

void* DeviceMemoryAllocator::malloc(size_t nbytes) {
  if (nbytes == 0) return nullptr;

  std::lock_guard<std::recursive_mutex> lock(mutex_);

  void* data = nullptr;
  auto ret = vortexMalloc(&data, nbytes);

  TORCH_CHECK(
      ret == kVortexSuccess && data != nullptr,
      "Failed to allocate ", nbytes, " bytes on Vortex device ",
      device_index_, ". ",
      "Allocated: ", stats_.allocated_bytes[0].current, " bytes, ",
      "Reserved: ", stats_.reserved_bytes[0].current, " bytes");

  allocation_sizes_[data] = nbytes;
  stats_.allocated_bytes[kAggregate].increase(nbytes);
  stats_.reserved_bytes[kAggregate].increase(nbytes);
  stats_.num_device_alloc++;

  return data;
}

void DeviceMemoryAllocator::free(void* ptr) {
  if (!ptr) return;

  std::lock_guard<std::recursive_mutex> lock(mutex_);

  auto ret = vortexFree(ptr);
  if (ret == kVortexSuccess) {
    auto it = allocation_sizes_.find(ptr);
    if (it != allocation_sizes_.end()) {
      size_t nbytes = it->second;
      stats_.allocated_bytes[kAggregate].decrease(nbytes);
      stats_.reserved_bytes[kAggregate].decrease(nbytes);
      stats_.num_device_free++;
      allocation_sizes_.erase(it);
    }
  } else {
    TORCH_WARN("vortexFree failed for pointer ", ptr, " on device ", device_index_);
  }
}

c10::CachingDeviceAllocator::DeviceStats DeviceMemoryAllocator::getStats() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return stats_;
}

void DeviceMemoryAllocator::resetAccumulatedStats() {
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

void DeviceMemoryAllocator::resetPeakStats() {
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

// ============ VortexDeviceAllocator ============

namespace {
VortexDeviceAllocator g_allocator;

void deleteVortexMemory(void* ptr) {
  g_allocator.freeMemory(ptr);
}
}  // namespace

VortexDeviceAllocator::VortexDeviceAllocator() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  const auto count = c10::vortex::device_count();
  device_allocators_.resize(count);
  for (const auto i : c10::irange(count)) {
    device_allocators_[i] = std::make_unique<DeviceMemoryAllocator>(i);
  }
}

at::DataPtr VortexDeviceAllocator::allocate(size_t nbytes) {
  // Vortex is single-device → always device 0
  constexpr int current_device_index = 0;
  auto curr_device = c10::Device(c10::DeviceType::PrivateUse1, current_device_index);

  void* data = nullptr;
  if (nbytes > 0) {
    data = device_allocators_[current_device_index]->malloc(nbytes);
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    allocated_blocks_[data] = current_device_index;
  }
  return {data, data, &deleteVortexMemory, curr_device};
}

at::DeleterFnPtr VortexDeviceAllocator::raw_deleter() const {
  return &deleteVortexMemory;
}

void VortexDeviceAllocator::copy_data(
    void* dest, const void* src, std::size_t count) const {
  auto ret = vortexMemcpy(dest, src, count, kDeviceToDevice);
  TORCH_CHECK(ret == kVortexSuccess,
              "Failed to copy ", count, " bytes on Vortex device");
}

bool VortexDeviceAllocator::initialized() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  return !device_allocators_.empty();
}

void VortexDeviceAllocator::freeMemory(void* ptr) {
  if (!ptr) return;

  c10::DeviceIndex device_index = -1;
  bool found = false;
  {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    auto it = allocated_blocks_.find(ptr);
    if (it != allocated_blocks_.end()) {
      device_index = it->second;
      allocated_blocks_.erase(it);
      found = true;
    }
  }

  if (found) {
    device_allocators_[device_index]->free(ptr);
  } else {
    vortexFree(ptr);
  }
}

c10::CachingDeviceAllocator::DeviceStats
VortexDeviceAllocator::getDeviceStats(c10::DeviceIndex device) {
  return device_allocators_[device]->getStats();
}

void VortexDeviceAllocator::resetAccumulatedStats(c10::DeviceIndex device) {
  device_allocators_[device]->resetAccumulatedStats();
}

void VortexDeviceAllocator::resetPeakStats(c10::DeviceIndex device) {
  device_allocators_[device]->resetPeakStats();
}

void VortexDeviceAllocator::emptyCache(MempoolId_t /*mempool_id*/) {
  // TODO: Implement cache eviction when caching is added
}

void VortexDeviceAllocator::recordStream(const DataPtr& /*ptr*/, c10::Stream /*stream*/) {
  // Vortex is synchronous — no stream tracking needed
}

// ============ Global Registration ============
REGISTER_ALLOCATOR(c10::DeviceType::PrivateUse1, &g_allocator);

} // namespace c10::vortex

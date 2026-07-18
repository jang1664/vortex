#include "VortexRuntime.h"

#include <c10/util/Exception.h>
#include <cstdint>
#include <cstring>
#include <limits>

namespace c10::vortex {

namespace {

thread_local uint64_t g_requested_memory_alignment = 0;

bool isPowerOfTwo(uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

} // namespace

VortexRuntime& VortexRuntime::instance() {
  static VortexRuntime inst;
  return inst;
}

VortexRuntime::~VortexRuntime() {
  shutdown();
}

int VortexRuntime::init() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (initialized_) return kVortexSuccess;

  int ret = vx_dev_open(&device_);
  if (ret != 0) {
    return kVortexError;
  }
  initialized_ = true;
  return kVortexSuccess;
}

void VortexRuntime::shutdown() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (!initialized_) return;

  // Free all outstanding buffers
  for (auto& [ptr, info] : buffer_map_) {
    vx_mem_free(info.handle);
    std::free(info.staging);
  }
  buffer_map_.clear();

  vx_dev_close(device_);
  device_ = nullptr;
  initialized_ = false;
  cache_line_size_ = 0;
}

void* VortexRuntime::malloc(size_t nbytes) {
  if (nbytes == 0) return nullptr;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (init() != kVortexSuccess) {
    return nullptr;
  }

  // Allocate device buffer
  vx_buffer_h hbuf = nullptr;
  uint64_t requested_alignment = g_requested_memory_alignment;
  int ret = 0;
  if (requested_alignment != 0) {
    ret = vx_mem_alloc_aligned(device_, nbytes, requested_alignment, VX_MEM_READ_WRITE, &hbuf);
  } else {
    ret = vx_mem_alloc(device_, nbytes, VX_MEM_READ_WRITE, &hbuf);
  }
  if (ret != 0 || !hbuf) {
    return nullptr;
  }

  // Allocate a host-side staging buffer.
  // This staging pointer is what PyTorch sees as the "data_ptr".
  // When kernels need to read/write, data is synced between staging and device.
  void* staging = std::malloc(nbytes);
  if (!staging) {
    vx_mem_free(hbuf);
    return nullptr;
  }
  std::memset(staging, 0, nbytes);

  BufferInfo info{hbuf, nbytes, staging};
  buffer_map_[staging] = info;

  return staging;
}

int VortexRuntime::setMemoryAlignment(uint64_t alignment) {
  if (alignment == 0) {
    g_requested_memory_alignment = 0;
    return kVortexSuccess;
  }
  if (!isPowerOfTwo(alignment)) {
    return kVortexError;
  }

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (init() != kVortexSuccess) {
    return kVortexError;
  }

  uint64_t cache_line_size = cacheLineSize();
  if (cache_line_size == 0
   || alignment < cache_line_size
   || (alignment % cache_line_size) != 0) {
    return kVortexError;
  }

  g_requested_memory_alignment = alignment;
  return kVortexSuccess;
}

uint64_t VortexRuntime::getMemoryAlignment() const {
  return g_requested_memory_alignment;
}

uint64_t VortexRuntime::exchangeMemoryAlignment(uint64_t alignment) {
  uint64_t prev_alignment = g_requested_memory_alignment;
  if (this->setMemoryAlignment(alignment) != kVortexSuccess) {
    return std::numeric_limits<uint64_t>::max();
  }
  return prev_alignment;
}

int VortexRuntime::free(void* ptr) {
  if (!ptr) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  auto it = buffer_map_.find(ptr);
  if (it == buffer_map_.end()) {
    return kVortexError;
  }

  vx_mem_free(it->second.handle);
  std::free(it->second.staging);
  buffer_map_.erase(it);
  return kVortexSuccess;
}

VortexRuntime::BufferInfo* VortexRuntime::findBufferContaining(
    const void* ptr, size_t nbytes, size_t* offset) {
  return const_cast<BufferInfo*>(
      static_cast<const VortexRuntime*>(this)->findBufferContaining(ptr, nbytes, offset));
}

const VortexRuntime::BufferInfo* VortexRuntime::findBufferContaining(
    const void* ptr, size_t nbytes, size_t* offset) const {
  if (!ptr) return nullptr;
  const uintptr_t address = reinterpret_cast<uintptr_t>(ptr);
  for (const auto& [base_ptr, info] : buffer_map_) {
    const uintptr_t base = reinterpret_cast<uintptr_t>(base_ptr);
    if (address < base) continue;
    const uintptr_t delta = address - base;
    if (delta > info.size || nbytes > info.size - delta) continue;
    if (offset) *offset = static_cast<size_t>(delta);
    return &info;
  }
  return nullptr;
}

vx_buffer_h VortexRuntime::bufferForPtr(void* ptr) const {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  const auto* info = findBufferContaining(ptr, 0, nullptr);
  return info ? info->handle : nullptr;
}

int VortexRuntime::memcpy(void* dst, const void* src, size_t nbytes, VortexMemcpyKind kind) {
  if (nbytes == 0) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);

  switch (kind) {
    case kHostToDevice: {
      // src is host, dst is our staging pointer → copy into staging, then upload
      size_t dst_offset = 0;
      auto* info = findBufferContaining(dst, nbytes, &dst_offset);
      if (!info) return kVortexError;
      std::memcpy(dst, src, nbytes);  // update staging
      return vx_copy_to_dev(info->handle, src, dst_offset, nbytes);
    }
    case kDeviceToHost: {
      // src is staging pointer, dst is host
      size_t src_offset = 0;
      auto* info = findBufferContaining(src, nbytes, &src_offset);
      if (!info) return kVortexError;
      int ret = vx_copy_from_dev(dst, info->handle, src_offset, nbytes);
      return ret;
    }
    case kDeviceToDevice: {
      // Both src and dst are staging pointers — go through host
      size_t src_offset = 0;
      size_t dst_offset = 0;
      auto* src_info = findBufferContaining(src, nbytes, &src_offset);
      auto* dst_info = findBufferContaining(dst, nbytes, &dst_offset);
      if (!src_info || !dst_info) {
        // Fallback: plain memcpy on staging buffers
        std::memcpy(dst, src, nbytes);
        return kVortexSuccess;
      }
      // Download from src device buffer to temporary, upload to dst device buffer
      void* tmp = std::malloc(nbytes);
      if (!tmp) return kVortexError;
      int ret = vx_copy_from_dev(tmp, src_info->handle, src_offset, nbytes);
      if (ret == 0) {
        ret = vx_copy_to_dev(dst_info->handle, tmp, dst_offset, nbytes);
        std::memcpy(dst, tmp, nbytes);  // keep staging in sync
      }
      std::free(tmp);
      return ret;
    }
    case kHostToHost: {
      std::memcpy(dst, src, nbytes);
      return kVortexSuccess;
    }
  }
  return kVortexError;
}

int VortexRuntime::syncToDevice(void* staging_ptr, size_t nbytes) {
  if (!staging_ptr || nbytes == 0) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  size_t offset = 0;
  auto* info = findBufferContaining(staging_ptr, 0, &offset);
  if (!info) return kVortexError;

  size_t copy_size = std::min(nbytes, info->size - offset);
  return vx_copy_to_dev(info->handle, staging_ptr, offset, copy_size);
}

int VortexRuntime::syncFromDevice(void* staging_ptr, size_t nbytes) {
  if (!staging_ptr || nbytes == 0) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  size_t offset = 0;
  auto* info = findBufferContaining(staging_ptr, 0, &offset);
  if (!info) return kVortexError;

  size_t copy_size = std::min(nbytes, info->size - offset);
  return vx_copy_from_dev(staging_ptr, info->handle, offset, copy_size);
}

uint64_t VortexRuntime::deviceAddress(void* staging_ptr) const {
  if (!staging_ptr) return 0;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  size_t offset = 0;
  const auto* info = findBufferContaining(staging_ptr, 0, &offset);
  if (!info) return 0;

  uint64_t addr = 0;
  vx_mem_address(info->handle, &addr);
  return addr + offset;
}

uint64_t VortexRuntime::globalMemSize() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (init() != kVortexSuccess) {
    return 0;
  }
  uint64_t mem_size = 0;
  vx_dev_caps(device_, VX_CAPS_GLOBAL_MEM_SIZE, &mem_size);
  return mem_size;
}

uint64_t VortexRuntime::cacheLineSize() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  if (init() != kVortexSuccess) {
    return 0;
  }
  if (cache_line_size_ == 0) {
    vx_dev_caps(device_, VX_CAPS_CACHE_LINE_SIZE, &cache_line_size_);
  }
  return cache_line_size_;
}

} // namespace c10::vortex

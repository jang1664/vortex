#include "VortexRuntime.h"

#include <c10/util/Exception.h>
#include <cstring>

namespace c10::vortex {

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
}

void* VortexRuntime::malloc(size_t nbytes) {
  if (nbytes == 0) return nullptr;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  init();

  // Allocate device buffer
  vx_buffer_h hbuf = nullptr;
  int ret = vx_mem_alloc(device_, nbytes, VX_MEM_READ_WRITE, &hbuf);
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

vx_buffer_h VortexRuntime::bufferForPtr(void* ptr) const {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  auto it = buffer_map_.find(ptr);
  if (it == buffer_map_.end()) return nullptr;
  return it->second.handle;
}

int VortexRuntime::memcpy(void* dst, const void* src, size_t nbytes, VortexMemcpyKind kind) {
  if (nbytes == 0) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);

  switch (kind) {
    case kHostToDevice: {
      // src is host, dst is our staging pointer → copy into staging, then upload
      auto it = buffer_map_.find(dst);
      if (it == buffer_map_.end()) return kVortexError;
      std::memcpy(dst, src, nbytes);  // update staging
      return vx_copy_to_dev(it->second.handle, src, 0, nbytes);
    }
    case kDeviceToHost: {
      // src is staging pointer, dst is host
      auto it = buffer_map_.find(const_cast<void*>(src));
      if (it == buffer_map_.end()) return kVortexError;
      int ret = vx_copy_from_dev(dst, it->second.handle, 0, nbytes);
      return ret;
    }
    case kDeviceToDevice: {
      // Both src and dst are staging pointers — go through host
      auto src_it = buffer_map_.find(const_cast<void*>(src));
      auto dst_it = buffer_map_.find(dst);
      if (src_it == buffer_map_.end() || dst_it == buffer_map_.end()) {
        // Fallback: plain memcpy on staging buffers
        std::memcpy(dst, src, nbytes);
        return kVortexSuccess;
      }
      // Download from src device buffer to temporary, upload to dst device buffer
      void* tmp = std::malloc(nbytes);
      int ret = vx_copy_from_dev(tmp, src_it->second.handle, 0, nbytes);
      if (ret == 0) {
        ret = vx_copy_to_dev(dst_it->second.handle, tmp, 0, nbytes);
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
  auto it = buffer_map_.find(staging_ptr);
  if (it == buffer_map_.end()) return kVortexError;

  size_t copy_size = std::min(nbytes, it->second.size);
  return vx_copy_to_dev(it->second.handle, staging_ptr, 0, copy_size);
}

int VortexRuntime::syncFromDevice(void* staging_ptr, size_t nbytes) {
  if (!staging_ptr || nbytes == 0) return kVortexSuccess;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  auto it = buffer_map_.find(staging_ptr);
  if (it == buffer_map_.end()) return kVortexError;

  size_t copy_size = std::min(nbytes, it->second.size);
  return vx_copy_from_dev(staging_ptr, it->second.handle, 0, copy_size);
}

uint64_t VortexRuntime::deviceAddress(void* staging_ptr) const {
  if (!staging_ptr) return 0;

  std::lock_guard<std::recursive_mutex> lock(mutex_);
  auto it = buffer_map_.find(staging_ptr);
  if (it == buffer_map_.end()) return 0;

  uint64_t addr = 0;
  vx_mem_address(it->second.handle, &addr);
  return addr;
}

uint64_t VortexRuntime::globalMemSize() {
  std::lock_guard<std::recursive_mutex> lock(mutex_);
  init();
  uint64_t mem_size = 0;
  vx_dev_caps(device_, VX_CAPS_GLOBAL_MEM_SIZE, &mem_size);
  return mem_size;
}

} // namespace c10::vortex

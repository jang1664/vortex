#pragma once
/// @file VortexRuntime.h
/// @brief Vortex runtime wrapper — Translates vx_* handle-based API into
///        a simpler interface for PyTorch allocator/guard integration.
///
/// Key design: Vortex uses opaque handles (vx_device_h, vx_buffer_h) rather
/// than raw pointers. This layer maintains a global device handle and a
/// pointer↔buffer_handle mapping so that PyTorch's raw-pointer-based
/// allocator interface can work with Vortex memory.

#include <vortex.h>

#include <include/Macros.h>

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <unordered_map>

namespace c10::vortex {

/// Error codes mirroring vx_* return values
enum VortexError {
  kVortexSuccess = 0,
  kVortexError = -1,
};

/// Direction enum for vortexMemcpy
enum VortexMemcpyKind {
  kHostToDevice,
  kDeviceToHost,
  kDeviceToDevice,
  kHostToHost,
};

/// Global runtime state — wraps a single vx_device_h handle.
/// Vortex is inherently a single-device system; we present it as
/// device index 0 to PyTorch.
class VORTEX_EXPORT VortexRuntime {
 public:
  static VortexRuntime& instance();

  /// Open the device (idempotent — only opens once)
  int init();

  /// Close the device
  void shutdown();

  bool isInitialized() const { return initialized_; }

  vx_device_h deviceHandle() const { return device_; }

  // ---- Memory management ----
  // These wrap vx_mem_alloc / vx_mem_free but also maintain a mapping
  // from host-visible staging pointer → vx_buffer_h so that PyTorch's
  // raw-pointer allocator can work.

  /// Allocate device memory.  Returns a host-visible staging pointer that
  /// the allocator can hand to PyTorch.  The real device buffer handle is
  /// tracked internally.
  void* malloc(size_t nbytes);

  /// Free device memory previously allocated via malloc().
  int free(void* ptr);

  /// Look up the buffer handle for a host pointer returned by malloc().
  vx_buffer_h bufferForPtr(void* ptr) const;

  /// Copy data between host and device using the appropriate vx_copy_* call.
  int memcpy(void* dst, const void* src, size_t nbytes, VortexMemcpyKind kind);

  /// Sync staging buffer content → device memory.  Call after writing data
  /// into the staging pointer (e.g. after a CPU→Device copy into data_ptr).
  int syncToDevice(void* staging_ptr, size_t nbytes);

  /// Sync device memory → staging buffer.  Call before reading data from
  /// the staging pointer (e.g. before a Device→CPU copy from data_ptr).
  int syncFromDevice(void* staging_ptr, size_t nbytes);

  /// Return the device-side address for a staging pointer.  This is the
  /// address that Vortex kernels can dereference directly.
  uint64_t deviceAddress(void* staging_ptr) const;

  // ---- Device info ----
  int deviceCount() const { return initialized_ ? 1 : 0; }
  uint64_t globalMemSize();

 private:
  VortexRuntime() = default;
  ~VortexRuntime();

  VortexRuntime(const VortexRuntime&) = delete;
  VortexRuntime& operator=(const VortexRuntime&) = delete;

  vx_device_h device_ = nullptr;
  bool initialized_ = false;

  // Mapping: staging host pointer → (vx_buffer_h, size)
  struct BufferInfo {
    vx_buffer_h handle;
    size_t size;
    void* staging;  // Host-side staging buffer for CPU fallback access
  };
  mutable std::recursive_mutex mutex_;
  std::unordered_map<void*, BufferInfo> buffer_map_;
};

// ---- Convenience free-functions (thin wrappers) ----

inline VORTEX_EXPORT int vortexMalloc(void** ptr, size_t nbytes) {
  auto& rt = VortexRuntime::instance();
  void* p = rt.malloc(nbytes);
  if (!p && nbytes > 0) {
    *ptr = nullptr;
    return kVortexError;
  }
  *ptr = p;
  return kVortexSuccess;
}

inline VORTEX_EXPORT int vortexFree(void* ptr) {
  return VortexRuntime::instance().free(ptr);
}

inline VORTEX_EXPORT int vortexMemcpy(void* dst, const void* src, size_t nbytes, VortexMemcpyKind kind) {
  return VortexRuntime::instance().memcpy(dst, src, nbytes, kind);
}

inline VORTEX_EXPORT int vortexGetDeviceCount(int* count) {
  *count = VortexRuntime::instance().deviceCount();
  return kVortexSuccess;
}

inline VORTEX_EXPORT int vortexSetDevice(int /*device*/) {
  // Single-device — no-op but ensure initialized
  VortexRuntime::instance().init();
  return kVortexSuccess;
}

inline VORTEX_EXPORT int vortexGetDevice(int* device) {
  *device = 0;
  return kVortexSuccess;
}

inline VORTEX_EXPORT int vortexDeviceSynchronize() {
  auto& rt = VortexRuntime::instance();
  if (!rt.isInitialized()) return kVortexSuccess;
  return vx_ready_wait(rt.deviceHandle(), VX_MAX_TIMEOUT);
}

// Host memory — for Vortex, host memory is just regular malloc/free
inline VORTEX_EXPORT int vortexMallocHost(void** ptr, size_t nbytes) {
  *ptr = std::malloc(nbytes);
  return (*ptr || nbytes == 0) ? kVortexSuccess : kVortexError;
}

inline VORTEX_EXPORT int vortexFreeHost(void* ptr) {
  std::free(ptr);
  return kVortexSuccess;
}

} // namespace c10::vortex

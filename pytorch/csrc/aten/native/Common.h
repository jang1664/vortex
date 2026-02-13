#pragma once
/// @file Common.h
/// @brief Common includes and utilities for Vortex ATen operator implementations.
///
/// Unlike openreg's MemoryGuard (which uses mmap/mprotect), Vortex uses a
/// staging-buffer model.  The staging pointer IS the data_ptr seen by PyTorch,
/// and it is always accessible from the CPU side.  Therefore we don't need
/// a MemoryGuard for CPU fallback — the data is already readable.
///
/// When data needs to be on the Vortex device (for kernel execution), explicit
/// sync calls (vortexSyncToDevice / vortexSyncFromDevice) are used.

#include <ATen/EmptyTensor.h>
#include <ATen/TensorIterator.h>
#include <ATen/TensorOperators.h>
#include <ATen/native/CPUFallback.h>
#include <ATen/ops/_local_scalar_dense_native.h>
#include <ATen/ops/_reshape_alias_native.h>
#include <ATen/ops/as_strided_cpu_dispatch.h>
#include <ATen/ops/copy_native.h>
#include <ATen/ops/resize_native.h>
#include <ATen/ops/set_cpu_dispatch.h>
#include <ATen/ops/set_native.h>
#include <ATen/ops/view_native.h>

#include <c10/core/Allocator.h>

namespace at::native::vortex {

/// SyncGuard — ensures data is synced from device to staging before CPU access.
///
/// In Vortex's staging-buffer model, the staging pointer is always valid for
/// CPU reads (it's regular malloc'd memory).  However, if a Vortex kernel has
/// written results to device memory, we need to copy them back to staging
/// before PyTorch's CPU-side code reads them.
///
/// For the initial skeleton (CPU fallback mode), this is a no-op since we
/// never actually run Vortex kernels.  When real kernel support is added,
/// this class should be extended to do vx_copy_from_dev as needed.
class SyncGuard {
 public:
  template <typename... Args>
  explicit SyncGuard(const Args&... /*args*/) {
    // TODO: When Vortex kernels are implemented, sync device→staging here
  }

  ~SyncGuard() noexcept {
    // TODO: When Vortex kernels write results, sync staging→device here
  }

  SyncGuard(const SyncGuard&) = delete;
  SyncGuard& operator=(const SyncGuard&) = delete;
  SyncGuard(SyncGuard&&) = delete;
  SyncGuard& operator=(SyncGuard&&) = delete;
};

} // namespace at::native::vortex

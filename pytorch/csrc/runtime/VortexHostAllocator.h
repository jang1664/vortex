#pragma once

#include <ATen/core/CachingHostAllocator.h>
#include <c10/core/Allocator.h>
#include <c10/core/Device.h>

#include "VortexRuntime.h"

namespace c10::vortex {

/// Host (pinned) memory allocator for Vortex.
/// Since Vortex doesn't distinguish pinned vs non-pinned host memory,
/// this just uses standard malloc/free.
struct VortexHostAllocator final : at::HostAllocator {
  VortexHostAllocator() = default;

  static void ReportAndDelete(void* ptr) {
    if (!ptr) return;
    vortexFreeHost(ptr);
  }

  at::DataPtr allocate(size_t nbytes) override {
    void* data = nullptr;
    if (nbytes > 0) {
      vortexMallocHost(&data, nbytes);
      TORCH_CHECK(data, "Failed to allocate ", nbytes, " bytes on host.");
    }
    return {data, data, &ReportAndDelete, at::Device(at::kCPU)};
  }

  at::DeleterFnPtr raw_deleter() const override {
    return &ReportAndDelete;
  }

  void copy_data(void* dest, const void* src, std::size_t count) const final {
    vortexMemcpy(dest, src, count, kHostToHost);
  }

  bool record_event(void* /*ptr*/, void* /*ctx*/, c10::Stream /*stream*/) override {
    return true;  // no-op
  }

  void empty_cache() override {}

  at::HostStats get_stats() override {
    return at::HostStats();
  }

  void reset_accumulated_stats() override {}
  void reset_peak_stats() override {}
};

} // namespace c10::vortex

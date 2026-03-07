#pragma once

#include <c10/core/Device.h>
#include <c10/core/DeviceCapability.h>
#include <c10/core/impl/DeviceGuardImplInterface.h>

#include "VortexException.h"
#include "VortexFunctions.h"
#include "VortexRuntime.h"

namespace c10::vortex {

/// DeviceGuard implementation for Vortex.
///
/// Vortex is a single-device system with no native stream or event support.
/// Stream and event methods are implemented as no-ops or minimal stubs so
/// that PyTorch's infrastructure (which expects them) does not crash.
struct VortexGuardImpl final : public c10::impl::DeviceGuardImplInterface {
  static constexpr DeviceType static_type = c10::DeviceType::PrivateUse1;

  VortexGuardImpl() = default;

  explicit VortexGuardImpl(DeviceType t) {
    TORCH_CHECK(t == static_type,
                "VortexGuardImpl initialized with non-PrivateUse1 DeviceType: ", t);
  }

  // ---- Device management ----

  DeviceType type() const override { return static_type; }

  Device exchangeDevice(Device d) const override {
    TORCH_CHECK(d.is_privateuseone(), "Expected PrivateUse1 device, got ", d);
    auto old = ExchangeDevice(d.index());
    return Device(static_type, old);
  }

  Device getDevice() const override {
    return Device(static_type, current_device());
  }

  DeviceCapability getDeviceCapability(Device /*unused*/) const override {
    return DeviceCapability();
  }

  void setDevice(Device d) const override {
    TORCH_CHECK(d.is_privateuseone(), "Expected PrivateUse1 device, got ", d);
    set_device(d.index());
  }

  void uncheckedSetDevice(Device d) const noexcept override {
    // Best-effort, no-throw
    VortexRuntime::instance().init();
  }

  DeviceIndex deviceCount() const noexcept override {
    return device_count();
  }

  void synchronizeDevice(const DeviceIndex /*device_index*/) const override {
    vortexDeviceSynchronize();
  }

  // ---- Stream stubs (Vortex has no stream concept) ----
  // We use a synthetic stream id = 0 for the "default stream".

  Stream getStream(Device d) const noexcept override {
    return Stream(Stream::DEFAULT, d);
  }

  Stream getDefaultStream(Device d) const override {
    return Stream(Stream::DEFAULT, d);
  }

  Stream getNewStream(Device d, int /*priority*/ = 0) const override {
    // Vortex is synchronous — all work goes to the single "stream"
    return Stream(Stream::DEFAULT, d);
  }

  Stream getStreamFromGlobalPool(Device d, bool /*isHighPriority*/ = false) const override {
    return Stream(Stream::DEFAULT, d);
  }

  Stream exchangeStream(Stream s) const noexcept override {
    return s;  // no-op — only one stream
  }

  bool queryStream(const Stream& /*stream*/) const override {
    return true;  // always complete (synchronous device)
  }

  void synchronizeStream(const Stream& /*stream*/) const override {
    vortexDeviceSynchronize();
  }

  // ---- Event stubs ----

  void destroyEvent(void* /*event*/, const DeviceIndex /*device_index*/) const noexcept override {
    // No-op — events are not supported
  }

  void record(void** /*event*/, const Stream& /*stream*/,
              const DeviceIndex /*device_index*/, const EventFlag /*flag*/) const override {
    // No-op
  }

  void block(void* /*event*/, const Stream& /*stream*/) const override {
    // No-op
  }

  bool queryEvent(void* /*event*/) const override {
    return true;  // always "recorded"
  }

  void synchronizeEvent(void* /*event*/) const override {
    vortexDeviceSynchronize();
  }

  double elapsedTime(void* /*event1*/, void* /*event2*/,
                     const DeviceIndex /*device_index*/) const override {
    return 0.0;  // timing not supported
  }
};

} // namespace c10::vortex

#pragma once

#include <ATen/core/CachingHostAllocator.h>
#include <ATen/detail/PrivateUse1HooksInterface.h>
#include <c10/core/Allocator.h>
#include <c10/core/Device.h>

#include "VortexFunctions.h"
#include "VortexGenerator.h"
#include "VortexRuntime.h"

namespace c10::vortex {

struct VORTEX_EXPORT VortexHooksInterface : public at::PrivateUse1HooksInterface {
  VortexHooksInterface() = default;
  ~VortexHooksInterface() override = default;

  void init() const override {
    VortexRuntime::instance().init();
  }

  bool hasPrimaryContext(DeviceIndex /*device_index*/) const override {
    return true;
  }

  bool isBuilt() const override {
    return true;
  }

  bool isAvailable() const override {
    return device_count() > 0;
  }

  DeviceIndex deviceCount() const override {
    return device_count();
  }

  void setCurrentDevice(DeviceIndex device) const override {
    set_device(device);
  }

  DeviceIndex getCurrentDevice() const override {
    return current_device();
  }

  DeviceIndex exchangeDevice(DeviceIndex device) const override {
    return ExchangeDevice(device);
  }

  DeviceIndex maybeExchangeDevice(DeviceIndex device) const override {
    auto count = device_count();
    if (device < 0 || device >= count) {
      return getCurrentDevice();
    }
    return exchangeDevice(device);
  }

  at::Allocator* getPinnedMemoryAllocator() const override {
    return at::getHostAllocator(at::kPrivateUse1);
  }

  bool isPinnedPtr(const void* /*data*/) const override {
    // Vortex does not distinguish pinned vs non-pinned host memory
    return false;
  }

  at::Device getDeviceFromPtr(void* /*data*/) const override {
    // Single-device system — all device pointers belong to device 0
    return at::Device(at::DeviceType::PrivateUse1, 0);
  }

  const at::Generator& getDefaultGenerator(DeviceIndex device_index) const override {
    return getDefaultVortexGenerator(device_index);
  }

  at::Generator getNewGenerator(DeviceIndex device_index) const override {
    return at::make_generator<VortexGeneratorImpl>(device_index);
  }
};

} // namespace c10::vortex

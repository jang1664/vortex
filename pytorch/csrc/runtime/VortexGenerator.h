#pragma once

#include <ATen/CPUGeneratorImpl.h>
#include <ATen/core/GeneratorForPrivateuseone.h>
#include <c10/core/Device.h>

#include "VortexFunctions.h"

namespace c10::vortex {

/// RNG generator for Vortex.
/// Since Vortex doesn't have on-device RNG, we inherit from CPUGeneratorImpl
/// and just override the device/dispatch key.
class VortexGeneratorImpl : public at::CPUGeneratorImpl {
 public:
  VortexGeneratorImpl(c10::DeviceIndex device_index) {
    device_ = c10::Device(c10::DeviceType::PrivateUse1, device_index);
    key_set_ = c10::DispatchKeySet(c10::DispatchKey::PrivateUse1);
  }
  ~VortexGeneratorImpl() override = default;
};

const at::Generator& getDefaultVortexGenerator(
    c10::DeviceIndex device_index = -1);

} // namespace c10::vortex
